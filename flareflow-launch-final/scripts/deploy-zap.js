/**
 * deploy-zap.js — Standalone CinderZap deployment
 *
 * Use this AFTER your main protocol is already deployed.
 * Deploys ONLY the CinderZap contract using existing addresses.
 *
 * REQUIRED .env values:
 *   SFLR_VAULT       = 0x153cD27cd7A8C0a78898bca2101B087029224804
 *   CINDER_TIMELOCK  = 0xee67eA383B8Fad32AE7ca7CE912fB1d21A175148
 *
 * OPTIONAL .env values (defaults to Flare mainnet):
 *   SCEPTRE_POOL     = 0x12e605bc104e93B45e1aD99F9e555f659051c2BB  (sFLR token)
 *   SFLR_ADDRESS     = 0x12e605bc104e93B45e1aD99F9e555f659051c2BB  (same — see note)
 *
 * NOTE ON ADDRESSES:
 *   On Flare, the sFLR token contract IS the staking pool. They are the same
 *   address. The contract has a `deposit()` payable function that stakes the
 *   incoming FLR and mints sFLR to msg.sender atomically. This differs from
 *   Lido on Ethereum where stETH (token) and stETH submission are separate.
 *
 * USAGE:
 *   1. Both SCEPTRE_POOL and SFLR_ADDRESS in .env should point to the same
 *      address (0x12e605...c2BB). The default values handle this correctly.
 *      → If you want to double-check, open this address on FlareScan and
 *        confirm there's a `deposit()` payable function in the contract ABI.
 *
 *   2. Dry-run on testnet:
 *      npx hardhat run scripts/deploy-zap.js --network coston2
 *
 *   3. Real deploy:
 *      npx hardhat run scripts/deploy-zap.js --network flare
 *
 *   4. After deploy, whitelist the zap in the sFLR vault:
 *      → If vault is still owned by deployer EOA: this script does it automatically
 *      → If vault is owned by CinderGovernor: submit a governance proposal
 *        calling sFLRVault.setApprovedZap(ZAP_ADDRESS, true)
 *
 *   5. Verify the contract on FlareScan with the three constructor args
 *      (script prints these at the end for easy copy-paste)
 */

const { ethers, network } = require("hardhat");
require("dotenv").config();

// ── Defaults for Flare mainnet ──────────────────────────────────────
// IMPORTANT: On Flare, the sFLR token contract IS the staking pool.
// Both _sceptrePool and _sFLR constructor args use the same address.
// The function called is deposit() payable (confirmed via on-chain inspection).
const DEFAULTS = {
  SCEPTRE_POOL: "0x12e605bc104e93B45e1aD99F9e555f659051c2BB",  // sFLR token = pool
  SFLR_ADDRESS: "0x12e605bc104e93B45e1aD99F9e555f659051c2BB",  // same address
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  const isMainnet = network.name === "flare";

  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║              CinderZap — Standalone Deploy              ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");
  console.log(`Network:  ${network.name}${isMainnet ? "  (MAINNET — REAL FUNDS)" : ""}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance:  ${ethers.formatEther(balance)} ${isMainnet ? "FLR" : "FLR-test"}`);

  if (isMainnet && balance < ethers.parseEther("5")) {
    console.log("\n⚠ Deployer balance < 5 FLR. You may run out of gas mid-deploy.");
    console.log("  Recommended: top up to at least 10 FLR before continuing.");
    console.log("  Aborting. Re-run after funding.\n");
    process.exit(1);
  }

  // ── Resolve constructor args ──────────────────────────────────────
  const SCEPTRE_POOL = process.env.SCEPTRE_POOL || DEFAULTS.SCEPTRE_POOL;
  const SFLR_ADDRESS = process.env.SFLR_ADDRESS || DEFAULTS.SFLR_ADDRESS;
  const SFLR_VAULT   = process.env.SFLR_VAULT;
  const TIMELOCK     = process.env.CINDER_TIMELOCK;

  if (!SFLR_VAULT) {
    console.error("\n✗ Missing SFLR_VAULT in .env");
    console.error("  Set: SFLR_VAULT=0x153cD27cd7A8C0a78898bca2101B087029224804\n");
    process.exit(1);
  }
  if (!TIMELOCK) {
    console.error("\n✗ Missing CINDER_TIMELOCK in .env");
    console.error("  Set: CINDER_TIMELOCK=0xee67eA383B8Fad32AE7ca7CE912fB1d21A175148\n");
    process.exit(1);
  }

  // Normalize to checksum addresses (catches typos)
  const sceptrePool = ethers.getAddress(SCEPTRE_POOL);
  const sFLR        = ethers.getAddress(SFLR_ADDRESS);
  const sFLRVault   = ethers.getAddress(SFLR_VAULT);
  const timelock    = ethers.getAddress(TIMELOCK);

  console.log("\n── Constructor args ──────────────────────────────────────");
  console.log(`  _sceptrePool  ${sceptrePool}`);
  console.log(`  _sFLR         ${sFLR}`);
  console.log(`  _sFLRVault    ${sFLRVault}`);
  console.log(`  Final owner   ${timelock}  (post-deploy transfer)`);

  // ── Sanity-check the Sceptre pool exists and looks like a contract ──
  if (isMainnet) {
    const code = await ethers.provider.getCode(sceptrePool);
    if (code === "0x") {
      console.error("\n✗ Sceptre pool address has no contract code!");
      console.error(`  Address: ${sceptrePool}`);
      console.error("  Verify on FlareScan before deploying.\n");
      process.exit(1);
    }
    console.log(`\n  ✓ Sceptre pool has contract code (${(code.length-2)/2} bytes)`);

    const sFLRCode = await ethers.provider.getCode(sFLR);
    if (sFLRCode === "0x") {
      console.error("\n✗ sFLR address has no contract code!"); process.exit(1);
    }
    const vaultCode = await ethers.provider.getCode(sFLRVault);
    if (vaultCode === "0x") {
      console.error("\n✗ sFLR Vault address has no contract code!"); process.exit(1);
    }
    console.log(`  ✓ sFLR token has contract code`);
    console.log(`  ✓ sFLR Vault has contract code`);
  }

  // ── Final confirmation pause ──────────────────────────────────────
  if (isMainnet) {
    console.log("\n⏳ Deploying in 5 seconds. Ctrl+C to abort.");
    await new Promise(r => setTimeout(r, 5000));
  }

  // ── Deploy ────────────────────────────────────────────────────────
  console.log("\n── Deploying CinderZap ───────────────────────────────────");
  const Zap = await ethers.getContractFactory("CinderZap");
  const zap = await Zap.deploy(sceptrePool, sFLR, sFLRVault);
  await zap.waitForDeployment();
  const zapAddress = await zap.getAddress();
  console.log(`  ✓ CinderZap deployed at: ${zapAddress}`);

  // Print deploy tx for receipt tracking
  const deployTx = zap.deploymentTransaction();
  if (deployTx) {
    console.log(`    tx: ${deployTx.hash}`);
  }

  // ── Attempt to whitelist zap in the vault ────────────────────────
  // This will succeed only if the vault is still owned by the deployer.
  // If ownership has been transferred to the governor, this reverts and
  // we instruct the user to submit a governance proposal instead.
  console.log("\n── Vault whitelist ──────────────────────────────────────");
  const vaultAbi = [
    "function owner() view returns (address)",
    "function setApprovedZap(address zap, bool approved)",
  ];
  const vault = new ethers.Contract(sFLRVault, vaultAbi, deployer);

  let vaultOwner;
  try {
    vaultOwner = await vault.owner();
  } catch (e) {
    console.log("  ⚠ Could not read vault.owner(). Skipping whitelist.");
    vaultOwner = null;
  }

  if (vaultOwner) {
    console.log(`  Vault owner: ${vaultOwner}`);
    if (vaultOwner.toLowerCase() === deployer.address.toLowerCase()) {
      console.log("  → You own the vault directly. Whitelisting zap now...");
      try {
        const tx = await vault.setApprovedZap(zapAddress, true);
        await tx.wait();
        console.log(`  ✓ Zap whitelisted in sFLR vault (tx: ${tx.hash})`);
      } catch (e) {
        console.log(`  ✗ Whitelist call reverted: ${e.message}`);
        console.log("  → Whitelist manually after fixing the issue.");
      }
    } else {
      console.log("  → Vault is owned by a different address (governor/timelock).");
      console.log("    Submit a governance proposal to whitelist this zap:");
      console.log(`    target:    ${sFLRVault}`);
      console.log(`    function:  setApprovedZap(address,bool)`);
      console.log(`    args:      ("${zapAddress}", true)`);
    }
  }

  // ── Transfer zap ownership to timelock ───────────────────────────
  console.log("\n── Ownership transfer ───────────────────────────────────");
  console.log("  Transferring zap ownership to CinderTimelock...");
  try {
    const tx = await zap.transferOwnership(timelock);
    await tx.wait();
    console.log(`  ✓ Zap owner → ${timelock} (tx: ${tx.hash})`);
  } catch (e) {
    console.log(`  ✗ Transfer reverted: ${e.message}`);
    console.log("  → You must call zap.transferOwnership(timelock) manually.");
  }

  // ── Summary ──────────────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║                    DEPLOY COMPLETE                       ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");

  console.log("── PASTE INTO .env ────────────────────────────────────────");
  console.log(`ZAP_ADDRESS=${zapAddress}\n`);

  console.log("── FlareScan verification args ────────────────────────────");
  console.log(`  Use these EXACT addresses (in this order) when verifying:`);
  console.log(`    _sceptrePool  ${sceptrePool}`);
  console.log(`    _sFLR         ${sFLR}`);
  console.log(`    _sFLRVault    ${sFLRVault}\n`);

  console.log("── Frontend integration ───────────────────────────────────");
  console.log(`  In app.html, update CONTRACTS[14].zap to:`);
  console.log(`    zap: "${zapAddress}",`);
  console.log("  Then commit and push to GitHub. Netlify auto-rebuilds.\n");

  console.log("── Next steps ─────────────────────────────────────────────");
  console.log("  1. Verify the contract source on FlareScan");
  console.log("  2. If whitelist failed above, submit governance proposal");
  console.log("  3. Test on mainnet with a tiny amount (5-10 FLR)");
  console.log("  4. Update frontend with new zap address");
  console.log("  5. If everything works → tweet launch\n");
}

main()
  .then(() => process.exit(0))
  .catch(e => {
    console.error("\n✗ DEPLOY FAILED:");
    console.error(e);
    process.exit(1);
  });
