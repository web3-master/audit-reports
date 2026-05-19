## Title
Coding error in slippage-cap check in T2/T4 smart-collateral perfect-deposit path

## Summary
There is an coding error in duplicate slippage-cap check in T2/T4 smart-collateral perfect-deposit path which might lead to sandwich attack vector.


## Vulnerability Detail
In the perfect-shares smart-collateral deposit path, the input-validation guard is supposed to require both per-token slippage caps (colToken0MinMax_ and colToken1MinMax_) to be strictly positive. Because of a copy-paste error, the second clause checks colToken0MinMax_ again instead of colToken1MinMax_. The token1 cap is therefore never validated.
```solidity
File: mainOperate.sol
083:     function _colOperatePerfectBefore(
084:         int perfectColShares_,
085:         int colToken0MinMax_,
086:         int colToken1MinMax_
087:     ) internal returns (int newColToken0_, int newColToken1_) {
088:         if ((colToken0MinMax_ <= 0) || (colToken0MinMax_ <= 0)) {    //@audit-issue: token0 checked twice!
089:             // max limit of token should be positive in case of deposit
090:             revert FluidVaultError(ErrorTypes.VaultDex__InvalidOperateAmount);
091:         }
092: 
093:         (uint token0Amt_, uint token1Amt_) = SUPPLY.depositPerfect{
094:             value: (SUPPLY_TOKEN0 == NATIVE_TOKEN)
095:                 ? uint(colToken0MinMax_)
096:                 : (SUPPLY_TOKEN1 == NATIVE_TOKEN)
097:                     ? uint(colToken1MinMax_)
098:                     : 0
099:         }(uint(perfectColShares_), uint(colToken0MinMax_), uint(colToken1MinMax_), false);
100:         newColToken0_ = int(token0Amt_);
101:         newColToken1_ = int(token1Amt_);
102:     }
```
A negative colToken1MinMax_ cast through uint(...) becomes ~2²⁵⁶, eliminating the per-token slippage cap entirely on the call into SUPPLY.depositPerfect(...). A user who supplies a negative token1 cap loses the slippage protection on that side and can be sandwiched on the smart-collateral DEX, draining their token approvals up to the approval limit.

The _debtOperatePerfectBorrow function in the same file at vaultT4 mainOperate.sol:185 correctly checks both debtToken0MinMax_ and debtToken1MinMax_, confirming this is a copy-paste coding error, but not intended behavior.

Even though it's uncertain whether the relative user who wants to deposit collateral gives negative slippage-cap value. But the protocol considered this case as well by design. So this issue can be validated, too.

## Impact
Direct loss of user funds: 
Attacker can run a sandwich attack when the victim user calls a smart-collateral perfect-deposit while the token1 cap is set to any non-positive value. Bypass of an explicit slippage guard is an unauthorized fund-extraction vector.

## Code Snippet
https://github.com/Instadapp/fluid-contracts-public/blob/a9949b48ba1247d4f478cd0acb40896b5c8bf3f8/contracts/protocols/vault/vaultT4/coreModule/mainOperate.sol#L88

https://github.com/Instadapp/fluid-contracts-public/blob/a9949b48ba1247d4f478cd0acb40896b5c8bf3f8/contracts/protocols/vault/vaultT2/coreModule/mainOperate.sol#L51

## Recommendation
Correct this logic as follows:
```solidity
if ((colToken0MinMax_ <= 0) || (colToken1MinMax_ <= 0)) {
    revert FluidVaultError(ErrorTypes.VaultDex__InvalidOperateAmount);
}
```