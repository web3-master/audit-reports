| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-fee-recipient-shares-cannot-be-decreased-when-total-fee-recipientss-share-is-at-max-limit) | Fee Recipient Shares Cannot Be Decreased When Total Fee recipients’s share is at Max Limit |
| [M-02](#m-02-refund-underflow-in-swap-refund-logic-leading-to-locked-funds) | Refund Underflow in Swap Refund Logic Leading to Locked Funds |
| [M-03](#m-03-rebalancevaultsassets-incorrectly-accounts-vaults-depositedusdc) | rebalanceVaultsAssets incorrectly accounts vaults' depositedUsdc |


# [M-01] Fee Recipient Shares Cannot Be Decreased When Total Fee recipients’s share is at Max Limit
## Summary

When the total fee recipient shares reach the maximum limit, reducing a recipient’s share is blocked due to a validation check. This prevents owners from updating feeBps for existing recipients.

## Vulnerability Details

The `configureFeeRecipient` allows owner to add , remove or update shares of recipient’s . when we calls this function it first validate that the newShare value will not exceeds the max limit of allows  recipients’s shares.

```solidity
/home/aman/Desktop/audits/2025-01-zaros-part-2/src/market-making/branches/MarketMakingEngineConfigurationBranch.sol:613
613:     function configureFeeRecipient(address feeRecipient, uint256 share) external onlyOwner {
614:         // revert if protocolFeeRecipient is set to zero
615:         if (feeRecipient == address(0)) revert Errors.ZeroInput("feeRecipient");
616: 
617:         // load market making engine configuration data from storage
618:         MarketMakingEngineConfiguration.Data storage marketMakingEngineConfiguration =
619:             MarketMakingEngineConfiguration.load();
620: 
621:         // check if share is greater than zero to verify the total will not exceed the maximum shares
622:         if (share > 0) {
623:             UD60x18 totalFeeRecipientsSharesX18 = ud60x18(marketMakingEngineConfiguration.totalFeeRecipientsShares);
624: 
625:             if (
626:                 totalFeeRecipientsSharesX18.add(ud60x18(share)).gt(
627:                     ud60x18(Constants.MAX_CONFIGURABLE_PROTOCOL_FEE_SHARES)
628:                 )
629:             ) {
630:                 revert Errors.FeeRecipientShareExceedsLimit();
631:             }
632:         }
633: 
634:         (, uint256 oldFeeRecipientShares) = marketMakingEngineConfiguration.protocolFeeRecipients.tryGet(feeRecipient);
635: 
636:         // update protocol total fee recipients shares value
637:         if (oldFeeRecipientShares > 0) {
638:             if (oldFeeRecipientShares > share) {
639:                 marketMakingEngineConfiguration.totalFeeRecipientsShares -=
640:                     (oldFeeRecipientShares - share).toUint128();
641:             } else {
642:                 marketMakingEngineConfiguration.totalFeeRecipientsShares +=
643:                     (share - oldFeeRecipientShares).toUint128();
644:             }
645:         } else {
646:             marketMakingEngineConfiguration.totalFeeRecipientsShares += share.toUint128();
647:         }
648: 
649:         // update protocol fee recipient
650:         marketMakingEngineConfiguration.protocolFeeRecipients.set(feeRecipient, share);
651: 
652:         // emit event LogConfigureFeeRecipient
653:         emit LogConfigureFeeRecipient(feeRecipient, share);
654:     }
```

The above code will not work as intended , as in case if the `totalFeeRecipientsSharesX18=MAX_CONFIGURABLE_PROTOCOL_FEE_SHARES` and owner wants to decrease share of specfic recipient’s it will always revert  due to check before removal of shares. The following POC will demonstrates it.

## POC

```solidity
/test/integration/market-making/market-making-engine-configuration-branch/configureFeeRecipient/configureFeeRecipieint.t.sol:39
39:     function test_totalFeeRecipientsShare_is_max_poc() external { // @audit POC
40:         address user1 = address(0x1234);
41:         address user2 = address(0x5678);
42:         marketMakingEngine.configureFeeRecipient(user1, 0.8e18); // set user1 share to 0.8
43:         marketMakingEngine.configureFeeRecipient(user2, 0.1e18); // set user2 share to 0.1
44:         // shares are already at max limit i.e 0.9e18
45:         // will not allow to update user1 share after words
46:         marketMakingEngine.configureFeeRecipient(user1, 0.7e18); // update user1 share to 0.7 
47:     }
```

run the Test with Command : `forge test --mt test_totalFeeRecipientsShare_is_max_poc`

## Impact

Owners cannot reduce a recipient’s feeBps when the total fee recipients’ shares are at the maximum limit.

## Tools Used

Manual Review

## Recommendations

Modify the configureFeeRecipient function to allow fee share reductions even when the total shares are at the max limit. Proposed Fix:

```diff
diff --git a/src/market-making/branches/MarketMakingEngineConfigurationBranch.sol b/src/market-making/branches/MarketMakingEngineConfigurationBranch.sol
index 6fcb388..c374564 100644
--- a/src/market-making/branches/MarketMakingEngineConfigurationBranch.sol
+++ b/src/market-making/branches/MarketMakingEngineConfigurationBranch.sol
@@ -621,17 +621,7 @@ contract MarketMakingEngineConfigurationBranch is OwnableUpgradeable {
 
         // check if share is greater than zero to verify the total will not exceed the maximum shares
         // @audit : what if share is already on 0.9e18 limit , and we want to decrease share of a user how can we do that ?
-        if (share > 0) {
-            UD60x18 totalFeeRecipientsSharesX18 = ud60x18(marketMakingEngineConfiguration.totalFeeRecipientsShares);
-
-            if (
-                totalFeeRecipientsSharesX18.add(ud60x18(share)).gt(
-                    ud60x18(Constants.MAX_CONFIGURABLE_PROTOCOL_FEE_SHARES)
-                )
-            ) {
-                revert Errors.FeeRecipientShareExceedsLimit();
-            }
-        }
+        
 
         (, uint256 oldFeeRecipientShares) = marketMakingEngineConfiguration.protocolFeeRecipients.tryGet(feeRecipient);
 
@@ -649,7 +639,17 @@ contract MarketMakingEngineConfigurationBranch is OwnableUpgradeable {
         } else {
             marketMakingEngineConfiguration.totalFeeRecipientsShares += share.toUint128();
         }
+        if (share > 0) {
+            UD60x18 totalFeeRecipientsSharesX18 = ud60x18(marketMakingEngineConfiguration.totalFeeRecipientsShares);
 
+            if (
+                totalFeeRecipientsSharesX18.gt(
+                    ud60x18(Constants.MAX_CONFIGURABLE_PROTOCOL_FEE_SHARES)
+                )
+            ) {
+                revert Errors.FeeRecipientShareExceedsLimit();
+            }
+        }
         // update protocol fee recipient
         marketMakingEngineConfiguration.protocolFeeRecipients.set(feeRecipient, share);

```

# [M-02] Refund Underflow in Swap Refund Logic Leading to Locked Funds
### Summary and Impact

The vulnerability lies in the refund logic within the `refundSwap` function in the `StabilityBranch.sol` contract. In this function, the code subtracts a configured base fee (`baseFeeUsd`) from the user’s deposited amount (`amountIn`) without verifying that the deposit is at least equal to the fee. When a user creates a swap request with an `amountIn` lower than the `baseFeeUsd`, the subtraction underflows. As Solidity 0.8+ performs automatic overflow/underflow checks, the underflow triggers a revert, leaving the swap request unprocessed and the user’s funds permanently locked in the contract.

**Impact**:

* **User Funds Locked**: Users depositing amounts smaller than the base fee cannot reclaim their funds.
* **Denial of Service**: This issue could be exploited to cause a denial-of-service for low–value swap requests.
* **Protocol Invariants**: The flaw violates the expected invariant that every swap request should eventually be either completed or refunded. Instead, underflow conditions cause the request to remain unresolved.

The flaw is significant because it directly conflicts with the protocol’s expectation that all user deposits are either executed or safely returned. In this case, the refund calculation fails, thereby trapping user funds and undermining confidence in the swap functionality.

***

### Vulnerability Details

* **Description**:\
  In the `refundSwap` function, the contract attempts to calculate the refund by subtracting the base fee from the deposited amount:
  ```solidity
  uint256 refundAmountUsd = depositedUsdToken - baseFeeUsd;
  ```
  If `depositedUsdToken` (i.e. `amountIn`) is less than `baseFeeUsd`, the subtraction underflows, triggering a revert due to Solidity’s built-in overflow/underflow protection. Consequently, the swap request remains unprocessed and the user’s funds are trapped indefinitely.

* **Code Snippet**:



The problematic portion of the code in `StabilityBranch.sol` is as follows:

```solidity
  function refundSwap(uint128 requestId, address engine) external {
      // load swap data
      UsdTokenSwapConfig.Data storage tokenSwapData = UsdTokenSwapConfig.load();

      // load swap request
      UsdTokenSwapConfig.SwapRequest storage request = tokenSwapData.swapRequests[msg.sender][requestId];

      // if request already procesed revert
      if (request.processed) {
          revert Errors.RequestAlreadyProcessed(msg.sender, requestId);
      }

      // if dealine has not yet passed revert
      uint120 deadlineCache = request.deadline;
      if (deadlineCache > block.timestamp) {
          revert Errors.RequestNotExpired(msg.sender, requestId);
      }

      // set precessed to true
      request.processed = true;

      // load Market making engine config
      MarketMakingEngineConfiguration.Data storage marketMakingEngineConfiguration =
          MarketMakingEngineConfiguration.load();

      // get usd token for engine
      address usdToken = marketMakingEngineConfiguration.usdTokenOfEngine[engine];

      // cache the usd token swap base fee
      uint256 baseFeeUsd = tokenSwapData.baseFeeUsd;

      // cache the amount of usd token previously deposited
      uint128 depositedUsdToken = request.amountIn;

      // transfer base fee too protocol fee recipients
      marketMakingEngineConfiguration.distributeProtocolAssetReward(usdToken, baseFeeUsd);

      // cache the amount of usd tokens to be refunded
      uint256 refundAmountUsd = depositedUsdToken - baseFeeUsd;

      // transfer usd refund amount back to user
      IERC20(usdToken).safeTransfer(msg.sender, refundAmountUsd);

      emit LogRefundSwap(
          msg.sender,
          requestId,
          request.vaultId,
          depositedUsdToken,
          request.minAmountOut,
          request.assetOut,
          deadlineCache,
          baseFeeUsd,
          refundAmountUsd
      );
  }
```

* **Test Code Snippet**:\
  Below is an excerpt from the Foundry test case that demonstrates the issue:
  ```solidity
  // Simulate a swap request with amountIn = 50 (less than baseFeeUsd = 100)
  _setSwapRequest(user, TEST_REQUEST_ID, 50);

  // Expect the refundSwap call to revert due to underflow (50 - 100 underflows)
  vm.prank(user);
  vm.expectRevert();
  mockStability.testRefundSwap(TEST_REQUEST_ID, address(0));
  ```
  This test confirms that if a user submits a swap request with an `amountIn` smaller than the required base fee, the refund calculation underflows and reverts, leaving the funds locked.

* **Technical Walkthrough**:
  1. **Swap Request Creation**: A user submits a swap request with a deposit (`amountIn`) that is less than the configured `baseFeeUsd`.
  2. **Refund Attempt**: When the user (or a system keeper) later attempts to execute `refundSwap`, the contract retrieves the `amountIn` from the swap request.
  3. **Underflow Calculation**: The refund is computed as `amountIn - baseFeeUsd`. If `amountIn` (e.g., 50) is less than `baseFeeUsd` (e.g., 100), the arithmetic underflows.
  4. **Reversion**: Solidity’s checked arithmetic causes the transaction to revert, preventing the refund logic from completing and leaving the swap request unprocessed.
  5. **Result**: The user’s funds remain locked in the contract with no mechanism for recovery.

***

### Tools Used

* Manual Review
* Foundry

***

### Recommendations

**Enforce a Minimum Deposit**:\
At the time of swap request creation, add an invariant check to require that `amountIn >= baseFeeUsd`. This would prevent requests with insufficient deposits from being created in the first place.

```solidity
require(amountIn >= tokenSwapData.baseFeeUsd, "Deposit must be >= base fee");
```

***

# [M-03] rebalanceVaultsAssets incorrectly accounts vaults' depositedUsdc
## Summary

`CreditDelegationBranch.rebalanceVaultsAssets` doesn't take DEX swap slippage into consideration when swapping debt vault's collateral asset to credit vault's usdc.

## Vulnerability Details

[`CreditDelegationBranch.rebalanceVaultsAssets`](https://github.com/Cyfrin/2025-01-zaros-part-2/blob/main/src/market-making/branches/CreditDelegationBranch.sol#L646-L682) rebalances credit and debt between two vaults by swapping debt vault's collateral asset to USDC and accumulates this to credit vault's `depositedUsdc` and `marketRealizedDebtUsd`.

```Solidity
uint256 assetInputNative = IDexAdapter(ctx.dexAdapter).getExpectedOutput(
    usdc,
    ctx.inDebtVaultCollateralAsset,
    Collateral.load(usdc).convertSd59x18ToTokenAmount(depositAmountUsdX18)
);

SwapExactInputSinglePayload memory swapCallData = SwapExactInputSinglePayload({
    tokenIn: ctx.inDebtVaultCollateralAsset,
    tokenOut: usdc,
    amountIn: assetInputNative,
    recipient: address(this)
    });

IERC20(ctx.inDebtVaultCollateralAsset).approve(ctx.dexAdapter, assetInputNative);
dexSwapStrategy.executeSwapExactInputSingle(swapCallData); // <-- amountOut

uint128 usdDelta = depositAmountUsdX18.intoUint256().toUint128();

inCreditVault.depositedUsdc += usdDelta; // @audit usdDelta != amountOut
inCreditVault.marketsRealizedDebtUsd += usdDelta.toInt256().toInt128();
inDebtVault.depositedUsdc -= usdDelta;
inDebtVault.marketsRealizedDebtUsd -= usdDelta.toInt256().toInt128();
```

The problem is, this swapping is done via DEX like Curve, Uniswap V2/3 that uses CFMM to decide `amountOut`, while `assetInputNative` is [estimated by price ratio](https://github.com/Cyfrin/2025-01-zaros-part-2/blob/35deb3e92b2a32cd304bf61d27e6071ef36e446d/src/utils/dex-adapters/BaseAdapter.sol#L95-L123).

So `tokenOut` will be different than `usdDelta` by up to [`slippageToleranceBps`%](https://github.com/Cyfrin/2025-01-zaros-part-2/blob/35deb3e92b2a32cd304bf61d27e6071ef36e446d/src/utils/dex-adapters/BaseAdapter.sol#L55)

According to the current implementation, total sum of `marketRealizedDebtUsd`and total `depositedUsdc` remains the same after the rebalancing. Thus, slippage is not accounted anywhere.

## Impact

* The protocol will suffer from DEX swap slippage

## Tools Used

Manual Review

## Recommendations

Consider the following change:

```diff
diff --git a/src/market-making/branches/CreditDelegationBranch.sol b/src/market-making/branches/CreditDelegationBranch.sol
index d091d5c..d948a0d 100644
--- a/src/market-making/branches/CreditDelegationBranch.sol
+++ b/src/market-making/branches/CreditDelegationBranch.sol
@@ -660,7 +660,7 @@ contract CreditDelegationBranch is EngineAccessControl {
 
         // approve the collateral token to the dex adapter and swap assets for USDC
         IERC20(ctx.inDebtVaultCollateralAsset).approve(ctx.dexAdapter, assetInputNative);
-        dexSwapStrategy.executeSwapExactInputSingle(swapCallData);
+        uint128 amountOut = uint128(dexSwapStrategy.executeSwapExactInputSingle(swapCallData));
 
         // SD59x18 -> uint128 using zaros internal precision
         uint128 usdDelta = depositAmountUsdX18.intoUint256().toUint128();
@@ -670,13 +670,13 @@ contract CreditDelegationBranch is EngineAccessControl {
         // 2) code implicitly assumes that 1 USD = 1 USDC
         //
         // deposits the USDC to the in-credit vault
-        inCreditVault.depositedUsdc += usdDelta;
+        inCreditVault.depositedUsdc += amountOut;
         // increase the in-credit vault's share of the markets realized debt
         // as it has received the USDC and needs to settle it in the future
         inCreditVault.marketsRealizedDebtUsd += usdDelta.toInt256().toInt128();
 
         // withdraws the USDC from the in-debt vault
         inDebtVault.depositedUsdc -= usdDelta;
         // decrease the in-debt vault's share of the markets realized debt
         // as it has transferred USDC to the in-credit vault
         inDebtVault.marketsRealizedDebtUsd -= usdDelta.toInt256().toInt128();

```