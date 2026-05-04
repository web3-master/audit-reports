// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IYelayLiteVault} from "src/interfaces/IYelayLiteVault.sol";
import {SwapArgs} from "src/interfaces/ISwapper.sol";
import {StrategyData} from "src/interfaces/IManagementFacet.sol";
import {Reward} from "src/interfaces/IStrategyBase.sol";
import {GearboxV3Strategy} from "src/strategies/GearboxV3Strategy.sol";
import {LibRoles} from "src/libraries/LibRoles.sol";
import {LibManagement} from "src/libraries/LibManagement.sol";
import {MockExchange, Quote} from "../mocks/MockExchange.sol";
import {Utils} from "../Utils.sol";
import {
    DAI_ADDRESS, MAINNET_BLOCK_NUMBER, GEARBOX_DAI_POOL, GEARBOX_DAI_STAKING, GEARBOX_TOKEN
} from "../Constants.sol";
import {LibErrors} from "src/libraries/LibErrors.sol";

contract CompoundTest is Test {
    using Utils for address;

    address constant owner = address(0x01);
    address constant user = address(0x02);
    address constant QUEUES_OPERATOR = address(0x10);
    address constant FUNDS_OPERATOR = address(0x11);
    address constant yieldExtractor = address(0x04);
    uint256 constant yieldProjectId = 0;
    uint256 constant projectId = 1;

    IYelayLiteVault yelayLiteVault;

    IERC20 underlyingAsset = IERC20(DAI_ADDRESS);

    MockExchange mockExchange;

    function _setupStrategy() internal {
        vm.startPrank(QUEUES_OPERATOR);
        address strategyAdapter = address(new GearboxV3Strategy(GEARBOX_TOKEN));
        StrategyData memory strategy = StrategyData({
            adapter: strategyAdapter,
            name: "gearbox",
            supplement: abi.encode(GEARBOX_DAI_POOL, GEARBOX_DAI_STAKING)
        });

        yelayLiteVault.addStrategy(strategy);
        yelayLiteVault.approveStrategy(0, type(uint256).max);
        {
            uint256[] memory queue = new uint256[](1);
            queue[0] = 0;
            yelayLiteVault.activateStrategy(0, queue, queue);
        }
        vm.stopPrank();
    }

    function setUp() external {
        vm.createSelectFork(vm.envString("MAINNET_URL"), MAINNET_BLOCK_NUMBER);

        vm.startPrank(owner);
        yelayLiteVault =
            Utils.deployDiamond(owner, address(underlyingAsset), yieldExtractor, "https://yelay-lite-vault/{id}.json");
        yelayLiteVault.grantRole(LibRoles.QUEUES_OPERATOR, QUEUES_OPERATOR);
        yelayLiteVault.grantRole(LibRoles.STRATEGY_AUTHORITY, QUEUES_OPERATOR);

        yelayLiteVault.grantRole(LibRoles.FUNDS_OPERATOR, FUNDS_OPERATOR);

        mockExchange = new MockExchange();
        Utils.addExchange(yelayLiteVault, address(mockExchange));
        vm.stopPrank();

        vm.startPrank(user);
        underlyingAsset.approve(address(yelayLiteVault), type(uint256).max);
        vm.stopPrank();

        _setupStrategy();

        //
        // Clear all balance before test.
        //
        address sdToken = 0xC853E4DA38d9Bd1d01675355b8c8f3BBC1451973;
        vm.startPrank(address(yelayLiteVault));
        IERC20(sdToken).transfer(address(0x1), IERC20(sdToken).balanceOf(address(yelayLiteVault)));
        vm.stopPrank();
        assertEq(IERC20(sdToken).balanceOf(address(yelayLiteVault)), 0);

    }

    function test_claim_rewards() external {
        uint256 userBalance = 10_000e18;
        uint256 toDeposit = 1000e18;
        uint256 toShares = 0;
        uint256 rewards = 1e18;
        deal(address(underlyingAsset), user, userBalance);

        vm.startPrank(user);
        toShares = yelayLiteVault.deposit(toDeposit, projectId, user);
        vm.stopPrank();

        //
        // There are some rewards in GearboxV3 strategy.
        //
        deal(address(GEARBOX_TOKEN), address(yelayLiteVault), rewards);
        assertEq(IERC20(GEARBOX_TOKEN).balanceOf(address(yelayLiteVault)), rewards);

        //
        // Queues operator deactivates this strategy.
        // This call fails because there are some asset balance in vault.
        //
        uint256[] memory queue = new uint256[](0);
        vm.startPrank(QUEUES_OPERATOR);
        vm.expectRevert();
        yelayLiteVault.deactivateStrategy(0, queue, queue);
        vm.stopPrank();

        //
        // Withdraw all balances from vault.
        //
        vm.startPrank(user);
        yelayLiteVault.redeem(toShares, projectId, user);
        vm.stopPrank();
        
        //
        // Queues operator deactivates this strategy again.
        // This call succeeds.
        //
        vm.startPrank(QUEUES_OPERATOR);
        yelayLiteVault.deactivateStrategy(0, queue, queue);
        vm.stopPrank();

        //
        // Funds operator wants to claim rewards, but fails.
        //
        vm.startPrank(FUNDS_OPERATOR);
        vm.expectRevert();
        yelayLiteVault.claimStrategyRewards(0);
        vm.stopPrank();
    }

}
