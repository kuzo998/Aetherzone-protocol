// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWSHIDO is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title AetherPayGateway
 * @author Aetherzone Protocol
 * @notice Enterprise Web3 Payment Gateway & Invoicing Engine on Shido Network.
 *         Features:
 *         - Instant native SHIDO and ERC-20 invoice settlement
 *         - 5% native SHIDO payer discount when enabled by merchant
 *         - 0.3% protocol fee (capped at 1.0% maximum)
 *         - Direct peer-to-peer / user payments
 *         - Automated buyback: every $25 USDC fee accumulated is swapped for SHIDO
 *           and deposited directly into the AetherStake Protocol Treasury (0x3B3d1C18b61A40F057956f43bC501D94473fFE10).
 *         - Full ReentrancyGuard, SafeERC20, CEI adherence, and MEV frontrunning protection.
 */
contract AetherPayGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    address public treasury;
    address public immutable wshido;
    address public immutable usdc;
    address public immutable swapRouter;
    uint24 public constant POOL_FEE = 3000; // 0.3% USDC/WSHIDO Uniswap V3 fee tier

    uint256 public protocolFeeBps = 30; // 0.3% (basis points: 30 / 10000)
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100; // 1.0% max protocol fee cap

    uint256 public shidoDiscountBps = 500; // 5.0% (basis points: 500 / 10000)
    uint256 public constant MAX_SHIDO_DISCOUNT_BPS = 2000; // 20.0% max discount cap

    uint256 public buybackThreshold = 25 * 1e6; // $25 in USDC (6 decimals = 25,000,000)
    uint256 public totalBuybacksExecuted;
    uint256 public totalShidoDeliveredToTreasury;

    // Track accumulated protocol fees per token
    mapping(address => uint256) public accumulatedFees;
    // Authorized keeper bots permitted to trigger buybacks with custom slippage tolerance
    mapping(address => bool) public isKeeper;

    struct Invoice {
        bytes32 id;
        address merchant;
        address token; // address(0) for native SHIDO, or ERC-20 token address
        uint256 amount;
        bool allowShidoDiscount;
        bool isPaid;
        address payer;
        uint256 paidAt;
        uint256 expiry; // 0 for no expiry, or unix timestamp
        string memo;
    }

    mapping(bytes32 => Invoice) public invoices;
    bytes32[] public allInvoiceIds;
    mapping(address => bytes32[]) private _merchantInvoices;
    mapping(address => bytes32[]) private _payerInvoices;

    event InvoiceCreated(
        bytes32 indexed id,
        address indexed merchant,
        address token,
        uint256 amount,
        bool allowShidoDiscount,
        uint256 expiry,
        string memo
    );
    event PaymentSettled(
        bytes32 indexed id,
        address indexed payer,
        address indexed merchant,
        address token,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount
    );
    event DirectPaymentSettled(
        address indexed payer,
        address indexed merchant,
        address token,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        string memo
    );
    event BuybackExecuted(uint256 usdcIn, uint256 shidoOut, address indexed destination);
    event ThresholdUpdated(uint256 newThreshold);
    event TreasuryUpdated(address indexed newTreasury);
    event KeeperUpdated(address indexed keeper, bool authorized);
    event ProtocolFeeUpdated(uint256 newFeeBps);
    event ShidoDiscountUpdated(uint256 newDiscountBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyKeeperOrOwner() {
        require(msg.sender == owner || isKeeper[msg.sender], "Only keeper or owner");
        _;
    }

    constructor(
        address _owner,
        address _treasury,
        address _wshido,
        address _usdc,
        address _swapRouter
    ) {
        require(_owner != address(0), "Invalid owner");
        require(_treasury != address(0), "Invalid treasury");
        require(_wshido != address(0), "Invalid wshido");
        require(_usdc != address(0), "Invalid usdc");
        require(_swapRouter != address(0), "Invalid swapRouter");

        owner = _owner;
        treasury = _treasury;
        wshido = _wshido;
        usdc = _usdc;
        swapRouter = _swapRouter;

        // Owner is authorized keeper by default
        isKeeper[_owner] = true;
    }

    receive() external payable {
        // Contract can receive native SHIDO (e.g. for unwrapping or direct gifts)
    }

    /**
     * @notice Create a unique invoice on-chain
     * @param token Address of token (address(0) for native SHIDO)
     * @param amount Base invoice amount in token units
     * @param allowShidoDiscount If true, payers paying in native SHIDO get 5% discount
     * @param expiry Unix timestamp when invoice expires (0 for no expiry)
     * @param memo Human-readable description, order ID, or product reference
     */
    function createInvoice(
        address token,
        uint256 amount,
        bool allowShidoDiscount,
        uint256 expiry,
        string calldata memo
    ) external returns (bytes32 id) {
        require(amount > 0, "Invalid amount");
        if (expiry > 0) {
            require(expiry > block.timestamp, "Expiry must be in future");
        }

        id = keccak256(
            abi.encodePacked(
                msg.sender,
                token,
                amount,
                block.timestamp,
                allInvoiceIds.length,
                blockhash(block.number - 1)
            )
        );
        require(invoices[id].amount == 0, "Invoice exists");

        invoices[id] = Invoice({
            id: id,
            merchant: msg.sender,
            token: token,
            amount: amount,
            allowShidoDiscount: allowShidoDiscount,
            isPaid: false,
            payer: address(0),
            paidAt: 0,
            expiry: expiry,
            memo: memo
        });

        allInvoiceIds.push(id);
        _merchantInvoices[msg.sender].push(id);

        emit InvoiceCreated(id, msg.sender, token, amount, allowShidoDiscount, expiry, memo);
    }

    /**
     * @notice Settle an existing invoice
     * @param id The invoice ID to settle
     */
    function payInvoice(bytes32 id) external payable nonReentrant {
        Invoice storage inv = invoices[id];
        require(inv.amount > 0, "Invoice not found");
        require(!inv.isPaid, "Already paid");
        if (inv.expiry > 0) {
            require(block.timestamp <= inv.expiry, "Invoice expired");
        }

        // Calculate gross payable amount (with 5% SHIDO discount if applicable)
        uint256 grossAmount = inv.amount;
        if (inv.allowShidoDiscount && inv.token == address(0)) {
            grossAmount = (inv.amount * (10000 - shidoDiscountBps)) / 10000;
        }

        uint256 feeAmount = (grossAmount * protocolFeeBps) / 10000;
        uint256 netMerchantAmount = grossAmount - feeAmount;

        // CHECKS-EFFECTS: Update invoice state before executing transfers
        inv.isPaid = true;
        inv.payer = msg.sender;
        inv.paidAt = block.timestamp;
        _payerInvoices[msg.sender].push(id);

        // INTERACTIONS
        if (inv.token == address(0)) {
            require(msg.value == grossAmount, "Exact SHIDO amount required");

            // Transfer net SHIDO to merchant
            (bool success, ) = inv.merchant.call{value: netMerchantAmount}("");
            require(success, "Merchant transfer failed");

            // Forward protocol fee directly to Treasury as WSHIDO
            if (feeAmount > 0) {
                IWSHIDO(wshido).deposit{value: feeAmount}();
                IERC20(wshido).safeTransfer(treasury, feeAmount);
                totalShidoDeliveredToTreasury += feeAmount;
            }
        } else {
            require(msg.value == 0, "No native value expected");

            // Transfer net tokens directly to merchant
            IERC20(inv.token).safeTransferFrom(msg.sender, inv.merchant, netMerchantAmount);

            // Transfer protocol fee to this gateway for automated buyback / treasury routing
            if (feeAmount > 0) {
                IERC20(inv.token).safeTransferFrom(msg.sender, address(this), feeAmount);
                accumulatedFees[inv.token] += feeAmount;
            }
        }

        emit PaymentSettled(id, msg.sender, inv.merchant, inv.token, grossAmount, netMerchantAmount, feeAmount);
    }

    /**
     * @notice Direct one-off payment to any recipient (peer-to-peer / merchant checkout)
     * @param merchant Destination recipient address
     * @param token Address of token (address(0) for native SHIDO)
     * @param amount Amount to send
     * @param memo Human-readable payment reference
     */
    function payDirect(
        address merchant,
        address token,
        uint256 amount,
        string calldata memo
    ) external payable nonReentrant {
        require(merchant != address(0), "Invalid merchant");
        require(amount > 0, "Invalid amount");

        uint256 feeAmount = (amount * protocolFeeBps) / 10000;
        uint256 netMerchantAmount = amount - feeAmount;

        if (token == address(0)) {
            require(msg.value == amount, "Exact SHIDO amount required");

            (bool success, ) = merchant.call{value: netMerchantAmount}("");
            require(success, "Merchant transfer failed");

            if (feeAmount > 0) {
                IWSHIDO(wshido).deposit{value: feeAmount}();
                IERC20(wshido).safeTransfer(treasury, feeAmount);
                totalShidoDeliveredToTreasury += feeAmount;
            }
        } else {
            require(msg.value == 0, "No native value expected");

            IERC20(token).safeTransferFrom(msg.sender, merchant, netMerchantAmount);

            if (feeAmount > 0) {
                IERC20(token).safeTransferFrom(msg.sender, address(this), feeAmount);
                accumulatedFees[token] += feeAmount;
            }
        }

        emit DirectPaymentSettled(msg.sender, merchant, token, amount, netMerchantAmount, feeAmount, memo);
    }

    /**
     * @notice Execute automated buyback: Swaps accumulated USDC fees into SHIDO
     *         and sends 100% of the purchased SHIDO directly to AetherStake Treasury.
     *         Protected by onlyKeeperOrOwner to eliminate sandwich attacks & MEV frontrunning.
     * @param minShidoOut Minimum WSHIDO output expected (slippage protection)
     */
    function executeBuyback(uint256 minShidoOut) external onlyKeeperOrOwner nonReentrant returns (uint256 shidoOut) {
        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        require(usdcBal >= buybackThreshold, "Below buyback threshold");
        require(minShidoOut > 0, "minShidoOut must be > 0");

        // Reset tracked accumulated USDC fee
        if (accumulatedFees[usdc] >= usdcBal) {
            accumulatedFees[usdc] -= usdcBal;
        } else {
            accumulatedFees[usdc] = 0;
        }

        // Safe approve Uniswap V3 SwapRouter
        IERC20(usdc).forceApprove(swapRouter, usdcBal);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: usdc,
            tokenOut: wshido,
            fee: POOL_FEE,
            recipient: treasury, // Direct delivery to AetherStake Treasury!
            deadline: block.timestamp,
            amountIn: usdcBal,
            amountOutMinimum: minShidoOut,
            sqrtPriceLimitX96: 0
        });

        shidoOut = ISwapRouter(swapRouter).exactInputSingle(params);
        totalBuybacksExecuted += 1;
        totalShidoDeliveredToTreasury += shidoOut;

        emit BuybackExecuted(usdcBal, shidoOut, treasury);
    }

    /**
     * @notice Forward any accumulated non-USDC ERC-20 fees directly to Treasury
     */
    function sweepFeesToTreasury(address token) external onlyKeeperOrOwner nonReentrant {
        require(token != address(0), "Invalid token");
        require(token != usdc, "Use executeBuyback for USDC");
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "No balance");
        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(treasury, bal);
    }

    // ─── ADMIN FUNCTIONS ──────────────────────────────────────────────────────

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setKeeper(address keeper, bool authorized) external onlyOwner {
        require(keeper != address(0), "Invalid keeper");
        isKeeper[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

    function setBuybackThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold >= 1 * 1e6, "Threshold too low");
        buybackThreshold = newThreshold;
        emit ThresholdUpdated(newThreshold);
    }

    function setProtocolFeeBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_PROTOCOL_FEE_BPS, "Fee exceeds maximum allowed cap");
        protocolFeeBps = newBps;
        emit ProtocolFeeUpdated(newBps);
    }

    function setShidoDiscountBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_SHIDO_DISCOUNT_BPS, "Discount exceeds maximum allowed cap");
        shidoDiscountBps = newBps;
        emit ShidoDiscountUpdated(newBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        address prev = owner;
        owner = newOwner;
        isKeeper[newOwner] = true;
        emit OwnershipTransferred(prev, newOwner);
    }

    /**
     * @notice Rescue accidentally sent tokens (protects accumulated USDC protocol fees)
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid destination");
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            require(amount <= bal, "Insufficient balance");
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "Transfer failed");
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (token == usdc) {
                // Safeguard: Cannot rescue accumulated USDC fees
                require(bal > accumulatedFees[usdc], "No unallocated USDC");
                uint256 available = bal - accumulatedFees[usdc];
                require(amount <= available, "Amount exceeds unallocated");
            } else {
                require(amount <= bal, "Insufficient balance");
            }
            IERC20(token).safeTransfer(to, amount);
        }
        emit TokensRescued(token, to, amount);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────────────────

    function getInvoice(bytes32 id) external view returns (Invoice memory) {
        return invoices[id];
    }

    function getAllInvoiceIds() external view returns (bytes32[] memory) {
        return allInvoiceIds;
    }

    function getInvoicesCount() external view returns (uint256) {
        return allInvoiceIds.length;
    }

    function getMerchantInvoices(address merchant) external view returns (bytes32[] memory) {
        return _merchantInvoices[merchant];
    }

    function getPayerInvoices(address payer) external view returns (bytes32[] memory) {
        return _payerInvoices[payer];
    }

    function canExecuteBuyback() external view returns (bool eligible, uint256 currentBalance, uint256 threshold) {
        currentBalance = IERC20(usdc).balanceOf(address(this));
        threshold = buybackThreshold;
        eligible = currentBalance >= threshold;
    }
}
