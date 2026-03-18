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
