| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-slight-miscalculation-in-maxamountsin-for-admin-fee-logic-in-upliftonlyexampleonafterremoveliquidity-causes-lock-of-all-funds) | Slight miscalculation in maxAmountsIn for Admin Fee Logic in UpliftOnlyExample::onAfterRemoveLiquidity Causes Lock of All Funds |
| [M-01](#m-01-formula-deviation-from-white-paper-and-weighted-pool-performupdate-unintended-revert) | formula Deviation from White Paper and Weighted Pool `performUpdate` unintended revert |


# [H-01] Slight miscalculation in maxAmountsIn for Admin Fee Logic in UpliftOnlyExample::onAfterRemoveLiquidity Causes Lock of All Funds
## Summary

The function `onAfterRemoveLiquidity` is responsible for handling post-liquidity removal operations, including fee calculations and administering liquidity back to the pool or QuantAMMAdmin. However, there is a subtle miscalculation in the `maxAmountsIn` parameter in line [541](https://github.com/Cyfrin/2024-12-quantamm/blob/a775db4273eb36e7b4536c5b60207c9f17541b92/pkg/pool-hooks/contracts/hooks-quantamm/UpliftOnlyExample.sol#L541) during admin fee processing, particularly when `localData.adminFeePercent` > 0

## Vulnerability Details

When the admin fee is calculated and accrued fees are intended to be added back to the liquidity pool, the value of `maxAmountsIn` becomes slightly less than the actual token amounts required. This leads to a mismatch during the `addLiquidity` operation in the `_vault`, which results in a reversion with the following error:

```solidity
AmountInAboveMax(token, amountInRaw, params.maxAmountsIn[i])
```

This issue prevents liquidity removal operations from completing successfully, effectively locking user funds in the pool.

The problem lies in the following block of code:

```solidity
        if (localData.adminFeePercent > 0) {
            _vault.addLiquidity(
                AddLiquidityParams({
                    pool: localData.pool,
                    to: IUpdateWeightRunner(_updateWeightRunner).getQuantAMMAdmin(),
                    maxAmountsIn: localData.accruedQuantAMMFees,
                    minBptAmountOut: localData.feeAmount.mulDown(localData.adminFeePercent) / 1e18,
                    kind: AddLiquidityKind.PROPORTIONAL,
                    userData: bytes("")
                })
            );
            emit ExitFeeCharged(
                userAddress,
                localData.pool,
                IERC20(localData.pool),
                localData.feeAmount.mulDown(localData.adminFeePercent) / 1e18
            );
        }
```

Here:

* `localData.accruedQuantAMMFees[i]` is calculated using:

```solidity
localData.accruedQuantAMMFees[i] = exitFee.mulDown(localData.adminFeePercent);
```

However, as vault calculation favours the vault over the user, the calculated `amountInRaw` in vault is slightly more than the `params.maxAmountsIn[i]`. Ref-[1](https://github.com/balancer/balancer-v3-monorepo/blob/93bacf3b5f219edff6214bcf58f8fe62ec3fde33/pkg/vault/contracts/Vault.sol#L712-L715)

* When the `_vault` validates the input via:

```solidity
if (amountInRaw > params.maxAmountsIn[i]) {
    revert AmountInAboveMax(token, amountInRaw, params.maxAmountsIn[i]);
}
```

The slight discrepancy causes a reversion, even when the difference is only by 1 wei.

## Impact

All liquidity removal operations revert, effectively locking user funds in the pool.

## Tools Used

Foundry

## Recommendations

* Add a small buffer to `localData.accruedQuantAMMFees` to account for precision errors. For example:

```solidity
for(uint256 i=0; i<localData.accruedQuantAMMFees.length; i++) {
    localData.accruedQuantAMMFees[i] += 1;
    hookAdjustedAmountsOutRaw[i] -= 1;
}
```

* Or reduce the `minBptAmountOut` silghtly:

```diff
        if (localData.adminFeePercent > 0) {
            _vault.addLiquidity(
                AddLiquidityParams({
                    pool: localData.pool,
                    to: IUpdateWeightRunner(_updateWeightRunner).getQuantAMMAdmin(),
                    maxAmountsIn: localData.accruedQuantAMMFees,
-                   minBptAmountOut: localData.feeAmount.mulDown(localData.adminFeePercent) / 1e18,
+                   minBptAmountOut: localData.feeAmount.mulDown(localData.adminFeePercent) / 1e18 -1,
                    kind: AddLiquidityKind.PROPORTIONAL,
                    userData: bytes("")
                })
            );
            emit ExitFeeCharged(
                userAddress,
                localData.pool,
                IERC20(localData.pool),
                localData.feeAmount.mulDown(localData.adminFeePercent) / 1e18
            );
        }
```

# [M-01] formula Deviation from White Paper and Weighted Pool `performUpdate` unintended revert
## Summary

The White Paper states that there should be no difference in the calculation of scaler and vector values across formulas. Additionally, during the unguarded weights stage, the protocol should allow negative weights, as the guard weight ensures final weights validity.

However, for vector kappa values, the `performUpdate` function reverts when it theoretically should not. While a valid revert for a single `performUpdate` is expected behavior, this particular revert should not be treated as default/valid behavior.

## Vulnerability Details

The White Paper mentions that a strategy can utilize either scalar or vector kappa values. The primary difference lies in implementation complexity, as vector kappa values require an additional `SLOAD` operation and a nested loop for processing.
![White Paper reference](https://i.ibb.co/fQdFf2s/image.png)
The same formula is applied for both scaler and vector kappa values, ensuring uniformity in calculations regardless of the type of kappa value used.
![Formula](https://i.ibb.co/JFVpysX/image1.png\[/img]\[/url])
The current strategy algorithm supports both short and long positions. However, the additional check in the implementation, as shown in the code below, prevents the weighted pool from functioning with long/short positions if the unguarded weights return negative values after a price change.

```solidity
contracts/rules/AntimomentumUpdateRule.sol:100
100:         newWeightsConverted = new int256[](_prevWeights.length);
101:         if (locals.kappa.length == 1) {
102:             locals.normalizationFactor /= int256(_prevWeights.length);
103:             // w(t − 1) + κ ·(ℓp(t) − 1/p(t) · ∂p(t)/∂t)
104: 
105:             for (locals.i = 0; locals.i < _prevWeights.length; ) {
106:                 int256 res = int256(_prevWeights[locals.i]) +
107:                     int256(locals.kappa[0]).mul(locals.normalizationFactor - locals.newWeights[locals.i]); 
108:                 newWeightsConverted[locals.i] = res; 
110:                 unchecked {
111:                     ++locals.i;
112:                 }
113:             }
114:         } else {
115:             for (locals.i = 0; locals.i < locals.kappa.length; ) {
116:                 locals.sumKappa += locals.kappa[locals.i];
117:                 unchecked {
118:                     ++locals.i;
119:                 }
120:             }
121: 
122:             locals.normalizationFactor = locals.normalizationFactor.div(locals.sumKappa);
123:             
124:             for (locals.i = 0; locals.i < _prevWeights.length; ) {
125:                 // w(t − 1) + κ ·(ℓp(t) − 1/p(t) · ∂p(t)/∂t)
126:                 int256 res = int256(_prevWeights[locals.i]) +
127:                     int256(locals.kappa[locals.i]).mul(locals.normalizationFactor - locals.newWeights[locals.i]);
128:                 require(res >= 0, "Invalid weight"); // @audit : no valid revert
129:                 newWeightsConverted[locals.i] = res;
130:                 unchecked {
131:                     ++locals.i;
132:                 }
133:             }
134:         }
135: 
136:         return newWeightsConverted;
```

## Impact

In the case of vector kappa, the weights are not updated and continue using the old values, which is incorrect given the latest price changes. However, with single kappa, the update proceeds as expected, reflecting the new prices.

## Tools Used

Manual Review, Unit Testing

## Recommendations

It is recommended to remove the check `require(res >= 0, "Invalid weight");` from all currently implemented strategies/algorithms. This change will ensure compatibility with scenarios where unguarded weights may temporarily result in negative values, allowing the system to proceed as intended.
