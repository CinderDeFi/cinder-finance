// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════╗
 * ║         EmberGovernor — On-Chain Governance           ║
 * ╚══════════════════════════════════════════════════════╝
 *
 * WHAT THIS DOES (plain English):
 * ──────────────────────────────────
 * This is the "parliament" of Cinder. EMBER token holders
 * can propose changes to the protocol and vote on them.
 * Winning proposals are automatically executed on-chain.
 *
 * WHAT CAN BE GOVERNED:
 * ──────────────────────
 * Anything the vault/treasury can do:
 * • Change the performance fee (10% → 8%?)
 * • Change the withdrawal fee
 * • Add new vaults (FBTC, FDOGE)
 * • Spend treasury funds (grants, audits, buybacks)
 * • Change emission rates in EmberMining
 * • Upgrade contracts (via timelock)
 *
 * THE GOVERNANCE PROCESS:
 * ────────────────────────
 * 1. PROPOSE  — Any holder of ≥ 1M EMBER can create a proposal
 * 2. DELAY    — 2-day voting delay (lets people prepare)
 * 3. VOTE     — 5-day voting window. For/Against/Abstain.
 * 4. QUEUE    — Winning proposals enter a 2-day timelock
 * 5. EXECUTE  — After timelock, anyone can execute the action
 *
 * QUORUM: 4% of total supply must vote FOR a proposal to pass.
 * That's 40M EMBER. Prevents tiny minorities from controlling protocol.
 *
 * TIMELOCK: Even after a vote passes, there's a 2-day delay
 * before execution. This gives users time to exit if they disagree
 * with a change. This is critical for user protection.
 *
 * This design is inspired by Compound Governor Bravo —
 * the most battle-tested governance system in DeFi.
 */

interface IEmberToken {
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract EmberGovernor {

    // ── Governance parameters ─────────────────────────────────────────────
    uint256 public constant VOTING_DELAY   = 2 days / 2;    // ~2 days in blocks (2s blocks)
    uint256 public constant VOTING_PERIOD  = 5 days / 2;    // ~5 days in blocks
    uint256 public constant TIMELOCK_DELAY = 2 days;        // seconds before execution
    uint256 public constant QUORUM_BPS     = 400;           // 4% of total supply
    uint256 public constant PROPOSAL_THRESHOLD = 1_000_000e18; // 1M EMBER to propose

    // ── Proposal states ───────────────────────────────────────────────────
    enum ProposalState {
        Pending,    // created, voting hasn't started
        Active,     // voting open
        Defeated,   // voting closed, did not pass
        Succeeded,  // voting closed, passed
        Queued,     // in timelock
        Executed,   // done
        Cancelled,  // cancelled by proposer
        Expired     // queued but not executed in time
    }

    enum VoteType { Against, For, Abstain }

    // ── Proposal struct ───────────────────────────────────────────────────
    struct Proposal {
        uint256 id;
        address proposer;
        // Execution target (what contract to call)
        address[] targets;
        uint256[] values;
        bytes[]   calldatas;
        string[]  signatures;
        // Timing
        uint256 startBlock;
        uint256 endBlock;
        uint256 eta;            // timelock: earliest execution time
        // Votes
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        // State
        bool    cancelled;
        bool    executed;
        // Meta
        string  description;
        uint256 snapshotBlock;  // block at which voting power is snapshotted
    }

    // ── Receipt: tracks if an address has voted on a proposal ────────────
    struct Receipt {
        bool    hasVoted;
        uint8   support;    // 0=Against, 1=For, 2=Abstain
        uint256 votes;
    }

    // ── State ─────────────────────────────────────────────────────────────
    IEmberToken public immutable token;
    address    public guardian;   // can cancel malicious proposals, no other power
    uint256    public proposalCount;

    mapping(uint256 => Proposal)                       public proposals;
    mapping(uint256 => mapping(address => Receipt))    public receipts;
    mapping(bytes32 => bool)                           public queuedTransactions;

    // ── Events ────────────────────────────────────────────────────────────
    event ProposalCreated(uint256 id, address proposer, string description, uint256 startBlock, uint256 endBlock);
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 votes, string reason);
    event ProposalQueued(uint256 id, uint256 eta);
    event ProposalExecuted(uint256 id);
    event ProposalCancelled(uint256 id);

    constructor(address _token, address _guardian) {
        token    = IEmberToken(_token);
        guardian = _guardian;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PROPOSE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new governance proposal.
     *
     * @param targets      Contract addresses to call if proposal passes
     * @param values       ETH/FLR to send with each call (usually 0)
     * @param signatures   Function signatures (e.g. "setFee(uint256)")
     * @param calldatas    ABI-encoded function arguments
     * @param description  Human-readable proposal description (supports Markdown)
     *
     * EXAMPLE — propose changing the performance fee to 8%:
     * targets    = [vaultAddress]
     * values     = [0]
     * signatures = ["setPerformanceFee(uint256)"]
     * calldatas  = [abi.encode(800)]  // 800 basis points = 8%
     * description = "# Reduce performance fee\nReduce from 10% to 8% to..."
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[]  memory signatures,
        bytes[]   memory calldatas,
        string    memory description
    ) external returns (uint256 proposalId) {
        require(
            token.getPriorVotes(msg.sender, block.number - 1) >= PROPOSAL_THRESHOLD,
            "Governor: proposer votes below threshold (need 1M EMBER)"
        );
        require(targets.length == values.length && targets.length == calldatas.length, "Governor: arity mismatch");
        require(targets.length > 0, "Governor: must provide actions");
        require(targets.length <= 10, "Governor: too many actions");

        proposalCount++;
        proposalId = proposalCount;

        Proposal storage p = proposals[proposalId];
        p.id            = proposalId;
        p.proposer      = msg.sender;
        p.targets       = targets;
        p.values        = values;
        p.signatures    = signatures;
        p.calldatas     = calldatas;
        p.description   = description;
        p.startBlock    = block.number + VOTING_DELAY;
        p.endBlock      = block.number + VOTING_DELAY + VOTING_PERIOD;
        p.snapshotBlock = block.number;

        emit ProposalCreated(proposalId, msg.sender, description, p.startBlock, p.endBlock);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VOTE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Cast a vote on a proposal.
     * @param proposalId  The proposal to vote on
     * @param support     0 = Against, 1 = For, 2 = Abstain
     */
    function castVote(uint256 proposalId, uint8 support) external returns (uint256) {
        return _castVote(msg.sender, proposalId, support, "");
    }

    /**
     * @notice Cast a vote with an optional reason string (shown in UI).
     */
    function castVoteWithReason(uint256 proposalId, uint8 support, string calldata reason) external returns (uint256) {
        return _castVote(msg.sender, proposalId, support, reason);
    }

    function _castVote(address voter, uint256 proposalId, uint8 support, string memory reason) internal returns (uint256) {
        require(state(proposalId) == ProposalState.Active, "Governor: voting is closed");
        require(support <= 2, "Governor: invalid vote type");

        Proposal storage proposal = proposals[proposalId];
        Receipt   storage receipt  = receipts[proposalId][voter];
        require(!receipt.hasVoted, "Governor: already voted");

        uint256 votes = token.getPriorVotes(voter, proposal.snapshotBlock);
        require(votes > 0, "Governor: no voting power at snapshot block");

        if (support == 0)      proposal.againstVotes += votes;
        else if (support == 1) proposal.forVotes     += votes;
        else                   proposal.abstainVotes  += votes;

        receipt.hasVoted = true;
        receipt.support  = support;
        receipt.votes    = votes;

        emit VoteCast(voter, proposalId, support, votes, reason);
        return votes;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  QUEUE + EXECUTE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Queue a successful proposal into the timelock.
     */
    function queue(uint256 proposalId) external {
        require(state(proposalId) == ProposalState.Succeeded, "Governor: proposal not succeeded");
        Proposal storage p = proposals[proposalId];
        uint256 eta = block.timestamp + TIMELOCK_DELAY;
        p.eta = eta;

        for (uint i = 0; i < p.targets.length; i++) {
            bytes32 txHash = keccak256(abi.encode(p.targets[i], p.values[i], p.signatures[i], p.calldatas[i], eta));
            require(!queuedTransactions[txHash], "Governor: already queued");
            queuedTransactions[txHash] = true;
        }
        emit ProposalQueued(proposalId, eta);
    }

    /**
     * @notice Execute a queued proposal after timelock expires.
     * Anyone can call this — execution is permissionless once timelock passes.
     */
    function execute(uint256 proposalId) external payable {
        require(state(proposalId) == ProposalState.Queued, "Governor: proposal not queued");
        Proposal storage p = proposals[proposalId];
        require(block.timestamp >= p.eta, "Governor: timelock not expired");
        require(block.timestamp <= p.eta + 14 days, "Governor: transaction expired");

        p.executed = true;

        for (uint i = 0; i < p.targets.length; i++) {
            bytes32 txHash = keccak256(abi.encode(p.targets[i], p.values[i], p.signatures[i], p.calldatas[i], p.eta));
            queuedTransactions[txHash] = false;

            bytes memory callData;
            if (bytes(p.signatures[i]).length == 0) {
                callData = p.calldatas[i];
            } else {
                callData = abi.encodePacked(bytes4(keccak256(bytes(p.signatures[i]))), p.calldatas[i]);
            }

            (bool success,) = p.targets[i].call{value: p.values[i]}(callData);
            require(success, "Governor: transaction execution reverted");
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal. Proposer can cancel, guardian can cancel anything.
     */
    function cancel(uint256 proposalId) external {
        ProposalState s = state(proposalId);
        require(s != ProposalState.Executed, "Governor: cannot cancel executed proposal");
        Proposal storage p = proposals[proposalId];
        require(msg.sender == p.proposer || msg.sender == guardian, "Governor: not authorized");
        p.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VIEW: PROPOSAL STATE
    // ════════════════════════════════════════════════════════════════════════

    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalId <= proposalCount && proposalId > 0, "Governor: invalid proposal id");
        Proposal storage p = proposals[proposalId];

        if (p.cancelled) return ProposalState.Cancelled;
        if (block.number <= p.startBlock) return ProposalState.Pending;
        if (block.number <= p.endBlock)   return ProposalState.Active;

        bool quorumReached = p.forVotes >= _quorumVotes();
        bool votePassed    = p.forVotes > p.againstVotes;

        if (!quorumReached || !votePassed) return ProposalState.Defeated;
        if (p.executed)   return ProposalState.Executed;
        if (p.eta == 0)   return ProposalState.Succeeded;
        if (block.timestamp <= p.eta + 14 days) return ProposalState.Queued;
        return ProposalState.Expired;
    }

    function _quorumVotes() public view returns (uint256) {
        return token.totalSupply() * QUORUM_BPS / 10000;
    }

    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return receipts[proposalId][voter];
    }

    function getProposalVotes(uint256 proposalId) external view returns (
        uint256 forVotes, uint256 againstVotes, uint256 abstainVotes
    ) {
        Proposal storage p = proposals[proposalId];
        return (p.forVotes, p.againstVotes, p.abstainVotes);
    }

    /**
     * @notice Get all proposals (paginated).
     */
    function getProposals(uint256 from, uint256 count) external view returns (
        uint256[] memory ids,
        address[] memory proposers,
        string[]  memory descriptions,
        ProposalState[] memory states_,
        uint256[] memory forVotes_,
        uint256[] memory endBlocks
    ) {
        uint256 end = from + count;
        if (end > proposalCount) end = proposalCount;
        uint256 len = end - from + 1;
        ids          = new uint256[](len);
        proposers    = new address[](len);
        descriptions = new string[](len);
        states_      = new ProposalState[](len);
        forVotes_    = new uint256[](len);
        endBlocks    = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 pid = from + i;
            Proposal storage p = proposals[pid];
            ids[i]          = p.id;
            proposers[i]    = p.proposer;
            descriptions[i] = p.description;
            states_[i]      = state(pid);
            forVotes_[i]    = p.forVotes;
            endBlocks[i]    = p.endBlock;
        }
    }
}
