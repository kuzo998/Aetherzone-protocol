// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// RetailLimitOrders.sol v1.0
//
// MECHANICS: Custodial swapper model — tokens held in contract, bot executes
// via router.exactInputSingle when price target is reached.
//
// TARGET: Small-to-medium orders. Admin sets per-token min/max limits.
// Example: USDC 6 decimals → minAmount=50_000_000 (50), maxAmount=1_000_000_000 (1000)
//
// GAS: Bot pays ~320 SHIDO per execution (4× cheaper than PM approach).
// Bot fee (2000 SHIDO default) is forwarded immediately to bot wallet.
//
// INTERFACE: Compatible with AetherMulticall IAetherLimitOrders (bytes32 ids).
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract RetailLimitOrders {

    // ─── Size Limits (per token) ───────────────────────────────────────────────

    struct TokenLimits {
        uint256 minAmount;   // min tokenIn (in token's raw decimals)
        uint256 maxAmount;   // max tokenIn (in token's raw decimals)
        bool    isEnabled;   // must be explicitly enabled by admin
    }
    mapping(address => TokenLimits) public tokenLimits;

    // ─── Fee Config ───────────────────────────────────────────────────────────

    uint256 public botFeeWei  = 2000 * 10**18;  // 2000 SHIDO flat (bot gas coverage)
    uint256 public revenueBps = 30;              // 0.3% of tokenIn → revenue

    uint256 public constant MAX_REVENUE_BPS = 200;           // hard cap 2%
    uint256 public constant MIN_BOT_FEE_WEI = 100 * 10**18;  // 100 SHIDO floor
    uint256 public constant MAX_BOT_FEE_WEI = 10000 * 10**18;// 10,000 SHIDO ceiling
    uint256 public constant BPS_BASE        = 10000;

    address public owner;
    address public bot;
    address public botFeeRecipient;
    address public revenueRecipient;

    mapping(address => bool) public authorizedRouters; // AetherOrderRouter whitelist

    bool    public paused;
    uint256 private _lock;

    // ─── Orders ───────────────────────────────────────────────────────────────

    enum OrderStatus { Pending, Filled, Cancelled, Expired }

    struct Order {
        bytes32     id;
        address     owner;
        address     tokenIn;
        address     tokenOut;
        uint256     amountGross;      // deposited by user
        uint256     revenueFee;       // 0.3% held for revenue
        uint256     amountIn;         // net = gross - fee (what bot swaps)
        uint256     amountRemaining;
        uint256     minAmountOut;
        uint256     targetPriceX96;
        uint64      deadline;
        uint64      createdAt;
        OrderStatus status;
        uint256     filledAmountOut;
    }

    mapping(bytes32 => Order)     public orders;
    mapping(address => bytes32[]) public userOrders;
    mapping(address => uint256)   public pendingRevenue;

    // ─── Events ───────────────────────────────────────────────────────────────

    event OrderCreated(bytes32 indexed orderId, address indexed owner, address tokenIn, address tokenOut, uint256 grossAmount, uint256 revenueFee, uint256 netAmount, uint256 botFeeWei, uint256 targetPriceX96, uint64 deadline);
    event OrderFilled(bytes32 indexed orderId, address indexed owner, uint256 amountOut);
    event OrderCancelled(bytes32 indexed orderId, address indexed owner, uint256 totalRefund);
    event OrderExpired(bytes32 indexed orderId, uint256 refunded);
    event RevenueCollected(address indexed token, uint256 amount);
    event TokenLimitsSet(address indexed token, uint256 minAmount, uint256 maxAmount);
    event RouterAuthorized(address indexed router, bool authorized);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner()     { require(msg.sender == owner,  "RL: Not owner"); _; }
    modifier onlyBot()       { require(msg.sender == bot,    "RL: Not bot");   _; }
    modifier nonReentrant()  { require(_lock == 0, "RL: Reentrant"); _lock = 1; _; _lock = 0; }
    modifier whenNotPaused() { require(!paused, "RL: Paused"); _; }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _bot,
        address _botFeeRecipient,
        address _revenueRecipient,
        uint256 _botFeeWei,
        uint256 _revenueBps
    ) {
        require(_revenueBps <= MAX_REVENUE_BPS, "RL: Revenue BPS > 2%");
        require(_botFeeWei >= MIN_BOT_FEE_WEI, "RL: Bot fee < 100 SHIDO");
        owner            = msg.sender;
        bot              = _bot;
        botFeeRecipient  = _botFeeRecipient;
        revenueRecipient = _revenueRecipient;
        botFeeWei        = _botFeeWei;
        revenueBps       = _revenueBps;
    }

    // ─── createOrder (direct user call) ──────────────────────────────────────

    function createOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 targetPriceX96,
        uint64  deadline
    ) external payable nonReentrant whenNotPaused returns (bytes32) {
        return _createOrder(msg.sender, msg.sender, tokenIn, tokenOut, amountIn, minAmountOut, targetPriceX96, deadline);
    }

    // ─── createOrderFor (router call — preserves original user as owner) ──────

    function createOrderFor(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 targetPriceX96,
        uint64  deadline
    ) external payable nonReentrant whenNotPaused returns (bytes32) {
        require(authorizedRouters[msg.sender], "RL: Not authorized router");
        return _createOrder(user, msg.sender, tokenIn, tokenOut, amountIn, minAmountOut, targetPriceX96, deadline);
    }

    function _createOrder(
        address user,
        address payer,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 targetPriceX96,
        uint64  deadline
    ) internal returns (bytes32 orderId) {
        // ── Validate token limits ─────────────────────────────────────────────
        TokenLimits storage limits = tokenLimits[tokenIn];
        require(limits.isEnabled,             "RL: Token not supported");
        require(amountIn >= limits.minAmount, "RL: Below minimum order size");
        require(amountIn <= limits.maxAmount, "RL: Exceeds retail max - use Whale Orders");

        // ── Basic validation ──────────────────────────────────────────────────
        require(tokenIn != address(0) && tokenOut != address(0), "RL: Zero addr");
        require(tokenIn != tokenOut,    "RL: Same token");
        require(amountIn > 0,           "RL: Zero amount");
        require(minAmountOut > 0,       "RL: Zero min out");
        require(deadline > block.timestamp, "RL: Deadline passed");
        require(msg.value >= botFeeWei, "RL: Bot fee insufficient");

        // ── Unique order ID ───────────────────────────────────────────────────
        orderId = keccak256(abi.encodePacked(
            user, tokenIn, tokenOut, amountIn, block.timestamp, block.number
        ));
        require(orders[orderId].createdAt == 0, "RL: ID collision");

        // ── Pull tokens (balance delta for fee-on-transfer safety) ────────────
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(payer, address(this), amountIn), "RL: Token pull failed");
        // If router is calling, tokens were already pulled to router then approved to this contract
        uint256 gross = IERC20(tokenIn).balanceOf(address(this)) - before;
        require(gross > 0, "RL: No tokens received");

        // ── Revenue split ─────────────────────────────────────────────────────
        uint256 fee = (gross * revenueBps) / BPS_BASE;
        uint256 net = gross - fee;
        require(net > 0, "RL: Net amount zero");
        pendingRevenue[tokenIn] += fee;

        // ── Store order ───────────────────────────────────────────────────────
        orders[orderId] = Order({
            id:              orderId,
            owner:           user,
            tokenIn:         tokenIn,
            tokenOut:        tokenOut,
            amountGross:     gross,
            revenueFee:      fee,
            amountIn:        net,
            amountRemaining: net,
            minAmountOut:    minAmountOut,
            targetPriceX96:  targetPriceX96,
            deadline:        deadline,
            createdAt:       uint64(block.timestamp),
            status:          OrderStatus.Pending,
            filledAmountOut: 0
        });
        userOrders[user].push(orderId);

        // ── Forward bot fee ───────────────────────────────────────────────────
        (bool ok,) = payable(botFeeRecipient).call{value: msg.value}("");
        require(ok, "RL: Bot fee send failed");

        emit OrderCreated(orderId, user, tokenIn, tokenOut, gross, fee, net, msg.value, targetPriceX96, deadline);
    }

    // ─── Router whitelist ─────────────────────────────────────────────────────
    // Only pre-approved routers can be called by executeOrder.
    // Prevents a compromised bot key from draining orders via a malicious contract.
    // Add ShidoDEX router after deployment: setApprovedRouter(SWAP_ROUTER_V2, true)

    mapping(address => bool) public approvedRouters;

    function setApprovedRouter(address router, bool approved) external onlyOwner {
        approvedRouters[router] = approved;
    }

    // ─── executeOrder (bot only) ──────────────────────────────────────────────
    //
    // swapData: ABI-encoded exactInputSingle params for ShidoDEX router.
    // CRITICAL: ShidoDEX router has NO deadline field in exactInputSingle.
    // Verified from Frontend/services/abis.ts SWAP_ROUTER_V2_ABI.
    // Struct: (tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96)

    function executeOrder(
        bytes32 orderId,
        address router,
        bytes calldata swapData
    ) external nonReentrant onlyBot {
        require(approvedRouters[router], "RL: Router not approved");
        Order storage o = orders[orderId];
        require(o.createdAt > 0,                 "RL: Not found");
        require(o.status == OrderStatus.Pending, "RL: Not pending");

        // Expired: full refund
        if (block.timestamp > o.deadline) {
            _refundFull(o);
            emit OrderExpired(orderId, o.amountGross);
            return;
        }

        // Approve router for net amount
        IERC20(o.tokenIn).approve(router, o.amountRemaining);

        uint256 outBefore = IERC20(o.tokenOut).balanceOf(address(this));
        (bool success,) = router.call(swapData);
        require(success, "RL: Swap reverted");
        IERC20(o.tokenIn).approve(router, 0); // revoke

        uint256 received = IERC20(o.tokenOut).balanceOf(address(this)) - outBefore;
        require(received >= o.minAmountOut, "RL: Slippage exceeded");

        o.filledAmountOut = received;
        o.amountRemaining = 0;
        o.status          = OrderStatus.Filled;

        require(IERC20(o.tokenOut).transfer(o.owner, received), "RL: Output transfer failed");
        emit OrderFilled(orderId, o.owner, received);
    }

    // ─── cancelOrder (user or bot) ────────────────────────────────────────────

    function cancelOrder(bytes32 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        require(o.createdAt > 0, "RL: Not found");
        require(msg.sender == o.owner || msg.sender == bot, "RL: Not authorized");
        require(o.status == OrderStatus.Pending, "RL: Not cancellable");
        _refundFull(o);
        emit OrderCancelled(orderId, o.owner, o.amountGross);
    }

    function _refundFull(Order storage o) internal {
        uint256 net   = o.amountRemaining;
        uint256 fee   = o.revenueFee;      // capture BEFORE zeroing
        uint256 total = net + fee;
        o.amountRemaining = 0;
        o.revenueFee      = 0;
        o.status = (block.timestamp > o.deadline) ? OrderStatus.Expired : OrderStatus.Cancelled;
        if (fee > 0 && pendingRevenue[o.tokenIn] >= fee) {
            pendingRevenue[o.tokenIn] -= fee;
        }
        if (total > 0) require(IERC20(o.tokenIn).transfer(o.owner, total), "RL: Refund failed");
    }

    // ─── Revenue Collection ───────────────────────────────────────────────────

    function collectRevenue(address token) external nonReentrant {
        require(msg.sender == owner || msg.sender == bot, "RL: Not authorized");
        uint256 amount = pendingRevenue[token];
        require(amount > 0, "RL: No revenue");
        pendingRevenue[token] = 0;
        require(IERC20(token).transfer(revenueRecipient, amount), "RL: Revenue transfer failed");
        emit RevenueCollected(token, amount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getUserOrders(address user) external view returns (bytes32[] memory) {
        return userOrders[user];
    }

    function getFeeQuote(uint256 amountIn) external view returns (
        uint256 revenueFeeAmount,
        uint256 netAmountForSwap,
        uint256 botFeeShido
    ) {
        revenueFeeAmount = (amountIn * revenueBps) / BPS_BASE;
        netAmountForSwap = amountIn - revenueFeeAmount;
        botFeeShido      = botFeeWei;
    }

    function getPendingRevenue(address token) external view returns (uint256) {
        return pendingRevenue[token];
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    // Set min/max limits for a token. Use raw decimals.
    // Example: USDC 6 decimals → setTokenLimits(USDC, 50_000_000, 1_000_000_000)
    // Example: WSHIDO 18 decimals → setTokenLimits(WSHIDO, 100_000e18, 2_000_000e18)
    function setTokenLimits(address token, uint256 minAmount, uint256 maxAmount) external onlyOwner {
        require(token != address(0), "RL: Zero addr");
        require(minAmount > 0,       "RL: Zero minimum");
        require(maxAmount > minAmount, "RL: Max must exceed min");
        tokenLimits[token] = TokenLimits(minAmount, maxAmount, true);
        emit TokenLimitsSet(token, minAmount, maxAmount);
    }

    function disableToken(address token) external onlyOwner {
        tokenLimits[token].isEnabled = false;
    }

    function setRouter(address router, bool authorized) external onlyOwner {
        authorizedRouters[router] = authorized;
        emit RouterAuthorized(router, authorized);
    }

    function setBotFee(uint256 _feeWei) external onlyOwner {
        require(_feeWei >= MIN_BOT_FEE_WEI && _feeWei <= MAX_BOT_FEE_WEI, "RL: Fee out of range");
        botFeeWei = _feeWei;
    }

    function setRevenueBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_REVENUE_BPS, "RL: Above 2% cap");
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
