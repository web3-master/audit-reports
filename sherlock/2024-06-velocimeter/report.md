| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-pause-or-kill-gauge-can-lead-to-flow-token-stuck-in-voter) | pause or kill gauge can lead to FLOW token stuck in voter |
| [M-01](#m-01-voterreplacefactory-and-voteraddfactory-functions-are-broken) | Voter.replaceFactory() and Voter.addFactory() functions are broken. |


# [H-01] pause or kill gauge can lead to FLOW token stuck in voter
## Summary
pause or kill gauge action set unclaimed reward to 0 without sending it back to minter or distributing it to gauge.

## Vulnerability Detail
when [Voter::distribute] is tigger , voter invoke Minter::update_period , if 1 week duration is pass by , minter transfer some FLOW to Voter, the amount is based on the number of gauges.
```solidity
  function distribute(address _gauge) public lock {
      IMinter(minter).update_period();     <@
      _updateFor(_gauge); // should set claimable to 0 if killed
      uint _claimable = claimable[_gauge];
      if (_claimable > IGauge(_gauge).left(base) && _claimable / DURATION > 0) {.  <@
          claimable[_gauge] = 0;
            if((_claimable * 1e18) / currentEpochRewardAmount > minShareForActiveGauge) {
                activeGaugeNumber += 1;
            }

            IGauge(_gauge).notifyRewardAmount(base, _claimable);//@audit-info update rewardRate or add reward token , send token to gauge.
            emit DistributeReward(msg.sender, _gauge, _claimable);
        }
    }
```
From above code we can see only if _claimable > IGauge(_gauge).left(base) the claimable reward token will be send to gauge

And emergencyCouncil can invoke Voter.sol::pauseGauge or Voter.sol::killGaugeTotally at anytime , without checking the claimable reward token amount and set it to zero. Which can lead to those unclaimed reward token stuck in voter contract.

test:
```solidity
    function testPauseGaugeLeadToRemainingToken() public {
        FLOW.setMinter(address(minter));
        minter.startActivePeriod();
        voter.distribute();

        address gauge = voter.createGauge(address(pair),0);
        address gauge2 = voter.createGauge(address(pair2),0);
        address gauge3 = voter.createGauge(address(pair3),0);

        //get voting power.
        flowDaiPair.approve(address(escrow), 5e17);
        uint256 tokenId = escrow.create_lock_for(1e16, FIFTY_TWO_WEEKS,address(owner));
        uint256 tokenId2 = escrow.create_lock_for(1e16, FIFTY_TWO_WEEKS,address(owner2));
        uint256 tokenId3 = escrow.create_lock_for(1e16, FIFTY_TWO_WEEKS,address(owner3));

        skip(5 weeks);
        vm.roll(block.number + 1);

        address[] memory votePools = new address[](3);
        votePools[0] = address(pair);
        votePools[1] = address(pair2);
        votePools[2] = address(pair3);

        uint256[] memory weight = new uint256[](3);
        weight[0] = 10;
        weight[1] = 20;
        weight[2] = 30;

        //user vote.
        vm.prank(address(owner));
        voter.vote(tokenId,votePools,weight);

        vm.prank(address(owner2));
        voter.vote(tokenId2,votePools,weight);
 
        vm.prank(address(owner3));
        voter.vote(tokenId3,votePools,weight);

        voter.pauseGauge(gauge3);

        skip(8 days);
        voter.distribute(gauge);
        voter.distribute(gauge2);
        voter.distribute(gauge3);

        console2.log("gauge get flow:",FLOW.balanceOf(address(gauge)));
        console2.log("gauge2 get flow:",FLOW.balanceOf(address(gauge2)));
        console2.log("gauge3 get flow:",FLOW.balanceOf(address(gauge3)));
        console2.log("remaining flow:",FLOW.balanceOf(address(voter)));
    }
```
out:
```
Ran 1 test for test/Voter.t.sol:VoterTest
[PASS] testPauseGaugeLeadToRemainingToken() (gas: 19148544)
Logs:
  gauge get flow: 333333333333333259574
  gauge2 get flow: 666666666666666740425
  gauge3 get flow: 0
  remaining flow: 1000000000000000000001

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 11.89ms (3.68ms CPU time)
```

Even to the next round those unclaimed flow token is still not add to reward lead to those token get stuck.

## Impact
FLOW token stuck in voter

## Code Snippet
https://github.com/sherlock-audit/2024-06-velocimeter/blob/main/v4-contracts/contracts/Voter.sol#L380-L392
https://github.com/sherlock-audit/2024-06-velocimeter/blob/main/v4-contracts/contracts/Voter.sol#L407-L429

## Tool used
Manual Review

## Recommendation
those code is forked from velocimeter V1 , above issue is already fixed in V2
https://github.com/velodrome-finance/contracts/blob/main/contracts/Voter.sol
```solidity
    function killGauge(address _gauge) external {
        if (_msgSender() != emergencyCouncil) revert NotEmergencyCouncil();
        if (!isAlive[_gauge]) revert GaugeAlreadyKilled();
        // Return claimable back to minter
        uint256 _claimable = claimable[_gauge];
        if (_claimable > 0) {
            IERC20(rewardToken).safeTransfer(minter, _claimable);    <@
            delete claimable[_gauge];
        }
        isAlive[_gauge] = false;
        emit GaugeKilled(_gauge);
    }
```
If _claimable > 0 send reward token back to minter

# [M-01] Voter.replaceFactory() and Voter.addFactory() functions are broken.
## Summary
The Voter.replaceFactory() and Voter.addFactory() functions are broken due to invalid validation.

## Vulnerability Detail
1. In the addFactory() function, the line require(!isFactory[_pairFactory], 'factory true'); is missing.
2. In the replaceFactory() function, the isFactory and isGaugeFactory checks are incorrect:
```solidity
        require(isFactory[_pairFactory], 'factory false'); // <=== should be !isFactory
        require(isGaugeFactory[_gaugeFactory], 'g.fact false'); // <=== should be !isGaugeFactory
```
These issues lead to the invariant being broken, allowing multiple instances of a factory or gauge to be pushed to the factories and gaugeFactories arrays.

## Impact
Broken code. DoS when calling Voter.createGauge().

## Code Snippet
https://github.com/sherlock-audit/2024-06-velocimeter/blob/main/v4-contracts/contracts/Voter.sol#L155-L185

## Tool used
Manual Review

## Recommendation
1. Add the require(!isFactory[_pairFactory], 'factory true'); validation to the addFactory() function.
2. Fix the checks in the replaceFactory() function:
```solidity
-        require(isFactory[_pairFactory], 'factory false');
+        require(!isFactory[_pairFactory], 'factory true');
-        require(isGaugeFactory[_gaugeFactory], 'g.fact false');
+        require(!isGaugeFactory[_gaugeFactory], 'g.fact true');
```