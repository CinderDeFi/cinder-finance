const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  const VAULT = "0xE6f960c77F2628A6ABC2Ec5D8994928c8E86A8e4";
  const SFLR  = "0x3c6D1f925e5Eb31CF151F525faFcFF7e356D63E8";

  const vaultABI = [
    "function withdraw(uint256 shares) external returns(uint256)",
    "function balanceOf(address) view returns(uint256)",
    "function totalAssets() view returns(uint256)",
    "function harvest() external"
  ];
  const tokenABI = ["function balanceOf(address) view returns(uint256)"];

  const vault = new ethers.Contract(VAULT, vaultABI, deployer);
  const sflr  = new ethers.Contract(SFLR,  tokenABI, deployer);

  console.log("Before withdraw:");
  console.log("  cFLR shares:", ethers.formatEther(await vault.balanceOf(deployer.address)));
  console.log("  sFLR balance:", ethers.formatEther(await sflr.balanceOf(deployer.address)));

  // Withdraw 50 shares
  console.log("\nWithdrawing 50 cFLR shares...");
  await (await vault.withdraw(ethers.parseEther("50"))).wait();

  console.log("\nAfter withdraw:");
  console.log("  cFLR shares:", ethers.formatEther(await vault.balanceOf(deployer.address)));
  console.log("  sFLR balance:", ethers.formatEther(await sflr.balanceOf(deployer.address)));
  console.log("  Vault TVL:", ethers.formatEther(await vault.totalAssets()));

  // Test harvest
  console.log("\nTesting harvest...");
  await (await vault.harvest()).wait();
  console.log("  Harvest ✓");

  console.log("\n✓ All core functions work!");
}

main().catch(console.error);