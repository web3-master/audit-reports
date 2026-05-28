import { ethers } from "hardhat"
import { expect } from "chai"
import { createContract, toWei } from "../scripts/deployUtils"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"

// The two source-IDs defined in ProxyFactory/Storage.sol
const SOURCE_ID_LIQUIDITY_POOL = 1
const SOURCE_ID_LENDING_POOL   = 2

// Two project IDs (GMX_V1 = 1, GMX_V2 = 2)
const PROJECT_GMX_V1 = 1
const PROJECT_GMX_V2 = 2

describe("PoC: ProxyFactory._getLiquiditySource reads wrong mapping key", () => {
  let owner:  SignerWithAddress
  let proxy:  SignerWithAddress           // a "proxy" address allowed to borrow
  let weth:   any
  let factory: any
  let defaultLP: any
  let lendingPoolForV1: any   // the LP that owner *intends* project-1 to use
  let lendingPoolForV2: any   // the LP that owner *intends* project-2 to use

  beforeEach(async () => {
    [owner, proxy] = await ethers.getSigners()

    weth = await createContract("MockERC20", ["WETH", "WETH", 18])

    // The default LiquidityPool that gets baked into ProxyFactory at init time.
    defaultLP = await createContract("MockLiquidityPool")

    // Two independent LendingPools – each is *meant* to back exactly one project.
    lendingPoolForV1 = await createContract("LendingPool")
    lendingPoolForV2 = await createContract("LendingPool")
    const priceHub  = await createContract("MockPriceHub")
    await lendingPoolForV1.initialize(defaultLP.address, priceHub.address, ethers.constants.AddressZero)
    await lendingPoolForV2.initialize(defaultLP.address, priceHub.address, ethers.constants.AddressZero)

    // Deploy ProxyFactory via TestProxyFactory wrapper (same storage layout, public init)
    factory = await createContract("TestProxyFactory")
    await factory.initialize(weth.address, defaultLP.address)
  })

  it("setLiquiditySource(projectId, sourceId, src) writes _liquiditySource[projectId] but read uses _liquiditySource[sourceId]", async () => {
    // ----------------------------------------------------------------------
    // STEP 1.  Owner explicitly assigns a *different* lending-pool to each project.
    //          - Project 1 (GMX-V1)  -> lendingPoolForV1   (sourceId=2)
    //          - Project 2 (GMX-V2)  -> lendingPoolForV2   (sourceId=2)
    // ----------------------------------------------------------------------
    await factory.setLiquiditySource(PROJECT_GMX_V1, SOURCE_ID_LENDING_POOL, lendingPoolForV1.address)
    await factory.setLiquiditySource(PROJECT_GMX_V2, SOURCE_ID_LENDING_POOL, lendingPoolForV2.address)

    // ----------------------------------------------------------------------
    // STEP 2.  Read it back.  Both projects share the same sourceId (=2),
    //          so the buggy `source = _liquiditySource[sourceId]` collapses them
    //          to a single slot — the address of WHOEVER WAS WRITTEN LAST.
    // ----------------------------------------------------------------------
    const [src1Id, src1Addr] = await factory.getLiquiditySource(PROJECT_GMX_V1)
    const [src2Id, src2Addr] = await factory.getLiquiditySource(PROJECT_GMX_V2)

    console.log("Project 1 expected:", lendingPoolForV1.address)
    console.log("Project 1 returned:", src1Addr)
    console.log("Project 2 expected:", lendingPoolForV2.address)
    console.log("Project 2 returned:", src2Addr)

    // PoC assertions — *both* projects now resolve to lendingPoolForV2,
    // because `_liquiditySource[sourceId=2]` was overwritten by the second setter.
    expect(src1Id).to.eq(SOURCE_ID_LENDING_POOL)
    expect(src2Id).to.eq(SOURCE_ID_LENDING_POOL)

    //  *** THE BUG ***
    expect(src1Addr).to.not.eq(lendingPoolForV1.address)       // project 1 lost its source
    expect(src1Addr).to.eq(lendingPoolForV2.address)           // it now points at project 2's pool
    expect(src2Addr).to.eq(lendingPoolForV2.address)
  })

  it("Setting the source ONLY for project 2 silently breaks project 2's reads (returns address(0))", async () => {
    // Owner only sets a custom LiquidityPool for project 2 (sourceId=1).
    // They never call setLiquiditySource for project 1.
    await factory.setLiquiditySource(PROJECT_GMX_V2, SOURCE_ID_LIQUIDITY_POOL, defaultLP.address)

    // Project 2 -> sourceId=1 -> source = _liquiditySource[1]   (NEVER WRITTEN -> 0x0)
    const [src2Id, src2Addr] = await factory.getLiquiditySource(PROJECT_GMX_V2)
    expect(src2Id).to.eq(SOURCE_ID_LIQUIDITY_POOL)
    expect(src2Addr).to.eq(ethers.constants.AddressZero)        //  *** BUG: zero address returned ***
  })

})
