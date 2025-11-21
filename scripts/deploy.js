const hre = require('hardhat');
require('dotenv').config();

async function main() {
  await hre.run('compile');

  const [deployer] = await hre.ethers.getSigners();
  console.log('Deploying with:', deployer.address);

  let usdcAddress = process.env.USDC_ADDRESS || '';

  if (!usdcAddress) {
    console.log('No USDC address provided — deploying MockERC20 as mUSDC...');
    const Mock = await hre.ethers.getContractFactory('MockERC20');
    const mock = await Mock.deploy('Mock USDC', 'mUSDC');
    await mock.deployed();
    console.log('MockERC20 deployed at', mock.address);
    // mint some tokens to deployer for testing
    const mintAmount = hre.ethers.parseUnits ? hre.ethers.parseUnits('10000', 6) : hre.ethers.utils.parseUnits('10000', 6);
    await mock.mint(deployer.address, mintAmount);
    usdcAddress = mock.address;
  } else {
    console.log('Using USDC address from .env:', usdcAddress);
  }

  // Deploy DePinVPN
  const Factory = await hre.ethers.getContractFactory('DePinVPN');
  const contract = await Factory.deploy(usdcAddress);
  await contract.deployed();

  console.log('DePinVPN deployed to:', contract.address);
  console.log('USDC used:', usdcAddress);

  console.log('\nTo verify on Etherscan (optional):');
  console.log('npx hardhat verify --network sepolia', contract.address, usdcAddress);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
