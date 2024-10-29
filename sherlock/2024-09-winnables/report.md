| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-attacker-can-set-prize-manager-address-of-ccip-message-as-whatever-he-wants) | Attacker can set prize manager address of CCIP message as whatever he wants. |
| [H-02](#h-02-ethers-of-refunded-amount-for-canceled-raffle-will-be-locked-for-the-next-raffles) | Ethers of refunded amount for canceled raffle will be locked for the next raffles. |
| [M-01](#m-01-admin-cant-revoke-role) | Admin can't revoke role. |


# [H-01] Attacker can set prize manager address of CCIP message as whatever he wants.
## Summary
Attacker can set prize manager address of CCIP message from `WinnablesTicketManager` as whatever he wants.
Exploiting this vulnerability, attacker can prevent admin or winner of raffle from withdrawing or claiming the locked prize.

## Vulnerability Detail
`WinnablesTicketManager.cancelRaffle()` function can be called by anyone because it doesn't have access modifier such as `nlyRole(0)` as follows.
```solidity
    function cancelRaffle(address prizeManager, uint64 chainSelector, uint256 raffleId) external {
        _checkShouldCancel(raffleId);

        _raffles[raffleId].status = RaffleStatus.CANCELED;
282:    _sendCCIPMessage(
            prizeManager,
            chainSelector,
            abi.encodePacked(uint8(CCIPMessageType.RAFFLE_CANCELED), raffleId)
        );
        IWinnablesTicket(TICKETS_CONTRACT).refreshMetadata(raffleId);
    }
```
Exploiting this vulnerability, attacker can call `cancelRaffle()` functions by passing an address which is not the address of `WinnablesPrizeManager` contract as `prizeManager` parameter.
Then, the CCIP message of `L282` is not transferred to the `WinnablesPrizeManager` contract.
Therefore, the locked funds for the `raffleId` in `WinnablesPrizeManager` contract can't be withdrawed by admin and are locked forever.

Example:
1. Admin locked `10 ethers` for `raffleId` in `WinnablesPrizeManager`. Then the CCIP message will be transferred to the `WinnablesTicketManager` of avalanche network.
2. Admin creates a raffle with `raffleId` in `WinnablesTicketManager`.
3. After time passed `endsAt`, the number of participants is less than `minTicketsThreshold`.
4. Attacker calls `cancelRaffle()` function before any other users by passing wrong address as `prizeManager` parameter.
5. Since the cancelling CCIP message is never transferred to the `WinnablesPrizeManager` contract, the locked funds of `10 ethers` are never unlocked and admin can never withdraw the locked funds for the very cancelled raffle.

The same problem also exists in the `WinnablesTicketManager.propagateRaffleWinner()` function.

## Impact
Attacker can set prize manager address of CCIP message as whatever he wants.
It prevents admin or winner of raffle from withdrawing or claiming the locked prize.

## Code Snippet
- [WinnablesTicketManager.cancelRaffle()](https://github.com/sherlock-audit/2024-08-winnables-raffles/blob/main/public-contracts/contracts/WinnablesTicketManager.sol#L278)
- [WinnablesTicketManager.propagateRaffleWinner()](https://github.com/sherlock-audit/2024-08-winnables-raffles/blob/main/public-contracts/contracts/WinnablesTicketManager.sol#L334)

## Tool used
Manual Review

## Recommendation
Modify `WinnablesTicketManager.cancelRaffle()` function as follows.
```solidity
--  function cancelRaffle(address prizeManager, uint64 chainSelector, uint256 raffleId) external {
++  function cancelRaffle(address prizeManager, uint64 chainSelector, uint256 raffleId) external onlyRole(0) {
        _checkShouldCancel(raffleId);

        _raffles[raffleId].status = RaffleStatus.CANCELED;
        _sendCCIPMessage(
            prizeManager,
            chainSelector,
            abi.encodePacked(uint8(CCIPMessageType.RAFFLE_CANCELED), raffleId)
        );
        IWinnablesTicket(TICKETS_CONTRACT).refreshMetadata(raffleId);
    }
```
Modify `WinnablesTicketManager.propagateRaffleWinner()` function the same way.

# [H-02] Ethers of refunded amount for canceled raffle will be locked for the next raffles.
## Summary
`WinnablesTicketManager` registers and updates locked ethers as `_lockedETH` state variable in order to refund ethers to participants for canceled raffle or withdraw ethers to admin for ticket sales.
However, `WinnablesTicketManager.refundPlayers()` doesn't reduce `_lockedETH` and it causes locked amount of ethers to be smaller than `_lockedETH` value by refunded amount of ethers.
Therefore, admin can't withdraw ethers of already refunded amount for the next raffles. 

## Vulnerability Detail
`WinnablesTicketManager` registers and updates locked ethers as `_lockedETH` state variable in order to refund ethers to participants for canceled raffle or withdraw ethers to admin for ticket sales. Therefore, `_lockedETH` value should be synced with really locked amount of ethers.
The `_lockedETH` is increased whenever participants buy tickets in `buyTickets()` and is decreased whenever raffles finishes successfully in `propagateRaffleWinner()`. However it is not updated in the following `WinnablesTicketManager.refundPlayers()` function.
```solidity
    function refundPlayers(uint256 raffleId, address[] calldata players) external {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status != RaffleStatus.CANCELED) revert InvalidRaffle();
        for (uint256 i = 0; i < players.length; ) {
            address player = players[i];
            uint256 participation = uint256(raffle.participations[player]);
            if (((participation >> 160) & 1) == 1) revert PlayerAlreadyRefunded(player);
            raffle.participations[player] = bytes32(participation | (1 << 160));
            uint256 amountToSend = (participation & type(uint128).max);
            _sendETH(amountToSend, player);
            emit PlayerRefund(raffleId, player, bytes32(participation));
            unchecked { ++i; }
        }
    }
```
As can be seen, the above function doesn't reduce `_lockedETH` state variable while it refunds ethers to pariticpants and reduces really locked ethers amount.

Example:
1. Admin creates raffle with `raffleId = 1`.
2. A particpant buys ticket with `2 ethers`. Now `_lockedETH = 2 ethers`.
3. Admin cancels `raffleId = 1` and refunds ethers to the participant. Now token manager's ETH balance is zero but `_lockedETH` is still `2 ethers` becasue `refundPlayers()` doesn't reduce it.
4. Admin creates another raffle with `raffleId = 2`.
5. A participant buys ticket with `3 ethers`. Now `_lockedETH = 5 ethers` and ETH balance is `3 ethers`.
6. Raffle finishes successfuly and `_lockedETH` will be `2 ethers` in `propagateRaffleWinner()`.
7. Admin can withdraw only `1 ether` because ETH balance is `3 ethers` and `_lockedETH` is `2 ethers`. 
8. As a result, `2 ethers` ETH will be locked to token manager contract.


## Impact
Ethers of refunded amount for canceled raffle will be locked for the next raffles.

## Code Snippet
- [WinnablesTicketManager.refundPlayers()](https://github.com/sherlock-audit/2024-08-winnables-raffles/blob/main/public-contracts/contracts/WinnablesTicketManager.sol#L215-L228)

## Tool used
Manual Review

## Recommendation
Modify `WinnablesTicketManager.refundPlayers()` function as follows.
```solidity
    function refundPlayers(uint256 raffleId, address[] calldata players) external {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status != RaffleStatus.CANCELED) revert InvalidRaffle();
        for (uint256 i = 0; i < players.length; ) {
            address player = players[i];
            uint256 participation = uint256(raffle.participations[player]);
            if (((participation >> 160) & 1) == 1) revert PlayerAlreadyRefunded(player);
            raffle.participations[player] = bytes32(participation | (1 << 160));
            uint256 amountToSend = (participation & type(uint128).max);
++          _lockedETH -= amountToSend;
            _sendETH(amountToSend, player);
            emit PlayerRefund(raffleId, player, bytes32(participation));
            unchecked { ++i; }
        }
    }
```

# [M-01] Admin can't revoke role.
## Summary
`Roles._setRole()` function can set role for user but can't revoke role form user.

## Vulnerability Detail
`Roles._setRole()` function is following.
```solidity
    function _setRole(address user, uint8 role, bool status) internal virtual {
        uint256 roles = uint256(_addressRoles[user]);
        _addressRoles[user] = bytes32(roles | (1 << role));
        emit RoleUpdated(user, role, status);
    }
```
As can be seen, the above function doesn't use `status` parameter at all.
That is, even though `status = false`, it sets role for user instead of revoking role from user.

## Impact
Admin can't revoke role from users.
If user addresses are compromised, admin has to revoke role from users.
However, current implementation can't revoke role from users, 

## Code Snippet
- [Roles._setRole()](https://github.com/sherlock-audit/2024-08-winnables-raffles/blob/main/public-contracts/contracts/Roles.sol#L29-L33)

## Tool used
Manual Review

## Recommendation
Modify `Roles._setRole()` function as follows.
```solidity
    function _setRole(address user, uint8 role, bool status) internal virtual {
        uint256 roles = uint256(_addressRoles[user]);
--      _addressRoles[user] = bytes32(roles | (1 << role));
++      if (status) _addressRoles[user] = bytes32(roles | (1 << role)) else _addressRoles[user] = bytes32(roles & ~(1 << role));
        emit RoleUpdated(user, role, status);
    }
```