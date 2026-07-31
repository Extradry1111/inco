const hre = require("hardhat");

async function main() {
  const megapotVault = process.env.MEGAPOT_VAULT_ADDRESS || "0x0000000000000000000000000000000000000000";

  const CipherMines = await hre.ethers.getContractFactory("CipherMines");
  const contract = await CipherMines.deploy(megapotVault);
  await contract.waitForDeployment();

  console.log("CipherMines deployed to:", await contract.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
