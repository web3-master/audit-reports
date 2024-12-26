| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-deleted-address-can-still-perform-actions-allowed-to-undeleted-addresses) | Deleted address can still perform actions allowed to undeleted addresses. |


# [M-01] Deleted address can still perform actions allowed to undeleted addresses.
## Summary
When an address is compromised, user delete it from the Ethos profile. However, the deleted address can still perform actions that undeleted addresses are authorized to do.

## Root Cause
When an address is compromised, user can delete it from the Ethos profile using the following [EthosProfile.deleteAddressAtIndex()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosProfile.sol#L415-L438) function which marks `isAddressCompromised` as `true`.

The [EthosProfile.verifiedProfileIdForAddress](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosProfile.sol#L568-L574) function is shown below.
```solidity
  function verifiedProfileIdForAddress(address _address) external view returns (uint256) {
    (bool verified, bool archived, bool mock, uint256 profileId) = profileStatusByAddress(_address);
    if (!verified || archived || mock) {
      revert ProfileNotFoundForAddress(_address);
    }
    return profileId;
  }
  ... SKIP ...
  function profileStatusByAddress(
    address addressStr
  ) public view returns (bool verified, bool archived, bool mock, uint256 profileId) {
    profileId = profileIdByAddress[addressStr];
    (verified, archived, mock) = profileStatusById(profileId);
  }
```
As can be seen, the function doesn't consider the `isAddressCompromised` flag. As a result, even though an address is deleted from a profile, the return value of the `verifiedProfileIdForAddress()` function for the deleted address remains unchanged.

The `EthosProfile.verifiedProfileIdForAddress()` function is called from many other places of the codebase to authorize the address to perform the following operations:
[EthosAttestation.createAttestation()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosAttestation.sol#L228)
[EthosDiscussion.addReply()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosDiscussion.sol#L113)
[EthosDiscussion.editReply()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosDiscussion.sol#L160)
[EthosReview.addReview()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosReview.sol#L199)
[EthosReview.editReview()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosReview.sol#L267)
[EthosReview.restoreReview()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosReview.sol#L314)
[EthosVote.voteFor()](https://github.com/sherlock-audit/2024-10-ethos-network/blob/main/ethos/packages/contracts/contracts/EthosVote.sol#L149)

## Internal pre-conditions

## External pre-conditions

## Attack Path
For example, in the case of the `EthosVote.voteFor()` function:
1. Address `addr1` is registered to `profile1`.
2. `addr1` get compromised and is deleted from `profile1` by the user.
3. Even though `addr1` is already deleted, it can still vote for anything by calling `EthosVote.voteFor()`.

## Impact
The vulnerability breaks core contract functionality because a deleted address can still perform actions that undeleted addresses can do.

## PoC
None

## Mitigation
Modify `EthosProfile.verifiedProfileIdForAddress()` function as follows.
```solidity
- function verifiedProfileIdForAddress(address _address) external view returns (uint256) {
+ function verifiedProfileIdForAddress(address _address) external view checkIfCompromised(_address) returns (uint256) {
    (bool verified, bool archived, bool mock, uint256 profileId) = profileStatusByAddress(_address);
    if (!verified || archived || mock) {
      revert ProfileNotFoundForAddress(_address);
    }
    return profileId;
  }
```
