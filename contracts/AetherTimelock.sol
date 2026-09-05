// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AetherTimelock
 * @notice A secure administrative timelock contract designed for solo developers.
 * Provides transparency for users and investors by forcing a 48-hour delay on all
 * structural admin changes, while preserving instant emergency pause capabilities.
 */
contract AetherTimelock {
    
    // ─── Events ───────────────────────────────────────────────────────────────
    
    event NewAdmin(address indexed newAdmin);
    event NewDelay(uint256 indexed newDelay);
    event CancelTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta);
    event EmergencyPauseExecuted(address indexed target, bytes data);

    // ─── State Variables ──────────────────────────────────────────────────────

    address public admin;
    uint256 public delay; // Mandatory delay in seconds (e.g., 172800 = 48 hours)
    uint256 public constant GRACE_PERIOD = 14 days; // Period during which a transaction can be executed after ETA
    uint256 public constant MINIMUM_DELAY = 12 hours;
    uint256 public constant MAXIMUM_DELAY = 30 days;

    mapping(bytes32 => bool) public queuedTransactions;

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "AetherTimelock: Call must come from admin");
        _;
    }

    constructor(address _admin, uint256 _delay) {
        require(_delay >= MINIMUM_DELAY, "AetherTimelock: Delay must exceed minimum delay");
        require(_delay <= MAXIMUM_DELAY, "AetherTimelock: Delay must not exceed maximum delay");
        admin = _admin;
        delay = _delay;
    }

    receive() external payable {}

    // ─── Admin Configuration ──────────────────────────────────────────────────

    function setAdmin(address _newAdmin) external {
        require(msg.sender == address(this), "AetherTimelock: Call must come from Timelock itself");
        require(_newAdmin != address(0), "AetherTimelock: Admin cannot be zero address");
        admin = _newAdmin;
        emit NewAdmin(_newAdmin);
    }

    function setDelay(uint256 _newDelay) external {
        require(msg.sender == address(this), "AetherTimelock: Call must come from Timelock itself");
        require(_newDelay >= MINIMUM_DELAY, "AetherTimelock: Delay must exceed minimum delay");
        require(_newDelay <= MAXIMUM_DELAY, "AetherTimelock: Delay must not exceed maximum delay");
        delay = _newDelay;
        emit NewDelay(_newDelay);
    }

    // ─── Queue, Cancel, and Execute Operations ────────────────────────────────

    function queueTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external onlyAdmin returns (bytes32) {
        require(eta >= block.timestamp + delay, "AetherTimelock: Estimated execution time must satisfy delay");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    function cancelTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external onlyAdmin {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(queuedTransactions[txHash], "AetherTimelock: Transaction hasn't been queued");

        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    function executeTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external payable onlyAdmin returns (bytes memory) {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(queuedTransactions[txHash], "AetherTimelock: Transaction hasn't been queued");
        require(block.timestamp >= eta, "AetherTimelock: Transaction hasn't surpassed ETA");
        require(block.timestamp <= eta + GRACE_PERIOD, "AetherTimelock: Transaction is stale");

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // Execute the low-level call
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "AetherTimelock: Transaction execution reverted");

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    // ─── Emergency Operations ─────────────────────────────────────────────────

    /**
     * @notice Allows the admin to execute an INSTANT emergency pause call without the timelock delay.
     * Only whitelisted emergency function signatures (such as setPaused(true)) are allowed.
     * Unpausing (setPaused(false)) MUST go through the standard 48-hour timelock queue.
     */
    function emergencyPause(address target, bytes calldata data) external onlyAdmin {
        // Enforce that the data payload corresponds exactly to setPaused(true)
        // Keccak256 of "setPaused(bool)" is 0x1bf92073
        // For boolean true, the encoded argument is 0x00...01
        bytes4 expectedSig = bytes4(keccak256("setPaused(bool)"));
        require(data.length >= 4, "AetherTimelock: Invalid emergency payload length");
        bytes4 sig = bytes4(data[0:4]);
        require(sig == expectedSig, "AetherTimelock: Only setPaused(bool) allowed in emergency");
        
        // Decode the boolean parameter to ensure we are only pausing (true), not unpausing (false)
        bool pauseState = abi.decode(data[4:], (bool));
        require(pauseState == true, "AetherTimelock: Emergency unpausing not allowed, must use standard timelock");

        // Execute the call instantly
        (bool success, ) = target.call(data);
        require(success, "AetherTimelock: Emergency pause execution reverted");

        emit EmergencyPauseExecuted(target, data);
    }
}
