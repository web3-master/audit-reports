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

import {ITermMaxMarket, ITermMaxMarketV2, TermMaxMarketV2} from "contracts/v2/TermMaxMarketV2.sol";
import {ITermMaxOrder, ISwapCallback, TermMaxOrderV2} from "contracts/v2/TermMaxOrderV2.sol";
import {MockERC20, ERC20} from "contracts/v1/test/MockERC20.sol";
import {MockERC20Blacklist} from "contracts/v1/test/MockERC20Blacklist.sol";
import {MockPriceFeed} from "contracts/v1/test/MockPriceFeed.sol";
import {IMintableERC20} from "contracts/v1/tokens/IMintableERC20.sol";
import {IMintableERC20V2, MintableERC20V2} from "contracts/v2/tokens/MintableERC20V2.sol";
import {IGearingToken} from "contracts/v1/tokens/IGearingToken.sol";
import {ITermMaxFactory, TermMaxFactoryV2} from "contracts/v2/factory/TermMaxFactoryV2.sol";
import {TermMaxRouterV2} from "contracts/v2/router/TermMaxRouterV2.sol";
import {IOracleV2, OracleAggregatorV2, AggregatorV3Interface} from "contracts/v2/oracle/OracleAggregatorV2.sol";
import {IOracle} from "contracts/v1/oracle/IOracle.sol";
import {MockOrderV2} from "contracts/v2/test/MockOrderV2.sol";
import {VaultFactory, IVaultFactory} from "contracts/v1/factory/VaultFactory.sol";
import {OrderManagerV2} from "contracts/v2/vault/OrderManagerV2.sol";
import {TermMaxVaultV2} from "contracts/v2/vault/TermMaxVaultV2.sol";
import {AccessManager} from "contracts/v2/access/AccessManagerV2.sol";
import {
    VaultInitialParams,
    MarketConfig,
    MarketInitialParams,
    LoanConfig,
    OrderConfig,
    CurveCut,
    CurveCuts
} from "contracts/v1/storage/TermMaxStorage.sol";
import {VaultInitialParamsV2} from "contracts/v2/storage/TermMaxStorageV2.sol";
import {TermMaxVaultFactoryV2} from "contracts/v2/factory/TermMaxVaultFactoryV2.sol";
import {MockAave} from "contracts/v2/test/MockAave.sol";
import {WhitelistManager, IWhitelistManager} from "contracts/v2/access/WhitelistManager.sol";

contract GtTestV2 is Test {
    using JSONLoader for *;
    using SafeCast for uint256;
    using SafeCast for int256;


    struct Res {
        TermMaxVaultV2 vault;
        IVaultFactory vaultFactory;
        TermMaxFactoryV2 factory;
        TermMaxOrderV2 order;
        TermMaxRouterV2 router;
        MarketConfig marketConfig;
        OrderConfig orderConfig;
        TermMaxMarketV2 market;
        IMintableERC20 ft;
        IMintableERC20 xt;
        IGearingToken gt;
        MockPriceFeed debtOracle;
        MockPriceFeed collateralOracle;
        OracleAggregatorV2 oracle;
        MockERC20Blacklist collateral;
        MockERC20 debt;
    }

    Res res;

    OrderConfig orderConfig;
    MarketConfig marketConfig;

    address deployer = vm.randomAddress();
    address sender = vm.randomAddress();
    address treasurer = vm.randomAddress();
    address maker = vm.randomAddress();
    address blacklisted = vm.randomAddress();
    string testdata;

    MockFlashLoanReceiver flashLoanReceiver;

    MockFlashRepayerV2 flashRepayer;

    uint32 maxLtv = 0.89e8;
    uint32 liquidationLtv = 0.9e8;
    
    bytes32 constant GT_ERC20 = keccak256("GearingTokenWithERC20");

    function deployFactory(address admin) public returns (TermMaxFactoryV2 factory) {
        address tokenImplementation = address(new MintableERC20V2());
        address orderImplementation = address(new TermMaxOrderV2());
        TermMaxMarketV2 m = new TermMaxMarketV2(tokenImplementation, orderImplementation);
        factory = new TermMaxFactoryV2(admin, address(m));
    }

    function deployFactoryWithMockOrder(address admin) public returns (TermMaxFactoryV2 factory) {
        address tokenImplementation = address(new MintableERC20V2());
        address orderImplementation = address(new MockOrderV2());
        TermMaxMarketV2 m = new TermMaxMarketV2(tokenImplementation, orderImplementation);
        factory = new TermMaxFactoryV2(admin, address(m));
    }

    function deployOracle(address admin, uint256 timeLock) public returns (OracleAggregatorV2 oracle) {
        oracle = new OracleAggregatorV2(admin, timeLock);
    }

    function deployMarket(address admin, MarketConfig memory marketConfig, uint32 maxLtv, uint32 liquidationLtv)
        internal
        returns (Res memory res)
    {
        res.factory = deployFactory(admin);

        res.collateral = new MockERC20Blacklist("sUSDe", "sUSDe", 18, blacklisted);
        res.debt = new MockERC20("DAI", "DAI", 8);

        res.debtOracle = new MockPriceFeed(admin);
        res.collateralOracle = new MockPriceFeed(admin);
        res.oracle = deployOracle(admin, 0);

        res.oracle.submitPendingOracle(
            address(res.debt), IOracleV2.Oracle(res.debtOracle, res.debtOracle, 0, 0, 365 days, 0)
        );
        res.oracle.submitPendingOracle(
            address(res.collateral), IOracleV2.Oracle(res.collateralOracle, res.collateralOracle, 0, 0, 365 days, 0)
        );

        res.oracle.acceptPendingOracle(address(res.debt));
        res.oracle.acceptPendingOracle(address(res.collateral));

        MockPriceFeed.RoundData memory roundData = MockPriceFeed.RoundData({
            roundId: 1,
            answer: int256(1e1 ** res.collateralOracle.decimals()),
            startedAt: 0,
            updatedAt: 0,
            answeredInRound: 0
        });
        res.collateralOracle.updateRoundData(roundData);

        MarketInitialParams memory initialParams = MarketInitialParams({
            collateral: address(res.collateral),
            debtToken: res.debt,
            admin: admin,
            gtImplementation: address(0),
            marketConfig: marketConfig,
            loanConfig: LoanConfig({
                oracle: IOracle(address(res.oracle)),
                liquidationLtv: liquidationLtv,
                maxLtv: maxLtv,
                liquidatable: true
            }),
            gtInitalParams: abi.encode(type(uint256).max),
            tokenName: "DAI-ETH",
            tokenSymbol: "DAI-ETH"
        });

        res.marketConfig = marketConfig;
        res.market = TermMaxMarketV2(res.factory.createMarket(GT_ERC20, initialParams, 0));

        (res.ft, res.xt, res.gt,,) = res.market.tokens();
    }

    function setUp() public {
        vm.startPrank(deployer);
        testdata = vm.readFile(string.concat(vm.projectRoot(), "/test/testdata/testdata.json"));

        marketConfig = JSONLoader.getMarketConfigFromJson(treasurer, testdata, ".marketConfig");
        orderConfig = JSONLoader.getOrderConfigFromJson(testdata, ".orderConfig");
        orderConfig.maxXtReserve = type(uint128).max;
        res = deployMarket(deployer, marketConfig, maxLtv, liquidationLtv);

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

        vm.stopPrank();
    }

    // Can't liquidate because of blacklisting.
    function testLiquidateBlacklist() public {
        uint128 debtAmt = 1000e8;
        uint256 collateralAmt = 1e18;

        vm.startPrank(sender);

        res.collateral.mint(sender, collateralAmt);
        res.collateral.approve(address(res.gt), collateralAmt);
        bytes memory collateralData = abi.encode(collateralAmt);

        //
        // @audit: This loan's owner is 'blacklisted' address of 'sUSDe' token.
        //
        (uint gtId,) = res.market.issueFt(blacklisted, debtAmt, collateralData);

        vm.stopPrank();
        vm.startPrank(deployer);
        // update oracle
        MockPriceFeed.RoundData memory priceData = JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_1000_DAI_1.eth");
        priceData.answer = 110500000000;    // @audit: In this case, ltv will be 90+%.
        res.collateralOracle.updateRoundData(priceData);
        res.debtOracle.updateRoundData(JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_1000_DAI_1.dai"));
        vm.stopPrank();

        address liquidator = vm.randomAddress();
        vm.startPrank(liquidator);

        res.debt.mint(liquidator, debtAmt);
        res.debt.approve(address(res.gt), debtAmt);

        (bool isLiquidable, uint128 ltv, uint128 maxRepayAmt) = res.gt.getLiquidationInfo(gtId);
        assert(ltv > 90_000_000);
        emit log_named_uint("ltv", ltv);

        //
        // @audit: Trying to liquidate total debt but it fails because remaining collateral can't be sent back to loan owner.
        //
        vm.expectRevert();
        res.gt.liquidate(gtId, debtAmt, true);

        vm.stopPrank();
    }

}
