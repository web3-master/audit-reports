| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-liquidationbranchsolliquidateaccounts-function-has-mistake) | `LiquidationBranch.sol#liquidateAccounts` function has mistake. |
| [H-02](#h-02-liquidation-may-be-impossible-when-there-are-large-number-of-accounts) | Liquidation may be impossible when there are large number of accounts. |


# [H-01] `LiquidationBranch.sol#liquidateAccounts` function has mistake.
## Summary
`LiquidationBranch.sol#liquidateAccounts` function has mistake of using `requiredMaintenanceMarginUsdX18` instead of `requiredMaintenanceMarginUsdX18 - ctx.marginBalanceUsdX18` for `pnlUsdX18`.

## Vulnerability Detail
`LiquidationBranch.sol#liquidateAccounts` function is the following.
```solidity
    function liquidateAccounts(uint128[] calldata accountsIds) external {
        --- SKIP ---

            // get account's required maintenance margin & unrealized PNL
138:        (, UD60x18 requiredMaintenanceMarginUsdX18, SD59x18 accountTotalUnrealizedPnlUsdX18) =
                tradingAccount.getAccountMarginRequirementUsdAndUnrealizedPnlUsd(0, SD59x18_ZERO);

            // get then save margin balance into working data
            ctx.marginBalanceUsdX18 = tradingAccount.getMarginBalanceUsd(accountTotalUnrealizedPnlUsdX18);

            // if account is not liquidatable, skip to next account
            // account is liquidatable if requiredMaintenanceMarginUsdX18 > ctx.marginBalanceUsdX18
            if (!TradingAccount.isLiquidatable(requiredMaintenanceMarginUsdX18, ctx.marginBalanceUsdX18)) {
                continue;
            }

            // deduct maintenance margin from the account's collateral
            // settlementFee = liquidationFee
            ctx.liquidatedCollateralUsdX18 = tradingAccount.deductAccountMargin({
                feeRecipients: FeeRecipients.Data({
                    marginCollateralRecipient: globalConfiguration.marginCollateralRecipient,
                    orderFeeRecipient: address(0),
                    settlementFeeRecipient: globalConfiguration.liquidationFeeRecipient
                }),
158:            pnlUsdX18: requiredMaintenanceMarginUsdX18,
                orderFeeUsdX18: UD60x18_ZERO,
                settlementFeeUsdX18: ctx.liquidationFeeUsdX18
            });

            --- SKIP ---
    }
```
As can be seen, in `L158`, `requiredMaintenanceMarginUsdX18` is used mistakenly instead of `requiredMaintenanceMarginUsdX18 - ctx.marginBalanceUsdX18` of `L138`.
It might be a developer's mistake.

## Imapact
The user may lose funds during liquidation.

## Code Snippet
- [src/perpetuals/branches/LiquidationBranch.sol#L158](https://github.com/Cyfrin/2024-07-zaros/blob/main/src/perpetuals/branches/LiquidationBranch.sol#L158)

## Tool used
Manual Review

## Recommendation
Modify the `LiquidationBranch.sol#liquidateAccounts` function as follows.
```solidity
    function liquidateAccounts(uint128[] calldata accountsIds) external {
        --- SKIP ---

            // deduct maintenance margin from the account's collateral
            // settlementFee = liquidationFee
            ctx.liquidatedCollateralUsdX18 = tradingAccount.deductAccountMargin({
                feeRecipients: FeeRecipients.Data({
                    marginCollateralRecipient: globalConfiguration.marginCollateralRecipient,
                    orderFeeRecipient: address(0),
                    settlementFeeRecipient: globalConfiguration.liquidationFeeRecipient
                }),
--              pnlUsdX18: requiredMaintenanceMarginUsdX18,
++              pnlUsdX18: requiredMaintenanceMarginUsdX18 - ctx.marginBalanceUsdX18,
                orderFeeUsdX18: UD60x18_ZERO,
                settlementFeeUsdX18: ctx.liquidationFeeUsdX18
            });

            --- SKIP ---
    }
```

# [H-02] Liquidation may be impossible when there are large number of accounts.
## Summary
When there are large amount number of accounts, liquidater calls `LiquidationBranch.sol#checkLiquidatableAccounts` function with `lowerBound > 0` to get liguidatable accounts.
But since the function has logical error when `lowerBound > 0`, the function call will be reverted.

## Vulnerability Detail
`LiquidationBranch.sol#checkLiquidatableAccounts` function is the following.
```solidity
    function checkLiquidatableAccounts(
        uint256 lowerBound,
        uint256 upperBound
    )
        external
        view
        returns (uint128[] memory liquidatableAccountsIds)
    {
        // prepare output array size
51:     liquidatableAccountsIds = new uint128[](upperBound - lowerBound);

        // return if nothing to process
        if (liquidatableAccountsIds.length == 0) return liquidatableAccountsIds;

        // fetch storage slot for global config
        GlobalConfiguration.Data storage globalConfiguration = GlobalConfiguration.load();

        // cache active account ids length
        uint256 cachedAccountsIdsWithActivePositionsLength =
            globalConfiguration.accountsIdsWithActivePositions.length();

        // iterate over active accounts within given bounds
64:     for (uint256 i = lowerBound; i < upperBound; i++) {
            // break if `i` greater then length of active account ids
            if (i >= cachedAccountsIdsWithActivePositionsLength) break;

            // get the `tradingAccountId` of the current active account
            uint128 tradingAccountId = uint128(globalConfiguration.accountsIdsWithActivePositions.at(i));

            // load that account's leaf (data + functions)
            TradingAccount.Data storage tradingAccount = TradingAccount.loadExisting(tradingAccountId);

            // get that account's required maintenance margin & unrealized PNL
            (, UD60x18 requiredMaintenanceMarginUsdX18, SD59x18 accountTotalUnrealizedPnlUsdX18) =
                tradingAccount.getAccountMarginRequirementUsdAndUnrealizedPnlUsd(0, SD59x18_ZERO);

            // get that account's current margin balance
            SD59x18 marginBalanceUsdX18 = tradingAccount.getMarginBalanceUsd(accountTotalUnrealizedPnlUsdX18);

            // account can be liquidated if requiredMargin > marginBalance
82:         if (TradingAccount.isLiquidatable(requiredMaintenanceMarginUsdX18, marginBalanceUsdX18)) {
83:             liquidatableAccountsIds[i] = tradingAccountId;
            }
        }
    }
```
Example:
1. Assume that `lowerBound = 60` and `upperBound = 100`.
2. Then, it will be `liquidatableAccountsIds.length = 100 - 60 = 40` in `L51`.
3. The iterator `i` loops from `i = 60` to `i = 100` in `L64`.
4. If an trading account is liguidatable for certain `i` (`60` to `100`), the `L83` will cause panic error with array out-of-bounds.

PoC:
Modify the `checkLiquidatableAccounts.t.sol#testFuzz_WhenThereAreOneOrManyLiquidatableAccounts` function as follows.
```solidity
    function testFuzz_WhenThereAreOneOrManyLiquidatableAccounts(
        uint256 marketId,
        bool isLong,
        uint256 amountOfTradingAccounts
    )
        external
    {
        MarketConfig memory fuzzMarketConfig = getFuzzMarketConfig(marketId);
        amountOfTradingAccounts = bound({ x: amountOfTradingAccounts, min: 1, max: 10 });
        uint256 marginValueUsd = 10_000e18 / amountOfTradingAccounts;
        uint256 initialMarginRate = fuzzMarketConfig.imr;

        deal({ token: address(usdz), to: users.naruto.account, give: marginValueUsd });

        for (uint256 i; i < amountOfTradingAccounts; i++) {
            uint256 accountMarginValueUsd = marginValueUsd / amountOfTradingAccounts;
            uint128 tradingAccountId = createAccountAndDeposit(accountMarginValueUsd, address(usdz));

            openPosition(fuzzMarketConfig, tradingAccountId, initialMarginRate, accountMarginValueUsd, isLong);
        }
        setAccountsAsLiquidatable(fuzzMarketConfig, isLong);

--      uint256 lowerBound = 0;
        uint256 upperBound = amountOfTradingAccounts;
++      uint256 lowerBound = upperBound / 2;

        uint128[] memory liquidatableAccountIds = perpsEngine.checkLiquidatableAccounts(lowerBound, upperBound);

        assertEq(liquidatableAccountIds.length, amountOfTradingAccounts);
        for (uint256 i; i < liquidatableAccountIds.length; i++) {
            // it should return an array with the liquidatable accounts ids
            assertEq(liquidatableAccountIds[i], i + 1);
        }
    }
```
The result is the following
```sh
Failing tests:
Encountered 1 failing test in test/integration/perpetuals/liquidation-branch/checkLiquidatableAccounts/checkLiquidatableAccounts.t.sol:CheckLiquidatableAccounts_Integration_Test
[FAIL. Reason: panic: array out-of-bounds access (0x32); counterexample: calldata=0xcac72dcd00000000000000000000000000000000000000000000000000000000000041a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000162d args=[16800 [1.68e4], false, 5677]] testFuzz_WhenThereAreOneOrManyLiquidatableAccounts(uint256,bool,uint256) (runs: 0, μ: 0, ~: 0)
```

## Imapact
When there are large number of accounts, The liquidator should call `LiquidationBranch.sol#checkLiquidatableAccounts` function with `lowerBound > 0` to avoid huge gas fee.
Then since the call will be reverted, the liquidator can't liquidate liquidatable accounts in time and it may cause the protocol unsolvent.

## Code Snippet
- [src/perpetuals/branches/LiquidationBranch.sol#L83](https://github.com/Cyfrin/2024-07-zaros/blob/main/src/perpetuals/branches/LiquidationBranch.sol#L83)

## Tool used
Manual Review

## Recommendation
Modify the `LiquidationBranch.sol#checkLiquidatableAccounts` function as follows.
```solidity
    function checkLiquidatableAccounts(
        uint256 lowerBound,
        uint256 upperBound
    )
        external
        view
        returns (uint128[] memory liquidatableAccountsIds)
    {
        ... SKIP ...

            // account can be liquidated if requiredMargin > marginBalance
            if (TradingAccount.isLiquidatable(requiredMaintenanceMarginUsdX18, marginBalanceUsdX18)) {
--              liquidatableAccountsIds[i] = tradingAccountId;
++              liquidatableAccountsIds[i - lowerBound] = tradingAccountId;
            }
        }
    }
```