| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-withdrawal-fee-for-usualx-vault-will-be-mis-calculated) | Withdrawal fee for UsualX vault will be mis-calculated. |

# [H-01] Withdrawal fee for UsualX vault will be mis-calculated.
## Summary
The `UsualX.withdraw()` function has logic error in calculating the withdrawal fee.

## Root Cause
The [UsualX.withdraw()](https://github.com/sherlock-audit/2024-10-usual-labs-v1/blob/main/pegasus/packages/solidity/src/vaults/UsualX.sol#L319-L343) function is following.
```solidity
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        UsualXStorageV0 storage $ = _usualXStorageV0();
        YieldDataStorage storage yieldStorage = _getYieldDataStorage();

        // Check withdrawal limit
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        // Calculate shares needed
335:    shares = previewWithdraw(assets);
336:    uint256 fee = Math.mulDiv(assets, $.withdrawFeeBps, BASIS_POINT_BASE, Math.Rounding.Ceil);

        // Perform withdrawal (exact assets to receiver)
        super._withdraw(_msgSender(), receiver, owner, assets, shares);

        // take the fee
342:    yieldStorage.totalDeposits -= fee;
    }
```
The [UsualX.previewWithdraw()](https://github.com/sherlock-audit/2024-10-usual-labs-v1/blob/main/pegasus/packages/solidity/src/vaults/UsualX.sol#L393-L404) function on `L335` is following.
```solidity
    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        UsualXStorageV0 storage $ = _usualXStorageV0();
        // Calculate the fee based on the equivalent assets of these shares
396:    uint256 fee = Math.mulDiv(
            assets, $.withdrawFeeBps, BASIS_POINT_BASE - $.withdrawFeeBps, Math.Rounding.Ceil
        );
        // Calculate total assets needed, including fee
        uint256 assetsWithFee = assets + fee;

        // Convert the total assets (including fee) to shares
        shares = _convertToShares(assetsWithFee, Math.Rounding.Ceil);
    }
```
As can be seen, The calculations of withdrawal fee is different in `L336` and `L396`.
Since `assets` refers to the asset amount without fee in the `withdraw()` and `previewWithdraw()` functions, the formula of `L336` is wrong and the `fee` of `L336` will be smaller than the `fee` of `L396` when `withdrawFeeBps > 0`. As a result, the `totalDeposits` in `L342` will becomes larger than it should be.

## Internal pre-conditions
`withdrawFeeBps` is larger than zero.

## External pre-conditions

## Attack Path
1. Assume that there are multiple users in the `UsualX` vault.
2. A user withdraws some assets from the vault.
3. `totalDeposits` becomes larger than it should be. Therefore, the assets of other users will be inflated.

## Impact
Loss of protocol's fee.
Broken core functionality because later withdrawers can make a profit.

## PoC
Add the following code to `UsualXUnit.t.sol`.
```solidity
    function test_withdrawFee() public {
        // update withdrawFee as 5%
        uint256 fee = 500;
        vm.prank(admin);
        registryAccess.grantRole(WITHDRAW_FEE_UPDATER_ROLE, address(this));
        usualX.updateWithdrawFee(fee);

        // initialize the vault with user1 and user2
        Init memory init;
        init.share[1] = 1e18; init.share[2] = 1e18;
        init.asset[1] = 1e18; init.asset[2] = 1e18;
        init = clamp(init);
        setUpVault(init);
        address user1 = init.user[1];
        address user2 = init.user[2];

        uint256 assetsOfUser2Before = _max_withdraw(user2);

        // user1 withdraw 0.5 ether from the vault
        vm.prank(user1);
        vault_withdraw(0.5e18, user1, user1);

        uint256 assetsOfUser2After = _max_withdraw(user2);

        // compare assets of user2 before withdrawal
        emit log_named_uint("before", assetsOfUser2Before);
        emit log_named_uint("after ", assetsOfUser2After);
    }
```
The output log of the above code is the following.
```bash
Ran 1 test for test/vaults/UsualXUnit.t.sol:UsualXUnitTest
[PASS] test_withdrawFee() (gas: 456410)
Logs:
  before: 1000000000000000100
  after : 1000892857142857243

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 13.10ms (3.33ms CPU time)

Ran 1 test suite in 20.07ms (13.10ms CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
```
As can be seen, after user1 withdraws, the assets of user2 becomes inflated.

## Mitigation
Modify `UsualX.withdraw()` function similar to the `UsualX.previewWithdraw()` function as follows.
```solidity
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        UsualXStorageV0 storage $ = _usualXStorageV0();
        YieldDataStorage storage yieldStorage = _getYieldDataStorage();

        // Check withdrawal limit
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        // Calculate shares needed
        shares = previewWithdraw(assets);
--      uint256 fee = Math.mulDiv(assets, $.withdrawFeeBps, BASIS_POINT_BASE, Math.Rounding.Ceil);
++      uint256 fee = Math.mulDiv(assets, $.withdrawFeeBps, BASIS_POINT_BASE - $.withdrawFeeBps, Math.Rounding.Ceil);

        // Perform withdrawal (exact assets to receiver)
        super._withdraw(_msgSender(), receiver, owner, assets, shares);

        // take the fee
        yieldStorage.totalDeposits -= fee;
    }
```