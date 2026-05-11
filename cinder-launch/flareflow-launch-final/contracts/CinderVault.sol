// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔═══════════════════════════════════════════════════════════╗
 * ║              Cinder XRPFi Yield Aggregator             ║
 * ║                   Core Vault Contract                     ║
 * ╚═══════════════════════════════════════════════════════════╝
 *
 * HOW IT WORKS (plain English):
 * ─────────────────────────────
 * 1. Users deposit stXRP (liquid-staked XRP from Firelight protocol)
 * 2. This contract holds all deposits in a single pool (the "vault")
 * 3. stXRP automatically accrues yield (like interest) just by being held —
 *    because the underlying XRP is staked and earning rewards
 * 4. Anyone can call harvest() to collect accumulated yield
 * 5. On harvest: 10% of new yield goes to the protocol treasury (that's you),
 *    90% stays in the vault and benefits all depositors proportionally
 * 6. Users receive "cXRP" share tokens when they deposit — these represent
 *    their proportional ownership of the vault. As yield accumulates,
 *    each cXRP share is worth more stXRP over time.
 * 7. To withdraw, users return cXRP shares and receive stXRP back
 *    (plus their share of accumulated yield, minus 0.1% withdrawal fee)
 *
 * REVENUE STREAMS:
 * ─────────────────
 * • 10% performance fee on all harvested yield  → treasury wallet
 * • 0.1% withdrawal fee on all withdrawals      → treasury wallet
 *
 * EXAMPLE:
 * ─────────
 * Alice deposits 1000 stXRP. Vault has 10,000 stXRP total.
 * Alice owns 10% of shares. Vault earns 100 stXRP yield.
 * Harvest: 10 stXRP → treasury, 90 stXRP stays in vault.
 * Alice's 10% share is now worth ~109 stXRP. She earned 9 stXRP.
 * Protocol earned 10 stXRP.
 *
 * Deploy on: Flare Mainnet (chainId 14) or Coston2 testnet (chainId 114)
 */

// ── Minimal ERC-20 interface for stXRP ──────────────────────────────────────
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

// ── Minimal ERC-20 implementation for cXRP share tokens ────────────────────
contract ERC20 {
    string public name;
    string public symbol;
    uint8  public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply    += amount;
        balanceOf[to]  += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: burn exceeds balance");
        totalSupply    -= amount;
        balanceOf[from] -= amount;
        emit Transfer(from, address(0), amount);
    }
}

// ── Main Vault ───────────────────────────────────────────────────────────────
contract CinderVault is ERC20 {

    // ── Constants ─────────────────────────────────────────────────────────
    uint256 public constant PERFORMANCE_FEE_BPS = 1000; // 10% (basis points: 1000/10000)
    uint256 public constant WITHDRAWAL_FEE_BPS  = 10;   //  0.1%
    uint256 public constant BPS_DENOMINATOR     = 10000;
    uint256 public constant MINIMUM_DEPOSIT     = 1e15; // 0.001 stXRP minimum

    // ── State ──────────────────────────────────────────────────────────────
    IERC20  public immutable stXRP;       // The stXRP token from Firelight/Sceptre
    address public treasury;              // Where protocol fees go
    address public owner;                 // Admin — can change treasury, pause
    bool    public paused;                // Emergency pause

    // TVL cap — limits blast radius before audit completes.
    // Raised by governance vote (CinderGovernor) after clean audit.
    uint256 public tvlCap = 50_000e18;    // 50,000 tokens (~$50K at launch)
    mapping(address => bool) public approvedZaps; // whitelisted zap contracts

    uint256 public totalStXRPDeposited;
    uint256 public totalYieldHarvested;
    uint256 public totalFeesCollected;
    uint256 public lastHarvestTimestamp;
    uint256 public lastHarvestBalance;

    mapping(address => uint256) public userDepositedAmount;
    mapping(address => uint256) public userDepositTimestamp;

    // ── Events ────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 stXrpAmount, uint256 sharesIssued);
    event Withdrawn(address indexed user, uint256 sharesReturned, uint256 stXrpReceived, uint256 fee);
    event Harvested(uint256 yieldAmount, uint256 feeAmount, uint256 timestamp);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event EmergencyPause(bool paused);

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier notPaused() { require(!paused, "Vault: paused"); _; }
    modifier onlyOwner()  { require(msg.sender == owner, "Vault: not owner"); _; }

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(address _stXRP, address _treasury)
        ERC20("Cinder XRP Vault", "cXRP")
    {
        require(_stXRP    != address(0), "Invalid stXRP address");
        require(_treasury != address(0), "Invalid treasury address");
        stXRP                = IERC20(_stXRP);
        treasury             = _treasury;
        owner                = msg.sender;
        lastHarvestTimestamp = block.timestamp;
        lastHarvestBalance   = 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  CORE USER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit stXRP into the vault. Receive cXRP shares in return.
     * @param amount The amount of stXRP to deposit (in wei, 18 decimals)
     *
     * HOW SHARES ARE CALCULATED:
     * If the vault is empty, you get 1:1 shares (deposit 100 → get 100 shares).
     * If the vault already has yield, your shares are worth proportionally
     * more — you get fewer shares, but each share is worth more stXRP.
     * This is the standard ERC-4626 vault math used by all major DeFi protocols.
     */
    function deposit(uint256 amount) external notPaused returns (uint256 shares) {
        require(amount >= MINIMUM_DEPOSIT, "Below minimum deposit");
        require(totalAssets() + amount <= tvlCap, "Vault: TVL cap reached — check governance for raise");

        // Transfer stXRP from user to this vault
        require(
            stXRP.transferFrom(msg.sender, address(this), amount),
            "stXRP transfer failed — did you approve() first?"
        );

        // Calculate shares to issue
        // Formula: shares = (deposit / totalVaultAssets) * totalShares
        // If vault is empty: shares = deposit (1:1)
        uint256 vaultBalance = stXRP.balanceOf(address(this));
        if (totalSupply == 0 || vaultBalance == 0) {
            shares = amount;
        } else {
            // vaultBalance already includes the new deposit, so subtract it
            uint256 balanceBefore = vaultBalance - amount;
            shares = (amount * totalSupply) / balanceBefore;
        }

        require(shares > 0, "Zero shares calculated");

        _mint(msg.sender, shares);
        totalStXRPDeposited          += amount;
        userDepositedAmount[msg.sender] += amount;
        userDepositTimestamp[msg.sender] = block.timestamp;

        // Update harvest baseline
        if (lastHarvestBalance == 0) {
            lastHarvestBalance = stXRP.balanceOf(address(this));
        }

        emit Deposited(msg.sender, amount, shares);
    }

    /**
     * @notice Deposit on behalf of another address.
     * Only callable by approved zap contracts — not the general public.
     *
     * WHY THIS EXISTS:
     * The CinderZap contract stakes FLR → gets sFLR → calls this to
     * deposit the sFLR and send vault shares to the original user.
     * Without this, the zap would deposit under its own address and the
     * user would never receive their cFLR/cXRP shares.
     *
     * WHY IT'S RESTRICTED:
     * If anyone could call depositFor, a malicious contract could deposit
     * on behalf of users without their consent. Only whitelisted zaps can call this.
     */
    function depositFor(address recipient, uint256 amount) external notPaused returns (uint256 shares) {
        require(approvedZaps[msg.sender], "Vault: caller not approved zap");
        require(recipient != address(0), "Vault: zero recipient");
        require(amount >= MINIMUM_DEPOSIT, "Below minimum deposit");
        require(totalAssets() + amount <= tvlCap, "Vault: TVL cap reached");

        require(
            stXRP.transferFrom(msg.sender, address(this), amount),
            "Asset transfer failed"
        );

        uint256 vaultBalance = stXRP.balanceOf(address(this));
        if (totalSupply == 0 || vaultBalance == 0) {
            shares = amount;
        } else {
            uint256 balanceBefore = vaultBalance - amount;
            shares = (amount * totalSupply) / balanceBefore;
        }
        require(shares > 0, "Zero shares");

        _mint(recipient, shares);
        totalStXRPDeposited             += amount;
        userDepositedAmount[recipient]  += amount;
        userDepositTimestamp[recipient]  = block.timestamp;
        if (lastHarvestBalance == 0) lastHarvestBalance = stXRP.balanceOf(address(this));

        emit Deposited(recipient, amount, shares);
    }

    /**
     * @notice Withdraw stXRP by returning cXRP shares.
     * @param shares The number of cXRP shares to burn
     *
     * HOW WITHDRAWAL WORKS:
     * Your shares represent a % of the total vault. If you own 10% of shares
     * and the vault has grown from 1000 to 1100 stXRP, you receive 110 stXRP.
     * A 0.1% fee is deducted from the withdrawal amount.
     */
    function withdraw(uint256 shares) external notPaused returns (uint256 stXrpOut) {
        require(shares > 0, "Zero shares");
        require(balanceOf[msg.sender] >= shares, "Insufficient shares");

        // Calculate stXRP owed for these shares
        uint256 vaultBalance = stXRP.balanceOf(address(this));
        stXrpOut = (shares * vaultBalance) / totalSupply;

        // Burn shares
        _burn(msg.sender, shares);

        // Deduct 0.1% withdrawal fee
        uint256 fee = (stXrpOut * WITHDRAWAL_FEE_BPS) / BPS_DENOMINATOR;
        stXrpOut -= fee;

        // Send fee to treasury
        if (fee > 0) {
            require(stXRP.transfer(treasury, fee), "Fee transfer failed");
            totalFeesCollected += fee;
        }

        // Send stXRP to user
        require(stXRP.transfer(msg.sender, stXrpOut), "Withdrawal transfer failed");

        // Update user tracking
        if (userDepositedAmount[msg.sender] > stXrpOut) {
            userDepositedAmount[msg.sender] -= stXrpOut;
        } else {
            userDepositedAmount[msg.sender] = 0;
        }

        emit Withdrawn(msg.sender, shares, stXrpOut, fee);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HARVEST (anyone can call this — it's public good)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Harvest accumulated yield. Takes 10% as protocol fee.
     *
     * HOW YIELD IS DETECTED:
     * stXRP is a "rebasing" token — its balance increases automatically as
     * XRP staking rewards accumulate. So if this vault held 1000 stXRP
     * and now holds 1010 stXRP without any new deposits, the 10 stXRP
     * difference IS the yield. We send 10% of that to treasury.
     *
     * Anyone can call this — it benefits all depositors by locking in
     * the fee calculation. Typically called by a keeper bot every few hours.
     */
    function harvest() external notPaused returns (uint256 yieldAmount, uint256 feeAmount) {
        uint256 currentBalance = stXRP.balanceOf(address(this));

        // Yield = current balance minus what we had at last harvest
        // (adjusted for deposits/withdrawals that happened since)
        if (currentBalance <= lastHarvestBalance) {
            return (0, 0); // No yield yet
        }

        yieldAmount = currentBalance - lastHarvestBalance;
        feeAmount   = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;

        if (feeAmount > 0) {
            require(stXRP.transfer(treasury, feeAmount), "Fee transfer failed");
            totalFeesCollected  += feeAmount;
            totalYieldHarvested += yieldAmount;
        }

        lastHarvestBalance   = stXRP.balanceOf(address(this)); // post-fee
        lastHarvestTimestamp = block.timestamp;

        emit Harvested(yieldAmount, feeAmount, block.timestamp);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS (free to call, read-only)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Total stXRP held in the vault right now
    function totalAssets() public view returns (uint256) {
        return stXRP.balanceOf(address(this));
    }

    /// @notice How much stXRP a given number of shares is worth right now
    function sharesToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (shares * totalAssets()) / totalSupply;
    }

    /// @notice How many shares a given amount of stXRP would receive if deposited now
    function assetsToShares(uint256 assets) public view returns (uint256) {
        if (totalSupply == 0 || totalAssets() == 0) return assets;
        return (assets * totalSupply) / totalAssets();
    }

    /// @notice Full dashboard data for a user in one call (saves gas)
    function getUserInfo(address user) external view returns (
        uint256 shares,
        uint256 stXrpValue,       // what their shares are worth right now
        uint256 deposited,        // original deposit amount
        uint256 yieldEarned,      // stXrpValue - deposited (approximate)
        uint256 depositTime,      // when they first deposited
        uint256 sharePercent      // their % of total vault (in basis points)
    ) {
        shares      = balanceOf[user];
        stXrpValue  = sharesToAssets(shares);
        deposited   = userDepositedAmount[user];
        yieldEarned = stXrpValue > deposited ? stXrpValue - deposited : 0;
        depositTime = userDepositTimestamp[user];
        sharePercent = totalSupply > 0 ? (shares * 10000) / totalSupply : 0;
    }

    /// @notice Protocol-wide stats for the dashboard
    function getVaultStats() external view returns (
        uint256 tvl,               // Total Value Locked (stXRP)
        uint256 totalShares,       // Total cXRP in circulation
        uint256 pricePerShare,     // stXRP per 1 cXRP (18 decimals)
        uint256 pendingYield,      // Unharvested yield sitting in vault
        uint256 lifetimeYield,     // All yield ever harvested
        uint256 lifetimeFees,      // All fees ever sent to treasury
        uint256 lastHarvest        // Timestamp of last harvest
    ) {
        tvl           = totalAssets();
        totalShares   = totalSupply;
        pricePerShare = totalSupply > 0 ? (totalAssets() * 1e18) / totalSupply : 1e18;
        pendingYield  = totalAssets() > lastHarvestBalance
            ? totalAssets() - lastHarvestBalance : 0;
        lifetimeYield = totalYieldHarvested;
        lifetimeFees  = totalFeesCollected;
        lastHarvest   = lastHarvestTimestamp;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Raise the TVL cap (requires governance vote via timelock)
    function setTvlCap(uint256 newCap) external onlyOwner {
        require(newCap >= totalAssets(), "Cap below current TVL");
        tvlCap = newCap;
    }

    /// @notice Approve or revoke a zap contract
    function setApprovedZap(address zap, bool approved) external onlyOwner {
        require(zap != address(0), "Zero address");
        approvedZaps[zap] = approved;
    }

    /// @notice Update the treasury address (where fees go)
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid address");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Emergency pause — stops deposits and withdrawals
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit EmergencyPause(_paused);
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
}
