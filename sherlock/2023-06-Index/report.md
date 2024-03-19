| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-change-price-calculation-in-boundedstepwiseexponentialpriceadaptergetprice-is-incorrect) | Change price calculation in BoundedStepwiseExponentialPriceAdapter.getPrice() is incorrect. |


# [M-01] Change price calculation in BoundedStepwiseExponentialPriceAdapter.getPrice() is incorrect.
## Summary
Change price calculation in BoundedStepwiseExponentialPriceAdapter.getPrice() is incorrect.

## Vulnerability Detail
BoundedStepwiseExponentialPriceAdapter.getPrice() calculates component price of that moment.
The code is as follows:
```solidity
File: BoundedStepwiseExponentialPriceAdapter.sol
28:     function getPrice(
29:         address /* _setToken */,
30:         address /* _component */,
31:         uint256 /* _componentQuantity */,
32:         uint256 _timeElapsed,
33:         uint256 /* _duration */,
34:         bytes memory _priceAdapterConfigData
35:     )
36:         external
37:         pure
38:         returns (uint256 price)
39:     {
...
73:         uint256 priceChange = scalingFactor * expExpression - WAD; //<--------@audit Incorrect calculation. Must be scalingFactor * (expExpression - WAD).
...
```
From the above code L73, priceChange calculation is incorrect and getPrice() returns greater value than correct value by (scalingFactor - 1) * WAD.

Within the AuctionRebalanceModuleV1._createBidInfo() function, quoteAssetQuantity becomes greater.
```solidity
File: AuctionRebalanceModuleV1.sol
772:     function _createBidInfo(
...
777:     )
...
781:     {
...         
811:         // Calculate the quantity of quote asset involved in the bid.
812:         uint256 quoteAssetQuantity = _calculateQuoteAssetQuantity(
813:             bidInfo.isSellAuction,
814:             _componentQuantity,
815:             bidInfo.componentPrice
816:         );
...
```
And within the _validateQuoteAssetQuantity() function, the condition of quoteAssetQuantity <= _quoteQuantityLimit might be unmet.
```solidity
File: AuctionRebalanceModuleV1.sol
867:     function _validateQuoteAssetQuantity(bool isSellAuction, uint256 quoteAssetQuantity, uint256 _quoteQuantityLimit, uint256 preBidTokenSentBalance) private pure {
868:         if (isSellAuction) {
869:             require(quoteAssetQuantity <= _quoteQuantityLimit, "Quote asset quantity exceeds limit");
870:         } else {
871:             require(quoteAssetQuantity >= _quoteQuantityLimit, "Quote asset quantity below limit");
872:             require(quoteAssetQuantity <= preBidTokenSentBalance, "Insufficient quote asset balance");
873:         }
874:     }
```
As a result, _validateQuoteAssetQuantity() may revert, and then the _createBidInfo() and bid() functions will revert as well.

## Impact
AuctionRebalanceModuleV1.bid() might always fail if the BoundedStepwiseExponentialPriceAdapter is used as priceAdapter and scalingFactor > 1.
When AuctionRebalanceModuleV1.bid() is called, _quoteAssetLimit is passed from outside.
If the caller calculates _quoteAssetLimit value in respect of price = initialPrice +/- scalingFactor * e ^ (timeCoefficient * timeBucket) formula,
the bid() function is reverted.

## Code Snippet
https://github.com/sherlock-audit/2023-06-Index/blob/main/index-protocol/contracts/protocol/integration/auction-price/BoundedStepwiseExponentialPriceAdapter.sol#L73

## Tool used
Manual Review

## Recommendation
```solidity
File: BoundedStepwiseExponentialPriceAdapter.sol
28:     function getPrice(
29:         address /* _setToken */,
30:         address /* _component */,
31:         uint256 /* _componentQuantity */,
32:         uint256 _timeElapsed,
33:         uint256 /* _duration */,
34:         bytes memory _priceAdapterConfigData
35:     )
36:         external
37:         pure
38:         returns (uint256 price)
39:     {
...
73: -       uint256 priceChange = scalingFactor * expExpression - WAD;
73: +       uint256 priceChange = scalingFactor * (expExpression - WAD);
...
```
