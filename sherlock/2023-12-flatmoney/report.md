| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-attacker-can-sell-a-position-which-is-pending-to-close) | Attacker can sell a position which is pending to close. |
| [H-02](#h-02-flatcoinvaultsolcheckskewmax-function-is-called-with-error) | FlatcoinVault.sol#checkSkewMax function is called with error. |



# [H-01] Attacker can sell a position which is pending to close.

## Summary
DelayedOrder.sol#announceLeverageClose function lock the position to close.
But an attacker can unlock the locked position by calling LimitOrder.sol#cancelLimitOrder function.
Thus attacker can sell a position which is pending to close.

## Vulnerability Detail
DelayedOrder.sol#announceLeverageClose function is the following.
```solidity
    function announceLeverageClose(uint256 tokenId, uint256 minFillPrice, uint256 keeperFee) external whenNotPaused {
        ......
        // Lock the NFT belonging to this position so that it can't be transferred to someone else.
        // Locking doesn't require an approval from the leverage trader.
        leverageModule.lock(tokenId);
        ......
    }
```
From comment, we can see that the token which is pending to close should not be transferred to someone else.
```solidity
On the other hand, LimitOrder.sol#cancelLimitOrder function is the following.

    function cancelLimitOrder(uint256 tokenId) external {
        ......
        // Unlock the ERC721 position NFT to allow for transfers.
        ILeverageModule(vault.moduleAddress(FlatcoinModuleKeys._LEVERAGE_MODULE_KEY)).unlock(tokenId);
        ......
    }
```
So an attacker can unlock the position which is pending to close and sell it to someone else.

Example:

Suppose that user1(attacker) owns tokenId1 position.
Attacker set tokenId1 as pending to LimitClose by calling LimitOrder.sol#announceLimitOrder function.
Next attacker set tokenId1 as pending to LeverageClose by calling DelayedOrder.sol#announceLeverageClose function.
Next attacker unlock tokenId1 by calling LimitOrder.sol#cancelLimitOrder function.
Next attacker sell tokenId1 to user2.
After a short time, the pending order with LeverageClose type is executed by keeper and the margin of the position are sent to user1(attacker).

## Impact
Attacker can sell a position which is pending to close.
Thus the buyer of the position will lose fund deposited to buy the position.

## Code Snippet
https://github.com/sherlock-audit/2023-12-flatmoney/blob/main/flatcoin-v1/src/LimitOrder.sol#L94

## Tool used
Manual Review

## Recommendation
We recommend that check if the position is already locked when locking a position.



# [H-02] FlatcoinVault.sol#checkSkewMax function is called with error.

## Summary
FlatcoinVault.sol#checkSkewMax function is called with wrong parameter in the DelayedOrder.sol#announceStableWithdraw function.
So FlatcoinVault.sol#checkSkewMax will be malfunctioned.

## Vulnerability Detail
FlatcoinVault.sol#checkSkewMax function is the following.
```solidity
294:/// @notice Asserts that the system will not be too skewed towards longs after additional skew is added (position change).
295:/// @param _additionalSkew The additional skew added by either opening a long or closing an LP position.
    function checkSkewMax(uint256 _additionalSkew) public view {
        // check that skew is not essentially disabled
        if (skewFractionMax < type(uint256).max) {
            uint256 sizeOpenedTotal = _globalPositions.sizeOpenedTotal;

            if (stableCollateralTotal == 0) revert FlatcoinErrors.ZeroValue("stableCollateralTotal");

303:        uint256 longSkewFraction = ((sizeOpenedTotal + _additionalSkew) * 1e18) / stableCollateralTotal;

            if (longSkewFraction > skewFractionMax) revert FlatcoinErrors.MaxSkewReached(longSkewFraction);
        }
    }
```

From L295 and L303, we can see that _additionalSkew should be the amount of collateral to be added into long positions inside the pool.
On the other hand, DelayedOrder.sol#announceStableWithdraw function is the following.
```solidity
    function announceStableWithdraw(
        uint256 withdrawAmount,
        uint256 minAmountOut,
        uint256 keeperFee
    ) external whenNotPaused {
        uint64 executableAtTime = _prepareAnnouncementOrder(keeperFee);

        IStableModule stableModule = IStableModule(vault.moduleAddress(FlatcoinModuleKeys._STABLE_MODULE_KEY));
        uint256 lpBalance = IERC20Upgradeable(stableModule).balanceOf(msg.sender);

        if (lpBalance < withdrawAmount)
            revert FlatcoinErrors.NotEnoughBalanceForWithdraw(msg.sender, lpBalance, withdrawAmount);

        // Check that the requested minAmountOut is feasible
        {
124:        uint256 expectedAmountOut = stableModule.stableWithdrawQuote(withdrawAmount);

            if (keeperFee > expectedAmountOut) revert FlatcoinErrors.WithdrawalTooSmall(expectedAmountOut, keeperFee);

128:        expectedAmountOut -= keeperFee;

            if (expectedAmountOut < minAmountOut) revert FlatcoinErrors.HighSlippage(expectedAmountOut, minAmountOut);

132:        vault.checkSkewMax({additionalSkew: expectedAmountOut});
        }
```

Since announceStableWithdraw function decrease the stableCollateralTotal of FlatcoinVault.sol#L303, it should pass the amount of decreased stable collateral to FlatcoinVault.sol#checkSkewMax function. (See Recommendation)
But now exepectedAmountOut of L132 is the amount of collateral which are refunded from pool to user.
Thus FlatcoinVault.sol#checkSkewMax will be malfunctioned.

## Impact
FlatcoinVault.sol#checkSkewMax will be malfunctioned.
That is, the system may be too skewed towards longs after redeeming stables, or redeeming stables may be failed while system is not too skewed towards longs.

## Code Snippet
https://github.com/sherlock-audit/2023-12-flatmoney/blob/main/flatcoin-v1/src/DelayedOrder.sol#L132

## Tool used
Manual Review

## Recommendation
Add the amount of stable collateral to remove as a parameter to FlatcoinVault.sol#checkSkewMax function and Modify DelayedOrder.sol#announceStableWithdraw function to pass the stableCollateralAmount which corresponds to withdrawAmount.
That is, modify FlatcoinVault.sol#checkSkewMax function as follows.
```solidity
--  function checkSkewMax(uint256 _additionalSkew) public view {
++  function checkSkewMax(uint256 _additionalSkew, uint256 _removedStateCollateral) public view {
        // check that skew is not essentially disabled
        if (skewFractionMax < type(uint256).max) {
            uint256 sizeOpenedTotal = _globalPositions.sizeOpenedTotal;

            if (stableCollateralTotal == 0) revert FlatcoinErrors.ZeroValue("stableCollateralTotal");

--         uint256 longSkewFraction = ((sizeOpenedTotal + _additionalSkew) * 1e18) / stableCollateralTotal;
++         uint256 longSkewFraction = ((sizeOpenedTotal + _additionalSkew) * 1e18) / (stableCollateralTotal - _removedStateCollateral);

            if (longSkewFraction > skewFractionMax) revert FlatcoinErrors.MaxSkewReached(longSkewFraction);
        }
    }
```

Then modify DelayedOrder.sol#announceStableWithdraw function as follows.
```solidity
    function announceStableWithdraw(
        uint256 withdrawAmount,
        uint256 minAmountOut,
        uint256 keeperFee
    ) external whenNotPaused {
++      uint256 stableCollateralAmount;
        ......
--          vault.checkSkewMax({additionalSkew: expectedAmountOut});
++          vault.checkSkewMax({additionalSkew: 0, removedStateCollateral: stableCollateralAmount});
        ......
    }
```
There are several places where vault.checkSkewMax function is called so all such calls should be updated with new signature.