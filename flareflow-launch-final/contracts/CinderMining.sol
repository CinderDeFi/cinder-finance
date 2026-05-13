// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════╗
 * ║     CinderMining v2 — Dual Pool Liquidity Mining           ║
 * ╚══════════════════════════════════════════════════════════╝
 *
 * WHAT CHANGED FROM v1:
 * ──────────────────────
 * v1: one pool, one token (cXRP only)
 * v2: multiple pools, any vault share token
 *
 * POOLS AT LAUNCH:
 * ─────────────────
 * Pool 0 — cFLR  (sFLR vault) — LIVE via Sceptre on Flare now
 * Pool 1 — cXRP  (stXRP vault) — added when Firelight Phase 2 launches
 *
 * EMISSION SPLIT AT LAUNCH:
 * ──────────────────────────
 * Pool 0 (cFLR): 6000 bps = 60% of emission
 * Pool 1 (cXRP): 4000 bps = 40% of emission
 * Governor adjusts allocations by governance vote at any time.
 *
 * TOTAL EMISSION: 450M EMBER over 4 years
 * Year 1: 180M | Year 2: 108M | Year 3: 90M | Year 4: 72M
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract CinderMining {

    IERC20  public immutable EMBER;
    address public owner;
    address public governor;

    // ── Emission schedule ──────────────────────────────────────────────
    struct Epoch { uint256 duration; uint256 totalFlow; }
    Epoch[4] public epochs;
    uint256  public currentEpoch;
    uint256  public epochStartTime;
    uint256  public rewardRate;
    uint256  public periodFinish;

    // ── Pools ──────────────────────────────────────────────────────────
    struct Pool {
        IERC20  stakedToken;
        uint256 allocBps;             // share of emission, out of 10000
        uint256 rewardPerTokenStored;
        uint256 lastUpdateTime;
        uint256 totalStaked;
        string  name;
        bool    active;
    }
    Pool[] public pools;

    // poolId → user → value
    mapping(uint256 => mapping(address => uint256)) public stakedBalance;
    mapping(uint256 => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(uint256 => mapping(address => uint256)) public rewards;

    uint256 public totalDistributed;

    event PoolAdded(uint256 indexed pid, address stakedToken, uint256 allocBps, string name);
    event AllocUpdated(uint256 indexed pid, uint256 newBps);
    event Staked(uint256 indexed pid, address indexed user, uint256 amount);
    event Withdrawn(uint256 indexed pid, address indexed user, uint256 amount);
    event RewardClaimed(uint256 indexed pid, address indexed user, uint256 reward);
    event EpochAdvanced(uint256 newEpoch, uint256 newRate);

    modifier onlyOwner()          { require(msg.sender == owner, "not owner"); _; }
    modifier onlyGov()            { require(msg.sender == governor || msg.sender == owner, "not gov"); _; }
    modifier validPool(uint256 p) { require(p < pools.length, "bad pool"); _; }

    constructor(address _flow) {
        EMBER     = IERC20(_flow);
        owner    = msg.sender;
        governor = msg.sender;
        uint256 yr = 365 days;
        epochs[0] = Epoch(yr, 180_000_000e18);
        epochs[1] = Epoch(yr, 108_000_000e18);
        epochs[2] = Epoch(yr,  90_000_000e18);
        epochs[3] = Epoch(yr,  72_000_000e18);
    }

    // ── Setup ──────────────────────────────────────────────────────────

    function addPool(address stakedToken, uint256 allocBps, string calldata name)
        external onlyGov
    {
        require(stakedToken != address(0), "zero addr");
        _updateAllPools();
        pools.push(Pool({
            stakedToken:          IERC20(stakedToken),
            allocBps:             allocBps,
            rewardPerTokenStored: 0,
            lastUpdateTime:       lastTimeRewardApplicable(),
            totalStaked:          0,
            name:                 name,
            active:               true
        }));
        emit PoolAdded(pools.length - 1, stakedToken, allocBps, name);
    }

    function setAlloc(uint256 pid, uint256 newBps) external onlyGov validPool(pid) {
        _updatePool(pid);
        pools[pid].allocBps = newBps;
        emit AllocUpdated(pid, newBps);
    }

    function startMining() external onlyOwner {
        require(epochStartTime == 0, "already started");
        require(pools.length > 0,   "add pools first");
        epochStartTime = block.timestamp;
        _setEpochRate(0);
    }

    function advanceEpoch() external {
        require(block.timestamp >= epochStartTime + epochs[currentEpoch].duration, "epoch not over");
        require(currentEpoch < 3, "all epochs done");
        _updateAllPools();
        currentEpoch++;
        epochStartTime = block.timestamp;
        _setEpochRate(currentEpoch);
        emit EpochAdvanced(currentEpoch, rewardRate);
    }

    function _setEpochRate(uint256 idx) internal {
        rewardRate   = epochs[idx].totalFlow / epochs[idx].duration;
        periodFinish = block.timestamp + epochs[idx].duration;
    }

    // ── User actions ───────────────────────────────────────────────────

    function stake(uint256 pid, uint256 amount) external validPool(pid) {
        require(amount > 0 && pools[pid].active, "invalid stake");
        _updateUserReward(pid, msg.sender);
        pools[pid].totalStaked        += amount;
        stakedBalance[pid][msg.sender] += amount;
        pools[pid].stakedToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(pid, msg.sender, amount);
    }

    function _withdraw(uint256 pid, uint256 amount) internal {
        _updateUserReward(pid, msg.sender);
        pools[pid].totalStaked        -= amount;
        stakedBalance[pid][msg.sender] -= amount;
        pools[pid].stakedToken.transfer(msg.sender, amount);
        _claim(pid, msg.sender);
    }

    function withdraw(uint256 pid, uint256 amount) external validPool(pid) {
        require(amount > 0 && stakedBalance[pid][msg.sender] >= amount, "invalid withdraw");
        _updateUserReward(pid, msg.sender);
        pools[pid].totalStaked        -= amount;
        stakedBalance[pid][msg.sender] -= amount;
        pools[pid].stakedToken.transfer(msg.sender, amount);
        _claim(pid, msg.sender);
        emit Withdrawn(pid, msg.sender, amount);
    }

    function claimReward(uint256 pid) external validPool(pid) {
        _updateUserReward(pid, msg.sender);
        _claim(pid, msg.sender);
    }

    function claimAll() external {
        for (uint256 i = 0; i < pools.length; i++) {
            _updateUserReward(i, msg.sender);
            _claim(i, msg.sender);
        }
    }

    function exit(uint256 pid) external validPool(pid) {
        _withdraw(pid, stakedBalance[pid][msg.sender]);
    }

    function _claim(uint256 pid, address user) internal {
        uint256 r = rewards[pid][user];
        if (r > 0) {
            rewards[pid][user] = 0;
            totalDistributed  += r;
            EMBER.transfer(user, r);
            emit RewardClaimed(pid, user, r);
        }
    }

    // ── Reward math ────────────────────────────────────────────────────

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken(uint256 pid) public view returns (uint256) {
        Pool storage p = pools[pid];
        if (p.totalStaked == 0) return p.rewardPerTokenStored;
        uint256 poolRate = (rewardRate * p.allocBps) / 10000;
        return p.rewardPerTokenStored
            + (lastTimeRewardApplicable() - p.lastUpdateTime) * poolRate * 1e18 / p.totalStaked;
    }

    function earned(uint256 pid, address user) public view returns (uint256) {
        return stakedBalance[pid][user]
            * (rewardPerToken(pid) - userRewardPerTokenPaid[pid][user]) / 1e18
            + rewards[pid][user];
    }

    function earnedAll(address user) external view returns (uint256 total) {
        for (uint256 i = 0; i < pools.length; i++) total += earned(i, user);
    }

    function _updatePool(uint256 pid) internal {
        pools[pid].rewardPerTokenStored = rewardPerToken(pid);
        pools[pid].lastUpdateTime       = lastTimeRewardApplicable();
    }

    function _updateAllPools() internal {
        for (uint256 i = 0; i < pools.length; i++) _updatePool(i);
    }

    function _updateUserReward(uint256 pid, address user) internal {
        _updatePool(pid);
        rewards[pid][user]                = earned(pid, user);
        userRewardPerTokenPaid[pid][user] = pools[pid].rewardPerTokenStored;
    }

    // ── View ───────────────────────────────────────────────────────────

    function poolCount() external view returns (uint256) { return pools.length; }

    function getPoolInfo(uint256 pid) external view returns (
        string memory name,
        address       stakedToken,
        uint256       allocBps,
        uint256       totalStaked,
        uint256       flowPerDay,
        bool          active
    ) {
        Pool storage p = pools[pid];
        uint256 rate = rewardRate > 0 ? (rewardRate * p.allocBps) / 10000 : 0;
        return (p.name, address(p.stakedToken), p.allocBps, p.totalStaked, rate * 1 days, p.active);
    }

    function getUserInfo(address user) external view returns (
        uint256[] memory staked,
        uint256[] memory pending,
        uint256          totalPending,
        uint256          epochNum,
        uint256          epochEnds
    ) {
        uint256 n  = pools.length;
        staked     = new uint256[](n);
        pending    = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            staked[i]     = stakedBalance[i][user];
            pending[i]    = earned(i, user);
            totalPending += pending[i];
        }
        epochNum  = currentEpoch + 1;
        epochEnds = epochStartTime + epochs[currentEpoch].duration;
    }

    function annualEmission() external view returns (uint256) {
        return rewardRate * 365 days;
    }

    // ── Admin ──────────────────────────────────────────────────────────
    function setGovernor(address g)   external onlyOwner { governor = g; }
    function deactivatePool(uint256 pid) external onlyGov validPool(pid) {
        _updatePool(pid); pools[pid].active = false;
    }
    function transferOwnership(address n) external onlyOwner { owner = n; }
}
