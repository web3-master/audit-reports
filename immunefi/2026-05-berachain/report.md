## Title 
`cancelQueuedWithdrawal` lets an approved spender steal an owner's shares without going through cooldown

## Brief / Intro
In both `WBERAStakerVault` and `LSTStakerVault`, when an approved spender (caller ≠ owner) calls `queueRedeem` / `queueWithdraw` on an owner's behalf, the withdrawal-request NFT is minted to the **caller**, not the owner. The caller can then immediately call `cancelQueuedWithdrawal`, which re-mints fresh vault shares to `msg.sender` (the caller). The original owner is permanently deprived of the burned shares; the spender effectively short-circuits the cooldown and converts an ERC20 allowance into a full transfer of value to themselves.

## Vulnerability Details
File: [src/pol/WBERAStakerVault.sol:391-414](src/pol/WBERAStakerVault.sol#L391-L414) and [src/pol/WBERAStakerVault.sol:237-260](src/pol/WBERAStakerVault.sol#L237-L260):

```solidity
function _queueWithdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
    internal returns (uint256)
{
    if (caller != owner) {
        _spendAllowance(owner, caller, shares);
    }
    _burn(owner, shares);                                         // shares burned from owner
    reservedAssets += assets;
    uint256 requestId = withdrawalRequests721.mint(caller, ...);  // NFT minted to caller!
    ...
}

function cancelQueuedWithdrawal(uint256 requestId) external nonReentrant whenNotPaused {
    if (msg.sender != IERC721(address(withdrawalRequests721)).ownerOf(requestId)) revert ...;
    ...
    uint256 newSharesToMint = previewDeposit(assets);
    reservedAssets -= assets;
    _mint(msg.sender, newSharesToMint);                           // new shares to caller, NOT owner
    ...
}
```

The same pattern exists in [src/pol/lst/LSTStakerVault.sol:163-185](src/pol/lst/LSTStakerVault.sol#L163-L185).

Standard ERC4626 semantics intend `withdraw/redeem` to consume the owner's allowance and deliver **assets** to the receiver — the spender never gets back fresh shares. By introducing a "cancel and re-mint" path that mints to `msg.sender`, the contract makes ERC4626 allowances behave like full ERC20 `transferFrom` capability, bypassing the asset-only escape valve the ERC4626 spec relies on.

Exploit flow (Alice → Bob with allowance):
1. Alice approves Bob for `X` sWBERA (e.g., to let Bob redeem on her behalf as a recovery contact).
2. Bob calls `queueRedeem(X, anyReceiver, Alice)`. `X` sWBERA are burned from Alice; an NFT for `X`-equivalent assets is minted to Bob.
3. Bob immediately calls `cancelQueuedWithdrawal(id)`. Vault burns the NFT and mints fresh sWBERA shares to Bob.
4. Bob now holds the shares; Alice has none. Cooldown was skipped.

## Impact / Severity
**Critical – theft of value from share holders.** ERC4626 share allowances were not designed to be substitutable for ERC20 transfers in this way; integrating contracts (lending protocols, vault routers, ops contracts) commonly grant such allowances based on the standard's redeem-only semantics. The cancel path lets any approved spender convert allowance into shares.

## Recommended Fix / Mitigation
- In `cancelQueuedWithdrawal`, mint the refund shares to `request.owner`, not to `msg.sender`.
- Or, mint the withdrawal-request NFT to `request.owner` instead of `caller`, and have only the owner cancel.

## References
https://github.com/berachain/contracts/blob/8d7a834ad1da6c2f400597a5fbf4be50494d492c/src/pol/WBERAStakerVault.sol#L258