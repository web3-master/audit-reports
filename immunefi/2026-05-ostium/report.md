## Title
`OstiumVault.receiveAssets` is missing access control, allowing arbitrary manipulation of `accPnlPerToken`, `dailyAccPnlDeltaPerToken`, and `totalClosedPnl`

## Brief
`OstiumVault.sendAssets` is correctly gated by `onlyCallbacks`, but its symmetric counterpart `OstiumVault.receiveAssets` has no access control. Any externally-owned account can call it, push USDC into the vault, and arbitrarily move the vault's risk-accounting state variables — including the very `dailyAccPnlDeltaPerToken` that gates the protocol's daily payout circuit breaker in `sendAssets`.

## Vulnerability Details

[OstiumVault.receiveAssets()](https://github.com/0xOstium/smart-contracts-public/blob/8390ce497f68fb128900840e0ec30683afa945d3/src/OstiumVault.sol#L757) is as follows:

```solidity
function receiveAssets(uint256 assets, address user) external {        // <— no modifier
    address sender = _msgSender();
    SafeERC20.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

    int256 accPnlDelta = (assets * PRECISION_18 / totalSupply()).toInt256();
    accPnlPerToken -= accPnlDelta;

    tryResetDailyAccPnlDelta();
    dailyAccPnlDeltaPerToken -= accPnlDelta;

    totalClosedPnl -= assets.toInt256();
    ...
}
```

Compare to the protected sibling [OstiumVault.sendAssets()](https://github.com/0xOstium/smart-contracts-public/blob/8390ce497f68fb128900840e0ec30683afa945d3/src/OstiumVault.sol#L731):

```solidity
function sendAssets(uint256 assets, address receiver) external onlyCallbacks {
    ...
    if (dailyAccPnlDeltaPerToken > maxDailyAccPnlDeltaPerToken.toInt256()) {
        revert MaxDailyPnlReached();          // daily circuit breaker
    }
    ...
}
```

`receiveAssets` is the only function that *decrements* `dailyAccPnlDeltaPerToken`. Because it is permissionless, an attacker who also holds an open winning position can:

1. Call `receiveAssets(X, anything)` to drive `dailyAccPnlDeltaPerToken` down by `(X * 1e18 / totalSupply)`.
2. Close their winning trade in the same block / day. The callback path invokes `vault.sendAssets(win, trader)`; the daily-cap check now sees the pre-lowered counter and accepts a payout the protocol had explicitly designed to defer to the next epoch.

In addition, `accPnlPerToken` is mutated without bounds. There is no lower-bound check on the result, so the variable can be driven arbitrarily negative. At the next epoch, `updateAccPnlPerTokenUsed` copies `accPnlPerToken` into `accPnlPerTokenUsed`, which feeds `updateShareToAssetsPrice()` (`shareToAssetsPrice = maxAccPnlPerToken - accPnlPerTokenUsed`). A negative `accPnlPerTokenUsed` directly inflates the share-to-assets price seen by new depositors and redemption rounding paths. The attacker also calls `tryNewOpenPnlRequestOrEpoch()` and `tryUpdateCurrentMaxSupply()` indirectly, advancing protocol state at will.

The function takes a `user` parameter that is only emitted in an event — it is not used for authorization or accounting — confirming the function was meant to be called by trusted callbacks only.

## Impact / Severity — Critical

- Bypasses the daily payout circuit breaker that protects LPs from runaway losses on volatile days.
- Permissionless write access to three internal accounting variables (`accPnlPerToken`, `dailyAccPnlDeltaPerToken`, `totalClosedPnl`) which the protocol uses to enforce solvency, gate withdrawals, and set the share price.
- Forces unscheduled state transitions in `OstiumOpenPnl` and `OstiumVault.tryUpdateCurrentMaxSupply` (epoch transitions and supply caps) without any authorization.

## Recommended Fix

Restrict the function the same way `sendAssets` is restricted:

```solidity
function receiveAssets(uint256 assets, address user) external onlyCallbacks {
    ...
}
```