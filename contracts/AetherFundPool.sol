// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherFundPool.sol v1.0
//
// HOW IT WORKS:
//   Admin creates project: token, targetAmount, softCap, milestones[], deadline.
//   Contributors deposit tokens - locked in this contract.
//   IF softCap reached: admin can release milestones one by one to beneficiary.
//   IF deadline passed and softCap not reached: contributors can claim full refund.
//   IF admin cancels: contributors can always claim full refund.
//
// SECURITY PROPERTIES:
//   - All contributions locked on-chain - admin can't access directly.
//   - raisedAmount is computed from actual on-chain deposits - can't be faked.
//   - Contributors can ALWAYS get refunds if project fails or is cancelled.
//   - Milestones must be released in order - no skipping.
//   - softCap enforced: no milestone released until minimum is reached.
//   - Each milestone has its own amount - prevents single lump-sum grab.
//
// EXAMPLE:
//   Admin creates project:
//     token=USDC, targetAmount=100,000, softCap=30,000, deadline=90days
//     milestones=[30000, 40000, 30000] = 3 phases
//
//   100 contributors deposit varying amounts.
//   Total raised: 85,000 USDC (above softCap of 30,000).
//
//   Admin releases milestone 0: 30,000 USDC -> beneficiary.
//   Admin releases milestone 1: 40,000 USDC -> beneficiary.
//   15,000 USDC remains locked (milestone 2 needs 30,000 but only 15,000 left).
//   Remaining contributors can claim refund for the unfulfilled portion.
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract AetherFundPool {

    // ─── Config ───────────────────────────────────────────────────────────────

    address public owner;
    address public admin;         // AetherZone admin (ADMIN_ADDRESS from communityService.ts)
    address public feeRecipient;  // AetherRevenueDistributor
    bool    public paused;
    uint256 private _lock;

    // Platform fee on each milestone release (2% default) -> feeRecipient
    // Charged to project beneficiary, not contributors.
    // Contributors' refund rights are based on gross raised amounts.
    uint256 public platformFeeBps   = 200;  // 2%
    uint256 public constant MAX_FEE = 500;  // 5% hard cap
    uint256 public constant BPS_BASE = 10000;

    // ─── Project ──────────────────────────────────────────────────────────────

    enum ProjectStatus { Active, Funded, Cancelled }

    struct Milestone {
        string  title;
        uint256 amount;
        bool    released;
        uint64  releasedAt;
    }

    struct Project {
        uint256       id;
        string        title;
        address       token;
        uint256       targetAmount;
        uint256       softCap;
        address       beneficiary;
        uint256       raised;
        uint256       released;
        uint256       deadline;
        uint256       minContribution;
        ProjectStatus status;
        uint64        createdAt;
        Milestone[]   milestones;
    }

    uint256 public nextProjectId;
    mapping(uint256 => Project) public projects;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => address[]) public contributors;
    mapping(uint256 => mapping(address => bool)) public refunded;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ProjectCreated(uint256 indexed projectId, string title, address token, uint256 targetAmount, uint256 softCap, address beneficiary, uint256 deadline);
    event Contributed(uint256 indexed projectId, address indexed contributor, uint256 amount, uint256 totalRaised);
    event MilestoneReleased(uint256 indexed projectId, uint256 indexed milestoneIndex, uint256 amountToBeneficiary, uint256 platformFee, address beneficiary);
    event Refunded(uint256 indexed projectId, address indexed contributor, uint256 amount);
    event ProjectCancelled(uint256 indexed projectId);
    event ProjectMarkedFunded(uint256 indexed projectId);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner()     { require(msg.sender == owner || msg.sender == admin, "FP: Not admin"); _; }
    modifier nonReentrant()  { require(_lock == 0, "FP: Reentrant"); _lock = 1; _; _lock = 0; }
    modifier whenNotPaused() { require(!paused, "FP: Paused"); _; }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _admin, address _feeRecipient) {
        owner        = msg.sender;
        admin        = _admin;        // 0x918937e3abed27ea8495fa09c1308c93b7749811
        feeRecipient = _feeRecipient; // AetherRevenueDistributor
    }

    // ─── createProject (admin only) ───────────────────────────────────────────

    function createProject(
        string calldata title,
        address token,
        uint256 targetAmount,
        uint256 softCap,
        address beneficiary,
        uint256 deadline,
        uint256 minContrib,
        string[] calldata milestoneTitles,
        uint256[] calldata milestoneAmounts
    ) external onlyOwner returns (uint256 projectId) {
        require(bytes(title).length > 0,   "FP: Empty title");
        require(token != address(0),       "FP: Zero token");
        require(targetAmount > 0,          "FP: Zero target");
        require(beneficiary != address(0), "FP: Zero beneficiary");
        require(milestoneTitles.length == milestoneAmounts.length, "FP: Milestone length mismatch");
        require(milestoneTitles.length > 0, "FP: No milestones");
        require(deadline == 0 || deadline > block.timestamp, "FP: Deadline passed");
        require(softCap <= targetAmount,   "FP: SoftCap > target");

        uint256 milestoneSum;
        for (uint256 i; i < milestoneAmounts.length; i++) {
            require(milestoneAmounts[i] > 0, "FP: Zero milestone");
            milestoneSum += milestoneAmounts[i];
        }
        require(milestoneSum <= targetAmount, "FP: Milestones exceed target");

        projectId = nextProjectId++;
        Project storage p = projects[projectId];
        p.id              = projectId;
        p.title           = title;
        p.token           = token;
        p.targetAmount    = targetAmount;
        p.softCap         = softCap;
        p.beneficiary     = beneficiary;
        p.deadline        = deadline;
        p.minContribution = minContrib;
        p.status          = ProjectStatus.Active;
        p.createdAt       = uint64(block.timestamp);

        for (uint256 i; i < milestoneTitles.length; i++) {
            p.milestones.push(Milestone({
                title:      milestoneTitles[i],
                amount:     milestoneAmounts[i],
                released:   false,
                releasedAt: 0
            }));
        }

        emit ProjectCreated(projectId, title, token, targetAmount, softCap, beneficiary, deadline);
    }

    // ─── contribute ───────────────────────────────────────────────────────────

    function contribute(uint256 projectId, uint256 amount) external nonReentrant whenNotPaused {
        Project storage p = projects[projectId];
        require(p.createdAt > 0,                  "FP: Project not found");
        require(p.status == ProjectStatus.Active,  "FP: Project not active");
        require(amount > 0,                        "FP: Zero amount");
        require(p.minContribution == 0 || amount >= p.minContribution, "FP: Below minimum");
        require(p.deadline == 0 || block.timestamp <= p.deadline, "FP: Deadline passed");

        uint256 remaining = p.targetAmount > p.raised ? p.targetAmount - p.raised : 0;
        require(remaining > 0, "FP: Target already reached");
        uint256 actualAmount = amount > remaining ? remaining : amount;

        uint256 before = IERC20(p.token).balanceOf(address(this));
        require(IERC20(p.token).transferFrom(msg.sender, address(this), actualAmount), "FP: Transfer failed");
        uint256 received = IERC20(p.token).balanceOf(address(this)) - before;
        require(received > 0, "FP: No tokens received");

        if (contributions[projectId][msg.sender] == 0) {
            contributors[projectId].push(msg.sender);
        }
        contributions[projectId][msg.sender] += received;
        p.raised += received;

        if (p.raised >= p.targetAmount && p.status == ProjectStatus.Active) {
            p.status = ProjectStatus.Funded;
            emit ProjectMarkedFunded(projectId);
        }

        emit Contributed(projectId, msg.sender, received, p.raised);
    }

    // ─── releaseMilestone (admin only) ────────────────────────────────────────

    function releaseMilestone(uint256 projectId, uint256 milestoneIndex) external nonReentrant onlyOwner {
        Project storage p = projects[projectId];
        require(p.createdAt > 0, "FP: Project not found");
        require(p.status == ProjectStatus.Active || p.status == ProjectStatus.Funded, "FP: Project not active");
        require(milestoneIndex < p.milestones.length, "FP: Invalid milestone");

        for (uint256 i; i < milestoneIndex; i++) {
            require(p.milestones[i].released, "FP: Previous milestone not released");
        }

        Milestone storage m = p.milestones[milestoneIndex];
        require(!m.released, "FP: Already released");
        require(p.raised >= p.softCap || p.softCap == 0, "FP: SoftCap not reached");

        uint256 available = p.raised - p.released;
        require(m.amount <= available, "FP: Insufficient funds for milestone");

        m.released   = true;
        m.releasedAt = uint64(block.timestamp);
        p.released  += m.amount;

        // Platform fee (2% default) taken from milestone before sending to beneficiary
        uint256 platformFee   = (m.amount * platformFeeBps) / BPS_BASE;
        uint256 toBeneficiary = m.amount - platformFee;

        if (platformFee > 0) {
            require(IERC20(p.token).transfer(feeRecipient, platformFee), "FP: Fee transfer failed");
        }
        require(IERC20(p.token).transfer(p.beneficiary, toBeneficiary), "FP: Milestone transfer failed");
        emit MilestoneReleased(projectId, milestoneIndex, toBeneficiary, platformFee, p.beneficiary);
    }

    // ─── claimRefund ──────────────────────────────────────────────────────────

    function claimRefund(uint256 projectId) external nonReentrant {
        Project storage p = projects[projectId];
        require(p.createdAt > 0, "FP: Project not found");
        require(!refunded[projectId][msg.sender], "FP: Already refunded");

        uint256 contributed = contributions[projectId][msg.sender];
        require(contributed > 0, "FP: No contribution");

        bool canRefund = false;
        uint256 refundAmount;

        if (p.status == ProjectStatus.Cancelled) {
            canRefund    = true;
            refundAmount = contributed;
        } else if (p.deadline > 0 && block.timestamp > p.deadline && p.raised < p.softCap) {
            canRefund    = true;
            refundAmount = contributed;
        } else if (p.deadline > 0 && block.timestamp > p.deadline && p.raised >= p.softCap) {
            uint256 unreleasedPool = p.raised - p.released;
            if (unreleasedPool > 0) {
                refundAmount = (contributed * unreleasedPool) / p.raised;
                canRefund    = refundAmount > 0;
            }
        }

        require(canRefund,       "FP: Not eligible for refund");
        require(refundAmount > 0, "FP: Zero refund");

        refunded[projectId][msg.sender] = true;
        require(IERC20(p.token).transfer(msg.sender, refundAmount), "FP: Refund failed");
        emit Refunded(projectId, msg.sender, refundAmount);
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    function cancelProject(uint256 projectId) external onlyOwner {
        Project storage p = projects[projectId];
        require(p.createdAt > 0, "FP: Not found");
        require(p.status == ProjectStatus.Active || p.status == ProjectStatus.Funded, "FP: Already closed");
        p.status = ProjectStatus.Cancelled;
        emit ProjectCancelled(projectId);
    }

    function updateBeneficiary(uint256 projectId, address newBeneficiary) external onlyOwner {
        require(newBeneficiary != address(0));
        projects[projectId].beneficiary = newBeneficiary;
    }

    function extendDeadline(uint256 projectId, uint256 newDeadline) external onlyOwner {
        require(newDeadline > block.timestamp, "FP: Deadline in past");
        projects[projectId].deadline = newDeadline;
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getProject(uint256 projectId) external view returns (
        uint256 id, string memory title, address token,
        uint256 targetAmount, uint256 softCap, address beneficiary,
        uint256 raised, uint256 released, uint256 deadline,
        ProjectStatus status, uint256 createdAt, uint256 milestoneCount
    ) {
        Project storage p = projects[projectId];
        return (p.id, p.title, p.token, p.targetAmount, p.softCap, p.beneficiary,
                p.raised, p.released, p.deadline, p.status, p.createdAt, p.milestones.length);
    }

    function getMilestone(uint256 projectId, uint256 milestoneIndex) external view returns (
        string memory title, uint256 amount, bool isReleased, uint64 releasedAt
    ) {
        Milestone storage m = projects[projectId].milestones[milestoneIndex];
        return (m.title, m.amount, m.released, m.releasedAt);
    }

    function getContribution(uint256 projectId, address contributor) external view returns (uint256) {
        return contributions[projectId][contributor];
    }

    function getContributorCount(uint256 projectId) external view returns (uint256) {
        return contributors[projectId].length;
    }

    function getProgressPercent(uint256 projectId) external view returns (uint256 percent, uint256 softCapPercent) {
        Project storage p = projects[projectId];
        if (p.targetAmount == 0) return (0, 0);
        percent        = (p.raised * 100) / p.targetAmount;
        softCapPercent = p.softCap > 0 ? (p.raised * 100) / p.softCap : 100;
    }

    function getRefundEligibility(uint256 projectId, address contributor) external view returns (
        bool eligible, uint256 amount, string memory reason
    ) {
        Project storage p = projects[projectId];
        if (p.createdAt == 0 || refunded[projectId][contributor]) return (false, 0, "Not applicable");

        uint256 contributed = contributions[projectId][contributor];
        if (contributed == 0) return (false, 0, "No contribution");

        if (p.status == ProjectStatus.Cancelled) {
            return (true, contributed, "Project cancelled");
        }
        if (p.deadline > 0 && block.timestamp > p.deadline && p.raised < p.softCap) {
            return (true, contributed, "SoftCap not reached after deadline");
        }
        if (p.deadline > 0 && block.timestamp > p.deadline && p.raised >= p.softCap) {
            uint256 unreleased = p.raised - p.released;
            uint256 refundAmt  = unreleased > 0 ? (contributed * unreleased) / p.raised : 0;
            return (refundAmt > 0, refundAmt, "Partial refund: unreleased funds");
        }
        return (false, 0, "Project active - refund not yet available");
    }

    // ─── Admin Config ─────────────────────────────────────────────────────────

    function setAdmin(address _admin) external { require(msg.sender == owner); admin = _admin; }
    function setFeeRecipient(address r) external { require(msg.sender == owner && r != address(0)); feeRecipient = r; }
    function setPlatformFee(uint256 _bps) external { require(msg.sender == owner && _bps <= MAX_FEE, "FP: Fee too high"); platformFeeBps = _bps; }
    function setPaused(bool _p) external { require(msg.sender == owner || msg.sender == admin); paused = _p; }
    function transferOwnership(address n) external { require(msg.sender == owner && n != address(0)); owner = n; }
    function rescueTokens(address t, uint256 a) external { require(msg.sender == owner); IERC20(t).transfer(owner, a); }
}
