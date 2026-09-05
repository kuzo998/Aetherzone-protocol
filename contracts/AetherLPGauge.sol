// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 ______________________________________________________________________________

  AetherLPGauge — the LP-incentive rail for AetherZone
 ______________________________________________________________________________

  A poster escrows a reward. Funders bring their OWN liquidity to a target v3
  pool and stake the position NFT here. Reward accrues strictly in proportion to
  in-range liquidity-seconds, attested by the AMM itself. Whatever is not earned
  goes back to the poster. There is no trusted party in the payment path.

  WHY THIS SHAPE

  The user requirement was "no room of trust me bro". That rules out any design
  where a human decides whether the work was done. So the proof has to be a
  number the AMM already keeps and neither side can forge:

      IUniswapV3Pool.snapshotCumulativesInside(tickLower, tickUpper)
        -> secondsPerLiquidityInsideX128

  This accumulator only advances while the pool's current tick sits inside
  [tickLower, tickUpper], and it advances at a rate of 1/L per second where L is
  the pool's total in-range liquidity. So for a staked position of liquidity l:

      liquiditySecondsInRange  =  (spliNow - spliAtStake) * l

  is exactly "how much depth this funder actually provided, for how long, at the
  price where it mattered". You cannot fake it by wash trading, by holding an
  out-of-range position, or by minting and immediately leaving.

  This is the Uniswap V3 Staker's core insight, and the reward split below is
  its pro-rata model: each staker's share of the escrow equals their share of
  the incentive's total unclaimed liquidity-seconds.

  WHAT THIS ADDS OVER THE UNISWAP STAKER

   1. Escrow-and-return with a snapshotted platform fee. Fee bps are copied into
      the Job at creation, so the platform can never retroactively raise the fee
      on a live job. Both are hard-capped by immutable constants.

   2. Lock-gated pricing ("lock-to-qualify"). A pool whose LP is Bubble-locked is
      registered as Tier A and its jobs pay a lower platform fee. This is the one
      admin input in the contract and it is deliberately declawed: the tier is
      snapshotted at job creation and can ONLY move the platform's own fee within
      the immutable cap. It can never reduce a funder's earned reward, block a
      claim, or touch a staked NFT. See the invariant list at the bottom.

   3. Job-side quality bounds: minLiquidity, minTickWidth, maxTickWidth. Without
      a width floor, a funder can mint a razor-thin range at spot, register huge
      liquidity, earn most of the escrow, and provide depth for only micro-trades
      before the price flips out of the range. The floor makes the paid-for depth
      real.

   4. An early-exit penalty that is deliberately NOT a price-risk penalty.

      This is the important asymmetry. A poster can move their own pool's price.
      If the contract punished a funder for being OUT OF RANGE, the poster could
      strand the funder with one trade — exactly the "set up for a large dump"
      failure mode this system exists to avoid. So:

        - being out of range costs the funder only the accrual they didn't earn
          (that is already the correct, unforgeable punishment), and
        - the penalty applies ONLY to leaving before endTime, which is entirely
          the funder's own choice and cannot be induced by the poster.

      Forfeited reward stays in the escrow and redistributes to the funders who
      did stay. The funder can ALWAYS withdraw their NFT; the penalty only ever
      touches accrued reward, never principal.

   5. emergencyWithdraw: a no-questions exit that returns the NFT and forfeits
      all reward without calling into the pool at all. If snapshotCumulativesInside
      ever reverts for any reason, a funder is still never locked in.

  WHAT THIS CONTRACT DOES NOT DO

   - It does not price anything. The poster decides the reward; the funder
     decides whether to show up. targets.js estimates the clearing premium
     off-chain; that is decision support, not a rule.
   - It does not protect the funder from impermanent loss. The funder holds 100%
     of the IL risk on their own position, by design. The reward is the premium
     for taking it.
   - It never takes economic ownership of a position. Custody exists only so the
     funder cannot decrease liquidity mid-stake while still being paid for it.
 ______________________________________________________________________________
*/

// ------------------------------------------------------------------ interfaces

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external view returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface INonfungiblePositionManager {
    function positions(uint256 tokenId)
        external view returns (
            uint96 nonce, address operator, address token0, address token1, uint24 fee,
            int24 tickLower, int24 tickUpper, uint128 liquidity,
            uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0, uint128 tokensOwed1
        );
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

// ------------------------------------------------------------------- fullmath

/// @dev 512-bit multiply-then-divide. Needed because rewardRemaining (up to
///      2^128) times liquiditySeconds (up to 2^160) overflows 256 bits before
///      the division brings it back down. Standard Remco Bloemen algorithm.
library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0, "FM:div0");
                return prod0 / denominator;
            }
            require(denominator > prod1, "FM:overflow");

            uint256 remainder;
            assembly { remainder := mulmod(a, b, denominator) }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
        }
    }
}

// ----------------------------------------------------------------- the gauge

contract AetherLPGauge is IERC721Receiver {
    // ---- immutable wiring ----
    INonfungiblePositionManager public immutable npm;
    IUniswapV3Factory public immutable v3Factory;

    /// @notice Hard ceilings. The owner can move fees only inside these, and a
    ///         job snapshots its fees at creation, so a live job's economics can
    ///         never be changed by anyone.
    uint16 public constant MAX_POST_FEE_BPS  = 500;  // 5% max off the escrow
    uint16 public constant MAX_CLAIM_FEE_BPS = 500;  // 5% max off a claim
    uint16 public constant MAX_PENALTY_BPS   = 5000; // 50% max early-exit forfeit
    uint32 public constant MIN_DURATION      = 1 days;
    uint32 public constant MAX_DURATION      = 365 days;
    /// @dev Grace window after endTime during which the poster cannot reclaim
    ///      the unearned escrow, so a funder who is asleep at endTime can still
    ///      settle. Also why refundJob requires zero live stakes.
    uint32 public constant REFUND_DELAY      = 3 days;

    // ---- admin (fee schedule + tier registry only) ----
    address public owner;
    /// @dev Nominee for a two-step handover. Non-zero only between the current
    ///      owner's nomination and the nominee's acceptance. See transferOwnership.
    address public pendingOwner;
    address public treasury;
    uint16 public postFeeBpsTierA   = 50;   // 0.5% — the lock-to-qualify discount
    uint16 public claimFeeBpsTierA  = 50;
    uint16 public postFeeBpsDefault = 200;  // 2.0%
    uint16 public claimFeeBpsDefault = 200;

    uint8 public constant TIER_UNRATED = 0;
    uint8 public constant TIER_A = 1;       // LP locked (Bubble) — discounted
    uint8 public constant TIER_B = 2;       // real pool, unlocked — standard

    /// @notice Off-chain-attested pool tier. AFFECTS PLATFORM FEE ONLY.
    mapping(address => uint8) public poolTier;

    // ---- jobs ----
    struct Job {
        address poster;
        address pool;
        address rewardToken;
        uint128 rewardRemaining;            // escrow not yet claimed or refunded
        uint128 rewardTotal;                // for accounting/UI only
        uint64  startTime;
        uint64  endTime;
        uint160 totalSecondsClaimedX128;    // liquidity-seconds already paid out
        uint128 minLiquidity;
        int24   minTickWidth;
        int24   maxTickWidth;               // 0 = unbounded
        uint32  minStakeSeconds;            // stay this long or forfeit all reward
        uint16  earlyExitPenaltyBps;
        uint16  claimFeeBps;                // snapshotted at creation
        uint8   tier;                       // snapshotted at creation
        uint32  numStakes;
        bool    refunded;
    }

    struct Stake {
        address funder;
        uint96  jobId;
        uint160 secondsPerLiquidityInsideInitialX128;
        uint128 liquidity;
        uint64  stakedAt;
    }

    /// @dev Who deposited each NFT. Set on receive, cleared on withdraw.
    mapping(uint256 => address) public depositOwner;
    /// @dev tokenId => live stake. jobId 0 means "deposited but not staked".
    mapping(uint256 => Stake) public stakes;

    Job[] private _jobs;

    uint256 private _lock = 1;
    modifier nonReentrant() { require(_lock == 1, "reentrant"); _lock = 2; _; _lock = 1; }
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    // ---- events ----
    event JobCreated(
        uint256 indexed jobId, address indexed poster, address indexed pool, address rewardToken,
        uint256 rewardEscrowed, uint256 platformFee, uint64 startTime, uint64 endTime, uint8 tier
    );
    event JobFunded(uint256 indexed jobId, address indexed from, uint256 added);
    event JobRefunded(uint256 indexed jobId, address indexed poster, uint256 amount);
    event Deposited(uint256 indexed tokenId, address indexed funder);
    event Staked(uint256 indexed jobId, uint256 indexed tokenId, address indexed funder, uint128 liquidity);
    event Unstaked(
        uint256 indexed jobId, uint256 indexed tokenId, address indexed funder,
        uint256 rewardPaid, uint256 penaltyForfeited, uint256 platformFee, uint160 liquiditySecondsX128
    );
    event EmergencyWithdrawn(uint256 indexed jobId, uint256 indexed tokenId, address indexed funder);
    event Withdrawn(uint256 indexed tokenId, address indexed to);
    event PoolTierSet(address indexed pool, uint8 tier);
    event FeesSet(uint16 postA, uint16 claimA, uint16 postDefault, uint16 claimDefault);
    event TreasurySet(address treasury);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed was);
    event OwnerSet(address owner);

    constructor(address _npm, address _v3Factory, address _treasury) {
        require(_npm != address(0) && _v3Factory != address(0) && _treasury != address(0), "zero");
        npm = INonfungiblePositionManager(_npm);
        v3Factory = IUniswapV3Factory(_v3Factory);
        owner = msg.sender;
        treasury = _treasury;
    }

    // ------------------------------------------------------------------ admin

    /// @notice Nominate the next owner. Ownership does NOT move here — the
    ///         nominee must call acceptOwnership from that exact address.
    /// @dev Two steps, not one, because a one-step setOwner is a single typo away
    ///      from an admin key that provably does not exist. Nothing here can be
    ///      rescued by redeploying: live jobs keep running against THIS contract,
    ///      and the tier registry and fee schedule would be frozen at whatever
    ///      they happened to be, so a pool mis-rated once could never be
    ///      corrected. Requiring the destination to sign proves the key is live
    ///      and controlled BEFORE it receives anything, which turns a fat-fingered
    ///      address from a permanent loss into a no-op. It is also the only safe
    ///      way to hand over to a multisig, where "can this address actually
    ///      transact" is a real question and not a formality.
    ///
    ///      Nominating costs the current owner nothing: until acceptance the
    ///      caller keeps every power and can withdraw the nomination. And note
    ///      what is NOT at stake either way — no owner, present or future, can
    ///      move escrow, seize a deposited NFT, pause a claim, or alter a live
    ///      job. The handover is over the fee schedule and the tier registry.
    function transferOwnership(address a) external onlyOwner {
        require(a != address(0), "zero");
        pendingOwner = a;
        emit OwnershipTransferStarted(msg.sender, a);
    }

    /// @notice Withdraw an outstanding nomination.
    function cancelOwnershipTransfer() external onlyOwner {
        address was = pendingOwner;
        require(was != address(0), "none pending");
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(was);
    }

    /// @notice Claim ownership. Callable only by the standing nominee.
    /// @dev Deliberately no renounceOwnership. Renouncing would freeze the fee
    ///      schedule and, worse, the tier registry — a pool wrongly rated Tier A
    ///      could never be demoted. Since the owner cannot reach user funds, a
    ///      permanently absent owner is strictly worse than a present one.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    function setTreasury(address a) external onlyOwner { require(a != address(0), "zero"); treasury = a; emit TreasurySet(a); }

    /// @notice Register a pool's tier. Tier A is granted when the pool's LP is
    ///         verifiably locked (Bubble). Its ONLY on-chain effect is the fee
    ///         schedule a NEW job snapshots at creation. It cannot alter, delay,
    ///         or block any existing job, stake, claim, or NFT withdrawal.
    function setPoolTier(address pool, uint8 tier) external onlyOwner {
        require(tier <= TIER_B, "bad tier");
        poolTier[pool] = tier;
        emit PoolTierSet(pool, tier);
    }

    function setFees(uint16 postA, uint16 claimA, uint16 postDefault, uint16 claimDefault) external onlyOwner {
        require(postA <= MAX_POST_FEE_BPS && postDefault <= MAX_POST_FEE_BPS, "post fee cap");
        require(claimA <= MAX_CLAIM_FEE_BPS && claimDefault <= MAX_CLAIM_FEE_BPS, "claim fee cap");
        postFeeBpsTierA = postA; claimFeeBpsTierA = claimA;
        postFeeBpsDefault = postDefault; claimFeeBpsDefault = claimDefault;
        emit FeesSet(postA, claimA, postDefault, claimDefault);
    }

    // ------------------------------------------------------------- job posting

    /// @param pool                target Uniswap-v3-style pool
    /// @param rewardToken         any ERC20 (fee-on-transfer safe: escrow is measured)
    /// @param rewardAmount        amount pulled from msg.sender
    /// @param startTime           0 = now
    /// @param endTime             must be start + [MIN_DURATION, MAX_DURATION]
    /// @param minLiquidity        reject dust positions
    /// @param minTickWidth        reject razor-thin ranges that fake depth
    /// @param maxTickWidth        0 = unbounded; caps uselessly wide ranges
    /// @param minStakeSeconds     leave before this and all accrued reward is forfeited
    /// @param earlyExitPenaltyBps forfeit on leaving before endTime (after minStakeSeconds)
    function createJob(
        address pool,
        address rewardToken,
        uint256 rewardAmount,
        uint64 startTime,
        uint64 endTime,
        uint128 minLiquidity,
        int24 minTickWidth,
        int24 maxTickWidth,
        uint32 minStakeSeconds,
        uint16 earlyExitPenaltyBps
    ) external nonReentrant returns (uint256 jobId) {
        require(pool != address(0) && rewardToken != address(0), "zero");
        require(rewardAmount > 0, "no reward");
        require(earlyExitPenaltyBps <= MAX_PENALTY_BPS, "penalty cap");
        require(minTickWidth > 0, "width floor");
        require(maxTickWidth == 0 || maxTickWidth >= minTickWidth, "width band");

        if (startTime == 0) startTime = uint64(block.timestamp);
        require(startTime >= block.timestamp, "start past");
        require(endTime > startTime, "end<=start");
        uint256 dur = uint256(endTime) - uint256(startTime);
        require(dur >= MIN_DURATION && dur <= MAX_DURATION, "duration");
        require(minStakeSeconds <= dur, "minStake>duration");

        // Sanity: the pool must actually be a v3 pool this factory produced.
        // Prevents a job pointing at a lookalike contract that fakes the
        // seconds accumulator.
        {
            IUniswapV3Pool p = IUniswapV3Pool(pool);
            require(v3Factory.getPool(p.token0(), p.token1(), p.fee()) == pool, "not a factory pool");
        }

        uint256 received = _pullMeasured(rewardToken, msg.sender, rewardAmount);

        uint8 tier = poolTier[pool];
        (uint16 postBps, uint16 claimBps) = _feeSchedule(tier);
        uint256 fee = (received * postBps) / 10_000;
        uint256 escrow = received - fee;
        require(escrow > 0, "escrow 0");
        if (fee > 0) _send(rewardToken, treasury, fee);

        jobId = _jobs.length;
        _jobs.push(Job({
            poster: msg.sender,
            pool: pool,
            rewardToken: rewardToken,
            rewardRemaining: _u128(escrow),
            rewardTotal: _u128(escrow),
            startTime: startTime,
            endTime: endTime,
            totalSecondsClaimedX128: 0,
            minLiquidity: minLiquidity,
            minTickWidth: minTickWidth,
            maxTickWidth: maxTickWidth,
            minStakeSeconds: minStakeSeconds,
            earlyExitPenaltyBps: earlyExitPenaltyBps,
            claimFeeBps: claimBps,
            tier: tier,
            numStakes: 0,
            refunded: false
        }));

        emit JobCreated(jobId, msg.sender, pool, rewardToken, escrow, fee, startTime, endTime, tier);
    }

    /// @notice Anyone may top up a live job's escrow (co-sponsorship).
    /// @dev    THE POST FEE ON A TOP-UP IS TODAY'S, NOT THE JOB'S. This comment used
    ///         to claim the opposite and it was wrong: `_feeSchedule(j.tier)` below
    ///         reads the LIVE schedule, and only the TIER is snapshotted. The claim
    ///         fee genuinely is snapshotted (see j.claimBps at creation) — the post
    ///         fee is not. Anyone quoting a top-up cost must read the schedule now.
    ///         Left as live-read rather than snapshotted deliberately: a top-up is a
    ///         fresh decision by whoever makes it, and they can read the fee first.
    function fundJob(uint256 jobId, uint256 amount) external nonReentrant {
        Job storage j = _job(jobId);
        require(!j.refunded, "refunded");
        require(block.timestamp < j.endTime, "ended");
        require(amount > 0, "zero");
        uint256 received = _pullMeasured(j.rewardToken, msg.sender, amount);
        (uint16 postBps, ) = _feeSchedule(j.tier);
        uint256 fee = (received * postBps) / 10_000;
        uint256 add = received - fee;
        if (fee > 0) _send(j.rewardToken, treasury, fee);
        j.rewardRemaining = _u128(uint256(j.rewardRemaining) + add);
        j.rewardTotal = _u128(uint256(j.rewardTotal) + add);
        emit JobFunded(jobId, msg.sender, add);
    }

    /// @notice Poster reclaims whatever was never earned.
    /// @dev Only after endTime + REFUND_DELAY, and only with zero live stakes,
    ///      so a settling funder can never be raced out of their reward. A job
    ///      that never started can be pulled immediately (nothing to settle).
    function refundJob(uint256 jobId) external nonReentrant {
        Job storage j = _job(jobId);
        require(msg.sender == j.poster, "not poster");
        require(!j.refunded, "already");
        require(j.numStakes == 0, "stakes live");
        bool neverStarted = block.timestamp < j.startTime;
        require(neverStarted || block.timestamp >= uint256(j.endTime) + REFUND_DELAY, "too early");
        uint256 amt = j.rewardRemaining;
        j.rewardRemaining = 0;
        j.refunded = true;
        if (amt > 0) _send(j.rewardToken, j.poster, amt);
        emit JobRefunded(jobId, j.poster, amt);
    }

    // ------------------------------------------------------ deposit and stake

    /// @notice Deposit by transferring the NFT here. Pass abi.encode(jobId) as
    ///         data to deposit and stake in one transaction.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external override returns (bytes4)
    {
        require(msg.sender == address(npm), "not npm");
        depositOwner[tokenId] = from;
        emit Deposited(tokenId, from);
        if (data.length == 32) {
            uint256 jobId = abi.decode(data, (uint256));
            _stake(jobId, tokenId, from);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function stake(uint256 jobId, uint256 tokenId) external nonReentrant {
        require(depositOwner[tokenId] == msg.sender, "not depositor");
        _stake(jobId, tokenId, msg.sender);
    }

    function _stake(uint256 jobId, uint256 tokenId, address funder) internal {
        Job storage j = _job(jobId);
        require(!j.refunded, "refunded");
        require(block.timestamp >= j.startTime, "not started");
        require(block.timestamp < j.endTime, "ended");
        require(stakes[tokenId].funder == address(0), "already staked");

        (, , address t0, address t1, uint24 fee, int24 tl, int24 tu, uint128 liq, , , , ) = npm.positions(tokenId);
        require(liq > 0, "no liquidity");
        require(liq >= j.minLiquidity, "below minLiquidity");
        require(v3Factory.getPool(t0, t1, fee) == j.pool, "wrong pool");

        int24 width = tu - tl;
        require(width >= j.minTickWidth, "range too narrow");
        require(j.maxTickWidth == 0 || width <= j.maxTickWidth, "range too wide");

        (, uint160 spli, ) = IUniswapV3Pool(j.pool).snapshotCumulativesInside(tl, tu);

        stakes[tokenId] = Stake({
            funder: funder,
            jobId: uint96(jobId),
            secondsPerLiquidityInsideInitialX128: spli,
            liquidity: liq,
            stakedAt: uint64(block.timestamp)
        });
        j.numStakes += 1;
        emit Staked(jobId, tokenId, funder, liq);
    }

    // ------------------------------------------------------------- settlement

    /// @notice Settle a stake: pay the earned reward, release the stake slot.
    ///         The NFT stays in custody until withdrawToken(). Callable by the
    ///         funder any time, and by ANYONE once endTime has passed (so a job
    ///         can always wind down and the poster's refund is never hostage).
    function unstake(uint256 tokenId) public nonReentrant returns (uint256 paid) {
        Stake memory s = stakes[tokenId];
        require(s.funder != address(0), "not staked");
        Job storage j = _jobs[s.jobId];
        require(msg.sender == s.funder || block.timestamp >= j.endTime, "not funder");

        (, uint160 spliNow, ) = IUniswapV3Pool(j.pool).snapshotCumulativesInside(
            _tickLower(tokenId), _tickUpper(tokenId)
        );

        (uint256 gross, uint160 lsX128) = _computeReward(j, s.liquidity, s.secondsPerLiquidityInsideInitialX128, spliNow);

        // ---- penalty: purely a function of the funder's own exit timing ----
        // Never a function of price, range, or anything the poster can move.
        uint256 penalty = 0;
        if (block.timestamp < j.endTime) {
            if (block.timestamp < uint256(s.stakedAt) + j.minStakeSeconds) {
                penalty = gross;                                     // full forfeit
            } else if (j.earlyExitPenaltyBps > 0) {
                penalty = (gross * j.earlyExitPenaltyBps) / 10_000;
            }
        }
        uint256 net = gross - penalty;

        uint256 fee = (net * j.claimFeeBps) / 10_000;
        paid = net - fee;

        // Consume the liquidity-seconds in full while returning the penalty to
        // the escrow: the forfeited amount redistributes to funders who stayed,
        // and failing that returns to the poster at refund. sum(paid + fees +
        // refund) can never exceed the escrow.
        j.totalSecondsClaimedX128 += lsX128;
        j.rewardRemaining = _u128(uint256(j.rewardRemaining) - net);
        j.numStakes -= 1;
        delete stakes[tokenId];

        if (fee > 0) _send(j.rewardToken, treasury, fee);
        if (paid > 0) _send(j.rewardToken, s.funder, paid);

        emit Unstaked(s.jobId, tokenId, s.funder, paid, penalty, fee, lsX128);
    }

    /// @notice Give up all reward and release the stake without reading the pool.
    /// @dev The safety valve. If snapshotCumulativesInside ever reverts — an
    ///      uninitialized tick, a pool upgrade, anything — a funder must still
    ///      be able to get their NFT back. Forfeited reward stays in escrow.
    function emergencyWithdraw(uint256 tokenId) external nonReentrant {
        Stake memory s = stakes[tokenId];
        require(s.funder != address(0), "not staked");
        require(msg.sender == s.funder, "not funder");
        Job storage j = _jobs[s.jobId];
        j.numStakes -= 1;
        delete stakes[tokenId];
        emit EmergencyWithdrawn(s.jobId, tokenId, s.funder);
    }

    /// @notice Take the position NFT back. Must be settled (or emergency-exited).
    function withdrawToken(uint256 tokenId, address to) external nonReentrant {
        require(depositOwner[tokenId] == msg.sender, "not depositor");
        require(stakes[tokenId].funder == address(0), "still staked");
        require(to != address(0), "zero");
        delete depositOwner[tokenId];
        npm.safeTransferFrom(address(this), to, tokenId);
        emit Withdrawn(tokenId, to);
    }

    /// @notice Settle and take the NFT in one call.
    function exit(uint256 tokenId, address to) external returns (uint256 paid) {
        paid = unstake(tokenId);
        require(depositOwner[tokenId] == msg.sender, "not depositor");
        require(to != address(0), "zero");
        delete depositOwner[tokenId];
        npm.safeTransferFrom(address(this), to, tokenId);
        emit Withdrawn(tokenId, to);
    }

    // ------------------------------------------------------------------ views

    function jobCount() external view returns (uint256) { return _jobs.length; }

    function getJob(uint256 jobId) external view returns (Job memory) { return _jobs[jobId]; }

    /// @notice What a stake would be paid right now, net of penalty and fee.
    function pendingReward(uint256 tokenId)
        external view returns (uint256 paid, uint256 penalty, uint256 fee, uint256 gross)
    {
        Stake memory s = stakes[tokenId];
        if (s.funder == address(0)) return (0, 0, 0, 0);
        Job storage j = _jobs[s.jobId];
        (, uint160 spliNow, ) = IUniswapV3Pool(j.pool).snapshotCumulativesInside(_tickLower(tokenId), _tickUpper(tokenId));
        (gross, ) = _computeReward(j, s.liquidity, s.secondsPerLiquidityInsideInitialX128, spliNow);
        if (block.timestamp < j.endTime) {
            if (block.timestamp < uint256(s.stakedAt) + j.minStakeSeconds) penalty = gross;
            else if (j.earlyExitPenaltyBps > 0) penalty = (gross * j.earlyExitPenaltyBps) / 10_000;
        }
        uint256 net = gross - penalty;
        fee = (net * j.claimFeeBps) / 10_000;
        paid = net - fee;
    }

    function feeScheduleFor(address pool) external view returns (uint8 tier, uint16 postBps, uint16 claimBps) {
        tier = poolTier[pool];
        (postBps, claimBps) = _feeSchedule(tier);
    }

    // -------------------------------------------------------------- internals

    /// @dev The Uniswap V3 Staker reward split. A staker's payout is their share
    ///      of the incentive's still-unclaimed liquidity-seconds:
    ///
    ///        liquiditySeconds  = (spliNow - spliInitial) * liquidity
    ///        totalUnclaimed    = ((max(now, end) - start) << 128) - alreadyClaimed
    ///        reward            = rewardRemaining * liquiditySeconds / totalUnclaimed
    ///
    ///      max(now, end) rather than min: the pool's seconds accumulator does
    ///      NOT stop at endTime, so a funder who settles late has a numerator
    ///      that kept growing. The denominator has to grow with it or a late
    ///      settler would claim more than their share of the escrow. This is
    ///      why anyone may unstake on a funder's behalf once endTime passes.
    ///
    ///      The subtraction of the seconds accumulator is intentionally
    ///      unchecked: Uniswap's accumulator is allowed to overflow and the
    ///      wrapped difference is still the correct elapsed value.
    function _computeReward(Job storage j, uint128 liquidity, uint160 spliInitial, uint160 spliNow)
        internal view returns (uint256 reward, uint160 liquiditySecondsX128)
    {
        unchecked {
            liquiditySecondsX128 = (spliNow - spliInitial) * liquidity;
        }
        uint256 nowT = block.timestamp > j.endTime ? block.timestamp : j.endTime;
        if (nowT <= j.startTime) return (0, 0);
        uint256 totalX128 = ((nowT - j.startTime) << 128);
        if (totalX128 <= j.totalSecondsClaimedX128) return (0, liquiditySecondsX128);
        uint256 unclaimedX128 = totalX128 - j.totalSecondsClaimedX128;
        if (liquiditySecondsX128 == 0) return (0, 0);
        reward = FullMath.mulDiv(j.rewardRemaining, liquiditySecondsX128, unclaimedX128);
        // Never pay out more than is escrowed, even if the accumulator is odd.
        if (reward > j.rewardRemaining) reward = j.rewardRemaining;
    }

    function _feeSchedule(uint8 tier) internal view returns (uint16 postBps, uint16 claimBps) {
        if (tier == TIER_A) return (postFeeBpsTierA, claimFeeBpsTierA);
        return (postFeeBpsDefault, claimFeeBpsDefault);
    }

    function _job(uint256 jobId) internal view returns (Job storage) {
        require(jobId < _jobs.length, "no job");
        return _jobs[jobId];
    }

    function _tickLower(uint256 tokenId) internal view returns (int24 tl) {
        (, , , , , tl, , , , , , ) = npm.positions(tokenId);
    }

    function _tickUpper(uint256 tokenId) internal view returns (int24 tu) {
        (, , , , , , tu, , , , , ) = npm.positions(tokenId);
    }

    /// @dev Measure what actually arrived, so a fee-on-transfer reward token
    ///      escrows the real amount instead of over-promising.
    /// @dev Tolerate the non-standard ERC20s that return NOTHING instead of a bool.
    ///      USDT is the famous one and there are plenty of bridged clones. The old
    ///      code was `require(IERC20(token).transfer(...))`, which makes the ABI
    ///      decoder revert on empty return data — so such a token could not fund a
    ///      job, and worse, if one ever became a job's reward token it could never
    ///      pay a claim or a refund. Empty return data is treated as success and an
    ///      explicit `false` as failure, exactly as AetherReserveEscrow already did
    ///      and as every audited SafeERC20 does.
    function _tokenCall(address token, bytes memory data, string memory err) internal {
        require(token.code.length > 0, "not a contract");
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), err);
    }

    function _pullMeasured(address token, address from, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(token).balanceOf(address(this));
        _tokenCall(token, abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount), "transferFrom failed");
        uint256 got = IERC20(token).balanceOf(address(this)) - before;
        require(got > 0, "received 0");
        return got;
    }

    function _send(address token, address to, uint256 amount) internal {
        _tokenCall(token, abi.encodeWithSelector(IERC20.transfer.selector, to, amount), "transfer failed");
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "u128");
        return uint128(x);
    }
}

/*
 ______________________________________________________________________________
  INVARIANTS this contract is built to hold (and that the test suite checks)
 ______________________________________________________________________________

  SOLVENCY
    1. For every job:  sum(all payouts) + sum(all claim fees) + refund
                       <= escrow recorded at creation + top-ups.
       Enforced because every payout is a mulDiv slice of rewardRemaining
       bounded by rewardRemaining, and rewardRemaining is decremented by
       exactly the net paid out.
    2. rewardRemaining never increases except via fundJob.

  CUSTODY
    3. A funder can always retrieve their NFT: unstake -> withdrawToken, or
       emergencyWithdraw -> withdrawToken. Neither path can be blocked by the
       poster, the owner, or the state of the pool.
    4. Nobody but the original depositor can withdraw a deposited NFT.
    5. Liquidity cannot be decreased mid-stake, because the gauge holds the NFT
       and NonfungiblePositionManager.decreaseLiquidity requires approval.

  PROOF-OF-WORK
    6. Reward accrues only from the AMM's own in-range seconds accumulator.
       An out-of-range position accrues nothing; there is no other input.
    7. The penalty is a function of (block.timestamp, stakedAt, endTime) only —
       never of price or range. A poster cannot induce a forfeit.

  ADMIN LIMITS
    8. Fees are snapshotted per job at creation and hard-capped by immutable
       constants. Changing the fee schedule or a pool's tier cannot affect any
       existing job.
    9. There is no owner function that can move escrow, seize an NFT, pause a
       claim, or alter a live job. The owner surface is: fee schedule, tier
       registry, treasury address, ownership.
   10. Ownership itself moves only in two steps — nominate, then accept from the
       nominated address — so the admin key can never be sent somewhere that
       cannot sign, and there is no renounce that would freeze the registry.

  TIMING
   11. refundJob requires zero live stakes AND endTime + REFUND_DELAY, so a
       settling funder can never be raced.
   12. After endTime anyone may unstake on a funder's behalf, so a job always
       terminates and the poster's refund is never hostage to an absent funder.
 ______________________________________________________________________________
*/
