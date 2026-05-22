## Title
`claimRedeemRequest` decrements `totReservedWithdrawals` by the full pre-haircut amount when system is undercollateralized

## Brief
When the system is undercollateralized, `claimRedeemRequest` pays the user a *proportional* share `amount * totalCollateral / parSupply` but then unconditionally subtracts the **full original `amount`** from `totReservedWithdrawals`. This understates the system's outstanding liabilities and over time causes `_parSupply()` (= `totalSupply + totReservedWithdrawals`) to be systematically too low, which then causes `isParetoDollarCollateralized()` to return `true` while the system is still in deficit — re-enabling `mint()`, `depositFunds`, and other gated paths on stale accounting.

## Vulnerability Details
- [src/ParetoDollarQueue.sol:384-419](https://github.com/pareto-credit/USP/blob/2cb0a098c7ccb9813497ef3982d78c44a596c87b/src/ParetoDollarQueue.sol#L419):
  ```solidity
  uint256 _amountLeft = amount;
  if (!isParetoDollarCollateralized()) {
      _amountLeft = amount * getTotalCollateralsScaled() / _parSupply();
  }
  ...
  // collateral transfer loop uses _amountLeft (the haircut amount)
  ...
  totReservedWithdrawals -= amount;          // <-- full amount, not _amountLeft
  ```
- `amount` is the user's original USP request, while `_amountLeft` is the haircut share they actually receive. After a partial payout the difference `amount - _amountLeft` is permanently written off from the liability counter, but no corresponding amount of USP is burned elsewhere (the USP was already burned at `requestRedeem` time).
- Concrete sequence:
  1. State: `totalSupply = 0`, `totReservedWithdrawals = 1,000e18`, `totalCollateralScaled = 500e18` (50 % collateralized).
  2. User claims their `1,000e18` request. `_amountLeft = 500e18`, user receives `500e18` of collateral.
  3. State after: `totalSupply = 0`, `totReservedWithdrawals = 0`, `totalCollateralScaled = 0` ✓ (looks balanced).
  4. But if there is another user with `500e18` in the queue, their pre-claim state should have shown `totReservedWithdrawals = 1,000e18 - 500e18 = 500e18` still owed and `totalCollateral = 0`. Instead, after step 2 their slice is gone too — *the first claimer collected the entire collateral pool while the second user's reservation counter implies they still have claim*.
- More damaging: while there remain unclaimed users in the same epoch, `isParetoDollarCollateralized()` evaluates `getTotalCollateralsScaled() + THRESHOLD >= totalSupply + totReservedWithdrawals`. Because `totReservedWithdrawals` has been over-subtracted, the function returns `true` prematurely, re-enabling `mint()`. New mints are issued against a collateral base that is already promised to existing redeemers.

## Impact / Severity
**Critical.** First-claimer race condition causing later redeemers to receive less than their proportional share, *and* re-opening the mint gate while the system is still underwater (allowing further dilution of existing USP holders).

## Recommended Fix / Mitigation
- Subtract `_amountLeft` (the haircut value) from `totReservedWithdrawals`, not `amount`, *and* burn / write down the un-redeemed `amount - _amountLeft` via the loss-absorption pathway so total supply accounting stays consistent:
  ```solidity
  totReservedWithdrawals -= _amountLeft;
  // The shortfall is socialised — handle it explicitly:
  uint256 shortfall = amount - _amountLeft;
  if (shortfall > 0) {
      // either: keep it on the books as a pending obligation, or
      // settle via sUSP loss absorption / governance write-down
  }
  ```
- Alternatively, freeze new mints (`isParetoDollarCollateralized()` should also consider any open undercollateralized epochs) until all in-flight haircut claims are processed.