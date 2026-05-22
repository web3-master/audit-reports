### Title
`RewardDistributor.setTargetAPR` uses the wrong access modifier (`onlyKeeper` instead of `onlyOwner`), allowing any keeper to manipulate APR and drain reward tokens.

### Brief / Intro
The contract's NatSpec and the rest of the admin surface document that `setTargetAPR` must be restricted to the owner. The implementation, however, gates it with `onlyKeeper`. Combined with the fact that the same keeper can call `distribute`, this gives any keeper unilateral control over how many reward tokens are pushed into the vault per call.

### Vulnerability Details
[src/periphery/RewardDistributor.sol:529-534](src/periphery/RewardDistributor.sol#L529-L534):
```solidity
File: RewardDistributor.sol
529:     function setTargetAPR(uint256 _apr) external onlyKeeper {
530:         if (_apr == 0) revert ZeroTargetAPR();
531: 
532:         emit TargetAPRUpdated(targetAPR, _apr);
533:         targetAPR = _apr;
534:     }
```

But the contract-level NatSpec at [src/periphery/RewardDistributor.sol:79-82](src/periphery/RewardDistributor.sol#L79-L82) clearly states:

> `@custom:access Only whitelisted keepers can call distribute. Only the owner can call setTargetAPR, setDistributionInterval, updateKeeper, setMaxSupplyDeviation, and withdrawRewards.`

`targetAPR` is then consumed by [`distribute`](src/periphery/RewardDistributor.sol#L453-L504), where it directly drives the amount of reward tokens pulled out of the contract and pushed into the vault via `infrared.addIncentives(...)`:

```solidity
File: RewardDistributor.sol
453:     function distribute(uint256 _maxTotalSupply) external onlyKeeper {
...
479:         // Calculate the target reward rate to achieve the desired APR
480:         // APR = (rewardRate * SECONDS_PER_YEAR * 100) / totalSupply
481:         // rewardRate = (APR * totalSupply) / (SECONDS_PER_YEAR * 100)
482:         // Calculate the total rewards needed for the full duration
483:         uint256 totalRewardsNeeded = (targetAPR * totalSupply * rewardsDuration)
484:             / (SECONDS_PER_YEAR * BASIS_POINTS);
485: 
486:         // Subtract leftover rewards to find the additional amount needed
487:         uint256 additionalAmount = totalRewardsNeeded > (leftover + residual)
488:             ? totalRewardsNeeded - (leftover + residual)
489:             : 0;
490: 
491:         if (additionalAmount == 0) revert NothingToAdd();
492: 
...
503:         emit RewardsDistributed(address(vault), additionalAmount);
504:     }
```

A compromised or malicious keeper can:
1. Call `setTargetAPR(VERY_LARGE_VALUE)` (the only upper bound on `targetAPR` is `uint256` overflow inside the multiplication).
2. Stake LP into the target vault from a controlled address (or simply collude with an existing staker).
3. Wait for `distributionInterval` to elapse, then call `distribute(maxTotalSupply)` with `maxTotalSupply` chosen to satisfy the slippage check.
4. The contract pushes its **entire reward token balance** into the vault in one cycle. The keeper / colluding staker harvests their proportional share of those rewards.

### Impact / Severity
**Critical.** A single keeper (a role intended to perform routine maintenance, not control reward economics) can:
- Drain the full reward-token balance held by the `RewardDistributor` in one distribution cycle.
- Compound the drain by repeatedly raising the APR and forcing distributions on every interval.
- The drained tokens land in the vault and are claimable proportionally by stakers — a colluding/self-staking keeper monetises directly.

### Recommended Fix
Change the modifier to `onlyOwner` to match the documented access policy:

```solidity
function setTargetAPR(uint256 _apr) external onlyOwner {
    if (_apr == 0) revert ZeroTargetAPR();
    emit TargetAPRUpdated(targetAPR, _apr);
    targetAPR = _apr;
}
```

## References
https://github.com/infrared-dao/contracts/blob/d1eeed6eb536cec3f02968e0b4663363042d58f1/src/periphery/RewardDistributor.sol#L529