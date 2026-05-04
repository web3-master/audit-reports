## Title
Unclaimed GearboxV3 Strategy Rewards Can Become Temporarily Inaccessible

## Summary
Reward tokens accrued in a GearboxV3 strategy may become temporarily inaccessible if the strategy is deactivated before rewards are claimed. This occurs due to a lack of reward-handling logic during the deactivation process.

## Vulnerability Detail
Under the current implementation, strategy rewards can only be claimed from active strategies by the FUNDS_OPERATOR:
```solidity
File: FundsFacet.sol
317:     function claimStrategyRewards(uint256 index) external notPaused onlyRole(LibRoles.FUNDS_OPERATOR) {
318:         LibManagement.ManagementStorage storage sM = LibManagement._getManagementStorage();
319:         sM.activeStrategies[index].adapter.functionDelegateCall(
320:             abi.encodeWithSelector(IStrategyBase.claimRewards.selector, sM.activeStrategies[index].supplement)
321:         );
322:     }
```

However, strategies can be deactivated by the QUEUES_OPERATOR without ensuring that all pending rewards have been claimed:
```solidity
File: ManagementFacet.sol
129:     function deactivateStrategy(uint256 index, uint256[] calldata depositQueue_, uint256[] calldata withdrawQueue_)
130:         external
131:         notPaused
132:         onlyRole(LibRoles.QUEUES_OPERATOR)
133:     {
134:         LibManagement.ManagementStorage storage sM = LibManagement._getManagementStorage();
135:         StrategyData memory strategy = sM.activeStrategies[index];
136:         bytes32 strategyId = _getStrategyId(strategy);
137:         require(LibManagement._strategyAssets(index) == 0, LibErrors.StrategyNotEmpty());
138:         emit LibEvents.DeactivateStrategy(strategy.adapter, strategy.supplement);
139:         sM.strategyIsActive[strategyId] = false;
140:         sM.activeStrategies[index].adapter.functionDelegateCall(
141:             abi.encodeWithSelector(IStrategyBase.onRemove.selector, sM.activeStrategies[index].supplement)
142:         );
143:         sM.activeStrategies[index] = sM.activeStrategies[sM.activeStrategies.length - 1];
144:         sM.activeStrategies.pop();
145:         _updateDepositQueue(sM, depositQueue_);
146:         _updateWithdrawQueue(sM, withdrawQueue_);
147:     }
```
The deactivation logic only verifies that the strategy holds no remaining assets, but it does not account for unclaimed reward tokens. 

As a result:

* A strategy can be deactivated while rewards are still pending.
* Once removed from activeStrategies, the FUNDS_OPERATOR can no longer invoke claimStrategyRewards.
* Consequently, the rewards remain locked within the strategy contract.

Although reactivating the same strategy may restore access to the rewards, this depends on coordination between roles (QUEUES_OPERATOR vs FUNDS_OPERATOR) and cannot be guaranteed in practice.

## Root Cause

The protocol does not enforce reward settlement (claiming) prior to strategy deactivation, nor does it provide a mechanism to claim rewards from inactive strategies.

## Impact
* Temporary Loss of Yield:
Accrued rewards may become inaccessible for an indefinite period.
* Operational Dependency Risk:
Recovery of rewards depends on reactivation by the QUEUES_OPERATOR, which may not align with the FUNDS_OPERATOR’s intentions.
* Accounting Inconsistency:
Reported strategy performance and realized yield may be understated due to unclaimed rewards.

## Code Snippet
https://github.com/YieldLayer/yelay-lite/blob/e48cc7d17099fafd0a589cbf62345162d9bd3ac5/src/facets/ManagementFacet.sol#L137

## Recommendation
* Enforce reward claiming prior to deactivation:
Automatically call claimRewards within deactivateStrategy, or
Add a requirement that all rewards must be claimed before deactivation.
* Alternatively, allow reward claims from inactive strategies:
Introduce a mechanism to claim rewards even after a strategy has been removed from activeStrategies.
* Consider adding safeguards such as:
Tracking pending rewards
Emitting warnings/events when deactivating with unclaimed rewards

Ensuring proper reward handling during lifecycle transitions will prevent unintended yield loss and improve protocol reliability.
