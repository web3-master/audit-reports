| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-perpetualatlanticvaultsettle-may-be-dosed-by-attacker) | PerpetualAtlanticVault.settle() may be DoSed by attacker. |


# [H-01] PerpetualAtlanticVault.settle() may be DoSed by attacker.
## Impact
PerpetualAtlanticVault can not be settled forever.

## Proof of Concept
When an attacker transfers few amount of collateral token to PerpetualAtlanticVaultLP, the function - 'PerpetualAtlanticVaultLP.sol#substractLoss' is always reverted because real balance is different from the value - _totalCollateral.

PerpetualAtlanticVaultLP.sol#substractLoss is following.
```solidity
File: PerpetualAtlanticVaultLP.sol
199:   function subtractLoss(uint256 loss) public onlyPerpVault {
200:     require(
201:       collateral.balanceOf(address(this)) == _totalCollateral - loss,
202:       "Not enough collateral was sent out"
203:     );
204:     _totalCollateral -= loss;
205:   }
```
In L201, the equation collateral.balanceOf(address(this)) == _totalCollateral - loss is based on the assumption in which collateral.balanceof(address(this)) is always synced with _totalCollateral.

But an attacker transfers few amount of collateral token to PerpetualAtlanticVaultLP contract, this assumption becomes wrong.

Then, this function is always reverted.

On the other hand, the function - PerpetualAtlanticVault.sol#settle calls this function - PerpetualAtlanticVaultLP.sol#substractLoss.

So, in this case, function - PerpetualAtlanticVault.sol#settle is always reverted.

## Lines of code
https://github.com/code-423n4/2023-08-dopex/blob/main/contracts/perp-vault/PerpetualAtlanticVaultLP.sol#L201

## Tool used
Manual Review

## Recommended Mitigation Steps
```solidity
File: PerpetualAtlanticVaultLP.sol
199:   function subtractLoss(uint256 loss) public onlyPerpVault {
200:     require(
201: -     collateral.balanceOf(address(this)) == _totalCollateral - loss,
201: +     collateral.balanceOf(address(this)) >= _totalCollateral - loss,
202:       "Not enough collateral was sent out"
203:     );
204:     _totalCollateral -= loss;
205:   }
```