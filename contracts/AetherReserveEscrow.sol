// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 ______________________________________________________________________________
  AetherReserveEscrow — the reserve-funding rail of the AetherZone marketplace
 ______________________________________________________________________________

  WHAT THIS IS

  An AetherStakePool needs a RESERVE: staked-token inventory the pool consumes
  to make redeeming stakers whole when the position comes back short. The
  reserve is spent, not invested. Nothing in the pool ever pays a reserve
  supplier back. So "funding a reserve" cannot honestly be sold as yield.

  What it actually is, once you strip the branding off, is a LOAN:

      the funder hands the creator working capital,
      the capital is delivered straight into the pool's reserve so it cannot be
      diverted on the way in,
      the creator owes it back by a date,
      and the funder is paid a fee for the time their capital was committed.

  This contract is that loan, with the parts that normally require trust
  replaced by things a chain can check.

  WHY THE COLLATERAL IS THE WHOLE SECURITY, NOT A DEPOSIT

  AetherStakePool.withdrawReserve is onlyCreator and only needs
  stakedPrincipal == 0. There is no creator-transfer function, so there is no
  way for this contract to hold the creator out of it for the term. A creator
  can therefore pull a freshly funded reserve back out the moment no stake is
  open. That is not a hypothetical; it is one call.

  Any design that treats the reserve balance as the funder's security is
  therefore wrong, and no amount of monitoring fixes it. So the reserve is
  treated purely as DELIVERY, and repayment is secured entirely by collateral
  escrowed here BEFORE the deal is ever visible to a funder. A funder who does
  not like the collateral does not fill. That is the only gate that matters.

  WHY THERE IS NO PRICE FEED

  The obvious next move is to value the collateral on-chain and liquidate when
  coverage slips. On this network that would be a liability, not a feature:
  most pairs hold five figures of liquidity or less, so a spot quote is
  something an attacker rents for an afternoon. A price-triggered liquidation
  would be the cheapest thing on the platform to attack.

  So this contract never asks what anything is worth. Valuation happens once,
  off-chain, by the funder, before they commit — helped by the quoter-based
  sizing in targets.js and the pool scoring — and the on-chain triggers are
  facts instead of prices:

      the repayment deadline passed, or
      the reserve covenant the BORROWER themselves set was broken.

  Both are booleans. Neither can be manufactured by moving a market.

  WHAT THE CHAIN VERIFIES, END TO END

    1. The borrower is the pool's actual creator (pool.creator()).
    2. The principal token is the pool's actual stakedToken().
    3. Delivery is measured, not asserted: the reserve balance must rise by at
       least `principal` across the fundReserve call, or the fill reverts.
    4. Collateral is in this contract's custody from posting to settlement. For
       an LP-NFT that also means the borrower cannot decreaseLiquidity or
       collect from it while it is pledged, because the position manager gates
       both on ownership.
    5. The service fee is escrowed by the borrower up front and streams to the
       funder over the term, so an early repayment refunds the unearned part
       and a full-term commitment is paid in full.
    6. Settlement is symmetric and time-boxed (see below), so neither side can
       hold the other hostage by doing nothing.

  THE SETTLEMENT TIMELINE, AND WHY IT HAS A CURE WINDOW

      fill ............................ principal delivered, fee starts streaming
      .. up to deadline ............... borrower may repay; funder gets the
                                        streamed fee, the rest goes back
      deadline .. +CURE_WINDOW ........ ONLY the funder may act. This window
                                        exists so there is no block-level race
                                        between a late repayment and a default
                                        claim on a chain this fast.
      after +CURE_WINDOW .............. if the funder still has not claimed, the
                                        borrower may cure by repaying principal
                                        plus the FULL fee. Prevents collateral
                                        being locked forever by an absent
                                        funder, without rewarding lateness.

  WHAT THIS CONTRACT DELIBERATELY DOES NOT DO

  It does not check that a collateral token has $2k of liquidity, is a week
  old, or is verified. Those are real and correct things to require — they just
  cannot be evaluated on-chain without importing exactly the price surface this
  design removes. They live in the scoring and the front end, and they bind
  because a funder reads them before choosing to fill. Same reasoning as the
  gauge's tier registry, which affects fees and nothing else.

  It does not do partial repayment, refinancing, or collateral top-up. Each of
  those needs a valuation to be meaningful.

  It never takes custody of the reserve. Once delivered, the reserve belongs to
  the pool and behaves exactly as it would have if the creator had funded it
  themselves.
 ______________________________________________________________________________
*/

// ------------------------------------------------------------------ interfaces

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Minimal {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface INonfungiblePositionManager {
    function positions(uint256 tokenId)
        external view returns (
            uint96 nonce, address operator, address token0, address token1, uint24 fee,
            int24 tickLower, int24 tickUpper, uint128 liquidity,
            uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0, uint128 tokensOwed1
        );
}

interface IAetherStakePool {
    function stakedToken() external view returns (address);
    function counterToken() external view returns (address);
    function fee() external view returns (uint24);
    function creator() external view returns (address);
    function reserve() external view returns (uint256);
    function stakedPrincipal() external view returns (uint256);
    function fundReserve(uint256 amount) external;
}

/// @dev Provenance only. `poolContract` is written in exactly one place —
///      AetherStakeFactory.createPool — so a match proves the address is a clone of
///      the audited pool implementation and not a contract someone wrote this morning.
interface IAetherStakeFactory {
    function getPoolId(address stakedToken, address counterToken, uint24 fee) external pure returns (bytes32);
    function poolContract(bytes32 poolId) external view returns (address);
}

// ------------------------------------------------------------------- contract

contract AetherReserveEscrow {
    // ---- hard limits. The owner moves fees only inside these, and every deal
    //      snapshots its fee bps at POSTING, so neither side's economics can be
    //      moved under them between reading a deal and acting on it.
    uint16 public constant MAX_FEE_BPS   = 500;      // 5% max platform cut of the service fee
    uint64 public constant MIN_TERM      = 1 days;
    uint64 public constant MAX_TERM      = 365 days;
    /// @dev After the deadline, a window in which only the funder may act. Removes
    ///      the repay-vs-default race; see the timeline note in the header.
    uint64 public constant CURE_WINDOW   = 7 days;

    uint8 public constant COL_ERC20 = 0;
    uint8 public constant COL_LPNFT = 1;

    uint8 public constant OPEN = 0;
    uint8 public constant FUNDED = 1;
    uint8 public constant REPAID = 2;
    uint8 public constant DEFAULTED = 3;
    uint8 public constant CANCELLED = 4;

    uint8 public constant TIER_UNRATED = 0;
    uint8 public constant TIER_A = 1;   // pool LP verifiably locked (Bubble) — discounted
    uint8 public constant TIER_B = 2;   // real pool, unlocked — standard

    /// @notice The canonical position manager. Only LP NFTs from this contract
    ///         are accepted as collateral, so `positions()` on a pledged token
    ///         id always means what the funder thinks it means.
    INonfungiblePositionManager public immutable npm;

    /// @notice The AetherStake factory. A deal may only name a pool this factory
    ///         actually deployed.
    /// @dev    This closes the hole that made every other guarantee in this contract
    ///         conditional. `pool` used to be any address that answered creator() and
    ///         stakedToken(), and `fill` APPROVES that address for the funder's whole
    ///         principal and then CALLS it (fundReserve), trusting its own reserve()
    ///         to report what arrived. Against an attacker-written "pool" the
    ///         measurement is the attacker measuring themselves: they take the
    ///         principal and return whatever number passes the check. Worse, a pool
    ///         that later reverts on reserve() bricks claimDefault, so the funder
    ///         cannot even seize the collateral.
    ///         AetherLPGauge already required factory provenance for the same reason
    ///         (see "not a factory pool" in its stake path). This contract did not.
    IAetherStakeFactory public immutable factory;

    // ---- admin: fee schedule and tier registry ONLY ----
    address public owner;
    /// @dev Nominee for a two-step handover. Non-zero only between the current
    ///      owner's nomination and the nominee's acceptance. See transferOwnership.
    address public pendingOwner;
    address public treasury;
    uint16 public feeBpsTierA   = 50;    // 0.5%
    uint16 public feeBpsDefault = 200;   // 2.0%

    /// @notice Off-chain-attested pool tier. AFFECTS PLATFORM FEE ONLY. It cannot
    ///         alter, delay or block any deal, delivery, repayment or claim.
    mapping(address => uint8) public poolTier;

    struct Deal {
        address borrower;
        address pool;
        address funder;
        address principalToken;     // == pool.stakedToken(), checked at posting
        address feeToken;
        address colToken;           // ERC20 collateral, or the NPM for COL_LPNFT
        uint256 colAmountOrId;      // ERC20 amount, or the LP token id
        uint128 principal;          // what must land in the reserve, and what comes back
        uint128 feeGross;           // service fee escrowed by the borrower at posting
        uint128 feeNet;             // fee after the platform cut, taken at fill
        uint128 reserveAtFund;      // pool.reserve() immediately after delivery
        uint64  term;
        uint64  fundedAt;
        uint64  deadline;
        uint16  reserveFloorBps;    // covenant floor as bps of principal, 0 = none
        uint16  upfrontBps;         // share of the fee earned on delivery; rest streams
        uint16  feeBps;             // platform cut, SNAPSHOTTED AT POSTING (see note)
        uint8   colKind;
        uint8   state;
    }

    Deal[] private _deals;

    /// @dev Pull-payment book for the funder. Pushing to the funder on repay would
    ///      let a hostile or broken funder contract brick the borrower's repayment
    ///      and force a default, so what the funder is owed is booked and claimed.
    mapping(uint256 => uint256) public claimablePrincipal;
    mapping(uint256 => uint256) public claimableFee;

    uint256 private _lock = 1;
    modifier nonReentrant() { require(_lock == 1, "reentrant"); _lock = 2; _; _lock = 1; }
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    event DealPosted(
        uint256 indexed dealId, address indexed borrower, address indexed pool,
        address principalToken, uint256 principal, address feeToken, uint256 feeGross,
        uint64 term, uint16 reserveFloorBps, uint16 upfrontBps,
        uint8 colKind, address colToken, uint256 colAmountOrId
    );
    event DealCancelled(uint256 indexed dealId);
    event DealFilled(
        uint256 indexed dealId, address indexed funder, uint256 delivered,
        uint256 reserveAfter, uint256 platformFee, uint256 feeNet, uint64 deadline, uint8 tier
    );
    event DealRepaid(uint256 indexed dealId, address indexed by, uint256 principal, uint256 feeEarned, uint256 feeReturned, bool late);
    event DealDefaulted(uint256 indexed dealId, address indexed funder, bool covenantBreach, uint256 reserveNow);
    event Claimed(uint256 indexed dealId, address indexed funder, uint256 principalOut, uint256 feeOut);
    event CollateralReleased(uint256 indexed dealId, address indexed to, uint8 colKind, address colToken, uint256 colAmountOrId);
    event PoolTierSet(address indexed pool, uint8 tier);
    event FeesSet(uint16 tierA, uint16 tierDefault);
    event TreasurySet(address treasury);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed was);
    event OwnerSet(address owner);

    constructor(address _npm, address _factory, address _treasury) {
        require(_npm != address(0) && _factory != address(0) && _treasury != address(0), "zero");
        npm = INonfungiblePositionManager(_npm);
        factory = IAetherStakeFactory(_factory);
        owner = msg.sender;
        treasury = _treasury;
    }

    // ------------------------------------------------------------------ admin

    /// @notice Nominate the next owner. Ownership does NOT move here — the
    ///         nominee must call acceptOwnership from that exact address.
    /// @dev Two steps, not one, because a one-step setOwner is a single typo away
    ///      from an admin key that provably does not exist. Nothing in this
    ///      contract can be rescued by redeploying: the tier registry and the fee
    ///      schedule would be frozen at whatever they happened to be, and a pool
    ///      mis-rated at posting time could never be corrected. Requiring the
    ///      destination to sign proves the key is live and controlled BEFORE it
    ///      receives anything, which turns a fat-fingered address from a permanent
    ///      loss into a no-op. It is also the only safe way to hand over to a
    ///      multisig, where "can this address actually transact" is a real
    ///      question and not a formality.
    ///
    ///      Nominating does not weaken the current owner: until acceptance the
    ///      caller keeps every power, and can withdraw the nomination. And note
    ///      what is NOT at stake either way — no owner, present or future, can
    ///      touch a posted deal, an escrowed fee, a pledged collateral, or a
    ///      funder's booked claim. The handover is over the fee schedule and the
    ///      tier registry, nothing else.
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

    function setPoolTier(address pool, uint8 tier) external onlyOwner {
        require(tier <= TIER_B, "bad tier");
        poolTier[pool] = tier;
        emit PoolTierSet(pool, tier);
    }

    function setFees(uint16 tierA, uint16 tierDefault) external onlyOwner {
        require(tierA <= MAX_FEE_BPS && tierDefault <= MAX_FEE_BPS, "fee cap");
        feeBpsTierA = tierA; feeBpsDefault = tierDefault;
        emit FeesSet(tierA, tierDefault);
    }

    function _feeBps(address pool) internal view returns (uint16) {
        return poolTier[pool] == TIER_A ? feeBpsTierA : feeBpsDefault;
    }

    // ------------------------------------------------------------- posting

    /// @notice Post a request for reserve capital. The borrower escrows the
    ///         collateral and the whole service fee here in this one call, so a
    ///         deal is never visible to funders until it is already backed.
    /// @param pool            the AetherStakePool whose reserve is to be funded
    /// @param principal       staked-token amount that must land in the reserve
    /// @param feeToken        token the service fee is paid in
    /// @param feeGross        service fee, escrowed now, streamed to the funder
    /// @param term            seconds from fill to the repayment deadline
    /// @param reserveFloorBps covenant: during the term pool.reserve() must stay
    ///                        >= principal * bps / 10000. 0 disables it, and 0 is
    ///                        the sane default. Understand what this is before
    ///                        setting it: a reserve EXISTS to be consumed when a
    ///                        redeeming staker comes back short, so a floor can
    ///                        break through the pool working exactly as intended,
    ///                        not only through misconduct — and breaking it forfeits
    ///                        the collateral immediately. It is here for borrowers
    ///                        who want to advertise a hard cap on drawdown in
    ///                        exchange for a cheaper fee, not as a safety default.
    /// @param upfrontBps      share of the fee earned the moment capital lands
    /// @param colKind         COL_ERC20 or COL_LPNFT
    /// @param colToken        collateral ERC20, or the position manager for an LP NFT
    /// @param colAmountOrId   collateral amount, or the LP token id
    function postDeal(
        address pool,
        uint256 principal,
        address feeToken,
        uint256 feeGross,
        uint64  term,
        uint16  reserveFloorBps,
        uint16  upfrontBps,
        uint8   colKind,
        address colToken,
        uint256 colAmountOrId
    ) external nonReentrant returns (uint256 dealId) {
        require(pool != address(0), "zero pool");
        require(principal > 0 && feeGross > 0, "zero amount");
        require(term >= MIN_TERM && term <= MAX_TERM, "term");
        require(reserveFloorBps <= 10000 && upfrontBps <= 10000, "bps");
        require(colKind == COL_ERC20 || colKind == COL_LPNFT, "col kind");

        // The borrower must be the pool's real creator. They are the only party
        // who can withdrawReserve, so they are the only party whose promise about
        // the reserve floor is worth anything.
        // PROVENANCE FIRST. Everything below — the creator check, the measured
        // delivery in fill(), the collateral seizure in claimDefault() — assumes
        // `pool` is a real AetherStake pool. Nothing enforced that, so a contract
        // written to imitate the interface satisfied every one of those checks
        // while controlling both sides of the measurement. Ask the factory whether
        // it built this address before trusting a single word it says.
        {
            IAetherStakePool p_ = IAetherStakePool(pool);
            bytes32 pid_ = factory.getPoolId(p_.stakedToken(), p_.counterToken(), p_.fee());
            require(factory.poolContract(pid_) == pool, "not a factory pool");
        }

        require(msg.sender == IAetherStakePool(pool).creator(), "not pool creator");
        address principalToken = IAetherStakePool(pool).stakedToken();
        require(principalToken != address(0), "bad pool");

        uint256 colHeld;
        if (colKind == COL_ERC20) {
            require(colToken != address(0) && colAmountOrId > 0, "col");
            colHeld = _pullMeasured(colToken, msg.sender, colAmountOrId);
        } else {
            // Only the canonical NPM, so a funder reading positions(id) is reading
            // the position they were shown. Plain transferFrom on purpose: it moves
            // custody without handing control to an external receiver hook.
            require(colToken == address(npm), "col npm");
            IERC721Minimal(colToken).transferFrom(msg.sender, address(this), colAmountOrId);
            require(IERC721Minimal(colToken).ownerOf(colAmountOrId) == address(this), "nft not held");
            (, , , , , , , uint128 liq, , , , ) = npm.positions(colAmountOrId);
            require(liq > 0, "empty position");
            colHeld = colAmountOrId;
        }

        uint256 feeHeld = _pullMeasured(feeToken, msg.sender, feeGross);

        dealId = _deals.length;
        _deals.push(Deal({
            borrower: msg.sender,
            pool: pool,
            funder: address(0),
            principalToken: principalToken,
            feeToken: feeToken,
            colToken: colToken,
            colAmountOrId: colHeld,
            principal: _u128(principal),
            feeGross: _u128(feeHeld),
            feeNet: 0,
            reserveAtFund: 0,
            term: term,
            fundedAt: 0,
            deadline: 0,
            reserveFloorBps: reserveFloorBps,
            upfrontBps: upfrontBps,
            // Snapshot the platform cut NOW. The borrower escrows the fee in this
            // same call and the funder reads the split before filling; letting the
            // owner move it afterwards would be an admin lever over a posted deal.
            feeBps: _feeBps(pool),
            colKind: colKind,
            state: OPEN
        }));

        emit DealPosted(
            dealId, msg.sender, pool, principalToken, principal, feeToken, feeHeld,
            term, reserveFloorBps, upfrontBps, colKind, colToken, colHeld
        );
    }

    /// @notice Withdraw an unfilled deal. Nothing has been charged yet, so the
    ///         borrower gets the collateral and the entire fee escrow back.
    function cancelDeal(uint256 dealId) external nonReentrant {
        Deal storage d = _deal(dealId);
        require(msg.sender == d.borrower, "not borrower");
        require(d.state == OPEN, "not open");
        d.state = CANCELLED;
        uint256 fee = d.feeGross;
        d.feeGross = 0;
        if (fee > 0) _send(d.feeToken, d.borrower, fee);
        _releaseCollateral(dealId, d, d.borrower);
        emit DealCancelled(dealId);
    }

    // -------------------------------------------------------------- filling

    /// @notice Supply the capital. `amountIn` may exceed `principal` so that a
    ///         fee-on-transfer principal token can still deliver the full amount;
    ///         the reserve keeps any excess, which only helps the borrower.
    /// @dev    Delivery is proven by the pool's own accounting, not by our transfer:
    ///         the reserve must rise by at least `principal` across fundReserve.
    function fill(uint256 dealId, uint256 amountIn) external nonReentrant {
        Deal storage d = _deal(dealId);
        require(d.state == OPEN, "not open");
        require(msg.sender != d.borrower, "self fill");
        require(amountIn >= d.principal, "amountIn");

        uint256 got = _pullMeasured(d.principalToken, msg.sender, amountIn);

        IAetherStakePool p = IAetherStakePool(d.pool);
        uint256 before = p.reserve();
        // Approve from zero: some tokens reject a non-zero-to-non-zero approve.
        // Nothing can have left a stale allowance here (the pool pulls exactly
        // what it is approved for, in this same call), but clearing first is free.
        _approve(d.principalToken, d.pool, 0);
        _approve(d.principalToken, d.pool, got);
        p.fundReserve(got);
        _approve(d.principalToken, d.pool, 0);   // leave no standing allowance

        uint256 nowReserve = p.reserve();
        uint256 delivered = nowReserve - before;
        require(delivered >= d.principal, "under-delivered");

        uint256 platformFee = (uint256(d.feeGross) * d.feeBps) / 10000;
        uint256 feeNet = uint256(d.feeGross) - platformFee;

        d.funder = msg.sender;
        d.fundedAt = uint64(block.timestamp);
        d.deadline = uint64(block.timestamp) + d.term;
        d.reserveAtFund = _u128(nowReserve);
        d.feeNet = _u128(feeNet);
        d.state = FUNDED;

        if (platformFee > 0) _send(d.feeToken, treasury, platformFee);

        emit DealFilled(dealId, msg.sender, delivered, nowReserve, platformFee, feeNet, d.deadline, poolTier[d.pool]);
    }

    // ------------------------------------------------------------ settlement

    /// @notice Repay the principal and close the deal. Callable by anyone — a
    ///         third party settling a borrower's debt harms no one — up to the
    ///         deadline, and again after the cure window if the funder never
    ///         claimed. Inside the cure window only the funder may act.
    /// @param amountIn how much to pull from the caller. It must be at least
    ///        `principal`, and it is a separate parameter for the same reason it
    ///        is on `fill`: a fee-on-transfer principal token delivers less than
    ///        is sent, so pulling exactly `principal` would make such a token
    ///        impossible to repay and every deal in it an automatic default.
    ///        Anything that arrives above `principal` is credited to the funder;
    ///        the caller decides the number, so nobody is surprised by it.
    function repay(uint256 dealId, uint256 amountIn) external nonReentrant {
        Deal storage d = _deal(dealId);
        require(d.state == FUNDED, "not funded");
        require(amountIn >= d.principal, "amountIn");

        bool late = block.timestamp > d.deadline;
        if (late) {
            // Past the deadline the funder owns the next move for CURE_WINDOW.
            require(block.timestamp > uint256(d.deadline) + CURE_WINDOW, "funder's window");
        }

        uint256 principal = d.principal;
        uint256 got = _pullMeasured(d.principalToken, msg.sender, amountIn);
        require(got >= principal, "short repay");

        // A late cure pays the whole fee: the funder's capital was committed for
        // longer than the term they agreed to.
        uint256 earned = late ? uint256(d.feeNet) : _feeEarned(d, block.timestamp);
        uint256 returned = uint256(d.feeNet) - earned;

        d.state = REPAID;
        claimablePrincipal[dealId] += got;
        claimableFee[dealId] += earned;

        if (returned > 0) _send(d.feeToken, d.borrower, returned);
        _releaseCollateral(dealId, d, d.borrower);

        emit DealRepaid(dealId, msg.sender, got, earned, returned, late);
    }

    /// @notice Take the collateral. Only the funder, and only on a fact:
    ///         the deadline passed, or the borrower's own reserve covenant broke.
    ///         No price is consulted, so nothing here can be triggered by a market.
    function claimDefault(uint256 dealId) external nonReentrant {
        Deal storage d = _deal(dealId);
        require(d.state == FUNDED, "not funded");
        require(msg.sender == d.funder, "not funder");

        bool breach = _covenantBroken(d);
        require(breach || block.timestamp > d.deadline, "not defaulted");

        d.state = DEFAULTED;
        claimableFee[dealId] += d.feeNet;   // full fee: the term was not honoured
        _releaseCollateral(dealId, d, d.funder);

        // Belt and braces on top of the factory check. A reverting reserve() here
        // would take the whole call down WITH the collateral release above it, and
        // a funder must never lose a seizure because a log field could not be
        // computed. The number is telemetry; the transfer is the point.
        emit DealDefaulted(dealId, msg.sender, breach, _reserveOrZero(d.pool));
    }

    /// @notice Funder withdraws whatever the deal has booked for them.
    function claim(uint256 dealId) external nonReentrant {
        Deal storage d = _deal(dealId);
        require(msg.sender == d.funder, "not funder");
        uint256 pOut = claimablePrincipal[dealId];
        uint256 fOut = claimableFee[dealId];
        require(pOut > 0 || fOut > 0, "nothing");
        claimablePrincipal[dealId] = 0;
        claimableFee[dealId] = 0;
        if (pOut > 0) _send(d.principalToken, msg.sender, pOut);
        if (fOut > 0) _send(d.feeToken, msg.sender, fOut);
        emit Claimed(dealId, msg.sender, pOut, fOut);
    }

    // ----------------------------------------------------------------- views

    function dealCount() external view returns (uint256) { return _deals.length; }
    function getDeal(uint256 dealId) external view returns (Deal memory) { return _deals[dealId]; }

    /// @notice True when the borrower's own reserve floor is currently broken.
    function covenantBroken(uint256 dealId) external view returns (bool) {
        return _covenantBroken(_deals[dealId]);
    }

    /// @notice What the funder would be owed in fee if the deal were repaid now.
    function feeEarnedNow(uint256 dealId) external view returns (uint256) {
        Deal storage d = _deals[dealId];
        if (d.state != FUNDED) return 0;
        if (block.timestamp > d.deadline) return d.feeNet;
        return _feeEarned(d, block.timestamp);
    }

    /// @notice The pledged LP position as the position manager reports it. A funder
    ///         should read this rather than trust the listing.
    function collateralPosition(uint256 dealId)
        external view returns (address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        Deal storage d = _deals[dealId];
        require(d.colKind == COL_LPNFT, "not an lp position");
        (, , token0, token1, fee, tickLower, tickUpper, liquidity, , , , ) = npm.positions(d.colAmountOrId);
    }

    /// @notice Whether the collateral is still in this contract's custody.
    function collateralHeld(uint256 dealId) external view returns (bool) {
        Deal storage d = _deals[dealId];
        if (d.state == REPAID || d.state == DEFAULTED || d.state == CANCELLED) return false;
        if (d.colKind == COL_LPNFT) return IERC721Minimal(d.colToken).ownerOf(d.colAmountOrId) == address(this);
        return d.colAmountOrId > 0;
    }

    // -------------------------------------------------------------- internals

    function _deal(uint256 dealId) internal view returns (Deal storage) {
        require(dealId < _deals.length, "no deal");
        return _deals[dealId];
    }

    /// @dev reserve() for logging only — never for a decision. Returns 0 rather than
    ///      reverting, so no settlement path can be bricked by a broken pool.
    function _reserveOrZero(address pool) internal view returns (uint256) {
        try IAetherStakePool(pool).reserve() returns (uint256 v) { return v; } catch { return 0; }
    }

    function _covenantBroken(Deal storage d) internal view returns (bool) {
        if (d.state != FUNDED || d.reserveFloorBps == 0) return false;
        uint256 floor = (uint256(d.principal) * d.reserveFloorBps) / 10000;
        return IAetherStakePool(d.pool).reserve() < floor;
    }

    function _feeEarned(Deal storage d, uint256 at) internal view returns (uint256) {
        uint256 net = d.feeNet;
        if (net == 0) return 0;
        uint256 up = (net * d.upfrontBps) / 10000;
        uint256 streamed = net - up;
        uint256 elapsed = at <= d.fundedAt ? 0 : at - d.fundedAt;
        if (elapsed >= d.term) return net;
        return up + (streamed * elapsed) / d.term;
    }

    /// @dev Zeroes the record before moving anything, so a re-entrant call finds
    ///      an empty pledge. Non-safe ERC721 transfer on purpose: releasing
    ///      collateral must not be blockable by a receiver hook.
    function _releaseCollateral(uint256 dealId, Deal storage d, address to) internal {
        uint8 kind = d.colKind;
        address token = d.colToken;
        uint256 amt = d.colAmountOrId;
        if (amt == 0 && kind == COL_ERC20) return;
        d.colAmountOrId = 0;
        if (kind == COL_LPNFT) {
            IERC721Minimal(token).transferFrom(address(this), to, amt);
        } else {
            _send(token, to, amt);
        }
        emit CollateralReleased(dealId, to, kind, token, amt);
    }

    /// @dev A great many live ERC20s (USDT and every token copied from it) return
    ///      NOTHING from transfer/transferFrom/approve rather than the bool the
    ///      standard asks for. Decoding a bool off empty returndata reverts, so a
    ///      strict `require(token.transfer(...))` would make those tokens simply
    ///      unusable here — as principal, as fee, and as collateral. Treat an empty
    ///      return as success and a `false` return as failure, which is what every
    ///      audited SafeERC20 does.
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

    function _approve(address token, address spender, uint256 amount) internal {
        _tokenCall(token, abi.encodeWithSelector(IERC20.approve.selector, spender, amount), "approve failed");
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

  CUSTODY
   1. Collateral is in this contract from postDeal until exactly one of cancel,
      repay or claimDefault, and each of those releases it to exactly one party.
      It can never be released twice: the pledge is zeroed before the transfer.
   2. While an LP NFT is pledged, the borrower cannot decreaseLiquidity or
      collect from it, because the position manager gates both on ownership.

  DELIVERY
   3. A fill that does not raise pool.reserve() by at least `principal` reverts.
      The funder's money and the pool's accounting move together or not at all.
   4. The escrow never holds the reserve, and never has a path to withdraw it.

  MONEY
   5. The platform is paid only out of the service fee, only at fill, and never
      more than MAX_FEE_BPS. Principal and collateral are untouchable by fees.
   6. feeEarned + feeReturned == feeNet on every repay; on default the funder
      gets exactly feeNet. The fee escrow is fully accounted in both branches.
   7. Everything owed to the funder is booked and pulled, so no counterparty
      can be griefed by a reverting recipient.

  TIMING
   8. Up to the deadline only the borrower's side can close the deal (repay);
      for CURE_WINDOW after it only the funder can (claimDefault); after that
      both may act. There is no window in which neither can, so collateral is
      never permanently stranded.
   9. A deal's fee schedule is snapshotted at POSTING (postDeal writes feeBps), not
      at fill — this line said "at fill" and was simply wrong. Posting is the
      stronger guarantee of the two: the borrower escrows the fee in that same
      call, and the funder reads the already-fixed split before filling, so the
      owner cannot move the cut on a deal that is sitting open. Later admin fee changes
      cannot alter it.

  AUTHORITY
  10. The owner can set the treasury, the fee bps within the cap, and the tier
      registry. There is no owner path to a deal, an escrow, a collateral
      pledge, or a claim.
  11. Ownership itself moves only in two steps — nominate, then accept from the
      nominated address — so the admin key can never be sent somewhere that
      cannot sign, and there is no renounce that would freeze the registry.
 ______________________________________________________________________________
*/
