| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-olympuspricev2solstoreprice-the-moving-average-prices-are-used-recursively-for-the-calculation-of-the-moving-average-price) | OlympusPrice.v2.sol#storePrice: The moving average prices are used recursively for the calculation of the moving average price. |
| [M-01](#m-01-incorrect-calculation-of-the-bunnitokenprice) | Incorrect calculation of the BunniTokenPrice. |
| [M-02](#m-02-wrong-calculation-of-protocolownedliquidityohm-in-bunnysupply) | Wrong calculation of ProtocolOwnedLiquidityOhm in BunnySupply. |
| [M-03](#m-03-price-can-be-miscalculated) | Price can be miscalculated. |
| [M-04](#m-04-olympussupplygetreservesbycategory-function-always-revert-for-some-categories) | OlympusSupply.getReservesByCategory function always revert for some categories. |
| [M-05](#m-05-the-check-for-deviation-in-deviationsol-is-not-valid) | The check for deviation in Deviation.sol is not valid. |


# [H-01] OlympusPrice.v2.sol#storePrice: The moving average prices are used recursively for the calculation of the moving average price.

## Summary
The moving average prices should be calculated by only oracle feed prices.
But now, they are calculated by not only oracle feed prices but also moving average price recursively.

That is, the storePrice function uses the current price obtained from the _getCurrentPrice function to update the moving average price.
However, in the case of asset.useMovingAverage = true, the _getCurrentPrice function computes the current price using the moving average price.

Thus, the moving average prices are used recursively to calculate moving average price, so the current prices will be obtained incorrectly.

## Vulnerability Detail
OlympusPrice.v2.sol#storePrice function is the following.
```solidity
    function storePrice(address asset_) public override permissioned {
        Asset storage asset = _assetData[asset_];

        // Check if asset is approved
        if (!asset.approved) revert PRICE_AssetNotApproved(asset_);

        // Get the current price for the asset
319:    (uint256 price, uint48 currentTime) = _getCurrentPrice(asset_);

        // Store the data in the obs index
        uint256 oldestPrice = asset.obs[asset.nextObsIndex];
        asset.obs[asset.nextObsIndex] = price;

        // Update the last observation time and increment the next index
        asset.lastObservationTime = currentTime;
        asset.nextObsIndex = (asset.nextObsIndex + 1) % asset.numObservations;

        // Update the cumulative observation, if storing the moving average
        if (asset.storeMovingAverage)
331:        asset.cumulativeObs = asset.cumulativeObs + price - oldestPrice;

        // Emit event
        emit PriceStored(asset_, price, currentTime);
    }
```
L319 obtain the current price for the asset by calling the _getCurrentPrice function and use it to update asset.cumulativeObs in L331.
The _getCurrentPrice function is the following.
```solidity
    function _getCurrentPrice(address asset_) internal view returns (uint256, uint48) {
        Asset storage asset = _assetData[asset_];

        // Iterate through feeds to get prices to aggregate with strategy
        Component[] memory feeds = abi.decode(asset.feeds, (Component[]));
        uint256 numFeeds = feeds.length;
138:    uint256[] memory prices = asset.useMovingAverage
            ? new uint256[](numFeeds + 1)
            : new uint256[](numFeeds);
        uint8 _decimals = decimals; // cache in memory to save gas
        for (uint256 i; i < numFeeds; ) {
            (bool success_, bytes memory data_) = address(_getSubmoduleIfInstalled(feeds[i].target))
                .staticcall(
                    abi.encodeWithSelector(feeds[i].selector, asset_, _decimals, feeds[i].params)
                );

            // Store price if successful, otherwise leave as zero
            // Idea is that if you have several price calls and just
            // one fails, it'll DOS the contract with this revert.
            // We handle faulty feeds in the strategy contract.
            if (success_) prices[i] = abi.decode(data_, (uint256));

            unchecked {
                ++i;
            }
        }

        // If moving average is used in strategy, add to end of prices array
160:    if (asset.useMovingAverage) prices[numFeeds] = asset.cumulativeObs / asset.numObservations;

        // If there is only one price, ensure it is not zero and return
        // Otherwise, send to strategy to aggregate
        if (prices.length == 1) {
            if (prices[0] == 0) revert PRICE_PriceZero(asset_);
            return (prices[0], uint48(block.timestamp));
        } else {
            // Get price from strategy
            Component memory strategy = abi.decode(asset.strategy, (Component));
            (bool success, bytes memory data) = address(_getSubmoduleIfInstalled(strategy.target))
                .staticcall(abi.encodeWithSelector(strategy.selector, prices, strategy.params));

            // Ensure call was successful
            if (!success) revert PRICE_StrategyFailed(asset_, data);

            // Decode asset price
            uint256 price = abi.decode(data, (uint256));

            // Ensure value is not zero
            if (price == 0) revert PRICE_PriceZero(asset_);

            return (price, uint48(block.timestamp));
        }
    }
```
As can be seen, when asset.useMovingAverage = true, the _getCurrentPrice calculates the current price price using the moving average price obtained by asset.cumulativeObs / asset.numObservations in L160.

So the price value in L331 is obtained from not only oracle feed prices but also moving average price.
Then, storePrice calculates the cumulative observations asset.cumulativeObs = asset.cumulativeObs + price - oldestPrice using the price which is obtained incorrectly above.

Thus, the moving average prices are used recursively for the calculation of the moving average price.

## Impact
Now the moving average prices are used recursively for the calculation of the moving average price.
Then, the moving average prices become more smoothed than the intention of the administrator.
That is, even when the actual price fluctuations are large, the price fluctuations of _getCurrentPrice function will become too small.

Moreover, even though all of the oracle price feeds fails, the moving averge prices will be calculated only by moving average prices.

Thus the current prices will become incorrect.
If _getCurrentPrice function value is miscalculated, it will cause fatal damage to the protocol.

## Code Snippet
https://github.com/sherlock-audit/2023-11-olympus-web3-master/blob/main/bophades/src/modules/PRICE/OlympusPrice.v2.sol#L312-L335
https://github.com/sherlock-audit/2023-11-olympus-web3-master/blob/main/bophades/src/modules/PRICE/OlympusPrice.v2.sol#L132-L184

## Tool used
Manual Review

## Recommendation
When updating the current price and cumulative observations in the storePrice function, it should use the oracle price feeds and not include the moving average prices.
So, instead of using the asset.useMovingAverage state variable in the _getCurrentPrice function, we can add a useMovingAverage parameter as the following.
```solidity
>>  function _getCurrentPrice(address asset_, bool useMovingAverage) internal view returns (uint256, uint48) {
        Asset storage asset = _assetData[asset_];

        // Iterate through feeds to get prices to aggregate with strategy
        Component[] memory feeds = abi.decode(asset.feeds, (Component[]));
        uint256 numFeeds = feeds.length;
>>      uint256[] memory prices = useMovingAverage
            ? new uint256[](numFeeds + 1)
            : new uint256[](numFeeds);
        uint8 _decimals = decimals; // cache in memory to save gas
        for (uint256 i; i < numFeeds; ) {
            (bool success_, bytes memory data_) = address(_getSubmoduleIfInstalled(feeds[i].target))
                .staticcall(
                    abi.encodeWithSelector(feeds[i].selector, asset_, _decimals, feeds[i].params)
                );

            // Store price if successful, otherwise leave as zero
            // Idea is that if you have several price calls and just
            // one fails, it'll DOS the contract with this revert.
            // We handle faulty feeds in the strategy contract.
            if (success_) prices[i] = abi.decode(data_, (uint256));

            unchecked {
                ++i;
            }
        }

        // If moving average is used in strategy, add to end of prices array
>>      if (useMovingAverage) prices[numFeeds] = asset.cumulativeObs / asset.numObservations;

        // If there is only one price, ensure it is not zero and return
        // Otherwise, send to strategy to aggregate
        if (prices.length == 1) {
            if (prices[0] == 0) revert PRICE_PriceZero(asset_);
            return (prices[0], uint48(block.timestamp));
        } else {
            // Get price from strategy
            Component memory strategy = abi.decode(asset.strategy, (Component));
            (bool success, bytes memory data) = address(_getSubmoduleIfInstalled(strategy.target))
                .staticcall(abi.encodeWithSelector(strategy.selector, prices, strategy.params));

            // Ensure call was successful
            if (!success) revert PRICE_StrategyFailed(asset_, data);

            // Decode asset price
            uint256 price = abi.decode(data, (uint256));

            // Ensure value is not zero
            if (price == 0) revert PRICE_PriceZero(asset_);

            return (price, uint48(block.timestamp));
        }
    }
```
Then we should set useMovingAverage = false to call _getCurrentPrice function only in the storePrice function.
In other cases, we should set useMovingAverage = asset.useMovingAverage to call _getCurrentPrice function.

# [M-01] Incorrect calculation of the BunniTokenPrice.
## Summary
When calculating the BunniTokenPrice, the uncollected fee is not considered.

## Vulnerability Detail
The BunniPrice.sol#getBunniTokenPrice() function determines the price of bunniToken_ (representing a Uniswap V3 pool) in USD.
```solidity
    function getBunniTokenPrice(
        address bunniToken_,
        uint8 outputDecimals_,
        bytes calldata params_
    ) external view returns (uint256) {
        ...

        // Validate reserves
155     _validateReserves(
            _getBunniKey(token),
            lens,
            params.twapMaxDeviationsBps,
            params.twapObservationWindow
        );

        // Fetch the reserves
163     uint256 totalValue = _getTotalValue(token, lens, outputDecimals_);

        return totalValue;
    }
```
The _getTotalValue() function called in L163 is as follow.
```solidity
    function _getTotalValue(
        BunniToken token_,
        BunniLens lens_,
        uint8 outputDecimals_
    ) internal view returns (uint256) {
220     (address token0, uint256 reserve0, address token1, uint256 reserve1) = _getBunniReserves(
            token_,
            lens_,
            outputDecimals_
        );
        uint256 outputScale = 10 ** outputDecimals_;

        // Determine the value of each reserve token in USD
        uint256 totalValue;
229     totalValue += _PRICE().getPrice(token0).mulDiv(reserve0, outputScale);
230     totalValue += _PRICE().getPrice(token1).mulDiv(reserve1, outputScale);

        return totalValue;
    }
```
The _getTotalValue() function determines the total value of the Uniswap V3 Position indicated by token_ in USD.

The _getBunnyReserves() function called in L220 is as follow.
```solidity
    function _getBunniReserves(
        BunniToken token_,
        BunniLens lens_,
        uint8 outputDecimals_
    ) internal view returns (address token0, uint256 reserve0, address token1, uint256 reserve1) {
        BunniKey memory key = _getBunniKey(token_);
198     (uint112 reserve0_, uint112 reserve1_) = lens_.getReserves(key);

        // Get the token addresses
        token0 = key.pool.token0();
        token1 = key.pool.token1();
        uint8 token0Decimals = ERC20(token0).decimals();
        uint8 token1Decimals = ERC20(token1).decimals();
        reserve0 = uint256(reserve0_).mulDiv(10 ** outputDecimals_, 10 ** token0Decimals);
        reserve1 = uint256(reserve1_).mulDiv(10 ** outputDecimals_, 10 ** token1Decimals);
    }
```
On L198 the amount of reserved token0 and token1 are calculated, but uncolleted fee is not considered.

On the other hand, in the BunniHelper.sol#getReservesRatio() function, the reserve ratio is calculated with considering the uncollected fee.
As compared with this, the BunniTokenPrice should be calculated with considering collected fee.
The BunniHelper.sol#getReservesRatio() function is as follow.
```solidity
    /// @notice         Returns the ratio of token1 to token0 based on the position reserves
    /// @dev            Includes uncollected fees
    function getReservesRatio(BunniKey memory key_, BunniLens lens_) public view returns (uint256) {
        IUniswapV3Pool pool = key_.pool;
        uint8 token0Decimals = ERC20(pool.token0()).decimals();

        (uint112 reserve0, uint112 reserve1) = lens_.getReserves(key_);
        (uint256 fee0, uint256 fee1) = lens_.getUncollectedFees(key_);

        return (reserve1 + fee1).mulDiv(10 ** token0Decimals, reserve0 + fee0);
    }
```
## Impact
Unconsidering Fee in calculation of BunniTokenPrice can cause incorrect Price.

## Code Snippet
https://github.com/sherlock-audit/2023-11-olympus-web3-master/blob/main/bophades/src/modules/PRICE/submodules/feeds/BunniPrice.sol#L205-L206

## Tool used
Manual Review

## Recommendation
The BunniPrice.sol#_getBunniReserves() function should be rewritten as follow.
```solidity
    function _getBunniReserves(
        BunniToken token_,
        BunniLens lens_,
        uint8 outputDecimals_
    ) internal view returns (address token0, uint256 reserve0, address token1, uint256 reserve1) {
        BunniKey memory key = _getBunniKey(token_);
        (uint112 reserve0_, uint112 reserve1_) = lens_.getReserves(key);
+       (uint256 fee0, uint256 fee1) = lens_.getUncollectedFees(key);

        // Get the token addresses
        token0 = key.pool.token0();
        token1 = key.pool.token1();
        uint8 token0Decimals = ERC20(token0).decimals();
        uint8 token1Decimals = ERC20(token1).decimals();
-       reserve0 = uint256(reserve0_).mulDiv(10 ** outputDecimals_, 10 ** token0Decimals);
-       reserve1 = uint256(reserve1_).mulDiv(10 ** outputDecimals_, 10 ** token1Decimals);
+       reserve0 = uint256(reserve0_ + fee0).mulDiv(10 ** outputDecimals_, 10 ** token0Decimals);
+       reserve1 = uint256(reserve1_ + fee1).mulDiv(10 ** outputDecimals_, 10 ** token1Decimals);
    }
```

# [M-02] Wrong calculation of ProtocolOwnedLiquidityOhm in BunnySupply.
## Summary
In BunnySupply.sol#getProtocolOwnedLiquidityOhm function, the amount of ohm is calculated without considering uncollected fee, so it is wrong.

## Vulnerability Detail
BunnySupply.sol#getProtocolOwnedLiquidityOhm is as follows.
```solidity
File: BunniSupply.sol
171:     function getProtocolOwnedLiquidityOhm() external view override returns (uint256) {
172:         // Iterate through tokens and total up the pool OHM reserves as the POL supply
173:         uint256 len = bunniTokens.length;
174:         uint256 total;
175:         for (uint256 i; i < len; ) {
176:             TokenData storage tokenData = bunniTokens[i];
177:             BunniLens lens = tokenData.lens;
178:             BunniKey memory key = _getBunniKey(tokenData.token);
179: 
180:             // Validate reserves
181:             _validateReserves(
182:                 key,
183:                 lens,
184:                 tokenData.twapMaxDeviationBps,
185:                 tokenData.twapObservationWindow
186:             );
187: 
188:             total += _getOhmReserves(key, lens);
189:             unchecked {
190:                 ++i;
191:             }
192:         }
193: 
194:         return total;
195:     }
```
On L188, the _getOhmReserves function which calculates the amount of ohm is as follows.
```solidity
File: BunniSupply.sol
399:     function _getOhmReserves(
400:         BunniKey memory key_,
401:         BunniLens lens_
402:     ) internal view returns (uint256) {
403:         (uint112 reserve0, uint112 reserve1) = lens_.getReserves(key_);
404:         if (key_.pool.token0() == ohm) {
405:             return reserve0;
406:         } else {
407:             return reserve1;
408:         }
409:     }
```
As we can see above, this function didn't consider uncollected fee.
On the other hand, the uncollected fee is considered in getProtocolOwnedLiquidityReserves function.
```solidity
File: BunniSupply.sol
212:     function getProtocolOwnedLiquidityReserves()
213:         external
214:         view
215:         override
216:         returns (SPPLYv1.Reserves[] memory)
217:     {
218:         // Iterate through tokens and total up the reserves of each pool
219:         uint256 len = bunniTokens.length;
220:         SPPLYv1.Reserves[] memory reserves = new SPPLYv1.Reserves[](len);
221:         for (uint256 i; i < len; ) {
222:             TokenData storage tokenData = bunniTokens[i];
223:             BunniToken token = tokenData.token;
224:             BunniLens lens = tokenData.lens;
225:             BunniKey memory key = _getBunniKey(token);
226:             (
227:                 address token0,
228:                 address token1,
229:                 uint256 reserve0,
230:                 uint256 reserve1
231:             ) = _getReservesWithFees(key, lens);
...
254:             unchecked {
255:                 ++i;
256:             }
257:         }
258: 
259:         return reserves;
260:     }
```
As we can see, the uncollected fee is considered in L231.
Therefore, we can see that the uncollected fee has to be considered in BunnySupply.sol#getProtocolOwnedLiquidityOhm function as well.

## Impact
The ProtocolOwnedLiquidityOhm is calculated wrongly because it didn't consider uncollected fee.

## Code Snippet
https://github.com/sherlock-audit/2023-11-olympus/blob/main/bophades/src/modules/SPPLY/submodules/BunniSupply.sol#L405
https://github.com/sherlock-audit/2023-11-olympus/blob/main/bophades/src/modules/SPPLY/submodules/BunniSupply.sol#L407

## Tool used
Manual Review

## Recommendation
BunnySupply.sol#_getOhmReserves function has to be rewritten as follows.
```solidity
    function _getOhmReserves(
        BunniKey memory key_,
        BunniLens lens_
    ) internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1) = lens_.getReserves(key_);
+       (uint256 fee0, uint256 fee1) = lens_.getUncollectedFees(key_);
        if (key_.pool.token0() == ohm) {
-           return reserve0;
+           return reserve0 + fee0;
        } else {
-           return reserve1;
+           return reserve1 + fee1;
        }
    }
```

# [M-03] Price can be miscalculated.
## Summary
In SimplePriceFeedStrategy.sol#getMedianPrice function, when the length of nonZeroPrices is 2 and they are deviated it returns first non-zero value, not median value.

## Vulnerability Detail
SimplePriceFeedStrategy.sol#getMedianPriceIfDeviation is as follows.
```solidity
    function getMedianPriceIfDeviation(
        uint256[] memory prices_,
        bytes memory params_
    ) public pure returns (uint256) {
        // Misconfiguration
        if (prices_.length < 3) revert SimpleStrategy_PriceCountInvalid(prices_.length, 3);

237     uint256[] memory nonZeroPrices = _getNonZeroArray(prices_);

        // Return 0 if all prices are 0
        if (nonZeroPrices.length == 0) return 0;

        // Cache first non-zero price since the array is sorted in place
        uint256 firstNonZeroPrice = nonZeroPrices[0];

        // If there are not enough non-zero prices to calculate a median, return the first non-zero price
246     if (nonZeroPrices.length < 3) return firstNonZeroPrice;

        uint256[] memory sortedPrices = nonZeroPrices.sort();

        // Get the average and median and abort if there's a problem
        // The following two values are guaranteed to not be 0 since sortedPrices only contains non-zero values and has a length of 3+
        uint256 averagePrice = _getAveragePrice(sortedPrices);
253     uint256 medianPrice = _getMedianPrice(sortedPrices);

        if (params_.length != DEVIATION_PARAMS_LENGTH) revert SimpleStrategy_ParamsInvalid(params_);
        uint256 deviationBps = abi.decode(params_, (uint256));
        if (deviationBps <= DEVIATION_MIN || deviationBps >= DEVIATION_MAX)
            revert SimpleStrategy_ParamsInvalid(params_);

        // Check the deviation of the minimum from the average
        uint256 minPrice = sortedPrices[0];
262     if (((averagePrice - minPrice) * 10000) / averagePrice > deviationBps) return medianPrice;

        // Check the deviation of the maximum from the average
        uint256 maxPrice = sortedPrices[sortedPrices.length - 1];
266     if (((maxPrice - averagePrice) * 10000) / averagePrice > deviationBps) return medianPrice;

        // Otherwise, return the first non-zero value
        return firstNonZeroPrice;
    }
```
As you can see above, on L237 it gets the list of non-zero prices. If the length of this list is smaller than 3, it assumes that a median price cannot be calculated and returns first non-zero price.
This is wrong.
If the number of non-zero prices is 2 and they are deviated, it has to return median value.
The _getMedianPrice function called on L253 is as follows.
```solidity
    function _getMedianPrice(uint256[] memory prices_) internal pure returns (uint256) {
        uint256 pricesLen = prices_.length;

        // If there are an even number of prices, return the average of the two middle prices
        if (pricesLen % 2 == 0) {
            uint256 middlePrice1 = prices_[pricesLen / 2 - 1];
            uint256 middlePrice2 = prices_[pricesLen / 2];
            return (middlePrice1 + middlePrice2) / 2;
        }

        // Otherwise return the median price
        // Don't need to subtract 1 from pricesLen to get midpoint index
        // since integer division will round down
        return prices_[pricesLen / 2];
    }
```
As you can see, the median value can be calculated from two values.
This problem exists at getMedianPrice function as well.
```solidity
    function getMedianPrice(uint256[] memory prices_, bytes memory) public pure returns (uint256) {
        // Misconfiguration
        if (prices_.length < 3) revert SimpleStrategy_PriceCountInvalid(prices_.length, 3);

        uint256[] memory nonZeroPrices = _getNonZeroArray(prices_);

        uint256 nonZeroPricesLen = nonZeroPrices.length;
        // Can only calculate a median if there are 3+ non-zero prices
        if (nonZeroPricesLen == 0) return 0;
        if (nonZeroPricesLen < 3) return nonZeroPrices[0];

        // Sort the prices
        uint256[] memory sortedPrices = nonZeroPrices.sort();

        return _getMedianPrice(sortedPrices);
    }
```
## Impact
When the length of nonZeroPrices is 2 and they are deviated, it returns first non-zero value, not median value. It causes wrong calculation error.

## Code Snippet
https://github.com/sherlock-audit/2023-11-olympus-web3-master/blob/main/bophades/src/modules/PRICE/submodules/strategies/SimplePriceFeedStrategy.sol#L246

## Tool used
Manual Review

## Recommendation
First, SimplePriceFeedStrategy.sol#getMedianPriceIfDeviation function has to be rewritten as follows.
```solidity
    function getMedianPriceIfDeviation(
        uint256[] memory prices_,
        bytes memory params_
    ) public pure returns (uint256) {
        // Misconfiguration
        if (prices_.length < 3) revert SimpleStrategy_PriceCountInvalid(prices_.length, 3);

        uint256[] memory nonZeroPrices = _getNonZeroArray(prices_);

        // Return 0 if all prices are 0
        if (nonZeroPrices.length == 0) return 0;

        // Cache first non-zero price since the array is sorted in place
        uint256 firstNonZeroPrice = nonZeroPrices[0];

        // If there are not enough non-zero prices to calculate a median, return the first non-zero price
-       if (nonZeroPrices.length < 3) return firstNonZeroPrice;
+       if (nonZeroPrices.length < 2) return firstNonZeroPrice;

        ...
    }
```
Second, SimplePriceFeedStrategy.sol#getMedianPrice has to be modified as following.
```solidity
    function getMedianPrice(uint256[] memory prices_, bytes memory) public pure returns (uint256) {
        // Misconfiguration
        if (prices_.length < 3) revert SimpleStrategy_PriceCountInvalid(prices_.length, 3);

        uint256[] memory nonZeroPrices = _getNonZeroArray(prices_);

        uint256 nonZeroPricesLen = nonZeroPrices.length;
        // Can only calculate a median if there are 3+ non-zero prices
        if (nonZeroPricesLen == 0) return 0;
-       if (nonZeroPricesLen < 3) return nonZeroPrices[0];
+       if (nonZeroPricesLen < 2) return nonZeroPrices[0];

        // Sort the prices
        uint256[] memory sortedPrices = nonZeroPrices.sort();

        return _getMedianPrice(sortedPrices);
    }
```

# [M-04] OlympusSupply.getReservesByCategory function always revert for some categories.
## Summary
In the case of submoduleReservesSelector = bytes4(0x0) and submodules.length > 0, the result of line OlympusSupply.sol#L541 always be false, so the OlympusSupply.getReservesByCategory function will revert.

## Vulnerability Detail
OlympusSupply.getReservesByCategory function is the following.
```solidity
    function getReservesByCategory(
        Category category_
    ) external view override returns (Reserves[] memory) {
        ...
496:    uint256 len = locations.length;
        ...
509:    CategoryData memory data = categoryData[category_];
        ...
512:    len = (data.useSubmodules) ? submodules.length : 0;
        ...
538:    uint256 j;
        for (uint256 i; i < len; ) {
            address submodule = address(_getSubmoduleIfInstalled(submodules[i]));
541:        (bool success, bytes memory returnData) = submodule.staticcall(
                abi.encodeWithSelector(data.submoduleReservesSelector)
            );

            // Ensure call was successful
            if (!success)
547:            revert SPPLY_SubmoduleFailed(address(submodule), data.submoduleReservesSelector);
            ...
562:    }
        ...
583:}
```
In OlympusSupply._addCategory function, when useSubmodules = true of CategoryData struct, submoduleMetricSelector field must be nonzero but submoduleReservesSelector field may be zero.
As a matter of fact, in OlympusSupply.constructor function, useSubmodules = true holds but submoduleReservesSelector = 0x00000000 for protocol-owned-treasury and protocol-owned-borrowable categories.

So, in the case of submoduleReservesSelector = bytes4(0x0) and submodules.length > 0, the result of line OlympusSupply.sol#L541 always be false, since all submodules of SPPLY module do not have the fallback function.

Therefore the OlympusSupply.getReservesByCategory function will revert at L547.

## Impact
For some categories the getReservesByCategory function will always revert.
Such examples are protocol-owned-treasury and protocol-owned-borrowable categories.
This means Denial-of-Service.

## Code Snippet
https://github.com/sherlock-audit/2023-11-olympus-web3-master/blob/main/bophades/src/modules/SPPLY/OlympusSupply.sol#L55-L58
https://github.com/sherlock-audit/2023-11-olympus-web3-master/blob/main/bophades/src/modules/SPPLY/OlympusSupply.sol#L541-L547

## Tool used
Manual Review

## Recommendation
OlympusSupply.getReservesByCategory can be modified such that L512 sets len = 0 to avoid calling submodules in the case of submoduleReservesSelector = bytes4(0x0).
```solidity
    function getReservesByCategory(
        Category category_
    ) external view override returns (Reserves[] memory) {
        ...
496:    uint256 len = locations.length;
        ...
509:    CategoryData memory data = categoryData[category_];
        ...
512:    len = (data.useSubmodules && data.submoduleReservesSelector != bytes4(0x0)) ? submodules.length : 0;
        ...
583:}
```

# [M-05] The check for deviation in Deviation.sol is not valid.
## Summary
We say that we check deviation between v0 and v1. We assume that v0 is fixed. Then the range of v1 which is not deviated is [v0 - a, v0 + b], and b > a, this is biased to large value.

## Vulnerability Detail
The Deviation.sol#isDeviatingWithBpsCheck -> isDeviating() function which checks for deviation is as follow.
```solidity
    function isDeviating(
        uint256 value0_,
        uint256 value1_,
        uint256 deviationBps_,
        uint256 deviationMax_
    ) internal pure returns (bool) {
        return
            (value0_ < value1_)
                ? _isDeviating(value1_, value0_, deviationBps_, deviationMax_)
                : _isDeviating(value0_, value1_, deviationBps_, deviationMax_);
    }
```
The _isDeviating() function is as follow.
```solidity
    function _isDeviating(
        uint256 value0_,
        uint256 value1_,
        uint256 deviationBps_,
        uint256 deviationMax_
    ) internal pure returns (bool) {
        return ((value0_ - value1_) * deviationMax_) / value0_ > deviationBps_;
    }
```
Let us fix value0_ and assume that the interval of value1_ which is not deviated is [value0_ - a, value0_ + b].

a = value0_ * deviationBps_ / deviationMax_
b = value0_ * deviationBps_ / (deviationMax_ - deviationBps_)
So b is always larger than a. The value1_ is one-sided to larger value.
The larger deviationBps_ / deviationMax_ is, the more the value1_ is one-sided.

For example, in the BunniPrice.sol#_validateReserves() function, when the deviation between TWAP Ratio and Reserve Ratio is checked, this error will be occured.

## Impact
Unstablity of Bunni Token price can be enlarged because of the invalid deviation check.
i.e. The reserve ratio can be too larger than twap token ratio.

## Code Snippet
https://github.com/sherlock-audit/2023-11-olympus-web3-master/blob/main/bophades/src/libraries/Deviation.sol#L23-L33

## Tool used
Manual Review

## Recommendation
In the Deviation.sol, the basic value should be determined in two values and the check between the difference ratio divided by the basic value and deviationBps should be applied.