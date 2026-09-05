// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherRangeManager.sol v2.0
//
// Automated LP position rebalancing with user-funded gas deposits.
//
// PROBLEM: LP positions stop earning fees when price moves out of range.
// SOLUTION: Register your position, deposit SHIDO for gas, and keepers
//           automatically re-center your position when needed.
//
// GAS DEPOSIT SYSTEM:
//   Users deposit SHIDO when registering. Each rerange costs `rerangeCostWei`
//   SHIDO deducted from their balance. The SHIDO goes to the keeper (caller)
//   as execution reward. Platform never executes on its own expense.
//
//   rerangeCostWei default: 1000 SHIDO
//     - Covers bot gas cost (~800 SHIDO) + 200 SHIDO keeper profit
//     - User sees: "1000 SHIDO per rerange" = how many times they can rebalance
//     - 5000 SHIDO deposit = 5 reranges funded
//
//   Users can top up anytime with depositGas(tokenId).
//   Users recover remaining balance with withdrawGas(tokenId) on unregister.
//
// PLATFORM FEE:
//   0.1% of position tokens taken on each rerange.
//   Goes to feeRecipient (AetherRevenueDistributor).
//   Separate from the SHIDO keeper reward.
//
// REBALANCING:
//   Uses AetherZap.zapInFromBoth() for the actual token swap + mint.
//   AetherZap handles the optimal ratio calculation and LP minting.
//   AetherZap does NOT take its own fee during authorized RangeManager calls
//   (callerHasTokens=true path). Platform fee is taken here instead.
//
// TWAP PROTECTION:
//   Before reranging, checks spot price vs 30s TWAP.
//   If deviation > maxTwapDeviation (3% default), reverts.
//   Prevents reranging during flash loan price manipulation.
//
// KEEPER FLOW:
//   1. Call needsRerange(tokenId) to find positions that need rebalancing
//   2. Call rerange(tokenId) — earns SHIDO from position's gas deposit
//   3. Position owner gets new NFT centered at current price
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function tickSpacing() external view returns (int24);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
}

interface INonfungiblePositionManager {
    struct DecreaseLiquidityParams {
        uint256 tokenId; uint128 liquidity;
        uint256 amount0Min; uint256 amount1Min; uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId; address recipient;
        uint128 amount0Max; uint128 amount1Max;
    }
    function positions(uint256) external view returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function ownerOf(uint256) external view returns (address);
    function isApprovedForAll(address, address) external view returns (bool);
    function safeTransferFrom(address, address, uint256) external;
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    function burn(uint256) external payable;
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
}

// AetherZap integration
interface IAetherZap {
    function zapInFromBoth(
        address token0, uint256 amount0,
        address token1, uint256 amount1,
        uint24 poolFee, int24 tickLower, int24 tickUpper,
        uint256 slippageBps, address recipient,
        bool callerHasTokens
    ) external returns (uint256 tokenId, uint128 liquidity);
}

contract AetherRangeManager {

    uint128 private constant MAX_UINT128 = type(uint128).max;
    uint256 public constant BPS_BASE     = 10000;

    // ─── Addresses ────────────────────────────────────────────────────────────

    address public immutable factory;
    address public immutable positionManager;
    address public zapContract;           // AetherZap — updatable in case of upgrade

    // ─── Fee + Gas Config ─────────────────────────────────────────────────────

    // SHIDO cost per rerange — deducted from user's gas deposit, sent to keeper
    // Default: 1000 SHIDO (covers ~800 SHIDO gas + 200 keeper profit)
    uint256 public rerangeCostWei = 1000 * 10**18;

    // Platform fee on each rerange (taken from position tokens, not SHIDO)
    uint256 public platformFeeBps       = 10;   // 0.1%
    uint256 public constant MAX_FEE_BPS = 100;  // 1% hard cap

    address public feeRecipient;   // AetherRevenueDistributor
    address public owner;
    bool    public paused;
    uint256 private _lock;

    // TWAP manipulation protection
    uint32  public twapWindow       = 30;   // seconds
    uint256 public maxTwapDeviation = 300;  // 3% in BPS (each tick ~ 0.01% = 1 BPS)

    // ─── Gas Deposits ─────────────────────────────────────────────────────────

    // tokenId => SHIDO balance deposited by user for gas
    mapping(uint256 => uint256) public gasDeposits;

    // ─── Registration ─────────────────────────────────────────────────────────

    enum Strategy { FIXED_WIDTH, FOLLOW_PRICE }

    struct Registration {
        address  owner;
        Strategy strategy;
        int24    rangeWidth;    // total tick range for new positions
        uint256  slippageBps;  // max slippage on rebalance swaps
        bool     active;
        uint256  rerangeCount;
        uint256  lastRerangeAt;
    }

    mapping(uint256 => Registration) public registrations;
    mapping(address => uint256[])    public userPositions;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Registered(uint256 indexed tokenId, address indexed owner, Strategy strategy, int24 rangeWidth, uint256 gasDeposited);
    event Unregistered(uint256 indexed tokenId, address indexed owner, uint256 gasRefunded);
    event GasDeposited(uint256 indexed tokenId, address indexed depositor, uint256 amount, uint256 newBalance, uint256 rerangesAvailable);
    event GasWithdrawn(uint256 indexed tokenId, address indexed owner, uint256 amount);
    event Reranged(uint256 indexed oldTokenId, uint256 indexed newTokenId, address indexed keeper, int24 newTickLower, int24 newTickUpper, uint256 keeperRewardShido, uint256 platformFee0, uint256 platformFee1);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner()    { require(msg.sender == owner, "RM: Not owner"); _; }
    modifier nonReentrant() { require(_lock == 0, "RM: Reentrant"); _lock = 1; _; _lock = 0; }

    constructor(address _factory, address _positionManager, address _zapContract, address _feeRecipient) {
        factory         = _factory;
        positionManager = _positionManager;
        zapContract     = _zapContract;
        feeRecipient    = _feeRecipient;
        owner           = msg.sender;
    }

    // ════════════════════════════════════════════════════════════════════════
    // REGISTER — opt into auto-rebalancing
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Register an LP position and deposit SHIDO gas budget.
     *
     * Prerequisites:
     *   positionManager.setApprovalForAll(AetherRangeManager, true)
     *
     * The SHIDO sent with this call funds future reranges.
     * Each rerange costs rerangeCostWei SHIDO.
     * Example: send 5000e18 SHIDO = 5 reranges funded.
     *
     * @param tokenId    LP position NFT ID
     * @param strategy   FIXED_WIDTH or FOLLOW_PRICE
     * @param rangeWidth Total tick range for rebalanced positions
     *                   (e.g. 120 for fee=3000 = ±1 tick spacing from center)
     * @param slippageBps Slippage tolerance on rebalance swaps
     */
    function register(
        uint256  tokenId,
        Strategy strategy,
        int24    rangeWidth,
        uint256  slippageBps
    ) external payable {
        require(!paused, "RM: Paused");
        require(INonfungiblePositionManager(positionManager).ownerOf(tokenId) == msg.sender, "RM: Not your position");
        require(INonfungiblePositionManager(positionManager).isApprovedForAll(msg.sender, address(this)), "RM: Need setApprovalForAll");
        require(rangeWidth > 0,       "RM: Zero range width");
        require(slippageBps <= 500,   "RM: Slippage too high");
        require(!registrations[tokenId].active, "RM: Already registered");
        require(msg.value >= rerangeCostWei, "RM: Deposit at least 1 rerange cost");

        registrations[tokenId] = Registration({
            owner:         msg.sender,
            strategy:      strategy,
            rangeWidth:    rangeWidth,
            slippageBps:   slippageBps,
            active:        true,
            rerangeCount:  0,
            lastRerangeAt: 0
        });
        gasDeposits[tokenId] = msg.value;
        userPositions[msg.sender].push(tokenId);

        uint256 rerangesAvailable = msg.value / rerangeCostWei;
        emit Registered(tokenId, msg.sender, strategy, rangeWidth, msg.value);
        emit GasDeposited(tokenId, msg.sender, msg.value, msg.value, rerangesAvailable);
    }

    /**
     * @notice Add more SHIDO gas budget to an existing registration.
     * Call this to fund additional reranges when balance runs low.
     */
    function depositGas(uint256 tokenId) external payable {
        require(registrations[tokenId].active, "RM: Not registered");
        require(msg.value > 0, "RM: Zero deposit");

        gasDeposits[tokenId] += msg.value;
        uint256 rerangesAvailable = gasDeposits[tokenId] / rerangeCostWei;
        emit GasDeposited(tokenId, msg.sender, msg.value, gasDeposits[tokenId], rerangesAvailable);
    }

    /**
     * @notice Unregister and recover remaining gas deposit.
     */
    function unregister(uint256 tokenId) external nonReentrant {
        require(registrations[tokenId].owner == msg.sender, "RM: Not registered owner");
        require(registrations[tokenId].active, "RM: Not active");

        uint256 refund = gasDeposits[tokenId];
        gasDeposits[tokenId] = 0;
        registrations[tokenId].active = false;

        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            require(ok, "RM: Refund failed");
        }
        emit Unregistered(tokenId, msg.sender, refund);
    }

    // ════════════════════════════════════════════════════════════════════════
    // RERANGE — permissionless keeper function
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Rebalance an out-of-range position to a new centered range.
     *
     * Caller (keeper) earns rerangeCostWei SHIDO from the position's gas deposit.
     * Platform takes platformFeeBps of position tokens as revenue.
     * Position owner gets new NFT at the current price.
     *
     * Reverts if:
     *   - Position is still in range
     *   - Gas deposit is insufficient
     *   - Price is being manipulated (TWAP check)
     */
    function rerange(uint256 tokenId) external nonReentrant returns (uint256 newTokenId) {
        require(!paused, "RM: Paused");
        Registration storage reg = registrations[tokenId];
        require(reg.active, "RM: Not registered");
        require(gasDeposits[tokenId] >= rerangeCostWei, "RM: Insufficient gas deposit - call depositGas()");

        // Read position state
        (, , address token0, address token1, uint24 fee,
           int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) =
            INonfungiblePositionManager(positionManager).positions(tokenId);

        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        require(pool != address(0), "RM: Pool not found");

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();

        // Must be out of range to rebalance
        require(currentTick < tickLower || currentTick >= tickUpper, "RM: Position still in range");

        // TWAP check — prevent manipulation
        _checkTwap(pool, currentTick);

        // Calculate new tick range centered on current price
        int24 spacing     = IUniswapV3Pool(pool).tickSpacing();
        int24 halfWidth   = reg.rangeWidth / 2;
        int24 newTickLower = _snapTick(currentTick - halfWidth, spacing);
        int24 newTickUpper = _snapTick(currentTick + halfWidth, spacing);
        if (newTickLower >= newTickUpper) newTickUpper = newTickLower + spacing;

        // Pull NFT from owner
        address posOwner = reg.owner;
        INonfungiblePositionManager(positionManager).safeTransferFrom(posOwner, address(this), tokenId);

        // Remove all liquidity + collect (includes accumulated pool fees)
        uint256 bal0Before = IERC20(token0).balanceOf(address(this));
        uint256 bal1Before = IERC20(token1).balanceOf(address(this));

        {
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

        uint256 got0 = IERC20(token0).balanceOf(address(this)) - bal0Before;
        uint256 got1 = IERC20(token1).balanceOf(address(this)) - bal1Before;

        // Platform fee on position tokens (0.1%)
        uint256 fee0 = (got0 * platformFeeBps) / BPS_BASE;
        uint256 fee1 = (got1 * platformFeeBps) / BPS_BASE;
        if (fee0 > 0) { IERC20(token0).transfer(feeRecipient, fee0); got0 -= fee0; }
        if (fee1 > 0) { IERC20(token1).transfer(feeRecipient, fee1); got1 -= fee1; }

        // Deduct keeper SHIDO reward and send to caller
        gasDeposits[tokenId] -= rerangeCostWei;
        (bool ok,) = payable(msg.sender).call{value: rerangeCostWei}("");
        require(ok, "RM: Keeper reward failed");

        // Transfer both tokens to AetherZap for optimal reminting
        // callerHasTokens=true: we are authorized caller, tokens going to Zap
        IERC20(token0).approve(zapContract, got0);
        IERC20(token1).approve(zapContract, got1);

        (newTokenId, ) = IAetherZap(zapContract).zapInFromBoth(
            token0, got0,
            token1, got1,
            fee,
            newTickLower,
            newTickUpper,
            reg.slippageBps,
            posOwner,   // new NFT goes directly to original position owner
            true        // callerHasTokens — we already approved Zap for our tokens
        );

        IERC20(token0).approve(zapContract, 0);
        IERC20(token1).approve(zapContract, 0);

        // Update registration state
        reg.rerangeCount++;
        reg.lastRerangeAt = block.timestamp;
        reg.active = false;

        // Auto-register new tokenId with the same settings
        // gasDeposits[tokenId] still holds any remaining balance — transfer to new tokenId
        uint256 remainingGas = gasDeposits[tokenId];
        gasDeposits[tokenId] = 0;
        gasDeposits[newTokenId] = remainingGas;

        registrations[newTokenId] = Registration({
            owner:         posOwner,
            strategy:      reg.strategy,
            rangeWidth:    reg.rangeWidth,
            slippageBps:   reg.slippageBps,
            active:        true,
            rerangeCount:  reg.rerangeCount,
            lastRerangeAt: block.timestamp
        });
        userPositions[posOwner].push(newTokenId);

        emit Reranged(tokenId, newTokenId, msg.sender, newTickLower, newTickUpper, rerangeCostWei, fee0, fee1);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _checkTwap(address pool, int24 currentTick) internal view {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        try IUniswapV3Pool(pool).observe(secondsAgos) returns (int56[] memory ticks, uint160[] memory) {
            int24 twapTick = int24((ticks[1] - ticks[0]) / int56(uint56(twapWindow)));
            int24 diff     = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
            require(uint256(uint24(diff)) <= maxTwapDeviation, "RM: Price manipulated - TWAP check failed");
        } catch {} // new pool with insufficient TWAP history - skip
    }

    function _snapTick(int24 tick, int24 spacing) internal pure returns (int24) {
        if (spacing <= 0) return tick;
        int24 rounded = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) rounded -= spacing;
        return rounded;
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getRegistration(uint256 tokenId) external view returns (Registration memory) {
        return registrations[tokenId];
    }

    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    /**
     * @notice Check if a position needs reranging and how many reranges remain.
     */
    function needsRerange(uint256 tokenId) external view returns (
        bool   outOfRange,
        bool   hasFunds,
        uint256 rerangesRemaining,
        int24  currentTick,
        int24  tickLower,
        int24  tickUpper
    ) {
        if (!registrations[tokenId].active) return (false, false, 0, 0, 0, 0);

        (, , address token0, address token1, uint24 fee,
           int24 tl, int24 tu, , , , , ) =
            INonfungiblePositionManager(positionManager).positions(tokenId);

        tickLower = tl;
        tickUpper = tu;
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        if (pool == address(0)) return (false, false, 0, 0, tl, tu);

        (, currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        outOfRange        = currentTick < tl || currentTick >= tu;
        hasFunds          = gasDeposits[tokenId] >= rerangeCostWei;
        rerangesRemaining = gasDeposits[tokenId] / rerangeCostWei;
    }

    /**
     * @notice Preview cost of registration.
     * @return costPerRerange SHIDO per rerange
     * @return minDeposit     Minimum SHIDO to register (1 rerange)
     */
    function getRegistrationCost() external view returns (
        uint256 costPerRerange,
        uint256 minDeposit,
        uint256 platformFeePercent
    ) {
        costPerRerange     = rerangeCostWei;
        minDeposit         = rerangeCostWei;
        platformFeePercent = platformFeeBps; // in BPS: 10 = 0.1%
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setRerangeCost(uint256 _wei) external onlyOwner {
        require(_wei >= 100 * 10**18, "RM: Too low"); // min 100 SHIDO
        rerangeCostWei = _wei;
    }

    function setPlatformFee(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "RM: Fee too high");
        platformFeeBps = _bps;
    }

    function setZapContract(address _zap) external onlyOwner {
        require(_zap != address(0));
        zapContract = _zap;
    }

    function setFeeRecipient(address r) external onlyOwner { require(r != address(0)); feeRecipient = r; }
    function setTwapWindow(uint32 w) external onlyOwner { require(w >= 10); twapWindow = w; }
    function setMaxTwapDeviation(uint256 d) external onlyOwner { maxTwapDeviation = d; }
    function setPaused(bool _p) external onlyOwner { paused = _p; }
    function transferOwnership(address n) external onlyOwner { require(n != address(0)); owner = n; }
    function rescueTokens(address t, uint256 a) external onlyOwner { IERC20(t).transfer(owner, a); }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
