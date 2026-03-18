## Title
Management fee undercalculated due to incorrect share-supply accounting

## Brief/Intro
A logic discrepancy in ManagementFee.settle() causes management fees to be computed using a reduced "net supply" value (total supply minus the VaultProxy's own balance) instead of the vault's total share supply. Because IntegrationManager and ExternalPositionManager operations transfer and/or approve underlying assets without adjusting share accounting, asset managers can be denied legitimately accrued fees when the vault's balanceOf(vaultProxy) is non-zero. This leads to managers receiving smaller (or zero) management fees despite performing fund activity that generates value.

Affected contract(s)

ManagementFee.sol (fee calculation)
IntegrationManager.sol / ExternalPositionManager.sol (interaction pattern that leads to vault-held shares or asset movement without corresponding fee accounting)

## Vulnerability Details
ManagementFee.settle() excludes shares held by the vault (balanceOf(vaultProxy)) from the base used to compute management fees. 
Integration and external position workflows do not mirror this exclusion (they operate on assets without adjusting share accounting). 
The mismatch between how fees are computed and how assets/spendable balances are managed results in underpayment.

Let's see more detail.
The management fee is calculated in ManagementFee.settle() function.
```solidity
File: ManagementFee.sol
079:     function settle(address _comptrollerProxy, address _vaultProxy, IFeeManager.FeeHook, bytes calldata, uint256)
080:         external
081:         override
082:         onlyFeeManager
083:         returns (IFeeManager.SettlementType settlementType_, address, uint256 sharesDue_)
084:     {
085:         FeeInfo storage feeInfo = comptrollerProxyToFeeInfo[_comptrollerProxy];
...
093:         // If there are shares issued for the fund, calculate the shares due
094:         IERC20 sharesToken = IERC20(_vaultProxy);
095:         uint256 sharesSupply = sharesToken.totalSupply();
096:         if (sharesSupply > 0) {
097:             // This assumes that all shares in the VaultProxy are shares outstanding,
098:             // which is fine for this release. Even if they are not, they are still shares that
099:             // are only claimable by the fund owner.
100:             uint256 netSharesSupply = sharesSupply.sub(sharesToken.balanceOf(_vaultProxy));
101:             if (netSharesSupply > 0) {
102:                 sharesDue_ = netSharesSupply.mul(                                                      // @audit: This is the management fee calculation!
103:                         __rpow(feeInfo.scaledPerSecondRate, secondsSinceSettlement, RATE_SCALE_BASE)
104:                             .sub(RATE_SCALE_BASE)
105:                     ).div(RATE_SCALE_BASE);
106:             }
107:         }
...
119:         return (IFeeManager.SettlementType.Mint, address(0), sharesDue_);
120:     }
```
In L102~L105, the fee is calculated for total supply share - vaultProxy's balance share.
This calculation's meaning equals to vaultProxy's share amount of assets(`sharesToken.balanceOf(_vaultProxy)`) in fund is not accounted for management fee calculation.

However, there's no such accounting logic in IntegrationManager and ExternalPositionManager.
Let's see the scenario when asset manager calls IntegrationManager to interact with an adapter.
Call stack is as follows.
ComptrollerLib.callOnExtension()
->IntegrationManager.receiveCallFromComptroller()
  ->IntegrationManager.__callOnIntegration()
    ->IntegrationManager.__callOnIntegrationInner()
      ->IntegrationManager.__preProcessCoI()
        ->IntegrationManager.__withdrawAssetTo()        : L347


IntegrationManager.__withdrawAssetTo() function is as follows:
```solidity
File: IntegrationManager.sol
290:     /// @dev Helper for the internal actions to take prior to executing CoI
291:     function __preProcessCoI(
292:         address _comptrollerProxy,
293:         address _vaultProxy,
294:         address _adapter,
295:         bytes4 _selector,
296:         bytes memory _integrationData
297:     )
298:         private
299:         returns (
300:             address[] memory incomingAssets_,
301:             uint256[] memory preCallIncomingAssetBalances_,
302:             uint256[] memory minIncomingAssetAmounts_,
303:             SpendAssetsHandleType spendAssetsHandleType_,
304:             address[] memory spendAssets_,
305:             uint256[] memory maxSpendAssetAmounts_,
306:             uint256[] memory preCallSpendAssetBalances_
307:         )
308:     {
...
335:         // SPEND ASSETS
336: 
337:         preCallSpendAssetBalances_ = new uint256[](spendAssets_.length);
338:         for (uint256 i; i < spendAssets_.length; i++) {
339:             preCallSpendAssetBalances_[i] = ERC20(spendAssets_[i]).balanceOf(_vaultProxy);
340: 
341:             // Grant adapter access to the spend assets.
342:             // spendAssets_ is already asserted to be a unique set.
343:             if (spendAssetsHandleType_ == SpendAssetsHandleType.Approve) {
344:                 // Use exact approve amount, and reset afterwards
345:                 __approveAssetSpender(_comptrollerProxy, spendAssets_[i], _adapter, maxSpendAssetAmounts_[i]);
346:             } else if (spendAssetsHandleType_ == SpendAssetsHandleType.Transfer) {
347:                 __withdrawAssetTo(_comptrollerProxy, spendAssets_[i], _adapter, maxSpendAssetAmounts_[i]);
348:             }
349:         }
350:     }
```
Real asset transfer is done in L345 or L347.
And transfer amount's upper limit is maxSpendAssetAmounts_[i].
The point is that there is no accounting for the ratio of vaultProxy's share balance in here.
In other words, asset manager can use vaultProxy's total supply's asset amount for his work.
This is discrepency to the management fee calculation's accounting logic.

For example, let's imagine that total supply is just for vault proxy's share.
In that case, asset manager doesn't receive any fee even though he makes some profit by rebalancing fund's underlying asset into adapters or external positions.
This is unfair.

## Impact Details
* Asset managers are undercompensated for legitimate management activity (potentially zero fees).
* Economic misalignment between documented behavior and on-chain execution.
* Possible disputes between funds and managers; degraded incentives for active management.

## Suggested fixes (recommended)
Compute management fees from the vault's total supply (totalSupply()) rather than netSupply = totalSupply() - balanceOf(vaultProxy).
Replace the netSharesSupply usage with the full sharesSupply in ManagementFee.settle():

```solidity
File: ManagementFee.sol
079:     function settle(address _comptrollerProxy, address _vaultProxy, IFeeManager.FeeHook, bytes calldata, uint256)
080:         external
081:         override
082:         onlyFeeManager
083:         returns (IFeeManager.SettlementType settlementType_, address, uint256 sharesDue_)
084:     {
085:         FeeInfo storage feeInfo = comptrollerProxyToFeeInfo[_comptrollerProxy];
...
093:         // If there are shares issued for the fund, calculate the shares due
094:         IERC20 sharesToken = IERC20(_vaultProxy);
095:         uint256 sharesSupply = sharesToken.totalSupply();
096:         if (sharesSupply > 0) {
102:                 sharesDue_ = sharesSupply.mul(                                                      
103:                         __rpow(feeInfo.scaledPerSecondRate, secondsSinceSettlement, RATE_SCALE_BASE)
104:                             .sub(RATE_SCALE_BASE)
105:                     ).div(RATE_SCALE_BASE);
107:         }
...
119:         return (IFeeManager.SettlementType.Mint, address(0), sharesDue_);
120:     }
```

Rationale: Fees should be proportional to the entire outstanding share base to reflect manager activity that benefits the fund as a whole; excluding vault-held shares causes legitimate feeable gains to be omitted.


## References
https://github.com/enzymefinance/protocol/blob/e9571845d8f175233dc58dbec431fa418ef675ca/contracts/release/extensions/fee-manager/fees/ManagementFee.sol#L102

## Proof of Concept
This is unit test code.
```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {AddOnUtilsBase} from "tests/utils/bases/AddOnUtilsBase.sol";
import {IERC20} from "tests/interfaces/external/IERC20.sol";
import {IComptrollerLib} from "tests/interfaces/internal/IComptrollerLib.sol";
import {IFundDeployer} from "tests/interfaces/internal/IFundDeployer.sol";
import {IManagementFee} from "tests/interfaces/internal/IManagementFee.sol";
import {IFeeManager} from "tests/interfaces/internal/IFeeManager.sol";
import {IVaultLib} from "tests/interfaces/internal/IVaultLib.sol";

abstract contract ManagementFeeUtils is AddOnUtilsBase {
    function deployManagementFee(IFeeManager _feeManager) internal returns (IManagementFee managementFee_) {
        return IManagementFee(deployCode("ManagementFee.sol", abi.encode(address(_feeManager))));
    }
}

contract ManagementFeeTest is IntegrationTest, ManagementFeeUtils {
    IManagementFee internal managementFee;

    function setUp() public override {
        super.setUp();

        managementFee = deployManagementFee(core.release.feeManager);
    }

    function testUnderCalculatedFeeWhenVaultHoldsShares() public {
        address feeRecipient = makeAddr("FeeRecipient");
        address sharesBuyer = makeAddr("SharesBuyer");

        IERC20 denominationAsset = nonStandardPrimitive;

        uint256 feeRate = 1_000_000_005_779_593_367_070_211_330; // f = (1 + 0.2) ^ (1 / (3600 * 24 * 365)) * 1e27. (APY: 20%, Scaled 1e27.)

        address[] memory fees = new address[](1);
        fees[0] = address(managementFee);

        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encode(feeRate, feeRecipient);

        bytes memory feeManagerConfigData = abi.encode(fees, settings);

        //
        // Case A: vault holds ZERO of its own shares
        //
        uint256 sharesDueA = getCaseA(sharesBuyer, denominationAsset, feeManagerConfigData);

        //
        // Case B: Vault holds ALL shares
        //
        uint256 sharesDueB = getCaseB(sharesBuyer, denominationAsset, feeManagerConfigData);

        // The vulnerability causes sharesDueB <= sharesDueA, typically sharesDueB == 0 when vault holds all supply.
        // Assert sharesDueB is strictly less than sharesDueA to demonstrate undercalculation.
        assertTrue(sharesDueB < sharesDueA, "Management fee not reduced when vault holds shares (expected reduction)");
    }

    function getCaseA(address sharesBuyer, IERC20 denominationAsset, bytes memory feeManagerConfigData) private returns (uint256) {
        uint8 denominationAssetDecimals = denominationAsset.decimals();
        uint256 denominationAssetUnit = 10 ** denominationAssetDecimals;

        //
        // Case A: vault holds ZERO of its own shares
        //
        (IComptrollerLib comptrollerProxyA, IVaultLib vaultProxyA,) = createFund({
            _fundDeployer: core.release.fundDeployer,
            _denominationAsset: denominationAsset,
            _sharesActionTimelock: 0,
            _feeManagerConfigData: feeManagerConfigData,
            _policyManagerConfigData: ""
        });
        IERC20 sharesTokenA = IERC20(address(vaultProxyA));

        // buy shares
        uint256 depositAmount = denominationAssetUnit * 5;
        buyShares({_sharesBuyer: sharesBuyer, _comptrollerProxy: comptrollerProxyA, _amountToDeposit: depositAmount});

        uint256 depositorInitialSharesBal = sharesTokenA.balanceOf(sharesBuyer);
        emit log_named_uint("depositorInitialSharesBal", depositorInitialSharesBal);

        skip(12);

        uint256 vaultOwnShares = sharesTokenA.balanceOf(address(sharesTokenA));
        emit log_named_uint("vaultOwnShares A", vaultOwnShares);

        vm.prank(address(core.release.feeManager));
        (, , uint256 sharesDueA) = managementFee.settle(
            address(comptrollerProxyA),
            address(vaultProxyA),
            IFeeManager.FeeHook.wrap(uint8(0)),
            "",
            block.timestamp
        );
        emit log_named_uint("sharesDueA", sharesDueA);

        return sharesDueA;
    }

    function getCaseB(address sharesBuyer, IERC20 denominationAsset, bytes memory feeManagerConfigData) private returns (uint256) {
        uint8 denominationAssetDecimals = denominationAsset.decimals();
        uint256 denominationAssetUnit = 10 ** denominationAssetDecimals;

        //
        // Case B: Vault holds ALL shares
        //
        (IComptrollerLib comptrollerProxyB, IVaultLib vaultProxyB,) = createFund({
            _fundDeployer: core.release.fundDeployer,
            _denominationAsset: denominationAsset,
            _sharesActionTimelock: 0,
            _feeManagerConfigData: feeManagerConfigData,
            _policyManagerConfigData: ""
        });
        IERC20 sharesTokenB = IERC20(address(vaultProxyB));

        // buy shares
        uint256 depositAmount = denominationAssetUnit * 5;
        buyShares({_sharesBuyer: sharesBuyer, _comptrollerProxy: comptrollerProxyB, _amountToDeposit: depositAmount});

        uint256 depositorInitialSharesBal = sharesTokenB.balanceOf(sharesBuyer);
        emit log_named_uint("depositorInitialSharesBal", depositorInitialSharesBal);

        skip(12);

        vm.prank(sharesBuyer);
        sharesTokenB.transfer(address(sharesTokenB), depositorInitialSharesBal);
        uint256 vaultOwnShares = sharesTokenB.balanceOf(address(sharesTokenB));
        emit log_named_uint("vaultOwnShares B", vaultOwnShares);

        vm.prank(address(core.release.feeManager));
        (, , uint256 sharesDueB) = managementFee.settle(
            address(comptrollerProxyB),
            address(vaultProxyB),
            IFeeManager.FeeHook.wrap(uint8(0)),
            "",
            block.timestamp
        );
        emit log_named_uint("sharesDueB", sharesDueB);

        return sharesDueB;
    }
}
```

To run this test code, please run
```shell
forge test --match-test testUnderCalculatedFeeWhenVaultHoldsShares
```