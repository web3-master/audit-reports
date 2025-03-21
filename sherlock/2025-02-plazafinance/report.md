| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-rounding-error-of-redeemamount-is-big) | Rounding error of `redeemAmount` is big. |
| [M-02](#m-02-user-will-lose-balancerpooltoken-and-it-is-freezed-to-balancerrouter) | User will lose `balancerPoolToken` and it is freezed to `BalancerRouter`. |


# [M-01] Rounding error of `redeemAmount` is big.
## Summary
Incorrect calculation of `redeemRate` will cause big error of redeemAmount as a user loses funds when redeem from `Pool`. 

## Vulnerability Detail
- In `Pool.sol:498`, there is calculation of `redeemRate` used for redeemAmount with big error.
```solidity
    // Calculate the redeem rate based on the collateral level and token type
    uint256 redeemRate;
    if (collateralLevel <= COLLATERAL_THRESHOLD) {
      redeemRate = ((tvl * multiplier) / assetSupply);
    } else if (tokenType == TokenType.LEVERAGE) {
498   redeemRate = ((tvl - (bondSupply * BOND_TARGET_PRICE)) / assetSupply) * PRECISION;
    } else {
      redeemRate = BOND_TARGET_PRICE * PRECISION;
    }
    
    // Calculate and return the final redeem amount
504 return ((depositAmount * redeemRate).fromBaseUnit(oracleDecimals) / ethPrice) / PRECISION;
```
As we can see on L498, redeemRate is calculated with big rounding error. Average error of redeemRate is `PRECISION / 2 = 0.5e6`.   
This error is expanded by `depositAmount` on L504.


## Impact
Users suffer loss of reserveToken when redeem from Pool because of big rounding error.

## Tool used
Manual Review

## Recommendation
`Pool.sol:498` has to be modified as follows.
```solidity
--  redeemRate = ((tvl - (bondSupply * BOND_TARGET_PRICE)) / assetSupply) * PRECISION;
++  redeemRate = (tvl - (bondSupply * BOND_TARGET_PRICE)) * PRECISION / assetSupply;
``` 

# [M-02] User will lose `balancerPoolToken` and it is freezed to `BalancerRouter`.
## Summary
`BalancerRouter#joinBalancerAndPredeposit()` function does not refund remained `balancerPoolToken` to the user.  


## Vulnerability Detail
`Predeposit.sol#_deposit()` function is as follows.
```solidity
  function _deposit(uint256 amount, address onBehalfOf) private checkDepositStarted checkDepositNotEnded {
    if (reserveAmount >= reserveCap) revert DepositCapReached();

    address recipient = onBehalfOf == address(0) ? msg.sender : onBehalfOf;

    // if user would like to put more than available in cap, fill the rest up to cap and add that to reserves
    if (reserveAmount + amount >= reserveCap) {
@>    amount = reserveCap - reserveAmount;
    }

    balances[recipient] += amount;
    reserveAmount += amount;

@>  IERC20(params.reserveToken).safeTransferFrom(msg.sender, address(this), amount);

    emit Deposited(recipient, amount);
  }
```
As we can see above, amount can be overrided because of `reserveCap`.
In this case, the amount of `reserveToken` which is transfered is less than the amount passed as parameter.   

On the other hand, `BalancerRounter.sol#joinBalancerAndPredeposit()` function is as follows.
```solidity
    function joinBalancerAndPredeposit(
        bytes32 balancerPoolId,
        address _predeposit,
        IAsset[] memory assets,
        uint256[] memory maxAmountsIn,
        bytes memory userData
    ) external nonReentrant returns (uint256) {
        // Step 1: Join Balancer Pool
        uint256 balancerPoolTokenReceived = joinBalancerPool(balancerPoolId, assets, maxAmountsIn, userData);

        // Step 2: Approve balancerPoolToken for PreDeposit
        balancerPoolToken.safeIncreaseAllowance(_predeposit, balancerPoolTokenReceived);

        // Step 3: Deposit to PreDeposit
        PreDeposit(_predeposit).deposit(balancerPoolTokenReceived, msg.sender);

        return balancerPoolTokenReceived;
    }
```
As we can see above, remained amount of `balancerPoolToken` after `Predeposit.deposit` is not refunded to the user.


## Impact
Users can lose funds when `reserveCap` is reached in Predeposit.

## Tool used
Manual Review

## Recommendation
`BalancerRounter.sol#joinBalancerAndPredeposit()` function has to be modified as follows.
```solidity
    function joinBalancerAndPredeposit(
        bytes32 balancerPoolId,
        address _predeposit,
        IAsset[] memory assets,
        uint256[] memory maxAmountsIn,
        bytes memory userData
    ) external nonReentrant returns (uint256) {
        // Step 1: Join Balancer Pool
        uint256 balancerPoolTokenReceived = joinBalancerPool(balancerPoolId, assets, maxAmountsIn, userData);

        // Step 2: Approve balancerPoolToken for PreDeposit
        balancerPoolToken.safeIncreaseAllowance(_predeposit, balancerPoolTokenReceived);

        // Step 3: Deposit to PreDeposit
++      uint256 balancerPoolTokenBalanceBefore = balancerPoolToken.balanceOf(address(this));
        PreDeposit(_predeposit).deposit(balancerPoolTokenReceived, msg.sender);
++      uint256 balancerPoolTokenBalanceAfter = balancerPoolToken.balanceOf(address(this));
++      uint256 remainedAmount = balancerPoolTokenReceived - (balancerPoolTokenBalanceBefore - balancerPoolTokenBalanceAfter);
++      balancerPoolToken.safeTransfer(msg.sender, remainedAmount);

        return balancerPoolTokenReceived;
    }
```