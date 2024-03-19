| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-the-total-amount-of-credits-per-allocator-can-be-exceed-maxvoicecreditsperallocator-in-qvsimplestrategy) | The total amount of credits per allocator can be exceed maxVoiceCreditsPerAllocator in QVSimpleStrategy. |
| [M-01](#m-01-allocation-can-be-set-invalid-by-incorrect-calculation-for-quadratic-voting-strategies-in-qvbasestrategy) | Allocation can be set invalid by incorrect calculation for quadratic voting strategies in QVBaseStrategy. |
| [M-02](#m-02-function-_distribute-of-rfpsimplestrategysol-would-be-reverted-due-to-the-coding-error) | Function _distribute of RFPSimpleStrategy.sol would be reverted due to the coding error. |


# [H-01] The total amount of credits per allocator can be exceed maxVoiceCreditsPerAllocator in QVSimpleStrategy.
## Summary
When _sender allocates, allocator.voiceCredits is not updated, so the total amount of credits per allocator can exceed maxVoiceCreditsPerAllocator in QVSimpleStrategy.

## Vulnerability Detail
QVSimpleStrategy._allocate is as following.
```solidity
File: QVSimpleStrategy.sol
107:     function _allocate(bytes memory _data, address _sender) internal virtual override {
108:         (address recipientId, uint256 voiceCreditsToAllocate) = abi.decode(_data, (address, uint256));
109: 
110:         // spin up the structs in storage for updating
111:         Recipient storage recipient = recipients[recipientId];
112:         Allocator storage allocator = allocators[_sender];
113: 
114:         // check that the sender can allocate votes
115:         if (!_isValidAllocator(_sender)) revert UNAUTHORIZED();
116: 
117:         // check that the recipient is accepted
118:         if (!_isAcceptedRecipient(recipientId)) revert RECIPIENT_ERROR(recipientId);
119: 
120:         // check that the recipient has voice credits left to allocate
121:         if (!_hasVoiceCreditsLeft(voiceCreditsToAllocate, allocator.voiceCredits)) revert INVALID();
122: 
123:         _qv_allocate(allocator, recipient, recipientId, voiceCreditsToAllocate, _sender);
124:     }
```
On the other hand, _hasVoiceCreditsLeft called by this function is as following.
```solidity
File: QVSimpleStrategy.sol
144:     function _hasVoiceCreditsLeft(uint256 _voiceCreditsToAllocate, uint256 _allocatedVoiceCredits)
145:         internal
146:         view
147:         override
148:         returns (bool)
149:     {
150:         return _voiceCreditsToAllocate + _allocatedVoiceCredits <= maxVoiceCreditsPerAllocator;
151:     }
```
From the implementation of these functions, we can see that the amount of total credits per allocator cannot exceed maxVoiceCreditsPerAllocator.
So _allocate necessarily has to update allocator.voiceCredits.
But the real implementation of _allocate didn't update allocator.voiceCredits anywhere.
As a result, the total amount of credits per allocator can exceed maxVoiceCreditsPerAllocator.

Meanwhile, this operation is implemented correctly in HackathonQVStrategy._allocate#L282.
```solidity
File: HackathonQVStrategy.sol
263:     function _allocate(bytes memory _data, address _sender) internal override {
264:         (address recipientId, uint256 nftId, uint256 voiceCreditsToAllocate) =
265:             abi.decode(_data, (address, uint256, uint256));
266: 
267:         // check that the sender can allocate votes
268:         if (nft.ownerOf(nftId) != _sender) {
269:             revert UNAUTHORIZED();
270:         }
271: 
272:         // spin up the structs in storage for updating
273:         Recipient storage recipient = recipients[recipientId];
274:         Allocator storage allocator = allocators[_sender];
275: 
276:         if (!_hasVoiceCreditsLeft(voiceCreditsToAllocate, voiceCreditsUsedPerNftId[nftId])) {
277:             revert INVALID();
278:         }
279: 
280:         _qv_allocate(allocator, recipient, recipientId, voiceCreditsToAllocate, _sender);
281: 
282:         voiceCreditsUsedPerNftId[nftId] += voiceCreditsToAllocate;
283: 
284:         TmpRecipient memory tmp = TmpRecipient({recipientId: address(0), voteRank: 0, foundRecipientAtIndex: 0});
285: 
```
## Impact
The total amount of credits per allocator can exceed maxVoiceCreditsPerAllocator.

## Code Snippet
https://github.com/sherlock-audit/2023-09-Gitcoin/blob/main/allo-v2/contracts/strategies/qv-simple/QVSimpleStrategy.sol#L107-L124

## Tool used
Manual Review

## Recommendation
By the end of QVSimpleStrategy._allocate, the following operation has to be added.
```solidity
    _allocator.voiceCredits += voiceCreditsToAllocate;
```

# [M-01] Allocation can be set invalid by incorrect calculation for quadratic voting strategies in QVBaseStrategy.
## Summary
In line 529 of QVBaseStrategy, operator += is used mistakenly instead of operator =. As a result, the allocation can be calculated incorrectly.

## Vulnerability Detail
In function _qv_allocate of QVBaseStrategy, an allocator allocate more credit with amount _voiceCreditsToAllocate to a recipient with _recipientId.
```solidity
    /// @notice Allocate voice credits to a recipient
    /// @dev This can only be called during active allocation period
    /// @param _allocator The allocator details
    /// @param _recipient The recipient details
    /// @param _recipientId The ID of the recipient
    /// @param _voiceCreditsToAllocate The voice credits to allocate to the recipient
    /// @param _sender The sender of the transaction
    function _qv_allocate(
        Allocator storage _allocator,
        Recipient storage _recipient,
        address _recipientId,
        uint256 _voiceCreditsToAllocate,
        address _sender
    ) internal onlyActiveAllocation {
        // check the `_voiceCreditsToAllocate` is > 0
        if (_voiceCreditsToAllocate == 0) revert INVALID();

        // get the previous values
        uint256 creditsCastToRecipient = _allocator.voiceCreditsCastToRecipient[_recipientId];
        uint256 votesCastToRecipient = _allocator.votesCastToRecipient[_recipientId];

        // get the total credits and calculate the vote result
        uint256 totalCredits = _voiceCreditsToAllocate + creditsCastToRecipient;
        uint256 voteResult = _sqrt(totalCredits * 1e18);

        // update the values
        voteResult -= votesCastToRecipient;
        totalRecipientVotes += voteResult;
        _recipient.totalVotesReceived += voteResult;

        _allocator.voiceCreditsCastToRecipient[_recipientId] += totalCredits;
        _allocator.votesCastToRecipient[_recipientId] += voteResult;

        // emit the event with the vote results
        emit Allocated(_recipientId, voteResult, _sender);
    }
```
As you can see from the code creditsCastToRecipient = _allocator.voiceCreditsCastToRecipient[_recipientId] in line 517 and totalCredits = _voiceCreditsToAllocate + creditsCastToRecipient in line 521 and _allocator.voiceCreditsCastToRecipient[_recipientId] += totalCredits in line 529, the value _allocator.voiceCreditsCastToRecipient[_recipientId] will be increased by _allocator.voiceCreditsCastToRecipient[_recipientId] + _voiceCreditsToAllocate instead of _voiceCreditsToAllocate, due to the use of operator += instead of operator = in line 529.

As a result, if the allocator calls function _qv_allocate again, the value _allocator.votesCastToRecipient[_recipientId] and totalRecipienttVotes can be set invalid and the funds can be distributed incorrectly.

Example:
Suppose that _allocator.voiceCreditsCastToRecipient[_recipientId] = 100 and the allocator wants to allocate 50 more to the recipient.
Then creditsCastToRecipient = 100 in line 517 and totalCredits = 50 + 100 = 150 in line 521 and _allocator.voiceCreditsCastToRecipient[_recipientId] will be 100 + 150 = 250 instead of correct value 150 in line 529. So it will be inflated by 100.
As a result, if the allocator calls function _qv_allocate again, the value _allocator.votesCastToRecipient[_recipientId] and totalRecipienttVotes are calculated incorrectly.

## Impact
Allocations to recipients can be set invalid and funds can be distributed incorrectly.

## Code Snippet
https://github.com/sherlock-audit/2023-09-Gitcoin/blob/main/allo-v2/contracts/strategies/qv-base/QVBaseStrategy.sol#L529

## Tool used
Manual Review

## Recommendation
Replace the operator += with = in QVBaseStrategy.sol#L529.

# [M-02] Function _distribute of RFPSimpleStrategy.sol would be reverted due to the coding error.
## Summary
Function _distribute of RFPSimpleStrategy.sol would be reverted due to the coding error.

## Vulnerability Detail
The _distribute function of RFPSimpleStrategy.sol is as follows.
```solidity
File: RFPSimpleStrategy.sol
414:     /// @notice Distribute the upcoming milestone to acceptedRecipientId.
415:     /// @dev '_sender' must be a pool manager to distribute.
416:     /// @param _sender The sender of the distribution
417:     function _distribute(address[] memory, bytes memory, address _sender)
418:         internal
419:         virtual
420:         override
421:         onlyInactivePool
422:         onlyPoolManager(_sender)
423:     {
...
431:         // make sure has enough funds to distribute based on the proposal bid
432:         if (recipient.proposalBid > poolAmount) revert NOT_ENOUGH_FUNDS();
433: 
434:         // Calculate the amount to be distributed for the milestone
435:         uint256 amount = (recipient.proposalBid * milestone.amountPercentage) / 1e18;
436: 
437:         // Get the pool, subtract the amount and transfer to the recipient
438:         poolAmount -= amount;
...
450:     }
```
L432 is the validation check to make sure pool has enough funds for this milestone's distribution.
But the poolAmount is mistakenly compared against recipient.proposalBid, which is invalid parameter to compare.
L432 must compare poolAmount with L435's amount.
poolAmount is current funds of the pool. And this amount is getting decreased by every _distribute call.
Meanwhile, recipient.proposalBid is fixed value so L432's compare can be reverted after few _distribute calls.

## Impact
Pool's legitimate funds might fail to be distributed.

## Code Snippet
https://github.com/sherlock-audit/2023-09-Gitcoin/blob/main/allo-v2/contracts/strategies/rfp-simple/RFPSimpleStrategy.sol#L432

## Tool used
Manual Review

## Recommendation
```solidity
File: RFPSimpleStrategy.sol
414:     /// @notice Distribute the upcoming milestone to acceptedRecipientId.
415:     /// @dev '_sender' must be a pool manager to distribute.
416:     /// @param _sender The sender of the distribution
417:     function _distribute(address[] memory, bytes memory, address _sender)
418:         internal
419:         virtual
420:         override
421:         onlyInactivePool
422:         onlyPoolManager(_sender)
423:     {
...
431: -        // make sure has enough funds to distribute based on the proposal bid
432: -        if (recipient.proposalBid > poolAmount) revert NOT_ENOUGH_FUNDS();
433: 
434:         // Calculate the amount to be distributed for the milestone
435:         uint256 amount = (recipient.proposalBid * milestone.amountPercentage) / 1e18;
436: 

 +           // make sure has enough funds to distribute based on the proposal bid
 +           if (amount > poolAmount) revert NOT_ENOUGH_FUNDS();

437:         // Get the pool, subtract the amount and transfer to the recipient
438:         poolAmount -= amount;
...
450:     }
```
