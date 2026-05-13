// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════╗
 * ║         CinderZap - One-Click FLR → Vault             ║
 * ╚══════════════════════════════════════════════════════════╝
 *
 * WHAT THIS DOES:
 * ────────────────
 * Turns a 3-step user journey into 1 transaction:
 *
 * BEFORE ZAP:
 *   1. Go to sceptre.fi → stake FLR → receive sFLR    (tx 1)
 *   2. Approve sFLR spend on Cinder                 (tx 2)
 *   3. Deposit sFLR into Cinder vault               (tx 3)
 *
 * AFTER ZAP:
 *   1. Send FLR to zapAndDeposit() → get cFLR shares  (tx 1, done)
 *
 * HOW IT WORKS INTERNALLY:
 * ──────────────────────────
 * 1. User sends FLR with the transaction
 * 2. Zap calls sFLR.deposit() with that FLR (sFLR token IS the staking pool on Flare)
 *    → sFLR stakes the FLR and mints sFLR back to the zap
 *    → No swap, no slippage, no DEX fee
 *    → Rate is 1:1 minus Sceptre's existing exchange rate (sFLR appreciates over time)
 * 3. Zap approves the sFLR vault to spend the received sFLR
 * 4. Zap calls vault.depositFor(msg.sender, sFLRAmount)
 *    → Vault pulls sFLR from zap, mints cFLR shares to USER
 * 5. User now has cFLR shares in their wallet
 *
 * WHAT MAKES THIS SAFE:
 * ──────────────────────
 * - Zap holds NO funds between transactions - everything is atomic
 * - If any step reverts, the entire tx reverts (user gets FLR back)
 * - Only whitelisted in the vault - vault.approvedZaps[zapAddr] = true
 * - Minimum output check: user specifies minimum cFLR they accept
 *   (slippage protection - reverts if vault share price moved too much)
 * - Owner cannot drain funds - no fund-holding functions
 * - recoverToken() explicitly blocks sFLR (and stXRP if configured) so
 *   the owner cannot drain the vault asset even in edge cases
 * - Ownership transferred to CinderTimelock post-deploy (no EOA admin)
 * - Fully stateless - no storage of user balances
 *
 * SCEPTRE ADDRESSES (Flare Mainnet):
 * ────────────────────────────────────
 * sFLR token + staking pool: 0x12e605bc104e93B45e1aD99F9e555f659051c2BB
 *   Method:                  deposit() payable - send FLR, receive sFLR
 *
 *   On Flare, the sFLR token contract IS the staking pool — single contract,
 *   not separate token + pool like Lido. Always pass this same address as
 *   both _sceptrePool and _sFLR in the constructor.
 *
 * ALSO SUPPORTS:
 * ───────────────
 * zapAndDepositStXRP() - for when Firelight launches:
 *   FLR → (Firelight stake) → stXRP → deposit → cXRP shares
 *   Currently stubbed, activated when Firelight provides their interface.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ISceptrePool {
    /**
     * @notice Stake FLR and receive sFLR.
     * Send FLR as msg.value. Sceptre mints sFLR to msg.sender.
     * The exchange rate is not 1:1 - sFLR appreciates over time.
     * At any point: 1 sFLR > 1 FLR in value.
     *
     * NOTE: On Flare, the sFLR token contract itself IS the staking pool.
     * The function is named `deposit()` (no args, payable) — confirmed via
     * on-chain transaction inspection. The contract follows an ERC-4626-like
     * pattern where staking and minting happen in one call.
     */
    function deposit() external payable;
}

interface ICinderVault {
    /**
     * @notice Deposit asset on behalf of a recipient.
     * Only callable by approved zap contracts.
     * Returns the number of vault shares minted to recipient.
     */
    function depositFor(address recipient, uint256 amount) external returns (uint256 shares);

    /**
     * @notice Preview how many shares a given asset amount would receive.
     */
    function assetsToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Current total assets in the vault.
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice TVL cap - reverts if deposit would exceed this.
     */
    function tvlCap() external view returns (uint256);
}

contract CinderZap {

    // ── Immutables ─────────────────────────────────────────────────────
    ISceptrePool     public immutable sceptrePool;
    IERC20           public immutable sFLR;
    ICinderVault  public immutable sFLRVault;   // sFLR vault (cFLR shares)

    // Firelight stXRP - set when Firelight Phase 2 launches
    address public stXRPStakingContract; // Firelight staking pool
    IERC20  public stXRP;
    ICinderVault public stXRPVault;   // stXRP vault (cXRP shares)

    address public owner;

    // ── Events ────────────────────────────────────────────────────────
    event ZappedFLRtosFLR(
        address indexed user,
        uint256 flrIn,
        uint256 sFLRReceived,
        uint256 sharesOut
    );
    event ZappedFLRtoStXRP(
        address indexed user,
        uint256 flrIn,
        uint256 stXRPReceived,
        uint256 sharesOut
    );
    event FirelightConfigured(address stakingContract, address stXRP, address vault);

    modifier onlyOwner() { require(msg.sender == owner, "Zap: not owner"); _; }

    /**
     * @param _sceptrePool  Sceptre staking pool (deposit() payable)
     *                       Pass the sFLR token address; it serves as both
     *                       the pool and the token on Flare.
     * @param _sFLR         sFLR token address
     * @param _sFLRVault    Cinder sFLR vault address
     */
    constructor(
        address _sceptrePool,
        address _sFLR,
        address _sFLRVault
    ) {
        sceptrePool = ISceptrePool(_sceptrePool);
        sFLR        = IERC20(_sFLR);
        sFLRVault   = ICinderVault(_sFLRVault);
        owner       = msg.sender;

        // Pre-approve vault to spend all sFLR this contract ever receives
        // Safe because this contract holds no persistent sFLR balance
        IERC20(_sFLR).approve(_sFLRVault, type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════════
    //  PRIMARY: FLR → sFLR → cFLR (one transaction)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Zap FLR into the Cinder sFLR vault in one transaction.
     *
     * @param minShares  Minimum cFLR shares you accept. Reverts if below.
     *                   Calculate this off-chain: expected shares * (1 - slippagePct).
     *                   Pass 0 to skip slippage check (not recommended).
     *
     * HOW TO CALL:
     *   const zap = new ethers.Contract(ZAP_ADDRESS, ZAP_ABI, signer)
     *   const minShares = estimatedShares * 995n / 1000n  // 0.5% slippage tolerance
     *   await zap.zapIntosFLRVault(minShares, { value: ethers.parseEther("100") })
     *
     * WHAT HAPPENS:
     *   100 FLR → Sceptre deposit() → ~95.2 sFLR (rate varies)
     *   ~95.2 sFLR → vault.depositFor(user) → ~95.2 cFLR shares (first deposit)
     *   User receives cFLR in their wallet. Done.
     */
    function zapIntosFLRVault(uint256 minShares) external payable returns (uint256 shares) {
        require(msg.value > 0, "Zap: send FLR");

        // Step 1: Check TVL cap won't be exceeded
        // We check before staking to fail early (avoid wasting gas on Sceptre call)
        // Note: sFLR amount will be slightly less than msg.value due to exchange rate
        // We use msg.value as upper bound for the pre-check
        ICinderVault vault = sFLRVault;
        require(
            vault.totalAssets() + msg.value <= vault.tvlCap(),
            "Zap: vault TVL cap reached - governance vote required to raise"
        );

        // Step 2: Stake FLR with Sceptre → receive sFLR
        // sFLR contract's deposit() is payable; it stakes the FLR and mints sFLR to msg.sender (this contract)
        uint256 sFLRBefore = sFLR.balanceOf(address(this));
        sceptrePool.deposit{value: msg.value}();
        uint256 sFLRReceived = sFLR.balanceOf(address(this)) - sFLRBefore;
        require(sFLRReceived > 0, "Zap: Sceptre returned 0 sFLR");

        // Step 3: Deposit sFLR into vault on behalf of user
        // vault approval was set in constructor (max approval)
        shares = vault.depositFor(msg.sender, sFLRReceived);

        // Step 4: Slippage check
        require(shares >= minShares, "Zap: slippage too high - increase tolerance or try again");

        emit ZappedFLRtosFLR(msg.sender, msg.value, sFLRReceived, shares);
    }

    // ════════════════════════════════════════════════════════════════════
    //  SECONDARY: FLR → stXRP → cXRP (when Firelight launches)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Zap FLR into the Cinder stXRP vault.
     * Only works after configureFirelight() is called by owner.
     * Firelight's staking interface: to be confirmed when Phase 2 launches.
     */
    function zapIntoStXRPVault(uint256 minShares) external payable returns (uint256 shares) {
        require(msg.value > 0, "Zap: send FLR");
        require(stXRPStakingContract != address(0), "Zap: Firelight not configured yet");

        ICinderVault vault = stXRPVault;
        require(
            vault.totalAssets() + msg.value <= vault.tvlCap(),
            "Zap: stXRP vault TVL cap reached"
        );

        // Stake FLR with Firelight to get stXRP
        // Interface TBD - Firelight Phase 2 not yet live
        // When it launches, update the function selector below to match
        // their actual staking entry point. The placeholder "submit()" is
        // a guess; confirm via Firelight docs before configureFirelight() is called.
        uint256 stXRPBefore = stXRP.balanceOf(address(this));
        (bool ok,) = stXRPStakingContract.call{value: msg.value}(
            abi.encodeWithSignature("submit()")
        );
        require(ok, "Zap: Firelight stake failed");
        uint256 stXRPReceived = stXRP.balanceOf(address(this)) - stXRPBefore;
        require(stXRPReceived > 0, "Zap: Firelight returned 0 stXRP");

        shares = vault.depositFor(msg.sender, stXRPReceived);
        require(shares >= minShares, "Zap: slippage too high");

        emit ZappedFLRtoStXRP(msg.sender, msg.value, stXRPReceived, shares);
    }

    // ════════════════════════════════════════════════════════════════════
    //  VIEW - preview before transacting
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Preview how many cFLR shares you'd receive for a given FLR amount.
     * Not exact - the actual sFLR received from Sceptre depends on the live
     * exchange rate at execution time. Use this as an estimate with ~0.5% buffer.
     *
     * @param flrAmount  FLR to zap (in wei)
     * @return estimatedShares  Approximate cFLR shares you'd receive
     * @return currentsFLRRate  Current sFLR per FLR rate (scaled 1e18)
     * @return vaultCapRemaining  How much more can be deposited before cap
     */
    function previewZapsFLR(uint256 flrAmount) external view returns (
        uint256 estimatedShares,
        uint256 currentsFLRRate,
        uint256 vaultCapRemaining
    ) {
        // Sceptre exchange rate: sFLR appreciates over time, so 1 FLR < 1 sFLR in USD value
        // but in token terms you receive slightly less sFLR than FLR sent
        // We approximate the rate from the sFLR/FLR exchange
        // In production, read directly from Sceptre's getPooledFlrByShares() or equivalent
        uint256 sFLREstimate = flrAmount; // conservative 1:1 estimate - real rate is close at launch
        estimatedShares     = sFLRVault.assetsToShares(sFLREstimate);
        currentsFLRRate     = 1e18; // 1:1 approximation
        uint256 currentTvl  = sFLRVault.totalAssets();
        uint256 cap         = sFLRVault.tvlCap();
        vaultCapRemaining   = cap > currentTvl ? cap - currentTvl : 0;
    }

    // ════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure Firelight staking when Phase 2 launches.
     * Approved vault must already have this zap whitelisted.
     */
    function configureFirelight(
        address _stakingContract,
        address _stXRP,
        address _stXRPVault
    ) external onlyOwner {
        require(_stakingContract != address(0), "Zap: zero address");
        stXRPStakingContract = _stakingContract;
        stXRP                = IERC20(_stXRP);
        stXRPVault           = ICinderVault(_stXRPVault);
        // Pre-approve stXRP vault
        IERC20(_stXRP).approve(_stXRPVault, type(uint256).max);
        emit FirelightConfigured(_stakingContract, _stXRP, _stXRPVault);
    }

    /**
     * @notice Emergency: recover any tokens accidentally sent to this contract.
     * The zap should hold zero balances between transactions.
     * If any tokens are stuck (e.g. Sceptre call partially succeeded),
     * the owner can recover them and return to the user.
     *
     * SAFETY: This function CANNOT recover sFLR (the vault asset). That asset
     * flows through the zap on every deposit; allowing owner-recovery would
     * create a rug vector. Stuck sFLR (which should be impossible since the
     * zap pre-approves max to the vault and depositFor is atomic) would need
     * to be rescued via a contract upgrade through governance.
     */
    function recoverToken(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Zap: zero address");
        require(token != address(sFLR), "Zap: cannot recover vault asset");
        if (address(stXRP) != address(0)) {
            require(token != address(stXRP), "Zap: cannot recover stXRP asset");
        }
        IERC20(token).transfer(to, amount);
    }

    function recoverFLR(address payable to) external onlyOwner {
        require(to != address(0), "Zap: zero address");
        to.transfer(address(this).balance);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zap: zero address");
        owner = newOwner;
    }

    // Reject accidental ETH/FLR sends
    receive() external payable {
        revert("Zap: use zapIntosFLRVault()");
    }
}
