| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-admin-cant-remove-splitter) | Admin can't remove splitter. |


# [M-01] Admin can't remove splitter.
## Summary
When there is rewards in the splitter, `LSTRewardsSplitterController.removeSplitter()` function will be reverted by logical error.

## Vulnerability Detail
`LSTRewardsSplitterController.removeSplitter()` function is following.
```solidity
    function removeSplitter(address _account) external onlyOwner {
        ILSTRewardsSplitter splitter = splitters[_account];
        if (address(splitter) == address(0)) revert SplitterNotFound();

134:    uint256 balance = IERC20(lst).balanceOf(address(splitter));
        uint256 principalDeposits = splitter.principalDeposits();
        if (balance != 0) {
137:        if (balance != principalDeposits) splitter.splitRewards();
138:        splitter.withdraw(balance, _account);
        }

        --- SKIP ---
    }
```
As can be seen in `L134`, the `balance` is the initial LST balance of the splitter. If there are rewards to be splitted to receivers, the function calls `splitRewards()` in `L137`. As a result, the LST balance of the splitter will be decreased as the amount of splitted fees. Therefore the LST balance of the splitter will be smaller than `balance` and the `withdraw()` function call of `L138` will be reverted by lacks of LST balance.

PoC:
Initial State: Assume that `balance = 1200` and `principalDeposits = 1000`.
1. In `L137`, The total rewards are `1200 - 1000 = 200`. Assume that the half of them `200 * 50% = 100` are splitted to fee receivers. Then LST balance of the splitter will be decreased to `1200 - 100 = 1100`.
2. In `L138`, since the balance of the splitter `1100` is smaller than `balance = 1200`, function call `withdraw(1200, _account)` will be reverted.

## Impact
Admin can't remove the splitter when there are rewards to be splitted to fee receivers.

## Code Snippet
- [LSTRewardsSplitterController.removeSplitter()](https://github.com/Cyfrin/2024-09-stakelink/tree/main/contracts/core/lstRewardsSplitter/LSTRewardsSplitterController.sol#L130-L153)

## Tool used
Manual Review

## Recommendation
Modify the `LSTRewardsSplitterController.removeSplitter()` function as follows.
```solidity
    function removeSplitter(address _account) external onlyOwner {
        ILSTRewardsSplitter splitter = splitters[_account];
        if (address(splitter) == address(0)) revert SplitterNotFound();

        uint256 balance = IERC20(lst).balanceOf(address(splitter));
        uint256 principalDeposits = splitter.principalDeposits();
        if (balance != 0) {
            if (balance != principalDeposits) splitter.splitRewards();
--          splitter.withdraw(balance, _account);
++          splitter.withdraw(IERC20(lst).balanceOf(address(splitter)), _account);
        }

        --- SKIP ---
    }
```
