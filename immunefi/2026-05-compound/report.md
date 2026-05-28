## Title
Logic bug in `swapViaCurve` causes the liquidator to call Curve's `exchange()` with the wrong indices when the collateral being liquidated is wstETH, sending the swap in the wrong direction.

## Brief / Intro
After unwrapping wstETH to stETH the local variable `tokenIn` is correctly updated to `stEth`, but the subsequent index-picking logic still compares against the original `asset` (wstETH). The validation passes (because it compares against `tokenIn`), but the `idxOfTokenIn` / `idxOfTokenOut` are computed against the wrong token. Combined with the hard-coded `_min_dy = 0`, this either silently swaps in the wrong direction, mis-uses the approval, or causes the entire flash-loan-arbitrage flow to revert (gas griefing) — but it can also yield zero/dust output that the protocol-side flash-loan repayment then forces the absorber's profit balance to cover.

## Vulnerability Details
File: [contracts/liquidator/OnChainLiquidator.sol](contracts/liquidator/OnChainLiquidator.sol#L480-L519)

```solidity
address tokenIn = asset;

// unwrap wstETH
if (tokenIn == wstEth) {
    swapAmount = IWstETH(wstEth).unwrap(swapAmount);
    tokenIn = stEth;                       // tokenIn is now stETH
}

address curvePool = poolConfig.curvePool;
TransferHelper.safeApprove(tokenIn, address(curvePool), swapAmount);

address coin0 = IStableSwap(curvePool).coins(0);
address coin1 = IStableSwap(curvePool).coins(1);

if (coin0 != tokenIn && coin1 != tokenIn) {       // validated against tokenIn ✓
    revert InvalidPoolConfig(tokenIn, poolConfig);
}

address tokenOut = CometInterface(comet).baseToken();
if (coin0 == NULL_ADDRESS || coin1 == NULL_ADDRESS) {
    tokenOut = NULL_ADDRESS;
}

int128 idxOfTokenIn  = coin0 == asset ? int128(0) : int128(1);   // BUG: uses `asset` (wstETH), not `tokenIn` (stETH)
int128 idxOfTokenOut = idxOfTokenIn == 0 ? int128(1) : int128(0);

uint amountOut = IStableSwap(curvePool).exchange(
    idxOfTokenIn,
    idxOfTokenOut,
    swapAmount,
    0                  // _min_dy = 0
);
```

Concrete scenario — liquidating wstETH against the canonical Curve `stETH/ETH` pool (`coin0 = stETH`, `coin1 = ETH(NULL)`):

1. `tokenIn` becomes `stETH`, approval is set on `stETH` for `swapAmount`.
2. Validation: `coin0 (stETH) != tokenIn (stETH)` is false → passes.
3. Index pick: `coin0 (stETH) == asset (wstETH)` is **false** → `idxOfTokenIn = 1`, `idxOfTokenOut = 0`.
4. `exchange(1, 0, ...)` instructs Curve to take `coin1 = ETH` from the caller and return `coin0 = stETH`. The liquidator has stETH, no msg.value, and an approval on stETH — the call reverts or silently produces no output, but `_min_dy = 0` disables the safety net.

When this swap fails or produces dust, the flash-loan repayment branch in `uniswapV3FlashCallback`:

```solidity
if (totalAmountOwed > balance) {
    revert InsufficientBalance(balance, totalAmountOwed);
}
```

will revert, wasting gas; in pool configurations where the wrong direction *does* execute (e.g. a 2-coin non-ETH pool where `asset != tokenIn` but both coins are valid), the liquidator receives the wrong token and can lose funds it pre-funded into the contract via `pay()`.

## Impact Details / Severity
**Critical** for any market that lists wstETH as a collateral asset and routes liquidations through Curve. At minimum, the wstETH liquidation path is broken (no on-chain liquidator can absorb wstETH positions, leaving bad debt to accrue against reserves). In pool configurations where the inverted call does not revert outright, combined with `_min_dy = 0` it allows full slippage and direct loss of collateral.

## Recommended Fix / Mitigation
Use `tokenIn` everywhere after the unwrap:

```solidity
int128 idxOfTokenIn  = coin0 == tokenIn ? int128(0) : int128(1);
int128 idxOfTokenOut = idxOfTokenIn == 0 ? int128(1) : int128(0);
```

Additionally, replace the hard-coded `_min_dy = 0` with a `min_dy` derived from `amountOutMin` so that bad swaps revert at the Curve layer, not at the flash-loan repayment layer.


## References
https://github.com/compound-finance/comet/blob/ed6ebcd84ac00906e8e725716891d482f4bef8b9/contracts/liquidator/OnChainLiquidator.sol#L511