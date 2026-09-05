// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// WhaleLimitOrders.sol v1.0
//
// MECHANICS: True V3 range orders — contract mints single-sided liquidity
// via Position Manager. DEX traders passively fill the order as price moves
// through the tick range. Zero slippage, zero price impact on creation.
//
// HOW FILL WORKS:
//   zeroForOne (selling token0): range placed ABOVE current tick.
//     → Filled when currentTick >= tickUpper (price rose past range).
//   oneForZero (selling token1): range placed BELOW current tick.
//     → Filled when currentTick < tickLower (price fell past range).
//
// TARGET: Large orders $1,000+. Admin sets per-token minimum amounts.
//
// GAS COST: ~800 SHIDO for claim (PM multicall: decreaseLiquidity+collect+burn).
// Bot fee (1000 SHIDO default) covers this with 1.25x buffer.
//
// NFT OWNERSHIP: Contract holds NFT (minted with recipient=address(this)).
// User cannot transfer/sell position — it's locked until filled or cancelled.
// This is intentional: prevents order manipulation.
//
// REVENUE: Taken from tokenOut at claim time (not input). On cancel/expiry:
// both tokens returned to user, no revenue fee.
//
// MULTICALL: Uses Position Manager's own multicall() for atomic withdrawal.
//
// PM NOTE: Position Manager MintParams and DecreaseLiquidityParams DO have
// deadline. collect() does NOT have deadline.
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool
    );
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function mint(MintParams calldata params) external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external payable
        returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external payable
        returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator,
        address token0, address token1,
        uint24 fee, int24 tickLower, int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
}

contract WhaleLimitOrders {

    // ─── Protocol Addresses ───────────────────────────────────────────────────

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory           public immutable factory;

    uint128 private constant MAX_UINT128 = type(uint128).max;

    // ─── Fee Config ───────────────────────────────────────────────────────────

    uint256 public botFeeWei  = 1000 * 10**18; // 1000 SHIDO (covers ~800 SHIDO PM multicall)
    uint256 public revenueBps = 30;             // 0.3% of tokenOut received at claim
    uint256 public constant MAX_REVENUE_BPS = 200;
    uint256 public constant MIN_BOT_FEE_WEI = 100 * 10**18;
    uint256 public constant MAX_BOT_FEE_WEI = 10000 * 10**18;
    uint256 public constant BPS_BASE        = 10000;

    address public owner;
    address public bot;
    address public botFeeRecipient;
    address public revenueRecipient;

    mapping(address => bool)    public authorizedRouters;
    mapping(address => uint256) public minWhaleAmount; // per-token minimum (raw decimals)

    bool    public paused;
    uint256 private _lock;

    // ─── Whale Order ──────────────────────────────────────────────────────────

    enum OrderStatus { Open, Filled, Cancelled, Expired }

    struct WhaleOrder {
        uint256     tokenId;        // PM NFT ID (held by this contract)
        address     owner;          // user who created the order
        address     token0;         // sorted token0 (lower address)
        address     token1;         // sorted token1
        address     tokenIn;        // token the user deposited
        address     tokenOut;       // token the user wants back
        uint24      fee;            // pool fee tier
        int24       tickLower;
        int24       tickUpper;
        uint128     initialLiquidity; // liquidity minted (for reference)
        uint256     amountDeposited;  // actual tokenIn received after fee-on-transfer
        OrderStatus status;
        uint64      createdAt;
        uint64      deadline;
    }

    // tokenId → WhaleOrder
    mapping(uint256 => WhaleOrder)  public orders;
    // user → list of tokenIds
    mapping(address => uint256[])   public userOrders;

    uint256 public totalOrdersCreated;

    // ─── Events ───────────────────────────────────────────────────────────────

    event WhaleOrderCreated(
        uint256 indexed tokenId, address indexed owner,
        address tokenIn, address tokenOut,
        uint256 amountDeposited, uint128 liquidity,
        int24 tickLower, int24 tickUpper,
        uint24 fee, uint64 deadline
    );
    event WhaleOrderClaimed(
        uint256 indexed tokenId, address indexed owner,
        uint256 tokenOutAmount, uint256 revenueFee,
        uint256 tokenInRefund   // non-zero if partially filled
    );
    event WhaleOrderCancelled(
        uint256 indexed tokenId, address indexed owner,
        uint256 tokenInRefund, uint256 tokenOutRefund
    );
    event WhaleOrderExpired(uint256 indexed tokenId);
    event MinWhaleAmountSet(address indexed token, uint256 minAmount);
    event RouterAuthorized(address indexed router, bool authorized);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner()     { require(msg.sender == owner, "WO: Not owner"); _; }
    modifier onlyBot()       { require(msg.sender == bot,   "WO: Not bot");   _; }
    modifier nonReentrant()  { require(_lock == 0, "WO: Reentrant"); _lock = 1; _; _lock = 0; }
    modifier whenNotPaused() { require(!paused, "WO: Paused"); _; }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _positionManager,
        address _factory,
        address _bot,
        address _botFeeRecipient,
        address _revenueRecipient,
        uint256 _botFeeWei,
        uint256 _revenueBps
    ) {
        require(_revenueBps <= MAX_REVENUE_BPS, "WO: Revenue BPS > 2%");
        require(_botFeeWei >= MIN_BOT_FEE_WEI,  "WO: Bot fee < 100 SHIDO");
        positionManager  = INonfungiblePositionManager(_positionManager);
        factory          = IUniswapV3Factory(_factory);
        owner            = msg.sender;
        bot              = _bot;
        botFeeRecipient  = _botFeeRecipient;
        revenueRecipient = _revenueRecipient;
        botFeeWei        = _botFeeWei;
        revenueBps       = _revenueBps;
    }

    // ─── createWhaleOrder (direct user call) ──────────────────────────────────

    function createWhaleOrder(
        address tokenIn,    // token to sell
        address tokenOut,   // token to receive when filled
        uint256 amountIn,   // gross amount of tokenIn to deposit
        uint24  poolFee,    // 500, 3000, or 10000
        int24   tickLower,  // computed by frontend (utils/defi.ts nearestUsableTick)
        int24   tickUpper,  // computed by frontend
        uint64  deadline    // order expiry unix timestamp
    ) external payable nonReentrant whenNotPaused returns (uint256 tokenId) {
        return _createWhaleOrder(msg.sender, msg.sender, tokenIn, tokenOut, amountIn, poolFee, tickLower, tickUpper, deadline);
    }

    // ─── createWhaleOrderFor (router call — preserves original user as owner) ─

    function createWhaleOrderFor(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper,
        uint64  deadline
    ) external payable nonReentrant whenNotPaused returns (uint256 tokenId) {
        require(authorizedRouters[msg.sender], "WO: Not authorized router");
        return _createWhaleOrder(user, msg.sender, tokenIn, tokenOut, amountIn, poolFee, tickLower, tickUpper, deadline);
    }

    function _createWhaleOrder(
        address user,
        address payer,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper,
        uint64  deadline
    ) internal returns (uint256 tokenId) {
        // ── Validate ──────────────────────────────────────────────────────────
        require(tokenIn != address(0) && tokenOut != address(0), "WO: Zero addr");
        require(tokenIn != tokenOut,       "WO: Same token");
        require(amountIn > 0,              "WO: Zero amount");
        require(tickLower < tickUpper,     "WO: Invalid tick range");
        require(deadline > block.timestamp,"WO: Deadline passed");
        require(msg.value >= botFeeWei,    "WO: Bot fee insufficient");

        // ── Size check ────────────────────────────────────────────────────────
        uint256 minAmt = minWhaleAmount[tokenIn];
        if (minAmt > 0) require(amountIn >= minAmt, "WO: Below whale minimum");

        // ── Sort tokens (PM requires token0 < token1 by address) ─────────────
        bool isSorted = uint160(tokenIn) < uint160(tokenOut);
        address token0 = isSorted ? tokenIn : tokenOut;
        address token1 = isSorted ? tokenOut : tokenIn;

        // ── Validate pool + tick placement ────────────────────────────────────
        address poolAddr = factory.getPool(token0, token1, poolFee);
        require(poolAddr != address(0), "WO: Pool not found");
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(poolAddr).slot0();

        if (isSorted) {
            // Selling token0 (zeroForOne): range must be ABOVE current tick
            // Fill detected when: currentTick >= tickUpper
            require(currentTick < tickLower, "WO: Price at or above target - use market swap");
        } else {
            // Selling token1 (oneForZero): range must be BELOW current tick
            // Fill detected when: currentTick < tickLower
            require(currentTick > tickUpper, "WO: Price at or below target - use market swap");
        }

        // ── Pull tokenIn from user ────────────────────────────────────────────
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(payer, address(this), amountIn), "WO: Token pull failed");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;
        require(received > 0, "WO: No tokens received");

        // ── Approve PM ────────────────────────────────────────────────────────
        IERC20(tokenIn).approve(address(positionManager), received);

        // ── Mint single-sided LP position ─────────────────────────────────────
        // Contract is recipient — we hold the NFT
        (uint256 mintedId, uint128 liquidity, uint256 used0, uint256 used1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0:         token0,
                token1:         token1,
                fee:            poolFee,
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                amount0Desired: isSorted ? received : 0,
                amount1Desired: isSorted ? 0 : received,
                amount0Min:     0,
                amount1Min:     0,
                recipient:      address(this), // CONTRACT holds the NFT
                deadline:       block.timestamp + 1200
            })
        );
        tokenId = mintedId;

        // ── Revoke approval ───────────────────────────────────────────────────
        IERC20(tokenIn).approve(address(positionManager), 0);

        // ── Refund any unused tokenIn (PM may use less than requested) ─────────
        uint256 usedAmount = isSorted ? used0 : used1;
        uint256 unused = received - usedAmount;
        if (unused > 0) {
            IERC20(tokenIn).transfer(user, unused);
            received = usedAmount;
        }

        require(liquidity > 0, "WO: Zero liquidity minted");

        // ── Store order ───────────────────────────────────────────────────────
        orders[tokenId] = WhaleOrder({
            tokenId:          tokenId,
            owner:            user,
            token0:           token0,
            token1:           token1,
            tokenIn:          tokenIn,
            tokenOut:         tokenOut,
            fee:              poolFee,
            tickLower:        tickLower,
            tickUpper:        tickUpper,
            initialLiquidity: liquidity,
            amountDeposited:  received,
            status:           OrderStatus.Open,
            createdAt:        uint64(block.timestamp),
            deadline:         deadline
        });
        userOrders[user].push(tokenId);
        totalOrdersCreated++;

        // ── Forward bot fee to bot wallet ─────────────────────────────────────
        (bool ok,) = payable(botFeeRecipient).call{value: msg.value}("");
        require(ok, "WO: Bot fee send failed");

        emit WhaleOrderCreated(tokenId, user, tokenIn, tokenOut, received, liquidity, tickLower, tickUpper, poolFee, deadline);
    }

    // ─── claimOrder (bot or user) ─────────────────────────────────────────────
    //
    // Called when the price has moved through the tick range (order filled).
    // Removes all liquidity, collects tokens, deducts revenue fee, sends to owner.
    // Also handles partial fills: sends whatever tokenOut is there, refunds tokenIn.
    // Handles expiry: full refund, no revenue fee.

    function claimOrder(uint256 tokenId) external nonReentrant {
        WhaleOrder storage o = orders[tokenId];
        require(o.tokenId != 0,          "WO: Order not found");
        require(o.status == OrderStatus.Open, "WO: Not open");
        require(msg.sender == bot || msg.sender == o.owner, "WO: Not authorized");

        // ── Handle expiry: full refund, no revenue ────────────────────────────
        if (block.timestamp > o.deadline) {
            uint256 expiredOutBefore = IERC20(o.tokenOut).balanceOf(address(this));
            uint256 expiredInBefore  = IERC20(o.tokenIn).balanceOf(address(this));
            _withdrawPosition(tokenId, o);
            uint256 expiredOutAmt = IERC20(o.tokenOut).balanceOf(address(this)) - expiredOutBefore;
            uint256 expiredInAmt  = IERC20(o.tokenIn).balanceOf(address(this))  - expiredInBefore;
            if (expiredOutAmt > 0) IERC20(o.tokenOut).transfer(o.owner, expiredOutAmt);
            if (expiredInAmt  > 0) IERC20(o.tokenIn).transfer(o.owner, expiredInAmt);
            o.status = OrderStatus.Expired;
            emit WhaleOrderExpired(tokenId);
            return;
        }

        // ── Normal claim ──────────────────────────────────────────────────────
        uint256 tokenOutBefore = IERC20(o.tokenOut).balanceOf(address(this));
        uint256 tokenInBefore  = IERC20(o.tokenIn).balanceOf(address(this));

        _withdrawPosition(tokenId, o);

        uint256 tokenOutReceived = IERC20(o.tokenOut).balanceOf(address(this)) - tokenOutBefore;
        uint256 tokenInRefund    = IERC20(o.tokenIn).balanceOf(address(this))  - tokenInBefore;

        // ── Revenue fee: only on the converted (tokenOut) amount ──────────────
        uint256 revFee     = (tokenOutReceived * revenueBps) / BPS_BASE;
        uint256 userAmount = tokenOutReceived - revFee;

        if (revFee > 0)    IERC20(o.tokenOut).transfer(revenueRecipient, revFee);
        if (userAmount > 0) IERC20(o.tokenOut).transfer(o.owner, userAmount);
        if (tokenInRefund > 0) IERC20(o.tokenIn).transfer(o.owner, tokenInRefund); // partial fill refund

        o.status = OrderStatus.Filled;
        emit WhaleOrderClaimed(tokenId, o.owner, userAmount, revFee, tokenInRefund);
    }

    // ─── cancelOrder (owner or bot only) ─────────────────────────────────────
    //
    // Full refund: both tokens returned. No revenue fee (order never filled).
    // Bot fee (SHIDO) is non-refundable (covers monitoring costs).

    function cancelOrder(uint256 tokenId) external nonReentrant {
        WhaleOrder storage o = orders[tokenId];
        require(o.tokenId != 0, "WO: Order not found");
        require(msg.sender == o.owner || msg.sender == bot, "WO: Not authorized");
        require(o.status == OrderStatus.Open, "WO: Not cancellable");

        uint256 tokenOutBefore = IERC20(o.tokenOut).balanceOf(address(this));
        uint256 tokenInBefore  = IERC20(o.tokenIn).balanceOf(address(this));

        _withdrawPosition(tokenId, o);

        uint256 tokenOutRefund = IERC20(o.tokenOut).balanceOf(address(this)) - tokenOutBefore;
        uint256 tokenInRefund  = IERC20(o.tokenIn).balanceOf(address(this))  - tokenInBefore;

        // Return EVERYTHING to user — no revenue on cancelled orders
        if (tokenOutRefund > 0) IERC20(o.tokenOut).transfer(o.owner, tokenOutRefund);
        if (tokenInRefund  > 0) IERC20(o.tokenIn).transfer(o.owner, tokenInRefund);

        o.status = OrderStatus.Cancelled;
        emit WhaleOrderCancelled(tokenId, o.owner, tokenInRefund, tokenOutRefund);
    }

    // ─── Internal: PM Multicall Withdrawal ───────────────────────────────────
    //
    // Uses Position Manager's own multicall() for atomic:
    // decreaseLiquidity → collect → burn
    // The contract owns the NFT so it can call these directly.

    function _withdrawPosition(uint256 tokenId, WhaleOrder storage /* o */) internal {
        // Read current on-chain liquidity (may differ from initial if partially filled externally)
        (, , , , , , , uint128 currentLiquidity, , , , ) = positionManager.positions(tokenId);

        bytes[] memory calls;

        if (currentLiquidity > 0) {
            calls = new bytes[](3);
            calls[0] = abi.encodeWithSelector(
                INonfungiblePositionManager.decreaseLiquidity.selector,
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId:    tokenId,
                    liquidity:  currentLiquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline:   block.timestamp + 300
                })
            );
            calls[1] = abi.encodeWithSelector(
                INonfungiblePositionManager.collect.selector,
                INonfungiblePositionManager.CollectParams({
                    tokenId:    tokenId,
                    recipient:  address(this),
                    amount0Max: MAX_UINT128,
                    amount1Max: MAX_UINT128
                })
            );
            calls[2] = abi.encodeWithSelector(
                INonfungiblePositionManager.burn.selector,
                tokenId
            );
        } else {
            // Liquidity already 0 (fully filled by pool mechanics): just collect + burn
            calls = new bytes[](2);
            calls[0] = abi.encodeWithSelector(
                INonfungiblePositionManager.collect.selector,
                INonfungiblePositionManager.CollectParams({
                    tokenId:    tokenId,
                    recipient:  address(this),
                    amount0Max: MAX_UINT128,
                    amount1Max: MAX_UINT128
                })
            );
            calls[1] = abi.encodeWithSelector(
                INonfungiblePositionManager.burn.selector,
                tokenId
            );
        }

        positionManager.multicall(calls);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getOrder(uint256 tokenId) external view returns (WhaleOrder memory) {
        return orders[tokenId];
    }

    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    function getUserOrdersFull(address user) external view returns (WhaleOrder[] memory result) {
        uint256[] memory ids = userOrders[user];
        result = new WhaleOrder[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            result[i] = orders[ids[i]];
        }
    }

    // Check if order is likely filled based on pool's current tick
    // Off-chain usage: bot calls this before executing claimOrder
    function isOrderFilled(uint256 tokenId) external view returns (
        bool filled, bool filling, int24 currentTick, uint128 remainingLiquidity
    ) {
        WhaleOrder storage o = orders[tokenId];
        if (o.tokenId == 0 || o.status != OrderStatus.Open) return (false, false, 0, 0);

        address poolAddr = factory.getPool(o.token0, o.token1, o.fee);
        if (poolAddr == address(0)) return (false, false, 0, 0);

        (, currentTick, , , , , ) = IUniswapV3Pool(poolAddr).slot0();
        (, , , , , , , remainingLiquidity, , , , ) = positionManager.positions(tokenId);

        bool isSorted = o.tokenIn == o.token0; // selling token0
        if (isSorted) {
            filled  = currentTick >= o.tickUpper;
            filling = currentTick > o.tickLower && currentTick < o.tickUpper;
        } else {
            filled  = currentTick < o.tickLower;
            filling = currentTick > o.tickLower && currentTick < o.tickUpper;
        }
    }

    function getFeeQuote(uint256 outputAmount) external view returns (
        uint256 revenueFeeAmount,
        uint256 userReceives,
        uint256 botFeeShido
    ) {
        revenueFeeAmount = (outputAmount * revenueBps) / BPS_BASE;
        userReceives     = outputAmount - revenueFeeAmount;
        botFeeShido      = botFeeWei;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    // Set minimum amount for a token to qualify as a whale order.
    // Example: USDC 6 decimals → setMinWhaleAmount(USDC, 1_000_000_000) = $1,000 min
    // Example: WSHIDO 18 decimals → setMinWhaleAmount(WSHIDO, 5_000_000e18) = 5M SHIDO min
    function setMinWhaleAmount(address token, uint256 minAmount) external onlyOwner {
        minWhaleAmount[token] = minAmount;
        emit MinWhaleAmountSet(token, minAmount);
    }

    function setRouter(address router, bool authorized) external onlyOwner {
        authorizedRouters[router] = authorized;
        emit RouterAuthorized(router, authorized);
    }

    function setBotFee(uint256 _feeWei) external onlyOwner {
        require(_feeWei >= MIN_BOT_FEE_WEI && _feeWei <= MAX_BOT_FEE_WEI, "WO: Fee out of range");
        botFeeWei = _feeWei;
    }

    function setRevenueBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_REVENUE_BPS, "WO: Above 2% cap");
        revenueBps = _bps;
    }

    function setBot(address _bot) external onlyOwner { require(_bot != address(0)); bot = _bot; }
    function setBotFeeRecipient(address r) external onlyOwner { require(r != address(0)); botFeeRecipient = r; }
    function setRevenueRecipient(address r) external onlyOwner { require(r != address(0)); revenueRecipient = r; }
    function setPaused(bool _p) external onlyOwner { paused = _p; }
    function transferOwnership(address n) external onlyOwner { require(n != address(0)); owner = n; }
    function rescueTokens(address t, uint256 a) external onlyOwner { IERC20(t).transfer(owner, a); }
    receive() external payable {}
}
