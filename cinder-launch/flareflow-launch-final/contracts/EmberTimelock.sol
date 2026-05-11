// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════╗
 * ║        EmberTimelock — Treasury Timelock              ║
 * ╚══════════════════════════════════════════════════════╝
 *
 * REPLACES: FlowTreasury (multisig) — you can't do 2-of-3 alone.
 *
 * HOW THIS WORKS:
 * ────────────────
 * This is a standard timelock controller. The only address that
 * can queue transactions is the EmberGovernor contract. Once a
 * governance proposal passes, it gets queued here and executes
 * after a mandatory 2-day delay.
 *
 * WHAT THIS MEANS IN PRACTICE:
 * ──────────────────────────────
 * - You (the founder) CANNOT spend treasury funds unilaterally
 * - EMBER holders vote → proposal passes → queued here → 2 days → execute
 * - During the 2-day window, anyone can see the pending tx
 * - If it's malicious, holders can exit before it executes
 * - The timelock IS the multisig for a solo founder
 *
 * WHAT LIVES IN THE TREASURY:
 * ────────────────────────────
 * - 250M EMBER (25% of supply) — governance controls it
 * - Accumulated stXRP fees from the vault (10% of all yield)
 * - Any other assets governance votes to hold
 *
 * GUARDIAN:
 * ──────────
 * The deployer (you) is set as guardian initially. The guardian
 * can cancel queued transactions if they're malicious — but cannot
 * queue new ones or execute anything. Guardian role should be
 * transferred to address(0) or a community multisig via governance
 * once the protocol is established.
 */

contract EmberTimelock {

    // ── Roles ─────────────────────────────────────────────────────────
    address public governor;   // the only address that can queue txs
    address public guardian;   // can cancel (but not queue or execute)

    // ── Config ────────────────────────────────────────────────────────
    uint256 public constant MIN_DELAY = 2 days;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public delay = 2 days;  // current timelock delay

    // ── Queue ─────────────────────────────────────────────────────────
    // txHash → timestamp when it can execute (0 = not queued)
    mapping(bytes32 => uint256) public queuedAt;

    // ── Events ────────────────────────────────────────────────────────
    event TransactionQueued(bytes32 indexed txHash, address target, uint256 value, bytes data, uint256 eta);
    event TransactionExecuted(bytes32 indexed txHash, address target, uint256 value, bytes data);
    event TransactionCancelled(bytes32 indexed txHash);
    event DelayChanged(uint256 oldDelay, uint256 newDelay);
    event GovernorChanged(address oldGov, address newGov);
    event Received(address indexed from, uint256 amount);

    modifier onlyGovernor() { require(msg.sender == governor, "Timelock: not governor"); _; }
    modifier onlyGuardian() { require(msg.sender == guardian || msg.sender == governor, "Timelock: not guardian"); _; }

    /**
     * @param _governor  EmberGovernor contract address
     * @param _guardian  Founder wallet initially — transfer to address(0) later
     */
    constructor(address _governor, address _guardian) {
        governor = _governor;
        guardian = _guardian;
    }

    receive() external payable { emit Received(msg.sender, msg.value); }

    // ════════════════════════════════════════════════════════════════════
    //  GOVERNOR-ONLY: QUEUE
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Queue a transaction. Only callable by the Governor after a vote passes.
     * @param target  Contract to call
     * @param value   ETH/FLR to send (0 for token transfers)
     * @param data    ABI-encoded calldata
     * @param eta     Timestamp when it can execute (must be >= now + delay)
     */
    function queueTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external onlyGovernor returns (bytes32) {
        require(eta >= block.timestamp + delay, "Timelock: eta too early");
        require(eta <= block.timestamp + MAX_DELAY, "Timelock: eta too late");

        bytes32 txHash = getTxHash(target, value, data, eta);
        require(queuedAt[txHash] == 0, "Timelock: already queued");

        queuedAt[txHash] = eta;
        emit TransactionQueued(txHash, target, value, data, eta);
        return txHash;
    }

    // ════════════════════════════════════════════════════════════════════
    //  EXECUTE (permissionless after delay)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Execute a queued transaction after the timelock expires.
     * Anyone can call this — permissionless execution.
     */
    function executeTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external payable returns (bytes memory) {
        bytes32 txHash = getTxHash(target, value, data, eta);
        require(queuedAt[txHash] != 0,         "Timelock: not queued");
        require(block.timestamp >= eta,         "Timelock: not ready");
        require(block.timestamp <= eta + 14 days, "Timelock: expired");

        queuedAt[txHash] = 0;
        (bool ok, bytes memory result) = target.call{value: value}(data);
        require(ok, "Timelock: execution failed");

        emit TransactionExecuted(txHash, target, value, data);
        return result;
    }

    // ════════════════════════════════════════════════════════════════════
    //  CANCEL (guardian or governor)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Cancel a queued transaction.
     * Guardian can cancel in case of a malicious governance attack.
     */
    function cancelTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external onlyGuardian {
        bytes32 txHash = getTxHash(target, value, data, eta);
        require(queuedAt[txHash] != 0, "Timelock: not queued");
        queuedAt[txHash] = 0;
        emit TransactionCancelled(txHash);
    }

    // ════════════════════════════════════════════════════════════════════
    //  ADMIN (only via executeTransaction — self-governance)
    // ════════════════════════════════════════════════════════════════════

    /** Change the timelock delay. Must be called via a queued + executed governance tx. */
    function setDelay(uint256 newDelay) external {
        require(msg.sender == address(this), "Timelock: self only");
        require(newDelay >= MIN_DELAY && newDelay <= MAX_DELAY, "Timelock: invalid delay");
        emit DelayChanged(delay, newDelay);
        delay = newDelay;
    }

    /** Update governor address (e.g. to upgrade governor contract). */
    function setGovernor(address newGovernor) external {
        require(msg.sender == address(this), "Timelock: self only");
        emit GovernorChanged(governor, newGovernor);
        governor = newGovernor;
    }

    /** Remove guardian (decentralize fully). Call via governance when ready. */
    function renounceGuardian() external {
        require(msg.sender == address(this) || msg.sender == guardian, "Timelock: unauthorized");
        guardian = address(0);
    }

    // ════════════════════════════════════════════════════════════════════
    //  VIEW
    // ════════════════════════════════════════════════════════════════════

    function getTxHash(
        address target,
        uint256 value,
        bytes memory data,
        uint256 eta
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, eta));
    }

    function isQueued(bytes32 txHash) external view returns (bool) {
        return queuedAt[txHash] != 0;
    }

    function getEta(bytes32 txHash) external view returns (uint256) {
        return queuedAt[txHash];
    }
}
