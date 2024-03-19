| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-the-first-founder-is-to-be-allocated-less-tokens-than-other-founders) | The first founder is to be allocated less tokens than other founders. |
| [H-02](#h-02-it-can-be-impossible-to-settle-the-auction) | It can be impossible to settle the auction. |


# [H-01] The first founder is to be allocated less tokens than other founders.
## Summary
Due to computational errors, the first founder is allocated less tokens than the other founders.

## Vulnerability Detail
Token.sol#_addFounders function is as follows.
```solidity
File: Token.sol
120:     function _addFounders(IManager.FounderParams[] calldata _founders, uint256 reservedUntilTokenId) internal {
121:         // Used to store the total percent ownership among the founders
122:         uint256 totalOwnership;
123: 
124:         uint8 numFoundersAdded = 0;
125: 
126:         unchecked {
127:             // For each founder:
128:             for (uint256 i; i < _founders.length; ++i) {
129:                 // Cache the percent ownership
130:                 uint256 founderPct = _founders[i].ownershipPct;
131: 
132:                 // Continue if no ownership is specified
133:                 if (founderPct == 0) {
134:                     continue;
135:                 }
136: 
137:                 // Update the total ownership and ensure it's valid
138:                 totalOwnership += founderPct;
139: 
140:                 // Check that founders own less than 100% of tokens
141:                 if (totalOwnership > 99) {
142:                     revert INVALID_FOUNDER_OWNERSHIP();
143:                 }
144: 
145:                 // Compute the founder's id
146:                 uint256 founderId = numFoundersAdded++;
147: 
148:                 // Get the pointer to store the founder
149:                 Founder storage newFounder = founder[founderId];
150: 
151:                 // Store the founder's vesting details
152:                 newFounder.wallet = _founders[i].wallet;
153:                 newFounder.vestExpiry = uint32(_founders[i].vestExpiry);
154:                 // Total ownership cannot be above 100 so this fits safely in uint8
155:                 newFounder.ownershipPct = uint8(founderPct);
156: 
157:                 // Compute the vesting schedule
158:                 uint256 schedule = 100 / founderPct;
159: 
160:                 // Used to store the base token id the founder will recieve
161:                 uint256 baseTokenId = reservedUntilTokenId;
162: 
163:                 // For each token to vest:
164:                 for (uint256 j; j < founderPct; ++j) {
165:                     // Get the available token id
166:                     baseTokenId = _getNextTokenId(baseTokenId);
167: 
168:                     // Store the founder as the recipient
169:                     tokenRecipient[baseTokenId] = newFounder;
170: 
171:                     emit MintScheduled(baseTokenId, founderId, newFounder);
172: 
173:                     // Update the base token id
174:                     baseTokenId = (baseTokenId + schedule) % 100;
175:                 }
176:             }
177: 
178:             // Store the founders' details
179:             settings.totalOwnership = uint8(totalOwnership);
180:             settings.numFounders = numFoundersAdded;
181:         }
182:     }
```
baseTokenId is initialized to reservedUntilTokenId and then it's value is determined by _getNextTokenId function in line 166.
The code of Token.sol#_getNextTokenId function is the following.
```solidity
File: Token.sol
186:     function _getNextTokenId(uint256 _tokenId) internal view returns (uint256) {
187:         unchecked {
188:             while (tokenRecipient[_tokenId].wallet != address(0)) {
189:                 _tokenId = (++_tokenId) % 100;
190:             }
191: 
192:             return _tokenId;
193:         }
194:     }
```
At the start time, the condition of line 188 does not hold. Thus the first baseTokenId value of the first founder will be equal to reservedUntilTokenId.
So the first baseTokenId value of the first founder will be over 100 when reservedUntilTokenId >= 100.
On the other hand, Token.sol#_isForFounder function is as follows.
```solidity
File: Token.sol
263:     function _isForFounder(uint256 _tokenId) private returns (bool) {
264:         // Get the base token id
265:         uint256 baseTokenId = _tokenId % 100;
266: 
267:         // If there is no scheduled recipient:
268:         if (tokenRecipient[baseTokenId].wallet == address(0)) {
269:             return false;
270: 
271:             // Else if the founder is still vesting:
272:         } else if (block.timestamp < tokenRecipient[baseTokenId].vestExpiry) {
273:             // Mint the token to the founder
274:             _mint(tokenRecipient[baseTokenId].wallet, _tokenId);
275: 
276:             return true;
277: 
278:             // Else the founder has finished vesting:
279:         } else {
280:             // Remove them from future lookups
281:             delete tokenRecipient[baseTokenId];
282: 
283:             return false;
284:         }
285:     }
```
From above, baseTokenId < 100 always hold.
Thus when reservedUntilTokenId >= 100, the first founder is to be allocated less tokens than other founders.

Example:

Suppose that _founders.length == 2, _founders[0].ownershipPct = 2, _founders[1].ownershipPct = 2 and reservedUntilTokenId == 100.
Then, as a result of _addFounders function, it is hold that tokenRecipient[100] = tokenRecipient[50] = _founders[0] and tokenRecipient[1] = tokenRecipient[51] = _founders[1].
Since 0 <= baseTokenId < 100 holds in _isForFounder function, tokenRecipient[100] will never be used and thus _founder[0] will be allocated tokens as half of the _founder[1].

## Impact
The first founder is to be allocated less tokens than other founders.
In particular, when ownershipPct == 1 of the first founder, he will not be allocated a token at all.

## Code Snippet
https://github.com/sherlock-audit/2023-09-nounsbuilder/blob/main/nouns-protocol/src/token/Token.sol#L161

## Tool used
Manual Review

## Recommendation
Modify Token.sol#L161 as follows.
```solidity
-               uint256 baseTokenId = reservedUntilTokenId;
+               uint256 baseTokenId = reservedUntilTokenId % 100;
```

# [H-02] It can be impossible to settle the auction.
## Summary
In the settlement of auction, partial amount of highestBid is sent to builder and referal, founder.
When rounding error occurs, the eth amount which is sent to rewardManager is not equal to the sum of rewards and the legitimate behavior can be reverted.

## Vulnerability Detail
The Auction.sol#_settleAuction() which settles auction is as follow.
```solidity
File: Auction.sol
244:     function _settleAuction() private {
245:         // Get a copy of the current auction
246:         Auction memory _auction = auction;
247: 
248:         // Ensure the auction wasn't already settled
249:         if (auction.settled) revert AUCTION_SETTLED();
250: 
251:         // Ensure the auction had started
252:         if (_auction.startTime == 0) revert AUCTION_NOT_STARTED();
253: 
254:         // Ensure the auction is over
255:         if (block.timestamp < _auction.endTime) revert AUCTION_ACTIVE();
256: 
257:         // Mark the auction as settled
258:         auction.settled = true;
259: 
260:         // If a bid was placed:
261:         if (_auction.highestBidder != address(0)) {
262:             // Cache the amount of the highest bid
263:             uint256 highestBid = _auction.highestBid;
264: 
265:             // If the highest bid included ETH: Pay rewards and transfer remaining amount to the DAO treasury
266:             if (highestBid != 0) {
267:                 // Calculate rewards
268:                 RewardSplits memory split = _computeTotalRewards(currentBidReferral, highestBid, founderReward.percentBps);
269: 
270:                 if (split.totalRewards != 0) {
271:                     // Deposit rewards
272:                     rewardsManager.depositBatch{ value: split.totalRewards }(split.recipients, split.amounts, split.reasons, "");
273:                 }
274: 
275:                 // Deposit remaining amount to treasury
276:                 _handleOutgoingTransfer(settings.treasury, highestBid - split.totalRewards);
277:             }
278: 
279:             // Transfer the token to the highest bidder
280:             token.transferFrom(address(this), _auction.highestBidder, _auction.tokenId);
281: 
282:             // Else no bid was placed:
283:         } else {
284:             // Burn the token
285:             token.burn(_auction.tokenId);
286:         }
287: 
288:         emit AuctionSettled(_auction.tokenId, _auction.highestBidder, _auction.highestBid);
289:     }
```
The Auction.sol#_computeTotalRewards() function which is called on L268 of the _settleAuction() function is as follow.
```solidity
File: Auction.sol
465:     function _computeTotalRewards(
466:         address _currentBidRefferal,
467:         uint256 _finalBidAmount,
468:         uint256 _founderRewardBps
469:     ) internal view returns (RewardSplits memory split) {
470:         // Get global builder recipient from manager
471:         address builderRecipient = manager.builderRewardsRecipient();
472: 
473:         // Calculate the total rewards percentage
474:         uint256 totalBPS = _founderRewardBps + referralRewardsBPS + builderRewardsBPS;
475: 
476:         // Verify percentage is not more than 100
477:         if (totalBPS >= BPS_PER_100_PERCENT) {
478:             revert INVALID_REWARD_TOTAL();
479:         }
480: 
481:         // Calulate total rewards
482:         split.totalRewards = (_finalBidAmount * totalBPS) / BPS_PER_100_PERCENT;
483: 
484:         // Check if founder reward is enabled
485:         bool hasFounderReward = _founderRewardBps > 0 && founderReward.recipient != address(0);
486: 
487:         // Set array size based on if founder reward is enabled
488:         uint256 arraySize = hasFounderReward ? 3 : 2;
489: 
490:         // Initialize arrays
491:         split.recipients = new address[](arraySize);
492:         split.amounts = new uint256[](arraySize);
493:         split.reasons = new bytes4[](arraySize);
494: 
495:         // Set builder reward
496:         split.recipients[0] = builderRecipient;
497:         split.amounts[0] = (_finalBidAmount * builderRewardsBPS) / BPS_PER_100_PERCENT;
498: 
499:         // Set referral reward
500:         split.recipients[1] = _currentBidRefferal != address(0) ? _currentBidRefferal : builderRecipient;
501:         split.amounts[1] = (_finalBidAmount * referralRewardsBPS) / BPS_PER_100_PERCENT;
502: 
503:         // Set founder reward if enabled
504:         if (hasFounderReward) {
505:             split.recipients[2] = founderReward.recipient;
506:             split.amounts[2] = (_finalBidAmount * _founderRewardBps) / BPS_PER_100_PERCENT;
507:         }
508:     }
```
On L497,501,506 the rewards which are assigned to builder, referal and founder are calculated.
But in this case, by rounding error, the spilt.totalRewards can possibly be not equal to the sum of spilt[0-2].amount.

The test version of rewardManager is implemented in the MockProtocolRewards.sol.
The MockProtocolRewards.sol#depositBatch() function is as follow.
```solidity
File: MockProtocolRewards.sol
30:     function depositBatch(
31:         address[] calldata recipients,
32:         uint256[] calldata amounts,
33:         bytes4[] calldata reasons,
34:         string calldata
35:     ) external payable {
36:         uint256 numRecipients = recipients.length;
37: 
38:         if (numRecipients != amounts.length || numRecipients != reasons.length) {
39:             revert ARRAY_LENGTH_MISMATCH();
40:         }
41: 
42:         uint256 expectedTotalValue;
43: 
44:         for (uint256 i; i < numRecipients; ) {
45:             expectedTotalValue += amounts[i];
46: 
47:             unchecked {
48:                 ++i;
49:             }
50:         }
51: 
52:         if (msg.value != expectedTotalValue) {
53:             revert INVALID_DEPOSIT();
54:         }
55: 
56:         address currentRecipient;
57:         uint256 currentAmount;
58: 
59:         for (uint256 i; i < numRecipients; ) {
60:             currentRecipient = recipients[i];
61:             currentAmount = amounts[i];
62: 
63:             if (currentRecipient == address(0)) {
64:                 revert ADDRESS_ZERO();
65:             }
66: 
67:             balanceOf[currentRecipient] += currentAmount;
68: 
69:             unchecked {
70:                 ++i;
71:             }
72:         }
73:     }
```
On the L45 and L52, when msg.value is not equal to the sum of amounts which is setted as parameter, the revert occurs.

## Impact
When rounding error occurs, the eth amount which is sent to rewardManager is not equal to the sum of rewards and the legitimate behavior could be reverted.
So the settlement of auction can be reverted by rounding error and it can be impossible to settle the auction.

## Code Snippet
https://github.com/sherlock-audit/2023-09-nounsbuilder/blob/main/nouns-protocol/src/auction/Auction.sol#L482

## Tool used
Manual Review

## Recommendation
The Auction.sol#_computeTotalRewards() function should be rewritten as follow.
```solidity
    function _computeTotalRewards(
        address _currentBidRefferal,
        uint256 _finalBidAmount,
        uint256 _founderRewardBps
    ) internal view returns (RewardSplits memory split) {
        // Get global builder recipient from manager
        address builderRecipient = manager.builderRewardsRecipient();

        // Calculate the total rewards percentage
        uint256 totalBPS = _founderRewardBps + referralRewardsBPS + builderRewardsBPS;

        // Verify percentage is not more than 100
        if (totalBPS >= BPS_PER_100_PERCENT) {
            revert INVALID_REWARD_TOTAL();
        }

        // Calulate total rewards
-       split.totalRewards = (_finalBidAmount * totalBPS) / BPS_PER_100_PERCENT;

        // Check if founder reward is enabled
        bool hasFounderReward = _founderRewardBps > 0 && founderReward.recipient != address(0);

        // Set array size based on if founder reward is enabled
        uint256 arraySize = hasFounderReward ? 3 : 2;

        // Initialize arrays
        split.recipients = new address[](arraySize);
        split.amounts = new uint256[](arraySize);
        split.reasons = new bytes4[](arraySize);

        // Set builder reward
        split.recipients[0] = builderRecipient;
        split.amounts[0] = (_finalBidAmount * builderRewardsBPS) / BPS_PER_100_PERCENT;

        // Set referral reward
        split.recipients[1] = _currentBidRefferal != address(0) ? _currentBidRefferal : builderRecipient;
        split.amounts[1] = (_finalBidAmount * referralRewardsBPS) / BPS_PER_100_PERCENT;

        // Set founder reward if enabled
        if (hasFounderReward) {
            split.recipients[2] = founderReward.recipient;
            split.amounts[2] = (_finalBidAmount * _founderRewardBps) / BPS_PER_100_PERCENT;
        }

+       for(uint256 i = 0; i < arraySize; i++){
+           split.totalRewards += split.amounts[i];
+       }

    }
```
