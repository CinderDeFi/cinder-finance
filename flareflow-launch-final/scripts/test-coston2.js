const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Testing with:", deployer.address);

  const SFLR  = "0x3c6D1f925e5Eb31CF151F525faFcFF7e356D63E8";
  const VAULT = "0xE6f960c77F2628A6ABC2Ec5D8994928c8E86A8e4";

  const mockABI = ["function mint(address,uint256) external",
                   "function approve(address,uint256) external returns(bool)",
                   "function balanceOf(address) view returns(uint256)"];
  const vaultABI = ["function deposit(uint256) external returns(uint256)",
                    "function balanceOf(address) view returns(uint256)",
                    "function totalAssets() view returns(uint256)"];

  const sflr  = new ethers.Contract(SFLR,  mockABI,  deployer);
  const vault = new ethers.Contract(VAULT, vaultABI, deployer);

  // Mint 1000 mock sFLR
  console.log("Minting 1000 sFLR...");
  await (await sflr.mint(deployer.address, ethers.parseEther("1000"))).wait();
  console.log("sFLR balance:", ethers.formatEther(await sflr.balanceOf(deployer.address)));

  // Approve vault
  console.log("Approving vault...");
  await (await sflr.approve(VAULT, ethers.parseEther("100"))).wait();

  // Deposit 100 sFLR
  console.log("Depositing 100 sFLR...");
  await (await vault.deposit(ethers.parseEther("100"))).wait();

  console.log("cFLR shares:", ethers.formatEther(await vault.balanceOf(deployer.address)));
  console.log("Vault TVL:  ", ethers.formatEther(await vault.totalAssets()));
  console.log("\n✓ Deposit works!");
}

main().catch(console.error);