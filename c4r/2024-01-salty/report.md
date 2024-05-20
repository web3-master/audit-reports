| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-user-can-evade-liquidation-by-depositing-the-minimum-of-tokens-and-gain-time-to-not-be-liquidated) | User can evade liquidation by depositing the minimum of tokens and gain time to not be liquidated |
| [M-01](#m-01-the-user-who-withdraws-liquidity-from-a-particular-pool-is-able-to-claim-more-rewards-than-he-duly-deserves-by-carefully-selecting-adecrease-share-amount-value-such-that-thevirtual-rewards-to-remove-is-rounded-down-to-zero) | THE USER WHO WITHDRAWS LIQUIDITY FROM A PARTICULAR POOL IS ABLE TO CLAIM MORE REWARDS THAN HE DULY DESERVES BY CAREFULLY SELECTING A decreaseShareAmount VALUE SUCH THAT THE virtualRewardsToRemove IS ROUNDED DOWN TO ZERO |
| [M-02](#m-02-dos-of-proposals-by-abusing-ballot-names-without-important-parameters) | DOS of proposals by abusing ballot names without important parameters |
| [M-03](#m-03-when-forming-pol-the-dao-will-end-up-stucked-with-dai-and-usds-tokens-that-cannot-handle) | When forming POL the DAO will end up stucked with DAI and USDS tokens that cannot handle. |


# [H-01] User can evade liquidation by depositing the minimum of tokens and gain time to not be liquidated
## Impact
The CollateralAndLiquidity contract contains a critical vulnerability that allows a user undergoing liquidation to evade the process by manipulating the user.cooldownExpiration variable. This manipulation is achieved through the CollateralAndLiquidity::depositCollateralAndIncreaseShare function, specifically within the StakingRewards::_increaseUserShare function (code line #70):
```solidity
File: StakingRewards.sol
57: 	function _increaseUserShare( address wallet, bytes32 poolID, uint256 increaseShareAmount, bool useCooldown ) internal
58: 		{
59: 		require( poolsConfig.isWhitelisted( poolID ), "Invalid pool" );
60: 		require( increaseShareAmount != 0, "Cannot increase zero share" );
61: 
62: 		UserShareInfo storage user = _userShareInfo[wallet][poolID];
63: 
64: 		if ( useCooldown )
65: 		if ( msg.sender != address(exchangeConfig.dao()) ) // DAO doesn't use the cooldown
66: 			{
67: 			require( block.timestamp >= user.cooldownExpiration, "Must wait for the cooldown to expire" );
68: 
69: 			// Update the cooldown expiration for future transactions
70: 			user.cooldownExpiration = block.timestamp + stakingConfig.modificationCooldown();
71: 			}
72: 
73: 		uint256 existingTotalShares = totalShares[poolID];
74: 
75: 		// Determine the amount of virtualRewards to add based on the current ratio of rewards/shares.
76: 		// The ratio of virtualRewards/increaseShareAmount is the same as totalRewards/totalShares for the pool.
77: 		// The virtual rewards will be deducted later when calculating the user's owed rewards.
78:         if ( existingTotalShares != 0 ) // prevent / 0
79:         	{
80: 			// Round up in favor of the protocol.
81: 			uint256 virtualRewardsToAdd = Math.ceilDiv( totalRewards[poolID] * increaseShareAmount, existingTotalShares );
82: 
83: 			user.virtualRewards += uint128(virtualRewardsToAdd);
84: 	        totalRewards[poolID] += uint128(virtualRewardsToAdd);
85: 	        }
86: 
87: 		// Update the deposit balances
88: 		user.userShare += uint128(increaseShareAmount);
89: 		totalShares[poolID] = existingTotalShares + increaseShareAmount;
90: 
91: 		emit UserShareIncreased(wallet, poolID, increaseShareAmount);
92: 		}
```
Malicious user can perform front-running of the liquidation function by depositing small amounts of tokens to his position, incrementing the user.cooldownExpiration variable. Consequently, the execution of the liquidation function will be reverted with the error message Must wait for the cooldown to expire. This vulnerability could lead to attackers evading liquidation, potentially causing the system to enter into debt as liquidations are avoided.

## Proof of Concept
A test case, named testUserLiquidationMayBeAvoided, has been created to demonstrate the potential misuse of the system. The test involves the following steps:

User Alice deposits and borrow the maximum amount.
The collateral price crashes.
Alice maliciously front-runs the liquidation execution by depositing a the minimum amount using the collateralAndLiquidity::depositCollateralAndIncreaseShare function.
The liquidation transaction is reverted by "Must wait for the cooldown to expire" error.
```solidity
// Filename: src/stable/tests/CollateralAndLiquidity.t.sol:TestCollateral
// $ forge test --match-test "testUserLiquidationMayBeAvoided" --rpc-url https://yoururl -vv
//
    function testUserLiquidationMayBeAvoided() public {
        // Liquidatable user can avoid liquidation
        //
		// Have bob deposit so alice can withdraw everything without DUST reserves restriction
        _depositHalfCollateralAndBorrowMax(bob);
        //
        // 1. Alice deposit and borrow the max amount
        // Deposit and borrow for Alice
        _depositHalfCollateralAndBorrowMax(alice);
        // Check if Alice has a position
        assertTrue(_userHasCollateral(alice));
        //
        // 2. Crash the collateral price
        _crashCollateralPrice();
        vm.warp( block.timestamp + 1 days );
        //
        // 3. Alice maliciously front run the liquidation action and deposit a DUST amount
        vm.prank(alice);
		collateralAndLiquidity.depositCollateralAndIncreaseShare(PoolUtils.DUST + 1, PoolUtils.DUST + 1, 0, block.timestamp, false );
        //
        // 4. The function alice liquidation will be reverted by "Must wait for the cooldown to expire"
        vm.expectRevert( "Must wait for the cooldown to expire" );
        collateralAndLiquidity.liquidateUser(alice);
    }
```

## Lines of code
https://github.com/code-423n4/2024-01-salty/blob/53516c2cdfdfacb662cdea6417c52f23c94d5b5b/src/stable/CollateralAndLiquidity.sol#L140
https://github.com/code-423n4/2024-01-salty/blob/53516c2cdfdfacb662cdea6417c52f23c94d5b5b/src/stable/CollateralAndLiquidity.sol#L70

## Tool used
Manual Review

## Recommended Mitigation Steps
Consider modifying the liquidation function as follows:
```solidity
	function liquidateUser( address wallet ) external nonReentrant
		{
		require( wallet != msg.sender, "Cannot liquidate self" );

		// First, make sure that the user's collateral ratio is below the required level
		require( canUserBeLiquidated(wallet), "User cannot be liquidated" );

		uint256 userCollateralAmount = userShareForPool( wallet, collateralPoolID );

		// Withdraw the liquidated collateral from the liquidity pool.
		// The liquidity is owned by this contract so when it is withdrawn it will be reclaimed by this contract.
		(uint256 reclaimedWBTC, uint256 reclaimedWETH) = pools.removeLiquidity(wbtc, weth, userCollateralAmount, 0, 0, totalShares[collateralPoolID] );

		// Decrease the user's share of collateral as it has been liquidated and they no longer have it.
--		_decreaseUserShare( wallet, collateralPoolID, userCollateralAmount, true );
++		 _decreaseUserShare( wallet, collateralPoolID, userCollateralAmount, false );

		// The caller receives a default 5% of the value of the liquidated collateral.
		uint256 rewardPercent = stableConfig.rewardPercentForCallingLiquidation();

		uint256 rewardedWBTC = (reclaimedWBTC * rewardPercent) / 100;
		uint256 rewardedWETH = (reclaimedWETH * rewardPercent) / 100;

		// Make sure the value of the rewardAmount is not excessive
		uint256 rewardValue = underlyingTokenValueInUSD( rewardedWBTC, rewardedWETH ); // in 18 decimals
		uint256 maxRewardValue = stableConfig.maxRewardValueForCallingLiquidation(); // 18 decimals
		if ( rewardValue > maxRewardValue )
			{
			rewardedWBTC = (rewardedWBTC * maxRewardValue) / rewardValue;
			rewardedWETH = (rewardedWETH * maxRewardValue) / rewardValue;
			}

		// Reward the caller
		wbtc.safeTransfer( msg.sender, rewardedWBTC );
		weth.safeTransfer( msg.sender, rewardedWETH );

		// Send the remaining WBTC and WETH to the Liquidizer contract so that the tokens can be converted to USDS and burned (on Liquidizer.performUpkeep)
		wbtc.safeTransfer( address(liquidizer), reclaimedWBTC - rewardedWBTC );
		weth.safeTransfer( address(liquidizer), reclaimedWETH - rewardedWETH );

		// Have the Liquidizer contract remember the amount of USDS that will need to be burned.
		uint256 originallyBorrowedUSDS = usdsBorrowedByUsers[wallet];
		liquidizer.incrementBurnableUSDS(originallyBorrowedUSDS);

		// Clear the borrowedUSDS for the user who was liquidated so that they can simply keep the USDS they previously borrowed.
		usdsBorrowedByUsers[wallet] = 0;
		_walletsWithBorrowedUSDS.remove(wallet);

		emit Liquidation(msg.sender, wallet, reclaimedWBTC, reclaimedWETH, originallyBorrowedUSDS);
		}
```
This modification ensures that the user.cooldownExpiration expiration check does not interfere with the liquidation process, mitigating the identified security risk.

# [M-01] THE USER WHO WITHDRAWS LIQUIDITY FROM A PARTICULAR POOL IS ABLE TO CLAIM MORE REWARDS THAN HE DULY DESERVES BY CAREFULLY SELECTING A decreaseShareAmount VALUE SUCH THAT THE virtualRewardsToRemove IS ROUNDED DOWN TO ZERO
## Impact
The StakingRewards._decreaseUserShare function is used to decrease a user's share for the pool and have any pending rewards sent to them. When the amount of pending rewards are calculated, initially the virtualRewardsToRemove are calculated as follows:
```solidity
	uint256 virtualRewardsToRemove = (user.virtualRewards * decreaseShareAmount) / user.userShare;
```
Then the virtualRewardsToRemove is substracted from the rewardsForAmount value to calculate the claimableRewards amount as shown below:
```solidity
	if ( virtualRewardsToRemove < rewardsForAmount )
		claimableRewards = rewardsForAmount - virtualRewardsToRemove; 
```
But the issue here is that the virtualRewardsToRemove calculation is rounded down in favor of the user and not in the favor of the protocol. Since the virtualRewardsToRemove is rounded down there is an opportunity to the user to call the StakingRewards._decreaseUserShare function with a very small decreaseShareAmount value such that the virtualRewardsToRemove will be rounded down to 0. Providing a very small decreaseShareAmount value is possible since only input validation on decreaseShareAmount is ! = 0 as shown below:
```solidity
	require( decreaseShareAmount != 0, "Cannot decrease zero share" );
```
When the claimableRewards is calculated it will be equal to the rewardsForAmount value since the virtualRewardsToRemove will be 0. This way the user can keep on removing his liquidity from a particular pool by withdrawing small decreaseShareAmount at a time such that keeping virtualRewardsToRemove at 0 due to rounding down.

Furthermore the decreaseShareAmount value should be selected in such a way rewardsForAmount is calculated to a considerable amount after round down (not zero) and the virtualRewardsToRemove should round down to zero.

Hence as a result the user can withdraw all the rewardsForAmount as the claimableRewards even though some of those rewards are virtual rewards which should not be claimable as clearly stated by the following natspec comment:

	// Some of the rewardsForAmount are actually virtualRewards and can't be claimed.
Hence as a result the user is able to get an undue advantage and claim more rewards for his liquidity during liquidity withdrawable. This happens because the user can bypass the virtual reward subtraction by making it round down to 0. As a result the virtualReward amount of the rewardsForAmount, which should not be claimable is also claimed by the user unfairly.

## Proof of Concept
```solidity
		// Determine the share of the rewards for the amountToDecrease (will include previously added virtual rewards)
		uint256 rewardsForAmount = ( totalRewards[poolID] * decreaseShareAmount ) / totalShares[poolID];

		// For the amountToDecrease determine the proportion of virtualRewards (proportional to all virtualRewards for the user)
		// Round virtualRewards down in favor of the protocol
		uint256 virtualRewardsToRemove = (user.virtualRewards * decreaseShareAmount) / user.userShare;
```
https://github.com/code-423n4/2024-01-salty/blob/main/src/staking/StakingRewards.sol#L113-L118
```solidity
		if ( virtualRewardsToRemove < rewardsForAmount )
			claimableRewards = rewardsForAmount - virtualRewardsToRemove;
```
https://github.com/code-423n4/2024-01-salty/blob/main/src/staking/StakingRewards.sol#L132-L133
```solidity
		require( decreaseShareAmount != 0, "Cannot decrease zero share" );
```
https://github.com/code-423n4/2024-01-salty/blob/main/src/staking/StakingRewards.sol#L99

## Lines of code
https://github.com/code-423n4/2024-01-salty/blob/main/src/staking/StakingRewards.sol#L113-L118
https://github.com/code-423n4/2024-01-salty/blob/main/src/staking/StakingRewards.sol#L132-L133
https://github.com/code-423n4/2024-01-salty/blob/main/src/staking/StakingRewards.sol#L99

## Tool used
Manual Review

## Recommended Mitigation Steps
Hence it is recommended to round up the virtualRewardsToRemove value during its calculation such that it will not be rounded down to zero for a very small decreaseShareAmount. This way user is unable to claim the rewards which he is not eligible for and the rewards will be claimed after accounting for the virtual rewards.

# [M-02] DOS of proposals by abusing ballot names without important parameters
## Impact
An adversary can prevent legit proposals from being created by using the same ballot name.

Proposals with the same name can't be created, leading to a DOS for some days until the voting phase ends. This can be done repeatedly, after finalizing the previous malicious proposal and creating a new one.

Impacts for each proposal function:

proposeSendSALT(): DOS of all proposals
proposeSetContractAddress(): DOS of specific contract setting by proposing a malicious address
proposeCallContract(): DOS of specific contract call by providing a wrong number
proposeTokenWhitelisting(): DOS of token whitelisting by providing a fake tokenIconURL
All: Prevent the creation of any legit proposal, by providing a fake/malicious description to discourage positive voting
Note: This Impact fits into the Attack Ideas: "Any issue that would prevent the DAO from functioning correctly."

## Proof of Concept
This test for proposeSendSALT() already shows how a new proposal can't be created when there is an existing one. An adversary can exploit that as explained on the Vulnerability Details section. That test could be extended to all the other mentioned functions with their corresponding impacts.

## Lines of code
https://github.com/code-423n4/2024-01-salty/blob/53516c2cdfdfacb662cdea6417c52f23c94d5b5b/src/dao/Proposals.sol#L101-L102
https://github.com/code-423n4/2024-01-salty/blob/53516c2cdfdfacb662cdea6417c52f23c94d5b5b/src/dao/Proposals.sol#L196

## Tool used
Manual Review

## Recommended Mitigation Steps
In order to prevent the DOS, ballot names (or some new id variable) should include ALL the attributes of the proposal: ballotType, address1, number1, string1, and string2. Strings could be hashed, and the whole pack could be hashed as well.

So, if an adversary creates the proposal, it would look exactly the same as the legit one.

In the particular case of proposeSendSALT(), strictly preventing simultaneous proposals as they are right now will lead to the explained DOS. Some other mechanism should be implemented to mitigate risks. One way could be to set a long enough cooldown for each user, so that they can't repeatedly send these type of proposals (take into account unstake time).

# [M-03] When forming POL the DAO will end up stucked with DAI and USDS tokens that cannot handle.
## Impact
The DAO contract cannot handle any token beside SALT tokens. So, if tokens like USDS or DAI were in its balance, they will be lost forever.

This can happen during the upkeep calls. Basically, during upkeep the contract takes some percentage from the arbitrage profits and use them to form POL for the DAO (usds/dai and salt/usds). The DAO swaps the ETH for both of the needed tokens and then adds the liquidity using the zapping flag to true.

https://github.com/code-423n4/2024-01-salty/blob/53516c2cdfdfacb662cdea6417c52f23c94d5b5b/src/dao/DAO.sol#L316-L324

Zapping will compute the amount of either tokenA or tokenB to swap in order to add liquidity at the final ratio of reserves after the swap. But, it is important to note that the zap computations do no take into account that the same pool may get arbitraged atomically, changing the ratio of reserves a little.

As a consequence, some of the USDS and DAI tokens will be send back to the DAO contract:

https://github.com/code-423n4/2024-01-salty/blob/53516c2cdfdfacb662cdea6417c52f23c94d5b5b/src/staking/Liquidity.sol#L110C3-L115C1

## Proof of Concept
The following coded PoC should be pasted into root_tests/Upkeep.t.sol, actually its the same test that can be found at the end of the file with some added lines to showcase the issue. Specifically, it shows how the USDS and DAI balance of the DAO are zero before upkeep and how both are greater than zero after upkeep.
```solidity
function testDoublePerformUpkeep() public {

        _setupLiquidity();
        _generateArbitrageProfits(false);

    	// Dummy WBTC and WETH to send to Liquidizer
    	vm.prank(DEPLOYER);
    	weth.transfer( address(liquidizer), 50 ether );

    	// Indicate that some USDS should be burned
    	vm.prank( address(collateralAndLiquidity));
    	liquidizer.incrementBurnableUSDS( 40 ether);

    	// Mimic arbitrage profits deposited as WETH for the DAO
    	vm.prank(DEPLOYER);
    	weth.transfer(address(dao), 100 ether);

    	vm.startPrank(address(dao));
    	weth.approve(address(pools), 100 ether);
    	pools.deposit(weth, 100 ether);
    	vm.stopPrank();

        // === Perform upkeep ===
        address upkeepCaller = address(0x9999);

        uint256 daiDaoBalanceBefore = dai.balanceOf(address(dao));
        uint256 usdsDaoBalanceBefore = usds.balanceOf(address(dao));

        assertEq(daiDaoBalanceBefore, 0);
        assertEq(usdsDaoBalanceBefore, 0);

        vm.prank(upkeepCaller);
        upkeep.performUpkeep();
        // ==================

        _secondPerformUpkeep();

        uint256 daiDaoBalanceAfter = dai.balanceOf(address(dao));
        uint256 usdsDaoBalanceAfter = usds.balanceOf(address(dao));

        assertTrue(daiDaoBalanceAfter > 0);
        assertTrue(usdsDaoBalanceAfter > 0);
}
```

## Lines of code
https://github.com/code-423n4/2024-01-salty/blob/53516c2cdfdfacb662cdea6417c52f23c94d5b5b/src/dao/DAO.sol#L321

## Tool used
Manual Review

## Recommended Mitigation Steps
The leftovers of USDS or DAI should be send to liquidizer so they can be handled.