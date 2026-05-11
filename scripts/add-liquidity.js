/**
 * add-liquidity.js — Seed initial EMBER/FLR liquidity on Sparkdex
 *
 * WHAT THIS DOES:
 * ───────────────
 * Adds the first EMBER/FLR liquidity pool on Sparkdex (Flare's main DEX,
 * Uniswap V2 fork). This gives EMBER a price and lets people trade it.
 *
 * YOU NEED:
 * ─────────
 * 1. EMBER tokens in your wallet (from treasury allocation via governance)
 * 2. FLR tokens (for the other side of the pair)
 * 3. Deployed EMBER contract address
 *
 * AMOUNTS TO SEED:
 * ─────────────────
 * We're seeding 1,000,000 EMBER + 100,000 FLR (~$2,000 total at $0.01/FLR)
 * This sets an initial price of: 1 FLR = 10 EMBER
 * (Same as the sale price — consistency matters for launch)
 * At FLR = $0.01: EMBER launch price ≈ $0.001
 *
 * WHY THIS MATTERS:
 * ─────────────────
 * Without liquidity, EMBER can't be traded or priced.
 * DeFiLlama needs a price to calculate treasury value.
 * Mining APR calculations need a EMBER price.
 * People who bought in the sale need somewhere to sell (after vesting).
 */

require("dotenv").config();
const { ethers } = require("ethers");

// ── Config ─────────────────────────────────────────────────────────────
const CFG = {
  rpc:          process.env.RPC_URL        || "https://flare-api.flare.network/ext/C/rpc",
  privateKey:   process.env.PRIVATE_KEY,
  emberAddress: process.env.EMBER_ADDRESS,  // deployed EMBER token
};

// Sparkdex (Flare mainnet) — Uniswap V2 fork
// Addresses from: https://docs.sparkdex.io/contracts
const SPARKDEX = {
  router:  "0x16b619B04c961b8Ce3A0E3FB8572dB3E55b99dB7", // SparkDex Router V2
  factory: "0x6040BB9E4E12B7e8dc5BcEbbE5b76b9E86dBd35E", // SparkDex Factory
  WFLR:    "0x1D80c49BbBCd1C0911346656B529DF9E5c2F783d", // Wrapped FLR
};

// Liquidity amounts — edit these
// ~$2,000 total liquidity at $0.01/FLR · price = 10 EMBER per FLR
// Recalculate FLR_AMOUNT on launch day: ($1,000 ÷ FLR_price) = FLR needed
const EMBER_AMOUNT = ethers.parseEther("1000000"); // 1M EMBER  (~$1,000 at $0.001/EMBER)
const FLR_AMOUNT  = ethers.parseEther("100000");   // 100,000 FLR (~$1,000 at $0.01/FLR)

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

const ROUTER_ABI = [
  "function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline) payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)",
  "function factory() view returns (address)",
];

const FACTORY_ABI = [
  "function getPair(address tokenA, address tokenB) view returns (address pair)",
];

async function main() {
  console.log("╔═══════════════════════════════════════════╗");
  console.log("║   Cinder — Add Initial EMBER Liquidity  ║");
  console.log("╚═══════════════════════════════════════════╝\n");

  if (!CFG.privateKey)  throw new Error("Set PRIVATE_KEY in .env");
  if (!CFG.emberAddress) throw new Error("Set EMBER_ADDRESS in .env");

  const provider = new ethers.JsonRpcProvider(CFG.rpc);
  const wallet   = new ethers.Wallet(CFG.privateKey, provider);
  const ember    = new ethers.Contract(CFG.emberAddress, ERC20_ABI, wallet);
  const router   = new ethers.Contract(SPARKDEX.router, ROUTER_ABI, wallet);
  const factory  = new ethers.Contract(SPARKDEX.factory, FACTORY_ABI, provider);

  // ── Pre-flight checks ──────────────────────────────────────────────
  const emberBal = await ember.balanceOf(wallet.address);
  const flrBal  = await provider.getBalance(wallet.address);

  console.log(`Wallet:       ${wallet.address}`);
  console.log(`EMBER balance: ${ethers.formatEther(emberBal)} EMBER`);
  console.log(`FLR balance:  ${ethers.formatEther(flrBal)} FLR\n`);

  if (emberBal < EMBER_AMOUNT) throw new Error(`Insufficient EMBER: have ${ethers.formatEther(emberBal)}, need ${ethers.formatEther(EMBER_AMOUNT)}`);
  if (flrBal < FLR_AMOUNT + ethers.parseEther("10")) throw new Error("Insufficient FLR (need amount + gas buffer)");

  // Check if pair already exists
  const existingPair = await factory.getPair(CFG.emberAddress, SPARKDEX.WFLR);
  if (existingPair !== ethers.ZeroAddress) {
    console.log(`⚠ Pair already exists at ${existingPair}`);
    console.log("Adding liquidity to existing pair...\n");
  } else {
    console.log("No pair exists — creating EMBER/FLR pool...\n");
  }

  // ── Step 1: Approve router to spend EMBER ──────────────────────────
  console.log("Step 1/2: Approving router to spend EMBER...");
  const currentAllowance = await ember.allowance(wallet.address, SPARKDEX.router);
  if (currentAllowance < EMBER_AMOUNT) {
    const approveTx = await ember.approve(SPARKDEX.router, EMBER_AMOUNT);
    await approveTx.wait();
    console.log("✓ Approved\n");
  } else {
    console.log("✓ Already approved\n");
  }

  // ── Step 2: Add liquidity ─────────────────────────────────────────
  console.log("Step 2/2: Adding liquidity to Sparkdex...");
  console.log(`  ${ethers.formatEther(EMBER_AMOUNT)} EMBER + ${ethers.formatEther(FLR_AMOUNT)} FLR`);
  console.log(`  Implied price: 1 FLR = ${(parseFloat(ethers.formatEther(EMBER_AMOUNT)) / parseFloat(ethers.formatEther(FLR_AMOUNT))).toFixed(2)} EMBER\n`);

  const deadline = Math.floor(Date.now() / 1000) + 30 * 60; // 30 min
  const slippage = 50n; // 0.5% slippage tolerance (50 basis points of 10000)

  const minFlow = EMBER_AMOUNT * (10000n - slippage) / 10000n;
  const minFLR  = FLR_AMOUNT  * (10000n - slippage) / 10000n;

  const tx = await router.addLiquidityETH(
    CFG.emberAddress,
    EMBER_AMOUNT,
    minFlow,
    minFLR,
    wallet.address, // LP tokens go to deployer (should be treasury multisig)
    deadline,
    { value: FLR_AMOUNT }
  );

  console.log(`Tx sent: ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`✓ Liquidity added in block ${receipt.blockNumber}`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
  console.log(`\n🎉 EMBER/FLR pool is live on Sparkdex!`);
  console.log(`   View on Flarescan: https://flarescan.com/tx/${tx.hash}`);
  console.log(`\n⚠ Transfer LP tokens to treasury multisig for governance control.`);
}

main().catch(e => { console.error(e); process.exit(1); });
