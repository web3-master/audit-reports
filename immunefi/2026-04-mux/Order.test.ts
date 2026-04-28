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
