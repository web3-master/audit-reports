| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-jusdbankstoragesolaccruerate-function-has-an-error-in-calculating-the-trate) | JUSDBankStorage.sol#accrueRate function has an error in calculating the tRate. |
| [M-02](#m-02-fundingsolrequestwithdraw-function-has-an-error) | Funding.sol#requestWithdraw function has an error. |


# [M-01] JUSDBankStorage.sol#accrueRate function has an error in calculating the tRate.
## Summary
JUSDBankStorage.sol#accrueRate function calculates the value of tRate larger than the right value.
Thus the borrowers of JUSDBank will lose more JUSD tokens when repaying or liquidating.

## Vulnerability Detail
JUSDBankStorage.sol#accrueRate function and getTRate function are the following.
```solidity
    function accrueRate() public {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp == lastUpdateTimestamp) {
            return;
        }
        uint256 timeDifference = block.timestamp - uint256(lastUpdateTimestamp);
59:     tRate = tRate.decimalMul((timeDifference * borrowFeeRate) / Types.SECONDS_PER_YEAR + 1e18);
        lastUpdateTimestamp = currentTimestamp;
    }

    function getTRate() public view returns (uint256) {
65:     uint256 timeDifference = block.timestamp - uint256(lastUpdateTimestamp);
        return tRate + (borrowFeeRate * timeDifference) / Types.SECONDS_PER_YEAR;
    }
```
As can be seen, the calculation formula for tRate in L59 of accrueRate function differs with L65 of getTRate function.
When tRate = 1e18, the formula of L59 is equal to L65.
JUSDBank.sol#L39 is following.
```solidity
        tRate = Types.ONE;
```
That is, since the initial value of tRate is 1e18 and it increases by time, tRate > 1e18 will be always hold true.
When tRate > 1e18, the value of L59 will be larger than L65 as follows.
```solidity
    tRateInL59 = tRate.decimalMul((timeDifference * borrowFeeRate) / Types.SECONDS_PER_YEAR + 1e18)
          = tRate.decimalMul((timeDifference * borrowFeeRate) / Types.SECONDS_PER_YEAR) + tRate.decmialMul(1e18)
          = tRate * (timeDifference * borrowFeeRate) / Types.SECONDS_PER_YEAR / 1e18 + tRate * 1e18 / 1e18
          > (timeDifference * borrowFeeRate) / Types.SECONDS_PER_YEAR + tRate = tRateInL65
```
Since tRate > 1e18 increases by time, the difference of two values will be larger and larger.
Since borrowRate is the increase amount of tRate in a year, the L65 of getTRate is right but not for L59 of accrueRate function.

## Impact
accrueRate function calculates the value of tRate larger than the right value.
accrueRate function is called from borrow, repay and liquidate function of JUSDBank.sol.
Thus borrowers will lose more JUSD tokens when repaying or liquidating.
As tRate > 1e18 continues to increases, the deviation of calculation becomes larger and larger.

## Code Snippet
https://github.com/sherlock-audit/2023-12-jojo-exchange-update/blob/main/smart-contract-EVM/src/JUSDBankStorage.sol#L59

## Tool used
Manual Review

## Recommendation
Modify JUSDBankStorage.sol#accrueRate function as follows.
```solidity
    function accrueRate() public {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp == lastUpdateTimestamp) {
            return;
        }
--      uint256 timeDifference = block.timestamp - uint256(lastUpdateTimestamp);
--      tRate = tRate.decimalMul((timeDifference * borrowFeeRate) / Types.SECONDS_PER_YEAR + 1e18);
++      tRate = getTRate();
        lastUpdateTimestamp = currentTimestamp;
    }
```



# [M-02] Funding.sol#requestWithdraw function has an error.

## Summary
Funding.sol#requestWithdraw function set pending withdrawal flag for msg.sender instead of from.
Since the purpose of the function is to withdraw tokens from user from, this causes unexpected errors.

## Vulnerability Detail
Funding.sol#requestWithdraw and executeWithdraw functions are the following.
```solidity
    function requestWithdraw(
        Types.State storage state,
        address from,
        uint256 primaryAmount,
        uint256 secondaryAmount
    )
        external
    {
        require(isWithdrawValid(state, msg.sender, from, primaryAmount, secondaryAmount), Errors.WITHDRAW_INVALID);
78:     state.pendingPrimaryWithdraw[msg.sender] = primaryAmount;
79:     state.pendingSecondaryWithdraw[msg.sender] = secondaryAmount;
80:     state.withdrawExecutionTimestamp[msg.sender] = block.timestamp + state.withdrawTimeLock;
        emit RequestWithdraw(msg.sender, primaryAmount, secondaryAmount, state.withdrawExecutionTimestamp[msg.sender]);
    }

    function executeWithdraw(
        Types.State storage state,
        address from,
        address to,
        bool isInternal,
        bytes memory param
    )
        external
    {
93:     require(state.withdrawExecutionTimestamp[from] <= block.timestamp, Errors.WITHDRAW_PENDING);
94:     uint256 primaryAmount = state.pendingPrimaryWithdraw[from];
95:     uint256 secondaryAmount = state.pendingSecondaryWithdraw[from];
        require(isWithdrawValid(state, msg.sender, from, primaryAmount, secondaryAmount), Errors.WITHDRAW_INVALID);
        state.pendingPrimaryWithdraw[from] = 0;
        state.pendingSecondaryWithdraw[from] = 0;
        // No need to change withdrawExecutionTimestamp, because we set pending
        // withdraw amount to 0.
        _withdraw(state, msg.sender, from, to, primaryAmount, secondaryAmount, isInternal, param);
    }
```
L78-80 of requestWithdraw function registers the amount of tokens to withdraw and the timestamp for the address msg.sender.
But L93-95 of executeWithdraw function get the amount of tokens and timestamp which are registered to address from.
In all of two functions, from is the user to withdraw tokens from and msg.sender is the operator (spender) of withdrawal.
Thus in the case that from and msg.sender differs, the regular pending withdrawal is impossible and also the irregular pending withdrawal may arise.

Example of regular pending withdrawal:

Suppose that operator1 tries to withdraw tokens from user1.
operator1 calls requestWithdraw function with parameter from=user1.
In the requestWithdraw function, it will be msg.sender=operator1.
Thus the values of pendingPrimaryWithdraw[operator1], pendingSecondaryWithdraw[operator1] and withdrawExecutionTimestamp[operator1] are set.
After withdrawTimeLock seconds elapsed, the operator1 calls executeWithdraw function with from=user1.
Since withdrawExecutionTimestamp[user1]=0 in L93, executeWithdraw function will be reverted.
Example of irregular pending withdrawal:

Suppose that user2 is the operator of user1 and operator1 is the one of user2.
user2 calls requestWindow function with from=user1.
In requestWithdraw function, the values of pendingPrimaryWithdraw[user2], pendingSecondaryWithdraw[user2] and withdrawExecutionTimestamp[user2] are set.
After withdrawTimeLock seconds elapsed, operator1 calls executeWithdraw function with from=user2.
Even though operator1 never called requestWithdraw function with from=user2, but in L93-94 primaryAmount > 0 and secondaryAmount > 0 holds true and executeWithdraw function will succeed.
## Impact
The regular pending withdrawal from user by operator (!=user) will be impossible and the irregular pending withdrawal may arise.

## Code Snippet
https://github.com/sherlock-audit/2023-12-jojo-exchange-update/blob/main/smart-contract-EVM/src/libraries/Funding.sol#L78-L80

## Tool used
Manual Review

## Recommendation
Modify Funding.sol#requestWithdraw function as follows.
```solidity
    function requestWithdraw(
        Types.State storage state,
        address from,
        uint256 primaryAmount,
        uint256 secondaryAmount
    )
        external
    {
        require(isWithdrawValid(state, msg.sender, from, primaryAmount, secondaryAmount), Errors.WITHDRAW_INVALID);
--      state.pendingPrimaryWithdraw[msg.sender] = primaryAmount;
--      state.pendingSecondaryWithdraw[msg.sender] = secondaryAmount;
--      state.withdrawExecutionTimestamp[msg.sender] = block.timestamp + state.withdrawTimeLock;
--      emit RequestWithdraw(msg.sender, primaryAmount, secondaryAmount, state.withdrawExecutionTimestamp[msg.sender]);
++      state.pendingPrimaryWithdraw[from] = primaryAmount;
++      state.pendingSecondaryWithdraw[from] = secondaryAmount;
++      state.withdrawExecutionTimestamp[from] = block.timestamp + state.withdrawTimeLock;
++      emit RequestWithdraw(from, primaryAmount, secondaryAmount, state.withdrawExecutionTimestamp[from]);
    }
```