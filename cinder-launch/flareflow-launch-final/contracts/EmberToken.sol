// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════╗
 * ║      EMBER — Cinder Governance Token (v2)          ║
 * ║      Solo Founder Edition                            ║
 * ╚══════════════════════════════════════════════════════╝
 *
 * TOTAL SUPPLY: 1,000,000,000 EMBER — fixed forever, no inflation
 *
 * ALLOCATION:
 * ────────────
 * 450M (45%) → EmberMining     — depositor rewards, 4 years
 * 250M (25%) → Treasury       — governed by timelock, no team access
 * 150M (15%) → Public Sale    — funds audit + initial ops
 *  50M  (5%) → Community      — airdrop to early users
 * 100M (10%) → Founder vest   — 2-year linear, on-chain in EmberFounderVest
 *
 * WHAT CHANGED FROM v1 (20% team):
 * ──────────────────────────────────
 * - Founder cut from 20% → 10% (100M EMBER is still life-changing if this works)
 * - Mining up from 40% → 45% (more for community)
 * - Treasury up from 20% → 25% (bigger audit/ops war chest)
 * - No cliff on founder vest — earns tokens daily, not in a lump sum
 * - Treasury is timelock-only, not multisig (you can't form a 2-of-3 alone)
 *
 * GOVERNANCE COMMITMENTS (social, not enforceable):
 * ───────────────────────────────────────────────────
 * - Founder will not vote founder allocation on treasury spending proposals
 * - FIP-0 will propose raising quorum from 4% → 10% once EMBER distributes
 */

contract EmberToken {

    string  public constant name     = "Cinder Governance Token";
    string  public constant symbol   = "EMBER";
    uint8   public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint256 public constant MINING_ALLOC    = 450_000_000e18;
    uint256 public constant TREASURY_ALLOC  = 250_000_000e18;
    uint256 public constant SALE_ALLOC      = 150_000_000e18;
    uint256 public constant COMMUNITY_ALLOC =  50_000_000e18;
    uint256 public constant FOUNDER_ALLOC   = 100_000_000e18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    struct Checkpoint { uint32 fromBlock; uint224 votes; }
    mapping(address => Checkpoint[]) public checkpoints;
    mapping(address => address)      public delegates;
    mapping(address => uint256)      public numCheckpoints;

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DelegateChanged(address indexed delegator, address indexed fromDel, address indexed toDel);
    event DelegateVotesChanged(address indexed delegate, uint256 prev, uint256 next);

    modifier onlyOwner() { require(msg.sender == owner, "EMBER: not owner"); _; }

    /**
     * @param mining          EmberMining rewards contract    (45%)
     * @param timelock        Governor timelock / treasury   (25%)
     * @param sale            EmberSale contract              (15%)
     * @param community       Airdrop distributor or EOA     (5%)
     * @param founderVest     EmberFounderVest contract       (10%)
     */
    constructor(
        address mining,
        address timelock,
        address sale,
        address community,
        address founderVest
    ) {
        owner = msg.sender;
        _mint(mining,      MINING_ALLOC);
        _mint(timelock,    TREASURY_ALLOC);
        _mint(sale,        SALE_ALLOC);
        _mint(community,   COMMUNITY_ALLOC);
        _mint(founderVest, FOUNDER_ALLOC);
        _delegate(msg.sender, msg.sender);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) { require(a >= amount, "EMBER: allowance"); allowance[from][msg.sender] = a - amount; }
        _transfer(from, to, amount); return true;
    }

    function delegate(address delegatee) external { _delegate(msg.sender, delegatee); }

    function _delegate(address delegator, address delegatee) internal {
        address cur = delegates[delegator];
        uint256 bal = balanceOf[delegator];
        delegates[delegator] = delegatee;
        emit DelegateChanged(delegator, cur, delegatee);
        _moveDelegates(cur, delegatee, bal);
    }

    function getCurrentVotes(address account) external view returns (uint256) {
        uint256 n = numCheckpoints[account];
        return n > 0 ? checkpoints[account][n - 1].votes : 0;
    }

    function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "EMBER: not determined");
        uint256 n = numCheckpoints[account];
        if (n == 0) return 0;
        if (checkpoints[account][n - 1].fromBlock <= blockNumber) return checkpoints[account][n - 1].votes;
        if (checkpoints[account][0].fromBlock > blockNumber) return 0;
        uint256 lo = 0; uint256 hi = n - 1;
        while (hi > lo) {
            uint256 mid = hi - (hi - lo) / 2;
            Checkpoint memory cp = checkpoints[account][mid];
            if (cp.fromBlock == blockNumber) return cp.votes;
            else if (cp.fromBlock < blockNumber) lo = mid;
            else hi = mid - 1;
        }
        return checkpoints[account][lo].votes;
    }

    function _moveDelegates(address src, address dst, uint256 amount) internal {
        if (src != dst && amount > 0) {
            if (src != address(0)) {
                uint256 n = numCheckpoints[src]; uint256 old = n > 0 ? checkpoints[src][n-1].votes : 0;
                _writeCheckpoint(src, n, old, old - amount);
            }
            if (dst != address(0)) {
                uint256 n = numCheckpoints[dst]; uint256 old = n > 0 ? checkpoints[dst][n-1].votes : 0;
                _writeCheckpoint(dst, n, old, old + amount);
            }
        }
    }

    function _writeCheckpoint(address delegatee, uint256 nCP, uint256 oldVotes, uint256 newVotes) internal {
        uint32 blockNum = safe32(block.number);
        if (nCP > 0 && checkpoints[delegatee][nCP - 1].fromBlock == blockNum) {
            checkpoints[delegatee][nCP - 1].votes = safe224(newVotes);
        } else {
            checkpoints[delegatee][nCP] = Checkpoint(blockNum, safe224(newVotes));
            numCheckpoints[delegatee] = nCP + 1;
        }
        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "EMBER: zero addr");
        require(balanceOf[from] >= amount, "EMBER: balance");
        balanceOf[from] -= amount; balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        _moveDelegates(delegates[from], delegates[to], amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount; balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
        _moveDelegates(address(0), delegates[to], amount);
    }

    function safe32(uint256 n) internal pure returns (uint32)  { require(n < 2**32,  "EMBER: >32");  return uint32(n);  }
    function safe224(uint256 n) internal pure returns (uint224) { require(n < 2**224, "EMBER: >224"); return uint224(n); }
    function transferOwnership(address newOwner) external onlyOwner { owner = newOwner; }
}
