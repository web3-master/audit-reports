| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-non-functional-vote-if-there-is-one-bribe-rewarder-for-this-pool) | Non-functional vote() if there is one bribe rewarder for this pool |
| [H-02](#h-02-wrong-call-order-for-settoppoolidswithweights-resulting-in-wrong-distribution-of-rewards) | Wrong call order for setTopPoolIdsWithWeights, resulting in wrong distribution of rewards |
| [H-03](#h-03-voting-does-not-take-into-account-end-of-staking-lock-period) | Voting does not take into account end of staking lock period |
| [H-04](#h-04-funds-unutilized-for-rewards-may-get-stranded-in-briberewarder) | Funds unutilized for rewards may get stranded in BribeRewarder |
| [M-01](#m-01-new-staking-positions-still-gets-the-full-reward-amount-as-with-old-stakings-diluting-rewards-for-old-stakers) | New staking positions still gets the full reward amount as with old stakings, diluting rewards for old stakers |
| [M-02](#m-02-mlumstakingaddtoposition-should-assing-the-amount-multiplier-based-on-the-new-lock-duration-instead-of-initial-lock-duration) | MlumStaking::addToPosition should assing the amount multiplier based on the new lock duration instead of initial lock duration. |
| [M-03](#m-03-adding-genuine-briberewarder-contract-instances-to-a-pool-in-order-to-incentivize-users-can-be-dosed) | Adding genuine BribeRewarder contract instances to a pool in order to incentivize users can be DOSed |
| [M-04](#m-04-inconsistent-check-in-harvestpositionsto-function) | Inconsistent check in harvestPositionsTo() function |
| [M-05](#m-05-lack-of-support-for-fee-on-transfer-rebasing-and-tokens-with-balance-modifications-outside-of-transfers) | Lack of support for fee on transfer, rebasing and tokens with balance modifications outside of transfers. |


# [H-01] Non-functional vote() if there is one bribe rewarder for this pool
## Summary
Permission check in BribeRewarder::deposit(), this will lead to vote() function cannot work if voted pool has any bribe rewarder.

## Vulnerability Detail
When people vote for one pool, there may be some extra rewards provided by bribe rewarders. When users vote for one pool with some bribe rewarders, voter contract will call bribe rewarder's deposit function. However, in bribe rewarder's deposit() function, there is one security check, the caller should be the NFT's owner, which is wrong. Because the voter contract call bribe rewarder's deposit(), msg.sender is voter contract, not the owner of NFT.
This will block all vote() transactions if this votes pool has any bribe rewarder.
```solidity
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata deltaAmounts) external {
        ......
        IVoterPoolValidator validator = _poolValidator;
        for (uint256 i = 0; i < pools.length; ++i) {
          ......
            uint256 deltaAmount = deltaAmounts[i];
            // per user account
            _userVotes[tokenId][pool] += deltaAmount;
            // per pool account
            _poolVotesPerPeriod[currentPeriodId][pool] += deltaAmount;
            // @audit_fp should we clean the _votes in one new vote period ,no extra side effect found
            if (_votes.contains(pool)) {
                _votes.set(pool, _votes.get(pool) + deltaAmount);
            } else {
                _votes.set(pool, deltaAmount);
            }
            // bribe reward will record voter
@==>   _notifyBribes(_currentVotingPeriodId, pool, tokenId, deltaAmount); // msg.sender, deltaAmount);
        }
        ......
    }
    function _notifyBribes(uint256 periodId, address pool, uint256 tokenId, uint256 deltaAmount) private {
        IBribeRewarder[] storage rewarders = _bribesPerPriod[periodId][pool];
        for (uint256 i = 0; i < rewarders.length; ++i) {
            if (address(rewarders[i]) != address(0)) {
                // bribe rewarder will record vote.
                rewarders[i].deposit(periodId, tokenId, deltaAmount);
                _userBribesPerPeriod[periodId][tokenId].push(rewarders[i]);
            }
        }
    }
    function deposit(uint256 periodId, uint256 tokenId, uint256 deltaAmount) public onlyVoter {
        _modify(periodId, tokenId, deltaAmount.toInt256(), false);

        emit Deposited(periodId, tokenId, _pool(), deltaAmount);
    }
    function _modify(uint256 periodId, uint256 tokenId, int256 deltaAmount, bool isPayOutReward)
        private
        returns (uint256 rewardAmount)
    {
        // If you're not the NFT owner, you cannot claim
        if (!IVoter(_caller).ownerOf(tokenId, msg.sender)) {
            revert BribeRewarder__NotOwner();
        }
```
Poc
When alice tries to vote for one pool with one bribe rewarder, the transaction will be reverted with the reason 'BribeRewarder__NotOwner'
```javascript
    function testPocVotedRevert() public {
        vm.startPrank(DEV);
        ERC20Mock(address(_rewardToken)).mint(address(ALICE), 100e18);
        vm.stopPrank();
        vm.startPrank(ALICE);
        rewarder1 = BribeRewarder(payable(address(factory.createBribeRewarder(_rewardToken, pool))));
        ERC20Mock(address(_rewardToken)).approve(address(rewarder1), 20e18);
        // Register
        //_voter.onRegister();
        rewarder1.fundAndBribe(1, 2, 10e18);
        vm.stopPrank();
        // join and register with voter
        // Create position at first
        vm.startPrank(ALICE);
        // stake in mlum to get one NFT
        _createPosition(ALICE);

        vm.prank(DEV);
        _voter.startNewVotingPeriod();
        vm.startPrank(ALICE);
        _voter.vote(1, _getDummyPools(), _getDeltaAmounts());
        // withdraw this NFT
        vm.stopPrank();
    }
```

## Impact
vote() will be blocked for pools which owns any bribe rewarders.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/rewarders/BribeRewarder.sol#L143-L147
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/rewarders/BribeRewarder.sol#L260-L269

## Tool used
Manual Review

## Recommendation
This security check should be valid in claim() function. We should remove this check from deposit().

# [H-02] Wrong call order for setTopPoolIdsWithWeights, resulting in wrong distribution of rewards
## Summary
Per the Sherlock rules:

If the protocol team provides specific information in the README or CODE COMMENTS, that information stands above all judging rules.

The Masterchef contract allows people to stake an admin-selected token in farms to earn LUM rewards. Each two weeks, MLUM stakers can vote on their favorite pools, and the top pools will earn LUM emissions according to the votes. Admin has to call setTopPoolIdsWithWeights to set those votes and weights to set the reward emission for the next two weeks.

Per the documented call order for setTopPoolIdsWithWeights:
```solidity
/**
* @dev Set farm pools with their weight;
*
* WARNING:
* Caller is responsible to updateAll oldPids on masterChef before using this function
* and also call updateAll for the new pids after.
*
* @param pids - list of pids
* @param weights - list of weights
*/
```
We show that this call order is wrong, and will result in wrong rewards distribution.

## Vulnerability Detail
There is a global parameter lumPerSecond, set by the admin. Whenever updateAll is called for a set of pools:

Let the total weight of all votes across all top pools be totalWeight
Let the current weight of a pool Pid be weightPid. This weight can be set by the admin using setTopPoolIdsWithWeights
Pool Pid will earn totalLumRewardForPid = (lumPerSecond * weightPid / totalWeight) * (elapsed_time), i.e. each second it earns lumPerSecond times its percentage of voted weight weightPid across the total weight all top pools totalWeight.
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/MasterchefV2.sol#L522-L525

Now, the function updateAll does the following:

For each pool, fetch its weight and calculate its totalLumRewardForPid since last update
Mint that calculated amount of LUM
updateAccDebtPerShare i.e. distribute rewards since the last updated time
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/MasterchefV2.sol#L526-L528

Per the code comments, the admin is responsible for calling updateAll() on the old pools before calling setTopPoolIdsWithWeights() for the new pools, and then calling updateAll() on the new pools.

We claim that, using this call order, a pool will be wrongly updated if it's within the set newPid but not in oldPid, and the functions are called with this order. Take this example.

## PoC
Let LUM per second = 1. We assume all farms were created and registered at time 0:

At time 1000: there are two pools, A and B making it into the top pools. Weight = 1 both.
updateAll for oldPid. There are no old Pids
setTopPoolIdsWithWeights: Pool A and pool B now have weight = 1.
updateAll for newPid (A and B). 1000 seconds passed, each pool accrued 500 LUM for having 50% weight despite just making it into the top weighted pools
At time 2000: a new pool C makes it into the pool, while pool B is no longer in the top. Weight = 1 both.
updateAll for oldPid (A and B).
For pool A, 1000 seconds passed. It earns 500 LUM
For pool B, 1000 seconds passed. It earns 500 LUM
setTopPoolIdsWithWeights: Pool A and pool C now have weight = 1.
updateAll for newPid (A and C).
For pool A, 0 seconds passed. It earns 0 LUM
For pool C, 2000 seconds passed. It earns 1000 LUM
The end result is that, at time 2000:

Pool A accrued 1000 LUM
Pool B accrued 1000 LUM
Pool C accrued 1000 LUM
Where the correct result should be:

Pool A accrued 500 LUM, it was in the top pools in time 1000 to 2000
Pool B accrued 500 LUM, it was in the top pools in time 1000 to 2000
Pool C accrued 0 LUM, it only started being in the top pools from timestamp 2000
In total, 3000 LUM has been distributed from timestamps 1000 to 2000, despite the emission rate should be 1 LUM per second. In fact, LUM has been wrongly distributed since timestamp 1000, as both pool A and B never made it into the top pools but still immediately accrued 500 LUM each.

This is because if a pool is included in an updateAll call after its weight has been set, its last updated timestamp is still in the past. Therefore when updateAll is called, the new weights are applied across the entire interval since it was last updated (i.e. a far point in the past).

## Impact
Pools that have just made it into the top pools will have already accrued rewards for time intervals it wasn't in the top pools. Rewards are thus severely inflated.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/Voter.sol#L250-L260

## Tool used
Manual Review

## Recommendation
All of the pools (oldPids and newPids) should be updated, only then weights should be applied.

In other words, the correct call order should be:

* updateAll should be called for all pools within oldPid or newPid.
* setTopPoolIdsWithWeights should then be called.

Additionally, we think it might be better that setTopPoolIdsWithWeights itself should just call updateAll for all (old and new) pools before updating the pool weights, or at least validate that their last updated timestamp is sufficiently fresh.

# [H-03] Voting does not take into account end of staking lock period
## Summary
The protocol allows to vote in Voter contract by means of staked position in MlumStaking. To vote, user must have staking position with certain properties. However, the voting does not implement check against invariant that the remaining lock period needs to be longer then the epoch time to be eligible for voting. Thus, it is possible to vote with stale voting position. Additionally, if position's lock period finishes inside of the voting epoch it is possible to vote, withdraw staked position, stake and vote again in the same epoch. Thus, voting twice with the same stake amount is possible from time to time. Ultimately, the invariant that voting once with same balance is only allowed is broken as well.
The voting will decide which pools receive LUM emissions and how much.

## Vulnerability Detail
The documentation states that:

Who is allowed to vote
Only valid Magic LUM Staking Position are allowed to vote. The overall lock needs to be longer then 90 days and the remaining lock period needs to be longer then the epoch time.

User who staked position in the MlumStaking contract gets NFT minted as a proof of stake with properties describing this stake. Then, user can use that staking position to vote for pools by means of vote() in Voter contract. The vote() functions checks if initialLockDuration is higher than _minimumLockTime and lockDuration is higher than _periodDuration to process further. However, it does not check whether the remaining lock period is longer than the epoch time.
Thus, it is possible to vote with stale staking position.
Also, current implementation makes renewLockPosition and extendLockPosition functions useless.
```solidity
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata deltaAmounts) external {
        if (pools.length != deltaAmounts.length) revert IVoter__InvalidLength();

        // check voting started
        if (!_votingStarted()) revert IVoter_VotingPeriodNotStarted();
        if (_votingEnded()) revert IVoter_VotingPeriodEnded();

        // check ownership of tokenId
        if (_mlumStaking.ownerOf(tokenId) != msg.sender) {
            revert IVoter__NotOwner();
        }

        uint256 currentPeriodId = _currentVotingPeriodId;
        // check if alreay voted
        if (_hasVotedInPeriod[currentPeriodId][tokenId]) {
            revert IVoter__AlreadyVoted();
        }

        // check if _minimumLockTime >= initialLockDuration and it is locked
        if (_mlumStaking.getStakingPosition(tokenId).initialLockDuration < _minimumLockTime) {
            revert IVoter__InsufficientLockTime();
        }
        if (_mlumStaking.getStakingPosition(tokenId).lockDuration < _periodDuration) {
            revert IVoter__InsufficientLockTime();
        }

        uint256 votingPower = _mlumStaking.getStakingPosition(tokenId).amountWithMultiplier;

        // check if deltaAmounts > votingPower
        uint256 totalUserVotes;
        for (uint256 i = 0; i < pools.length; ++i) {
            totalUserVotes += deltaAmounts[i];
        }

        if (totalUserVotes > votingPower) {
            revert IVoter__InsufficientVotingPower();
        }

        IVoterPoolValidator validator = _poolValidator;

        for (uint256 i = 0; i < pools.length; ++i) {
            address pool = pools[i];

            if (address(validator) != address(0) && !validator.isValid(pool)) {
                revert Voter__PoolNotVotable();
            }

            uint256 deltaAmount = deltaAmounts[i];

            _userVotes[tokenId][pool] += deltaAmount;
            _poolVotesPerPeriod[currentPeriodId][pool] += deltaAmount;

            if (_votes.contains(pool)) {
                _votes.set(pool, _votes.get(pool) + deltaAmount);
            } else {
                _votes.set(pool, deltaAmount);
            }

            _notifyBribes(_currentVotingPeriodId, pool, tokenId, deltaAmount); // msg.sender, deltaAmount);
        }

        _totalVotes += totalUserVotes;

        _hasVotedInPeriod[currentPeriodId][tokenId] = true;

        emit Voted(tokenId, currentPeriodId, pools, deltaAmounts);
    }
```
The documentation states that minimum lock period for staking to be eligible for voting is 90 days.
The documentation states that voting for pools occurs biweekly.

Thus, assuming the implementation with configuration presented in the documentation, every 90 days it is possible to vote twice within the same voting epoch by:

* voting,
* withdrawing staked amount,
* creating new position with staking token,
* voting again.

```solidity
    function createPosition(uint256 amount, uint256 lockDuration) external override nonReentrant {
        // no new lock can be set if the pool has been unlocked
        if (isUnlocked()) {
            require(lockDuration == 0, "locks disabled");
        }

        _updatePool();

        // handle tokens with transfer tax
        amount = _transferSupportingFeeOnTransfer(stakedToken, msg.sender, amount);
        require(amount != 0, "zero amount"); // createPosition: amount cannot be null

        // mint NFT position token
        uint256 currentTokenId = _mintNextTokenId(msg.sender);

        // calculate bonuses
        uint256 lockMultiplier = getMultiplierByLockDuration(lockDuration);
        uint256 amountWithMultiplier = amount * (lockMultiplier + 1e4) / 1e4;

        // create position
        _stakingPositions[currentTokenId] = StakingPosition({
            initialLockDuration: lockDuration,
            amount: amount,
            rewardDebt: amountWithMultiplier * (_accRewardsPerShare) / (PRECISION_FACTOR),
            lockDuration: lockDuration,
            startLockTime: _currentBlockTimestamp(),
            lockMultiplier: lockMultiplier,
            amountWithMultiplier: amountWithMultiplier,
            totalMultiplier: lockMultiplier
        });

        // update total lp supply
        _stakedSupply = _stakedSupply + amount;
        _stakedSupplyWithMultiplier = _stakedSupplyWithMultiplier + amountWithMultiplier;

        emit CreatePosition(currentTokenId, amount, lockDuration);
    }
```

## Impact
A user can vote with stale staking position, then withdraw the staking position with any consequences.
Additionally, a user can periodically vote twice with the same balance of staking tokens for the same pool to increase unfairly the chance of the pool being selected for further processing.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/Voter.sol#L172
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/Voter.sol#L175

## Tool used
Manual Review

## Recommendation
It is recommended to enforce the invariant that the remaining lock period must be longer than the epoch time to be eligible for voting.
Additionally, It is recommended to prevent double voting at any time. One of the solution can be to prevent voting within the epoch if staking position was not created before epoch started.

# [H-04] Funds unutilized for rewards may get stranded in BribeRewarder
## Summary
When a bribe provider starts the bribe cycle on a BribeRewarder.sol contract, they are required to fund the contract with the total amount of rewardToken required across all the bribePeriods (enforced by the check here), which is amountPerPeriod x number of bribe periods they want to incentivize.

However if any of these funds remain untilized for reward distribution, they will remain stranded in the contract forever as there is no way to recover tokens.

## Vulnerability Detail
The bribe cycle can be started on a BribeRewarder contract by calling fundAndBribe() or bribe(), where it is checked that the balance of the rewardToken in this contract is at least equal to the amount required to distribute across all defined bribe periods.

total amount required = amountPerPeriod x number of bribe periods briber wants to incentivize.

Lets say X amount of funds is required and the contract has been funded with exactly X.
Now if in any case, the funds do not get utilized, they will remain stuck in the contract forever : as there is no way to sweep these tokens out.

This is possible due to the following reasons :

(1). The full amountPerPeriod will be utilized for distribution even if there is only one voter for the associated poolID in a given period. But if there is no voter, these funds will not be utilized for any other periods too. A pool might not get any voter under normal operations :

* The pool is not in the top pool IDs set on the Voter contract, thus not earning any rewards on the MasterChef, so users might want to vote for the top pools to potentially earn more LUM from there.
* The associated pool might get hacked, or drained, or emptied by LPs : thus no user would want to vote for such a pool after this happens, instead they would go for better incentives on LP swap fees.

(2). Some amount of tokens might remain unutilized even under normal circumstances and actively running bribing periods due to rounding in calculations. An instance of this is possible when calculating total rewards accrued in BribeRewarder._modify => _calculateRewards :

```solidity
    function _calculateRewards(uint256 periodId) internal view returns (uint256) {
        (uint256 startTime, uint256 endTime) = IVoter(_caller).getPeriodStartEndtime(periodId);

        if (endTime == 0 || startTime > block.timestamp) {
            return 0;
        }

        uint256 duration = endTime - startTime;
        uint256 emissionsPerSecond = _amountPerPeriod / duration;

        uint256 lastUpdateTimestamp = _lastUpdateTimestamp;
        uint256 timestamp = block.timestamp > endTime ? endTime : block.timestamp;
        return timestamp > lastUpdateTimestamp ? (timestamp - lastUpdateTimestamp) * emissionsPerSecond : 0;
    }
```
Here emissionsPerSecond = _amountPerPeriod / duration : this could round down leading to some portion of the funds unutilized in the rewards calculations, and will be left out of the rewards for whole of the bribing cycle.

## Impact
Due to the two reasons mentioned above, it is possible that some amount of rewardToken remains stranded in the contract, but there is no way for the bribe provider to recover these tokens.

These funds will be lost permanently, especially in the first case above, the amount would be large.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/rewarders/BribeRewarder.sol#L308

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/rewarders/BaseRewarder.sol#L208

## Tool used
Manual Review

## Recommendation
BribeRewarder.sol should have a method to recover unutilized reward tokens, just like the sweep function in BaseRewarder.sol. This will prevent the permanent loss of funds for the briber.

# [M-01] New staking positions still gets the full reward amount as with old stakings, diluting rewards for old stakers
## Summary
New staking positions still gets the full reward amount as with old stakings, diluting rewards for old stakers. Furthermore, due to the way multipliers are calculated, extremely short stakings are still very effective in stealing long-term stakers' rewards.

## Vulnerability Detail
In the Magic LUM Staking system, users can lock-stake MLUM in exchange for voting power, as well as a share of the protocol revenue. As per the docs:

You can stake and lock your Magic LUM token in the Magic LUM staking pools to benefit from protocol profits. All protocol returns like a part of the trading fees, Fairlaunch listing fees, and NFT trading fees flow into the staking pool in form of USDC.

Rewards are distributed every few days, and you can Claim at any time.

However, when rewards are distributed, new and old staking positions are treated alike, and immediately receive the same rewards as it is distributed.

Thus, anyone can stake MLUM for a short duration as rewards are distributed, and siphon away rewards from long-term stakers. Staking for a few days still gets almost the same multiplier as staking for a year, and the profitability can be calculated and timed by calculating the protocol's revenue using various offchain methods (e.g. watching the total trade volume in each time intervals).

Consider the following scenario:

* Alice stakes 50 MLUM for a year.
* Bob has 50 MLUM but hasn't staked.
* Bob notices that there is a spike in trading activity, and the protocol is gaining a lot of trading volume in a short time (thereby gaining a lot of revenue).
* Bob stakes 50 MLUM for 1 second.
* As soon as the rewards are distributed, Bob can harvest his part immediately.

Note that expired positions, while should not be able to vote, still accrue rewards. Thus Bob can just leave the position there and withdraw whenever he wants to without watching the admin actions. A more sophisticated attack involves front-running the admin reward distribution to siphon rewards, then unstake right away.

## Impact
Staking rewards can be stolen from honest stakers.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/MlumStaking.sol#L354

## Tool used
Manual Review

## Recommendation
When new positions are created, their position should be recorded, but their amount with multipliers should be summed up and queued until the next reward distribution.

When the admin distributes rewards, there should be a function that first updates the pool, then add the queued amounts into staking. That way, newly created positions can still vote, but they do not accrue rewards for the immediate following distribution (only the next one onwards).

One must note down the timestamp that the position was created (as well as the timestamp the rewards were last distributed), so that when the position unstakes, the contract knows whether to burn the unstaked shares from the queued shares pool or the active shares pool.

# [M-02] MlumStaking::addToPosition should assing the amount multiplier based on the new lock duration instead of initial lock duration.
## Summary
There are two separate issues that make necessary to assign the multiplier based on the new lock duration:

## Vulnerability Detail
First, when users add tokens to their position via MlumStaking::addToPosition, the new remaining time for the lock duration is recalculated as the amount-weighted lock duration. However, when the remaining time for an existing deposit is 0, this term is omitted, allowing users to retain the same amount multiplier with a reduced lock time. Consider the following sequence of actions:

Alice creates a position by calling MlumStaking::createPositiondepositing 1 ether and a lock time of 365 days

After the 365 days elapse, Alice adds another 1 ether to her position. The snippet below illustrates how the new lock time for the position is calculated:
```solidity
        uint256 avgDuration = (remainingLockTime *
            position.amount +
            amountToAdd *
            position.initialLockDuration) / (position.amount + amountToAdd);
        position.startLockTime = _currentBlockTimestamp();
        position.lockDuration = avgDuration;

        // lock multiplier stays the same
        position.lockMultiplier = getMultiplierByLockDuration(
            position.initialLockDuration
        );
```
The result will be: (0*1 ether + 1 ether*365 days)/ 2 ether, therefore Alice will need to wait just half a year, while the multiplier remains unchanged.

Second, the missalignment between this function and MlumStaking::renewLockPosition creates an arbitrage opportunity for users, allowing them to reassign the lock multiplier to the initial duration if it is more beneficial. Consider the following scenario:

Alice creates a position with an initial lock duration of 365 days. The multiplier will be 3.
Then after 9 months, the lock duration is updated, let's say she adds to the position just 1 wei. The new lock duration is ≈ 90 days.
After another 30 days, she wants to renew her position for another 90 days. Then she calls MlumStaking::renewLockPosition. The new amount multiplier will be calculated as ≈ 1+90/365*2 < 3.
Since it is not in her interest to have a lower multiplier than originally, then she adds just 1 wei to her position. The new multiplier will be 3 again.


## Impact
You may find below the coded PoC corresponding to each of the aforementioned scenarios:

Place in `MlumStaking.t.sol`.
```solidity
    function testLockDurationReduced() public {
        _stakingToken.mint(ALICE, 2 ether);

        vm.startPrank(ALICE);
        _stakingToken.approve(address(_pool), 1 ether);
        _pool.createPosition(1 ether, 365 days);
        vm.stopPrank();

        // check lockduration
        MlumStaking.StakingPosition memory position = _pool.getStakingPosition(
            1
        );
        assertEq(position.lockDuration, 365 days);

        skip(365 days);

        // add to position should take calc. avg. lock duration
        vm.startPrank(ALICE);
        _stakingToken.approve(address(_pool), 1 ether);
        _pool.addToPosition(1, 1 ether);
        vm.stopPrank();

        position = _pool.getStakingPosition(1);

        assertEq(position.lockDuration, 365 days / 2);
        assertEq(position.amountWithMultiplier, 2 ether * 3);
    }
```

Place in `MlumStaking.t.sol`.
```solidity
    function testExtendLockAndAdd() public {
        _stakingToken.mint(ALICE, 2 ether);

        vm.startPrank(ALICE);
        _stakingToken.approve(address(_pool), 2 ether);
        _pool.createPosition(1 ether, 365 days);
        vm.stopPrank();

        // check lockduration
        MlumStaking.StakingPosition memory position = _pool.getStakingPosition(
            1
        );
        assertEq(position.lockDuration, 365 days);

        skip(365 days - 90 days);
        vm.startPrank(ALICE);
        _pool.addToPosition(1, 1 wei); // lock duration ≈ 90 days
        skip(30 days);
        _pool.renewLockPosition(1); // multiplier ≈ 1+90/365*2
        position = _pool.getStakingPosition(1);
        assertEq(position.lockDuration, 7776000);
        assertEq(position.amountWithMultiplier, 1493100000000000001);

        _pool.addToPosition(1, 1 wei); // multiplier = 3
        position = _pool.getStakingPosition(1);
        assertEq(position.lockDuration, 7776000);
        assertEq(position.amountWithMultiplier, 3000000000000000006);
    }
```

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/MlumStaking.sol#L409-L417

https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/MlumStaking.sol#L509-L514

https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/MlumStaking.sol#L714

## Tool used
Manual Review

## Recommendation
Assign new multiplier in MlumStaking::addToPosition based on lock duration rather than initial lock duration.

# [M-03] Adding genuine BribeRewarder contract instances to a pool in order to incentivize users can be DOSed
## Summary
In the Voter.sol contract, protocols can create BribeRewarder.sol contract instances in order to bribe users to vote for the pool specified by the protocol. The more users vote for a specific pool, the bigger the weight of that pool will be compared to other pools and thus users staking the pool LP token in the MasterchefV2.sol contract will receive more rewards. The LP token of the pool the protocol is bribing for, receives bigger allocation of the LUM token in the MasterchefV2.sol contract. Thus incentivizing people to deposit tokens in the AMM associated with the LP token in order to acquire the LP token for a pool with higher weight, thus providing more liquidity in a trading pair. In the Voter.sol contract a voting period is defined by an id, start time, and a end time which is the start time + the globaly specified _periodDuration. When a protocol tries to add a BribeRewarder.sol contract instance for a pool and a voting period, they have to call the fundAndBribe() function or the bribe() funciton and supply the required amount of reward tokens. Both of the above mentioned functions internally call the _bribe() function which in turn calls the onRegister() function in the Voter.sol contract. There is the following check in the onRegister() function:
```solidity
    function onRegister() external override {
        IBribeRewarder rewarder = IBribeRewarder(msg.sender);

        _checkRegisterCaller(rewarder);

        uint256 currentPeriodId = _currentVotingPeriodId;
        (address pool, uint256[] memory periods) = rewarder.getBribePeriods();
        for (uint256 i = 0; i < periods.length; ++i) {
            // TODO check if rewarder token + pool  is already registered

            require(periods[i] >= currentPeriodId, "wrong period");
            require(_bribesPerPriod[periods[i]][pool].length + 1 <= Constants.MAX_BRIBES_PER_POOL, "too much bribes");
            _bribesPerPriod[periods[i]][pool].push(rewarder);
        }
    }
```
Constants.MAX_BRIBES_PER_POOL is equal to 5. This means that each pool can be associated with a maximum of 5 instances of the BribeRewarder.sol contract for each voting period. The problem is that adding BribeRewarder.sol contract instances for a pool for a certain voting period is permissionless. There is no whitelist for the tokens that can be used as reward tokens in the BribeRewarder.sol contract or a minimum amount of rewards that have to be distributed per each voting period. A malicious actor can just deploy an ERC20 token on the network, that have absolutely no dollar value, mint as many tokens as he wants and then deploy 5 instance of the BribeRewarder.sol contract by calling the createBribeRewarder() function in the RewarderFactory.sol contract. After that he can either call fundAndBribe() function or the bribe() function in order to associate the above mentioned BribeRewarder.sol contract instances for a specific pool and voting period. A malicious actor can specify as many voting periods as he want. _periodDuration is set to 1209600 seconds = 2 weeks on Voter.sol initialization. If a malicious actor sets BribeRewarder.sol contract instances for 100 voting periods, that means 200 weeks or almost 4 years, no other BribeRewarder.sol contract instance can be added during this period. When real rewards can't be used as incentives for users, nobody will vote for a specific pool. A malicious actor can dos all pools that can potentially be added for example by tracking what new pools are created at the MagicSea exchange and then immediately performing the above specified steps, thus making the entire Voter.sol and BribeRewarders.sol contracts obsolete, as their main purpose is to incentivize users to vote for specific pools and reward them with tokens for their vote. Or a malicious actor can dos specific projects that are direct competitors of his project, thus more people will provide liquidity for an AMM he is bribing users for, this way he can also provide much less rewards and still his pool will be the most lucrative one.

## Vulnerability Detail
After following the steps in the above mentioned gist add the following test to the AuditorTests.t.sol file:
```solidity
    function test_BrickRewardBribers() public {
        vm.startPrank(attacker);
        customNoValueToken.mint(attacker, 500_000e18);
        BribeRewarder rewarder = BribeRewarder(payable(address(rewarderFactory.createBribeRewarder(customNoValueToken, pool))));
        customNoValueToken.approve(address(rewarder), type(uint256).max);
        rewarder.fundAndBribe(1, 100, 100e18);

        BribeRewarder rewarder1 = BribeRewarder(payable(address(rewarderFactory.createBribeRewarder(customNoValueToken, pool))));
        customNoValueToken.approve(address(rewarder1), type(uint256).max);
        rewarder1.fundAndBribe(1, 100, 100e18);

        BribeRewarder rewarder2 = BribeRewarder(payable(address(rewarderFactory.createBribeRewarder(customNoValueToken, pool))));
        customNoValueToken.approve(address(rewarder2), type(uint256).max);
        rewarder2.fundAndBribe(1, 100, 100e18);

        BribeRewarder rewarder3 = BribeRewarder(payable(address(rewarderFactory.createBribeRewarder(customNoValueToken, pool))));
        customNoValueToken.approve(address(rewarder3), type(uint256).max);
        rewarder3.fundAndBribe(1, 100, 100e18);

        BribeRewarder rewarder4 = BribeRewarder(payable(address(rewarderFactory.createBribeRewarder(customNoValueToken, pool))));
        customNoValueToken.approve(address(rewarder4), type(uint256).max);
        rewarder4.fundAndBribe(1, 100, 100e18);
        vm.stopPrank();

        vm.startPrank(tom);
        BribeRewarder rewarderReal = BribeRewarder(payable(address(rewarderFactory.createBribeRewarder(bribeRewardToken, pool))));
        bribeRewardToken.mint(tom, 100_000e6);
        bribeRewardToken.approve(address(rewarderReal), type(uint256).max);
        customNoValueToken.approve(address(rewarderReal), type(uint256).max);
        vm.expectRevert(bytes("too much bribes"));
        rewarderReal.fundAndBribe(2, 6, 20_000e6);
        vm.stopPrank();
    }
```
To run the test use: forge test -vvv --mt test_BrickRewardBribers

## Impact
A malicious actor can dos the adding of BribeRewarder.sol contract instances for specific pools, and thus either make Voter.sol and BribeRewarders.sol contracts obsolete, or prevent the addition of genuine BribeRewarder.sol contract instances for a specific project which he sees as a competitor. I believe this vulnerability is of high severity as it severely restricts the availability of the main functionality of the Voter.sol and BribeRewarders.sol contracts.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/Voter.sol#L130-L144

## Tool used
Manual Review & Foundry

## Recommendation
Consider creating a functionality that whitelists only previously verified owner of pools, or people that really intend to distribute rewards to voters, and allow only them to add BribeRewarders.sol contracts instances for the pool they are whitelisted for.

# [M-04] Inconsistent check in harvestPositionsTo() function
## Summary
Inconsistent check in harvestPositionsTo() function limits the ability of approved address to harvest on behalf of owner.

## Vulnerability Detail
In the function harvestPositionsTo(), function _requireOnlyApprovedOrOwnerOf() allows owner or approved address to harvest for the position.

However, the check (msg.sender == tokenOwner && msg.sender == to) only allowing the caller to be token owner. Thus these 2 checks are contradicted.
```solidity
function harvestPositionsTo(uint256[] calldata tokenIds, address to) external override nonReentrant {
    _updatePool();

    uint256 length = tokenIds.length;

    for (uint256 i = 0; i < length; ++i) {
        uint256 tokenId = tokenIds[i];
        _requireOnlyApprovedOrOwnerOf(tokenId);
        address tokenOwner = ERC721Upgradeable.ownerOf(tokenId);
        // if sender is the current owner, must also be the harvest dst address
        // if sender is approved, current owner must be a contract
        // @audit not consistent with _requireOnlyApprovedOrOwnerOf()
        require(
            (msg.sender == tokenOwner && msg.sender == to), // legacy || tokenOwner.isContract() 
            "FORBIDDEN"
        );

        _harvestPosition(tokenId, to);
        _updateBoostMultiplierInfoAndRewardDebt(_stakingPositions[tokenId]);
    }
}
```

## Impact
Contradictions in the function harvestPositionsTo(). Approved address cannot call harvestPositionsTo() on behalf of NFT owner.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/main/magicsea-staking/src/MlumStaking.sol#L475-L484

## Tool used
Manual Review

## Recommendation
The intended check in function harvestPositionsTo() might be, changing && to ||
```solidity
require(
-    (msg.sender == tokenOwner && msg.sender == to), // legacy || tokenOwner.isContract() 
+    (msg.sender == tokenOwner || msg.sender == to), // legacy || tokenOwner.isContract() 
    "FORBIDDEN"
);
```

# [M-05] Lack of support for fee on transfer, rebasing and tokens with balance modifications outside of transfers.
## Summary
The protocol wants to work with various ERC20 tokens, but in certain cases doesn't provide the needed support for tokens that charge a fee on transfer, tokens that rebase (negatively/positively) and overall, tokens with balance modifications outside of transfers.

## Vulnerability Detail
The protocol wants to work with various ERC20 tokens, but still handles various transfers without querying the amount transferred and amount received, which can lead a host of accounting issues and the likes downstream.

For instance, In MasterchefV2.sol during withdrawals or particularly emergency withdrawals, the last user to withdraw all tokens will face issues as the amount registered to his name might be signifiacntly lesser than the token balance in the contract, which as a result will cause the withdrawal functions to fail. Or the protocol risks having to send extra funds from their pocket to coverup for these extra losses due to the fees.
This is because on deposit, the amount entered is deposited as is, without accounting for potential fees.
```solidity
    function deposit(uint256 pid, uint256 amount) external override {
        _modify(pid, msg.sender, amount.toInt256(), false);

        if (amount > 0) _farms[pid].token.safeTransferFrom(msg.sender, address(this), amount);
    }
```
Some tokens like stETH have a 1 wei corner case in which during transfers the amount that actually gets sent is actually a bit less than what has been specified in the transaction.

## Impact
On a QA severity level, tokens received by users will be less than emitted to them in the event.
On medium severity level, accounting issues, potential inability of last users to withdraw, potential loss of funds from tokens with airdrops, etc.

## Code Snippet
https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MasterchefV2.sol#L287

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MasterchefV2.sol#L298

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MasterchefV2.sol#L309

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MasterchefV2.sol#L334

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MlumStaking.sol#L559

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MlumStaking.sol#L649

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MlumStaking.sol#L744

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/MlumStaking.sol#L747

https://github.com/sherlock-audit/2024-06-magicsea/blob/42e799446595c542eff9519353d3becc50cdba63/magicsea-staking/src/rewarders/BribeRewarder.sol#L120

## Tool used
Manual Review

## Recommendation
Recommend implementing a measure like that of the _transferSupportingFeeOnTransfer function that can correctly handle these transfers. A sweep function can also be created to help with positive rebases and airdrops.