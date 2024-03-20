| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-since-there-is-no-penalty-at-cancel-in-auction-attacker-can-manipulate-the-price) | Since there is no penalty at cancel in auction, attacker can manipulate the price. |
| [M-01](#m-01-in-the-sales-of-decreaing-price-token-price-may-jump-to-the-initial-high-price-at-the-end-time-of-the-sale) | In the sales of decreaing price, token price may jump to the initial high price at the end time of the sale. |


# [H-01] Since there is no penalty at cancel in auction, attacker can manipulate the price.
## Impact
At auction, token is sold at a very low price close to zero.
This is in fact the same as losing token.

## Proof of Concept
Any bidder can withdraw the bid without any restriction through AuctionDemo.sol#cancelBid function as follows.
```solidity
File: AuctionDemo.sol
124:    function cancelBid(uint256 _tokenid, uint256 index) public {
125:        require(block.timestamp <= minter.getAuctionEndTime(_tokenid), "Auction ended");
126:        require(auctionInfoData[_tokenid][index].bidder == msg.sender && auctionInfoData[_tokenid][index].status == true);
127:        auctionInfoData[_tokenid][index].status = false;
128:        (bool success, ) = payable(auctionInfoData[_tokenid][index].bidder).call{value: auctionInfoData[_tokenid][index].bid}("");
129:        emit CancelBid(msg.sender, _tokenid, index, success, auctionInfoData[_tokenid][index].bid);
130:    }
```
Therefore, the attacker makes a very low-price bid at the beginning of the auction and then registers a very high-price bid further, preventing other competitors from making a bid.
If a high-price bid is withdrawn just before the auction is over, the attacker can buy the token at a low price.

Here is the attacking scenario.

The manager starts auction for token and the estimated fair price of it is 100.
An attacker, on the beginning of the auction, registers the bid of price 1 (< 100) and the bid of price 10,000 ( > 100) in turn.
Other bidders give up participation because they have to enter the auction only at prices higher than 10,000, which are much higher than the fair price 100.
Just before the end of the auction deadline, the attacker withdraws the second bid at a price of 10,000.
After the auction deadline, the attacker buys a token at a price of 1.
The system (manager + creator) will suffer a loss of `100-1 = 99'.

## Lines of code
https://github.com/code-423n4/2023-10-nextgen/blob/main/smart-contracts/AuctionDemo.sol#L124-L130

## Tool used
Manual Review

## Recommended Mitigation Steps
Modify AuctionDemo.sol#cancelBid function and impose penalty on the highest-priced bidder (msg.sender == returnHighestBidder (_tokenid)).
Do not impose penalty when he is not the highest-priced bidder.

# [M-01] In the sales of decreaing price, token price may jump to the initial high price at the end time of the sale.
## Impact
The buyers who buy tokens at the end of the sale may not buy or buy tokens at unexpected high prices.

## Proof of Concept
If salesOption==2, the selling price of token decreases linearly or exponentially with time.
In the decreaing price sale, the buyer will want to buy a token at the end of the sales period to buy token as cheaply as possible if tokens have no fear of being sold all before the deadline.
However, by the following code in the MinterContract.sol#getPrice function, the price of token will jump to the initial selling price at the end of the sale.
```solidity
File: MinterContract.sol
540:        } else if (collectionPhases[_collectionId].salesOption == 2 && block.timestamp > collectionPhases[_collectionId].allowlistStartTime && block.timestamp < collectionPhases[_collectionId].publicEndTime){
```
That is when block.timestamp == collectionPhases[_collectionId].publicEndTime, an initial price, not a decreased price, is applied.

Here is the reproducing scenario.

Let suppose that total amount of tokens of a collection is 100, initial price is 1000, decrease rate is 30, timePeriod is one hour and sales period is one day.
The expected price at the end of sales is 1000 - 30 * 23 = 310.
A buyer attempts to buy token by calling the MinterContract.sol#mint function at just the end time of sales.
Because MinterContract.sol#getPrice jumps to 1000 at the end of sales, the buyer does not buy tokens or buys tokens at the high price of 1000 eth.

## Lines of code
https://github.com/code-423n4/2023-10-nextgen/blob/main/smart-contracts/MinterContract.sol#L540

## Tool used
Manual Review

## Recommended Mitigation Steps
In MinterContract.sol#L540 modify < with <= as follows.
```solidity
File: MinterContract.sol
540: -       } else if (collectionPhases[_collectionId].salesOption == 2 && block.timestamp > collectionPhases[_collectionId].allowlistStartTime && block.timestamp < collectionPhases[_collectionId].publicEndTime){
540: +       } else if (collectionPhases[_collectionId].salesOption == 2 && block.timestamp > collectionPhases[_collectionId].allowlistStartTime && block.timestamp <= collectionPhases[_collectionId].publicEndTime){
```