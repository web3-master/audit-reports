| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-malicious-user-can-front-run-and-steal-token-claims-in-vvvvctokendistributorclaim-function) | Malicious User Can Front-Run and Steal Token Claims in `VVVVCTokenDistributor.claim()` Function. |



# [H-01] Malicious User Can Front-Run and Steal Token Claims in `VVVVCTokenDistributor.claim()` Function.
## Summary
The `VVVVCTokenDistributor.claim()` function can be called by anyone with a valid signature. This allows a malicious user to front-run a legitimate claim and steal tokens by submitting the same claim transaction earlier.

## Root Cause
- The [VVVVCTokenDistributor.claim()](https://github.com/sherlock-audit/2024-11-vvv-exchange-update/blob/main/vvv-platform-smart-contracts/contracts/vc/VVVVCTokenDistributor.sol#L106-L145) function allows anyone to submit a claim as long as they have a valid signature. There is no restriction that ties the claim to a specific caller, making it susceptible to front-running.

## Internal pre-conditions

## External pre-conditions

## Attack Path
- A user submits a transaction to call the `VVVVCTokenDistributor.claim()` function with a valid signature to claim tokens.
- A malicious user monitors the mempool for this transaction and submits a front-running transaction with the same signature, effectively stealing the claim before the legitimate user’s transaction is processed.

## Impact
A malicious user can steal another user’s token claim by front-running the transaction, resulting in the legitimate user losing access to their tokens.

## PoC

## Mitigation
To prevent front-running:
- Limit the msg.sender in the `claim()` function to the `_params.kycAddress`, ensuring that only the intended user can call the function.
- Alternatively, include `msg.sender` in the signed data so that the signature is valid only for the intended caller. This would prevent any other user from using the same signature.
