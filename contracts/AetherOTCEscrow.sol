// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherOTCEscrow.sol v1.0
//
// PURPOSE: On-chain atomic escrow.
// Without this contract, OTC deals are a scam vector - maker can
// post a deal without owning the tokens, and taker can "fill" without paying.
//
// HOW IT WORKS:
//   Maker posts deal -> deposits tokenIn into contract (tokens locked).
//   Taker fills deal -> deposits tokenOut, gets tokenIn atomically.
//   Neither party can be scammed: swap is atomic.
//
// PARTIAL FILLS:
//   Large OTC blocks (10M CHINA for 50k USDC) can be partially filled.
//   Multiple takers can each fill a portion.
//   Maker gets paid per fill. Remaining tokenIn stays locked.
//
// FEE MODEL:
//   0.3% of tokenOut (payment side) at fill time -> revenueRecipient.
//   No fee on cancelled/expired deals (no service rendered).
//   Maker pays nothing to post - tokens are just locked, not charged.
//
// EXAMPLE:
//   Alice: createDeal(CHINA, 10_000_000e18, USDC, 50_000e6, 7days)
//     -> locks 10M CHINA in contract
//   Bob:   fillDeal(dealId, 2_000_000e18)
//     -> Bob sends 10,000 USDC (2M/10M * 50k USDC)
//     -> Bob receives 2M CHINA
//     -> Alice receives 9,970 USDC (10k - 0.3% fee)
//     -> 30 USDC sent to revenue distributor
//   8M CHINA still locked. Another taker can fill the rest.
//   Alice: cancelDeal(dealId) -> remaining 8M CHINA returned.
//
// SECURITY:
//   - Tokens locked at deal creation (no post-without-tokens scam)
//   - Atomic swap (taker can't take without paying)
//   - Reentrancy guard on all state-changing functions
//   - Balance delta pattern for fee-on-transfer token safety
//   - Admin can cancel any open deal (emergency)
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract AetherOTCEscrow {

    // ─── Fee Config ───────────────────────────────────────────────────────────

    uint256 public feeBps = 30;                    // 0.3% of tokenOut at fill
    uint256 public constant MAX_FEE_BPS = 300;     // 3% hard cap
    uint256 public constant BPS_BASE    = 10000;

    address public owner;
    address public revenueRecipient;
    mapping(address => bool) public admins;

    bool    public paused;
    uint256 private _lock;

    // ─── Deal ─────────────────────────────────────────────────────────────────

    enum DealStatus { Open, Filled, Cancelled, Expired }

    struct Deal {
        uint256     id;
        address     maker;
        address     tokenIn;     // token maker is selling (locked in contract)
        address     tokenOut;    // token maker wants to receive
        uint256     amountIn;    // total tokenIn for sale
        uint256     amountOut;   // total tokenOut expected for full fill
        uint256     amountInFilled;  // tokenIn already transferred to takers
        uint256     amountOutFilled; // tokenOut already received from takers
        uint256     amountInRemaining; // still available for filling
        DealStatus  status;
        uint64      createdAt;
        uint64      deadline;     // unix timestamp; 0 = no deadline
        uint256     minFillAmount; // minimum tokenIn per fill (0 = no minimum)
    }

    uint256 public nextDealId;
    mapping(uint256 => Deal) public deals;
    mapping(address => uint256[]) public makerDeals;

    // Total revenue accrued per token (for distributor to pull)
    mapping(address => uint256) public pendingRevenue;

    // ─── Events ───────────────────────────────────────────────────────────────

    event DealCreated(
        uint256 indexed dealId,
        address indexed maker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint64  deadline,
        uint256 minFillAmount
    );
    event DealFilled(
        uint256 indexed dealId,
        address indexed taker,
        uint256 tokenInAmount,
        uint256 tokenOutGross,
        uint256 tokenOutFee,
        uint256 tokenOutToMaker,
        bool    fullyFilled
    );
    event DealCancelled(uint256 indexed dealId, address indexed maker, uint256 tokenInRefund);
    event DealExpired(uint256 indexed dealId, uint256 tokenInRefund);
    event RevenueCollected(address indexed token, uint256 amount);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner()     { require(msg.sender == owner, "OTC: Not owner"); _; }
    modifier onlyAdmin()     { require(admins[msg.sender] || msg.sender == owner, "OTC: Not admin"); _; }
    modifier nonReentrant()  { require(_lock == 0, "OTC: Reentrant"); _lock = 1; _; _lock = 0; }
    modifier whenNotPaused() { require(!paused, "OTC: Paused"); _; }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _revenueRecipient, uint256 _feeBps) {
        require(_feeBps <= MAX_FEE_BPS, "OTC: Fee too high");
        owner             = msg.sender;
        revenueRecipient  = _revenueRecipient;
        feeBps            = _feeBps;
        admins[msg.sender] = true;
    }

    // ─── createDeal ───────────────────────────────────────────────────────────

    function createDeal(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint64  deadline,
        uint256 minFillAmount
    ) external nonReentrant whenNotPaused returns (uint256 dealId) {
        require(tokenIn != address(0) && tokenOut != address(0), "OTC: Zero addr");
        require(tokenIn != tokenOut,    "OTC: Same token");
        require(amountIn > 0,           "OTC: Zero amountIn");
        require(amountOut > 0,          "OTC: Zero amountOut");
        require(deadline == 0 || deadline > block.timestamp, "OTC: Deadline passed");
        require(minFillAmount == 0 || minFillAmount <= amountIn, "OTC: Min > total");

        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "OTC: Token pull failed");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;
        require(received > 0, "OTC: No tokens received");

        dealId = nextDealId++;
        deals[dealId] = Deal({
            id:                  dealId,
            maker:               msg.sender,
            tokenIn:             tokenIn,
            tokenOut:            tokenOut,
            amountIn:            received,
            amountOut:           amountOut,
            amountInFilled:      0,
            amountOutFilled:     0,
            amountInRemaining:   received,
            status:              DealStatus.Open,
            createdAt:           uint64(block.timestamp),
            deadline:            deadline,
            minFillAmount:       minFillAmount
        });
        makerDeals[msg.sender].push(dealId);

        emit DealCreated(dealId, msg.sender, tokenIn, tokenOut, received, amountOut, deadline, minFillAmount);
    }

    // ─── fillDeal ─────────────────────────────────────────────────────────────

    function fillDeal(uint256 dealId, uint256 tokenInAmount) external nonReentrant whenNotPaused {
        Deal storage deal = deals[dealId];

        require(deal.id == dealId && deal.maker != address(0), "OTC: Not found");
        require(deal.status == DealStatus.Open, "OTC: Not open");
        require(msg.sender != deal.maker, "OTC: Maker can't fill own deal");

        if (deal.deadline > 0 && block.timestamp > deal.deadline) {
            _expireDeal(deal);
            return;
        }

        require(tokenInAmount > 0, "OTC: Zero fill amount");
        require(tokenInAmount <= deal.amountInRemaining, "OTC: Exceeds available");
        require(
            deal.minFillAmount == 0 ||
            tokenInAmount >= deal.minFillAmount ||
            tokenInAmount == deal.amountInRemaining,
            "OTC: Below minimum fill"
        );

        uint256 tokenOutGross = (tokenInAmount * deal.amountOut) / deal.amountIn;
        require(tokenOutGross > 0, "OTC: Zero tokenOut");

        uint256 outBefore = IERC20(deal.tokenOut).balanceOf(address(this));
        require(IERC20(deal.tokenOut).transferFrom(msg.sender, address(this), tokenOutGross), "OTC: Payment pull failed");
        uint256 outReceived = IERC20(deal.tokenOut).balanceOf(address(this)) - outBefore;
        require(outReceived > 0, "OTC: No payment received");

        uint256 actualFee     = (outReceived * feeBps) / BPS_BASE;
        uint256 actualToMaker = outReceived - actualFee;

        deal.amountInFilled    += tokenInAmount;
        deal.amountOutFilled   += outReceived;
        deal.amountInRemaining -= tokenInAmount;

        bool fullyFilled = deal.amountInRemaining == 0;
        if (fullyFilled) deal.status = DealStatus.Filled;

        pendingRevenue[deal.tokenOut] += actualFee;

        require(IERC20(deal.tokenIn).transfer(msg.sender, tokenInAmount), "OTC: TokenIn transfer failed");
        require(IERC20(deal.tokenOut).transfer(deal.maker, actualToMaker), "OTC: Payment to maker failed");

        emit DealFilled(dealId, msg.sender, tokenInAmount, outReceived, actualFee, actualToMaker, fullyFilled);
    }

    // ─── cancelDeal ───────────────────────────────────────────────────────────

    function cancelDeal(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.maker != address(0), "OTC: Not found");
        require(deal.status == DealStatus.Open, "OTC: Not open");
        require(msg.sender == deal.maker || admins[msg.sender], "OTC: Not authorized");

        uint256 refund = deal.amountInRemaining;
        deal.amountInRemaining = 0;
        deal.status = DealStatus.Cancelled;

        if (refund > 0) {
            require(IERC20(deal.tokenIn).transfer(deal.maker, refund), "OTC: Refund failed");
        }

        emit DealCancelled(dealId, deal.maker, refund);
    }

    // ─── expireDeal ───────────────────────────────────────────────────────────

    function expireDeal(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.maker != address(0), "OTC: Not found");
        require(deal.status == DealStatus.Open, "OTC: Not open");
        require(deal.deadline > 0 && block.timestamp > deal.deadline, "OTC: Not expired");
        _expireDeal(deal);
    }

    function _expireDeal(Deal storage deal) internal {
        uint256 refund = deal.amountInRemaining;
        deal.amountInRemaining = 0;
        deal.status = DealStatus.Expired;

        if (refund > 0) {
            require(IERC20(deal.tokenIn).transfer(deal.maker, refund), "OTC: Expire refund failed");
        }

        emit DealExpired(deal.id, refund);
    }

    // ─── Revenue Collection ───────────────────────────────────────────────────

    function collectRevenue(address token) external nonReentrant {
        require(admins[msg.sender] || msg.sender == owner, "OTC: Not authorized");
        uint256 amount = pendingRevenue[token];
        require(amount > 0, "OTC: No revenue");
        pendingRevenue[token] = 0;
        require(IERC20(token).transfer(revenueRecipient, amount), "OTC: Revenue transfer failed");
        emit RevenueCollected(token, amount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getDeal(uint256 dealId) external view returns (Deal memory) {
        return deals[dealId];
    }

    function getMakerDeals(address maker) external view returns (uint256[] memory) {
        return makerDeals[maker];
    }

    function getMakerDealsFull(address maker) external view returns (Deal[] memory result) {
        uint256[] memory ids = makerDeals[maker];
        result = new Deal[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            result[i] = deals[ids[i]];
        }
    }

    function getFillQuote(uint256 dealId, uint256 tokenInAmount) external view returns (
        uint256 tokenOutGross,
        uint256 tokenOutFee,
        uint256 tokenOutToMaker
    ) {
        Deal storage deal = deals[dealId];
        require(deal.amountIn > 0, "OTC: Not found");
        tokenOutGross   = (tokenInAmount * deal.amountOut) / deal.amountIn;
        tokenOutFee     = (tokenOutGross * feeBps) / BPS_BASE;
        tokenOutToMaker = tokenOutGross - tokenOutFee;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "OTC: Fee too high");
        feeBps = _bps;
    }

    function setRevenueRecipient(address r) external onlyOwner { require(r != address(0)); revenueRecipient = r; }
    function setAdmin(address a, bool s) external onlyOwner { admins[a] = s; }
    function setPaused(bool _p) external onlyOwner { paused = _p; }
    function transferOwnership(address n) external onlyOwner { require(n != address(0)); owner = n; }
    function rescueTokens(address t, uint256 a) external onlyOwner { IERC20(t).transfer(owner, a); }
}
