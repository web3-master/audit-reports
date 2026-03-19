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
