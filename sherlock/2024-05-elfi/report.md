| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-updateallpositionfrombalancemargin-function-mistakenly-increments-positions-frombalance) | updateAllPositionFromBalanceMargin function mistakenly increments positions "fromBalance" |
| [H-02](#h-02-attacker-can-inflate-stake-rewards-as-he-wants) | Attacker can inflate stake rewards as he wants. |
| [M-01](#m-01-keepers-loss-gas-is-never-accounted) | Keepers loss gas is never accounted |
| [M-02](#m-02-user-collateral-cap-check-issue) | User Collateral Cap Check Issue |

# [H-01] updateAllPositionFromBalanceMargin function mistakenly increments positions "fromBalance"
## Summary
When a position is closed all the other positions "from balances" are updated. However, the function logic updateAllPositionFromBalanceMargin is not fully correct and can increment the "from balances" of other positions more than it supposed to.

## Vulnerability Detail
Assume Bob has 3 positions as follows:
WBTC SHORT 1000$ margin 5x (BTC price 25k)
WETH SHORT 500$ margin 5x (ETH price 1k)
SOL SHORT 1000$ margin 5x (SOL price 10$)

Also, Bob has the following balances in his cross account:
USDC:
balance.amount = 1000
WBTC:
balance.amount = 1

Bob first opens up the WBTC short and since the marginToken is USDC all the balance he has in his account will be used. Hence, this position will have the same initialMargin amount as its initialMarginFromBalance.

When Bob opens the SOL and WETH shorts the initialMarginFromBalance for them will be "0" since the first WBTC short occupied all the available USDC.

At some time later, assume the BTC price goes to 23K. Bob opened the short position from 25k and assuming fees are not more than the profit bob has profits. Say Bob's settled margin after closing this position is 1381 USDC (actual amount from the PoC) which means there is a profit of 381$ for Bob.

Below code snippet in DecreasePosition::_settleCrossAccount() will be calculating the changeToken which since the entire position is closed the value for it will be the settle margin, 1381 USDC.
```solidity
 if (!cache.isLiquidation) {
            int256 changeToken = (
                cache.decreaseMarginInUsdFromBalance.mul(cache.position.initialMargin).div(
                    cache.position.initialMarginInUsd
                )
            ).toInt256() +
                cache.settledMargin -
                cache.decreaseMargin.toInt256();
            PositionMarginProcess.updateAllPositionFromBalanceMargin(
                requestId,
                accountProps.owner,
                cache.position.marginToken,
                changeToken,
                position.key
            );
        }
```
Below code snippet in PositionMarginProcess::updateAllPositionFromBalanceMargin() function will start incrementing the "from balance"s of the other remaining SOL and WETH positions. As we can see updatePositionFromBalanceMargin always gets the initial amount as function variable which remember it was the settle margin amount.
```solidity
bytes32[] memory positionKeys = Account.load(account).getAllPosition();
        int256 reduceAmount = amount;
        for (uint256 i; i < positionKeys.length; i++) {
            Position.Props storage position = Position.load(positionKeys[i]);
            if (token == position.marginToken && position.isCrossMargin) {
                int256 changeAmount = updatePositionFromBalanceMargin(
                    position,
                    originPositionKey.length > 0 && originPositionKey == position.key,
                    requestId,
                    amount
                ).toInt256();
                reduceAmount = amount > 0 ? reduceAmount - changeAmount : reduceAmount + changeAmount;
                if (reduceAmount == 0) {
                    break;
                }
            }
        }
```
Below code snippet in PositionMarginProcess::updatePositionFromBalanceMargin() will be executed for both SOL and WETH positions. Assume WETH is the first in the position keys line, changeAmount will be calculated as the borrowMargin because of the min operation and position.initialMarginInUsdFromBalance will be increased by the position.initialMarginInUsdFromBalance which is 500$. When the execution ends here and we go back to the above code snippets for loop for the SOL position, the reduceAmount will be decreased by 500$ and will be 1381 - 500 = 881$.
However, when the updatePositionFromBalanceMargin function called for the SOL position the amount is still 1381 USDC. Hence, the return value for the function will be again the borrowMargin which is 1000$. When we go back to the loop we will update the decreaseAmount as 881 - 1000 = -119 and the loop ends because we looped over all the positions (no underflow since reduceAmount is int256). However, what happened here is that although the reduceAmount was lower than what needed to be increased for the positions "from balance" the full amount increased. Which is completely wrong and now the accounts overall "from balance"s are completely wrong as well.
```solidity
if (amount > 0) {
            // @review how much I am borrowing
            uint256 borrowMargin = (position.initialMarginInUsd - position.initialMarginInUsdFromBalance)
                .mul(position.initialMargin)
                .div(position.initialMarginInUsd);
            changeAmount = amount.toUint256().min(borrowMargin);
            position.initialMarginInUsdFromBalance += changeAmount.mul(position.initialMarginInUsd).div(
                position.initialMargin
            );
        }
```

## Impact
Cross accounts values will be completely off. Cross available value will be a lower number than it should be.
Also, the opposite scenario can happen which would make the account has more borrowing power than it should be.
Hence, high.

## Code Snippet
https://github.com/sherlock-audit/2024-05-elfi-protocol/blob/8a1a01804a7de7f73a04d794bf6b8104528681ad/elfi-perp-contracts/contracts/process/DecreasePositionProcess.sol#L206-L336
https://github.com/sherlock-audit/2024-05-elfi-protocol/blob/8a1a01804a7de7f73a04d794bf6b8104528681ad/elfi-perp-contracts/contracts/process/DecreasePositionProcess.sol#L338-L414
https://github.com/sherlock-audit/2024-05-elfi-protocol/blob/8a1a01804a7de7f73a04d794bf6b8104528681ad/elfi-perp-contracts/contracts/process/PositionMarginProcess.sol#L274-L338

## Tool used
Manual Review

## Recommendation
Do the following for the updateAllPositionFromBalanceMargin function
```solidity
function updateAllPositionFromBalanceMargin(
        uint256 requestId,
        address account,
        address token,
        int256 amount,
        bytes32 originPositionKey
    ) external {
        if (amount == 0) {
            return;
        }

        bytes32[] memory positionKeys = Account.load(account).getAllPosition();
        int256 reduceAmount = amount;
        for (uint256 i; i < positionKeys.length; i++) {
            Position.Props storage position = Position.load(positionKeys[i]);
            if (token == position.marginToken && position.isCrossMargin) {
                int256 changeAmount = updatePositionFromBalanceMargin(
                    position,
                    originPositionKey.length > 0 && originPositionKey == position.key,
                    requestId,
 -                 amount
 +                reduceAmount
                ).toInt256();
                reduceAmount = amount > 0 ? reduceAmount - changeAmount : reduceAmount + changeAmount;
                if (reduceAmount == 0) {
                    break;
                }
            }
        }
    }
```

# [H-02] Attacker can inflate stake rewards as he wants.
## Summary
FeeRewardsProcess.sol#updateAccountFeeRewards function uses balance of account as amount of stake tokens.
Since it is possible to transfer stake tokens to any accounts, attacker can flash loan other's stake tokens to inflate stake rewards.

## Vulnerability Detail
FeeRewardsProcess.sol#updateAccountFeeRewards function is the following.
```solidity
    function updateAccountFeeRewards(address account, address stakeToken) public {
        StakingAccount.Props storage stakingAccount = StakingAccount.load(account);
        StakingAccount.FeeRewards storage accountFeeRewards = stakingAccount.getFeeRewards(stakeToken);
        FeeRewards.MarketRewards storage feeProps = FeeRewards.loadPoolRewards(stakeToken);
        if (accountFeeRewards.openRewardsPerStakeToken == feeProps.getCumulativeRewardsPerStakeToken()) {
            return;
        }
63:     uint256 stakeTokens = IERC20(stakeToken).balanceOf(account);
        if (
            stakeTokens > 0 &&
            feeProps.getCumulativeRewardsPerStakeToken() - accountFeeRewards.openRewardsPerStakeToken >
            feeProps.getPoolRewardsPerStakeTokenDeltaLimit()
        ) {
            accountFeeRewards.realisedRewardsTokenAmount += (
                stakeToken == CommonData.getStakeUsdToken()
                    ? CalUtils.mul(
                        feeProps.getCumulativeRewardsPerStakeToken() - accountFeeRewards.openRewardsPerStakeToken,
                        stakeTokens
                    )
                    : CalUtils.mulSmallRate(
                        feeProps.getCumulativeRewardsPerStakeToken() - accountFeeRewards.openRewardsPerStakeToken,
                        stakeTokens
                    )
            );
        }
        accountFeeRewards.openRewardsPerStakeToken = feeProps.getCumulativeRewardsPerStakeToken();
        stakingAccount.emitFeeRewardsUpdateEvent(stakeToken);
    }
```
Balance of account is used as amount of stake tokens in L63.
But since the stake tokens can be transferred to any other account, attacker can inflate stake token rewards by flash loan.

Example:

User has two account: account1, account2.
User has staked 1000 ETH in account1 and 1000 ETH in account2.
After a period of time, user transfer 1000 xETH from account2 to account1 and claim rewards for account1.
Now, attacker can claim rewards twice for account1.
In the same way, attacker can claim rewards twice for account2 too.

## Impact
Attacker can inflate stake rewards as he wants using this vulnerability.

## Code Snippet
https://github.com/sherlock-audit/2024-05-elfi-protocol/blob/main/elfi-perp-contracts/contracts/process/FeeRewardsProcess.sol#L63

## Tool used
Manual Review

## Recommendation
Use stakingAccount.stakeTokenBalances[stakeToken].stakeAmount instead of stake token balance as follows.
```solidity
    function updateAccountFeeRewards(address account, address stakeToken) public {
        StakingAccount.Props storage stakingAccount = StakingAccount.load(account);
        StakingAccount.FeeRewards storage accountFeeRewards = stakingAccount.getFeeRewards(stakeToken);
        FeeRewards.MarketRewards storage feeProps = FeeRewards.loadPoolRewards(stakeToken);
        if (accountFeeRewards.openRewardsPerStakeToken == feeProps.getCumulativeRewardsPerStakeToken()) {
            return;
        }
--      uint256 stakeTokens = IERC20(stakeToken).balanceOf(account);
++      uint256 stakeTokens = stakingAccount.stakeTokenBalances[stakeToken].stakeAmount;
        if (
            stakeTokens > 0 &&
            feeProps.getCumulativeRewardsPerStakeToken() - accountFeeRewards.openRewardsPerStakeToken >
            feeProps.getPoolRewardsPerStakeTokenDeltaLimit()
        ) {
            accountFeeRewards.realisedRewardsTokenAmount += (
                stakeToken == CommonData.getStakeUsdToken()
                    ? CalUtils.mul(
                        feeProps.getCumulativeRewardsPerStakeToken() - accountFeeRewards.openRewardsPerStakeToken,
                        stakeTokens
                    )
                    : CalUtils.mulSmallRate(
                        feeProps.getCumulativeRewardsPerStakeToken() - accountFeeRewards.openRewardsPerStakeToken,
                        stakeTokens
                    )
            );
        }
        accountFeeRewards.openRewardsPerStakeToken = feeProps.getCumulativeRewardsPerStakeToken();
        stakingAccount.emitFeeRewardsUpdateEvent(stakeToken);
    }
```

# [M-01] Keepers loss gas is never accounted
## Summary
When keepers send excess gas, the excess gas is accounted in Diamonds storage so that keeper can compensate itself later. However, losses are never accounted due to math error in calculating it.

## Vulnerability Detail
Almost every facet uses the same pattern, which eventually calls the GasProcess::processExecutionFee function:
```solidity
function processExecutionFee(PayExecutionFeeParams memory cache) external {
    uint256 usedGas = cache.startGas - gasleft();
    uint256 executionFee = usedGas * tx.gasprice;
    uint256 refundFee;
    uint256 lossFee;
    if (executionFee > cache.userExecutionFee) {
        executionFee = cache.userExecutionFee;
        // @review always 0
        lossFee = executionFee - cache.userExecutionFee;
    } else {
        refundFee = cache.userExecutionFee - executionFee;
    }
    // ...
    if (lossFee > 0) {
        CommonData.addLossExecutionFee(lossFee);
    }
}
```
As we can see in the snippet above, if the execution fee is higher than the user's provided execution fee, then the execution fee is set to cache.userExecutionFee, and the loss fee is calculated as the difference between these two, which are now the same value. This means the lossFee variable will always be "0", and the loss fees for keepers will never be accounted for.

## Impact
In a scaled system, these fees will accumulate significantly, resulting in substantial losses for the keeper. Hence, labelling it as high.

## Code Snippet
https://github.com/sherlock-audit/2024-05-elfi-protocol/blob/8a1a01804a7de7f73a04d794bf6b8104528681ad/elfi-perp-contracts/contracts/process/GasProcess.sol#L17-L40

## Tool used
Manual Review

# [M-02] User Collateral Cap Check Issue
## Summary
User Collateral can exceeds the cap andd deposit will still be processed

## Vulnerability Detail
The check accountProps.getTokenAmount(token) > tradeTokenConfig.collateralUserCap is designed to ensure that a user's collateral does not exceed their specific cap. However, this validation occurs before the new deposit amount is added, thereby only verifying the current balance. Consequently, this can result in the user's collateral exceeding the cap once the deposit is processed.

## Impact
this can result in the user's collateral exceeding the cap once the deposit is processed.

## Code Snippet
https://github.com/sherlock-audit/2024-05-elfi-protocol/blob/main/elfi-perp-contracts/contracts/process/AssetsProcess.sol#L81

## Tool used
Manual Review

## Recommendation
Please find the updated check for the new deposit amount below:
```solidity
uint256 newUserCollateralAmount = accountProps.getTokenAmount(token) + params.amount;
require(newUserCollateralAmount <= tradeTokenConfig.collateralUserCap, "CollateralUserCapOverflow");
```
This modification ensures that the user's total collateral, including the new deposit, does not exceed the predefined user cap.