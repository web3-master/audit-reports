## Title
Incorrect Collateralization Factor Used in Global Locked Collateral Calculation

## Summary
The `_requiredLockedShares()` function in AlchemistV3 uses `minimumCollateralization` instead of `globalMinimumCollateralization` when calculating the required collateral backing for total system debt. This results in an underestimation of required collateral, which can incorrectly affect protocol state checks and lead to unintended reverts of legitimate user operations.


## Vulnerability Detail
### Incorrect Collateral Factor Usage
The protocol calculates the minimum required locked collateral shares as follows:
```solidity
File: AlchemistV3.sol
1715:     function _requiredLockedShares() internal view returns (uint256) {
1716:         if (totalDebt == 0) return 0;
1717: 
1718:         uint256 debtShares = convertDebtTokensToYield(totalDebt);
1719:         return FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);     //@audit-issue We should use 'globalMinimumCollateralization' instead of 'minimumCollateralization'.
1720:     }
```
The function uses `minimumCollateralization` as the collateralization factor. However, this parameter represents the **minimum collateralization ratio at the individual account level**, not the **global protocol-level requirement**.

The correct parameter for global solvency calculations is `globalMinimumCollateralization`.

### Expected Behavior
The protocol defines a separate global constraint:
```solidity
File: AlchemistV3.sol
315:     function setGlobalMinimumCollateralization(uint256 value) external onlyAdmin {
316:         _checkArgument(value >= minimumCollateralization);
317:         globalMinimumCollateralization = value;
318:         emit GlobalMinimumCollateralizationUpdated(value);
319:     }
```
This ensures:

`globalMinimumCollateralization` >= `minimumCollateralization`

Therefore, using minimumCollateralization in global calculations **systematically underestimates** the required collateral.


### Propagation of the Issue

The `_requiredLockedShares()` function is used in critical accounting paths. Notably:

* It contributes to `_getTotalLockedUnderlyingValue()`
* Which is used by `_isProtocolInBadDebt()`
* Which is enforced across user-facing operations

For example:
```solidity
File: AlchemistV3.sol
417:     function deposit(uint256 amount, address recipient, uint256 tokenId) external returns (uint256, uint256) {
418:         _checkArgument(recipient != address(0));
419:         _checkArgument(amount > 0);
420:         _checkState(!depositsPaused);
421:         _checkState(!_isProtocolInBadDebt());      //@audit-issue This check is impacted by wrong collateral factor.
422:         _checkState(_mytSharesDeposited + amount <= depositCap);
...
443:     }
```
Because the required collateral is underestimated, the protocol’s internal accounting may become inconsistent. This can lead to incorrect evaluations of system health, potentially causing valid user operations (such as deposits) to revert under certain conditions.

## Impact
* Incorrect Global Solvency Assessment:
The protocol underestimates the collateral required to back outstanding debt.
* Unexpected Reverts of Valid Operations:
User actions (e.g., deposits) gated by _isProtocolInBadDebt() may fail due to inconsistent internal accounting.
* Economic Inefficiency:
Legitimate protocol usage may be hindered, potentially reducing system utilization and yield generation.

## Code Snippet
https://github.com/alchemix-finance/v3/blob/a83b98cd93539e533a3988ec3bb5cd090075ad43/src/AlchemistV3.sol#L1743

## Recommendation
Update `_requiredLockedShares()` to use the correct global collateralization parameter:
```solidity
File: AlchemistV3.sol
1715:     function _requiredLockedShares() internal view returns (uint256) {
1716:         if (totalDebt == 0) return 0;
1717: 
1718:         uint256 debtShares = convertDebtTokensToYield(totalDebt);
1719:         return FixedPointMath.mulDivUp(debtShares, globalMinimumCollateralization, FIXED_POINT_SCALAR);
1720:     }
```