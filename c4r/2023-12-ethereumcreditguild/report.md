| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-the-non-initialized-variable-is-used-in-the-conditional-expression) | The non-initialized variable is used in the conditional expression. |
| [M-01](#m-01-when-a-term-is-offboarded-but-not-cleaned-up-and-then-it-is-onboarded-again-an-attacker-can-offboard-it-freely) | When a term is offboarded but not cleaned up and then it is onboarded again, an attacker can offboard it freely. |
| [M-02](#m-02-an-attacker-can-clean-up-a-term-more-than-twice-so-he-can-redeem-funds-maliciously-and-a-legitimate-term-can-become-impossible-to-be-cleaned-up) | An attacker can clean up a term more than twice, so he can redeem funds maliciously and a legitimate term can become impossible to be cleaned up. |


# [H-01] The non-initialized variable is used in the conditional expression.
## Impact
In SurplusGuildMinter.sol#getRewards function, the variable userStake.lastGaugeLoss, which is not initialized, is used in the conditional expression.
This can raise several serious problems.
For example, once loss has occurred, the gauge will be repeatedly slashed, and the user will lose the CREDIT tokens to stake.

## Proof of Concept
SurplusGuildMinter.sol#getRewards function is following.
```solidity
    function getRewards(
        address user,
        address term
    )
        public
        returns (
            uint256 lastGaugeLoss, // GuildToken.lastGaugeLoss(term)
223:        UserStake memory userStake, // stake state after execution of getRewards()
            bool slashed // true if the user has been slashed
        )
    {
        bool updateState;
        lastGaugeLoss = GuildToken(guild).lastGaugeLoss(term);
229:    if (lastGaugeLoss > uint256(userStake.lastGaugeLoss)) {
            slashed = true;
        }

        // if the user is not staking, do nothing
234:    userStake = _stakes[user][term];
        if (userStake.stakeTime == 0)
            return (lastGaugeLoss, userStake, slashed);

        // compute CREDIT rewards
        ProfitManager(profitManager).claimRewards(address(this)); // this will update profit indexes
        uint256 _profitIndex = ProfitManager(profitManager)
            .userGaugeProfitIndex(address(this), term);
        uint256 _userProfitIndex = uint256(userStake.profitIndex);

        if (_profitIndex == 0) _profitIndex = 1e18;
        if (_userProfitIndex == 0) _userProfitIndex = 1e18;

        uint256 deltaIndex = _profitIndex - _userProfitIndex;

        if (deltaIndex != 0) {
            uint256 creditReward = (uint256(userStake.guild) * deltaIndex) /
                1e18;
            uint256 guildReward = (creditReward * rewardRatio) / 1e18;
            if (slashed) {
                guildReward = 0;
            }

            // forward rewards to user
            if (guildReward != 0) {
                RateLimitedMinter(rlgm).mint(user, guildReward);
                emit GuildReward(block.timestamp, user, guildReward);
            }
            if (creditReward != 0) {
                CreditToken(credit).transfer(user, creditReward);
            }

            // save the updated profitIndex
            userStake.profitIndex = SafeCastLib.safeCastTo160(_profitIndex);
            updateState = true;
        }

        // if a loss occurred while the user was staking, the GuildToken.applyGaugeLoss(address(this))
        // can be called by anyone to slash address(this) and decrement gauge weight etc.
        // The contribution to the surplus buffer is also forfeited.
        if (slashed) {
            emit Unstake(block.timestamp, term, uint256(userStake.credit));
276:        userStake = UserStake({
                stakeTime: uint48(0),
                lastGaugeLoss: uint48(0),
                profitIndex: uint160(0),
                credit: uint128(0),
                guild: uint128(0)
            });
            updateState = true;
        }

        // store the updated stake, if needed
        if (updateState) {
            _stakes[user][term] = userStake;
        }
    }
```
The memory variable userStake which is defined in L223 is used in conditional expression of L234 before initialization by _stakes[user][term] state variable in L229.
Thus since userStake.lastGaugeLoss = 0 in L229, the condition always holds and slashed = true is executed.

This can raises several serious problems.

Example:

For a certain gauge1, the GuildToken.sol#notifyGaugeLoss function is called and the result is lastGaugeLoss[gauge1] = block.timestamp > 0.
user1 calls the SurplusGuildMinter.sol#stake function for gauge1 and stake CREDIT tokens.
user1 tries to stake more CREDIT tokens so he calls the SurplusGuildMinter.sol#stake function for gauge1 again.
Since non-initialized variable is used, the conditional expression of L229 holds true in SurplusGuildMinter.sol#getRewards, therefore slashed = true is executed.
In L276 user1's stake are slashed.

## Lines of code
https://github.com/code-423n4/2023-12-ethereumcreditguild/blob/main/src/loan/SurplusGuildMinter.sol#L229-L234

## Tool used
Manual Review

## Recommended Mitigation Steps
Modify SurplusGuildMinter.sol#getRewards function as the following.
```solidity
    function getRewards(
        address user,
        address term
    )
        public
        returns (
            uint256 lastGaugeLoss, // GuildToken.lastGaugeLoss(term)
            UserStake memory userStake, // stake state after execution of getRewards()
            bool slashed // true if the user has been slashed
        )
    {
        bool updateState;
        lastGaugeLoss = GuildToken(guild).lastGaugeLoss(term);
+       userStake = _stakes[user][term];
        if (lastGaugeLoss > uint256(userStake.lastGaugeLoss)) {
            slashed = true;
        }

        // if the user is not staking, do nothing
_       userStake = _stakes[user][term];
        if (userStake.stakeTime == 0)
            return (lastGaugeLoss, userStake, slashed);

        // compute CREDIT rewards
        ProfitManager(profitManager).claimRewards(address(this)); // this will update profit indexes
        uint256 _profitIndex = ProfitManager(profitManager)
            .userGaugeProfitIndex(address(this), term);
        uint256 _userProfitIndex = uint256(userStake.profitIndex);

        if (_profitIndex == 0) _profitIndex = 1e18;
        if (_userProfitIndex == 0) _userProfitIndex = 1e18;

        uint256 deltaIndex = _profitIndex - _userProfitIndex;

        if (deltaIndex != 0) {
            uint256 creditReward = (uint256(userStake.guild) * deltaIndex) /
                1e18;
            uint256 guildReward = (creditReward * rewardRatio) / 1e18;
            if (slashed) {
                guildReward = 0;
            }

            // forward rewards to user
            if (guildReward != 0) {
                RateLimitedMinter(rlgm).mint(user, guildReward);
                emit GuildReward(block.timestamp, user, guildReward);
            }
            if (creditReward != 0) {
                CreditToken(credit).transfer(user, creditReward);
            }

            // save the updated profitIndex
            userStake.profitIndex = SafeCastLib.safeCastTo160(_profitIndex);
            updateState = true;
        }

        // if a loss occurred while the user was staking, the GuildToken.applyGaugeLoss(address(this))
        // can be called by anyone to slash address(this) and decrement gauge weight etc.
        // The contribution to the surplus buffer is also forfeited.
        if (slashed) {
            emit Unstake(block.timestamp, term, uint256(userStake.credit));
            userStake = UserStake({
                stakeTime: uint48(0),
                lastGaugeLoss: uint48(0),
                profitIndex: uint160(0),
                credit: uint128(0),
                guild: uint128(0)
            });
            updateState = true;
        }

        // store the updated stake, if needed
        if (updateState) {
            _stakes[user][term] = userStake;
        }
    }
```

# [M-01] When a term is offboarded but not cleaned up and then it is onboarded again, an attacker can offboard it freely.
## Impact
When a term is offboarded but not cleaned up and then it is onboarded again, any user who don't have any weight can propose and offboard it freely without passing supporting process.

## Proof of Concept
We say that a term is offboarded.
```solidity
    function offboard(address term) external whenNotPaused {
        require(canOffboard[term], "LendingTermOffboarding: quorum not met");

        // update protocol config
        // this will revert if the term has already been offboarded
        // through another mean.
        GuildToken(guildToken).removeGauge(term);

        // pause psm redemptions
        if (
            nOffboardingsInProgress++ == 0 &&
            !SimplePSM(psm).redemptionsPaused()
        ) {
            SimplePSM(psm).setRedemptionsPaused(true);
        }

        emit Offboard(block.timestamp, term);
    }
```
Then canOffboard[term] == true.
Because of some reasons, for example issuance not repayed, it remains not cleaned up and then it can be onboarded again.
At this time, any user can propose it in offboarding. Then polls[block.number][term] is smaller than quorum but canOffboard[term] == true.
So any user can offboard it immediately.
```solidity
    function proposeOffboard(address term) external whenNotPaused {
        require(
            polls[block.number][term] == 0,
            "LendingTermOffboarding: poll exists"
        );
        require(
            block.number > lastPollBlock[term] + POLL_DURATION_BLOCKS,
            "LendingTermOffboarding: poll active"
        );
        // Check that the term is an active gauge
        require(
            GuildToken(guildToken).isGauge(term),
            "LendingTermOffboarding: not an active term"
        );

        polls[block.number][term] = 1; // voting power
        lastPollBlock[term] = block.number;
        emit OffboardSupport(
            block.timestamp,
            term,
            block.number,
            address(0),
            1
        );
    }
```

## Lines of code
https://github.com/code-423n4/2023-12-ethereumcreditguild/blob/main/src/governance/LendingTermOffboarding.sol#L89

## Tool used
Manual Review

## Recommended Mitigation Steps
LendingTermOffboarding.sol#proposeOffboard function has to be modified as follows.
```solidity
    function proposeOffboard(address term) external whenNotPaused {
        require(
            polls[block.number][term] == 0,
            "LendingTermOffboarding: poll exists"
        );
        require(
            block.number > lastPollBlock[term] + POLL_DURATION_BLOCKS,
            "LendingTermOffboarding: poll active"
        );
        // Check that the term is an active gauge
        require(
            GuildToken(guildToken).isGauge(term),
            "LendingTermOffboarding: not an active term"
        );

        polls[block.number][term] = 1; // voting power
        lastPollBlock[term] = block.number;
+       canOffboard[term] = false;

        emit OffboardSupport(
            block.timestamp,
            term,
            block.number,
            address(0),
            1
        );
    }
```

# [M-02] An attacker can clean up a term more than twice, so he can redeem funds maliciously and a legitimate term can become impossible to be cleaned up.
## Impact
An attacker can clean up a term more than twice by using little amount of guildToken and can release redeemption-paused flag, so he can redeem funds maliciously and a legitimate term can become impossible to be cleaned up because of mismatching of offboard and cleanup count.

## Proof of Concept
Through LendingTermOffboarding.sol#proposeOffboard -> supportOffboard -> offboard -> cleanup, a term has been just cleaned up. So we can say that canOffboard[term] == false and polls[snapshotBlock][term] >= quorum.
And we say still block.number <= snapshotBlock + POLL_DURATION_BLOCKS.
Then, an attacker who owned 1 vote of guildToken calls supportOffboard function.
```solidity
    function supportOffboard(
        uint256 snapshotBlock,
        address term
    ) external whenNotPaused {
120     require(
            block.number <= snapshotBlock + POLL_DURATION_BLOCKS,
            "LendingTermOffboarding: poll expired"
        );
        uint256 _weight = polls[snapshotBlock][term];
125     require(_weight != 0, "LendingTermOffboarding: poll not found");
        uint256 userWeight = GuildToken(guildToken).getPastVotes(
            msg.sender,
            snapshotBlock
        );
130     require(userWeight != 0, "LendingTermOffboarding: zero weight");
131     require(
            userPollVotes[msg.sender][snapshotBlock][term] == 0,
            "LendingTermOffboarding: already voted"
        );

        userPollVotes[msg.sender][snapshotBlock][term] = userWeight;
        polls[snapshotBlock][term] = _weight + userWeight;
138     if (_weight + userWeight >= quorum) {
139         canOffboard[term] = true;
        }
        emit OffboardSupport(
            block.timestamp,
            term,
            snapshotBlock,
            msg.sender,
            userWeight
        );
    }
```
As we can see above, the attacker's call isn't reverted on L120, 125, 130, 131.
And on L138 _weight + userWeight > quorum and canOffboard[term] becomes true again.
And then the attacker calls cleanup function.
```solidity
    function cleanup(address term) external whenNotPaused {
176     require(canOffboard[term], "LendingTermOffboarding: quorum not met");
        require(
177         LendingTerm(term).issuance() == 0,
            "LendingTermOffboarding: not all loans closed"
        );
        require(
182         GuildToken(guildToken).isDeprecatedGauge(term),
            "LendingTermOffboarding: re-onboarded"
        );

        // update protocol config
        core().revokeRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, term);
        core().revokeRole(CoreRoles.GAUGE_PNL_NOTIFIER, term);

        // unpause psm redemptions
        if (
192         --nOffboardingsInProgress == 0 && SimplePSM(psm).redemptionsPaused()
        ) {
194         SimplePSM(psm).setRedemptionsPaused(false);
        }

        canOffboard[term] = false;
        emit Cleanup(block.timestamp, term);
    }
```
L176 isn't reverted and if we assume that all loans are closed L177 isn't reverted as well.
And the term has been already removed on L177 of offboard function, so L182 is not reverted.
```solidity
    function offboard(address term) external whenNotPaused {
        require(canOffboard[term], "LendingTermOffboarding: quorum not met");

        // update protocol config
        // this will revert if the term has already been offboarded
        // through another mean.
159     GuildToken(guildToken).removeGauge(term);

        // pause psm redemptions
        if (
            nOffboardingsInProgress++ == 0 &&
            !SimplePSM(psm).redemptionsPaused()
        ) {
            SimplePSM(psm).setRedemptionsPaused(true);
        }

        emit Offboard(block.timestamp, term);
    }
```
Therefore, L192 is run. If only one term is remained in state of offboard, --nOffboardingProgress == 0
and L192 is run. Then redeemption-paused state is released.
On the other hand, the remained legitimate term becomes impossible to be cleaned up because L192 is reverted because of underflow.

## Lines of code
https://github.com/code-423n4/2023-12-ethereumcreditguild/blob/main/src/governance/LendingTermOffboarding.sol#L116-L148

## Tool used
Manual Review

## Recommended Mitigation Steps
LendingTermOffboarding.sol#supportOffboard function has to be rewritten as follows.
```solidity
    function supportOffboard(
        uint256 snapshotBlock,
        address term
    ) external whenNotPaused {
        require(
            block.number <= snapshotBlock + POLL_DURATION_BLOCKS,
            "LendingTermOffboarding: poll expired"
        );
        
+       // Check that the term is an active gauge
+       require(
+           GuildToken(guildToken).isGauge(term),
+           "LendingTermOffboarding: not an active term"
+       );

        uint256 _weight = polls[snapshotBlock][term];
        require(_weight != 0, "LendingTermOffboarding: poll not found");
        uint256 userWeight = GuildToken(guildToken).getPastVotes(
            msg.sender,
            snapshotBlock
        );
        require(userWeight != 0, "LendingTermOffboarding: zero weight");
        require(
            userPollVotes[msg.sender][snapshotBlock][term] == 0,
            "LendingTermOffboarding: already voted"
        );

        userPollVotes[msg.sender][snapshotBlock][term] = userWeight;
        polls[snapshotBlock][term] = _weight + userWeight;
        if (_weight + userWeight >= quorum) {
            canOffboard[term] = true;
        }
        emit OffboardSupport(
            block.timestamp,
            term,
            snapshotBlock,
            msg.sender,
            userWeight
        );
    }
```