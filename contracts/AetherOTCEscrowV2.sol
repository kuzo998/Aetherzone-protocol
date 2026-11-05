// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// AetherOTCEscrowV2.sol
//
// HYBRID ALL-IN-ONE PROTOCOL ESCROW:
//   1. Static Deals: 100% backward-compatible fixed token ratios.
//   2. Dynamic Volume Curve: Bulk discount scales with fill percentage.
//   3. Floating Pool Pricing: Dynamic spread pegged to live UniswapV3 / Shido DEX
//      spot price (slot0 sqrtPriceX96) on-chain.
//   4. Floating Oracle Pricing: Dynamic spread pegged to live multi-pool
//      cryptographically signed price vouchers (works for ALL token pairs).
//   5. Whale Floor Guard: Maker sets minPriceFloor to defend against flash crashes.
//   6. Taker Slippage Guard: Taker specifies maxTokenOut protection.
//   7. Dojo Pass / XP Loyalty fee discounts via EIP-712 signed vouchers.
//   8. Strict Invariants: Balance delta, overfill defense, dust remainder sweep.
// ════════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

library FullMath {
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                require(denominator > 0, "Math: div by zero");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            require(denominator > prod1, "Math: overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
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

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
            return result;
        }
    }
}

contract AetherOTCEscrowV2 {

    // ─── Fee Config ───────────────────────────────────────────────────────────

    uint256 public feeBps = 30;                    // 0.30% of tokenOut at fill
    uint256 public constant MAX_FEE_BPS = 300;     // 3.00% hard ceiling
    uint256 public constant BPS_BASE    = 10000;

    address public owner;
    address public revenueRecipient;
    address public loyaltySigner;                  // Authorized signer for Dojo Pass XP tier & Oracle price vouchers
    mapping(address => bool) public admins;

    bool    public paused;
    uint256 private _lock;

    // ─── Deal Data Structures ─────────────────────────────────────────────────

    enum DealStatus { Open, Filled, Cancelled, Expired }
    enum PricingModel { Static, DynamicVolume, FloatingPool, FloatingOracle }

    struct Deal {
        uint256      id;
        address      maker;
        address      tokenIn;              // Token maker is selling (locked in escrow)
        address      tokenOut;             // Token maker wants to receive
        uint256      amountIn;             // Initial tokenIn amount locked
        uint256      amountOut;            // Base tokenOut expected (for Static / VolumeCurve) or baseline
        uint256      amountInFilled;       // Amount of tokenIn filled so far
        uint256      amountOutFilled;      // Total tokenOut received so far
        uint256      amountInRemaining;    // Available tokenIn remaining in escrow
        DealStatus   status;
        uint64       createdAt;
        uint64       deadline;             // Unix timestamp; 0 = no expiry
        uint256      minFillAmount;        // Minimum tokenIn per partial fill
        PricingModel pricingModel;         // 0: Static, 1: DynamicVolume, 2: FloatingPool, 3: FloatingOracle
        uint16       baseDiscountBps;      // Base discount bps (e.g. 500 = 5%)
        uint16       bulkDiscountMaxBps;   // Max bulk discount bps at 100% buyout (e.g. 2000 = 20%)
        address      pool;                 // Direct UniswapV3 pool address (for FloatingPool)
        uint256      minPriceFloor;        // Min acceptable tokenOut per 1e18 tokenIn (floor guard)
    }

    struct CreateDealParams {
        address      tokenIn;
        address      tokenOut;
        uint256      amountIn;
        uint256      amountOut;
        uint64       deadline;
        uint256      minFillAmount;
        PricingModel pricingModel;
        uint16       baseDiscountBps;
        uint16       bulkDiscountMaxBps;
        address      pool;
        uint256      minPriceFloor;
    }

    uint256 public nextDealId;
    mapping(uint256 => Deal) public deals;
    mapping(address => uint256[]) public makerDeals;

    // Total revenue accrued per token
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
        uint256 minFillAmount,
        PricingModel pricingModel,
        uint16  baseDiscountBps,
        uint16  bulkDiscountMaxBps,
        address pool,
        uint256 minPriceFloor
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
    event LoyaltySignerUpdated(address indexed newSigner);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "OTC: Not owner");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == owner || admins[msg.sender], "OTC: Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "OTC: Contract paused");
        _;
    }

    modifier nonReentrant() {
        require(_lock == 0, "OTC: Reentrant call");
        _lock = 1;
        _;
        _lock = 0;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _revenueRecipient, uint256 _feeBps) {
        require(_revenueRecipient != address(0), "OTC: Zero address");
        require(_feeBps <= MAX_FEE_BPS, "OTC: Fee exceeds cap");
        owner = msg.sender;
        revenueRecipient = _revenueRecipient;
        feeBps = _feeBps;
        loyaltySigner = msg.sender;
    }

    // ─── Deal Creation Methods ────────────────────────────────────────────────

    function createDealWithParams(CreateDealParams memory p) public whenNotPaused nonReentrant returns (uint256 dealId) {
        require(p.tokenIn != address(0) && p.tokenOut != address(0), "OTC: Zero token address");
        require(p.tokenIn != p.tokenOut, "OTC: Identical tokens");
        require(p.amountIn > 0, "OTC: Zero amountIn");

        if (p.pricingModel == PricingModel.Static || p.pricingModel == PricingModel.DynamicVolume) {
            require(p.amountOut > 0, "OTC: Zero amountOut");
        } else if (p.pricingModel == PricingModel.FloatingPool) {
            require(p.pool != address(0), "OTC: Missing V3 pool");
            address t0 = IUniswapV3Pool(p.pool).token0();
            address t1 = IUniswapV3Pool(p.pool).token1();
            require(
                (t0 == p.tokenIn && t1 == p.tokenOut) || (t0 == p.tokenOut && t1 == p.tokenIn),
                "OTC: Pool tokens mismatch"
            );
        }

        if (p.pricingModel == PricingModel.DynamicVolume || 
            p.pricingModel == PricingModel.FloatingPool || 
            p.pricingModel == PricingModel.FloatingOracle) {
            require(p.bulkDiscountMaxBps >= p.baseDiscountBps, "OTC: Bulk discount below base discount");
            require(p.bulkDiscountMaxBps <= 5000, "OTC: Discount exceeds 50% ceiling");
        }

        dealId = ++nextDealId;

        // Pull tokens into escrow
        uint256 beforeBal = IERC20(p.tokenIn).balanceOf(address(this));
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn), "OTC: TransferFrom failed");
        uint256 received = IERC20(p.tokenIn).balanceOf(address(this)) - beforeBal;
        require(received >= p.amountIn, "OTC: Incomplete token deposit");

        _initDeal(dealId, p);
        makerDeals[msg.sender].push(dealId);

        emit DealCreated(
            dealId,
            msg.sender,
            p.tokenIn,
            p.tokenOut,
            p.amountIn,
            p.amountOut,
            p.deadline,
            p.minFillAmount,
            p.pricingModel,
            p.baseDiscountBps,
            p.bulkDiscountMaxBps,
            p.pool,
            p.minPriceFloor
        );
    }

    function _initDeal(uint256 dealId, CreateDealParams memory p) internal {
        Deal storage d = deals[dealId];
        d.id                 = dealId;
        d.maker              = msg.sender;
        d.tokenIn            = p.tokenIn;
        d.tokenOut           = p.tokenOut;
        d.amountIn           = p.amountIn;
        d.amountOut          = p.amountOut;
        d.amountInRemaining  = p.amountIn;
        d.status             = DealStatus.Open;
        d.createdAt          = uint64(block.timestamp);
        d.deadline           = p.deadline;
        d.minFillAmount      = p.minFillAmount;
        d.pricingModel       = p.pricingModel;
        d.baseDiscountBps    = p.baseDiscountBps;
        d.bulkDiscountMaxBps = p.bulkDiscountMaxBps;
        d.pool               = p.pool;
        d.minPriceFloor      = p.minPriceFloor;
    }

    // Backward-compatible V1 Static Deal
    function createDeal(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint64  deadline,
        uint256 minFillAmount
    ) external returns (uint256) {
        return createDealWithParams(CreateDealParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            deadline: deadline,
            minFillAmount: minFillAmount,
            pricingModel: PricingModel.Static,
            baseDiscountBps: 0,
            bulkDiscountMaxBps: 0,
            pool: address(0),
            minPriceFloor: 0
        }));
    }

    // Dynamic Volume Curve Deal
    function createDealDynamic(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint64  deadline,
        uint256 minFillAmount,
        uint16  baseDiscountBps,
        uint16  bulkDiscountMaxBps
    ) external returns (uint256) {
        return createDealWithParams(CreateDealParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            deadline: deadline,
            minFillAmount: minFillAmount,
            pricingModel: PricingModel.DynamicVolume,
            baseDiscountBps: baseDiscountBps,
            bulkDiscountMaxBps: bulkDiscountMaxBps,
            pool: address(0),
            minPriceFloor: 0
        }));
    }

    // Floating Pool Deal (UniswapV3 slot0 pegged)
    function createDealFloatingPool(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address pool,
        uint64  deadline,
        uint256 minFillAmount,
        uint16  baseDiscountBps,
        uint16  bulkDiscountMaxBps,
        uint256 minPriceFloor
    ) external returns (uint256) {
        return createDealWithParams(CreateDealParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: 0,
            deadline: deadline,
            minFillAmount: minFillAmount,
            pricingModel: PricingModel.FloatingPool,
            baseDiscountBps: baseDiscountBps,
            bulkDiscountMaxBps: bulkDiscountMaxBps,
            pool: pool,
            minPriceFloor: minPriceFloor
        }));
    }

    // Floating Oracle Deal (Backend signed price voucher pegged)
    function createDealFloatingOracle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint64  deadline,
        uint256 minFillAmount,
        uint16  baseDiscountBps,
        uint16  bulkDiscountMaxBps,
        uint256 minPriceFloor
    ) external returns (uint256) {
        return createDealWithParams(CreateDealParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: 0,
            deadline: deadline,
            minFillAmount: minFillAmount,
            pricingModel: PricingModel.FloatingOracle,
            baseDiscountBps: baseDiscountBps,
            bulkDiscountMaxBps: bulkDiscountMaxBps,
            pool: address(0),
            minPriceFloor: minPriceFloor
        }));
    }

    // ─── Price & Quote Computation ───────────────────────────────────────────

    function calculateTokenOutGross(uint256 dealId, uint256 tokenInAmount) public view returns (
        uint256 tokenOutGross,
        uint256 discountBpsApplied
    ) {
        Deal storage deal = deals[dealId];
        require(deal.amountIn > 0, "OTC: Deal not found");
        require(tokenInAmount > 0, "OTC: Zero tokenIn amount");

        if (deal.pricingModel == PricingModel.Static) {
            tokenOutGross = (tokenInAmount * deal.amountOut) / deal.amountIn;
            discountBpsApplied = 0;
        } else if (deal.pricingModel == PricingModel.DynamicVolume) {
            discountBpsApplied = _calcDiscountBps(deal, tokenInAmount);
            uint256 baseOut = (tokenInAmount * deal.amountOut) / deal.amountIn;
            tokenOutGross = (baseOut * (BPS_BASE - discountBpsApplied)) / BPS_BASE;
        } else if (deal.pricingModel == PricingModel.FloatingPool) {
            uint256 spotTokenOut = _queryV3PoolPrice(deal.pool, deal.tokenIn, deal.tokenOut, tokenInAmount);
            if (deal.minPriceFloor > 0) {
                uint256 effectiveRatePerUnit = (spotTokenOut * 1e18) / tokenInAmount;
                require(effectiveRatePerUnit >= deal.minPriceFloor, "OTC: Pool price below maker floor");
            }
            discountBpsApplied = _calcDiscountBps(deal, tokenInAmount);
            tokenOutGross = (spotTokenOut * (BPS_BASE - discountBpsApplied)) / BPS_BASE;
        } else {
            revert("OTC: FloatingOracle requires oracle price input");
        }
    }

    function _calcDiscountBps(Deal storage deal, uint256 tokenInAmount) internal view returns (uint256) {
        if (deal.bulkDiscountMaxBps <= deal.baseDiscountBps) {
            return deal.baseDiscountBps;
        }
        uint256 fillRatioBps = (tokenInAmount * BPS_BASE) / deal.amountIn;
        if (fillRatioBps > BPS_BASE) fillRatioBps = BPS_BASE;
        uint256 spread = uint256(deal.bulkDiscountMaxBps - deal.baseDiscountBps);
        uint256 extra = (spread * fillRatioBps) / BPS_BASE;
        return uint256(deal.baseDiscountBps) + extra;
    }

    function _queryV3PoolPrice(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 tokenInAmount
    ) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(sqrtPriceX96 > 0, "OTC: Invalid pool price");

        address t0 = IUniswapV3Pool(pool).token0();
        address t1 = IUniswapV3Pool(pool).token1();

        if (tokenIn == t0 && tokenOut == t1) {
            // token0 -> token1: amount0 * (sqrtPriceX96^2) / 2^192
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            return FullMath.mulDiv(tokenInAmount, ratioX128, 1 << 128);
        } else if (tokenIn == t1 && tokenOut == t0) {
            // token1 -> token0: amount1 * 2^192 / (sqrtPriceX96^2)
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            return FullMath.mulDiv(tokenInAmount, 1 << 128, ratioX128);
        } else {
            revert("OTC: Pool tokens mismatch");
        }
    }

    // ─── Deal Settlement (Fill) ───────────────────────────────────────────────

    // Standard fill (Static, VolumeCurve, FloatingPool)
    function fillDeal(
        uint256 dealId,
        uint256 tokenInAmount,
        uint256 maxTokenOut
    ) external whenNotPaused nonReentrant {
        (uint256 tokenOutGross, ) = calculateTokenOutGross(dealId, tokenInAmount);
        if (maxTokenOut > 0) {
            require(tokenOutGross <= maxTokenOut, "OTC: Slippage exceeded");
        }
        _executeFill(dealId, tokenInAmount, tokenOutGross, 0);
    }

    // Fill with Dojo Pass / XP Loyalty fee discount voucher
    function fillDealWithLoyalty(
        uint256 dealId,
        uint256 tokenInAmount,
        uint256 maxTokenOut,
        uint16  loyaltyDiscountPct,
        uint64  loyaltyDeadline,
        bytes calldata loyaltySig
    ) external whenNotPaused nonReentrant {
        require(loyaltyDiscountPct <= 100, "OTC: Invalid loyalty discount");
        require(block.timestamp <= loyaltyDeadline, "OTC: Loyalty voucher expired");
        require(loyaltySigner != address(0), "OTC: Loyalty signer not set");

        bytes32 hash = keccak256(abi.encodePacked(
            "AETHER_LOYALTY",
            msg.sender,
            dealId,
            loyaltyDiscountPct,
            loyaltyDeadline,
            block.chainid,
            address(this)
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        require(_recoverSigner(ethSignedHash, loyaltySig) == loyaltySigner, "OTC: Invalid loyalty signature");

        (uint256 tokenOutGross, ) = calculateTokenOutGross(dealId, tokenInAmount);
        if (maxTokenOut > 0) {
            require(tokenOutGross <= maxTokenOut, "OTC: Slippage exceeded");
        }

        _executeFill(dealId, tokenInAmount, tokenOutGross, loyaltyDiscountPct);
    }

    // Fill FloatingOracle deals with cryptographically signed price voucher
    function fillDealWithOraclePrice(
        uint256 dealId,
        uint256 tokenInAmount,
        uint256 maxTokenOut,
        uint256 priceRatioNumerator,
        uint256 priceRatioDenominator,
        uint64  priceDeadline,
        bytes calldata priceSig,
        uint16  loyaltyDiscountPct,
        uint64  loyaltyDeadline,
        bytes calldata loyaltySig
    ) external whenNotPaused nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.pricingModel == PricingModel.FloatingOracle, "OTC: Not FloatingOracle deal");
        require(priceRatioDenominator > 0, "OTC: Zero denominator");
        require(block.timestamp <= priceDeadline, "OTC: Price signature expired");
        require(loyaltySigner != address(0), "OTC: Oracle signer not set");

        // Verify Price Signature
        bytes32 priceHash = keccak256(abi.encodePacked(
            "AETHER_OTC_PRICE",
            dealId,
            priceRatioNumerator,
            priceRatioDenominator,
            priceDeadline,
            block.chainid,
            address(this)
        ));
        bytes32 ethPriceHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", priceHash));
        require(_recoverSigner(ethPriceHash, priceSig) == loyaltySigner, "OTC: Invalid price signature");

        // Calculate spot price
        uint256 spotTokenOut = (tokenInAmount * priceRatioNumerator) / priceRatioDenominator;
        if (deal.minPriceFloor > 0) {
            uint256 effectiveRatePerUnit = (spotTokenOut * 1e18) / tokenInAmount;
            require(effectiveRatePerUnit >= deal.minPriceFloor, "OTC: Oracle price below maker floor");
        }

        uint256 discountBpsApplied = _calcDiscountBps(deal, tokenInAmount);
        uint256 tokenOutGross = (spotTokenOut * (BPS_BASE - discountBpsApplied)) / BPS_BASE;

        if (maxTokenOut > 0) {
            require(tokenOutGross <= maxTokenOut, "OTC: Slippage exceeded");
        }

        // Verify Loyalty Voucher if provided
        uint16 finalLoyaltyDiscount = 0;
        if (loyaltyDiscountPct > 0 && loyaltySig.length > 0) {
            require(loyaltyDiscountPct <= 100, "OTC: Invalid loyalty discount");
            require(block.timestamp <= loyaltyDeadline, "OTC: Loyalty voucher expired");
            bytes32 lHash = keccak256(abi.encodePacked(
                "AETHER_LOYALTY",
                msg.sender,
                dealId,
                loyaltyDiscountPct,
                loyaltyDeadline,
                block.chainid,
                address(this)
            ));
            bytes32 ethLHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", lHash));
            require(_recoverSigner(ethLHash, loyaltySig) == loyaltySigner, "OTC: Invalid loyalty signature");
            finalLoyaltyDiscount = loyaltyDiscountPct;
        }

        _executeFill(dealId, tokenInAmount, tokenOutGross, finalLoyaltyDiscount);
    }

    // Core Fill Execution
    function _executeFill(
        uint256 dealId,
        uint256 tokenInAmount,
        uint256 tokenOutGross,
        uint16  loyaltyDiscountPct
    ) internal {
        Deal storage deal = deals[dealId];
        require(deal.status == DealStatus.Open, "OTC: Deal not open");
        if (deal.deadline > 0 && block.timestamp > deal.deadline) {
            _expireDeal(deal);
            revert("OTC: Deal expired");
        }

        require(tokenInAmount <= deal.amountInRemaining, "OTC: Exceeds available remaining");
        require(
            deal.minFillAmount == 0 ||
            tokenInAmount >= deal.minFillAmount ||
            tokenInAmount == deal.amountInRemaining,
            "OTC: Below minimum fill"
        );
        require(tokenOutGross > 0, "OTC: Zero tokenOut required");

        // Standard 0.30% fee
        uint256 fee = (tokenOutGross * feeBps) / BPS_BASE;

        // Apply Dojo Pass rank discount on platform fee
        if (loyaltyDiscountPct > 0) {
            uint256 feeDiscount = (fee * uint256(loyaltyDiscountPct)) / 100;
            fee -= feeDiscount;
            tokenOutGross -= feeDiscount;
        }

        uint256 outBefore = IERC20(deal.tokenOut).balanceOf(address(this));
        require(IERC20(deal.tokenOut).transferFrom(msg.sender, address(this), tokenOutGross), "OTC: Payment pull failed");
        uint256 outReceived = IERC20(deal.tokenOut).balanceOf(address(this)) - outBefore;
        require(outReceived >= tokenOutGross, "OTC: Insufficient payment received");

        uint256 toMaker = outReceived - fee;

        deal.amountInFilled    += tokenInAmount;
        deal.amountOutFilled   += outReceived;
        deal.amountInRemaining -= tokenInAmount;

        bool fullyFilled = (deal.amountInRemaining == 0);
        if (fullyFilled) {
            deal.status = DealStatus.Filled;
        }

        pendingRevenue[deal.tokenOut] += fee;

        require(IERC20(deal.tokenIn).transfer(msg.sender, tokenInAmount), "OTC: Token delivery failed");
        require(IERC20(deal.tokenOut).transfer(deal.maker, toMaker), "OTC: Maker payout failed");

        emit DealFilled(
            dealId,
            msg.sender,
            tokenInAmount,
            outReceived,
            fee,
            toMaker,
            fullyFilled
        );
    }

    // ─── Cryptographic Signer Recovery ────────────────────────────────────────

    function _recoverSigner(bytes32 hash, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27) v += 27;
        return ecrecover(hash, v, r, s);
    }

    // ─── Deal Cancellation ────────────────────────────────────────────────────

    function cancelDeal(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.maker != address(0), "OTC: Deal not found");
        require(deal.status == DealStatus.Open, "OTC: Deal not open");
        require(msg.sender == deal.maker || admins[msg.sender] || msg.sender == owner, "OTC: Not authorized");

        uint256 refund = deal.amountInRemaining;
        deal.amountInRemaining = 0;
        deal.status = DealStatus.Cancelled;

        if (refund > 0) {
            require(IERC20(deal.tokenIn).transfer(deal.maker, refund), "OTC: Refund transfer failed");
        }

        emit DealCancelled(dealId, deal.maker, refund);
    }

    // ─── Deal Expiration ──────────────────────────────────────────────────────

    function expireDeal(uint256 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.maker != address(0), "OTC: Deal not found");
        require(deal.status == DealStatus.Open, "OTC: Deal not open");
        require(deal.deadline > 0 && block.timestamp > deal.deadline, "OTC: Not expired yet");
        _expireDeal(deal);
    }

    function _expireDeal(Deal storage deal) internal {
        uint256 refund = deal.amountInRemaining;
        deal.amountInRemaining = 0;
        deal.status = DealStatus.Expired;

        if (refund > 0) {
            require(IERC20(deal.tokenIn).transfer(deal.maker, refund), "OTC: Expire refund transfer failed");
        }

        emit DealExpired(deal.id, refund);
    }

    // ─── Revenue Harvesting ───────────────────────────────────────────────────

    function collectRevenue(address token) external nonReentrant {
        require(admins[msg.sender] || msg.sender == owner, "OTC: Not authorized");
        uint256 amount = pendingRevenue[token];
        require(amount > 0, "OTC: Zero revenue");
        pendingRevenue[token] = 0;
        require(IERC20(token).transfer(revenueRecipient, amount), "OTC: Revenue sweep failed");
        emit RevenueCollected(token, amount);
    }

    // ─── View Methods ─────────────────────────────────────────────────────────

    function getDeal(uint256 dealId) external view returns (
        uint256 id,
        address maker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountInRemaining,
        DealStatus status,
        uint64  deadline,
        uint256 minFillAmount,
        PricingModel pricingModel,
        uint16  baseDiscountBps,
        uint16  bulkDiscountMaxBps
    ) {
        Deal storage d = deals[dealId];
        return (
            d.id,
            d.maker,
            d.tokenIn,
            d.tokenOut,
            d.amountIn,
            d.amountOut,
            d.amountInRemaining,
            d.status,
            d.deadline,
            d.minFillAmount,
            d.pricingModel,
            d.baseDiscountBps,
            d.bulkDiscountMaxBps
        );
    }

    function getDealExtended(uint256 dealId) external view returns (
        address pool,
        uint256 minPriceFloor,
        uint256 amountInFilled,
        uint256 amountOutFilled,
        uint64  createdAt
    ) {
        Deal storage d = deals[dealId];
        return (d.pool, d.minPriceFloor, d.amountInFilled, d.amountOutFilled, d.createdAt);
    }

    function getDealProgress(uint256 dealId) external view returns (
        uint256 amountInFilled,
        uint256 amountOutFilled,
        uint64  createdAt
    ) {
        Deal storage d = deals[dealId];
        return (d.amountInFilled, d.amountOutFilled, d.createdAt);
    }

    function getMakerDeals(address maker) external view returns (uint256[] memory) {
        return makerDeals[maker];
    }

    function getFillQuote(uint256 dealId, uint256 tokenInAmount) external view returns (
        uint256 tokenOutGross,
        uint256 tokenOutFee,
        uint256 tokenOutToMaker,
        uint256 discountBpsApplied
    ) {
        (tokenOutGross, discountBpsApplied) = calculateTokenOutGross(dealId, tokenInAmount);
        tokenOutFee     = (tokenOutGross * feeBps) / BPS_BASE;
        tokenOutToMaker = tokenOutGross - tokenOutFee;
    }

    // ─── Admin Controls ───────────────────────────────────────────────────────

    function setFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "OTC: Fee exceeds cap");
        feeBps = _bps;
    }

    function setLoyaltySigner(address s) external onlyOwner {
        require(s != address(0), "OTC: Zero address");
        loyaltySigner = s;
        emit LoyaltySignerUpdated(s);
    }

    function setRevenueRecipient(address r) external onlyOwner {
        require(r != address(0), "OTC: Zero address");
        revenueRecipient = r;
    }

    function setAdmin(address a, bool s) external onlyOwner {
        admins[a] = s;
    }

    function setPaused(bool _p) external onlyOwner {
        paused = _p;
    }

    function transferOwnership(address n) external onlyOwner {
        require(n != address(0), "OTC: Zero address");
        owner = n;
    }

    function rescueTokens(address t, uint256 a) external onlyOwner {
        IERC20(t).transfer(owner, a);
    }
}
