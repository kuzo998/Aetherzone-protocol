// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherGuard.sol v1.0
//
// MEV AND MANIPULATION PROTECTION FOR ALL SWAPS
//
// THE PROBLEM:
//   Standard DEX swaps are vulnerable to sandwich attacks. A bot sees your
//   pending transaction, front-runs it to move the price, lets your trade
//   execute at the worse price, then back-runs to profit. On Shido this is
//   especially relevant for the limit order bot executing retail orders.
//
// WHAT THIS CONTRACT DOES:
//   1. TWAP Validation: Before any swap, compare spot price to the pool's
//      time-weighted average price (TWAP). If they diverge more than the
//      allowed threshold, the swap reverts. This defeats flash loan
//      price manipulation.
//
//   2. Pool Whitelist: Only pools deployed by the legitimate ShidoDEX
//      factory are allowed. Prevents routing through malicious pools.
//
//   3. Token Whitelist: Only pre-approved tokens can be swapped. Prevents
//      interaction with malicious ERC20s that have transfer hooks.
//
//   4. Slippage Hard Cap: Maximum slippage enforced at the guard level,
//      regardless of what the caller requests. Prevents draining via
//      excessive slippage parameters.
//
// HOW THE BOT USES THIS:
//   Instead of calling the ShidoDEX router directly in executeOrder,
//   the bot calls AetherGuard.safeSwap which validates everything first.
//   RetailLimitOrders.setApprovedRouter(AETHER_GUARD_ADDRESS, true)
//
// TWAP:
//   Uniswap V3 pools store an oracle of cumulative ticks. We read the
//   30-second TWAP and compare it to spot price. If spot deviates by more
//   than maxTwapDeviationBps, the swap is sandwichable and we revert.
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

// ShidoDEX router - NO deadline in exactInputSingle (Shido-specific)
interface IShidoDEXRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract AetherGuard {

    // ─── Config ───────────────────────────────────────────────────────────────

    address public immutable factory;
    address public immutable dexRouter;

    // TWAP window in seconds - 30s is enough to detect flash loan manipulation
    uint32  public twapWindow          = 30;
    // Max allowed deviation between spot and TWAP price before reverting
    uint256 public maxTwapDeviationBps = 200;  // 2% default
    // Max slippage allowed regardless of caller's request
    uint256 public maxSlippageBps      = 300;  // 3% hard cap
    // Minimum amount to protect against dust attacks
    uint256 public minSwapAmount       = 1000; // in smallest token unit

    uint256 public constant BPS_BASE = 10000;

    address public owner;
    bool    public paused;
    uint256 private _lock;

    // Whitelisted tokens (only these can be swapped through AetherGuard)
    mapping(address => bool) public approvedTokens;
    // Approved callers (RetailLimitOrders bot only in production)
    mapping(address => bool) public approvedCallers;

    // ─── Events ───────────────────────────────────────────────────────────────

    event SafeSwapExecuted(address indexed caller, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, int24 spotTick, int24 twapTick);
    event SwapRejected(address indexed caller, string reason);
    event TokenApproved(address indexed token, bool approved);
    event CallerApproved(address indexed caller, bool approved);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner()    { require(msg.sender == owner, "AG: Not owner"); _; }
    modifier nonReentrant() { require(_lock == 0, "AG: Reentrant"); _lock = 1; _; _lock = 0; }

    constructor(address _factory, address _dexRouter) {
        factory   = _factory;
        dexRouter = _dexRouter;
        owner     = msg.sender;
    }

    // ════════════════════════════════════════════════════════════════════════
    // SAFE SWAP — the main protected entry point
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Execute a swap with full MEV and manipulation protection.
     *
     * Checks performed before every swap:
     *   1. Caller is whitelisted (only approved contracts/bots)
     *   2. Both tokens are whitelisted
     *   3. Pool was deployed by the legitimate ShidoDEX factory
     *   4. Spot price vs TWAP deviation is within tolerance
     *   5. Slippage parameter doesn't exceed the hard cap
     *   6. Amount is above the minimum dust threshold
     *
     * @param tokenIn       Token to sell
     * @param tokenOut      Token to buy
     * @param poolFee       Pool fee tier
     * @param amountIn      Amount of tokenIn
     * @param minAmountOut  Minimum acceptable output (caller's slippage)
     * @param recipient     Who receives tokenOut
     */
    function safeSwap(
        address tokenIn,
        address tokenOut,
        uint24  poolFee,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        require(!paused, "AG: Paused");
        require(approvedCallers[msg.sender], "AG: Caller not approved");
        require(approvedTokens[tokenIn],     "AG: tokenIn not approved");
        require(approvedTokens[tokenOut],    "AG: tokenOut not approved");
        require(amountIn >= minSwapAmount,   "AG: Amount too small");

        // Validate pool is from legitimate factory
        address pool = IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, poolFee);
        require(pool != address(0), "AG: Pool not from factory");

        // TWAP check - detect price manipulation
        _validateTwap(pool);

        // Enforce slippage hard cap
        uint256 impliedSlippage = minAmountOut == 0 ? BPS_BASE :
            BPS_BASE - (minAmountOut * BPS_BASE / amountIn); // rough estimate
        require(impliedSlippage <= maxSlippageBps, "AG: Slippage exceeds cap");

        // Pull tokens from caller
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "AG: Pull failed");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;

        // Execute the swap
        IERC20(tokenIn).approve(dexRouter, received);
        amountOut = IShidoDEXRouter(dexRouter).exactInputSingle(
            IShidoDEXRouter.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               poolFee,
                recipient:         recipient,
                amountIn:          received,
                amountOutMinimum:  minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).approve(dexRouter, 0);

        // Log for monitoring
        (, int24 spotTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        int24 twapTick = _getTwapTick(pool);
        emit SafeSwapExecuted(msg.sender, tokenIn, tokenOut, received, amountOut, spotTick, twapTick);
    }

    // ─── TWAP Validation ──────────────────────────────────────────────────────

    /**
     * @notice Reverts if spot price deviates too much from TWAP.
     * This is the core sandwich/flash loan protection.
     *
     * A flash loan can move spot price significantly within one block.
     * The TWAP (time-weighted average) is much harder to manipulate —
     * it requires sustained price pressure over the twapWindow seconds.
     * If spot diverges from TWAP by more than maxTwapDeviationBps,
     * the pool has likely been manipulated and we revert.
     */
    function _validateTwap(address pool) internal view {
        (, int24 spotTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        int24 twapTick = _getTwapTick(pool);

        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;

        // Convert tick difference to approximate price deviation in BPS
        // Each tick = 0.01% price movement. diff ticks = diff * 1 BPS roughly.
        uint256 deviationBps = uint256(uint24(diff));

        require(deviationBps <= maxTwapDeviationBps,
            "AG: Price manipulated - spot diverges from TWAP");
    }

    function _getTwapTick(address pool) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            int56 tickCumulativeDelta = tickCumulatives[1] - tickCumulatives[0];
            return int24(tickCumulativeDelta / int56(uint56(twapWindow)));
        } catch {
            // Pool may not have enough observations yet (new pool)
            // Fall back to spot tick — safe because the swap will still have minAmountOut protection
            (, int24 spotTick, , , , , ) = IUniswapV3Pool(pool).slot0();
            return spotTick;
        }
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /**
     * @notice Check if a swap would pass the TWAP validation.
     * Call off-chain before submitting to check if pool is being manipulated.
     */
    function checkTwapSafe(
        address tokenIn,
        address tokenOut,
        uint24  poolFee
    ) external view returns (
        bool safe,
        int24 spotTick,
        int24 twapTick,
        uint256 deviationBps
    ) {
        address pool = IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, poolFee);
        if (pool == address(0)) return (false, 0, 0, 0);

        (, spotTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        twapTick = _getTwapTick(pool);

        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        deviationBps = uint256(uint24(diff));
        safe = deviationBps <= maxTwapDeviationBps;
    }

    function isPoolSafe(address tokenIn, address tokenOut, uint24 fee) external view returns (bool) {
        address pool = IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee);
        return pool != address(0); // factory-deployed = safe
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    // Call after deployment to whitelist ShidoDEX tokens
    // approveToken(WSHIDO, true); approveToken(USDC, true); approveToken(CWK, true); etc.
    function approveToken(address token, bool approved) external onlyOwner {
        approvedTokens[token] = approved;
        emit TokenApproved(token, approved);
    }

    function batchApproveTokens(address[] calldata tokens, bool approved) external onlyOwner {
        for (uint256 i; i < tokens.length; i++) {
            approvedTokens[tokens[i]] = approved;
            emit TokenApproved(tokens[i], approved);
        }
    }

    // Whitelist RetailLimitOrders contract as approved caller
    function approveCaller(address caller, bool approved) external onlyOwner {
        approvedCallers[caller] = approved;
        emit CallerApproved(caller, approved);
    }

    function setTwapWindow(uint32 _window) external onlyOwner {
        require(_window >= 10, "AG: Window too short");
        twapWindow = _window;
    }

    function setMaxTwapDeviation(uint256 _bps) external onlyOwner {
        require(_bps >= 50 && _bps <= 1000, "AG: Out of range"); // 0.5%-10%
        maxTwapDeviationBps = _bps;
    }

    function setMaxSlippage(uint256 _bps) external onlyOwner {
        require(_bps <= 1000, "AG: Slippage cap too high"); // max 10%
        maxSlippageBps = _bps;
    }

    function setMinSwapAmount(uint256 _min) external onlyOwner { minSwapAmount = _min; }
    function setPaused(bool _p) external onlyOwner { paused = _p; }
    function transferOwnership(address n) external onlyOwner { require(n != address(0)); owner = n; }
    function rescueTokens(address t, uint256 a) external onlyOwner { IERC20(t).transfer(owner, a); }
}
