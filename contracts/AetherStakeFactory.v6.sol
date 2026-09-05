// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
    AetherZone Productive Staking — FACTORY + ISOLATED PER-POOL VAULTS (EIP-1167 clones).

    StakePoolFactory deploys one AetherStakePool per (stakedToken, counterToken, fee)
    as a minimal-proxy CLONE of a single shared implementation — same per-pool
    isolation as full deploys, at ~1/10th the creation gas. Each pool:
      • holds ONLY its own reserve and its own v3 positions — physically unable to
        reach another pool's funds or the treasury;
      • mints/custodies its own single-sided v3 position per stake;
      • lets anyone TOP UP the reserve (creator refills when capacity runs low);
      • preserves each staker's ORIGINAL deposited count (stored once at stake) and
        pays it back + staked-side fees on redeem; the reserve covers any shortfall
        computed from the position's CURRENT composition at withdrawal.

    Because clones share the implementation's bytecode, per-pool config lives in
    STORAGE and is set once via initialize() — there are NO immutables here.

    Custody: reserves live inside each pool; no EOA/key controls them; NO admin drain
    function exists. The factory owner can rotate the shared treasury and globally
    pause NEW stakes in an emergency, but can never pause redemptions or move reserves.

    ⚠ UNAUDITED REFERENCE. Audit + fuzz before mainnet.
//////////////////////////////////////////////////////////////////////////*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IUniswapV3Factory { function getPool(address, address, uint24) external view returns (address); }
interface IUniswapV3Pool {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, uint8, bool);
    function tickSpacing() external view returns (int24);
    function token0() external view returns (address);
    function token1() external view returns (address);
}
interface INonfungiblePositionManager {
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }
    struct DecreaseLiquidityParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    function burn(uint256) external payable;
}
interface IStakeFactory {
    function treasury() external view returns (address);
    function stakingPaused() external view returns (bool);
}

/*//////////////////////////  PER-POOL VAULT (clone target)  //////////////////////////*/

contract AetherStakePool is IERC721Receiver {
    using SafeERC20 for IERC20;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;
    bool  public constant counterFallbackOnShortfall = true;
    uint16 public constant EARLY_EXIT_PENALTY_BPS = 2000; // early exit forfeits 20% of principal to the platform treasury
    string public constant VERSION = "aetherzone-staking-v6";

    // ---- config: STORAGE (not immutable — clones share bytecode) ----
    IStakeFactory public factory;
    INonfungiblePositionManager public npm;
    address public v3Pool;
    address public stakedToken;
    address public counterToken;
    uint24  public fee;
    int24   public tickSpacing;
    bool    public stakedIsToken0;
    address public creator;
    uint16  public deployerFeeShareBps;   // snapshot at creation — fixed for this pool
    uint64  public lockPeriod;
    address public rewardRecipient;
    uint256 public maxCapacity;
    string  public name;   // human label, e.g. "Test Pool 1" (cosmetic; creator-settable)
    address public pendingCreator; // two-step creator handoff (propose here, accept from the new address)

    uint256 public reserve;
    uint256 public stakedPrincipal;

    /// @notice Counter-token retained from redemptions: the portion of a staker's deposit
    ///         that converted into the counter token while their position was in range.
    /// @dev    v5 sent this to the treasury together with the platform's fee share, so the
    ///         reserve funded every shortfall and was never repaid — it drained one
    ///         redemption at a time while the treasury accumulated the offsetting value.
    ///         v6 keeps it here instead. It is NOT counted as coverage: the guarantee pays
    ///         in stakedToken, and this is the wrong asset for that until it is converted.
    ///         Deliberately not swapped in-contract — an automatic swap would be forced to
    ///         trade at whatever depth exists at that instant, and these pools are thin.
    uint256 public counterReserve;

    struct Position { address owner; uint256 nftId; uint128 liquidity; uint256 principal; int24 entryTick; uint64 unlockAt; bool open; }
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public userPositions;
    uint256 public nextPositionId;

    // ---- clone-safe init + reentrancy (no constructor state) ----
    bool private _initialized;
    uint256 private _lock; // 0/1 = free, 2 = entered

    modifier initializer() { require(!_initialized, "initialized"); _initialized = true; _; }
    modifier nonReentrant() { require(_lock != 2, "reentrant"); _lock = 2; _; _lock = 1; }
    modifier onlyFactory() { require(msg.sender == address(factory), "only factory"); _; }
    modifier onlyCreator() { require(msg.sender == creator, "only creator"); _; }

    event ReserveFunded(address indexed from, uint256 amount, uint256 newReserve);
    event ReserveWithdrawn(address indexed to, uint256 amount, uint256 newReserve);
    event CounterReserveAdded(uint256 indexed positionId, uint256 amount, uint256 newCounterReserve);
    event CounterReserveWithdrawn(address indexed to, uint256 amount, uint256 newCounterReserve);
    event MaxCapacitySet(uint256 cap);
    event RewardRecipientSet(address recipient);
    event CreatorTransferStarted(address indexed from, address indexed to);
    event CreatorTransferred(address indexed from, address indexed to);
    event Staked(uint256 indexed positionId, address indexed user, uint256 principal, uint256 nftId, int24 entryTick, uint64 unlockAt);
    event Redeemed(uint256 indexed positionId, address indexed user, uint256 principalReturned, uint256 stakedFees, uint256 counterToPlatform, uint256 counterToDeployer, uint256 reserveDraw);
    event EmergencyRedeemed(uint256 indexed positionId, address indexed user, uint256 userStaked, uint256 userCounter, uint256 penaltyStaked, uint256 penaltyCounter, uint256 stakedFees, uint256 counterToDeployer, uint256 counterToPlatform);
    event CounterHarvested(uint256 indexed positionId, uint256 toDeployer, uint256 toPlatform);
    event Claimed(uint256 indexed positionId, address indexed owner, uint256 stakedFees, uint256 counterToDeployer, uint256 counterToPlatform);
    event NameSet(string name);
    event ReserveShortfall(uint256 indexed positionId, uint256 missing, bool counterHandedToUser);

    struct InitArgs {
        address npm; address v3Pool; address stakedToken; address counterToken;
        uint24 fee; int24 tickSpacing; bool stakedIsToken0; address creator;
        uint16 deployerFeeShareBps; uint64 lockPeriod; uint256 maxCapacity; string name;
    }

    struct PoolInfo {
        address creator; address pendingCreator; address rewardRecipient; string name;
        address stakedToken; address counterToken; uint24 fee; uint64 lockPeriod;
        uint256 maxCapacity; uint256 reserve; uint256 stakedPrincipal; uint256 available; uint256 coverageWad;
        bool stakedIsToken0; uint16 deployerFeeShareBps;
    }

    /// @notice Called once by the factory right after cloning. `msg.sender` is the factory.
    function initialize(InitArgs calldata a) external initializer {
        factory = IStakeFactory(msg.sender);
        npm = INonfungiblePositionManager(a.npm); v3Pool = a.v3Pool;
        stakedToken = a.stakedToken; counterToken = a.counterToken; fee = a.fee; tickSpacing = a.tickSpacing;
        stakedIsToken0 = a.stakedIsToken0; creator = a.creator; deployerFeeShareBps = a.deployerFeeShareBps;
        lockPeriod = a.lockPeriod; maxCapacity = a.maxCapacity; rewardRecipient = a.creator;
        name = a.name;
        nextPositionId = 1;
    }

    function initReserve(uint256 amount) external onlyFactory {
        require(reserve == 0, "init");
        require(IERC20(stakedToken).balanceOf(address(this)) >= amount, "unfunded");
        reserve = amount;
        emit ReserveFunded(msg.sender, amount, reserve);
    }

    /// @notice Top up the reserve any time — creator refills when capacity runs low.
    function fundReserve(uint256 amount) external nonReentrant {
        uint256 got = _pullExact(msg.sender, amount);
        reserve += got;
        emit ReserveFunded(msg.sender, got, reserve);
    }

    function withdrawReserve(uint256 amount) external nonReentrant onlyCreator {
        require(stakedPrincipal == 0, "stakes active");
        require(amount <= reserve, "amt>reserve");
        reserve -= amount;
        IERC20(stakedToken).safeTransfer(msg.sender, amount);
        emit ReserveWithdrawn(msg.sender, amount, reserve);
    }

    /// @notice Take the retained counter-token out so it can be swapped back to the staked
    ///         token off-chain and returned with fundReserve().
    /// @dev    Same guard as withdrawReserve: nothing may leave while stakes are live, so a
    ///         creator cannot pull the backing out from under an open position.
    function withdrawCounterReserve(uint256 amount) external nonReentrant onlyCreator {
        require(stakedPrincipal == 0, "stakes active");
        require(amount <= counterReserve, "amt>counterReserve");
        counterReserve -= amount;
        IERC20(counterToken).safeTransfer(msg.sender, amount);
        emit CounterReserveWithdrawn(msg.sender, amount, counterReserve);
    }

    function setMaxCapacity(uint256 cap) external onlyCreator { require(cap >= maxCapacity, "cannot reduce"); maxCapacity = cap; emit MaxCapacitySet(cap); }
    function setRewardRecipient(address r) external onlyCreator { require(r != address(0), "zero"); rewardRecipient = r; emit RewardRecipientSet(r); }
    function setName(string calldata n) external onlyCreator { name = n; emit NameSet(n); }

    /// @notice Two-step creator handoff. The current creator proposes a new address here; that
    ///         address must then call acceptCreator(). This makes it impossible to lose creator
    ///         control (and reserve access) to a mistyped address. Propose address(0) to cancel.
    function transferCreator(address newCreator) external onlyCreator { pendingCreator = newCreator; emit CreatorTransferStarted(creator, newCreator); }
    function acceptCreator() external {
        require(msg.sender == pendingCreator && pendingCreator != address(0), "not pending");
        emit CreatorTransferred(creator, pendingCreator);
        creator = pendingCreator; pendingCreator = address(0);
    }

    /*//////////////////////////  STAKE  //////////////////////////*/

    function stake(uint256 amount, uint256 deadline) external nonReentrant returns (uint256 positionId) {
        require(!factory.stakingPaused(), "staking paused");
        require(amount > 0, "zero");
        uint256 got = _pullExact(msg.sender, amount);
        uint256 ceiling = reserve < maxCapacity ? reserve : maxCapacity;
        require(stakedPrincipal + got <= ceiling, "capacity");

        IERC20(stakedToken).forceApprove(address(npm), got);
        (int24 lo, int24 hi) = _range();
        (address t0, address t1) = stakedIsToken0 ? (stakedToken, counterToken) : (counterToken, stakedToken);
        (uint256 nftId, uint128 liq, uint256 u0, uint256 u1) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0, token1: t1, fee: fee, tickLower: lo, tickUpper: hi,
                amount0Desired: stakedIsToken0 ? got : 0, amount1Desired: stakedIsToken0 ? 0 : got,
                amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: deadline
            })
        );
        require(liq > 0, "no liquidity");
        uint256 used = stakedIsToken0 ? u0 : u1;               // ORIGINAL amount staked (the balance proof)
        if (used < got) IERC20(stakedToken).safeTransfer(msg.sender, got - used); // refund rounding dust
        IERC20(stakedToken).forceApprove(address(npm), 0);

        (, int24 cur,,,,,) = IUniswapV3Pool(v3Pool).slot0();
        positionId = nextPositionId++;
        positions[positionId] = Position(msg.sender, nftId, liq, used, cur, uint64(block.timestamp) + lockPeriod, true);
        userPositions[msg.sender].push(positionId);
        stakedPrincipal += used;
        emit Staked(positionId, msg.sender, used, nftId, cur, positions[positionId].unlockAt);
    }

    /*//////////////////////////  REDEEM  //////////////////////////*/

    function redeem(uint256 positionId, uint256 deadline) external nonReentrant returns (uint256 principalOut, uint256 stakedFeesOut) {
        return _redeem(positionId, deadline);
    }

    /// @notice Exit several of YOUR unlocked positions in one transaction. Ids that are locked,
    ///         closed, or not owned by you are skipped (no revert), so a mixed batch still works.
    function redeemMany(uint256[] calldata ids, uint256 deadline) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (!p.open || p.owner != msg.sender || block.timestamp < p.unlockAt) continue;
            _redeem(ids[i], deadline);
        }
    }

    function _redeem(uint256 positionId, uint256 deadline) internal returns (uint256 principalOut, uint256 stakedFeesOut) {
        Position storage pos = positions[positionId];
        require(pos.open, "closed");
        require(pos.owner == msg.sender, "not owner");
        require(block.timestamp >= pos.unlockAt, "locked");

        (uint256 f0, uint256 f1) = npm.collect(_collect(pos.nftId));
        npm.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({ tokenId: pos.nftId, liquidity: pos.liquidity, amount0Min: 0, amount1Min: 0, deadline: deadline }));
        (uint256 p0, uint256 p1) = npm.collect(_collect(pos.nftId));
        npm.burn(pos.nftId);

        uint256 stakedFees  = stakedIsToken0 ? f0 : f1;
        uint256 counterFees = stakedIsToken0 ? f1 : f0;
        uint256 stakedPrin  = stakedIsToken0 ? p0 : p1;   // CURRENT staked-token amount in position
        uint256 counterPrin = stakedIsToken0 ? p1 : p0;   // converted portion

        pos.open = false;
        stakedPrincipal -= pos.principal;                 // aggregate moves by the ORIGINAL

        uint256 owed = pos.principal;                     // pay back the ORIGINAL count
        uint256 draw; bool handed;
        if (stakedPrin >= owed) {
            uint256 s = stakedPrin - owed; if (s > 0) reserve += s;
        } else {
            uint256 miss = owed - stakedPrin;             // shortfall = original − current
            if (reserve >= miss) { reserve -= miss; draw = miss; }
            else {
                draw = reserve; uint256 still = miss - draw; reserve = 0; owed = stakedPrin + draw;
                if (counterFallbackOnShortfall && counterPrin > 0) { IERC20(counterToken).safeTransfer(pos.owner, counterPrin); counterPrin = 0; handed = true; }
                emit ReserveShortfall(positionId, still, handed);
            }
        }

        principalOut = owed; stakedFeesOut = stakedFees;
        IERC20(stakedToken).safeTransfer(pos.owner, owed + stakedFees);

        uint256 cut = (counterFees * deployerFeeShareBps) / 10000;
        if (cut > 0) IERC20(counterToken).safeTransfer(rewardRecipient, cut);
        // v6: the platform takes FEES only. counterPrin is the mirror image of `draw` —
        // the staker's own principal in its converted form — so it stays with the pool
        // that just paid that principal out, instead of leaving as platform revenue.
        uint256 plat = counterFees - cut;
        if (plat > 0) IERC20(counterToken).safeTransfer(factory.treasury(), plat);
        if (counterPrin > 0) {
            counterReserve += counterPrin;
            emit CounterReserveAdded(positionId, counterPrin, counterReserve);
        }

        emit Redeemed(positionId, pos.owner, principalOut, stakedFeesOut, plat, cut, draw);
    }

    /*//////////////////////////  EMERGENCY (EARLY) REDEEM  //////////////////////////*/
    // v5: EARLY EXIT never touches the reserve. The principal guarantee is earned by holding to
    // term; an early-exiter takes their ACTUAL position (whatever it converted to) minus a fixed
    // 20% penalty on BOTH sides. Reserve stays whole for the stakers who stay. Normal redeem() is
    // unchanged and remains fully reserve-backed.
    function emergencyRedeem(uint256 positionId, uint256 deadline) external nonReentrant returns (uint256 userStaked, uint256 penaltyStaked) {
        Position storage pos = positions[positionId];
        require(pos.open, "closed");
        require(pos.owner == msg.sender, "not owner");
        require(block.timestamp < pos.unlockAt, "unlocked"); // past lock: use redeem() for a penalty-free, reserve-backed exit

        (uint256 f0, uint256 f1) = npm.collect(_collect(pos.nftId));
        npm.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({ tokenId: pos.nftId, liquidity: pos.liquidity, amount0Min: 0, amount1Min: 0, deadline: deadline }));
        (uint256 p0, uint256 p1) = npm.collect(_collect(pos.nftId));
        npm.burn(pos.nftId);

        uint256 stakedFees  = stakedIsToken0 ? f0 : f1;
        uint256 counterFees = stakedIsToken0 ? f1 : f0;
        uint256 stakedPrin  = stakedIsToken0 ? p0 : p1;   // ACTUAL current composition (user bears their own IL)
        uint256 counterPrin = stakedIsToken0 ? p1 : p0;

        pos.open = false;
        stakedPrincipal -= pos.principal;                 // aggregate moves by the ORIGINAL count; reserve is NOT touched

        penaltyStaked = (stakedPrin * EARLY_EXIT_PENALTY_BPS) / 10000;
        uint256 penaltyCounter = (counterPrin * EARLY_EXIT_PENALTY_BPS) / 10000;
        userStaked = stakedPrin - penaltyStaked;
        uint256 userCounter = counterPrin - penaltyCounter;

        // user: 80% of their real position (both sides) + their staked-side fees
        IERC20(stakedToken).safeTransfer(pos.owner, userStaked + stakedFees);
        if (userCounter > 0) IERC20(counterToken).safeTransfer(pos.owner, userCounter);
        // penalty on the staked side -> treasury
        if (penaltyStaked > 0) IERC20(stakedToken).safeTransfer(factory.treasury(), penaltyStaked);
        // counter-side fees keep the normal creator/platform split; the counter penalty -> treasury
        uint256 cut = (counterFees * deployerFeeShareBps) / 10000;
        if (cut > 0) IERC20(counterToken).safeTransfer(rewardRecipient, cut);
        uint256 plat = penaltyCounter + (counterFees - cut);
        if (plat > 0) IERC20(counterToken).safeTransfer(factory.treasury(), plat);

        emit EmergencyRedeemed(positionId, pos.owner, userStaked, userCounter, penaltyStaked, penaltyCounter, stakedFees, cut, plat);
    }

    /*//////////////////////////  FEE HARVEST (no unwinding)  //////////////////////////*/
    // Two SURGICAL, one-sided collects. Each only ever pulls one side of the fees, so the
    // deployer collecting their revenue can NEVER move a staker's rewards, and vice-versa.
    // collect() only pulls fees, never the staked liquidity — principal, reserve and locks
    // are untouched. amount{0,1}Max is set to 0 on the side we are NOT taking, so the other
    // side's fees stay parked on the position (paid later on claim or redeem).

    /// @notice Deployer/anyone: pull ONLY the counter-side fees and split them
    ///         (deployerFeeShareBps to the reward address, remainder to the treasury).
    ///         Stakers' staked-side fees are left exactly where they are.
    function harvestCounter(uint256[] calldata ids) external nonReentrant {
        address treasury = factory.treasury();
        uint128 max0; uint128 max1;
        if (stakedIsToken0) { max1 = type(uint128).max; } else { max0 = type(uint128).max; } // counter side only
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage pos = positions[ids[i]];
            if (!pos.open) continue;
            (uint256 a0, uint256 a1) = npm.collect(INonfungiblePositionManager.CollectParams({
                tokenId: pos.nftId, recipient: address(this), amount0Max: max0, amount1Max: max1 }));
            uint256 counterFees = stakedIsToken0 ? a1 : a0;
            if (counterFees == 0) continue;
            uint256 cut = (counterFees * deployerFeeShareBps) / 10000;
            uint256 plat = counterFees - cut;
            if (cut > 0) IERC20(counterToken).safeTransfer(rewardRecipient, cut);
            if (plat > 0) IERC20(counterToken).safeTransfer(treasury, plat);
            emit CounterHarvested(ids[i], cut, plat);
        }
    }

    /// @notice Position OWNER only: settle ALL accrued fees on your OWN positions without unwinding.
    ///         Your staked-side fees go to you; the counter-side settles its creator/platform split.
    ///         Owner-gated (skips positions you don't own), so your rewards only move when YOU act.
    function claim(uint256[] calldata ids) external nonReentrant {
        address treasury = factory.treasury();
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage pos = positions[ids[i]];
            if (!pos.open || pos.owner != msg.sender) continue;
            (uint256 f0, uint256 f1) = npm.collect(_collect(pos.nftId)); // both sides; liquidity stays
            uint256 stakedFees  = stakedIsToken0 ? f0 : f1;
            uint256 counterFees = stakedIsToken0 ? f1 : f0;
            if (stakedFees > 0) IERC20(stakedToken).safeTransfer(pos.owner, stakedFees);
            uint256 cut; uint256 plat;
            if (counterFees > 0) {
                cut = (counterFees * deployerFeeShareBps) / 10000;
                plat = counterFees - cut;
                if (cut > 0) IERC20(counterToken).safeTransfer(rewardRecipient, cut);
                if (plat > 0) IERC20(counterToken).safeTransfer(treasury, plat);
            }
            emit Claimed(ids[i], pos.owner, stakedFees, cut, plat);
        }
    }

    /*//////////////////////  INTERNAL / VIEWS  //////////////////////*/

    function _pullExact(address from, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(stakedToken).balanceOf(address(this));
        IERC20(stakedToken).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(stakedToken).balanceOf(address(this)) - before;
        require(received == amount, "unsupported token");
        return received;
    }
    function _collect(uint256 nftId) internal view returns (INonfungiblePositionManager.CollectParams memory) {
        return INonfungiblePositionManager.CollectParams({ tokenId: nftId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max });
    }
    function _range() internal view returns (int24 lower, int24 upper) {
        (, int24 cur,,,,,) = IUniswapV3Pool(v3Pool).slot0();
        int24 s = tickSpacing;
        int24 usableMax = (MAX_TICK / s) * s;
        int24 usableMin = (MIN_TICK / s) * s;
        int24 a = (cur / s) * s;
        if (stakedIsToken0) { if (a <= cur) a += s; lower = a; upper = usableMax; }
        else { if (a >= cur) a -= s; lower = usableMin; upper = a; }
        require(lower < upper, "range");
    }
    function availableCapacity() external view returns (uint256) {
        uint256 ceiling = reserve < maxCapacity ? reserve : maxCapacity;
        return ceiling > stakedPrincipal ? ceiling - stakedPrincipal : 0;
    }
    function reserveCoverageRatio() external view returns (uint256) {
        if (stakedPrincipal == 0) return type(uint256).max;
        return (reserve * 1e18) / stakedPrincipal;
    }
    /// @notice All pool config + live state in one call (fewer RPC round-trips for the UI).
    function getPoolInfo() external view returns (PoolInfo memory info) {
        uint256 ceiling = reserve < maxCapacity ? reserve : maxCapacity;
        info = PoolInfo({
            creator: creator, pendingCreator: pendingCreator, rewardRecipient: rewardRecipient, name: name,
            stakedToken: stakedToken, counterToken: counterToken, fee: fee, lockPeriod: lockPeriod,
            maxCapacity: maxCapacity, reserve: reserve, stakedPrincipal: stakedPrincipal,
            available: ceiling > stakedPrincipal ? ceiling - stakedPrincipal : 0,
            coverageWad: stakedPrincipal == 0 ? type(uint256).max : (reserve * 1e18) / stakedPrincipal,
            stakedIsToken0: stakedIsToken0, deployerFeeShareBps: deployerFeeShareBps
        });
    }
    function positionsOf(address user) external view returns (uint256[] memory) { return userPositions[user]; }
    /// @notice All currently-open position ids in this pool — feed into harvestCounter() for a “collect all”.
    function openPositionIds() external view returns (uint256[] memory ids) {
        uint256 n = nextPositionId; uint256 count;
        for (uint256 i = 1; i < n; i++) if (positions[i].open) count++;
        ids = new uint256[](count); uint256 j;
        for (uint256 i = 1; i < n; i++) if (positions[i].open) ids[j++] = i;
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return IERC721Receiver.onERC721Received.selector; }
}

/*//////////////////////////////  FACTORY  //////////////////////////////*/

contract StakePoolFactory is Ownable, Pausable {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public immutable npm;
    IUniswapV3Factory public immutable v3Factory;
    address public immutable poolImplementation;   // the clone target, deployed once
    address public treasury;                        // shared platform sink (set to a multisig)
    uint16  public defaultDeployerFeeShareBps = 3000;
    bool    public stakingPausedFlag;
    string  public constant VERSION = "aetherzone-staking-v6";

    mapping(uint24 => bool) public allowedFee;
    mapping(bytes32 => address) public poolContract;
    address[] public allPools;

    event PoolDeployed(bytes32 indexed poolId, address indexed pool, address indexed creator, address stakedToken, address counterToken, uint24 fee, uint256 reserve, uint256 maxCapacity);
    event TreasurySet(address treasury);
    event FeeTierSet(uint24 fee, bool allowed);
    event DefaultDeployerFeeShareSet(uint16 bps);
    event StakingPausedSet(bool paused);

    constructor(address _npm, address _v3Factory, address _treasury, address _owner) Ownable(_owner) {
        require(_npm != address(0) && _v3Factory != address(0) && _treasury != address(0), "zero addr");
        npm = INonfungiblePositionManager(_npm);
        v3Factory = IUniswapV3Factory(_v3Factory);
        treasury = _treasury;
        poolImplementation = address(new AetherStakePool()); // implementation is never initialized / holds no funds
        allowedFee[1000] = true; allowedFee[3000] = true; allowedFee[10000] = true;
    }

    function getPoolId(address stakedToken, address counterToken, uint24 fee) public pure returns (bytes32) {
        return keccak256(abi.encode(stakedToken, counterToken, fee));
    }
    function poolsCount() external view returns (uint256) { return allPools.length; }
    function stakingPaused() external view returns (bool) { return stakingPausedFlag; }

    /// @notice Clone an isolated staking pool and bond its reserve. Caller must have
    ///         approved THIS factory to spend `reserveAmount` of `stakedToken`.
    /// @dev maxCapacity is the ADVERTISED ceiling and may exceed reserveAmount. Staking is
    ///      always hard-gated by the bonded reserve (stake ceiling = min(reserve, maxCapacity)),
    ///      so every staked token stays fully 1:1 reserve-backed; the creator raises real
    ///      stakeable room by topping up the reserve via fundReserve().
    function createPool(
        address stakedToken, address counterToken, uint24 fee,
        uint64 lockPeriod, uint256 reserveAmount, uint256 maxCapacity, string calldata poolName
    ) external whenNotPaused returns (address poolAddr, bytes32 poolId) {
        require(stakedToken != address(0) && counterToken != address(0) && stakedToken != counterToken, "bad tokens");
        require(allowedFee[fee], "fee tier");
        require(reserveAmount > 0 && maxCapacity > 0, "zero amounts");
        poolId = getPoolId(stakedToken, counterToken, fee);
        require(poolContract[poolId] == address(0), "exists");

        address v3 = v3Factory.getPool(stakedToken, counterToken, fee);
        require(v3 != address(0), "no dex pool");

        poolAddr = Clones.clone(poolImplementation);
        AetherStakePool(poolAddr).initialize(AetherStakePool.InitArgs({
            npm: address(npm), v3Pool: v3, stakedToken: stakedToken, counterToken: counterToken, fee: fee,
            tickSpacing: IUniswapV3Pool(v3).tickSpacing(), stakedIsToken0: IUniswapV3Pool(v3).token0() == stakedToken,
            creator: msg.sender, deployerFeeShareBps: defaultDeployerFeeShareBps, lockPeriod: lockPeriod, maxCapacity: maxCapacity, name: poolName
        }));

        uint256 before = IERC20(stakedToken).balanceOf(poolAddr);
        IERC20(stakedToken).safeTransferFrom(msg.sender, poolAddr, reserveAmount);
        uint256 got = IERC20(stakedToken).balanceOf(poolAddr) - before;
        require(got == reserveAmount, "unsupported token");
        AetherStakePool(poolAddr).initReserve(got);

        poolContract[poolId] = poolAddr;
        allPools.push(poolAddr);
        emit PoolDeployed(poolId, poolAddr, msg.sender, stakedToken, counterToken, fee, got, maxCapacity);
    }

    function setTreasury(address t) external onlyOwner { require(t != address(0), "zero"); treasury = t; emit TreasurySet(t); }
    function setAllowedFee(uint24 fee, bool ok) external onlyOwner { allowedFee[fee] = ok; emit FeeTierSet(fee, ok); }
    function setDefaultDeployerFeeShare(uint16 bps) external onlyOwner { require(bps <= 10000, "bps"); defaultDeployerFeeShareBps = bps; emit DefaultDeployerFeeShareSet(bps); }
    function setStakingPaused(bool v) external onlyOwner { stakingPausedFlag = v; emit StakingPausedSet(v); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
