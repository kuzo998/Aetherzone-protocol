// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherOrderRouter.sol v1.0
//
// SINGLE ENTRY POINT for all limit orders on AetherZone.
// Automatically routes to the correct engine based on order size:
//
//   amountIn <= maxRetailAmount[tokenIn]  →  RetailLimitOrders (bot swapper)
//   amountIn  > maxRetailAmount[tokenIn]  →  WhaleLimitOrders  (V3 LP)
//
// Both retail and whale contracts have `createOrderFor(user, ...)` functions
// so the router correctly preserves the original user as the order owner.
//
// USER FLOW:
//   1. User approves AetherOrderRouter for tokenIn
//   2. User calls placeLimitOrder(...)
//   3. Router reads threshold → decides route
//   4. Router pulls tokenIn from user → approves target contract → calls createOrderFor
//   5. Target contract creates order with user as owner
//
// APPROVALS: User only needs ONE approval (to this router).
// The router approves the target contract internally.
//
// ROUTING RULES:
//   - If maxRetailAmount[tokenIn] == 0: token must go to whale only
//   - If amountIn <= maxRetailAmount: retail route
//   - If amountIn > maxRetailAmount: whale route
//   - Retail validation: tokenLimits[tokenIn].isEnabled must be true in RetailLimitOrders
//   - Whale validation: pool must exist, tick range must be valid
//
// PARAMETERS:
//   - tickLower, tickUpper, poolFee: only used for whale orders (ignored for retail)
//   - minAmountOut, targetPriceX96: only used for retail orders (ignored for whale)
//   - Set unused params to 0 if routing to one type
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IRetailLimitOrders {
    function createOrderFor(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 targetPriceX96,
        uint64  deadline
    ) external payable returns (bytes32);
    function botFeeWei() external view returns (uint256);
    function tokenLimits(address token) external view returns (uint256 minAmount, uint256 maxAmount, bool isEnabled);
}

interface IWhaleLimitOrders {
    function createWhaleOrderFor(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper,
        uint64  deadline
    ) external payable returns (uint256 tokenId);
    function botFeeWei() external view returns (uint256);
    function minWhaleAmount(address token) external view returns (uint256);
}

contract AetherOrderRouter {

    // ─── Target Contracts ────────────────────────────────────────────────────

    IRetailLimitOrders public retailContract;
    IWhaleLimitOrders  public whaleContract;

    // ─── Routing Config ───────────────────────────────────────────────────────

    // Max amountIn (raw token decimals) that uses the retail route.
    // Above this → whale route. Set to 0 to disable retail for a token (whale only).
    mapping(address => uint256) public maxRetailAmount;

    address public owner;
    bool    public paused;
    uint256 private _lock;

    // ─── Events ───────────────────────────────────────────────────────────────

    event OrderRouted(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        bool    isWhale,
        address targetContract
    );
    event MaxRetailAmountSet(address indexed token, uint256 maxAmount);
    event ContractsUpdated(address retail, address whale);

    // ─── Modifier ─────────────────────────────────────────────────────────────

    modifier onlyOwner()     { require(msg.sender == owner, "OR: Not owner"); _; }
    modifier nonReentrant()  { require(_lock == 0, "OR: Reentrant"); _lock = 1; _; _lock = 0; }
    modifier whenNotPaused() { require(!paused, "OR: Paused"); _; }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _retailContract, address _whaleContract) {
        owner          = msg.sender;
        retailContract = IRetailLimitOrders(_retailContract);
        whaleContract  = IWhaleLimitOrders(_whaleContract);
    }

    // ─── Main Entry Point ─────────────────────────────────────────────────────

    /**
     * @notice Unified limit order placement. Router determines retail vs whale.
     *
     * @param tokenIn         Token to sell (user must approve THIS router for amountIn)
     * @param tokenOut        Token to receive
     * @param amountIn        Gross amount of tokenIn to deposit
     * @param minAmountOut    Min tokenOut (retail only — set to 1 for whale orders)
     * @param targetPriceX96  Q96 price (retail only — set to 0 for whale orders)
     * @param deadline        Unix timestamp expiry
     * @param poolFee         V3 pool fee tier — 500, 3000, 10000 (whale only)
     * @param tickLower       Lower tick bound (whale only — set to 0 for retail)
     * @param tickUpper       Upper tick bound (whale only — set to 0 for retail)
     */
    function placeLimitOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 targetPriceX96,
        uint64  deadline,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper
    ) external payable nonReentrant whenNotPaused {
        require(tokenIn != address(0) && tokenOut != address(0), "OR: Zero addr");
        require(amountIn > 0, "OR: Zero amount");
        require(deadline > block.timestamp, "OR: Deadline passed");

        bool isWhale = _isWhaleRoute(tokenIn, amountIn);

        // Pull tokenIn from user → router holds tokens temporarily
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "OR: Token pull failed");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;
        require(received > 0, "OR: No tokens received");

        if (isWhale) {
            require(address(whaleContract) != address(0), "OR: Whale contract not set");
            // Approve whale contract
            IERC20(tokenIn).approve(address(whaleContract), received);
            // Create order — user is preserved as owner
            whaleContract.createWhaleOrderFor{value: msg.value}(
                msg.sender, tokenIn, tokenOut, received, poolFee, tickLower, tickUpper, deadline
            );
            // Revoke approval
            IERC20(tokenIn).approve(address(whaleContract), 0);
            emit OrderRouted(msg.sender, tokenIn, received, true, address(whaleContract));
        } else {
            require(address(retailContract) != address(0), "OR: Retail contract not set");
            require(minAmountOut > 0, "OR: Zero min out (retail)");
            // Approve retail contract
            IERC20(tokenIn).approve(address(retailContract), received);
            // Create order — user is preserved as owner
            retailContract.createOrderFor{value: msg.value}(
                msg.sender, tokenIn, tokenOut, received, minAmountOut, targetPriceX96, deadline
            );
            // Revoke approval
            IERC20(tokenIn).approve(address(retailContract), 0);
            emit OrderRouted(msg.sender, tokenIn, received, false, address(retailContract));
        }
    }

    // ─── Forced Route Functions ───────────────────────────────────────────────
    //
    // Use these if you want to explicitly force a route regardless of threshold.
    // Frontend can use these to skip the router's automatic decision.

    function placeRetailOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 targetPriceX96,
        uint64  deadline
    ) external payable nonReentrant whenNotPaused {
        require(address(retailContract) != address(0), "OR: Retail contract not set");
        require(amountIn > 0 && minAmountOut > 0, "OR: Zero amounts");
        require(deadline > block.timestamp, "OR: Deadline passed");

        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "OR: Pull failed");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;

        IERC20(tokenIn).approve(address(retailContract), received);
        retailContract.createOrderFor{value: msg.value}(
            msg.sender, tokenIn, tokenOut, received, minAmountOut, targetPriceX96, deadline
        );
        IERC20(tokenIn).approve(address(retailContract), 0);
        emit OrderRouted(msg.sender, tokenIn, received, false, address(retailContract));
    }

    function placeWhaleOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24  poolFee,
        int24   tickLower,
        int24   tickUpper,
        uint64  deadline
    ) external payable nonReentrant whenNotPaused {
        require(address(whaleContract) != address(0), "OR: Whale contract not set");
        require(amountIn > 0, "OR: Zero amount");
        require(deadline > block.timestamp, "OR: Deadline passed");

        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "OR: Pull failed");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;

        IERC20(tokenIn).approve(address(whaleContract), received);
        whaleContract.createWhaleOrderFor{value: msg.value}(
            msg.sender, tokenIn, tokenOut, received, poolFee, tickLower, tickUpper, deadline
        );
        IERC20(tokenIn).approve(address(whaleContract), 0);
        emit OrderRouted(msg.sender, tokenIn, received, true, address(whaleContract));
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /**
     * @notice Preview which route would be used and the required bot fee.
     */
    function getRoute(
        address tokenIn,
        uint256 amountIn
    ) external view returns (
        bool    isWhale,
        address targetContract,
        uint256 botFeeWei,
        uint256 retailMax,
        uint256 whaleMin
    ) {
        retailMax = maxRetailAmount[tokenIn];
        isWhale   = _isWhaleRoute(tokenIn, amountIn);
        if (isWhale) {
            targetContract = address(whaleContract);
            botFeeWei      = address(whaleContract) != address(0) ? whaleContract.botFeeWei() : 0;
            whaleMin       = address(whaleContract) != address(0) ? whaleContract.minWhaleAmount(tokenIn) : 0;
        } else {
            targetContract = address(retailContract);
            botFeeWei      = address(retailContract) != address(0) ? retailContract.botFeeWei() : 0;
        }
    }

    /**
     * @notice Get both bot fees in one call (useful for frontend to show fee before routing).
     */
    function getBotFees() external view returns (uint256 retailFee, uint256 whaleFee) {
        if (address(retailContract) != address(0)) {
            try retailContract.botFeeWei() returns (uint256 f) { retailFee = f; } catch {}
        }
        if (address(whaleContract) != address(0)) {
            try whaleContract.botFeeWei() returns (uint256 f) { whaleFee = f; } catch {}
        }
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _isWhaleRoute(address tokenIn, uint256 amountIn) internal view returns (bool) {
        uint256 maxRetail = maxRetailAmount[tokenIn];
        // If maxRetailAmount is 0: all orders for this token go to whale
        if (maxRetail == 0) return true;
        // If amount exceeds retail max: whale route
        return amountIn > maxRetail;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Set the retail/whale threshold per token.
     * Orders at or below maxAmount → retail. Above → whale.
     *
     * Examples (using raw token decimals):
     *   USDC  6 dec: setMaxRetailAmount(USDC, 1_000_000_000) = $1,000 max retail
     *   WSHIDO 18 dec: setMaxRetailAmount(WSHIDO, 6_000_000e18) = ~$1k worth of WSHIDO at $0.000157
     *   Set to 0 to force all orders to whale route for that token.
     */
    function setMaxRetailAmount(address token, uint256 maxAmount) external onlyOwner {
        maxRetailAmount[token] = maxAmount;
        emit MaxRetailAmountSet(token, maxAmount);
    }

    function setContracts(address _retail, address _whale) external onlyOwner {
        if (_retail != address(0)) retailContract = IRetailLimitOrders(_retail);
        if (_whale  != address(0)) whaleContract  = IWhaleLimitOrders(_whale);
        emit ContractsUpdated(address(retailContract), address(whaleContract));
    }

    function setPaused(bool _p) external onlyOwner { paused = _p; }
    function transferOwnership(address n) external onlyOwner { require(n != address(0)); owner = n; }

    // Emergency: rescue any stuck tokens (should never happen in normal use)
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }

    receive() external payable {}
}
