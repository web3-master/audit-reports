| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-contracts-of-the-codebase-will-not-strictly-compliant-with-the-erc-1504) | Contracts of the codebase will not strictly compliant with the ERC-1504. |


# [M-01] Contracts of the codebase will not strictly compliant with the ERC-1504.
## Summary
Contracts of the codebase isn't strictly compliant with the ERC-1504. This breaks the readme.

## Root Cause
As per readme:
> Is the codebase expected to comply with any EIPs? Can there be/are there any deviations from the specification?
> 
> Strictly compliant: ERC-1504: Upgradable Smart Contract

But the contracts of the codebase uses openzepplin upgradable contracts as base contract which are not compliant with ERC-1504. As per [ERC-1504](https://eips.ethereum.org/EIPS/eip-1504), the upgradable contract should consists of have handler contract, data contract and optionally the upgrader contract.
But the contracts of the codebase are not compliant with ERC-1504 because they has no data contract and has data inside the handler contract.

## Internal pre-conditions

## External pre-conditions

## Attack Path

## Impact
Break the readme.

## PoC

## Mitigation
Make the contracts strictly compliant with ERC-1504.
