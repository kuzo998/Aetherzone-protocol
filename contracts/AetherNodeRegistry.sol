// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherNodeRegistry.sol v1.3 - Idle DePIN Miner Simulator
//
// PURPOSE: A high-fidelity idle mining simulation game (USDC Miner).
//   - Users purchase "Virtual DePIN Miners" (representing virtual hashrate).
//   - Purchased miners are locked in the contract (cannot be sold back).
//   - Miners generate "Bandwidth Gigabytes" in real-time.
//   - Users can Compound (Re-mine) or Sell (Claim USDC) their Bandwidth.
//   - Referral system: 5% bonus on purchases made by referred users.
//
// BUSINESS MODEL (Self-Sustaining Protocol Loop):
//   - 5% Developer Fee on Buy & Sell (routed to devTreasury).
//   - 5% Platform Fee on Buy & Sell (routed to AetherRevenueDistributor to reward USDC stakers).
//   - Compound transactions charge a reduced 2% Dev Fee and 2% Platform Fee.
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract AetherNodeRegistry {

    // ─── Game Constants ───────────────────────────────────────────────────────

    uint256 private constant GB_TO_VAL_MINERS = 864000; // time in seconds for 1 miner to produce 1 share
    uint256 private constant PSN = 10000;
    uint256 private constant PSNH = 5000;

    address public constant USDC = 0xeE1Fc22381e6B6bb5ee3bf6B5ec58DF6F5480dF8;

    address public owner;
    address public revenueDistributor; // Receives 5% platform fee
    address public devTreasury;         // Receives 5% developer fee

    uint256 public marketBandwidth;    // Game economy state tracker
    bool public paused;
    bool public gameStarted;

    // User Data
    mapping(address => uint256) public miners;          // count of virtual miners owned
    mapping(address => uint256) public claimedBandwidth;// bandwidth shares claimed
    mapping(address => uint256) public lastClaimTime;   // last interaction time
    mapping(address => address) public referrals;       // referrer registry
    mapping(address => uint256) public referralEarnings;// earnings from referrals

    // Statistics
    uint256 public totalDeposits;
    uint256 public totalClaims;
    uint256 public totalCompounds;
    uint256 public totalUsers;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MinersBought(address indexed user, uint256 amountPaid, uint256 minersGained);
    event MinersCompounded(address indexed user, uint256 bandwidthCompounded, uint256 minersGained);
    event BandwidthSold(address indexed user, uint256 bandwidthSold, uint256 usdcReceived);
    event ReferralPaid(address indexed referrer, address indexed referral, uint256 amount);
    event GameStarted();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() { require(msg.sender == owner, "ANR: Not owner"); _; }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _revenueDistributor, address _devTreasury) {
        owner = msg.sender;
        revenueDistributor = _revenueDistributor;
        devTreasury = _devTreasury;
    }

    // ─── Start Game Economy ───────────────────────────────────────────────────

    function startGame() external onlyOwner {
        require(!gameStarted, "ANR: Game already active");
        gameStarted = true;
        marketBandwidth = 86400000000; // Initialize global bandwidth market supply
        emit GameStarted();
    }

    // ─── Compound (Re-mine Bandwidth) ─────────────────────────────────────────

    /**
     * @notice Compound accumulated bandwidth back into more Virtual Miners.
     * @param ref Address of the referrer.
     */
    function compoundMiners(address ref) external {
        require(gameStarted, "ANR: Game not started");
        if (ref == msg.sender || ref == address(0)) {
            ref = owner;
        }
        if (referrals[msg.sender] == address(0) && referrals[msg.sender] != msg.sender) {
            referrals[msg.sender] = ref;
        }

        uint256 bandwidthUsed = getMyBandwidth(msg.sender);
        uint256 newMiners = bandwidthUsed / GB_TO_VAL_MINERS;
        
        miners[msg.sender] += newMiners;
        claimedBandwidth[msg.sender] = 0;
        lastClaimTime[msg.sender] = block.timestamp;

        // Dev/Distributor Compound fees (4% total compound fee)
        uint256 totalCompoundFee = (bandwidthUsed * 400) / 10000;
        marketBandwidth += (bandwidthUsed - totalCompoundFee);

        totalCompounds++;
        emit MinersCompounded(msg.sender, bandwidthUsed, newMiners);
    }

    // ─── Sell (Claim USDC rewards) ────────────────────────────────────────────

    /**
     * @notice Cash out accumulated bandwidth for USDC.
     */
    function sellBandwidth() external {
        require(gameStarted, "ANR: Game not started");
        
        uint256 bandwidth = getMyBandwidth(msg.sender);
        uint256 usdcPayout = calculateBandwidthSell(bandwidth);

        // Fees: 5% Dev, 5% Platform Staking Distributor
        uint256 devFee = (usdcPayout * 500) / 10000;
        uint256 platformFee = (usdcPayout * 500) / 10000;

        claimedBandwidth[msg.sender] = 0;
        lastClaimTime[msg.sender] = block.timestamp;
        marketBandwidth += bandwidth;

        // Transfer fees
        require(IERC20(USDC).transfer(devTreasury, devFee), "ANR: Dev fee payout failed");
        require(IERC20(USDC).transfer(revenueDistributor, platformFee), "ANR: Platform fee payout failed");

        // Transfer payout to user
        uint256 netPayout = usdcPayout - devFee - platformFee;
        require(IERC20(USDC).transfer(msg.sender, netPayout), "ANR: User payout failed");

        totalClaims++;
        totalClaims += netPayout;
        emit BandwidthSold(msg.sender, bandwidth, netPayout);
    }

    // ─── Buy Miners (USDC Deposit) ────────────────────────────────────────────

    /**
     * @notice Purchase Virtual Miners with USDC.
     * @param ref Address of the referrer.
     * @param amount Amount of USDC to spend (6 decimals).
     */
    function buyMiners(address ref, uint256 amount) external {
        require(gameStarted, "ANR: Game not started");
        
        // Pull USDC
        require(
            IERC20(USDC).transferFrom(msg.sender, address(this), amount),
            "ANR: USDC transfer failed"
        );

        if (miners[msg.sender] == 0) {
            totalUsers++;
        }

        // Fees: 5% Dev, 5% Platform Staking Distributor
        uint256 devFee = (amount * 500) / 10000;
        uint256 platformFee = (amount * 500) / 10000;

        require(IERC20(USDC).transfer(devTreasury, devFee), "ANR: Dev fee failed");
        require(IERC20(USDC).transfer(revenueDistributor, platformFee), "ANR: Platform fee failed");

        uint256 netDeposit = amount - devFee - platformFee;
        
        // Calculate miners gained based on current contract balance and market state
        uint256 balance = IERC20(USDC).balanceOf(address(this));
        uint256 bandwidthBought = calculateBandwidthBuy(netDeposit, balance - netDeposit);

        // Referral rewards: 5% to referrer
        if (ref == msg.sender || ref == address(0)) {
            ref = owner;
        }
        if (referrals[msg.sender] == address(0)) {
            referrals[msg.sender] = ref;
        }
        address referrer = referrals[msg.sender];
        uint256 refPayout = (amount * 500) / 10000; // 5% referral fee
        
        // Pay referrer in miners (or directly in USDC if pool allows, but standard is miners/bandwidth boost)
        claimedBandwidth[referrer] += (bandwidthBought * 5) / 100;
        referralEarnings[referrer] += refPayout;
        emit ReferralPaid(referrer, msg.sender, refPayout);

        bandwidthBought += getMyBandwidth(msg.sender);
        uint256 newMiners = bandwidthBought / GB_TO_VAL_MINERS;

        miners[msg.sender] += newMiners;
        claimedBandwidth[msg.sender] = 0;
        lastClaimTime[msg.sender] = block.timestamp;

        marketBandwidth += bandwidthBought;
        totalDeposits += amount;

        emit MinersBought(msg.sender, amount, newMiners);
    }

    // ─── Trade Calculations (Resource Pricing Model) ──────────────────────────

    function calculateTrade(
        uint256 rt,
        uint256 rs,
        uint256 bs
    ) public pure returns (uint256) {
        return (PSN * bs) / (PSNH + (((PSN * rs) + (PSNH * rt)) / rt));
    }

    function calculateBandwidthSell(uint256 bandwidth) public view returns (uint256) {
        uint256 balance = IERC20(USDC).balanceOf(address(this));
        return calculateTrade(bandwidth, marketBandwidth, balance);
    }

    function calculateBandwidthBuy(uint256 eth, uint256 contractBalance) public view returns (uint256) {
        return calculateTrade(eth, contractBalance, marketBandwidth);
    }

    function getMyBandwidth(address adr) public view returns (uint256) {
        return claimedBandwidth[adr] + getBandwidthSinceLastClaim(adr);
    }

    function getBandwidthSinceLastClaim(address adr) public view returns (uint256) {
        if (lastClaimTime[adr] == 0) return 0;
        uint256 elapsed = block.timestamp - lastClaimTime[adr];
        return elapsed * miners[adr];
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getContractBalance() external view returns (uint256) {
        return IERC20(USDC).balanceOf(address(this));
    }

    // ─── Admin Config ─────────────────────────────────────────────────────────

    function setRevenueDistributor(address _distributor) external onlyOwner {
        require(_distributor != address(0));
        revenueDistributor = _distributor;
    }

    function setDevTreasury(address _devTreasury) external onlyOwner {
        require(_devTreasury != address(0));
        devTreasury = _devTreasury;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0));
        owner = newOwner;
    }
}
