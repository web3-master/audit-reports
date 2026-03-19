## Title
Precision loss in staker reward calculation (ClaimNodeOp)

## Brief/Intro
A precision-loss issue exists in ClaimNodeOp.calculateAndDistributeRewards(): the function divides by totalEligibleGGPStaked before multiplying by the rewards circle total, which can truncate fractional values and underpay stakers. This is a deterministic integer-division ordering bug that results in systematic undercompensation.

## Vulnerability Details
The code first computes a fractional percentage using integer-fixed-point division (ggpEffectiveStaked / totalEligibleGGPStaked) then multiplies that percentage by rewardsCycleTotal.
Performing the division prior to scaling down introduces rounding/truncation that removes fractional precision.
Repeated or aggregate truncation causes stakers to receive lower rewards than their proportional share.

Let's see more detail.
ClaimNodeOp.calculateAndDistributeRewards() function is as follows.
```solidity
File: ClaimNodeOp.sol
46: 	function calculateAndDistributeRewards(address stakerAddr, uint256 totalEligibleGGPStaked) external onlyMultisig {
...
58: 		staking.setLastRewardsCycleCompleted(stakerAddr, rewardsPool.getRewardsCycleCount());
59: 		uint256 ggpEffectiveStaked = staking.getEffectiveGGPStaked(stakerAddr);
60: 		uint256 percentage = ggpEffectiveStaked.divWadDown(totalEligibleGGPStaked);
61: 		uint256 rewardsCycleTotal = getRewardsCycleTotal();
62: 		uint256 rewardsAmt = percentage.mulWadDown(rewardsCycleTotal);   // @audit: Division before multiplication, which leads to precision loss!!
63: 		if (rewardsAmt > rewardsCycleTotal) {
64: 			revert InvalidAmount();
65: 		}
...
75: 	}
```
In L59~L62, the reward amount is calculated as ggpEffectiveStaked / totalEligibleGGPStaked * rewardsCycleTotal.
This calculation leads to precision loss.


## Impact Details
* Stakers can be undercompensated relative to their fair share.
* Over many distributions, cumulative truncation may meaningfully reduce earned rewards.
* This degrades economic fairness and could harm user trust.

## Suggested fixes (recommended)
Compute the reward by multiplying first, then dividing to preserve precision. 
```solidity
File: ClaimNodeOp.sol
46: 	function calculateAndDistributeRewards(address stakerAddr, uint256 totalEligibleGGPStaked) external onlyMultisig {
...
58: 		staking.setLastRewardsCycleCompleted(stakerAddr, rewardsPool.getRewardsCycleCount());
59: 		uint256 ggpEffectiveStaked = staking.getEffectiveGGPStaked(stakerAddr);
61: 		uint256 rewardsCycleTotal = getRewardsCycleTotal();
62: 		uint256 rewardsAmt = ggpEffectiveStaked.mulWadDown(rewardsCycleTotal).divWadDown(totalEligibleGGPStaked);   // @audit: Should be fixed like this!!
63: 		if (rewardsAmt > rewardsCycleTotal) {
64: 			revert InvalidAmount();
65: 		}
...
75: 	}
```

## References
https://github.com/multisig-labs/gogopool/blob/aa205870ce415ace2ec5a0e061426c0bb8f364db/contracts/contract/ClaimNodeOp.sol#L62

## Proof of Concept
This is unit test code.
```solidity
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.17;

import "./utils/BaseTest.sol";
import {BaseAbstract} from "../../contracts/contract/BaseAbstract.sol";
import {Staking} from "../../contracts/contract/Staking.sol";

import {FixedPointMathLib} from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

contract ClaimNodeOpTest is BaseTest {
	using FixedPointMathLib for uint256;
	uint256 private constant TOTAL_INITIAL_SUPPLY = 22500000 ether;

	function setUp() public override {
		super.setUp();
	}

	function test_myTest() public {
		skip(dao.getRewardsCycleSeconds());
		rewardsPool.startRewardsCycle();
		address nodeOp1 = getActorWithTokens("nodeOp1", MAX_AMT, MAX_AMT);
		vm.startPrank(nodeOp1);
		ggAVAX.depositAVAX{value: 2000 ether}();
		ggp.approve(address(staking), MAX_AMT);
		staking.stakeGGP(100 ether);
		MinipoolManager.Minipool memory mp1 = createMinipool(1000 ether, 1000 ether, 2 weeks);
		rialto.processMinipoolStart(mp1.nodeID);
		vm.stopPrank();

		vm.startPrank(address(rialto));
		nopClaim.calculateAndDistributeRewards(nodeOp1, 1001 ether);

		//
		// Reward value.
		//
		uint currentValue = staking.getGGPRewards(nodeOp1);
		emit log_named_uint("currentValue", currentValue); 

		// 
		// Current calculation logic is as follows.
		// by ClaimNodeOp.sol#L59~L62.
		//
		uint256 ggpEffectiveStaked = staking.getEffectiveGGPStaked(nodeOp1);
		uint256 percentage = ggpEffectiveStaked.divWadDown(1001 ether);
		uint256 rewardsCycleTotal = nopClaim.getRewardsCycleTotal();
		uint256 rewardsAmt = percentage.mulWadDown(rewardsCycleTotal);	// @audit: Division before multiplication!!
		emit log_named_uint("rewardsAmt", rewardsAmt); 

		assertEq(currentValue, rewardsAmt);

		//
		// What's correct value.
		//
		uint256 rewardsAmtCorrect = ggpEffectiveStaked.mulWadDown(rewardsCycleTotal).divWadDown(1001 ether);
		emit log_named_uint("rewardsAmtCorrect", rewardsAmtCorrect); 

		//
		// Current calculation logic gives smaller value because of rounding error.
		//
		assertEq(currentValue < rewardsAmtCorrect, true);
	}
}
```

To run this test code, please run
```shell
forge test --match-test myTest
```