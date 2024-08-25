| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-vultisig-whitelisting-can-be-bypassed-by-anyone) | Vultisig whitelisting can be bypassed by anyone |
| [M-01](#m-01-claim-function-lacks-slippage-controls-for-amount0-and-amount1-returned-by-poolburn-function-call) | claim function lacks slippage controls for amount0 and amount1 returned by pool.burn function call |

# [H-01] Vultisig whitelisting can be bypassed by anyone
## Impact
Whitelist launch will be bricked. Anyone can buy tokens, and also bypass the 3 ETH limit by buying via other non-whitelisted accounts. This will have an impact on price and ruin the opportunities of legit whitelisted users.

Here's a diagram on the timelines of the launch. "WL Launch" is the affected phase.

The checkWhitelist() function makes an erroneous check here:
```solidity
    if (_allowedWhitelistIndex == 0 || _whitelistIndex[to] > _allowedWhitelistIndex) {
        revert NotWhitelisted();
    }
```
https://github.com/code-423n4/2024-06-vultisig/blob/main/hardhat-vultisig/contracts/Whitelist.sol#L216

_allowedWhitelistIndex is the max index allowed, and works as a limit, not a whitelist flag. Once it is set (which must happen for all whitelists), any non-whitelisted user can bypass it.

This is because _whitelistIndex[to] will be 0, and _whitelistIndex[to] > _allowedWhitelistIndex will never revert (0 > 1000 for example).

## Proof of Concept
Add this test to /2024-06-vultisig/hardhat-vultisig/test/unit/Whitelist.ts
Run the test npx hardhat test
```javascript
it.only("Bypasses whitelisting", async function () {
    const { owner, whitelist, pool, otherAccount, mockOracleSuccess, mockContract } = await loadFixture(deployWhitelistFixture);

    await whitelist.setVultisig(mockContract);
    await whitelist.setLocked(false);
    await whitelist.setOracle(mockOracleSuccess);

    // `otherAccount` is not whitelisted and can't bypass the whitelist check
    await expect(whitelist.connect(mockContract).checkWhitelist(pool, otherAccount, 0)).to.be.revertedWithCustomError(
    whitelist,
    "NotWhitelisted",
    );

    // Until an `_allowedWhitelistIndex` limit is set
    // This value is intended as a limit, not as a flag not allow non-whitelisted users
    await whitelist.setAllowedWhitelistIndex(10);

    // `otherAccount` and any other user can now bypass the whitelisting
    await whitelist.connect(mockContract).checkWhitelist(pool, otherAccount, 0);
});
```

## Lines of code
https://github.com/code-423n4/2024-06-vultisig/blob/main/hardhat-vultisig/contracts/Whitelist.sol#L216

## Tool used
Manual Review

## Recommended Mitigation Steps
Prevent non-whitelisted users to bypass the whitelist:
```solidity
-   if (_allowedWhitelistIndex == 0 || _whitelistIndex[to] > _allowedWhitelistIndex) {
+   if (_whitelistIndex[to] == 0 || _whitelistIndex[to] > _allowedWhitelistIndex) {
        revert NotWhitelisted();
    }
```

# [M-01] claim function lacks slippage controls for amount0 and amount1 returned by pool.burn function call
## Impact
Because the claim function does not have slippage controls for amount0 and amount1 returned by the pool.burn function call, the claim function call can suffer from price manipulation on the associated Uniswap v3 pool. If a price manipulation frontruns the claim transaction, the claimed token amounts can be much less than what they should be.

## Proof of Concept
When calling the following claim function, there are no slippage controls for amount0 and amount1 returned by the pool.burn function call. This is unlike Uniswap's decreaseLiquidity function below that does execute require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Price slippage check'), where amount0 and amount1 are also returned by the pool.burn function call. Thus, if a price manipulation on the associated Uniswap v3 pool frontruns the claim transaction, amount0 and amount1 can be much less than what they should be when the claim transaction is executed, which would cause the investor to claim token amounts that are much less than what they should be.
```solidity
    function claim(uint256 tokenId)
        external
        payable
        override
        isAuthorizedForToken(tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        // only can claim if the launch is successfully
        require(_launchSucceeded, "PNL");

        // calculate amount of unlocked liquidity for the position
        uint128 liquidity2Claim = _claimableLiquidity(tokenId);
        IUniswapV3Pool pool = IUniswapV3Pool(_cachedUniV3PoolAddress);
        Position storage position = _positions[tokenId];
        {
            IILOManager.Project memory _project = IILOManager(MANAGER).project(address(pool));

            uint128 positionLiquidity = position.liquidity;
            require(positionLiquidity >= liquidity2Claim);

            // get amount of token0 and token1 that pool will return for us
            (amount0, amount1) = pool.burn(TICK_LOWER, TICK_UPPER, liquidity2Claim);

            // get amount of token0 and token1 after deduct platform fee
            (amount0, amount1) = _deductFees(amount0, amount1, _project.platformFee);

            bytes32 positionKey = PositionKey.compute(address(this), TICK_LOWER, TICK_UPPER);

            // calculate amount of fees that position generated
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);
            uint256 fees0 = FullMath.mulDiv(
                                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                                positionLiquidity,
                                FixedPoint128.Q128
                            );
            
            uint256 fees1 = FullMath.mulDiv(
                                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                                positionLiquidity,
                                FixedPoint128.Q128
                            );

            // amount of fees after deduct performance fee
            (fees0, fees1) = _deductFees(fees0, fees1, _project.performanceFee);

            // fees is combined with liquidity token amount to return to the user
            amount0 += fees0;
            amount1 += fees1;

            position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
            position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;

            // subtraction is safe because we checked positionLiquidity is gte liquidity2Claim
            position.liquidity = positionLiquidity - liquidity2Claim;
            ...
        }
        // real amount collected from uintswap pool
        (uint128 amountCollected0, uint128 amountCollected1) = pool.collect(
            address(this),
            TICK_LOWER,
            TICK_UPPER,
            type(uint128).max,
            type(uint128).max
        );
        ...
        // transfer token for user
        TransferHelper.safeTransfer(_cachedPoolKey.token0, ownerOf(tokenId), amount0);
        TransferHelper.safeTransfer(_cachedPoolKey.token1, ownerOf(tokenId), amount1);
        ...
        address feeTaker = IILOManager(MANAGER).FEE_TAKER();
        // transfer fee to fee taker
        TransferHelper.safeTransfer(_cachedPoolKey.token0, feeTaker, amountCollected0-amount0);
        TransferHelper.safeTransfer(_cachedPoolKey.token1, feeTaker, amountCollected1-amount1);
    }
```

## Lines of code
https://github.com/code-423n4/2024-06-vultisig/blob/58ebda57ccf6a74bdef2b88eb18a62ec4ad46112/src/ILOPool.sol#L184-L261
https://github.com/Uniswap/v3-periphery/blob/main/contracts/NonfungiblePositionManager.sol#L257-L306

## Tool used
Manual Review

## Recommended Mitigation Steps
The claim function can be updated to include slippage controls for amount0 and amount1 returned by the pool.burn function call like what Uniswap's decreaseLiquidity function does.