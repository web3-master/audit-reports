// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.28 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ParetoDollar } from "../src/ParetoDollar.sol";
import { ParetoDollarQueue } from "../src/ParetoDollarQueue.sol";
import { ParetoDollarStaking } from "../src/ParetoDollarStaking.sol";
import { IKeyring } from "../src/interfaces/IKeyring.sol";
import { DeployScript } from "../script/Deploy.s.sol";

/// @notice Proof of Concept
///   `claimRedeemRequest` decrements `totReservedWithdrawals` by the full
///   pre-haircut `amount` even when the user was paid the haircut share
///   `_amountLeft = amount * collateral / parSupply` in an undercollateralized
///   epoch. This understates outstanding liabilities so
///   `isParetoDollarCollateralized()` can flip back to `true` prematurely.
///
/// Scenario:
///   - Alice and Bob each request a 1000 USP redemption (total reserved = 2000 USP).
///   - Half the queue collateral is wiped (50% undercollateralized).
///   - Alice claims first and receives a 50% haircut (500 USDC).
///   - The manager replenishes the lost half of the collateral.
///   - Bug: `totReservedWithdrawals` was over-subtracted by 500 USP, so the
///     collateralization check now reports the system as fully collateralized
///     even though Alice was only partially paid.
///   - Bob then claims with no haircut and walks away with the full 1000 USDC,
///     draining the pool. Alice's effective haircut becomes permanent while
///     Bob is made whole — a strict ordering inequity that the buggy
///     accounting both enables and hides from `mint()`/`depositFunds()`.
contract PoCFinding4 is Test, DeployScript {
  using SafeERC20 for IERC20Metadata;

  ParetoDollar par;
  ParetoDollarStaking sPar;
  ParetoDollarQueue queue;

  address internal constant ALICE = address(0xA11CE);
  address internal constant BOB   = address(0xB0B);

  function setUp() public {
    vm.createSelectFork("mainnet", 23_068_980);

    vm.startPrank(DEPLOYER);
    (par, sPar, queue) = _deploy(false);
    vm.stopPrank();

    vm.prank(TL_MULTISIG);
    IKeyring(KEYRING_WHITELIST).setWhitelistStatus(address(queue), true);

    vm.startPrank(par.owner());
    par.addCollateral(USDC, USDC_FEED, 0);
    par.setKeyringParams(address(0), 1);
    vm.stopPrank();

    skip(100);
  }

  function testPoC_overSubtractionOpensMintGateAndShortchangesLateClaimer() external {
    uint256 oneK_usdc = 1_000 * 1e6;
    uint256 oneK_usp  = 1_000 * 1e18;

    _mintUSP(ALICE, oneK_usdc);
    _mintUSP(BOB,   oneK_usdc);

    assertEq(par.totalSupply(), 2 * oneK_usp, "pre: USP supply");
    assertEq(IERC20Metadata(USDC).balanceOf(address(queue)), 2 * oneK_usdc, "pre: queue USDC");

    vm.prank(ALICE); par.requestRedeem(oneK_usp);
    vm.prank(BOB);   par.requestRedeem(oneK_usp);

    assertEq(par.totalSupply(), 0, "post-requestRedeem: USP burned");
    assertEq(queue.totReservedWithdrawals(), 2 * oneK_usp, "post-requestRedeem: reservations");

    // Simulate a 50% loss of unlent collateral (e.g. yield-source default).
    deal(USDC, address(queue), oneK_usdc);

    // Advance epoch so the requests become claimable.
    // stopEpoch() accepts undercollateralized state by resetting epochPending.
    vm.prank(TL_MULTISIG);
    queue.stopEpoch();

    assertFalse(queue.isParetoDollarCollateralized(), "must be undercollateralized");
    assertEq(queue.getTotalCollateralsScaled(), oneK_usp, "collateral scaled");
    // _parSupply = totalSupply (0) + totReservedWithdrawals (2000)
    // -> 50% collateral coverage, expected haircut = 50%.

    // ---- Alice claims first, taking the 50% haircut ----
    uint256 aliceBalPre = IERC20Metadata(USDC).balanceOf(ALICE);
    vm.prank(ALICE);
    par.claimRedeemRequest(1);
    uint256 alicePaid = IERC20Metadata(USDC).balanceOf(ALICE) - aliceBalPre;

    assertEq(alicePaid, 500 * 1e6, "Alice receives the 50% haircut: 500 USDC");

    // === THE BUG ===
    // claimRedeemRequest did:   totReservedWithdrawals -= amount   (= 1000e18, the *request*)
    // It should have done:      totReservedWithdrawals -= _amountLeft (= 500e18, the *payout*)
    uint256 totReservedAfterAlice = queue.totReservedWithdrawals();
    assertEq(totReservedAfterAlice, 1_000 * 1e18, "BUG: over-subtracted by 500 USP");
    // Bob's outstanding obligation is *still* 1000 USP. The book says 1000 USP. Coincidence.
    // The damage manifests when collateral is restored to that 1000-USP figure:

    // ---- Operator tops up the lost collateral (e.g. recovers from a defaulted CV) ----
    deal(USDC, address(queue), 1_000 * 1e6); // +500 USDC, queue now holds 1000 USDC again.

    // Without the bug: parSupply == 1500 USP, collateral == 1000 USDC  -> still undercollateralized,
    //                  Bob would also receive a (now smaller) haircut of 1000 * 1000/1500 = 666.67 USDC.
    // With the bug:    parSupply == 1000 USP, collateral == 1000 USDC  -> "collateralized",
    //                  Bob takes the unhaircut path and walks away with the full 1000 USDC.
    assertTrue(
      queue.isParetoDollarCollateralized(),
      "BUG-INDUCED: system mistakenly reports collateralized"
    );

    // ---- Bob claims and is paid in full at Alice's expense ----
    uint256 bobBalPre = IERC20Metadata(USDC).balanceOf(BOB);
    vm.prank(BOB);
    par.claimRedeemRequest(1);
    uint256 bobPaid = IERC20Metadata(USDC).balanceOf(BOB) - bobBalPre;

    assertEq(bobPaid, 1_000 * 1e6, "BUG: Bob receives 1000 USDC (no haircut)");
    assertGt(bobPaid, alicePaid, "BUG: late claimer is favored over early claimer");

    // Fair outcome would be ~750 USDC each (1500 USDC total / 2 claimants).
    // Actual outcome: Alice 500, Bob 1000.  Alice was shortchanged by 250 USDC,
    // captured by Bob purely as a function of claim ordering.
    console2.log("Alice paid (USDC, 6dp):", alicePaid);
    console2.log("Bob   paid (USDC, 6dp):", bobPaid);
    console2.log("Shortfall vs. fair share for Alice (USDC, 6dp):", 750 * 1e6 - alicePaid);
  }

  // -- helpers -----------------------------------------------------------

  function _mintUSP(address _user, uint256 _usdcAmount) internal {
    deal(USDC, _user, _usdcAmount);
    vm.startPrank(_user);
    IERC20Metadata(USDC).safeIncreaseAllowance(address(par), _usdcAmount);
    par.mint(USDC, _usdcAmount);
    vm.stopPrank();
  }
}
