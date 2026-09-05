// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherMulticall2.sol v1.0
//
// Companion to the deployed AetherMulticall.
// Covers the second generation of AetherZone contracts:
//   - WhaleLimitOrders  (V3 LP range orders, uint256 tokenIds)
//   - AetherOTCEscrow   (P2P atomic escrow, uint256 dealIds)
//   - AetherFundPool    (milestone crowdfunding, uint256 projectIds)
//   - AetherOrderRouter (routing info, bot fees)
//
// WHY A SECOND MULTICALL:
//   The deployed AetherMulticall has IAetherLimitOrders hardcoded (bytes32 ids).
//   These new contracts use different data types and interfaces.
//   Deploying a second contract is cleaner than redeploying the first
//   (which would break all existing frontend integrations).
//
// ALL FUNCTIONS ARE VIEW-ONLY - safe for any caller, no gas unless called
// from a transaction. All external calls wrapped in try/catch.
//
// CONSTRUCTOR: No arguments. Stateless - all contract addresses passed
// as parameters to each function. Flexible, no redeployment needed if
// contract addresses change.
// ════════════════════════════════════════════════════════════════════════════

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IWhaleLimitOrders {
    enum OrderStatus { Open, Filled, Cancelled, Expired }
    struct WhaleOrder {
        uint256     tokenId;
        address     owner;
        address     token0;
        address     token1;
        address     tokenIn;
        address     tokenOut;
        uint24      fee;
        int24       tickLower;
        int24       tickUpper;
        uint128     initialLiquidity;
        uint256     amountDeposited;
        OrderStatus status;
        uint64      createdAt;
        uint64      deadline;
    }
    function getOrder(uint256 tokenId) external view returns (WhaleOrder memory);
    function getUserOrders(address user) external view returns (uint256[] memory);
    function getUserOrdersFull(address user) external view returns (WhaleOrder[] memory);
    function isOrderFilled(uint256 tokenId) external view returns (bool filled, bool filling, int24 currentTick, uint128 remainingLiquidity);
    function getFeeQuote(uint256 outputAmount) external view returns (uint256 revenueFeeAmount, uint256 userReceives, uint256 botFeeShido);
    function botFeeWei() external view returns (uint256);
    function revenueBps() external view returns (uint256);
    function minWhaleAmount(address token) external view returns (uint256);
    function totalOrdersCreated() external view returns (uint256);
}

interface IAetherOTCEscrow {
    enum DealStatus { Open, Filled, Cancelled, Expired }
    struct Deal {
        uint256    id;
        address    maker;
        address    tokenIn;
        address    tokenOut;
        uint256    amountIn;
        uint256    amountOut;
        uint256    amountInFilled;
        uint256    amountOutFilled;
        uint256    amountInRemaining;
        DealStatus status;
        uint64     createdAt;
        uint64     deadline;
        uint256    minFillAmount;
    }
    function getDeal(uint256 dealId) external view returns (Deal memory);
    function getMakerDeals(address maker) external view returns (uint256[] memory);
    function getMakerDealsFull(address maker) external view returns (Deal[] memory);
    function getFillQuote(uint256 dealId, uint256 tokenInAmount) external view returns (uint256 tokenOutGross, uint256 tokenOutFee, uint256 tokenOutToMaker);
    function nextDealId() external view returns (uint256);
    function feeBps() external view returns (uint256);
    function pendingRevenue(address token) external view returns (uint256);
}

interface IAetherFundPool {
    enum ProjectStatus { Active, Funded, Cancelled }
    function getProject(uint256 projectId) external view returns (
        uint256 id, string memory title, address token,
        uint256 targetAmount, uint256 softCap, address beneficiary,
        uint256 raised, uint256 released, uint256 deadline,
        ProjectStatus status, uint256 createdAt, uint256 milestoneCount
    );
    function getMilestone(uint256 projectId, uint256 milestoneIndex) external view returns (
        string memory title, uint256 amount, bool isReleased, uint64 releasedAt
    );
    function getContribution(uint256 projectId, address contributor) external view returns (uint256);
    function getContributorCount(uint256 projectId) external view returns (uint256);
    function getProgressPercent(uint256 projectId) external view returns (uint256 percent, uint256 softCapPercent);
    function getRefundEligibility(uint256 projectId, address contributor) external view returns (bool eligible, uint256 amount, string memory reason);
    function nextProjectId() external view returns (uint256);
}

interface IAetherOrderRouter {
    function getRoute(address tokenIn, uint256 amountIn) external view returns (
        bool isWhale, address targetContract, uint256 botFeeWei, uint256 retailMax, uint256 whaleMin
    );
    function getBotFees() external view returns (uint256 retailFee, uint256 whaleFee);
    function maxRetailAmount(address token) external view returns (uint256);
}

interface IRetailLimitOrders {
    enum OrderStatus { Pending, Filled, Cancelled, Expired }
    struct Order {
        bytes32     id;
        address     owner;
        address     tokenIn;
        address     tokenOut;
        uint256     amountGross;
        uint256     revenueFee;
        uint256     amountIn;
        uint256     amountRemaining;
        uint256     minAmountOut;
        uint256     targetPriceX96;
        uint64      deadline;
        uint64      createdAt;
        OrderStatus status;
        uint256     filledAmountOut;
    }
    function getOrder(bytes32 orderId) external view returns (Order memory);
    function getUserOrders(address user) external view returns (bytes32[] memory);
    function getFeeQuote(uint256 amountIn) external view returns (uint256 revenueFeeAmount, uint256 netAmountForSwap, uint256 botFeeShido);
    function tokenLimits(address token) external view returns (uint256 minAmount, uint256 maxAmount, bool isEnabled);
    function botFeeWei() external view returns (uint256);
    function revenueBps() external view returns (uint256);
}

// ─── AetherMulticall2 ─────────────────────────────────────────────────────────


interface IAetherZap {
    function previewZapIn(
        address tokenIn, uint256 amountIn,
        address token0, address token1, uint24 poolFee,
        int24 tickLower, int24 tickUpper
    ) external view returns (uint256 platformFee, uint256 netAmount, uint256 swapAmount);
    function feeBps() external view returns (uint256);
    function keeperRewardBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
}

interface IAetherGuard {
    function checkTwapSafe(address tokenIn, address tokenOut, uint24 poolFee)
        external view returns (bool safe, int24 spotTick, int24 twapTick, uint256 deviationBps);
    function isPoolSafe(address tokenIn, address tokenOut, uint24 fee) external view returns (bool);
    function maxTwapDeviationBps() external view returns (uint256);
    function twapWindow() external view returns (uint32);
    function approvedTokens(address token) external view returns (bool);
}

interface IAetherRangeManager {
    enum Strategy { FIXED_WIDTH, FOLLOW_PRICE }
    struct Registration {
        address  owner;
        Strategy strategy;
        int24    rangeWidth;
        uint256  slippageBps;
        bool     active;
        uint256  rerangeCount;
        uint256  lastRerangeAt;
    }
    function getRegistration(uint256 tokenId) external view returns (Registration memory);
    function getUserPositions(address user) external view returns (uint256[] memory);
    function needsRerange(uint256 tokenId) external view returns (
        bool outOfRange, bool hasFunds, uint256 rerangesRemaining,
        int24 currentTick, int24 tickLower, int24 tickUpper
    );
    function getRegistrationCost() external view returns (
        uint256 costPerRerange, uint256 minDeposit, uint256 platformFeePercent
    );
    function gasDeposits(uint256 tokenId) external view returns (uint256);
    function rerangeCostWei() external view returns (uint256);
}

contract AetherMulticall2 {

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 1: WHALE LIMIT ORDERS
    // ════════════════════════════════════════════════════════════════════════

    struct WhaleFillStatus {
        uint256 tokenId;
        bool    filled;
        bool    filling;
        int24   currentTick;
        uint128 remainingLiquidity;
        bool    exists;
    }

    /// @notice All whale orders for a user + fill status for each open order
    /// @dev Replaces: getUserOrdersFull + N x isOrderFilled calls
    function getWhaleUserDashboard(
        address user,
        address whaleContract
    ) external view returns (
        IWhaleLimitOrders.WhaleOrder[] memory orders,
        WhaleFillStatus[] memory       fillStatuses,
        uint256                        botFeeWei,
        uint256                        revenueBps
    ) {
        IWhaleLimitOrders wc = IWhaleLimitOrders(whaleContract);
        try wc.getUserOrdersFull(user) returns (IWhaleLimitOrders.WhaleOrder[] memory o) {
            orders = o;
        } catch { orders = new IWhaleLimitOrders.WhaleOrder[](0); }

        fillStatuses = new WhaleFillStatus[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            if (orders[i].status == IWhaleLimitOrders.OrderStatus.Open) {
                try wc.isOrderFilled(orders[i].tokenId) returns (bool f, bool fl, int24 t, uint128 liq) {
                    fillStatuses[i] = WhaleFillStatus(orders[i].tokenId, f, fl, t, liq, true);
                } catch {}
            }
        }
        try wc.botFeeWei()  returns (uint256 f) { botFeeWei  = f; } catch {}
        try wc.revenueBps() returns (uint256 r) { revenueBps = r; } catch {}
    }

    /// @notice Batch fill status check - bot uses this every 30s instead of N individual calls
    function batchIsOrderFilled(
        uint256[] calldata tokenIds,
        address whaleContract
    ) external view returns (WhaleFillStatus[] memory statuses) {
        IWhaleLimitOrders wc = IWhaleLimitOrders(whaleContract);
        statuses = new WhaleFillStatus[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; i++) {
            try wc.isOrderFilled(tokenIds[i]) returns (bool f, bool fl, int24 t, uint128 liq) {
                statuses[i] = WhaleFillStatus(tokenIds[i], f, fl, t, liq, true);
            } catch {}
        }
    }

    /// @notice Batch read whale orders by tokenId
    function batchGetWhaleOrders(
        uint256[] calldata tokenIds,
        address whaleContract
    ) external view returns (IWhaleLimitOrders.WhaleOrder[] memory orders) {
        IWhaleLimitOrders wc = IWhaleLimitOrders(whaleContract);
        orders = new IWhaleLimitOrders.WhaleOrder[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; i++) {
            try wc.getOrder(tokenIds[i]) returns (IWhaleLimitOrders.WhaleOrder memory o) {
                orders[i] = o;
            } catch {}
        }
    }

    /// @notice Whale contract config: bot fee, revenue rate, min amounts per token
    function getWhaleConfig(
        address whaleContract,
        address[] calldata tokens
    ) external view returns (
        uint256   botFeeWei,
        uint256   revenueBps,
        uint256   totalCreated,
        uint256[] memory minAmounts
    ) {
        IWhaleLimitOrders wc = IWhaleLimitOrders(whaleContract);
        try wc.botFeeWei()          returns (uint256 f) { botFeeWei    = f; } catch {}
        try wc.revenueBps()         returns (uint256 r) { revenueBps   = r; } catch {}
        try wc.totalOrdersCreated() returns (uint256 t) { totalCreated = t; } catch {}
        minAmounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            try wc.minWhaleAmount(tokens[i]) returns (uint256 m) { minAmounts[i] = m; } catch {}
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 2: OTC ESCROW
    // ════════════════════════════════════════════════════════════════════════

    /// @notice All OTC deals by a maker with full data
    function getOtcMakerDeals(
        address maker,
        address otcContract
    ) external view returns (
        IAetherOTCEscrow.Deal[] memory deals,
        uint256                 feeBps
    ) {
        IAetherOTCEscrow oc = IAetherOTCEscrow(otcContract);
        try oc.getMakerDealsFull(maker) returns (IAetherOTCEscrow.Deal[] memory d) {
            deals = d;
        } catch { deals = new IAetherOTCEscrow.Deal[](0); }
        try oc.feeBps() returns (uint256 f) { feeBps = f; } catch {}
    }

    /// @notice Batch read OTC deals by dealId - page through 0..nextDealId-1
    function batchGetOtcDeals(
        uint256[] calldata dealIds,
        address otcContract
    ) external view returns (IAetherOTCEscrow.Deal[] memory deals) {
        IAetherOTCEscrow oc = IAetherOTCEscrow(otcContract);
        deals = new IAetherOTCEscrow.Deal[](dealIds.length);
        for (uint256 i; i < dealIds.length; i++) {
            try oc.getDeal(dealIds[i]) returns (IAetherOTCEscrow.Deal memory d) {
                deals[i] = d;
            } catch {}
        }
    }

    /// @notice Deal data + fill quote in one call (taker confirmation UI)
    function getOtcFillPreview(
        uint256 dealId,
        uint256 tokenInAmount,
        address otcContract
    ) external view returns (
        IAetherOTCEscrow.Deal memory deal,
        uint256 tokenOutGross,
        uint256 tokenOutFee,
        uint256 tokenOutToMaker,
        uint256 feeBps
    ) {
        IAetherOTCEscrow oc = IAetherOTCEscrow(otcContract);
        try oc.getDeal(dealId) returns (IAetherOTCEscrow.Deal memory d) { deal = d; } catch {}
        try oc.getFillQuote(dealId, tokenInAmount) returns (uint256 g, uint256 f, uint256 m) {
            tokenOutGross   = g;
            tokenOutFee     = f;
            tokenOutToMaker = m;
        } catch {}
        try oc.feeBps() returns (uint256 f) { feeBps = f; } catch {}
    }

    /// @notice OTC contract stats + pending revenue per token
    function getOtcStats(
        address otcContract,
        address[] calldata revenueTokens
    ) external view returns (
        uint256   totalDeals,
        uint256   feeBps,
        uint256[] memory pendingRevenue
    ) {
        IAetherOTCEscrow oc = IAetherOTCEscrow(otcContract);
        try oc.nextDealId() returns (uint256 n) { totalDeals = n; } catch {}
        try oc.feeBps()     returns (uint256 f) { feeBps     = f; } catch {}
        pendingRevenue = new uint256[](revenueTokens.length);
        for (uint256 i; i < revenueTokens.length; i++) {
            try oc.pendingRevenue(revenueTokens[i]) returns (uint256 r) {
                pendingRevenue[i] = r;
            } catch {}
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 3: FUND POOL
    // ════════════════════════════════════════════════════════════════════════

    struct MilestoneData {
        string  title;
        uint256 amount;
        bool    released;
        uint64  releasedAt;
    }

    struct ProjectFull {
        uint256         id;
        string          title;
        address         token;
        uint256         targetAmount;
        uint256         softCap;
        address         beneficiary;
        uint256         raised;
        uint256         released;
        uint256         deadline;
        uint8           status;          // 0=Active 1=Funded 2=Cancelled
        uint256         createdAt;
        uint256         percentComplete;
        uint256         softCapPercent;
        MilestoneData[] milestones;
    }

    /// @notice Project + all milestones + progress in one call
    /// @dev Replaces: getProject + N x getMilestone + getProgressPercent
    function getFundProjectFull(
        uint256 projectId,
        address fundContract
    ) external view returns (ProjectFull memory proj) {
        IAetherFundPool fc = IAetherFundPool(fundContract);
        uint256 milestoneCount;

        try fc.getProject(projectId) returns (
            uint256 id, string memory title, address token,
            uint256 targetAmount, uint256 softCap, address beneficiary,
            uint256 raised, uint256 released, uint256 deadline,
            IAetherFundPool.ProjectStatus status, uint256 createdAt, uint256 mc
        ) {
            proj.id           = id;
            proj.title        = title;
            proj.token        = token;
            proj.targetAmount = targetAmount;
            proj.softCap      = softCap;
            proj.beneficiary  = beneficiary;
            proj.raised       = raised;
            proj.released     = released;
            proj.deadline     = deadline;
            proj.status       = uint8(status);
            proj.createdAt    = createdAt;
            milestoneCount    = mc;
        } catch { return proj; }

        try fc.getProgressPercent(projectId) returns (uint256 pct, uint256 scPct) {
            proj.percentComplete = pct;
            proj.softCapPercent  = scPct;
        } catch {}

        proj.milestones = new MilestoneData[](milestoneCount);
        for (uint256 i; i < milestoneCount; i++) {
            try fc.getMilestone(projectId, i) returns (string memory t, uint256 a, bool r, uint64 ra) {
                proj.milestones[i] = MilestoneData(t, a, r, ra);
            } catch {}
        }
    }

    /// @notice Batch read multiple projects
    function batchGetFundProjects(
        uint256[] calldata projectIds,
        address fundContract
    ) external view returns (ProjectFull[] memory projects) {
        projects = new ProjectFull[](projectIds.length);
        for (uint256 i; i < projectIds.length; i++) {
            try this.getFundProjectFull(projectIds[i], fundContract) returns (ProjectFull memory p) {
                projects[i] = p;
            } catch {}
        }
    }

    /// @notice Paginated project listing by ID range
    function getFundProjectRange(
        uint256 fromId,
        uint256 toId,
        address fundContract
    ) external view returns (ProjectFull[] memory projects, uint256 totalProjects) {
        IAetherFundPool fc = IAetherFundPool(fundContract);
        try fc.nextProjectId() returns (uint256 n) { totalProjects = n; } catch {}

        uint256 end = toId < totalProjects ? toId : totalProjects;
        if (fromId >= end) return (new ProjectFull[](0), totalProjects);

        uint256 count = end - fromId;
        projects = new ProjectFull[](count);
        for (uint256 i; i < count; i++) {
            try this.getFundProjectFull(fromId + i, fundContract) returns (ProjectFull memory p) {
                projects[i] = p;
            } catch {}
        }
    }

    struct ContributorProjectInfo {
        uint256 projectId;
        uint256 contributed;
        bool    refundEligible;
        uint256 refundAmount;
        string  refundReason;
    }

    /// @notice All fund contributions + refund eligibility for a contributor
    function getContributorPortfolio(
        address contributor,
        uint256[] calldata projectIds,
        address fundContract
    ) external view returns (ContributorProjectInfo[] memory info) {
        IAetherFundPool fc = IAetherFundPool(fundContract);
        info = new ContributorProjectInfo[](projectIds.length);
        for (uint256 i; i < projectIds.length; i++) {
            info[i].projectId = projectIds[i];
            try fc.getContribution(projectIds[i], contributor) returns (uint256 c) {
                info[i].contributed = c;
            } catch {}
            if (info[i].contributed > 0) {
                try fc.getRefundEligibility(projectIds[i], contributor) returns (bool e, uint256 a, string memory r) {
                    info[i].refundEligible = e;
                    info[i].refundAmount   = a;
                    info[i].refundReason   = r;
                } catch {}
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 4: ORDER ROUTER
    // ════════════════════════════════════════════════════════════════════════

    struct RouteInfo {
        address token;
        uint256 amount;
        bool    isWhale;
        address targetContract;
        uint256 botFeeWei;
        uint256 retailMax;
        uint256 whaleMin;
    }

    /// @notice Batch routing preview - frontend shows Retail/Whale badge before submit
    function batchGetRoutes(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address routerContract
    ) external view returns (RouteInfo[] memory routes) {
        require(tokens.length == amounts.length, "MC2: Length mismatch");
        IAetherOrderRouter router = IAetherOrderRouter(routerContract);
        routes = new RouteInfo[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            routes[i].token  = tokens[i];
            routes[i].amount = amounts[i];
            try router.getRoute(tokens[i], amounts[i]) returns (
                bool isWhale, address target, uint256 fee, uint256 rMax, uint256 wMin
            ) {
                routes[i].isWhale        = isWhale;
                routes[i].targetContract = target;
                routes[i].botFeeWei      = fee;
                routes[i].retailMax      = rMax;
                routes[i].whaleMin       = wMin;
            } catch {}
        }
    }

    /// @notice Fee config for a token - retail fee, whale fee, thresholds
    function getLimitOrderConfig(
        address tokenIn,
        address routerContract
    ) external view returns (
        uint256 retailBotFee,
        uint256 whaleBotFee,
        uint256 retailMax
    ) {
        IAetherOrderRouter router = IAetherOrderRouter(routerContract);
        try router.getBotFees() returns (uint256 rf, uint256 wf) {
            retailBotFee = rf;
            whaleBotFee  = wf;
        } catch {}
        try router.maxRetailAmount(tokenIn) returns (uint256 m) { retailMax = m; } catch {}
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 5: RETAIL LIMIT ORDERS
    // Returns full Order struct - the deployed AetherMulticall uses a simplified
    // IAetherLimitOrders.Order without revenueFee/amountGross fields
    // ════════════════════════════════════════════════════════════════════════

    /// @notice All retail orders for a user with full struct data
    function getRetailUserOrders(
        address user,
        address retailContract
    ) external view returns (
        IRetailLimitOrders.Order[] memory orders,
        uint256 botFeeWei,
        uint256 revenueBps
    ) {
        IRetailLimitOrders rc = IRetailLimitOrders(retailContract);
        bytes32[] memory ids;
        try rc.getUserOrders(user) returns (bytes32[] memory i) { ids = i; } catch { return (orders, 0, 0); }

        orders = new IRetailLimitOrders.Order[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            try rc.getOrder(ids[i]) returns (IRetailLimitOrders.Order memory o) {
                orders[i] = o;
            } catch {}
        }
        try rc.botFeeWei()  returns (uint256 f) { botFeeWei  = f; } catch {}
        try rc.revenueBps() returns (uint256 r) { revenueBps = r; } catch {}
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 6: UNIFIED USER DASHBOARD
    // Everything a connected wallet needs across ALL AetherZone contracts
    // in a single RPC call
    // ════════════════════════════════════════════════════════════════════════

    struct UserDashboard {
        IWhaleLimitOrders.WhaleOrder[] whaleOrders;
        WhaleFillStatus[]              whaleFillStatuses;
        IRetailLimitOrders.Order[]     retailOrders;
        IAetherOTCEscrow.Deal[]        otcDeals;
        ContributorProjectInfo[]       fundContributions;
        uint256                        whaleBotFee;
        uint256                        retailBotFee;
    }

    /// @notice Complete user snapshot across all contracts in one call
    function getUserDashboard(
        address            user,
        address            whaleContract,
        address            retailContract,
        address            otcContract,
        address            fundContract,
        uint256[] calldata fundProjectIds
    ) external view returns (UserDashboard memory dash) {
        // --- Whale orders ---
        if (whaleContract != address(0)) {
            try IWhaleLimitOrders(whaleContract).getUserOrdersFull(user)
                returns (IWhaleLimitOrders.WhaleOrder[] memory orders)
            {
                dash.whaleOrders       = orders;
                dash.whaleFillStatuses = new WhaleFillStatus[](orders.length);
                for (uint256 i; i < orders.length; i++) {
                    if (orders[i].status == IWhaleLimitOrders.OrderStatus.Open) {
                        try IWhaleLimitOrders(whaleContract).isOrderFilled(orders[i].tokenId)
                            returns (bool f, bool fl, int24 t, uint128 liq)
                        {
                            dash.whaleFillStatuses[i] = WhaleFillStatus(orders[i].tokenId, f, fl, t, liq, true);
                        } catch {}
                    }
                }
            } catch {}
            try IWhaleLimitOrders(whaleContract).botFeeWei() returns (uint256 f) { dash.whaleBotFee = f; } catch {}
        }

        // --- Retail orders ---
        if (retailContract != address(0)) {
            bytes32[] memory ids;
            try IRetailLimitOrders(retailContract).getUserOrders(user) returns (bytes32[] memory i) { ids = i; } catch {}
            if (ids.length > 0) {
                dash.retailOrders = new IRetailLimitOrders.Order[](ids.length);
                for (uint256 i; i < ids.length; i++) {
                    try IRetailLimitOrders(retailContract).getOrder(ids[i])
                        returns (IRetailLimitOrders.Order memory o) { dash.retailOrders[i] = o; }
                    catch {}
                }
            }
            try IRetailLimitOrders(retailContract).botFeeWei() returns (uint256 f) { dash.retailBotFee = f; } catch {}
        }

        // --- OTC deals ---
        if (otcContract != address(0)) {
            try IAetherOTCEscrow(otcContract).getMakerDealsFull(user)
                returns (IAetherOTCEscrow.Deal[] memory deals) { dash.otcDeals = deals; }
            catch {}
        }

        // --- Fund contributions ---
        if (fundContract != address(0) && fundProjectIds.length > 0) {
            dash.fundContributions = new ContributorProjectInfo[](fundProjectIds.length);
            IAetherFundPool fc = IAetherFundPool(fundContract);
            for (uint256 i; i < fundProjectIds.length; i++) {
                dash.fundContributions[i].projectId = fundProjectIds[i];
                try fc.getContribution(fundProjectIds[i], user) returns (uint256 c) {
                    dash.fundContributions[i].contributed = c;
                } catch {}
                if (dash.fundContributions[i].contributed > 0) {
                    try fc.getRefundEligibility(fundProjectIds[i], user) returns (bool e, uint256 a, string memory r) {
                        dash.fundContributions[i].refundEligible = e;
                        dash.fundContributions[i].refundAmount   = a;
                        dash.fundContributions[i].refundReason   = r;
                    } catch {}
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 7: GENERIC MULTICALL (Multicall3-compatible fallback)
    // ════════════════════════════════════════════════════════════════════════

    struct Call   { address target; bytes callData; }
    struct Result { bool success;   bytes returnData; }

    function tryAggregate(bool requireSuccess, Call[] calldata calls)
        external view returns (Result[] memory results)
    {
        results = new Result[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.staticcall(calls[i].callData);
            if (requireSuccess) require(success, "MC2: Required call failed");
            results[i] = Result(success, ret);
        }
    }

    function getBlockMetadata() external view returns (
        uint256 blockNumber, uint256 timestamp, uint256 basefee
    ) {
        blockNumber = block.number;
        timestamp   = block.timestamp;
        basefee     = block.basefee;
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 8: AETHER ZAP
    // ════════════════════════════════════════════════════════════════════════


    struct ZapPreview {
        uint256 platformFee;
        uint256 netAmount;
        uint256 swapAmount;
        uint256 feeBps;
        uint256 keeperRewardBps;
    }

    /// @notice Preview a zapIn and fetch config in one call
    function previewZap(
        address tokenIn, uint256 amountIn,
        address token0, address token1,
        uint24 poolFee, int24 tickLower, int24 tickUpper,
        address zapContract
    ) external view returns (ZapPreview memory preview) {
        IAetherZap zap = IAetherZap(zapContract);
        try zap.previewZapIn(tokenIn, amountIn, token0, token1, poolFee, tickLower, tickUpper)
            returns (uint256 fee, uint256 net, uint256 swap)
        {
            preview.platformFee = fee;
            preview.netAmount   = net;
            preview.swapAmount  = swap;
        } catch {}
        try zap.feeBps()          returns (uint256 f) { preview.feeBps          = f; } catch {}
        try zap.keeperRewardBps() returns (uint256 k) { preview.keeperRewardBps = k; } catch {}
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 9: AETHER GUARD (TWAP + pool safety checks)
    // ════════════════════════════════════════════════════════════════════════


    struct TwapCheck {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        bool    safe;
        bool    poolExists;
        int24   spotTick;
        int24   twapTick;
        uint256 deviationBps;
    }

    /// @notice Batch TWAP safety check across multiple token pairs
    /// @dev Bot calls this before executing retail orders
    function batchCheckTwap(
        address[] calldata tokenIns,
        address[] calldata tokenOuts,
        uint24[]  calldata fees,
        address guardContract
    ) external view returns (TwapCheck[] memory checks) {
        require(tokenIns.length == tokenOuts.length && tokenOuts.length == fees.length, "MC2: Length mismatch");
        IAetherGuard guard = IAetherGuard(guardContract);
        checks = new TwapCheck[](tokenIns.length);
        for (uint256 i; i < tokenIns.length; i++) {
            checks[i].tokenIn = tokenIns[i];
            checks[i].tokenOut = tokenOuts[i];
            checks[i].fee = fees[i];
            try guard.checkTwapSafe(tokenIns[i], tokenOuts[i], fees[i])
                returns (bool safe, int24 spot, int24 twap, uint256 dev)
            {
                checks[i].safe         = safe;
                checks[i].spotTick     = spot;
                checks[i].twapTick     = twap;
                checks[i].deviationBps = dev;
            } catch {}
            try guard.isPoolSafe(tokenIns[i], tokenOuts[i], fees[i])
                returns (bool exists) { checks[i].poolExists = exists; } catch {}
        }
    }

    /// @notice Check if a set of tokens are approved in AetherGuard
    function checkTokensApproved(
        address[] calldata tokens,
        address guardContract
    ) external view returns (bool[] memory approved) {
        IAetherGuard guard = IAetherGuard(guardContract);
        approved = new bool[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            try guard.approvedTokens(tokens[i]) returns (bool a) { approved[i] = a; } catch {}
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 10: AETHER RANGE MANAGER
    // ════════════════════════════════════════════════════════════════════════


    struct RangePositionStatus {
        uint256 tokenId;
        bool    registered;
        bool    outOfRange;
        bool    hasFunds;
        uint256 rerangesRemaining;
        uint256 gasBalance;
        int24   currentTick;
        int24   tickLower;
        int24   tickUpper;
        uint256 rerangeCount;
        uint256 lastRerangeAt;
    }

    /// @notice Get full status of all range-managed positions for a user
    function getUserRangePositions(
        address user,
        address rangeManager
    ) external view returns (RangePositionStatus[] memory statuses, uint256 costPerRerange) {
        IAetherRangeManager rm = IAetherRangeManager(rangeManager);
        uint256[] memory ids;
        try rm.getUserPositions(user) returns (uint256[] memory i) { ids = i; } catch {
            return (new RangePositionStatus[](0), 0);
        }
        try rm.rerangeCostWei() returns (uint256 c) { costPerRerange = c; } catch {}

        statuses = new RangePositionStatus[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            statuses[i].tokenId = ids[i];
            try rm.getRegistration(ids[i]) returns (IAetherRangeManager.Registration memory reg) {
                statuses[i].registered   = reg.active;
                statuses[i].rerangeCount = reg.rerangeCount;
                statuses[i].lastRerangeAt = reg.lastRerangeAt;
            } catch {}
            try rm.gasDeposits(ids[i]) returns (uint256 g) { statuses[i].gasBalance = g; } catch {}
            try rm.needsRerange(ids[i]) returns (
                bool oor, bool hf, uint256 rr, int24 ct, int24 tl, int24 tu
            ) {
                statuses[i].outOfRange        = oor;
                statuses[i].hasFunds          = hf;
                statuses[i].rerangesRemaining = rr;
                statuses[i].currentTick       = ct;
                statuses[i].tickLower         = tl;
                statuses[i].tickUpper         = tu;
            } catch {}
        }
    }

    /// @notice Batch needsRerange check — bot uses this to find work
    function batchNeedsRerange(
        uint256[] calldata tokenIds,
        address rangeManager
    ) external view returns (RangePositionStatus[] memory statuses) {
        IAetherRangeManager rm = IAetherRangeManager(rangeManager);
        statuses = new RangePositionStatus[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; i++) {
            statuses[i].tokenId = tokenIds[i];
            try rm.needsRerange(tokenIds[i]) returns (
                bool oor, bool hf, uint256 rr, int24 ct, int24 tl, int24 tu
            ) {
                statuses[i].outOfRange        = oor;
                statuses[i].hasFunds          = hf;
                statuses[i].rerangesRemaining = rr;
                statuses[i].currentTick       = ct;
                statuses[i].tickLower         = tl;
                statuses[i].tickUpper         = tu;
                statuses[i].registered        = true;
            } catch {}
            try rm.gasDeposits(tokenIds[i]) returns (uint256 g) { statuses[i].gasBalance = g; } catch {}
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 11: UNIFIED FULL DASHBOARD (all contracts, one call)
    // Extends Section 6's getUserDashboard with the new contracts
    // ════════════════════════════════════════════════════════════════════════

    struct FullDashboard {
        // From Section 6 (limit orders, OTC, fund)
        IWhaleLimitOrders.WhaleOrder[] whaleOrders;
        WhaleFillStatus[]              whaleFillStatuses;
        IRetailLimitOrders.Order[]     retailOrders;
        IAetherOTCEscrow.Deal[]        otcDeals;
        ContributorProjectInfo[]       fundContributions;
        uint256                        whaleBotFee;
        uint256                        retailBotFee;
        // Range Manager positions
        RangePositionStatus[]          rangePositions;
        uint256                        rerangeCostWei;
        // Zap config
        uint256                        zapFeeBps;
        uint256                        zapKeeperRewardBps;
    }

    /**
     * @notice Everything a connected wallet needs across ALL AetherZone contracts.
     * Single RPC call replaces: getUserDashboard + getUserRangePositions + zapConfig.
     */
    function getFullDashboard(
        address            user,
        address            whaleContract,
        address            retailContract,
        address            otcContract,
        address            fundContract,
        uint256[] calldata fundProjectIds,
        address            rangeManager,
        address            zapContract
    ) external view returns (FullDashboard memory dash) {
        // --- Whale orders ---
        if (whaleContract != address(0)) {
            try IWhaleLimitOrders(whaleContract).getUserOrdersFull(user)
                returns (IWhaleLimitOrders.WhaleOrder[] memory orders)
            {
                dash.whaleOrders       = orders;
                dash.whaleFillStatuses = new WhaleFillStatus[](orders.length);
                for (uint256 i; i < orders.length; i++) {
                    if (orders[i].status == IWhaleLimitOrders.OrderStatus.Open) {
                        try IWhaleLimitOrders(whaleContract).isOrderFilled(orders[i].tokenId)
                            returns (bool f, bool fl, int24 t, uint128 liq)
                        {
                            dash.whaleFillStatuses[i] = WhaleFillStatus(orders[i].tokenId, f, fl, t, liq, true);
                        } catch {}
                    }
                }
            } catch {}
            try IWhaleLimitOrders(whaleContract).botFeeWei() returns (uint256 f) { dash.whaleBotFee = f; } catch {}
        }

        // --- Retail orders ---
        if (retailContract != address(0)) {
            bytes32[] memory ids;
            try IRetailLimitOrders(retailContract).getUserOrders(user) returns (bytes32[] memory i) { ids = i; } catch {}
            if (ids.length > 0) {
                dash.retailOrders = new IRetailLimitOrders.Order[](ids.length);
                for (uint256 i; i < ids.length; i++) {
                    try IRetailLimitOrders(retailContract).getOrder(ids[i])
                        returns (IRetailLimitOrders.Order memory o) { dash.retailOrders[i] = o; } catch {}
                }
            }
            try IRetailLimitOrders(retailContract).botFeeWei() returns (uint256 f) { dash.retailBotFee = f; } catch {}
        }

        // --- OTC deals ---
        if (otcContract != address(0)) {
            try IAetherOTCEscrow(otcContract).getMakerDealsFull(user)
                returns (IAetherOTCEscrow.Deal[] memory deals) { dash.otcDeals = deals; } catch {}
        }

        // --- Fund contributions ---
        if (fundContract != address(0) && fundProjectIds.length > 0) {
            dash.fundContributions = new ContributorProjectInfo[](fundProjectIds.length);
            IAetherFundPool fc = IAetherFundPool(fundContract);
            for (uint256 i; i < fundProjectIds.length; i++) {
                dash.fundContributions[i].projectId = fundProjectIds[i];
                try fc.getContribution(fundProjectIds[i], user) returns (uint256 c) {
                    dash.fundContributions[i].contributed = c;
                } catch {}
                if (dash.fundContributions[i].contributed > 0) {
                    try fc.getRefundEligibility(fundProjectIds[i], user)
                        returns (bool e, uint256 a, string memory r) {
                        dash.fundContributions[i].refundEligible = e;
                        dash.fundContributions[i].refundAmount   = a;
                        dash.fundContributions[i].refundReason   = r;
                    } catch {}
                }
            }
        }

        // --- Range positions ---
        if (rangeManager != address(0)) {
            IAetherRangeManager rm = IAetherRangeManager(rangeManager);
            uint256[] memory ids;
            try rm.getUserPositions(user) returns (uint256[] memory i) { ids = i; } catch {}
            try rm.rerangeCostWei() returns (uint256 c) { dash.rerangeCostWei = c; } catch {}
            if (ids.length > 0) {
                dash.rangePositions = new RangePositionStatus[](ids.length);
                for (uint256 i; i < ids.length; i++) {
                    dash.rangePositions[i].tokenId = ids[i];
                    try rm.needsRerange(ids[i]) returns (
                        bool oor, bool hf, uint256 rr, int24 ct, int24 tl, int24 tu
                    ) {
                        dash.rangePositions[i].outOfRange        = oor;
                        dash.rangePositions[i].hasFunds          = hf;
                        dash.rangePositions[i].rerangesRemaining = rr;
                        dash.rangePositions[i].currentTick       = ct;
                        dash.rangePositions[i].tickLower         = tl;
                        dash.rangePositions[i].tickUpper         = tu;
                        dash.rangePositions[i].registered        = true;
                    } catch {}
                    try rm.gasDeposits(ids[i]) returns (uint256 g) { dash.rangePositions[i].gasBalance = g; } catch {}
                }
            }
        }

        // --- Zap config ---
        if (zapContract != address(0)) {
            IAetherZap zap = IAetherZap(zapContract);
            try zap.feeBps()          returns (uint256 f) { dash.zapFeeBps          = f; } catch {}
            try zap.keeperRewardBps() returns (uint256 k) { dash.zapKeeperRewardBps = k; } catch {}
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    //
    // Constructor: NONE - no arguments, deploy with empty constructor
    // Stateless: all contract addresses passed per function call
    //
    // Shido Mainnet - pass addresses to each function after deployment:
    //   whaleContract:  WhaleLimitOrders  deployed address
    //   retailContract: RetailLimitOrders deployed address
    //   otcContract:    AetherOTCEscrow   deployed address
    //   fundContract:   AetherFundPool    deployed address
    //   routerContract: AetherOrderRouter deployed address
    //   zapContract:    AetherZap         deployed address
    //   guardContract:  AetherGuard       deployed address
    //   rangeManager:   AetherRangeManager deployed address
    //
    // NOTE: The deployed AetherMulticall Section 6 (limit orders) has a
    //       struct mismatch vs RetailLimitOrders. Use this contract's
    //       getRetailUserOrders() and getFullDashboard() instead.
    // ════════════════════════════════════════════════════════════════════════
}

