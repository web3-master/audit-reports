/**
 * PoC test for:
 *   `OnChainLiquidator.swapViaCurve` uses `asset` instead of `tokenIn`
 *   when picking the Curve coin index after the wstETH → stETH unwrap.
 *
 * No mainnet fork is required. The PoC uses:
 *   - MockStETH / MockWstETH (1:1 unwrap)
 *   - MockCurveStETHETHPool (coin0 = stETH, coin1 = ETH/NULL_ADDRESS)
 *   - SwapViaCurveHarness: a verbatim copy of the buggy logic from
 *     contracts/liquidator/OnChainLiquidator.sol:480-519, plus the
 *     one-line fix recommended in the audit.
 *
 * The proof has two parts:
 *
 *   (A) Buggy path:
 *       Calling swapViaCurve_BUGGY with asset = wstETH on a pool
 *       configured as the canonical Curve stETH/ETH pool ends up
 *       calling exchange(i = 1, j = 0, dx, 0). On the real Curve
 *       stETH/ETH pool, i = 1 sells ETH (coin1); the pool requires
 *       msg.value == _dx for that leg. The harness sends 0 ETH, so
 *       the call reverts. With `_min_dy = 0` hard-coded, the only
 *       safety net is the pool-side ETH check — there is no slippage
 *       protection at the liquidator layer.
 *
 *   (B) Fixed path:
 *       The one-character change (compare `coin0 == tokenIn` instead
 *       of `coin0 == asset`) makes exchange(0, 1, dx, 0) — the
 *       intended stETH → ETH direction — and the call succeeds.
 */

import { ethers } from 'hardhat';
import { expect } from 'chai';

const NULL_ADDRESS = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';
const ONE_ETHER = ethers.utils.parseEther('1');

describe('PoC — swapViaCurve uses `asset` instead of `tokenIn` after wstETH unwrap', function () {
  async function setup() {
    const MockStETH   = await ethers.getContractFactory('MockStETH');
    const MockWstETH  = await ethers.getContractFactory('MockWstETH');
    const MockPool    = await ethers.getContractFactory('MockCurveStETHETHPool');
    const Harness     = await ethers.getContractFactory('SwapViaCurveHarness');

    const stETH    = await MockStETH.deploy();
    const wstETH   = await MockWstETH.deploy(stETH.address);
    const pool     = await MockPool.deploy(stETH.address);
    const harness  = await Harness.deploy(wstETH.address, stETH.address);

    // Sanity: pool layout matches the canonical Curve stETH/ETH pool.
    expect(await pool.coin0()).to.equal(stETH.address);
    expect(await pool.coin1()).to.equal(NULL_ADDRESS);

    // Pre-fund the pool with ETH so the *correct* (i=0, j=1) leg can pay out.
    const [signer] = await ethers.getSigners();
    await signer.sendTransaction({ to: pool.address, value: ONE_ETHER.mul(10) });

    // Give the harness 1 wstETH to "liquidate".
    await wstETH.mint(harness.address, ONE_ETHER);

    return { stETH, wstETH, pool, harness };
  }

  it('BUGGY: picks (i=1, j=0) — the ETH→stETH direction — and reverts at the ETH leg', async function () {
    const { wstETH, pool, harness } = await setup();

    // The pool's `i==1, j==0` branch requires msg.value == _dx (mirrors
    // the real Curve stETH/ETH pool's ETH-input requirement). The
    // harness never sends ETH, so the call reverts there. The revert
    // message is uniquely produced by that branch, so observing it
    // proves the buggy code reached exchange() with (i=1, j=0).
    await expect(
      harness.swapViaCurve_BUGGY(wstETH.address, pool.address)
    ).to.be.revertedWith('MockCurve: msg.value != _dx (ETH leg)');

    // The harness records indices only AFTER the (failed) exchange call,
    // but the assignment happens before the external call — so the
    // recorded values reflect the buggy decision even though the call
    // reverted (state changes inside a transaction that reverts are
    // rolled back, so we cannot read them here). The fact that the
    // revert message came from the (1,0) branch is the proof.
  });

  it('FIXED: picks (i=0, j=1) — the intended stETH→ETH direction — and succeeds', async function () {
    const { wstETH, pool, harness } = await setup();

    await harness.swapViaCurve_FIXED(wstETH.address, pool.address);

    expect(await harness.lastIdxIn()).to.equal(0);   // sell coin0 = stETH
    expect(await harness.lastIdxOut()).to.equal(1);  // buy  coin1 = ETH

    expect(await pool.called()).to.equal(true);
    expect(await pool.lastI()).to.equal(0);
    expect(await pool.lastJ()).to.equal(1);

    // Note: the audit also recommends replacing the hard-coded `_min_dy = 0`
    // with a min derived from amountOutMin. This PoC only verifies the
    // index-selection fix.
    expect(await pool.lastMinDy()).to.equal(0);
  });
});
