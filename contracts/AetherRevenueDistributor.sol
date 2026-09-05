// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherRevenueDistributor v1.0
//
// Receives SHIDO fees from platform (limit orders, subscriptions, etc.)
// and distributes to revenue streams:
//   70% → USDC  → Main treasury (operations & development)
//   10% → CHINA → China ecosystem treasury
//   10% → CWK   → ChinaWok ecosystem treasury
//   10% → WSHIDO → Dev/team treasury
//
// Distribution flow:
//   1. Contract receives SHIDO (native) or WSHIDO
//   2. On distribute() call: wraps SHIDO → WSHIDO
//   3. Swaps portions via ShidoDEX V3 Router to USDC, CHINA, CWK
//   4. Sends each token to its respective treasury
//
// Security: Only owner can change config, pausable, reentrancy guard.
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IWSHIDO {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV3Router {
    // Shido's ShidoDEX V3 router does NOT have 'deadline' in exactInputSingle
    // Verified from Frontend/services/abis.ts SWAP_ROUTER_V2_ABI
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

contract AetherRevenueDistributor {

    // ─── Addresses ────────────────────────────────────────────────────────────

    // ShidoDEX V3
    address public constant ROUTER   = 0x1c5316BA88a99a5c35389053D987aFfa502bfa8f;
    address public constant WSHIDO   = 0x8cbafFD9b658997E7bf87E98FEbF6EA6917166F7;
    address public constant USDC     = 0xeE1Fc22381e6B6bb5ee3bf6B5ec58DF6F5480dF8;

    // Ecosystem tokens (set via constructor / owner)
    address public chinaToken;
    address public cwkToken;

    // Treasury addresses
    address public mainTreasury;    // 70% USDC → main operations
    address public chinaTreasury;   // 10% CHINA → China ecosystem
    address public cwkTreasury;     // 10% CWK   → ChinaWok ecosystem
    address public devTreasury;     // 10% WSHIDO → Dev team

    // ─── Distribution Config ─────────────────────────────────────────────────

    uint256 public constant TOTAL_BPS      = 10000;
    uint256 public mainBps   = 7000; // 70% USDC
    uint256 public chinaBps  = 1000; // 10% CHINA
    uint256 public cwkBps    = 1000; // 10% CWK
    uint256 public devBps    = 1000; // 10% WSHIDO (residual)

    // Pool fee tiers to use for each swap
    uint24 public wshidoToUsdcFee  = 3000;
    uint24 public wshidoToChinaFee = 3000;
    uint24 public wshidoToCwkFee   = 10000;

    // Slippage tolerance (in BPS): 500 = 5%
    uint256 public maxSlippageBps = 500;

    // Minimum accumulation before distributing (avoid dust distributions)
    uint256 public minDistributeWei = 1 ether; // 1 SHIDO

    // ─── State ────────────────────────────────────────────────────────────────

    address public owner;
    bool    public paused;
    uint256 private _lock;

    uint256 public totalDistributed;    // Total SHIDO distributed (wei)
    uint256 public lastDistributeTime;

    // ─── Events ───────────────────────────────────────────────────────────────

    event RevenueReceived(address indexed from, uint256 amount);
    event Distributed(
        uint256 totalShido,
        uint256 usdcSent,
        uint256 chinaSent,
        uint256 cwkSent,
        uint256 wsshidoSent,
        uint256 timestamp
    );
    event ConfigUpdated(string key);
    event SwapFailed(address tokenOut, string reason);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "RD: Not owner");
        _;
    }

    modifier nonReentrant() {
        require(_lock == 0, "RD: Reentrant");
        _lock = 1; _; _lock = 0;
    }

    modifier whenNotPaused() {
        require(!paused, "RD: Paused");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _chinaToken,
        address _cwkToken,
        address _mainTreasury,
        address _chinaTreasury,
        address _cwkTreasury,
        address _devTreasury
    ) {
        owner         = msg.sender;
        chinaToken    = _chinaToken;
        cwkToken      = _cwkToken;
        mainTreasury  = _mainTreasury;
        chinaTreasury = _chinaTreasury;
        cwkTreasury   = _cwkTreasury;
        devTreasury   = _devTreasury;

        // Validate BPS sum
        require(mainBps + chinaBps + cwkBps + devBps == TOTAL_BPS, "RD: BPS mismatch");
    }

    // ─── Revenue Collection ───────────────────────────────────────────────────

    /// @notice Receive SHIDO (native) as revenue
    receive() external payable {
        emit RevenueReceived(msg.sender, msg.value);
    }

    /// @notice Accept WSHIDO as revenue (from contracts that send ERC20)
    function receiveWshido(uint256 amount) external nonReentrant {
        require(IERC20(WSHIDO).transferFrom(msg.sender, address(this), amount), "RD: Transfer failed");
        emit RevenueReceived(msg.sender, amount);
    }

    // ─── Core Distribution Logic ──────────────────────────────────────────────

    /**
     * @notice Distribute accumulated revenue to all treasuries.
     *         Can be called by owner or a keeper bot.
     *         Converts SHIDO → WSHIDO, then swaps to target tokens.
     */
    function distribute() external nonReentrant whenNotPaused {
        uint256 nativeBal = address(this).balance;

        // Wrap native SHIDO to WSHIDO
        if (nativeBal > 0) {
            IWSHIDO(WSHIDO).deposit{value: nativeBal}();
        }

        uint256 totalWshido = IWSHIDO(WSHIDO).balanceOf(address(this));
        require(totalWshido >= minDistributeWei, "RD: Below minimum");

        uint256 mainAmount  = (totalWshido * mainBps)  / TOTAL_BPS;
        uint256 chinaAmount = (totalWshido * chinaBps)  / TOTAL_BPS;
        uint256 cwkAmount   = (totalWshido * cwkBps)    / TOTAL_BPS;
        uint256 devAmount   = totalWshido - mainAmount - chinaAmount - cwkAmount;

        uint256 usdcSent  = 0;
        uint256 chinaSent = 0;
        uint256 cwkSent   = 0;

        IUniswapV3Router router = IUniswapV3Router(ROUTER);

        // ── 70%: WSHIDO → USDC → mainTreasury ────────────────────────────────
        if (mainAmount > 0) {
            IERC20(WSHIDO).approve(ROUTER, mainAmount);
            try router.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
                tokenIn:           WSHIDO,
                tokenOut:          USDC,
                fee:               wshidoToUsdcFee,
                recipient:         mainTreasury,
                amountIn:          mainAmount,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })) returns (uint256 amtOut) {
                usdcSent = amtOut;
            } catch Error(string memory reason) {
                IERC20(WSHIDO).transfer(mainTreasury, mainAmount);
                emit SwapFailed(USDC, reason);
            } catch {
                IERC20(WSHIDO).transfer(mainTreasury, mainAmount);
                emit SwapFailed(USDC, "unknown");
            }
            IERC20(WSHIDO).approve(ROUTER, 0);
        }

        // ── 10%: WSHIDO → CHINA → chinaTreasury ──────────────────────────────
        if (chinaAmount > 0 && chinaToken != address(0)) {
            IERC20(WSHIDO).approve(ROUTER, chinaAmount);
            try router.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
                tokenIn:           WSHIDO,
                tokenOut:          chinaToken,
                fee:               wshidoToChinaFee,
                recipient:         chinaTreasury,
                amountIn:          chinaAmount,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })) returns (uint256 amtOut) {
                chinaSent = amtOut;
            } catch Error(string memory reason) {
                IERC20(WSHIDO).transfer(chinaTreasury, chinaAmount);
                emit SwapFailed(chinaToken, reason);
            } catch {
                IERC20(WSHIDO).transfer(chinaTreasury, chinaAmount);
                emit SwapFailed(chinaToken, "unknown");
            }
            IERC20(WSHIDO).approve(ROUTER, 0);
        } else if (chinaAmount > 0) {
            IERC20(WSHIDO).transfer(chinaTreasury, chinaAmount);
        }

        // ── 10%: WSHIDO → CWK → cwkTreasury ──────────────────────────────────
        if (cwkAmount > 0 && cwkToken != address(0)) {
            IERC20(WSHIDO).approve(ROUTER, cwkAmount);
            try router.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
                tokenIn:           WSHIDO,
                tokenOut:          cwkToken,
                fee:               wshidoToCwkFee,
                recipient:         cwkTreasury,
                amountIn:          cwkAmount,
                amountOutMinimum:  0,
                sqrtPriceLimitX96: 0
            })) returns (uint256 amtOut) {
                cwkSent = amtOut;
            } catch Error(string memory reason) {
                IERC20(WSHIDO).transfer(cwkTreasury, cwkAmount);
                emit SwapFailed(cwkToken, reason);
            } catch {
                IERC20(WSHIDO).transfer(cwkTreasury, cwkAmount);
                emit SwapFailed(cwkToken, "unknown");
            }
            IERC20(WSHIDO).approve(ROUTER, 0);
        } else if (cwkAmount > 0) {
            IERC20(WSHIDO).transfer(cwkTreasury, cwkAmount);
        }

        // ── 10%: WSHIDO → devTreasury (no swap needed) ───────────────────────
        if (devAmount > 0) {
            IERC20(WSHIDO).transfer(devTreasury, devAmount);
        }

        totalDistributed  += totalWshido;
        lastDistributeTime = block.timestamp;

        emit Distributed(totalWshido, usdcSent, chinaSent, cwkSent, devAmount, block.timestamp);
    }

    /// @notice Check pending balance + whether min threshold is met
    function getPendingDistribution() external view returns (
        uint256 nativeBalance,
        uint256 wshidoBalance,
        uint256 totalWshido,
        bool    readyToDistribute
    ) {
        nativeBalance = address(this).balance;
        wshidoBalance = IERC20(WSHIDO).balanceOf(address(this));
        totalWshido   = nativeBalance + wshidoBalance;
        readyToDistribute = totalWshido >= minDistributeWei;
    }

    // ─── Admin Configuration ──────────────────────────────────────────────────

    function setTreasuries(
        address _main, address _china, address _cwk, address _dev
    ) external onlyOwner {
        require(_main != address(0) && _china != address(0) && _cwk != address(0) && _dev != address(0));
        mainTreasury  = _main;
        chinaTreasury = _china;
        cwkTreasury   = _cwk;
        devTreasury   = _dev;
        emit ConfigUpdated("treasuries");
    }

    function setDistributionBps(
        uint256 _main, uint256 _china, uint256 _cwk, uint256 _dev
    ) external onlyOwner {
        require(_main + _china + _cwk + _dev == TOTAL_BPS, "RD: BPS must sum to 10000");
        mainBps  = _main;
        chinaBps = _china;
        cwkBps   = _cwk;
        devBps   = _dev;
        emit ConfigUpdated("distributionBps");
    }

    function setTokens(address _china, address _cwk) external onlyOwner {
        chinaToken = _china;
        cwkToken   = _cwk;
        emit ConfigUpdated("tokens");
    }

    function setPoolFees(uint24 _usdcFee, uint24 _chinaFee, uint24 _cwkFee) external onlyOwner {
        wshidoToUsdcFee  = _usdcFee;
        wshidoToChinaFee = _chinaFee;
        wshidoToCwkFee   = _cwkFee;
        emit ConfigUpdated("poolFees");
    }

    function setMinDistributeWei(uint256 _min) external onlyOwner { minDistributeWei = _min; }
    function setPaused(bool _paused) external onlyOwner { paused = _paused; }
    function transferOwnership(address newOwner) external onlyOwner { owner = newOwner; }

    /// @notice Emergency token rescue
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = payable(owner).call{value: amount}("");
            require(ok);
        } else {
            IERC20(token).transfer(owner, amount);
        }
    }
}
