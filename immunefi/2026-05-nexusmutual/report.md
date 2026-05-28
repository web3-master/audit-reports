## Title
Double-payment of CLAIM_DEPOSIT_IN_ETH allows a cover owner to drain ETH from the Pool when an assessment outcome transitions DRAW → ACCEPTED.

## Brief/Intro
`Claims.sol` tracks two independent state flags on a claim: `payoutRedeemed` and `depositRetrieved`. `retrieveDeposit` correctly sets `depositRetrieved = true` when a `DRAW` deposit is refunded, but `redeemClaimPayout` (the ACCEPTED-outcome path) **never reads `depositRetrieved`** and unconditionally instructs `Pool.sendPayout(..., CLAIM_DEPOSIT_IN_ETH)` to refund the deposit a second time. The outcome of an assessment is not monotonic — governance can flip it via `Assessments.extendVotingPeriod` and `Assessments.undoVotes` — so the DRAW → ACCEPTED transition is a real, reachable state path

## Vulnerability Details
The submission flow takes exactly one deposit into the Pool:
```solidity
File: Claims.sol
127:   function submitClaim(
128:     uint32 coverId,
129:     uint96 requestedAmount,
130:     bytes32 ipfsMetadata
131:   ) external payable override whenNotPaused(PAUSE_CLAIMS) returns (Claim memory claim) {
...
188:     require(msg.value == CLAIM_DEPOSIT_IN_ETH, AssessmentDepositNotExact());
189: 
190:     // Transfer the assessment deposit to the pool
191:     (
192:       bool transferSucceeded,
193:       /* bytes data */
194:     ) =  address(pool).call{value: CLAIM_DEPOSIT_IN_ETH}("");
195:     require(transferSucceeded, AssessmentDepositTransferToPoolFailed());
196: 
197:     return claim;
198:   }
```

The DRAW refund path correctly guards on `depositRetrieved` and refunds the deposit:
```solidity
File: Claims.sol
235:   function retrieveDeposit(uint claimId) external override whenNotPaused(PAUSE_CLAIMS) {
236:     Claim memory claim = _claims[claimId];
237:     require(claim.coverId > 0, InvalidClaimId());
238: 
239:     require(
240:       assessments.getAssessment(claimId).getOutcome() == AssessmentOutcome.DRAW,
241:       ClaimNotADraw()
242:     );
243: 
244:     require(!claim.depositRetrieved, DepositAlreadyRetrieved());
245: 
246:     _claims[claimId].depositRetrieved = true;
247: 
248:     address payable coverOwner = payable(coverNFT.ownerOf(claim.coverId));
249: 
250:     pool.sendPayout(0, payable(coverOwner), 0, CLAIM_DEPOSIT_IN_ETH);   // refund #1
251: 
252:     emit ClaimDepositRetrieved(claimId, coverOwner);
253:   }
```

The ACCEPTED redemption path checks `payoutRedeemed` but **not** `depositRetrieved`, and still passes the deposit-refund amount to `Pool.sendPayout`:
```solidity
File: Claims.sol
108:   function _isClaimRedeemable(Claim memory claim, Assessment memory assessment) internal view returns (bool) {
109:     return
110:       assessment.getOutcome() == AssessmentOutcome.ACCEPTED &&
111:       block.timestamp < assessment.votingEnd + assessment.cooldownPeriod + claim.payoutRedemptionPeriod &&
112:       !claim.payoutRedeemed;
113:   }
```
```solidity
File: Claims.sol
205:   function redeemClaimPayout(uint claimId) external override onlyMember whenNotPaused(PAUSE_CLAIMS) {
206: 
207:     Claim memory claim = _claims[claimId];
208:     require(claim.coverId > 0, InvalidClaimId());
209: 
210:     address coverOwner = coverNFT.ownerOf(claim.coverId);
211:     require(coverOwner == msg.sender, NotCoverOwner());
212: 
213:     Assessment memory assessment = assessments.getAssessment(claimId);
214:     require(_isClaimRedeemable(claim, assessment), ClaimNotRedeemable());
215: 
216:     _claims[claimId].payoutRedeemed = true;
217:     _claims[claimId].depositRetrieved = true;
218: 
219:     ramm.updateTwap();
220: 
221:     cover.burnStake(claim.coverId, claim.amount);
222: 
223:     // Send payout in cover asset
224:     pool.sendPayout(claim.coverAsset, payable(coverOwner), claim.amount, CLAIM_DEPOSIT_IN_ETH);  // refund #2 — unconditional
225: 
226:     emit ClaimPayoutRedeemed(coverOwner, claim.amount, claimId, claim.coverId);
227:     emit ClaimDepositRetrieved(claimId, coverOwner);
228:   }
```

The outcome of a finalized assessment is not immutable. 
Governance has explicit tools to mutate it:

`Assessments.extendVotingPeriod` rewrites votingEnd = block.timestamp + VOTING_PERIOD, putting `getOutcome()` back into PENDING and allowing new votes.
```solidity
File: Assessments.sol
360:   function extendVotingPeriod(uint claimId) external override onlyContracts(C_GOVERNOR) {
361:     Assessment memory assessment = _assessments[claimId];
362:     require(assessment.start != 0, InvalidClaimId());
363: 
364:     assessment.votingEnd = (block.timestamp + VOTING_PERIOD).toUint32();
365:     _assessments[claimId] = assessment;
366: 
367:     emit VotingEndChanged(claimId, assessment.votingEnd);
368:   }
```

`Assessments.undoVotes` decrements acceptVotes/denyVotes, so a DRAW (acceptVotes == denyVotes) can become ACCEPTED simply by undoing a DENY ballot — no extension required.
```solidity
File: Assessments.sol
195:   function undoVotes(uint assessorMemberId, uint[] calldata claimIds) external override onlyContracts(C_GOVERNOR) {
196:     uint len = claimIds.length;
197:     for (uint i = 0; i < len; i++) {
198:       uint claimId = claimIds[i];
199:       Ballot memory ballot = _ballots[assessorMemberId][claimId];
200: 
201:       require(ballot.timestamp > 0, HasNotVoted(claimId));
202: 
203:       Assessment memory assessment = _assessments[claimId];
204: 
205:       if (ballot.support) {
206:         assessment.acceptVotes--;
207:       } else {
208:         assessment.denyVotes--;
209:       }
210: 
211:       _assessments[claimId] = assessment;
212:       delete _ballots[assessorMemberId][claimId];
213:       delete _ballotsMetadata[assessorMemberId][claimId];
214: 
215:       emit VoteUndone(claimId, assessorMemberId);
216:     }
```

`AssessmentLib.getOutcome()` is a pure function of the (mutable) tally fields, with no record of any prior finalized outcome.
```solidity
File: AssessmentLib.sol
21:   function getOutcome(Assessment memory assessment) internal view returns(AssessmentOutcome) {
22:     if (block.timestamp <= assessment.votingEnd + assessment.cooldownPeriod) {
23:       return AssessmentOutcome.PENDING;
24:     }
25: 
26:     // Cooldown has passed, the assessment can have a final decision
27:     if (assessment.acceptVotes > assessment.denyVotes) {
28:       return AssessmentOutcome.ACCEPTED;
29:     }
30: 
31:     if (assessment.acceptVotes < assessment.denyVotes) {
32:       return AssessmentOutcome.DENIED;
33:     }
34: 
35:     return AssessmentOutcome.DRAW;
36:   }
```

## Exploit Path
1. User submits a claim and pays `CLAIM_DEPOSIT_IN_ETH` (0.05 ETH) to Pool.
2. Voting and cooldown end with `acceptVotes == denyVotes` → outcome DRAW.
3. User calls `retrieveDeposit(claimId)` → Pool sends 0.05 ETH back. `depositRetrieved = true`, `payoutRedeemed = false`.
4. Governance later calls `undoVotes(...)` to remove a DENY ballot (or `extendVotingPeriod` + a follow-up tally shift). The outcome now reads `ACCEPTED` from `getOutcome()`.
5. Within `payoutRedemptionPeriod`, the cover owner calls `redeemClaimPayout(claimId)`. `_isClaimRedeemable` passes (it only blocks on `payoutRedeemed`). Pool sends out the cover payout **plus a second 0.05 ETH deposit refund**, even though the user already retrieved their deposit in step 3.


## Impact Details
* Direct theft of ETH from the Pool:
It is reproducible on every claim that traverses DRAW → ACCEPTED. The second 0.05 ETH refund is fully unbacked (only one deposit was ever taken in). The bug also breaks the implicit invariant that the deposit is paid out exactly once. The flag `depositRetrieved` is stored in the Claim struct precisely to enforce this invariant, but the ACCEPTED path ignores it.

## Recommended Fix
Make the deposit-refund leg of `redeemClaimPayout` conditional on `!claim.depositRetrieved`.
For example:
```solidity
function redeemClaimPayout(uint claimId) external override onlyMember whenNotPaused(PAUSE_CLAIMS) {
    Claim memory claim = _claims[claimId];
    require(claim.coverId > 0, InvalidClaimId());

    address coverOwner = coverNFT.ownerOf(claim.coverId);
    require(coverOwner == msg.sender, NotCoverOwner());

    Assessment memory assessment = assessments.getAssessment(claimId);
    require(_isClaimRedeemable(claim, assessment), ClaimNotRedeemable());

    uint depositRefund = claim.depositRetrieved ? 0 : CLAIM_DEPOSIT_IN_ETH; //@audit-fix Like this!

    _claims[claimId].payoutRedeemed = true;
    _claims[claimId].depositRetrieved = true;

    ramm.updateTwap();
    cover.burnStake(claim.coverId, claim.amount);

    pool.sendPayout(claim.coverAsset, payable(coverOwner), claim.amount, depositRefund);

    emit ClaimPayoutRedeemed(coverOwner, claim.amount, claimId, claim.coverId);
    if (depositRefund > 0) {
        emit ClaimDepositRetrieved(claimId, coverOwner);
    }
}
```

## References
https://github.com/NexusMutual/smart-contracts/blob/67f531208b693f8edbc6ea46528f164046ed1f0b/contracts/modules/assessment/Claims.sol#L224
