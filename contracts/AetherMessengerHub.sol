// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

interface IENSManager {
    function getPrimaryDomain(address user) external view returns (string memory);
}

/**
 * @title AetherMessengerHub
 * @notice Aetherzone On-Chain Encrypted Messenger & Community Groups Hub (Shido Network - Chain ID 9008)
 */
contract AetherMessengerHub is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint8 public constant DM_PRIVACY_EVERYONE = 0;
    uint8 public constant DM_PRIVACY_SHIDO_HOLDERS = 1;
    uint8 public constant DM_PRIVACY_CONTACTS_ONLY = 2;

    uint8 public constant GROUP_PUBLIC = 0;
    uint8 public constant GROUP_SHIDO_HOLDERS_ONLY = 1;
    uint8 public constant GROUP_TOKEN_GATED = 2;
    uint8 public constant GROUP_PAID_VIP = 3;

    address public snsTokenV1;
    address public snsTokenV3;
    address public ensManager;
    address public treasuryAddress;

    uint256 public nonHolderGroupCreationFee = 250 ether;
    uint256 public vipPlatformFeeBps = 1000;

    struct SessionConfig {
        address sessionKey;
        uint64 expiresAt;
        bool active;
    }

    struct UserMessagingProfile {
        bytes encryptionPublicKey;
        uint8 dmPrivacyMode;
        uint64 updatedAt;
        bool registered;
    }

    mapping(address => UserMessagingProfile) public userProfiles;
    mapping(address => SessionConfig) public userSessions;
    mapping(address => uint256) public relayNonces;

    mapping(address => mapping(address => bool)) public isBlocked;
    mapping(address => mapping(address => bool)) public isAcceptedContact;

    struct DirectMessage {
        uint256 id;
        bytes32 conversationId;
        address sender;
        address recipient;
        string ciphertext;
        string metadataCid;
        address paymentToken;
        uint256 paymentAmount;
        uint64 timestamp;
        bool redacted;
    }

    uint256 public totalDirectMessages;
    mapping(uint256 => DirectMessage) private _directMessages;
    mapping(bytes32 => uint256[]) private _conversationMessageIds;
    mapping(address => address[]) private _userPeers;
    mapping(address => mapping(address => bool)) private _hasPeer;

    struct GroupConfig {
        uint256 id;
        address owner;
        string name;
        string description;
        string avatarUri;
        string snsBadgeDomain;
        uint8 groupType;
        address gateToken;
        uint256 minGateBalance;
        address entryFeeToken;
        uint256 entryFeeAmount;
        uint32 slowModeCooldown;
        uint32 memberCount;
        uint32 messageCount;
        uint64 createdAt;
        bool active;
        bool isEncrypted;
    }

    struct GroupMessage {
        uint256 id;
        uint256 groupId;
        address sender;
        string ciphertext;
        string metadataCid;
        uint256 replyToMessageId;
        address tipRecipient;
        address tipToken;
        uint256 tipAmount;
        uint64 timestamp;
        bool redacted;
    }

    uint256 public totalGroups;
    uint256 public totalGroupMessages;

    mapping(uint256 => GroupConfig) private _groups;
    mapping(uint256 => GroupMessage) private _groupMessages;
    mapping(uint256 => uint256[]) private _groupMessageIds;
    mapping(uint256 => address[]) private _groupMembersList;

    mapping(uint256 => mapping(address => bool)) public isGroupMember;
    mapping(uint256 => mapping(address => bool)) public isGroupModerator;
    mapping(uint256 => mapping(address => bool)) public isGroupBanned;
    mapping(uint256 => mapping(address => uint64)) public groupMutedUntil;
    mapping(uint256 => mapping(address => uint64)) public lastGroupMessageAt;
    mapping(uint256 => mapping(address => string)) public encryptedGroupKeys;
    mapping(address => uint256[]) private _userJoinedGroups;

    event IdentityRegistered(
        address indexed user,
        bytes encryptionPublicKey,
        address indexed sessionKey,
        uint64 sessionExpiry,
        uint8 dmPrivacyMode
    );
    event SessionKeyUpdated(address indexed user, address indexed sessionKey, uint64 expiresAt, bool active);
    event DmPrivacyUpdated(address indexed user, uint8 dmPrivacyMode);
    event UserBlockStatusChanged(address indexed blocker, address indexed target, bool blocked);
    event ContactAccepted(address indexed user, address indexed peer);

    event DirectMessageSent(
        uint256 indexed messageId,
        bytes32 indexed conversationId,
        address indexed sender,
        address recipient,
        string ciphertext,
        string metadataCid,
        address paymentToken,
        uint256 paymentAmount,
        uint64 timestamp
    );
    event DirectMessageRedacted(uint256 indexed messageId, bytes32 indexed conversationId, address indexed sender);

    event GroupCreated(
        uint256 indexed groupId,
        address indexed owner,
        string name,
        string snsBadgeDomain,
        uint8 groupType,
        address gateToken,
        uint256 minGateBalance,
        address entryFeeToken,
        uint256 entryFeeAmount,
        bool isEncrypted
    );
    event GroupSettingsUpdated(
        uint256 indexed groupId,
        string name,
        string description,
        string avatarUri,
        uint32 slowModeCooldown,
        uint256 entryFeeAmount
    );
    event GroupMemberJoined(uint256 indexed groupId, address indexed member, uint256 feePaid);
    event GroupMemberLeft(uint256 indexed groupId, address indexed member);
    event GroupModeratorUpdated(uint256 indexed groupId, address indexed moderator, bool status);
    event GroupMemberModerated(
        uint256 indexed groupId,
        address indexed moderator,
        address indexed target,
        bool banned,
        uint64 muteUntil
    );
    event GroupMessageSent(
        uint256 indexed messageId,
        uint256 indexed groupId,
        address indexed sender,
        string ciphertext,
        string metadataCid,
        uint256 replyToMessageId,
        address tipRecipient,
        address tipToken,
        uint256 tipAmount,
        uint64 timestamp
    );
    event GroupMessageRedacted(uint256 indexed groupId, uint256 indexed messageId, address indexed redactedBy);
    event EncryptedGroupKeyUpdated(uint256 indexed groupId, address indexed member, string encryptedKey);

    constructor(
        address _snsTokenV1,
        address _snsTokenV3,
        address _ensManager,
        address _treasuryAddress
    ) Ownable(msg.sender) {
        snsTokenV1 = _snsTokenV1;
        snsTokenV3 = _snsTokenV3;
        ensManager = _ensManager;
        treasuryAddress = _treasuryAddress != address(0) ? _treasuryAddress : msg.sender;
    }

    function _resolveActor(address onBehalfOf) internal view returns (address) {
        if (onBehalfOf == address(0) || msg.sender == onBehalfOf) {
            return msg.sender;
        }
        SessionConfig memory sess = userSessions[onBehalfOf];
        require(sess.active && sess.sessionKey == msg.sender && block.timestamp <= sess.expiresAt, "Invalid session");
        return onBehalfOf;
    }

    function _verifyRelayedSigner(
        address user,
        bytes32 actionHash,
        bytes calldata sig
    ) internal view returns (bool) {
        if (sig.length != 65) return false;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", actionHash));
        address recovered = ecrecover(ethSignedHash, v, r, s);
        if (recovered == address(0)) return false;
        if (recovered == user) return true;
        SessionConfig memory sess = userSessions[user];
        return (sess.active && sess.sessionKey == recovered && block.timestamp <= sess.expiresAt);
    }

    function hasActiveSnsDomain(address user) public view returns (bool) {
        if (user == address(0)) return false;
        if (snsTokenV1 != address(0)) {
            try IERC721Balance(snsTokenV1).balanceOf(user) returns (uint256 b1) {
                if (b1 > 0) return true;
            } catch {}
        }
        if (snsTokenV3 != address(0)) {
            try IERC721Balance(snsTokenV3).balanceOf(user) returns (uint256 b3) {
                if (b3 > 0) return true;
            } catch {}
        }
        if (ensManager != address(0)) {
            try IENSManager(ensManager).getPrimaryDomain(user) returns (string memory p) {
                if (bytes(p).length > 0) return true;
            } catch {}
        }
        return false;
    }

    function getConversationId(address userA, address userB) public pure returns (bytes32) {
        return userA < userB
            ? keccak256(abi.encodePacked(userA, userB))
            : keccak256(abi.encodePacked(userB, userA));
    }

    function registerMessagingIdentity(
        bytes calldata encryptionPublicKey,
        address sessionKey,
        uint64 sessionDurationSeconds,
        uint8 dmPrivacyMode
    ) external payable nonReentrant {
        require(dmPrivacyMode <= DM_PRIVACY_CONTACTS_ONLY, "Invalid privacy");

        UserMessagingProfile storage profile = userProfiles[msg.sender];
        if (encryptionPublicKey.length > 0) {
            profile.encryptionPublicKey = encryptionPublicKey;
        }
        profile.dmPrivacyMode = dmPrivacyMode;
        profile.updatedAt = uint64(block.timestamp);
        profile.registered = true;

        uint64 expiresAt = 0;
        if (sessionKey != address(0) && sessionDurationSeconds > 0) {
            require(sessionDurationSeconds <= 30 days, "Max 30d");
            expiresAt = uint64(block.timestamp) + sessionDurationSeconds;
            userSessions[msg.sender] = SessionConfig(sessionKey, expiresAt, true);
            emit SessionKeyUpdated(msg.sender, sessionKey, expiresAt, true);

            if (msg.value > 0) {
                (bool ok, ) = payable(sessionKey).call{value: msg.value}("");
                require(ok, "Gas transfer failed");
            }
        } else {
            require(msg.value == 0, "Unexpected value");
        }

        emit IdentityRegistered(msg.sender, profile.encryptionPublicKey, sessionKey, expiresAt, dmPrivacyMode);
    }

    function revokeSessionKey() external {
        delete userSessions[msg.sender];
        emit SessionKeyUpdated(msg.sender, address(0), 0, false);
    }

    function setDmPrivacyMode(address onBehalfOf, uint8 dmPrivacyMode) external {
        address actor = _resolveActor(onBehalfOf);
        require(dmPrivacyMode <= DM_PRIVACY_CONTACTS_ONLY, "Invalid privacy");
        userProfiles[actor].dmPrivacyMode = dmPrivacyMode;
        userProfiles[actor].updatedAt = uint64(block.timestamp);
        emit DmPrivacyUpdated(actor, dmPrivacyMode);
    }

    function setBlocked(address onBehalfOf, address target, bool blocked) external {
        address actor = _resolveActor(onBehalfOf);
        require(target != address(0) && target != actor, "Invalid target");
        isBlocked[actor][target] = blocked;
        emit UserBlockStatusChanged(actor, target, blocked);
    }

    function acceptContact(address onBehalfOf, address peer) external {
        address actor = _resolveActor(onBehalfOf);
        require(peer != address(0) && peer != actor, "Invalid peer");
        isAcceptedContact[actor][peer] = true;
        emit ContactAccepted(actor, peer);
    }

    function _transferValue(address from, address to, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "SHIDO transfer failed");
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    function _validateAndRecordDm(
        address sender,
        address recipient,
        string calldata ciphertext,
        string calldata metadataCid,
        address paymentToken,
        uint256 paymentAmount
    ) internal returns (uint256 messageId) {
        require(recipient != address(0) && recipient != sender, "Invalid recipient");
        require(bytes(ciphertext).length > 0 && bytes(ciphertext).length <= 8192, "Invalid length");
        require(!isBlocked[recipient][sender] && !isBlocked[sender][recipient], "Blocked");

        uint8 recipientPrivacy = userProfiles[recipient].dmPrivacyMode;
        if (!isAcceptedContact[recipient][sender]) {
            if (recipientPrivacy == DM_PRIVACY_SHIDO_HOLDERS) {
                require(hasActiveSnsDomain(sender), ".shido required");
            } else if (recipientPrivacy == DM_PRIVACY_CONTACTS_ONLY) {
                revert("Contacts only");
            }
        }

        if (!isAcceptedContact[sender][recipient]) {
            isAcceptedContact[sender][recipient] = true;
            emit ContactAccepted(sender, recipient);
        }

        if (!_hasPeer[sender][recipient]) {
            _hasPeer[sender][recipient] = true;
            _userPeers[sender].push(recipient);
        }
        if (!_hasPeer[recipient][sender]) {
            _hasPeer[recipient][sender] = true;
            _userPeers[recipient].push(sender);
        }

        bytes32 convId = getConversationId(sender, recipient);
        messageId = ++totalDirectMessages;

        _directMessages[messageId] = DirectMessage({
            id: messageId,
            conversationId: convId,
            sender: sender,
            recipient: recipient,
            ciphertext: ciphertext,
            metadataCid: metadataCid,
            paymentToken: paymentToken,
            paymentAmount: paymentAmount,
            timestamp: uint64(block.timestamp),
            redacted: false
        });

        _conversationMessageIds[convId].push(messageId);

        emit DirectMessageSent(
            messageId,
            convId,
            sender,
            recipient,
            ciphertext,
            metadataCid,
            paymentToken,
            paymentAmount,
            uint64(block.timestamp)
        );
    }

    function sendDirectMessage(
        address onBehalfOf,
        address recipient,
        string calldata ciphertext,
        string calldata metadataCid,
        address paymentToken,
        uint256 paymentAmount
    ) external payable nonReentrant returns (uint256) {
        address sender = _resolveActor(onBehalfOf);
        if (paymentAmount > 0) {
            require(msg.sender == sender, "Main wallet required");
            require(paymentToken == address(0) ? msg.value == paymentAmount : msg.value == 0, "Bad value");
            _transferValue(sender, recipient, paymentToken, paymentAmount);
        } else {
            require(msg.value == 0, "Bad value");
        }
        return _validateAndRecordDm(sender, recipient, ciphertext, metadataCid, paymentToken, paymentAmount);
    }

    function relayDirectMessage(
        address sender,
        address recipient,
        string calldata ciphertext,
        string calldata metadataCid,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256) {
        require(block.timestamp <= deadline && nonce == relayNonces[sender], "Expired/bad nonce");
        bytes32 actionHash = keccak256(
            abi.encodePacked(
                "AETHERCOMMS_DM",
                block.chainid,
                address(this),
                sender,
                recipient,
                keccak256(bytes(ciphertext)),
                keccak256(bytes(metadataCid)),
                nonce,
                deadline
            )
        );
        require(_verifyRelayedSigner(sender, actionHash, signature), "Bad sig");
        relayNonces[sender]++;
        return _validateAndRecordDm(sender, recipient, ciphertext, metadataCid, address(0), 0);
    }

    function redactDirectMessage(address onBehalfOf, uint256 messageId) external {
        address actor = _resolveActor(onBehalfOf);
        DirectMessage storage dm = _directMessages[messageId];
        require(dm.id != 0 && dm.sender == actor, "Unauthorized");
        dm.redacted = true;
        dm.ciphertext = "[REDACTED ON-CHAIN]";
        emit DirectMessageRedacted(messageId, dm.conversationId, actor);
    }

    struct CreateGroupParams {
        string name;
        string description;
        string avatarUri;
        string snsBadgeDomain;
        uint8 groupType;
        address gateToken;
        uint256 minGateBalance;
        address entryFeeToken;
        uint256 entryFeeAmount;
        uint32 slowModeCooldown;
        bool isEncrypted;
        string creatorEncryptedGroupKey;
    }

    function createGroup(CreateGroupParams calldata p) external payable nonReentrant returns (uint256 groupId) {
        require(bytes(p.name).length >= 2 && bytes(p.name).length <= 80 && p.groupType <= GROUP_PAID_VIP, "Invalid group");

        if (!hasActiveSnsDomain(msg.sender)) {
            require(msg.value >= nonHolderGroupCreationFee, "Fee required");
            _transferValue(msg.sender, treasuryAddress, address(0), msg.value);
        } else if (msg.value > 0) {
            _transferValue(address(this), msg.sender, address(0), msg.value);
        }

        if (p.groupType == GROUP_TOKEN_GATED) {
            require(p.gateToken != address(0) && p.minGateBalance > 0, "Invalid gate");
        }

        groupId = ++totalGroups;
        GroupConfig storage g = _groups[groupId];
        g.id = groupId;
        g.owner = msg.sender;
        g.name = p.name;
        g.description = p.description;
        g.avatarUri = p.avatarUri;
        g.snsBadgeDomain = p.snsBadgeDomain;
        g.groupType = p.groupType;
        g.gateToken = p.gateToken;
        g.minGateBalance = p.minGateBalance;
        g.entryFeeToken = p.entryFeeToken;
        g.entryFeeAmount = p.entryFeeAmount;
        g.slowModeCooldown = p.slowModeCooldown;
        g.memberCount = 1;
        g.createdAt = uint64(block.timestamp);
        g.active = true;
        g.isEncrypted = p.isEncrypted;

        isGroupMember[groupId][msg.sender] = true;
        isGroupModerator[groupId][msg.sender] = true;
        _groupMembersList[groupId].push(msg.sender);
        _userJoinedGroups[msg.sender].push(groupId);

        if (bytes(p.creatorEncryptedGroupKey).length > 0) {
            encryptedGroupKeys[groupId][msg.sender] = p.creatorEncryptedGroupKey;
            emit EncryptedGroupKeyUpdated(groupId, msg.sender, p.creatorEncryptedGroupKey);
        }

        emit GroupCreated(
            groupId,
            msg.sender,
            p.name,
            p.snsBadgeDomain,
            p.groupType,
            p.gateToken,
            p.minGateBalance,
            p.entryFeeToken,
            p.entryFeeAmount,
            p.isEncrypted
        );
        emit GroupMemberJoined(groupId, msg.sender, 0);
    }

    function joinGroup(uint256 groupId) external payable nonReentrant {
        GroupConfig storage g = _groups[groupId];
        require(g.id != 0 && g.active && !isGroupBanned[groupId][msg.sender] && !isGroupMember[groupId][msg.sender], "Cannot join");

        if (g.groupType == GROUP_SHIDO_HOLDERS_ONLY) {
            require(hasActiveSnsDomain(msg.sender), ".shido required");
        } else if (g.groupType == GROUP_TOKEN_GATED) {
            require(IERC20(g.gateToken).balanceOf(msg.sender) >= g.minGateBalance, "Gate balance low");
        }

        uint256 feePaid = 0;
        if (g.groupType == GROUP_PAID_VIP && g.entryFeeAmount > 0) {
            feePaid = g.entryFeeAmount;
            uint256 platformFee = (feePaid * vipPlatformFeeBps) / 10000;
            uint256 creatorShare = feePaid - platformFee;
            require(g.entryFeeToken == address(0) ? msg.value == feePaid : msg.value == 0, "Bad fee value");
            _transferValue(msg.sender, g.owner, g.entryFeeToken, creatorShare);
            _transferValue(msg.sender, treasuryAddress, g.entryFeeToken, platformFee);
        } else {
            require(msg.value == 0, "Unexpected value");
        }

        isGroupMember[groupId][msg.sender] = true;
        g.memberCount++;
        _groupMembersList[groupId].push(msg.sender);
        _userJoinedGroups[msg.sender].push(groupId);

        emit GroupMemberJoined(groupId, msg.sender, feePaid);
    }

    function leaveGroup(uint256 groupId) external {
        GroupConfig storage g = _groups[groupId];
        require(isGroupMember[groupId][msg.sender] && g.owner != msg.sender, "Cannot leave");
        isGroupMember[groupId][msg.sender] = false;
        if (g.memberCount > 0) g.memberCount--;
        emit GroupMemberLeft(groupId, msg.sender);
    }

    function _validateAndRecordGroupMessage(
        address sender,
        uint256 groupId,
        string calldata ciphertext,
        string calldata metadataCid,
        uint256 replyToMessageId,
        address tipRecipient,
        address tipToken,
        uint256 tipAmount
    ) internal returns (uint256 messageId) {
        GroupConfig storage g = _groups[groupId];
        require(g.id != 0 && g.active && isGroupMember[groupId][sender] && !isGroupBanned[groupId][sender], "Not allowed");
        require(block.timestamp >= groupMutedUntil[groupId][sender], "Muted");
        require(bytes(ciphertext).length > 0 && bytes(ciphertext).length <= 8192, "Bad length");

        if (sender != g.owner && !isGroupModerator[groupId][sender]) {
            if (g.groupType == GROUP_SHIDO_HOLDERS_ONLY) {
                require(hasActiveSnsDomain(sender), ".shido required");
            } else if (g.groupType == GROUP_TOKEN_GATED) {
                require(IERC20(g.gateToken).balanceOf(sender) >= g.minGateBalance, "Gate balance low");
            }
            if (g.slowModeCooldown > 0) {
                require(block.timestamp >= lastGroupMessageAt[groupId][sender] + g.slowModeCooldown, "Slow mode");
            }
        }

        lastGroupMessageAt[groupId][sender] = uint64(block.timestamp);
        g.messageCount++;

        messageId = ++totalGroupMessages;
        _groupMessages[messageId] = GroupMessage({
            id: messageId,
            groupId: groupId,
            sender: sender,
            ciphertext: ciphertext,
            metadataCid: metadataCid,
            replyToMessageId: replyToMessageId,
            tipRecipient: tipRecipient,
            tipToken: tipToken,
            tipAmount: tipAmount,
            timestamp: uint64(block.timestamp),
            redacted: false
        });

        _groupMessageIds[groupId].push(messageId);

        emit GroupMessageSent(
            messageId,
            groupId,
            sender,
            ciphertext,
            metadataCid,
            replyToMessageId,
            tipRecipient,
            tipToken,
            tipAmount,
            uint64(block.timestamp)
        );
    }

    function sendGroupMessage(
        address onBehalfOf,
        uint256 groupId,
        string calldata ciphertext,
        string calldata metadataCid,
        uint256 replyToMessageId,
        address tipRecipient,
        address tipToken,
        uint256 tipAmount
    ) external payable nonReentrant returns (uint256) {
        address sender = _resolveActor(onBehalfOf);
        if (tipAmount > 0 && tipRecipient != address(0)) {
            require(msg.sender == sender, "Main wallet required");
            require(tipToken == address(0) ? msg.value == tipAmount : msg.value == 0, "Bad tip value");
            _transferValue(sender, tipRecipient, tipToken, tipAmount);
        } else {
            require(msg.value == 0, "Bad value");
        }
        return _validateAndRecordGroupMessage(
            sender,
            groupId,
            ciphertext,
            metadataCid,
            replyToMessageId,
            tipRecipient,
            tipToken,
            tipAmount
        );
    }

    function relayGroupMessage(
        address sender,
        uint256 groupId,
        string calldata ciphertext,
        string calldata metadataCid,
        uint256 replyToMessageId,
        uint256 nonce,
        uint64 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256) {
        require(block.timestamp <= deadline && nonce == relayNonces[sender], "Expired/bad nonce");
        bytes32 actionHash = keccak256(
            abi.encodePacked(
                "AETHERCOMMS_GROUP_MSG",
                block.chainid,
                address(this),
                sender,
                groupId,
                keccak256(bytes(ciphertext)),
                keccak256(bytes(metadataCid)),
                replyToMessageId,
                nonce,
                deadline
            )
        );
        require(_verifyRelayedSigner(sender, actionHash, signature), "Bad sig");
        relayNonces[sender]++;
        return _validateAndRecordGroupMessage(sender, groupId, ciphertext, metadataCid, replyToMessageId, address(0), address(0), 0);
    }

    function setGroupModerator(uint256 groupId, address moderator, bool status) external {
        require(_groups[groupId].id != 0 && msg.sender == _groups[groupId].owner, "Only owner");
        isGroupModerator[groupId][moderator] = status;
        emit GroupModeratorUpdated(groupId, moderator, status);
    }

    function moderateGroupMember(
        address onBehalfOf,
        uint256 groupId,
        address target,
        bool ban,
        uint64 muteDurationSeconds
    ) external {
        address actor = _resolveActor(onBehalfOf);
        GroupConfig storage g = _groups[groupId];
        require(g.id != 0 && (actor == g.owner || isGroupModerator[groupId][actor]), "Not mod");
        require(target != g.owner && (actor == g.owner || !isGroupModerator[groupId][target]), "Cannot mod target");

        isGroupBanned[groupId][target] = ban;
        if (ban && isGroupMember[groupId][target]) {
            isGroupMember[groupId][target] = false;
            if (g.memberCount > 0) g.memberCount--;
        }

        uint64 muteUntil = muteDurationSeconds > 0 ? uint64(block.timestamp) + muteDurationSeconds : 0;
        groupMutedUntil[groupId][target] = muteUntil;
        emit GroupMemberModerated(groupId, actor, target, ban, muteUntil);
    }

    function updateGroupSettings(
        address onBehalfOf,
        uint256 groupId,
        string calldata name,
        string calldata description,
        string calldata avatarUri,
        uint32 slowModeCooldown,
        uint256 entryFeeAmount
    ) external {
        address actor = _resolveActor(onBehalfOf);
        GroupConfig storage g = _groups[groupId];
        require(g.id != 0 && actor == g.owner && bytes(name).length >= 2 && bytes(name).length <= 80, "Unauthorized/bad name");
        g.name = name;
        g.description = description;
        g.avatarUri = avatarUri;
        g.slowModeCooldown = slowModeCooldown;
        g.entryFeeAmount = entryFeeAmount;
        emit GroupSettingsUpdated(groupId, name, description, avatarUri, slowModeCooldown, entryFeeAmount);
    }

    function redactGroupMessage(address onBehalfOf, uint256 groupId, uint256 messageId) external {
        address actor = _resolveActor(onBehalfOf);
        GroupConfig storage g = _groups[groupId];
        GroupMessage storage gm = _groupMessages[messageId];
        require(gm.id != 0 && gm.groupId == groupId, "Not found");
        require(actor == gm.sender || actor == g.owner || isGroupModerator[groupId][actor], "Unauthorized");
        gm.redacted = true;
        gm.ciphertext = "[REDACTED BY MODERATOR]";
        emit GroupMessageRedacted(groupId, messageId, actor);
    }

    function setEncryptedGroupKeyForMember(
        address onBehalfOf,
        uint256 groupId,
        address member,
        string calldata encryptedKey
    ) external {
        address actor = _resolveActor(onBehalfOf);
        GroupConfig storage g = _groups[groupId];
        require(g.id != 0 && (actor == g.owner || isGroupModerator[groupId][actor]), "Unauthorized");
        encryptedGroupKeys[groupId][member] = encryptedKey;
        emit EncryptedGroupKeyUpdated(groupId, member, encryptedKey);
    }

    function getDirectMessage(uint256 id) external view returns (DirectMessage memory) {
        return _directMessages[id];
    }

    function getGroup(uint256 id) external view returns (GroupConfig memory) {
        return _groups[id];
    }

    function getGroupMessage(uint256 id) external view returns (GroupMessage memory) {
        return _groupMessages[id];
    }

    function getUserPeers(address user) external view returns (address[] memory) {
        return _userPeers[user];
    }

    function getConversationMessageIds(bytes32 conversationId) external view returns (uint256[] memory) {
        return _conversationMessageIds[conversationId];
    }

    function getGroupMessageIds(uint256 groupId) external view returns (uint256[] memory) {
        return _groupMessageIds[groupId];
    }

    function getGroupMembers(uint256 groupId) external view returns (address[] memory) {
        return _groupMembersList[groupId];
    }

    function getUserJoinedGroups(address user) external view returns (uint256[] memory) {
        return _userJoinedGroups[user];
    }

    function setProtocolConfig(
        address _snsTokenV1,
        address _snsTokenV3,
        address _ensManager,
        address _treasuryAddress,
        uint256 _nonHolderGroupCreationFee,
        uint256 _vipPlatformFeeBps
    ) external onlyOwner {
        require(_vipPlatformFeeBps <= 3000, "Max 30%");
        snsTokenV1 = _snsTokenV1;
        snsTokenV3 = _snsTokenV3;
        ensManager = _ensManager;
        treasuryAddress = _treasuryAddress;
        nonHolderGroupCreationFee = _nonHolderGroupCreationFee;
        vipPlatformFeeBps = _vipPlatformFeeBps;
    }
}
