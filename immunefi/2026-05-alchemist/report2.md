## Title
Mismatch Between Reported Max Withdrawable Collateral and Actual Withdrawable Amount

## Summary
The `AlchemistV3.getMaxWithdrawable()` function computes the maximum withdrawable collateral for a position, accounting for both position-level and global constraints. However, the `withdraw()` function enforces only the position-level collateralization, ignoring global constraints. This inconsistency can cause the value returned by `getMaxWithdrawable()` to be higher than what can actually be withdrawn.

## Vulnerability Detail
### Withdraw Function Logic
The `withdraw()` function currently validates withdrawals as follows:
```solidity
File: AlchemistV3.sol
446:     function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
447:         _checkArgument(recipient != address(0));
448:         _checkForValidAccountId(tokenId);
449:         _checkArgument(amount > 0);
450:         _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
451:         _earmark();
452:         _sync(tokenId);
453: 
454:         if (_accounts[tokenId].collateralBalance > _mytSharesDeposited) {
455:             _accounts[tokenId].collateralBalance = _mytSharesDeposited;
456:         }
457: 
458:         uint256 debtShares = convertDebtTokensToYield(_accounts[tokenId].debt);
459:         uint256 lockedCollateral = FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
460:         _checkArgument(_accounts[tokenId].collateralBalance - lockedCollateral >= amount);
461:         uint256 transferred = _subCollateralBalance(amount, tokenId);
462: 
463:         // Assure that the collateralization invariant is still held.
464:         _validate(tokenId);
465: 
466:         // Transfer the yield tokens to msg.sender
467:         TokenUtils.safeTransfer(myt, recipient, transferred);
468: 
469:         emit Withdraw(transferred, tokenId, recipient);
470: 
471:         return transferred;
472:     }
```
Observation:

Withdrawal is validated only against the **position-level collateralization**, ignoring global constraints.

### Max Withdrawable Calculation Logic
In contrast, `getMaxWithdrawable()` considers both position-level and global-level constraints:
```solidity
File: AlchemistV3.sol
371:     function getMaxWithdrawable(uint256 tokenId) external view returns (uint256) {
372:         (uint256 debt,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
373: 
374:         uint256 lockedCollateral = 0;
375:         if (debt != 0) {
376:             uint256 debtShares = convertDebtTokensToYield(debt);
377:             lockedCollateral = FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
378:         }
379: 
380:         uint256 positionFree = collateral > lockedCollateral ? collateral - lockedCollateral : 0;
381:         uint256 required = _requiredLockedShares();
382:         uint256 globalFree = _mytSharesDeposited > required ? _mytSharesDeposited - required : 0;
383: 
384:         return positionFree < globalFree ? positionFree : globalFree;
385:     }
```
Observation:

* The function returns the minimum of **position-free collateral** and **global-free collateral**, which may differ from the actual amount allowed by `withdraw()`.
* This discrepancy can mislead users into believing they can withdraw more collateral than permitted.

## Impact
* Users may see **incorrect maximum withdrawable amounts** when calling `getMaxWithdrawable()`.
* Attempts to withdraw the reported amount may **revert unexpectedly**, causing a poor user experience.

## Code Snippet
https://github.com/alchemix-finance/v3/blob/a83b98cd93539e533a3988ec3bb5cd090075ad43/src/AlchemistV3.sol#L382

## Recommendation
Update `getMaxWithdrawable()` to reflect the same checks as `withdraw()`, i.e., enforce only **position-level collateralization**:
```solidity
File: AlchemistV3.sol
371:     function getMaxWithdrawable(uint256 tokenId) external view returns (uint256) {
372:         (uint256 debt,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
373: 
374:         uint256 lockedCollateral = 0;
375:         if (debt != 0) {
376:             uint256 debtShares = convertDebtTokensToYield(debt);
377:             lockedCollateral = FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
378:         }
379: 
380:         uint256 positionFree = collateral > lockedCollateral ? collateral - lockedCollateral : 0;
383: 
384:         return positionFree;
385:     }
```