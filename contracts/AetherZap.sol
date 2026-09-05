// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherZap.sol v2.0
//
// Single-token entry/exit for V3 LP positions + auto-compounding.
// Called directly by users AND by AetherRangeManager for rebalancing.
//
// THREE CORE FUNCTIONS:
//
//   zapIn(tokenIn, amountIn, token0, token1, poolFee, tickLower, tickUpper,
//         slippageBps, recipient)
//     One token in -> LP position NFT to recipient.
//     Calculates optimal split, swaps, mints LP, refunds dust.
//
//   zapInFromBoth(token0, amount0, token1, amount1, poolFee, tickLower,
//                 tickUpper, slippageBps, recipient)
//     Two tokens in -> LP position NFT. Used by AetherRangeManager which
//     already has both tokens after removing an existing position.
//     Rebalances ratio to match the target range, mints, refunds dust.
//
//   zapOut(tokenId, tokenOut, slippageBps)
//     LP position NFT in -> single token out.
//     Removes liquidity, collects fees, swaps everything to tokenOut.
//     Caller must own the NFT or be approved.
//
//   compoundFees(tokenId, slippageBps)
//     Collect accrued LP fees and reinvest into the same position.
//     Permissionless - anyone can call for any position.
//     Caller gets 0.1% keeper reward from the fees.
//
// FEES:
//   zapIn / zapOut / zapInFromBoth: feeBps (0.1% default) of input/output
//   compoundFees: 0 platform fee (caller earns 0.1% keeper reward instead)
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function tickSpacing() external view returns (int24);
}

// ShidoDEX router - NO deadline in exactInputSingle (Shido-specific)
interface IShidoDEXRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee;
        address recipient; uint256 amountIn;
        uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        uint256 deadline;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId; uint128 liquidity;
        uint256 amount0Min; uint256 amount1Min; uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId; address recipient;
        uint128 amount0Max; uint128 amount1Max;
    }
    function mint(MintParams calldata) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata) external payable returns (uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    function burn(uint256) external payable;
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
    function positions(uint256) external view returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function ownerOf(uint256) external view returns (address);
    function safeTransferFrom(address, address, uint256) external;
}

contract AetherZap {

    // ─── Addresses ────────────────────────────────────────────────────────────

    address public immutable factory;
    address public immutable positionManager;
    address public immutable router;

    uint128 private constant MAX_UINT128 = type(uint128).max;
    uint256 public constant BPS_BASE     = 10000;

    // ─── Fee Config ───────────────────────────────────────────────────────────

    uint256 public feeBps              = 10;   // 0.1% on zapIn/zapOut/zapInFromBoth
    uint256 public constant MAX_FEE    = 100;  // 1% hard cap
    uint256 public keeperRewardBps     = 10;   // 0.1% to compoundFees caller

    address public feeRecipient;               // AetherRevenueDistributor
    mapping(address => bool) public authorizedCallers; // AetherRangeManager whitelist

    address public owner;
    bool    public paused;
    uint256 private _lock;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ZappedIn(address indexed user, address tokenIn, uint256 amountIn, uint256 tokenId, uint128 liquidity, uint256 platformFee);
    event ZappedInFromBoth(address indexed user, uint256 amount0In, uint256 amount1In, uint256 tokenId, uint128 liquidity);
    event ZappedOut(address indexed user, uint256 tokenId, address tokenOut, uint256 amountOut, uint256 platformFee);
    event FeesCompounded(uint256 indexed tokenId, address caller, uint256 added0, uint256 added1, uint256 keeperReward0, uint256 keeperReward1);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner()     { require(msg.sender == owner, "ZAP: Not owner"); _; }
    modifier nonReentrant()  { require(_lock == 0, "ZAP: Reentrant"); _lock = 1; _; _lock = 0; }
    modifier whenNotPaused() { require(!paused, "ZAP: Paused"); _; }

    constructor(address _factory, address _positionManager, address _router, address _feeRecipient) {
        factory         = _factory;
        positionManager = _positionManager;
        router          = _router;
        feeRecipient    = _feeRecipient;
        owner           = msg.sender;
    }

    // ════════════════════════════════════════════════════════════════════════
    // ZAP IN — single token to LP position
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice One token in, LP position NFT out.
     * @param tokenIn     Single token to deposit
     * @param amountIn    Amount of tokenIn (gross, platform fee deducted first)
     * @param token0      Pool token0 (lower address)
     * @param token1      Pool token1
     * @param poolFee     Pool fee tier
     * @param tickLower   Lower tick of target range
     * @param tickUpper   Upper tick of target range
     * @param slippageBps Slippage tolerance on internal swap (e.g. 50 = 0.5%)
     * @param recipient   Who receives the minted NFT (user or contract)
     */
    function zapIn(
        address tokenIn,
        uint256 amountIn,
        address token0,
        address token1,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper,
        uint256 slippageBps,
        address recipient
    ) external nonReentrant whenNotPaused returns (uint256 tokenId, uint128 liquidity) {
        require(tokenIn == token0 || tokenIn == token1, "ZAP: tokenIn must be pool token");
        require(tickLower < tickUpper, "ZAP: Invalid ticks");
        require(amountIn > 0, "ZAP: Zero amount");
        require(recipient != address(0), "ZAP: Zero recipient");

        address pool = IUniswapV3Factory(factory).getPool(token0, token1, poolFee);
        require(pool != address(0), "ZAP: Pool not found");

        // Pull tokenIn
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "ZAP: Pull failed");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;

        // Platform fee
        uint256 platformFee = _takeFee(tokenIn, received);
        uint256 net = received - platformFee;

        (tokenId, liquidity) = _zapInInternal(tokenIn, net, token0, token1, poolFee, tickLower, tickUpper, slippageBps, recipient, pool);

        emit ZappedIn(msg.sender, tokenIn, received, tokenId, liquidity, platformFee);
    }

    // ════════════════════════════════════════════════════════════════════════
    // ZAP IN FROM BOTH — two tokens to LP (used by AetherRangeManager)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Provide BOTH tokens and get an LP position.
     * Used by AetherRangeManager which already has both tokens after
     * removing an existing position. Swaps to correct ratio then mints.
     *
     * Called by: authorized contracts (AetherRangeManager) OR external users.
     * When called by authorized contracts, tokens are already in this contract.
     * When called externally, tokens are pulled from msg.sender.
     *
     * @param callerHasTokens  true = tokens already transferred to this contract (internal call)
     *                         false = pull tokens from msg.sender (external call)
     */
    function zapInFromBoth(
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper,
        uint256 slippageBps,
        address recipient,
        bool    callerHasTokens
    ) external nonReentrant whenNotPaused returns (uint256 tokenId, uint128 liquidity) {
        require(tickLower < tickUpper, "ZAP: Invalid ticks");
        require(recipient != address(0), "ZAP: Zero recipient");

        // Authorized contracts can call with tokens already deposited
        if (!callerHasTokens) {
            if (amount0 > 0) {
                uint256 b0 = IERC20(token0).balanceOf(address(this));
                require(IERC20(token0).transferFrom(msg.sender, address(this), amount0));
                amount0 = IERC20(token0).balanceOf(address(this)) - b0;
            }
            if (amount1 > 0) {
                uint256 b1 = IERC20(token1).balanceOf(address(this));
                require(IERC20(token1).transferFrom(msg.sender, address(this), amount1));
                amount1 = IERC20(token1).balanceOf(address(this)) - b1;
            }
            // Platform fee on external zapInFromBoth
            if (amount0 > 0) { uint256 f = _takeFee(token0, amount0); amount0 -= f; }
            if (amount1 > 0) { uint256 f = _takeFee(token1, amount1); amount1 -= f; }
        } else {
            // Only authorized callers can use callerHasTokens=true
            require(authorizedCallers[msg.sender], "ZAP: Not authorized");
        }

        address pool = IUniswapV3Factory(factory).getPool(token0, token1, poolFee);
        require(pool != address(0), "ZAP: Pool not found");

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();

        // Swap to correct ratio based on tick position
        (amount0, amount1) = _rebalanceForRange(token0, amount0, token1, amount1, poolFee, tickLower, tickUpper, currentTick, slippageBps);

        // Mint position
        if (amount0 > 0) IERC20(token0).approve(positionManager, amount0);
        if (amount1 > 0) IERC20(token1).approve(positionManager, amount1);

        uint256 used0;
        uint256 used1;
        (tokenId, liquidity, used0, used1) = INonfungiblePositionManager(positionManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0, token1: token1, fee: poolFee,
                tickLower: tickLower, tickUpper: tickUpper,
                amount0Desired: amount0, amount1Desired: amount1,
                amount0Min: 0, amount1Min: 0,
                recipient: recipient,
                deadline: block.timestamp + 1200
            })
        );
        IERC20(token0).approve(positionManager, 0);
        IERC20(token1).approve(positionManager, 0);

        // Refund dust to recipient
        uint256 dust0 = amount0 > used0 ? amount0 - used0 : 0;
        uint256 dust1 = amount1 > used1 ? amount1 - used1 : 0;
        if (dust0 > 1) IERC20(token0).transfer(recipient, dust0);
        if (dust1 > 1) IERC20(token1).transfer(recipient, dust1);

        emit ZappedInFromBoth(msg.sender, amount0, amount1, tokenId, liquidity);
    }

    // ════════════════════════════════════════════════════════════════════════
    // ZAP OUT — LP position to single token
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Remove entire LP position and receive a single token.
     * Caller must own the NFT. Removes liquidity, collects all fees,
     * swaps both tokens to tokenOut, sends proceeds to caller.
     */
    function zapOut(
        uint256 tokenId,
        address tokenOut,
        uint256 slippageBps
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(INonfungiblePositionManager(positionManager).ownerOf(tokenId) == msg.sender, "ZAP: Not your position");

        (, , address token0, address token1, uint24 fee, , , uint128 posLiquidity, , , , ) =
            INonfungiblePositionManager(positionManager).positions(tokenId);

        require(tokenOut == token0 || tokenOut == token1, "ZAP: tokenOut must be pool token");

        // Transfer NFT here
        INonfungiblePositionManager(positionManager).safeTransferFrom(msg.sender, address(this), tokenId);

        uint256 bal0Before = IERC20(token0).balanceOf(address(this));
        uint256 bal1Before = IERC20(token1).balanceOf(address(this));

        // Remove all liquidity + collect fees (both position tokens AND accrued pool fees)
        _withdrawPosition(tokenId, posLiquidity);

        uint256 got0 = IERC20(token0).balanceOf(address(this)) - bal0Before;
        uint256 got1 = IERC20(token1).balanceOf(address(this)) - bal1Before;

        // Swap the non-tokenOut side to tokenOut
        bool wantToken0 = (tokenOut == token0);
        if (!wantToken0 && got0 > 0) {
            IERC20(token0).approve(router, got0);
            uint256 minOut = got0 * (BPS_BASE - slippageBps) / BPS_BASE;
            got1 += IShidoDEXRouter(router).exactInputSingle(
                IShidoDEXRouter.ExactInputSingleParams({
                    tokenIn: token0, tokenOut: token1, fee: fee,
                    recipient: address(this), amountIn: got0,
                    amountOutMinimum: minOut, sqrtPriceLimitX96: 0
                })
            );
            IERC20(token0).approve(router, 0);
        } else if (wantToken0 && got1 > 0) {
            IERC20(token1).approve(router, got1);
            uint256 minOut = got1 * (BPS_BASE - slippageBps) / BPS_BASE;
            got0 += IShidoDEXRouter(router).exactInputSingle(
                IShidoDEXRouter.ExactInputSingleParams({
                    tokenIn: token1, tokenOut: token0, fee: fee,
                    recipient: address(this), amountIn: got1,
                    amountOutMinimum: minOut, sqrtPriceLimitX96: 0
                })
            );
            IERC20(token1).approve(router, 0);
        }

        amountOut = wantToken0 ? got0 : got1;

        // Platform fee on output
        uint256 platformFee = _takeFee(tokenOut, amountOut);
        uint256 userAmount  = amountOut - platformFee;

        require(IERC20(tokenOut).transfer(msg.sender, userAmount), "ZAP: Transfer failed");
        emit ZappedOut(msg.sender, tokenId, tokenOut, userAmount, platformFee);
    }

    // ════════════════════════════════════════════════════════════════════════
    // COMPOUND FEES — collect and reinvest LP fees (permissionless keeper)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Collect accumulated pool fees and reinvest into the same position.
     * No platform fee. Caller receives 0.1% keeper reward from the collected fees.
     * Anyone can call this for any position — the position owner always benefits.
     */
    function compoundFees(
        uint256 tokenId,
        uint256 slippageBps
    ) external nonReentrant whenNotPaused returns (uint256 added0, uint256 added1) {
        (, , address token0, address token1, uint24 fee,
         int24 tickLower, int24 tickUpper, , , , , ) =
            INonfungiblePositionManager(positionManager).positions(tokenId);

        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        require(pool != address(0), "ZAP: Pool not found");

        // Collect fees only (no decreaseLiquidity - position stays open)
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager(positionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this),
                amount0Max: MAX_UINT128, amount1Max: MAX_UINT128
            })
        );

        uint256 fees0 = IERC20(token0).balanceOf(address(this)) - b0;
        uint256 fees1 = IERC20(token1).balanceOf(address(this)) - b1;

        if (fees0 == 0 && fees1 == 0) return (0, 0);

        // Platform fee (feeBps = 0.1%) on collected LP fees -> feeRecipient
        if (fees0 > 0) { uint256 pf = _takeFee(token0, fees0); fees0 -= pf; }
        if (fees1 > 0) { uint256 pf = _takeFee(token1, fees1); fees1 -= pf; }

        // Keeper reward (keeperRewardBps = 0.1% of remaining) -> caller
        uint256 r0 = (fees0 * keeperRewardBps) / BPS_BASE;
        uint256 r1 = (fees1 * keeperRewardBps) / BPS_BASE;
        if (r0 > 0) { IERC20(token0).transfer(msg.sender, r0); fees0 -= r0; }
        if (r1 > 0) { IERC20(token1).transfer(msg.sender, r1); fees1 -= r1; }

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        (fees0, fees1) = _rebalanceForRange(token0, fees0, token1, fees1, fee, tickLower, tickUpper, currentTick, slippageBps);

        if (fees0 > 0) IERC20(token0).approve(positionManager, fees0);
        if (fees1 > 0) IERC20(token1).approve(positionManager, fees1);

        (, added0, added1) = INonfungiblePositionManager(positionManager).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: fees0, amount1Desired: fees1,
                amount0Min: 0, amount1Min: 0,
                deadline: block.timestamp + 300
            })
        );
        IERC20(token0).approve(positionManager, 0);
        IERC20(token1).approve(positionManager, 0);

        // Return any leftover dust to position owner
        address posOwner = INonfungiblePositionManager(positionManager).ownerOf(tokenId);
        uint256 d0 = IERC20(token0).balanceOf(address(this)) - b0;
        uint256 d1 = IERC20(token1).balanceOf(address(this)) - b1;
        if (d0 > 1) IERC20(token0).transfer(posOwner, d0);
        if (d1 > 1) IERC20(token1).transfer(posOwner, d1);

        emit FeesCompounded(tokenId, msg.sender, added0, added1, r0, r1);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _zapInInternal(
        address tokenIn,
        uint256 net,
        address token0,
        address token1,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper,
        uint256 slippageBps,
        address recipient,
        address pool
    ) internal returns (uint256 tokenId, uint128 liquidity) {
        bool isToken0 = (tokenIn == token0);
        address tokenOut = isToken0 ? token1 : token0;

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        uint256 swapAmt = _calcSwapAmount(net, isToken0, tickLower, tickUpper, currentTick);

        uint256 amountOther;
        if (swapAmt > 0) {
            IERC20(tokenIn).approve(router, swapAmt);
            uint256 minOut = swapAmt * (BPS_BASE - slippageBps) / BPS_BASE;
            amountOther = IShidoDEXRouter(router).exactInputSingle(
                IShidoDEXRouter.ExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: tokenOut, fee: poolFee,
                    recipient: address(this), amountIn: swapAmt,
                    amountOutMinimum: minOut, sqrtPriceLimitX96: 0
                })
            );
            IERC20(tokenIn).approve(router, 0);
        }

        uint256 amount0 = isToken0 ? (net - swapAmt) : amountOther;
        uint256 amount1 = isToken0 ? amountOther : (net - swapAmt);

        if (amount0 > 0) IERC20(token0).approve(positionManager, amount0);
        if (amount1 > 0) IERC20(token1).approve(positionManager, amount1);

        uint256 used0;
        uint256 used1;
        (tokenId, liquidity, used0, used1) = INonfungiblePositionManager(positionManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0, token1: token1, fee: poolFee,
                tickLower: tickLower, tickUpper: tickUpper,
                amount0Desired: amount0, amount1Desired: amount1,
                amount0Min: 0, amount1Min: 0,
                recipient: recipient,
                deadline: block.timestamp + 1200
            })
        );
        IERC20(token0).approve(positionManager, 0);
        IERC20(token1).approve(positionManager, 0);

        // Dust refund
        uint256 d0 = amount0 > used0 ? amount0 - used0 : 0;
        uint256 d1 = amount1 > used1 ? amount1 - used1 : 0;
        if (d0 > 1) IERC20(token0).transfer(recipient, d0);
        if (d1 > 1) IERC20(token1).transfer(recipient, d1);
    }

    // Rebalance two tokens to correct ratio for a tick range
    // Returns the adjusted amounts ready for mint/increaseLiquidity
    function _rebalanceForRange(
        address token0, uint256 amt0,
        address token1, uint256 amt1,
        uint24  fee,
        int24   tickLower, int24 tickUpper,
        int24   currentTick,
        uint256 slippageBps
    ) internal returns (uint256 out0, uint256 out1) {
        out0 = amt0;
        out1 = amt1;

        if (currentTick <= tickLower) {
            // All token0 needed — swap all token1 to token0
            if (amt1 > 0) {
                IERC20(token1).approve(router, amt1);
                out0 += IShidoDEXRouter(router).exactInputSingle(
                    IShidoDEXRouter.ExactInputSingleParams({
                        tokenIn: token1, tokenOut: token0, fee: fee,
                        recipient: address(this), amountIn: amt1,
                        amountOutMinimum: amt1 * (BPS_BASE - slippageBps) / BPS_BASE,
                        sqrtPriceLimitX96: 0
                    })
                );
                IERC20(token1).approve(router, 0);
                out1 = 0;
            }
            return (out0, out1);
        }

        if (currentTick >= tickUpper) {
            // All token1 needed — swap all token0 to token1
            if (amt0 > 0) {
                IERC20(token0).approve(router, amt0);
                out1 += IShidoDEXRouter(router).exactInputSingle(
                    IShidoDEXRouter.ExactInputSingleParams({
                        tokenIn: token0, tokenOut: token1, fee: fee,
                        recipient: address(this), amountIn: amt0,
                        amountOutMinimum: amt0 * (BPS_BASE - slippageBps) / BPS_BASE,
                        sqrtPriceLimitX96: 0
                    })
                );
                IERC20(token0).approve(router, 0);
                out0 = 0;
            }
            return (out0, out1);
        }

        // Price in range — swap to correct ratio using tick position fraction
        int24 rangeW = tickUpper - tickLower;
        uint256 t1Frac = uint256(uint24(currentTick - tickLower)) * BPS_BASE / uint256(uint24(rangeW));

        // Total value in token0 terms (rough)
        // We need t1Frac fraction of total as token1 and (1-t1Frac) as token0
        if (amt0 > 0) {
            uint256 swapAmt = (amt0 * t1Frac) / (BPS_BASE + t1Frac);
            if (swapAmt > 0 && swapAmt < amt0) {
                IERC20(token0).approve(router, swapAmt);
                uint256 got1 = IShidoDEXRouter(router).exactInputSingle(
                    IShidoDEXRouter.ExactInputSingleParams({
                        tokenIn: token0, tokenOut: token1, fee: fee,
                        recipient: address(this), amountIn: swapAmt,
                        amountOutMinimum: swapAmt * (BPS_BASE - slippageBps) / BPS_BASE,
                        sqrtPriceLimitX96: 0
                    })
                );
                IERC20(token0).approve(router, 0);
                out0 -= swapAmt;
                out1 += got1;
            }
        }
    }

    function _calcSwapAmount(
        uint256 amountIn,
        bool isToken0,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick
    ) internal pure returns (uint256) {
        if (isToken0) {
            if (currentTick <= tickLower) return 0;    // all token0 needed
            if (currentTick >= tickUpper) return amountIn / 2; // all token1 needed - convert all
            int24 rangeW = tickUpper - tickLower;
            uint256 t1Frac = uint256(uint24(currentTick - tickLower)) * BPS_BASE / uint256(uint24(rangeW));
            return (amountIn * t1Frac) / (BPS_BASE + t1Frac);
        } else {
            if (currentTick >= tickUpper) return 0;    // all token1 needed
            if (currentTick <= tickLower) return amountIn / 2; // all token0 needed
            int24 rangeW = tickUpper - tickLower;
            uint256 t0Frac = BPS_BASE - (uint256(uint24(currentTick - tickLower)) * BPS_BASE / uint256(uint24(rangeW)));
            return (amountIn * t0Frac) / (BPS_BASE + t0Frac);
        }
    }

    function _withdrawPosition(uint256 tokenId, uint128 liquidity) internal {
        bytes[] memory calls = new bytes[](liquidity > 0 ? 3 : 2);
        uint256 ci = 0;
        if (liquidity > 0) {
            calls[ci++] = abi.encodeWithSelector(
                INonfungiblePositionManager.decreaseLiquidity.selector,
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liquidity,
                    amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 300
                })
            );
        }
        calls[ci++] = abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector,
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this),
                amount0Max: MAX_UINT128, amount1Max: MAX_UINT128
            })
        );
        calls[ci] = abi.encodeWithSelector(INonfungiblePositionManager.burn.selector, tokenId);
        INonfungiblePositionManager(positionManager).multicall(calls);
    }

    function _takeFee(address token, uint256 amount) internal returns (uint256 fee) {
        fee = (amount * feeBps) / BPS_BASE;
        if (fee > 0) IERC20(token).transfer(feeRecipient, fee);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function previewZapIn(
        address tokenIn, uint256 amountIn,
        address token0, address token1, uint24 poolFee,
        int24 tickLower, int24 tickUpper
    ) external view returns (uint256 platformFee, uint256 netAmount, uint256 swapAmount) {
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, poolFee);
        require(pool != address(0), "ZAP: Pool not found");
        platformFee = (amountIn * feeBps) / BPS_BASE;
        netAmount   = amountIn - platformFee;
        (, int24 tick, , , , , ) = IUniswapV3Pool(pool).slot0();
        bool isToken0 = (tokenIn == token0);
        swapAmount = _calcSwapAmount(netAmount, isToken0, tickLower, tickUpper, tick);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setFeeBps(uint256 _bps) external onlyOwner { require(_bps <= MAX_FEE); feeBps = _bps; }
    function setKeeperRewardBps(uint256 _bps) external onlyOwner { require(_bps <= 50); keeperRewardBps = _bps; }
    function setFeeRecipient(address r) external onlyOwner { require(r != address(0)); feeRecipient = r; }
    function setAuthorizedCaller(address c, bool a) external onlyOwner { authorizedCallers[c] = a; }
    function setPaused(bool _p) external onlyOwner { paused = _p; }
    function transferOwnership(address n) external onlyOwner { require(n != address(0)); owner = n; }
    function rescueTokens(address t, uint256 a) external onlyOwner { IERC20(t).transfer(owner, a); }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    receive() external payable {}
}
