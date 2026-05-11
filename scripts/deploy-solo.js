/**
 * deploy-solo.js — Dual Vault Deploy (sFLR + stXRP)
 * See inline comments for full docs.
 */
const { ethers, network } = require("hardhat");
require("dotenv").config();

const SFLR_MAINNET = "0x12e605bc104e93B45e1aD99F9e555f659051c2BB";

async function main() {
  const [deployer] = await ethers.getSigners();
  const isMainnet  = network.name === "flare";
  console.log(`\nDeploy: ${network.name} | Deployer: ${deployer.address}\n`);
  const d = {};

  // testnet mocks
  let sFLRAddr  = isMainnet ? SFLR_MAINNET : null;
  let stXRPAddr = process.env.STXRP_ADDRESS || null;
  if (!isMainnet) {
    const Mock = await ethers.getContractFactory("MockStXRP");
    const m1 = await (await Mock.deploy("Mock sFLR","sFLR")).waitForDeployment();
    const m2 = await (await Mock.deploy("Mock stXRP","stXRP")).waitForDeployment();
    sFLRAddr  = await m1.getAddress();
    stXRPAddr = await m2.getAddress();
    console.log(`Mock sFLR: ${sFLRAddr}\nMock stXRP: ${stXRPAddr}\n`);
  }

  // 1. CinderFounderVest
  const FV = await ethers.getContractFactory("CinderFounderVest");
  const fv = await (await FV.deploy(deployer.address, deployer.address)).waitForDeployment();
  d.founderVest = await fv.getAddress(); console.log(`CinderFounderVest: ${d.founderVest}`);

  // 2. CinderSale
  const FS = await ethers.getContractFactory("CinderSale");
  const fs = await (await FS.deploy(deployer.address, deployer.address)).waitForDeployment();
  d.sale = await fs.getAddress(); console.log(`CinderSale: ${d.sale}`);

  // 3. CinderToken
  const FT = await ethers.getContractFactory("CinderToken");
  const flow = await (await FT.deploy(
    deployer.address, // mining placeholder — replaced below
    deployer.address, // treasury placeholder
    d.sale,
    deployer.address, // community
    d.founderVest
  )).waitForDeployment();
  d.flow = await flow.getAddress(); console.log(`CinderToken: ${d.flow}`);

  // 4. CinderGovernor
  const Gov = await ethers.getContractFactory("CinderGovernor");
  const gov = await (await Gov.deploy(d.flow, deployer.address)).waitForDeployment();
  d.governor = await gov.getAddress(); console.log(`CinderGovernor: ${d.governor}`);

  // 5. CinderTimelock
  const TL = await ethers.getContractFactory("CinderTimelock");
  const tl = await (await TL.deploy(d.governor, deployer.address)).waitForDeployment();
  d.timelock = await tl.getAddress(); console.log(`CinderTimelock: ${d.timelock}`);
  // Move 250M treasury EMBER to timelock
  await (await flow.transfer(d.timelock, 250_000_000n * 10n**18n)).wait();
  console.log(`  250M EMBER -> timelock ✓`);

  // 6. sFLR vault
  const Vault = await ethers.getContractFactory("CinderVault");
  const sFLRVault = await (await Vault.deploy(sFLRAddr, d.timelock)).waitForDeployment();
  d.sFLRVault = await sFLRVault.getAddress(); console.log(`sFLR Vault (cFLR): ${d.sFLRVault}`);

  // 7. stXRP vault (if address known)
  d.stXRPVault = "PENDING_FIRELIGHT_LAUNCH";
  if (stXRPAddr) {
    const stXRPVault = await (await Vault.deploy(stXRPAddr, d.timelock)).waitForDeployment();
    d.stXRPVault = await stXRPVault.getAddress();
    console.log(`stXRP Vault (cXRP): ${d.stXRPVault}`);
    await (await stXRPVault.transferOwnership(d.governor)).wait();
  }

  // 8. CinderMining v2 with real EMBER + both pools
  const Mining = await ethers.getContractFactory("CinderMining");
  const mining = await (await Mining.deploy(d.flow)).waitForDeployment();
  d.mining = await mining.getAddress(); console.log(`CinderMining v2: ${d.mining}`);
  await (await flow.transfer(d.mining, 450_000_000n * 10n**18n)).wait();
  console.log(`  450M EMBER -> mining ✓`);
  await (await mining.addPool(d.sFLRVault, 6000, "sFLR Vault (Sceptre)")).wait();
  console.log(`  Pool 0: cFLR 60% ✓`);
  if (d.stXRPVault !== "PENDING_FIRELIGHT_LAUNCH") {
    await (await mining.addPool(d.stXRPVault, 4000, "stXRP Vault (Firelight)")).wait();
    console.log(`  Pool 1: cXRP 40% ✓`);
  }

  // 9. Gelato resolver (sFLR vault as primary)
  const Resolver = await ethers.getContractFactory("CinderGelatoResolver");
  const resolver = await (await Resolver.deploy(d.sFLRVault, d.mining)).waitForDeployment();
  d.resolver = await resolver.getAddress(); console.log(`GelatoResolver: ${d.resolver}`);

  // 10. CinderZap — one-click FLR → sFLR → cFLR
  const SCEPTRE_POOL = isMainnet
    ? "0xb53Da25e918F9Df67f8dEDFeC83d7e81F3a0D0d"  // Sceptre mainnet pool
    : deployer.address;                              // testnet placeholder
  console.log("\n10/11 CinderZap (FLR → sFLR → cFLR)...");
  const Zap = await ethers.getContractFactory("CinderZap");
  const zap = await (await Zap.deploy(SCEPTRE_POOL, sFLRAddr, d.sFLRVault)).waitForDeployment();
  d.zap = await zap.getAddress(); console.log(`CinderZap: ${d.zap}`);
  // Whitelist the zap in the vault
  await (await sFLRVault.setApprovedZap(d.zap, true)).wait();
  console.log(`  Zap whitelisted in sFLR vault ✓`);

  // 11. LP Vaults (EMBER/FLR and sFLR/FLR)
  // The LP pair addresses come from Sparkdex factory.getPair()
  // EMBER/FLR pair is created by add-liquidity.js — get the address from Flarescan after running it
  // sFLR/FLR pair may already exist on Sparkdex — check factory.getPair(sFLR, WFLR)
  const SPARKDEX_FACTORY = isMainnet
    ? "0x6040BB9E4E12B7e8dc5BcEbbE5b76b9E86dBd35E"
    : deployer.address; // testnet placeholder
  const SPARKDEX_ROUTER = isMainnet
    ? "0x16b619B04c961b8Ce3A0E3FB8572dB3E55b99dB7"
    : deployer.address;
  const WFLR_ADDR = isMainnet
    ? "0x1D80c49BbBCd1C0911346656B529DF9E5c2F783d"
    : deployer.address;
  const SCEPTRE_POOL = isMainnet
    ? "0xb53Da25e918F9Df67f8dEDFeC83d7e81F3a0D0d"
    : deployer.address;

  // Get LP pair addresses from factory
  // On testnet we use placeholder — deploy add-liquidity.js first to create pairs
  let emberFlrPair  = process.env.EMBER_FLR_PAIR  || deployer.address;
  let sFLRFlrPair  = process.env.SFLR_FLR_PAIR  || deployer.address;

  if (isMainnet && emberFlrPair === deployer.address) {
    console.log("\n⚠ EMBER_FLR_PAIR not set in .env");
    console.log("  Run add-liquidity.js first to create the EMBER/FLR pool");
    console.log("  Then set EMBER_FLR_PAIR in .env and re-run from step 11");
    console.log("  Skipping LP vault deployment for now...\n");
  } else {
    // Deploy EMBER/FLR LP vault
    const LPVault = await ethers.getContractFactory("CinderLPVault");
    const emberFlrVault = await (await LPVault.deploy(emberFlrPair, d.timelock)).waitForDeployment();
    d.emberFlrVault = await emberFlrVault.getAddress();
    console.log(`EMBER/FLR LP Vault (cEMBER-FLR): ${d.emberFlrVault}`);

    // Deploy sFLR/FLR LP vault (if pair exists)
    let sFLRFlrVault;
    if (sFLRFlrPair !== deployer.address) {
      sFLRFlrVault = await (await LPVault.deploy(sFLRFlrPair, d.timelock)).waitForDeployment();
      d.sFLRFlrVault = await sFLRFlrVault.getAddress();
      console.log(`sFLR/FLR LP Vault (csFLR-FLR): ${d.sFLRFlrVault}`);
    } else {
      d.sFLRFlrVault = "DEPLOY_WHEN_SFLR_FLR_PAIR_EXISTS";
      console.log(`sFLR/FLR pair not set — set SFLR_FLR_PAIR in .env to deploy`);
    }

    // Add LP vaults to CinderMining as new pools
    // Rebalance: sFLR 50%, stXRP 30%, EMBER/FLR LP 15%, sFLR/FLR LP 5%
    // (governance can rebalance later via setAlloc)
    // For now add at 0% and let governance set real allocations
    await (await mining.addPool(d.emberFlrVault, 0, "EMBER/FLR LP (Sparkdex)")).wait();
    console.log(`  Pool 2: cEMBER-FLR added (0% — governance sets allocation via FIP)`);

    if (d.sFLRFlrVault !== "DEPLOY_WHEN_SFLR_FLR_PAIR_EXISTS") {
      await (await mining.addPool(d.sFLRFlrVault, 0, "sFLR/FLR LP (Sparkdex)")).wait();
      console.log(`  Pool 3: csFLR-FLR added (0% — governance sets allocation via FIP)`);
    }

    // Deploy LP Zap
    const LPZap = await ethers.getContractFactory("CinderLPZap");
    const lpZap = await (await LPZap.deploy(
      SPARKDEX_ROUTER,
      SPARKDEX_FACTORY,
      WFLR_ADDR,
      d.flow,
      sFLRAddr,
      SCEPTRE_POOL,
      emberFlrPair,
      sFLRFlrPair !== deployer.address ? sFLRFlrPair : ethers.ZeroAddress,
      d.emberFlrVault,
      d.sFLRFlrVault !== "DEPLOY_WHEN_SFLR_FLR_PAIR_EXISTS" ? d.sFLRFlrVault : ethers.ZeroAddress
    )).waitForDeployment();
    d.lpZap = await lpZap.getAddress();
    console.log(`CinderLPZap: ${d.lpZap}`);

    // Whitelist LP zap in both LP vaults
    await (await emberFlrVault.setApprovedZap(d.lpZap, true)).wait();
    console.log(`  LP Zap whitelisted in EMBER/FLR vault ✓`);
    if (sFLRFlrVault) {
      await (await sFLRFlrVault.setApprovedZap(d.lpZap, true)).wait();
      console.log(`  LP Zap whitelisted in sFLR/FLR vault ✓`);
    }

    // Transfer LP vault ownership to governor
    await (await emberFlrVault.transferOwnership(d.governor)).wait();
    if (sFLRFlrVault) await (await sFLRFlrVault.transferOwnership(d.governor)).wait();
    console.log(`  LP vaults -> governor ✓`);
  }

  // 12. Transfer core ownerships
  await (await sFLRVault.transferOwnership(d.governor)).wait();
  await (await mining.transferOwnership(d.governor)).wait();
  await (await resolver.transferOwnership(d.governor)).wait();
  console.log(`\nAll core ownership -> governor ✓`);

  console.log("\n── PASTE INTO .env ──────────────────────────────────");
  console.log(`EMBER_ADDRESS=${d.flow}`);
  console.log(`EMBER_MINING=${d.mining}`);
  console.log(`EMBER_GOVERNOR=${d.governor}`);
  console.log(`EMBER_TIMELOCK=${d.timelock}`);
  console.log(`EMBER_SALE=${d.sale}`);
  console.log(`FOUNDER_VEST=${d.founderVest}`);
  console.log(`GELATO_RESOLVER=${d.resolver}`);
  console.log(`ZAP_ADDRESS=${d.zap}`);
  console.log(`SFLR_VAULT=${d.sFLRVault}`);
  console.log(`STXRP_VAULT=${d.stXRPVault}`);
  console.log(`SFLR_ADDRESS=${sFLRAddr}`);
  console.log(`EMBER_FLR_VAULT=${d.emberFlrVault || "NOT_DEPLOYED"}`);
  console.log(`SFLR_FLR_VAULT=${d.sFLRFlrVault || "NOT_DEPLOYED"}`);
  console.log(`LP_ZAP_ADDRESS=${d.lpZap || "NOT_DEPLOYED"}`);
  console.log(`\n1. Run add-liquidity.js to seed EMBER/FLR pool (get pair address from Flarescan)`);
  console.log(`2. Set EMBER_FLR_PAIR in .env and re-run for LP vault deployment`);
  console.log(`3. Call CinderMining.startMining() on Flarescan`);
  console.log(`4. Register Gelato task: ${d.resolver} checker()`);
  console.log(`5. Call CinderSale.startSale()`);
  console.log(`6. Self-delegate: CinderToken.delegate(yourAddress)`);
  console.log(`7. Submit FIP to set LP pool allocations in CinderMining`);
}

main().catch(e => { console.error(e); process.exit(1); });
