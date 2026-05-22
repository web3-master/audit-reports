## Title
Unauthenticated flashloan callback drains user funds via `permit2` (AaveV3LeverageOperator)

## Brief / Intro
`AaveV3LeverageOperator.onMorphoFlashLoan` is the Morpho flashloan callback. It decodes a fully attacker-controlled `(user, collateralVault, ...)` tuple from `data` and then pulls `underlyingCollateral` and `aToken` **directly from `user` using Permit2**. Because Morpho is permissionless (anyone may initiate a flashloan and Morpho will call back into this contract with any `data`), the only access control is `require(msg.sender == address(MORPHO))`, which an attacker trivially satisfies by initiating their own Morpho flashloan.

## Vulnerability Details
`AaveV3LeverageOperator.onMorphoFlashLoan()` is as follows.
```solidity
function onMorphoFlashLoan(uint amount, bytes calldata data) external {
    require(msg.sender == address(MORPHO), T_CallerNotMorpho());

    ( address user, address targetAsset, address collateralVault, ... )
        = abi.decode(data, (address, address, address, uint, uint, uint, uint, bytes[]));
    ...
    if (underlyingCollateralAmount > 0) {
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(underlyingCollateral), user, address(this), underlyingCollateralAmount, permit2);
        ...
    }
    if (aTokenCollateralAmount > 0) {
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(aToken), user, address(this), aTokenCollateralAmount, permit2);
    }
    ...
    IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
    items[0] = IEVC.BatchItem({ targetContract: collateralVault, onBehalfOfAccount: user,
        value: 0, data: abi.encodeCall(CollateralVaultBase.skim, ()) });
    items[1] = IEVC.BatchItem({ targetContract: collateralVault, onBehalfOfAccount: user,
        value: 0, data: abi.encodeCall(CollateralVaultBase.borrow, (amount, address(this))) });
    IEVC(evc).batch(items);
}
```

Any user that has granted a persistent Permit2 allowance to `AaveV3LeverageOperator` (which is **required** in order to use `executeLeverage` normally) can be drained by an attacker:

1. Attacker calls `MORPHO.flashLoan(targetAsset, amount, encoded)` where `encoded` sets `user = victim` and any amounts they choose.
2. Morpho transfers `amount` into the operator and calls `onMorphoFlashLoan`.
3. The flashloan funds are forwarded to `SWAPPER` and the attacker-controlled `swapData` is executed (e.g. `sweep` to attacker).
4. The callback then pulls `underlyingCollateralAmount` and `aTokenCollateralAmount` from the victim via the existing Permit2 approval.
5. `EVC.batch` runs `skim` and `borrow` against the victim's collateral vault (the victim has authorized this operator on the EVC), saddling them with new debt that goes to the operator and is used to repay Morpho.

The victim ends up with all of their Permit2-approved underlying collateral and aTokens stolen, plus brand new debt on their collateral vault. Combined with full attacker control of `swapData`, the attacker also walks away with the flashloan proceeds.

## Impact / Severity
**Critical — direct theft of funds.**
Every user who has used (or pre-approved) `AaveV3LeverageOperator` via Permit2 is permanently exposed until they revoke their Permit2 allowance and EVC operator authorization.

## Recommended Fix
Bind the callback to a real, in-progress operation. Common, minimal mitigations:

1. In `executeLeverage`, store a transient hash (or `tstore`/`SSTORE2`) of the expected `(user, collateralVault, amounts, …)` before calling `MORPHO.flashLoan`, and require `onMorphoFlashLoan` to match it and clear it. Reject calls when no operation is in flight.
2. Or store `address transient pendingUser` and require `pendingUser == _msgSender()` was set by the parent `executeLeverage`, and require it has not been already consumed.
3. Disallow Permit2 pulls in the callback altogether — pull the user's tokens in `executeLeverage` before requesting the flashloan, exactly as `LeverageOperator.sol` already does.

## References
https://github.com/0xTwyne/twyne-contracts-v1/blob/0aa37b02fca27025a049daf0d7ec31b94f1810eb/src/operators/AaveV3LeverageOperator.sol#L146

https://github.com/0xTwyne/twyne-contracts-v1/blob/0aa37b02fca27025a049daf0d7ec31b94f1810eb/src/operators/AaveV3LeverageOperator.sol#L151