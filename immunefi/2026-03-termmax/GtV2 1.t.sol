// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {JSONLoader} from "./utils/JSONLoader.sol";
import {StateChecker} from "./utils/StateChecker.sol";
import {SwapUtils} from "./utils/SwapUtils.sol";
import {LoanUtils} from "./utils/LoanUtils.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "contracts/v1/lib/Constants.sol";
import {
    ITermMaxMarketV2, TermMaxMarketV2, Constants, MarketErrors, MarketEvents
} from "contracts/v2/TermMaxMarketV2.sol";
import {MockERC20, ERC20} from "contracts/v1/test/MockERC20.sol";

import {MockPriceFeed} from "contracts/v1/test/MockPriceFeed.sol";
import {IMintableERC20} from "contracts/v1/tokens/MintableERC20.sol";
import {IGearingToken} from "contracts/v1/tokens/IGearingToken.sol";
import {
    GearingTokenWithERC20V2,
    GearingTokenEvents,
    GearingTokenErrors,
    GearingTokenErrorsV2,
    GearingTokenEventsV2,
    GtConfig
} from "contracts/v2/tokens/GearingTokenWithERC20V2.sol";
import {
    ITermMaxFactory,
    TermMaxFactoryV2,
    FactoryErrors,
    FactoryEvents,
    FactoryEventsV2
} from "contracts/v2/factory/TermMaxFactoryV2.sol";
import {IOracleV2, OracleAggregatorV2, AggregatorV3Interface} from "contracts/v2/oracle/OracleAggregatorV2.sol";
import {IOracle} from "contracts/v1/oracle/IOracle.sol";
import {
    VaultInitialParams,
    MarketConfig,
    MarketInitialParams,
    LoanConfig,
    OrderConfig,
    CurveCuts
} from "contracts/v1/storage/TermMaxStorage.sol";
import {MockFlashLoanReceiver} from "contracts/v1/test/MockFlashLoanReceiver.sol";
import {MockFlashRepayerV2} from "contracts/v2/test/MockFlashRepayerV2.sol";
import {ISwapCallback} from "contracts/v1/ISwapCallback.sol";
import {TermMaxOrderV2, OrderInitialParams} from "contracts/v2/TermMaxOrderV2.sol";

contract GtTestV2 is Test {
    using JSONLoader for *;
    using SafeCast for uint256;
    using SafeCast for int256;

    DeployUtils.Res res;

    OrderConfig orderConfig;
    MarketConfig marketConfig;

    address deployer = vm.randomAddress();
    address sender = vm.randomAddress();
    address treasurer = vm.randomAddress();
    address maker = vm.randomAddress();
    string testdata;

    MockFlashLoanReceiver flashLoanReceiver;

    MockFlashRepayerV2 flashRepayer;

    uint32 maxLtv = 0.89e8;
    uint32 liquidationLtv = 0.9e8;
    uint256 collateralCapacity = 5e18;

    function setUp() public {
        vm.startPrank(deployer);
        testdata = vm.readFile(string.concat(vm.projectRoot(), "/test/testdata/testdata.json"));

        marketConfig = JSONLoader.getMarketConfigFromJson(treasurer, testdata, ".marketConfig");
        orderConfig = JSONLoader.getOrderConfigFromJson(testdata, ".orderConfig");
        orderConfig.maxXtReserve = type(uint128).max;
        res = DeployUtils.deployMarket(deployer, marketConfig, maxLtv, liquidationLtv);

        res.order = TermMaxOrderV2(
            address(
                res.market.createOrder(
                    maker, orderConfig.maxXtReserve, ISwapCallback(address(0)), orderConfig.curveCuts
                )
            )
        );

        OrderInitialParams memory orderParams;
        orderParams.maker = maker;
        orderParams.orderConfig = orderConfig;
        uint256 amount = 15000e8;
        orderParams.virtualXtReserve = amount;
        res.order = TermMaxOrderV2(address(res.market.createOrder(orderParams)));

        vm.warp(vm.parseUint(vm.parseJsonString(testdata, ".currentTime")));

        // update oracle
        res.collateralOracle.updateRoundData(JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_2000_DAI_1.eth"));
        res.debtOracle.updateRoundData(JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_2000_DAI_1.dai"));

        res.debt.mint(deployer, amount);
        res.debt.approve(address(res.market), amount);
        res.market.mint(deployer, amount);
        res.ft.transfer(address(res.order), amount);
        res.xt.transfer(address(res.order), amount);

        flashLoanReceiver = new MockFlashLoanReceiver(res.market);
        flashRepayer = new MockFlashRepayerV2(res.gt);

        //
        // Set collateral capacity.
        //
        res.market.updateGtConfig(abi.encode(collateralCapacity));

        vm.stopPrank();
    }

    function testMyTest() public {
        uint128 debtAmt = 100e8;
        uint256 collateralAmt = 1e18;
        uint256 addCollateralAmt = 10e18;
        res.collateral.mint(sender, collateralAmt + addCollateralAmt);

        vm.startPrank(sender);

        res.collateral.approve(address(res.gt), collateralAmt);
        bytes memory collateralData = abi.encode(collateralAmt);

        StateChecker.MarketState memory state = StateChecker.getMarketState(res);

        uint256 issueFee = (debtAmt * res.market.mintGtFeeRatio()) / Constants.DECIMAL_BASE;
        vm.expectEmit();
        emit MarketEvents.IssueFt(
            sender, sender, 1, debtAmt, uint128(debtAmt - issueFee), uint128(issueFee), collateralData
        );

        (uint256 gtId, uint128 ftOutAmt) = res.market.issueFt(sender, debtAmt, collateralData);

        //
        // Add extra collateral into existing GT position.
        //
        res.collateral.approve(address(res.gt), addCollateralAmt);
        bytes memory addCollateralData = abi.encode(addCollateralAmt);
        res.gt.addCollateral(gtId, addCollateralData);

        //
        // GT's total collateral amount is out of range!
        //
        uint gtCollateralBalance = res.collateral.balanceOf(address(res.gt));
        emit log_named_uint("gtCollateralBalance", gtCollateralBalance);
        emit log_named_uint("collateralCapacity", collateralCapacity);

        assert(gtCollateralBalance > collateralCapacity);

        vm.stopPrank();
    }
}
