## Title
Incorrect Min-Profit Validation Allows Premature Order Closure Without Profit

## Brief/Intro
The protocol supports a “min-profit” order type, which is intended to ensure that a position can only be closed once it has reached a profitable state.

However, due to a critical logic error in LibOrderBook._hasPassMinProfit(), this condition is incorrectly validated. 
As a result, orders configured with the min-profit constraint can be closed even when no profit has been realized, violating expected protocol behavior.

## Vulnerability Details
### Close Order Flow
When a close position order is executed, the protocol enforces the min-profit condition as follows:
```solidity
File: LibOrderBook.sol
277: 
278:     function fillClosePositionOrder(
279:         OrderBookStorage storage orderBook,
280:         PositionOrderParams memory orderParams,
281:         uint64 orderId,
282:         uint96 fillAmount,
283:         uint96 tradingPrice,
284:         uint96[] memory markPrices,
285:         uint32 blockTimestamp
286:     ) external returns (uint96 retTradingPrice) {
...
306:         // check min profit
307:         if (orderParams.shouldReachMinProfit()) {
308:             require(_hasPassMinProfit(orderBook, orderParams, oldSubAccount, blockTimestamp, tradingPrice), "PFT"); // order must have ProFiT      //@audit-issue This will be passed wrongly!!
309:         }
310:         // auto withdraw
311:         uint96 collateralAmount = orderParams.collateral;
312:         if (collateralAmount > 0) {
313:             uint96 collateralPrice = markPrices[orderParams.subAccountId.collateralId()];
314:             uint96 assetPrice = markPrices[orderParams.subAccountId.assetId()];
315:             IDegenPool(orderBook.pool).withdrawCollateral(
316:                 orderParams.subAccountId,
317:                 collateralAmount,
318:                 collateralPrice,
319:                 assetPrice
320:             );
321:         }
...
336:     }
```
The _hasPassMinProfit() function is expected to return true only when the position is profitable (or satisfies additional timing/rate conditions).

### Faulty Profit Validation Logic
```solidity
File: LibOrderBook.sol
453: 
454:     function _hasPassMinProfit(
455:         OrderBookStorage storage orderBook,
456:         PositionOrderParams memory orderParams,
457:         SubAccount memory oldSubAccount,
458:         uint32 blockTimestamp,
459:         uint96 tradingPrice
460:     ) private view returns (bool) {
461:         if (oldSubAccount.size == 0) {
462:             return true;
463:         }
464:         require(tradingPrice > 0, "P=0"); // Price Is Zero
465:         bool hasProfit = orderParams.subAccountId.isLong()
466:             ? tradingPrice > oldSubAccount.entryPrice
467:             : tradingPrice < oldSubAccount.entryPrice;
468:         if (!hasProfit) {
469:             return true;       //@audit-issue Critical coding error! Incorrect: should return false
470:         }
471:         uint8 assetId = orderParams.subAccountId.assetId();
472:         uint32 minProfitTime = IDegenPool(orderBook.pool)
473:             .getAssetParameter(assetId, LibConfigKeys.MIN_PROFIT_TIME)
474:             .toUint32();
475:         uint32 minProfitRate = IDegenPool(orderBook.pool)
476:             .getAssetParameter(assetId, LibConfigKeys.MIN_PROFIT_RATE)
477:             .toUint32();
478:         if (blockTimestamp >= oldSubAccount.lastIncreasedTime + minProfitTime) {
479:             return true;
480:         }
481:         uint96 priceDelta = tradingPrice >= oldSubAccount.entryPrice
482:             ? tradingPrice - oldSubAccount.entryPrice
483:             : oldSubAccount.entryPrice - tradingPrice;
484:         if (priceDelta >= uint256(oldSubAccount.entryPrice).rmul(minProfitRate).toUint96()) {
485:             return true;
486:         }
487:         return false;
488:     }
489: 
```
This logic contains a critical flaw:

* When the position has no profit, hasProfit == false
* Instead of rejecting the condition, the function returns true
* This effectively bypasses the min-profit requirement entirely

The check always passes, regardless of profitability.


### Example Scenario
1. A user opens a position at price = 1000 with min-profit constraint enabled
2. Market price remains at 1000 (no profit)
3. A broker executes a close order with tradingPrice = 1000
4. _hasPassMinProfit() evaluates: hasProfit = false. Function returns true due to bug.
5. The position is closed without any profit, violating protocol guarantees

## Impact Details
* Min-profit guarantee is broken: Users relying on this feature cannot enforce profitable exits.
* Premature position closure: Third parties (e.g., brokers/keepers) can close positions without profit.
* Loss of expected gains: Users may lose potential upside due to forced early execution.
* Protocol trust degradation: Violates expected semantics of order types.

## Suggested fixes (recommended)
The function should return false when no profit is present.
LibOrderBook._hasPassMinProfit() function should be fixed as follows.
```solidity
File: LibOrderBook.sol
453: 
454:     function _hasPassMinProfit(
455:         OrderBookStorage storage orderBook,
456:         PositionOrderParams memory orderParams,
457:         SubAccount memory oldSubAccount,
458:         uint32 blockTimestamp,
459:         uint96 tradingPrice
460:     ) private view returns (bool) {
461:         if (oldSubAccount.size == 0) {
462:             return true;
463:         }
464:         require(tradingPrice > 0, "P=0"); // Price Is Zero
465:         bool hasProfit = orderParams.subAccountId.isLong()
466:             ? tradingPrice > oldSubAccount.entryPrice
467:             : tradingPrice < oldSubAccount.entryPrice;
468:         if (!hasProfit) {
469:             return false;       //@audit-issue Should be fixed like this!
470:         }
471:         uint8 assetId = orderParams.subAccountId.assetId();
472:         uint32 minProfitTime = IDegenPool(orderBook.pool)
473:             .getAssetParameter(assetId, LibConfigKeys.MIN_PROFIT_TIME)
474:             .toUint32();
475:         uint32 minProfitRate = IDegenPool(orderBook.pool)
476:             .getAssetParameter(assetId, LibConfigKeys.MIN_PROFIT_RATE)
477:             .toUint32();
478:         if (blockTimestamp >= oldSubAccount.lastIncreasedTime + minProfitTime) {
479:             return true;
480:         }
481:         uint96 priceDelta = tradingPrice >= oldSubAccount.entryPrice
482:             ? tradingPrice - oldSubAccount.entryPrice
483:             : oldSubAccount.entryPrice - tradingPrice;
484:         if (priceDelta >= uint256(oldSubAccount.entryPrice).rmul(minProfitRate).toUint96()) {
485:             return true;
486:         }
487:         return false;
488:     }
489: 
```

## References
https://github.com/mux-world/mux-degen-protocol/blob/c5bfe81255fb0af8834709cffe019e9fd08efad8/contracts/libraries/LibOrderBook.sol#L469

## Proof of Concept
This is unit test code.
```typescript
import { ethers } from "hardhat"
import "@nomiclabs/hardhat-waffle"
import { expect } from "chai"
import { toWei, createContract, OrderType, assembleSubAccountId, PositionOrderFlags, toBytes32, rate, BROKER_ROLE } from "../scripts/deployUtils"
import { OB_CANCEL_COOL_DOWN_KEY, OB_LIMIT_ORDER_TIMEOUT_KEY, OB_LIQUIDITY_LOCK_PERIOD_KEY, OB_MARKET_ORDER_TIMEOUT_KEY, pad32l } from "../scripts/deployUtils"
import { Contract } from "ethers"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"
import { MockDegenPool, OrderBook } from "../typechain"
import { time } from "@nomicfoundation/hardhat-network-helpers"
const U = ethers.utils

function parsePositionOrder(orderData: string) {
  const [subAccountId, collateral, size, price, tpPrice, slPrice, expiration, tpslExpiration, profitTokenId, tpslProfitTokenId, flags] = ethers.utils.defaultAbiCoder.decode(
    ["bytes32", "uint96", "uint96", "uint96", "uint96", "uint96", "uint32", "uint32", "uint8", "uint8", "uint8"],
    orderData
  )
  return {
    subAccountId,
    collateral,
    size,
    price,
    tpPrice,
    slPrice,
    expiration,
    tpslExpiration,
    profitTokenId,
    tpslProfitTokenId,
    flags,
  }
}

function parseLiquidityOrder(orderData: string) {
  const [rawAmount, assetId, isAdding] = ethers.utils.defaultAbiCoder.decode(["uint96", "uint8", "bool"], orderData)
  return {
    rawAmount,
    assetId,
    isAdding,
  }
}

function parseWithdrawalOrder(orderData: string) {
  const [subAccountId, rawAmount, profitTokenId, isProfit] = ethers.utils.defaultAbiCoder.decode(["bytes32", "uint96", "uint8", "bool"], orderData)
  return {
    subAccountId,
    rawAmount,
    profitTokenId,
    isProfit,
  }
}

describe("Order", () => {
  const refCode = toBytes32("")
  let orderBook: OrderBook
  let pool: MockDegenPool
  let mlp: Contract
  let atk: Contract
  let ctk: Contract

  let user0: SignerWithAddress
  let broker: SignerWithAddress
  let timestampOfTest: number

  before(async () => {
    const accounts = await ethers.getSigners()
    user0 = accounts[0]
    broker = accounts[1]
  })

  beforeEach(async () => {
    timestampOfTest = await time.latest()
    ctk = await createContract("MockERC20", ["CTK", "CTK", 18])
    atk = await createContract("MockERC20", ["ATK", "ATK", 18])
    mlp = await createContract("MockERC20", ["MLP", "MLP", 18])
    pool = await createContract("MockDegenPool") as MockDegenPool
    const libOrderBook = await createContract("LibOrderBook")
    orderBook = (await createContract("OrderBook", [], { "contracts/libraries/LibOrderBook.sol:LibOrderBook": libOrderBook })) as OrderBook
    await orderBook.initialize(pool.address, mlp.address)
    await orderBook.grantRole(BROKER_ROLE, broker.address)
    await orderBook.setConfig(OB_LIQUIDITY_LOCK_PERIOD_KEY, pad32l(60 * 15))
    await orderBook.setConfig(OB_MARKET_ORDER_TIMEOUT_KEY, pad32l(60 * 2))
    await orderBook.setConfig(OB_LIMIT_ORDER_TIMEOUT_KEY, pad32l(86400 * 365))
    await orderBook.setConfig(OB_CANCEL_COOL_DOWN_KEY, pad32l(5))
    await pool.setAssetAddress(0, ctk.address)
    await pool.setAssetAddress(1, atk.address)
    // tokenId, minProfit, minProfit, lotSize
    await pool.setAssetParams(1, 0, rate("0"), toWei('0.1'))
    // assetId, trade, open, short, enable, stable, strict, liquidity
    await pool.setAssetFlags(0, false, false, false, true, true, true, true)
    await pool.setAssetFlags(1, true, true, true, true, false, false, false)
    await pool.setAssetFlags(2, false, false, false, true, true, true, true)
  })

  it.only("close long position - must profit - but can be closed without profit!!!", async () => {
    const subAccountId = assembleSubAccountId(user0.address, 0, 1, true)
    // open
    await pool.openPosition(subAccountId, toWei("0.1"), toWei("1000"), [toWei("1"), toWei("1000"), toWei("1")])
    {
      await expect(orderBook.placePositionOrder(
        {
          subAccountId,
          collateral: toWei("0"),
          size: toWei("0.1"),
          price: toWei("1000"),
          tpPrice: toWei("0"),
          slPrice: toWei("0"),
          expiration: timestampOfTest + 1000 + 86400,
          tpslExpiration: timestampOfTest + 1000 + 86400,
          profitTokenId: 0,
          tpslProfitTokenId: 0,
          flags: PositionOrderFlags.WithdrawAllIfEmpty + PositionOrderFlags.ShouldReachMinProfit,
        }, refCode
      )).to.revertedWith("MPT")
    }
    // place close - success
    {
      await pool.setAssetAddress(1, atk.address)
      // assetId, minProfit, minProfit, lotSize
      await pool.setAssetParams(1, 60, rate("0.10"), toWei('0.1'))
      await orderBook.placePositionOrder(
        {
          subAccountId,
          collateral: toWei("0"),
          size: toWei("0.1"),
          price: toWei("1000"),
          tpPrice: toWei("0"),
          slPrice: toWei("0"),
          expiration: timestampOfTest + 1000 + 86400,
          tpslExpiration: timestampOfTest + 1000 + 86400,
          profitTokenId: 0,
          tpslProfitTokenId: 0,
          flags: PositionOrderFlags.WithdrawAllIfEmpty + PositionOrderFlags.ShouldReachMinProfit,
        }, refCode
      )
      {
        const orders = await orderBook.getOrders(0, 100)
        expect(orders.totalCount).to.equal(1)
        expect(orders.orderDataArray.length).to.equal(1)
      }
    }
    // place close - profit/time not reached
    //@audit-issue The closing price is same as entry price, which means no profit at all. But this fill order tx doesn't revert!
    {
      await expect(orderBook.connect(broker).fillPositionOrder(0, toWei('0.1'), toWei("1000"), [toWei("1"), toWei("1000"), toWei("1")])).to.revertedWith("PFT")
      const orders = await orderBook.getOrders(0, 100)
      expect(orders.totalCount).to.equal(1)
      expect(orders.orderDataArray.length).to.equal(1)
    }
  })
})

```

To run this test code, please run
```shell
npx hardhat test
```