| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-incorrect-withdraw-queue-balance-in-tvl-calculation) | Incorrect withdraw queue balance in TVL calculation |
| [M-01](#m-01-lack-of-slippage-and-deadline-during-withdraw-and-deposit) | Lack of slippage and deadline during withdraw and deposit |
| [M-02](#m-02-deposits-will-always-revert-if-the-amount-being-deposited-is-less-than-the-buffertofill-value) | Deposits will always revert if the amount being deposited is less than the bufferToFill value |

# [H-01] Incorrect withdraw queue balance in TVL calculation
## Impact
When calculating TVL it iterates over all the operator delegators and inside it iterates over all the collateral tokens. 
```solidity
    for (uint256 i = 0; i < odLength; ) {
        ...
        // Iterate through the tokens and get the value of each
        uint256 tokenLength = collateralTokens.length;
        for (uint256 j = 0; j < tokenLength; ) {
            ...
            // record token value of withdraw queue
            if (!withdrawQueueTokenBalanceRecorded) {
                totalWithdrawalQueueValue += renzoOracle.lookupTokenValue(
                    collateralTokens[i],
                    collateralTokens[j].balanceOf(withdrawQueue)
                );
            }
            unchecked {
                ++j;
            }
        }
        ...
        unchecked {
            ++i;
        }
    }
```
However, the balance of withdrawQueue is incorrectly fetched, specifically this line:
```solidity
    totalWithdrawalQueueValue += renzoOracle.lookupTokenValue(
        collateralTokens[i],
        collateralTokens[j].balanceOf(withdrawQueue)
    );
```
It uses an incorrect index of the outer loop i to access the collateralTokens. i belongs to the operator delegator index, thus the returned value will not represent the real value of the token. For instance, if there is 1 OD and 3 collateral tokens, it will add the balance of the first token 3 times and neglect the other 2 tokens. If there are more ODs than collateral tokens, the the execution will revert (index out of bounds).

This calculation impacts the TVL which is the essential data when calculating mint/redeem and other critical values. A miscalculation in TVL could have devastating results.

## Proof of Concept
A simplified version of the function to showcase that the same token (in this case address(1)) is emitted multiple times and other tokens are untouched:
```solidity
contract RestakeManager {
    address[] public operatorDelegators;
    address[] public collateralTokens;
    event CollateralTokenLookup(address token);
    constructor() {
        operatorDelegators.push(msg.sender);
        collateralTokens.push(address(1));
        collateralTokens.push(address(2));
        collateralTokens.push(address(3));
    }
    function calculateTVLs() public {
        // Iterate through the ODs
        uint256 odLength = operatorDelegators.length;
        for (uint256 i = 0; i < odLength; ) {
            // Iterate through the tokens and get the value of each
            uint256 tokenLength = collateralTokens.length;
            for (uint256 j = 0; j < tokenLength; ) {
                emit CollateralTokenLookup(collateralTokens[i]);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
```

## Tool used
Manual Review

## Recommended Mitigation Steps
Change to collateralTokens[j].

# [M-01] Lack of slippage and deadline during withdraw and deposit
## Impact
When users call withdraw() to burn their ezETH and receive redemption amount in return, there is no provision to provide any slippage & deadline params. This is necessary because the withdraw() function uses values from the oracle and the users may get a worse rate than they planned for.

Additionally, the withdraw() function also makes use of calls to calculateTVLs() to fetch the current totalTVL. The calculateTVLs() function makes use of oracle prices too. Note that though there is a MAX_TIME_WINDOW inside these oracle lookup functions, the users are forced to rely on this hardcoded value & can’t provide a deadline from their side.
These facts are apart from the consideration that users’ call to withdraw() could very well be unintentionally/intentionally front-run which causes a drop in totalTVL. 

In all of these situations, users receive less than they bargained for and, hence, a slippage and deadline parameter is necessary.

Similar issue can be seen inside deposit() and depositETH().

## Tool used
Manual Review

## Recommended Mitigation Steps
Allow users to pass a slippage tolerance value and a deadline parameter while calling these functions.

# [M-02] Deposits will always revert if the amount being deposited is less than the bufferToFill value
## Impact
Severity: Medium. User deposits will always revert if the amount being deposited is less than the bufferToFill value.

Likelihood: High. Depending on the set amount for the withdrawal buffer, this could be a common occurrence.

## Proof of Concept
The deposit function in the RestakeManager contract enables users to deposit ERC20 whitelisted collateral tokens into the protocol. It first checks the withdrawal buffer and fills it up using some or all of the deposited amount if it is below the buffer target. The remaining amount is then transferred to the operator delegator and deposited into EigenLayer.
The current issue with this implementation is that if the amount deposited is less than bufferToFill, the full amount will be used to fill the withdrawal buffer, leaving the amount value as zero.

```solidity
function deposit(IERC20 _collateralToken, uint256 _amount, uint256 _referralId) public nonReentrant notPaused {
        // Verify collateral token is in the list - call will revert if not found
        uint256 tokenIndex = getCollateralTokenIndex(_collateralToken);
	...
        // Check the withdraw buffer and fill if below buffer target
        uint256 bufferToFill = depositQueue.withdrawQueue().getBufferDeficit(address(_collateralToken));
        if (bufferToFill > 0) {
            bufferToFill = (_amount <= bufferToFill) ? _amount : bufferToFill;
            // update amount to send to the operator Delegator
            _amount -= bufferToFill;
            // safe Approve for depositQueue
            _collateralToken.safeApprove(address(depositQueue), bufferToFill);
            // fill Withdraw Buffer via depositQueue
            depositQueue.fillERC20withdrawBuffer(address(_collateralToken), bufferToFill);
        }
        // Approve the tokens to the operator delegator
        _collateralToken.safeApprove(address(operatorDelegator), _amount);
        // Call deposit on the operator delegator
        operatorDelegator.deposit(_collateralToken, _amount);
        ...
    }
```

Subsequently, the function will approve the zero amount to the operator delegator and call deposit on the operator delegator. However, as seen in the OperatorDelegator contract’s deposit function below, a zero deposit will be reverted.

```solidity
  function deposit(IERC20 token, uint256 tokenAmount)
        external
        nonReentrant
        onlyRestakeManager
        returns (uint256 shares)
    {
        if (address(tokenStrategyMapping[token]) == address(0x0) || tokenAmount == 0) {
            revert InvalidZeroInput();
        }
        // Move the tokens into this contract
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        return _deposit(token, tokenAmount);
    }
```

Severity: Medium. User deposits will always revert if the amount being deposited is less than the bufferToFill value.

Likelihood: High. Depending on the set amount for the withdrawal buffer, this could be a common occurrence.

## Tool used
Manual Review

## Recommended Mitigation Steps
To address this issue, the deposit function can be modified to only approve the amount to the operator delegator and call deposit on the operator delegator if the amount is greater than zero.
```solidity
    function deposit(IERC20 _collateralToken, uint256 _amount, uint256 _referralId) public nonReentrant notPaused {
        // Verify collateral token is in the list - call will revert if not found
        uint256 tokenIndex = getCollateralTokenIndex(_collateralToken);
	...
        // Check the withdraw buffer and fill if below buffer target
        uint256 bufferToFill = depositQueue.withdrawQueue().getBufferDeficit(address(_collateralToken));
        if (bufferToFill > 0) {
            bufferToFill = (_amount <= bufferToFill) ? _amount : bufferToFill;
            // update amount to send to the operator Delegator
            _amount -= bufferToFill;
            // safe Approve for depositQueue
            _collateralToken.safeApprove(address(depositQueue), bufferToFill);
            // fill Withdraw Buffer via depositQueue
            depositQueue.fillERC20withdrawBuffer(address(_collateralToken), bufferToFill);
        }
	if (_amount > 0) { // ADD HERE
            // Transfer the tokens to the operator delegator
            _collateralToken.safeApprove(address(operatorDelegator), _amount);
            // Call deposit on the operator delegator
            operatorDelegator.deposit(_collateralToken, _amount);
        }
        ...
    }
```