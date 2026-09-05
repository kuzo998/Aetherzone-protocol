// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherMulticall v1.0 — Custom Specialized Multicall for AetherZone
//
// Purpose: Replace dozens of individual RPC calls with single batched reads.
// Designed specifically for the AetherZone frontend call patterns:
//   - Portfolio snapshots (ERC20 balances + staking + LP positions)
//   - Pool state aggregation (slot0 + liquidity + TVL + ticks)
//   - Limit order status batch reads
//   - Address display info (SNS + bytecode check)
//   - Revenue stats aggregation
//   - Generic tryAggregate (Multicall3-compatible fallback)
//
// All functions are view/static — zero state changes, safe for any caller.
// ════════════════════════════════════════════════════════════════════════════

// ─── Minimal Interfaces ───────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality,
        uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked
    );
    function liquidity() external view returns (uint128);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function ticks(int24 tick) external view returns (
        uint128 liquidityGross, int128 liquidityNet,
        uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128,
        int56 tickCumulativeOutside, uint160 secondsPerLiquidityOutsideX128,
        uint32 secondsOutside, bool initialized
    );
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128
    );
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface INonfungiblePositionManager {
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1,
        uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface ITickLens {
    struct PopulatedTick {
        int24 tick;
        int128 liquidityNet;
        uint128 liquidityGross;
    }
    function getPopulatedTicksInWord(address pool, int16 tickBitmapIndex) external view returns (PopulatedTick[] memory populatedTicks);
}

interface IStakingContract {
    function getStakeInfo(address user) external view returns (uint256 totalAmount, uint256 nextUnlockTime, uint256 availableRewards);
    function totalStaked() external view returns (uint256);
    function lockPeriod() external view returns (uint256);
    function earned(address) external view returns (uint256);
    function deposits(address user, uint256 index) external view returns (uint256 amount, uint256 depositTime, uint256 lastClaimTime);
    function EMERGENCY_WITHDRAW_PENALTY() external view returns (uint256);
}

interface IAetherLimitOrders {
    struct Order {
        bytes32 id;
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountRemaining;
        uint256 minAmountOut;
        uint64 deadline;
        uint64 createdAt;
        uint8 status;
        uint256 filledAmountOut;
        uint256 targetPriceX96;
    }
    function getOrder(bytes32 orderId) external view returns (Order memory);
    function getUserOrders(address user) external view returns (bytes32[] memory);
    function botFeeWei() external view returns (uint256);
}

// ─── AetherMulticall ─────────────────────────────────────────────────────────

contract AetherMulticall {

    // ── Constants ─────────────────────────────────────────────────────────────

    address public immutable factory;
    address public immutable positionManager;
    address public immutable tickLens;
    uint128 public constant MAX_UINT128 = type(uint128).max;

    constructor(address _factory, address _positionManager, address _tickLens) {
        factory    = _factory;
        positionManager = _positionManager;
        tickLens   = _tickLens;
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 1: GENERIC MULTICALL (Multicall3-compatible)
    // ════════════════════════════════════════════════════════════════════════

    struct Call {
        address target;
        bytes   callData;
    }

    struct Call3 {
        address target;
        bool    allowFailure;
        bytes   callData;
    }

    struct Result {
        bool    success;
        bytes   returnData;
    }

    /// @notice Executes multiple calls in a single transaction (require all succeed)
    function aggregate(Call[] calldata calls)
        external view
        returns (uint256 blockNumber, bytes[] memory returnData)
    {
        blockNumber = block.number;
        returnData  = new bytes[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.staticcall(calls[i].callData);
            require(success, string(abi.encodePacked("AetherMulticall: call ", _toString(i), " failed")));
            returnData[i] = ret;
        }
    }

    /// @notice Try-aggregate — never reverts, returns success flag per call
    function tryAggregate(bool requireSuccess, Call[] calldata calls)
        external view
        returns (Result[] memory results)
    {
        results = new Result[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.staticcall(calls[i].callData);
            if (requireSuccess) require(success, "AetherMulticall: required call failed");
            results[i] = Result(success, ret);
        }
    }

    /// @notice Try-aggregate with per-call failure control
    function aggregate3(Call3[] calldata calls)
        external view
        returns (Result[] memory results)
    {
        results = new Result[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.staticcall(calls[i].callData);
            if (!calls[i].allowFailure) require(success, "AetherMulticall: required call failed");
            results[i] = Result(success, ret);
        }
    }

    /// @notice Block metadata (for frontend sync)
    function getBlockMetadata() external view returns (
        uint256 blockNumber,
        bytes32 blockHash,
        uint256 timestamp,
        uint256 basefee,
        uint256 gasLimit,
        address coinbase
    ) {
        blockNumber = block.number;
        blockHash   = blockhash(block.number - 1);
        timestamp   = block.timestamp;
        basefee     = block.basefee;
        gasLimit    = block.gaslimit;
        coinbase    = block.coinbase;
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 2: TOKEN BATCH READS
    // ════════════════════════════════════════════════════════════════════════

    struct TokenBalance {
        address token;
        uint256 balance;
        uint8   decimals;
    }

    struct TokenMetadata {
        address token;
        string  symbol;
        string  name;
        uint8   decimals;
        uint256 totalSupply;
    }

    struct AllowanceData {
        address token;
        uint256 allowance;
    }

    /// @notice Get native + ERC20 balances for one address in one call
    /// @dev Replaces N individual balanceOf calls — key performance win
    function getBalances(address user, address[] calldata tokens)
        external view
        returns (uint256 nativeBalance, TokenBalance[] memory balances)
    {
        nativeBalance = user.balance;
        balances = new TokenBalance[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            uint256 bal;
            uint8 dec = 18;
            try IERC20(tokens[i]).balanceOf(user) returns (uint256 b) { bal = b; } catch {}
            try IERC20(tokens[i]).decimals() returns (uint8 d) { dec = d; } catch {}
            balances[i] = TokenBalance(tokens[i], bal, dec);
        }
    }

    /// @notice Batch token metadata (replaces individual symbol/name/decimals calls)
    function getTokenMetadata(address[] calldata tokens)
        external view
        returns (TokenMetadata[] memory meta)
    {
        meta = new TokenMetadata[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            string memory sym  = "?";
            string memory name = "Unknown";
            uint8  dec  = 18;
            uint256 sup = 0;
            try IERC20(tokens[i]).symbol()      returns (string memory s)  { sym  = s; } catch {}
            try IERC20(tokens[i]).name()         returns (string memory n)  { name = n; } catch {}
            try IERC20(tokens[i]).decimals()     returns (uint8 d)           { dec  = d; } catch {}
            try IERC20(tokens[i]).totalSupply()  returns (uint256 ts)        { sup  = ts; } catch {}
            meta[i] = TokenMetadata(tokens[i], sym, name, dec, sup);
        }
    }

    /// @notice Batch allowance checks (for approve UI)
    function getAllowances(address owner, address spender, address[] calldata tokens)
        external view
        returns (AllowanceData[] memory allowances)
    {
        allowances = new AllowanceData[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            uint256 allowance = 0;
            try IERC20(tokens[i]).allowance(owner, spender) returns (uint256 a) { allowance = a; } catch {}
            allowances[i] = AllowanceData(tokens[i], allowance);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 3: POOL STATE BATCH READS
    // ════════════════════════════════════════════════════════════════════════

    struct PoolState {
        address pool;
        uint160 sqrtPriceX96;
        int24   tick;
        uint128 liquidity;
        uint24  fee;
        int24   tickSpacing;
        address token0;
        address token1;
        bool    exists;
    }

    struct PoolTVL {
        address pool;
        uint256 balance0;
        uint256 balance1;
        uint8   decimals0;
        uint8   decimals1;
    }

    /// @notice Batch read pool states (slot0 + liquidity + metadata) for all pools
    /// @dev Replaces: slot0() + liquidity() + tickSpacing() + token0() + token1() × N pools
    function getPoolsState(address[] calldata pools)
        external view
        returns (PoolState[] memory states)
    {
        states = new PoolState[](pools.length);
        for (uint256 i; i < pools.length; i++) {
            address p = pools[i];
            PoolState memory s;
            s.pool = p;
            try IUniswapV3Pool(p).slot0() returns (
                uint160 sqrtP, int24 tick, uint16, uint16, uint16, uint8, bool
            ) {
                s.sqrtPriceX96 = sqrtP;
                s.tick          = tick;
                s.exists        = true;
            } catch { continue; }
            try IUniswapV3Pool(p).liquidity()    returns (uint128 liq) { s.liquidity    = liq; } catch {}
            try IUniswapV3Pool(p).fee()          returns (uint24 f)   { s.fee          = f; } catch {}
            try IUniswapV3Pool(p).tickSpacing()  returns (int24 ts)   { s.tickSpacing  = ts; } catch {}
            try IUniswapV3Pool(p).token0()       returns (address t0) { s.token0       = t0; } catch {}
            try IUniswapV3Pool(p).token1()       returns (address t1) { s.token1       = t1; } catch {}
            states[i] = s;
        }
    }

    /// @notice Get pool addresses from factory for multiple token pairs + fee tiers in one call
    /// @dev Replaces: factory.getPool() × N×F calls
    function getPoolAddresses(
        address[] calldata token0s,
        address[] calldata token1s,
        uint24[] calldata fees
    ) external view returns (address[] memory poolAddresses) {
        require(token0s.length == token1s.length && token1s.length == fees.length, "AetherMulticall: length mismatch");
        poolAddresses = new address[](token0s.length);
        for (uint256 i; i < token0s.length; i++) {
            try IUniswapV3Factory(factory).getPool(token0s[i], token1s[i], fees[i]) returns (address pool) {
                poolAddresses[i] = pool;
            } catch {
                poolAddresses[i] = address(0);
            }
        }
    }

    /// @notice Pool TVL — token balances inside pools (for liquidity calculation)
    function getPoolsTVL(address[] calldata pools)
        external view
        returns (PoolTVL[] memory tvls)
    {
        tvls = new PoolTVL[](pools.length);
        for (uint256 i; i < pools.length; i++) {
            address p = pools[i];
            tvls[i].pool = p;
            try IUniswapV3Pool(p).token0() returns (address t0) {
                try IERC20(t0).balanceOf(p)  returns (uint256 b) { tvls[i].balance0  = b; } catch {}
                try IERC20(t0).decimals()    returns (uint8 d)   { tvls[i].decimals0 = d; } catch {}
            } catch {}
            try IUniswapV3Pool(p).token1() returns (address t1) {
                try IERC20(t1).balanceOf(p)  returns (uint256 b) { tvls[i].balance1  = b; } catch {}
                try IERC20(t1).decimals()    returns (uint8 d)   { tvls[i].decimals1 = d; } catch {}
            } catch {}
        }
    }

    /// @notice Batch tick reads from TickLens (replaces 11+ individual calls per pool view)
    struct TickBatch {
        address pool;
        int16[] bitmapIndices;
    }

    // Renamed from PopulatedTick to avoid collision with ITickLens.PopulatedTick
    struct TickData {
        int24   tick;
        int128  liquidityNet;
        uint128 liquidityGross;
    }

    function getPoolTickBatch(address pool, int16[] calldata bitmapIndices)
        external view
        returns (TickData[][] memory ticks)
    {
        ticks = new TickData[][](bitmapIndices.length);
        ITickLens lens = ITickLens(tickLens);
        for (uint256 i; i < bitmapIndices.length; i++) {
            try lens.getPopulatedTicksInWord(pool, bitmapIndices[i])
                returns (ITickLens.PopulatedTick[] memory pts)
            {
                TickData[] memory converted = new TickData[](pts.length);
                for (uint256 j; j < pts.length; j++) {
                    converted[j] = TickData(pts[j].tick, pts[j].liquidityNet, pts[j].liquidityGross);
                }
                ticks[i] = converted;
            } catch {}
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 4: LP POSITION BATCH READS
    // ════════════════════════════════════════════════════════════════════════

    struct LPPosition {
        uint256 tokenId;
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        bool    exists;
    }

    /// @notice Get all LP positions for a user from Position Manager in one call
    /// @dev Replaces: balanceOf + N×tokenOfOwnerByIndex + N×positions calls
    function getUserLPPositions(address user, uint256 maxPositions)
        external view
        returns (uint256[] memory tokenIds, LPPosition[] memory positions)
    {
        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        uint256 balance;
        try pm.balanceOf(user) returns (uint256 b) { balance = b; } catch { return (new uint256[](0), new LPPosition[](0)); }

        uint256 count = balance < maxPositions ? balance : maxPositions;
        tokenIds  = new uint256[](count);
        positions = new LPPosition[](count);

        for (uint256 i; i < count; i++) {
            uint256 tokenId;
            try pm.tokenOfOwnerByIndex(user, i) returns (uint256 tid) { tokenId = tid; } catch { continue; }
            tokenIds[i] = tokenId;

            try pm.positions(tokenId) returns (
                uint96, address, address t0, address t1,
                uint24 fee, int24 tl, int24 tu, uint128 liq,
                uint256, uint256, uint128 owed0, uint128 owed1
            ) {
                positions[i] = LPPosition({
                    tokenId:    tokenId,
                    token0:     t0,
                    token1:     t1,
                    fee:        fee,
                    tickLower:  tl,
                    tickUpper:  tu,
                    liquidity:  liq,
                    tokensOwed0: owed0,
                    tokensOwed1: owed1,
                    exists:     true
                });
            } catch {}
        }
    }

    /// @notice Batch read specific LP positions by tokenId
    function getLPPositionsByIds(uint256[] calldata tokenIds)
        external view
        returns (LPPosition[] memory positions)
    {
        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        positions = new LPPosition[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; i++) {
            try pm.positions(tokenIds[i]) returns (
                uint96, address, address t0, address t1,
                uint24 fee, int24 tl, int24 tu, uint128 liq,
                uint256, uint256, uint128 owed0, uint128 owed1
            ) {
                positions[i] = LPPosition({
                    tokenId:    tokenIds[i],
                    token0:     t0,
                    token1:     t1,
                    fee:        fee,
                    tickLower:  tl,
                    tickUpper:  tu,
                    liquidity:  liq,
                    tokensOwed0: owed0,
                    tokensOwed1: owed1,
                    exists:     true
                });
            } catch {}
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 5: STAKING BATCH READS
    // ════════════════════════════════════════════════════════════════════════

    struct StakingPosition {
        address contractAddr;
        uint256 stakedAmount;
        uint256 pendingRewards;
        uint256 nextUnlockTime;
        uint256 totalStaked;
        uint256 lockPeriod;
        uint256 penalty;
        bool    hasPosition;
    }

    /// @notice Get all staking positions for a user across all staking contracts
    /// @dev Replaces: getStakeInfo + earned + totalStaked + lockPeriod × N contracts
    function getStakingPositions(address user, address[] calldata contracts)
        external view
        returns (StakingPosition[] memory positions)
    {
        positions = new StakingPosition[](contracts.length);
        for (uint256 i; i < contracts.length; i++) {
            address c = contracts[i];
            StakingPosition memory p;
            p.contractAddr = c;

            // Try getStakeInfo (most comprehensive)
            bool gotInfo = false;
            try IStakingContract(c).getStakeInfo(user) returns (
                uint256 totalAmount, uint256 nextUnlock, uint256 rewards
            ) {
                p.stakedAmount    = totalAmount;
                p.nextUnlockTime  = nextUnlock;
                p.pendingRewards  = rewards;
                gotInfo           = true;
            } catch {}

            // Fallback: try earned() separately
            if (!gotInfo || p.pendingRewards == 0) {
                try IStakingContract(c).earned(user) returns (uint256 e) {
                    p.pendingRewards = e;
                } catch {}
            }

            if (p.stakedAmount > 0) {
                p.hasPosition = true;
                try IStakingContract(c).totalStaked()   returns (uint256 ts)  { p.totalStaked = ts; } catch {}
                try IStakingContract(c).lockPeriod()    returns (uint256 lp)  { p.lockPeriod  = lp; } catch {}
                try IStakingContract(c).EMERGENCY_WITHDRAW_PENALTY() returns (uint256 pen) { p.penalty = pen; } catch {}
            }

            positions[i] = p;
        }
    }

    /// @notice Batch deposits read for a user's staking position
    struct DepositInfo {
        uint256 index;
        uint256 amount;
        uint256 depositTime;
        uint256 unlockTime;
        bool    isUnlocked;
    }

    function getStakingDeposits(address user, address stakingContract, uint256 maxDeposits)
        external view
        returns (DepositInfo[] memory deposits)
    {
        uint256 lockPeriod = 0;
        try IStakingContract(stakingContract).lockPeriod() returns (uint256 lp) { lockPeriod = lp; } catch {}

        DepositInfo[] memory tempDeposits = new DepositInfo[](maxDeposits);
        uint256 count;
        for (uint256 i; i < maxDeposits; i++) {
            try IStakingContract(stakingContract).deposits(user, i) returns (
                uint256 amount, uint256 depositTime, uint256 /* lastClaimTime */
            ) {
                if (amount == 0) break;
                uint256 unlockTime = depositTime + lockPeriod;
                tempDeposits[count++] = DepositInfo({
                    index:      i,
                    amount:     amount,
                    depositTime: depositTime,
                    unlockTime: unlockTime,
                    isUnlocked: block.timestamp >= unlockTime
                });
            } catch { break; }
        }

        deposits = new DepositInfo[](count);
        for (uint256 i; i < count; i++) deposits[i] = tempDeposits[i];
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 6: LIMIT ORDER BATCH READS
    // ════════════════════════════════════════════════════════════════════════

    struct OrderData {
        bytes32 id;
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountRemaining;
        uint256 minAmountOut;
        uint64  deadline;
        uint64  createdAt;
        uint8   status;         // 0=Pending, 1=Filled, 2=Cancelled, 3=Expired
        uint256 filledAmountOut;
        uint256 targetPriceX96;
        bool    exists;
    }

    /// @notice Batch read limit orders by IDs
    function getLimitOrders(bytes32[] calldata orderIds, address limitContract)
        external view
        returns (OrderData[] memory orders)
    {
        orders = new OrderData[](orderIds.length);
        IAetherLimitOrders lo = IAetherLimitOrders(limitContract);
        for (uint256 i; i < orderIds.length; i++) {
            try lo.getOrder(orderIds[i]) returns (IAetherLimitOrders.Order memory o) {
                orders[i] = OrderData({
                    id:              o.id,
                    owner:           o.owner,
                    tokenIn:         o.tokenIn,
                    tokenOut:        o.tokenOut,
                    amountIn:        o.amountIn,
                    amountRemaining: o.amountRemaining,
                    minAmountOut:    o.minAmountOut,
                    deadline:        o.deadline,
                    createdAt:       o.createdAt,
                    status:          o.status,
                    filledAmountOut: o.filledAmountOut,
                    targetPriceX96:  o.targetPriceX96,
                    exists:          o.owner != address(0)
                });
            } catch {}
        }
    }

    /// @notice Get all order IDs for a user plus their full data
    function getUserLimitOrdersFull(address user, address limitContract)
        external view
        returns (bytes32[] memory ids, OrderData[] memory orders, uint256 botFeeWei)
    {
        IAetherLimitOrders lo = IAetherLimitOrders(limitContract);
        try lo.getUserOrders(user) returns (bytes32[] memory userIds) {
            ids    = userIds;
            orders = new OrderData[](userIds.length);
            for (uint256 i; i < userIds.length; i++) {
                try lo.getOrder(userIds[i]) returns (IAetherLimitOrders.Order memory o) {
                    orders[i] = OrderData({
                        id: o.id, owner: o.owner, tokenIn: o.tokenIn, tokenOut: o.tokenOut,
                        amountIn: o.amountIn, amountRemaining: o.amountRemaining,
                        minAmountOut: o.minAmountOut, deadline: o.deadline, createdAt: o.createdAt,
                        status: o.status, filledAmountOut: o.filledAmountOut, targetPriceX96: o.targetPriceX96,
                        exists: o.owner != address(0)
                    });
                } catch {}
            }
        } catch {
            ids    = new bytes32[](0);
            orders = new OrderData[](0);
        }
        try lo.botFeeWei() returns (uint256 fee) { botFeeWei = fee; } catch {}
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 7: PORTFOLIO SNAPSHOT (THE KILLER FUNCTION)
    // Replaces 50-100+ individual RPC calls with a single on-chain batch
    // ════════════════════════════════════════════════════════════════════════

    struct PortfolioSnapshot {
        address user;
        uint256 nativeBalance;
        TokenBalance[]   tokenBalances;
        StakingPosition[] stakingPositions;
        uint256          lpPositionCount;
        uint256[]        lpTokenIds;
    }

    /// @notice Complete portfolio read: native + ERC20 balances + staking positions
    /// @dev The single most impactful function — collapses 50+ calls into 1
    function getPortfolioSnapshot(
        address     user,
        address[] calldata tokens,
        address[] calldata stakingContracts
    ) external view returns (PortfolioSnapshot memory snapshot) {
        snapshot.user          = user;
        snapshot.nativeBalance = user.balance;

        // Token balances
        snapshot.tokenBalances = new TokenBalance[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            uint256 bal; uint8 dec = 18;
            try IERC20(tokens[i]).balanceOf(user) returns (uint256 b) { bal = b; } catch {}
            try IERC20(tokens[i]).decimals()     returns (uint8 d)   { dec = d; } catch {}
            snapshot.tokenBalances[i] = TokenBalance(tokens[i], bal, dec);
        }

        // Staking positions
        snapshot.stakingPositions = new StakingPosition[](stakingContracts.length);
        for (uint256 i; i < stakingContracts.length; i++) {
            address c = stakingContracts[i];
            StakingPosition memory p;
            p.contractAddr = c;
            try IStakingContract(c).getStakeInfo(user) returns (uint256 amt, uint256 unlock, uint256 rwd) {
                p.stakedAmount = amt; p.nextUnlockTime = unlock; p.pendingRewards = rwd;
            } catch {
                try IStakingContract(c).earned(user) returns (uint256 e) { p.pendingRewards = e; } catch {}
            }
            if (p.stakedAmount > 0) {
                p.hasPosition = true;
                try IStakingContract(c).lockPeriod() returns (uint256 lp) { p.lockPeriod = lp; } catch {}
            }
            snapshot.stakingPositions[i] = p;
        }

        // LP position count
        try INonfungiblePositionManager(positionManager).balanceOf(user) returns (uint256 b) {
            snapshot.lpPositionCount = b;
            uint256 maxLoad = b < 20 ? b : 20;
            snapshot.lpTokenIds = new uint256[](maxLoad);
            for (uint256 i; i < maxLoad; i++) {
                try INonfungiblePositionManager(positionManager).tokenOfOwnerByIndex(user, i) returns (uint256 tid) {
                    snapshot.lpTokenIds[i] = tid;
                } catch {}
            }
        } catch {}
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 8: ADDRESS UTILITY READS
    // ════════════════════════════════════════════════════════════════════════

    struct AddressInfo {
        address addr;
        uint256 balance;
        bool    isContract;
        uint256 codeSize;
    }

    /// @notice Batch address info (is contract check + balance)
    function getAddressInfoBatch(address[] calldata addrs)
        external view
        returns (AddressInfo[] memory infos)
    {
        infos = new AddressInfo[](addrs.length);
        for (uint256 i; i < addrs.length; i++) {
            uint256 size;
            address addr = addrs[i]; // Load address outside of inline assembly
            assembly { size := extcodesize(addr) }
            infos[i] = AddressInfo({
                addr:       addr,
                balance:    addr.balance,
                isContract: size > 0,
                codeSize:   size
            });
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 9: DEX QUOTE HELPERS (on-chain routing data)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Check which fee tiers have pools for a token pair
    /// @dev Saves frontend from calling getPool() for every fee tier individually
    function getAvailableFeeTiers(address tokenA, address tokenB)
        external view
        returns (uint24[] memory feeTiers, address[] memory poolAddresses)
    {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10000];
        uint24[] memory tempFees  = new uint24[](4);
        address[] memory tempPools = new address[](4);
        uint256 count;

        for (uint256 i; i < 4; i++) {
            try IUniswapV3Factory(factory).getPool(tokenA, tokenB, tiers[i]) returns (address pool) {
                if (pool != address(0)) {
                    tempFees[count]  = tiers[i];
                    tempPools[count] = pool;
                    count++;
                }
            } catch {}
        }

        feeTiers     = new uint24[](count);
        poolAddresses = new address[](count);
        for (uint256 i; i < count; i++) {
            feeTiers[i]     = tempFees[i];
            poolAddresses[i] = tempPools[i];
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SECTION 10: INTERNAL HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT PARAMETERS
    // Constructor args for AetherZone Shido Mainnet:
    //   factory:         0xA17f1D96379d53B235587136F86880932c2b605F
    //   positionManager: 0xEdCf5C38BEc4EA10fb2d67d3Da03dd1f4086866F
    //   tickLens:        0x5445bC8c3810c699048315085397cd0065c7fe41
    // ════════════════════════════════════════════════════════════════════════
}