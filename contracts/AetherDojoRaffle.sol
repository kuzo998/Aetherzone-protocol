// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Raffle {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Raffle {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/**
 * @title AetherDojoRaffle
 * @notice On-Chain Chinatown Dojo Leaderboard & AetherComms Multi-Winner Raffle Engine
 * @dev Supports Native SHIDO, ERC-20 ($CHINA, $CWK, USDC, WSHIDO), ERC-721 NFTs, and Custom Perks.
 *      Supports Dojo Rank Tier filtering (Tier 1..8) and Autonomous Keeper settlement.
 */
contract AetherDojoRaffle {
    uint8 public constant PRIZE_NATIVE_SHIDO = 0;
    uint8 public constant PRIZE_ERC20_TOKEN = 1;
    uint8 public constant PRIZE_ERC721_NFT = 2;
    uint8 public constant PRIZE_CUSTOM_PERK = 3;

    uint8 public constant STATUS_ACTIVE = 0;
    uint8 public constant STATUS_SETTLED = 1;
    uint8 public constant STATUS_CANCELLED = 2;

    struct Raffle {
        uint256 id;
        address creator;
        string title;
        string description;
        uint8 prizeType;
        address prizeToken;
        uint256 prizeAmount;
        uint256[] nftTokenIds;
        uint8 minDojoTier;      // 1 = Initiate Ronin .. 8 = Imperial Dragon
        uint8 maxDojoTier;      // 1..8
        uint32 winnerCount;     // 1..50
        uint64 createdAt;
        uint64 endsAt;
        uint8 status;           // 0 = Active, 1 = Settled, 2 = Cancelled
        bool isSnapshotMode;    // true = Keeper settles from Leaderboard snapshot, false = Click-to-enter
        bool isTestSimulation;  // true = Test / Simulation raffle (no public announcement)
        uint32 entryCount;
        uint64 settledAt;
    }

    struct Entry {
        address participant;
        uint8 dojoTier;
        uint32 weight;
        uint64 enteredAt;
        bool viaAetherComms;
    }

    address public owner;
    address public keeperAddress;
    uint256 public totalRaffles;

    uint256 private _locked = 1;

    mapping(uint256 => Raffle) private _raffles;
    mapping(uint256 => Entry[]) private _raffleEntries;
    mapping(uint256 => mapping(address => bool)) public hasEntered;
    mapping(uint256 => address[]) private _raffleWinners;
    mapping(uint256 => uint256[]) private _winnerAmounts;
    mapping(address => uint8) public userDojoTier;

    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed creator,
        string title,
        uint8 prizeType,
        address prizeToken,
        uint256 prizeAmount,
        uint8 minDojoTier,
        uint8 maxDojoTier,
        uint32 winnerCount,
        uint64 endsAt,
        bool isSnapshotMode,
        bool isTestSimulation
    );

    event RaffleEntered(
        uint256 indexed raffleId,
        address indexed participant,
        uint8 dojoTier,
        uint32 weight,
        bool viaAetherComms
    );

    event RaffleSettled(
        uint256 indexed raffleId,
        address[] winners,
        uint256 prizePerWinner,
        uint64 settledAt
    );

    event RaffleCancelled(uint256 indexed raffleId, address indexed cancelledBy);

    error Unauthorized();
    error InvalidInput();
    error AlreadyEntered();
    error TierRequirementNotMet();
    error RaffleNotActive();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwnerOrKeeper() {
        if (msg.sender != owner && msg.sender != keeperAddress) revert Unauthorized();
        _;
    }

    constructor(address _keeperAddress) {
        owner = msg.sender;
        keeperAddress = _keeperAddress == address(0) ? msg.sender : _keeperAddress;
    }

    function setAdminConfig(address _newOwner, address _newKeeper) external {
        if (msg.sender != owner) revert Unauthorized();
        if (_newOwner != address(0)) owner = _newOwner;
        if (_newKeeper != address(0)) keeperAddress = _newKeeper;
    }

    function batchSyncDojoTiers(address[] calldata users, uint8[] calldata tiers) external onlyOwnerOrKeeper {
        if (users.length != tiers.length) revert InvalidInput();
        for (uint256 i = 0; i < users.length; i++) {
            userDojoTier[users[i]] = tiers[i];
        }
    }

    function _transferToken(address from, address to, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert InvalidInput();
        } else {
            bytes memory data = from == address(this)
                ? abi.encodeWithSelector(IERC20Raffle.transfer.selector, to, amount)
                : abi.encodeWithSelector(IERC20Raffle.transferFrom.selector, from, to, amount);
            (bool success, bytes memory ret) = token.call(data);
            if (!success || (ret.length > 0 && !abi.decode(ret, (bool)))) revert InvalidInput();
        }
    }

    struct CreateRaffleParams {
        string title;
        string description;
        uint8 prizeType;
        address prizeToken;
        uint256 prizeAmount;
        uint256[] nftTokenIds;
        uint8 minDojoTier;
        uint8 maxDojoTier;
        uint32 winnerCount;
        uint64 durationSeconds;
        bool isSnapshotMode;
        bool isTestSimulation;
    }

    function createRaffle(CreateRaffleParams calldata p) external payable nonReentrant returns (uint256 raffleId) {
        if (bytes(p.title).length < 2 || bytes(p.title).length > 120) revert InvalidInput();
        if (p.prizeType > PRIZE_CUSTOM_PERK) revert InvalidInput();
        if (p.winnerCount == 0 || p.winnerCount > 50) revert InvalidInput();
        if (p.minDojoTier == 0 || p.maxDojoTier > 8 || p.minDojoTier > p.maxDojoTier) revert InvalidInput();
        if (p.durationSeconds < 30 || p.durationSeconds > 90 days) revert InvalidInput();

        if (p.prizeType == PRIZE_NATIVE_SHIDO) {
            if (p.prizeAmount == 0 || msg.value != p.prizeAmount || p.prizeAmount < p.winnerCount) revert InvalidInput();
        } else if (p.prizeType == PRIZE_ERC20_TOKEN) {
            if (msg.value != 0 || p.prizeToken == address(0) || p.prizeAmount < p.winnerCount) revert InvalidInput();
            _transferToken(msg.sender, address(this), p.prizeToken, p.prizeAmount);
        } else if (p.prizeType == PRIZE_ERC721_NFT) {
            if (msg.value != 0 || p.prizeToken == address(0) || p.nftTokenIds.length != p.winnerCount) revert InvalidInput();
            for (uint256 i = 0; i < p.nftTokenIds.length; i++) {
                IERC721Raffle(p.prizeToken).transferFrom(msg.sender, address(this), p.nftTokenIds[i]);
            }
        } else {
            if (msg.value != 0) revert InvalidInput();
        }

        raffleId = ++totalRaffles;
        uint64 endsAt = uint64(block.timestamp) + p.durationSeconds;

        Raffle storage r = _raffles[raffleId];
        r.id = raffleId;
        r.creator = msg.sender;
        r.title = p.title;
        r.description = p.description;
        r.prizeType = p.prizeType;
        r.prizeToken = p.prizeToken;
        r.prizeAmount = p.prizeAmount;
        r.nftTokenIds = p.nftTokenIds;
        r.minDojoTier = p.minDojoTier;
        r.maxDojoTier = p.maxDojoTier;
        r.winnerCount = p.winnerCount;
        r.createdAt = uint64(block.timestamp);
        r.endsAt = endsAt;
        r.status = STATUS_ACTIVE;
        r.isSnapshotMode = p.isSnapshotMode;
        r.isTestSimulation = p.isTestSimulation;

        emit RaffleCreated(
            raffleId,
            msg.sender,
            p.title,
            p.prizeType,
            p.prizeToken,
            p.prizeAmount,
            p.minDojoTier,
            p.maxDojoTier,
            p.winnerCount,
            endsAt,
            p.isSnapshotMode,
            p.isTestSimulation
        );
    }

    /**
     * @notice Enters a participant into an active raffle.
     *         Can be invoked by Keeper/Owner (with verified Dojo tier & weight) or directly by the participant.
     */
    function enterRaffle(
        uint256 raffleId,
        address participant,
        uint8 dojoTier,
        uint32 weight,
        bool viaAetherComms
    ) external nonReentrant {
        Raffle storage r = _raffles[raffleId];
        if (r.id == 0 || r.status != STATUS_ACTIVE || block.timestamp >= r.endsAt) revert RaffleNotActive();

        address actor = participant == address(0) ? msg.sender : participant;
        if (hasEntered[raffleId][actor]) revert AlreadyEntered();

        uint8 verifiedTier = dojoTier;
        uint32 verifiedWeight = weight;

        if (msg.sender == owner || msg.sender == keeperAddress) {
            if (verifiedTier > 0) userDojoTier[actor] = verifiedTier;
            if (verifiedWeight == 0) verifiedWeight = 100;
        } else {
            if (actor != msg.sender) revert Unauthorized();
            verifiedTier = userDojoTier[actor];
            if (verifiedTier == 0 && r.minDojoTier == 1) {
                verifiedTier = 1;
            }
            verifiedWeight = viaAetherComms ? 200 : 100;
        }

        if (verifiedTier < r.minDojoTier || verifiedTier > r.maxDojoTier) {
            revert TierRequirementNotMet();
        }

        hasEntered[raffleId][actor] = true;
        r.entryCount++;
        _raffleEntries[raffleId].push(Entry({
            participant: actor,
            dojoTier: verifiedTier,
            weight: verifiedWeight,
            enteredAt: uint64(block.timestamp),
            viaAetherComms: viaAetherComms
        }));

        emit RaffleEntered(raffleId, actor, verifiedTier, verifiedWeight, viaAetherComms);
    }

    /**
     * @notice Autonomous Keeper or Owner settles the raffle on-chain and distributes prizes to winners.
     * @param raffleId The raffle ID to settle.
     * @param snapshotCandidates Additional eligible candidates from the Chinatown Dojo Leaderboard snapshot.
     * @param snapshotWeights Corresponding weights for snapshotCandidates.
     * @param keeperSeed Entropy seed provided by the Autonomous Keeper.
     */
    function settleRaffle(
        uint256 raffleId,
        address[] calldata snapshotCandidates,
        uint32[] calldata snapshotWeights,
        bytes32 keeperSeed
    ) external nonReentrant onlyOwnerOrKeeper returns (address[] memory winners) {
        Raffle storage r = _raffles[raffleId];
        if (r.id == 0 || r.status != STATUS_ACTIVE) revert RaffleNotActive();
        if (snapshotCandidates.length != snapshotWeights.length) revert InvalidInput();

        Entry[] storage entries = _raffleEntries[raffleId];
        uint256 maxCandidates = entries.length + snapshotCandidates.length;

        if (maxCandidates == 0) {
            _refundCreator(r);
            r.status = STATUS_CANCELLED;
            emit RaffleCancelled(raffleId, msg.sender);
            return new address[](0);
        }

        address[] memory poolAddrs = new address[](maxCandidates);
        uint32[] memory poolWeights = new uint32[](maxCandidates);
        uint256 poolLen = 0;

        for (uint256 i = 0; i < entries.length; i++) {
            poolAddrs[poolLen] = entries[i].participant;
            poolWeights[poolLen] = entries[i].weight > 0 ? entries[i].weight : 100;
            poolLen++;
        }

        for (uint256 i = 0; i < snapshotCandidates.length; i++) {
            address cand = snapshotCandidates[i];
            if (cand == address(0) || hasEntered[raffleId][cand]) continue;
            bool dup = false;
            for (uint256 j = entries.length; j < poolLen; j++) {
                if (poolAddrs[j] == cand) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                poolAddrs[poolLen] = cand;
                poolWeights[poolLen] = snapshotWeights[i] > 0 ? snapshotWeights[i] : 100;
                poolLen++;
            }
        }

        if (poolLen == 0) {
            _refundCreator(r);
            r.status = STATUS_CANCELLED;
            emit RaffleCancelled(raffleId, msg.sender);
            return new address[](0);
        }

        uint256 actualWinnerCount = r.winnerCount;
        if (actualWinnerCount > poolLen) {
            actualWinnerCount = poolLen;
        }

        winners = new address[](actualWinnerCount);

        for (uint256 w = 0; w < actualWinnerCount; w++) {
            uint256 totalWeight = 0;
            for (uint256 i = 0; i < poolLen; i++) {
                totalWeight += poolWeights[i];
            }

            uint256 rand = uint256(
                keccak256(
                    abi.encodePacked(
                        block.prevrandao,
                        blockhash(block.number > 0 ? block.number - 1 : 0),
                        block.timestamp,
                        keeperSeed,
                        raffleId,
                        w
                    )
                )
            );

            uint256 chosenIdx = 0;
            if (totalWeight > 0) {
                uint256 target = rand % totalWeight;
                uint256 cumulative = 0;
                for (uint256 i = 0; i < poolLen; i++) {
                    if (poolWeights[i] == 0) continue;
                    cumulative += poolWeights[i];
                    if (target < cumulative) {
                        chosenIdx = i;
                        break;
                    }
                }
            } else {
                chosenIdx = w % poolLen;
            }

            winners[w] = poolAddrs[chosenIdx];
            poolWeights[chosenIdx] = 0; // Remove winner from subsequent draws
        }

        r.status = STATUS_SETTLED;
        r.settledAt = uint64(block.timestamp);
        _raffleWinners[raffleId] = winners;

        uint256 prizePerWinner = 0;
        if (r.prizeType == PRIZE_NATIVE_SHIDO || r.prizeType == PRIZE_ERC20_TOKEN) {
            prizePerWinner = r.prizeAmount / actualWinnerCount;
            uint256 distributed = 0;
            for (uint256 w = 0; w < actualWinnerCount; w++) {
                uint256 share = (w == actualWinnerCount - 1) ? (r.prizeAmount - distributed) : prizePerWinner;
                distributed += share;
                _winnerAmounts[raffleId].push(share);
                _transferToken(address(this), winners[w], r.prizeType == PRIZE_NATIVE_SHIDO ? address(0) : r.prizeToken, share);
            }
        } else if (r.prizeType == PRIZE_ERC721_NFT) {
            prizePerWinner = 1;
            for (uint256 w = 0; w < actualWinnerCount; w++) {
                uint256 tokenId = r.nftTokenIds[w];
                _winnerAmounts[raffleId].push(tokenId);
                IERC721Raffle(r.prizeToken).transferFrom(address(this), winners[w], tokenId);
            }
            // Refund any leftover NFTs if actualWinnerCount < r.nftTokenIds.length
            for (uint256 k = actualWinnerCount; k < r.nftTokenIds.length; k++) {
                IERC721Raffle(r.prizeToken).transferFrom(address(this), r.creator, r.nftTokenIds[k]);
            }
        }

        emit RaffleSettled(raffleId, winners, prizePerWinner, r.settledAt);
    }

    function cancelRaffle(uint256 raffleId) external nonReentrant {
        Raffle storage r = _raffles[raffleId];
        if (r.id == 0 || r.status != STATUS_ACTIVE) revert RaffleNotActive();
        if (msg.sender != r.creator && msg.sender != owner && msg.sender != keeperAddress) revert Unauthorized();

        r.status = STATUS_CANCELLED;
        _refundCreator(r);
        emit RaffleCancelled(raffleId, msg.sender);
    }

    function _refundCreator(Raffle storage r) internal {
        if (r.prizeType == PRIZE_NATIVE_SHIDO && r.prizeAmount > 0) {
            _transferToken(address(this), r.creator, address(0), r.prizeAmount);
        } else if (r.prizeType == PRIZE_ERC20_TOKEN && r.prizeAmount > 0) {
            _transferToken(address(this), r.creator, r.prizeToken, r.prizeAmount);
        } else if (r.prizeType == PRIZE_ERC721_NFT) {
            for (uint256 i = 0; i < r.nftTokenIds.length; i++) {
                IERC721Raffle(r.prizeToken).transferFrom(address(this), r.creator, r.nftTokenIds[i]);
            }
        }
    }

    function getRaffle(uint256 id) external view returns (Raffle memory, address[] memory winners, uint256[] memory amounts) {
        return (_raffles[id], _raffleWinners[id], _winnerAmounts[id]);
    }

    function getRafflesBatch(uint256 offset, uint256 limit) external view returns (Raffle[] memory list) {
        if (offset >= totalRaffles) return new Raffle[](0);
        uint256 end = offset + limit;
        if (end > totalRaffles) end = totalRaffles;
        uint256 count = end - offset;
        list = new Raffle[](count);
        for (uint256 i = 0; i < count; i++) {
            list[i] = _raffles[totalRaffles - (offset + i)];
        }
    }

    function getRaffleEntries(uint256 raffleId) external view returns (Entry[] memory) {
        return _raffleEntries[raffleId];
    }

    function getRaffleWinners(uint256 raffleId) external view returns (address[] memory winners, uint256[] memory amounts) {
        return (_raffleWinners[raffleId], _winnerAmounts[raffleId]);
    }

    receive() external payable {}
}
