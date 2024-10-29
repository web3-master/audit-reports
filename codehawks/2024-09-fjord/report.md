| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-all-of-bid-unbid-and-auctionend-functions-can-be-executed-at-the-same-auctionendtime) | All of `bid()`, `unbid()` and `auctionEnd()` functions can be executed at the same `auctionEndTime`. |


# [M-01] All of `bid()`, `unbid()` and `auctionEnd()` functions can be executed at the same `auctionEndTime`.
## Summary
All of `bid()`, `unbid()` and `auctionEnd()` functions can be executed at the same `auctionEndTime` within the same block.
In particular, if `bid()` or `unbid()` is executed after `auctionEnd()`, it causes serious problems to the protocol.

## Vulnerability Detail
`FjordAuction.bid()`, `FjordAuction.unbid()` and `FjordAuction.auctionEnd()` functions are following.
```solidity
    function bid(uint256 amount) external {
144:    if (block.timestamp > auctionEndTime) {
            revert AuctionAlreadyEnded();
        }
        --- SKIP ---
    }

    function unbid(uint256 amount) external {
160:    if (block.timestamp > auctionEndTime) {
            revert AuctionAlreadyEnded();
        }
        --- SKIP ---
    }
    
    function auctionEnd() external {
182:    if (block.timestamp < auctionEndTime) {
            revert AuctionNotYetEnded();
        }
        --- SKIP ---
    }
```
As can be seen, all of `bid()`, `unbid()` and `auctionEnd()` functions can be executed at `auctionEndTime`.
From this, the following scenarios are available. To simplify, we ignore precision factor in the following calculations.

Scenario 1 of `bid()`:
1. Assume that total auction token is `1000` and `user1` bids `100` points.
2. At `auctionEndTime`, `auctionEnd()` is executed and multiplier is determined as `1000 / 100 = 10`.
3. In the same block of `auctionEnd()`'s tx but after that, `user2`'s `bid()` tx is executed with `100` points.
4. If `user2` claims first, `100 * 10 = 1000` auction tokens are transferred to `user2`.
5. After that, `user1` can't claim auction tokens because there are no more auction tokens left.

Scenario 2 of `unbid()`:
1. Assume that total auction token is `1000` and `user1` bids `40` points and `user2` bids `60` points so the total bids are `40 + 60 = 100`.
2. At `auctionEndTime`, `auctionEnd()` is executed and multiplier is determined as `10`.
3. In the same block of `auctionEnd()`'s tx but after that, `user2`'s `unbid()` tx is executed with `60` points.
4. `user1` claims his `400` auction tokens.
5. `1000 - 400 = 600` auction tokens will be locked in `FjordAuction` contract.

Attacker can even use scenario 2 to lock almost auction tokens in the contract and damage other users with huge amount of points.

## Impact
Users can't claim tokens after auction finishes or some tokens may be locked in `FjordAuction` contract.
Attacker can lock almost auction tokens in the contract and damage other users.

## Code Snippet
- [FjordAuction.bid()](https://github.com/Cyfrin/2024-08-fjord/tree/main/src/FjordAuction.sol#L144)
- [FjordAuction.unbid()](https://github.com/Cyfrin/2024-08-fjord/tree/main/src/FjordAuction.sol#L160)
- [FjordAuction.auctionEnd()](https://github.com/Cyfrin/2024-08-fjord/tree/main/src/FjordAuction.sol#L182)

## Tool used
Manual Review

## Recommendation
Modify `FjordAuction.auctionEnd()` function as follows.
```solidity
    function auctionEnd() external {
--      if (block.timestamp < auctionEndTime) {
++      if (block.timestamp <= auctionEndTime) {
            revert AuctionNotYetEnded();
        }
        --- SKIP ---
    }
```
