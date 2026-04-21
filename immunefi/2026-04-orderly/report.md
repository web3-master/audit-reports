## Title
Incorrect Settlement Logic Leads to Invalid Position Accounting

## Brief/Intro
A flaw in the settlement logic incorrectly applies realized PnL to a position’s costPosition, rather than limiting its effect to the user’s balance. This results in distorted position accounting and violates the protocol’s documented settlement semantics.

## Vulnerability Details
### Settlement Flow Analysis
During settlement, the protocol processes each execution via the following function:
```solidity
File: LedgerImplA.sol
237:     function executeSettlement(EventTypes.Settlement calldata settlement, uint64 eventId) external override {
...
261:         // for-loop ledger execution
262:         for (uint256 i = 0; i < length; ++i) {
263:             EventTypes.SettlementExecution calldata ledgerExecution = settlementExecutions[i];
264:             totalSettleAmount += ledgerExecution.settledAmount;
265:             if (!vaultManager.getAllowedSymbol(ledgerExecution.symbolHash)) revert SymbolNotAllowed();
266:             AccountTypes.PerpPosition storage position = account.perpPositions[ledgerExecution.symbolHash];
267:             position.chargeFundingFee(ledgerExecution.sumUnitaryFundings);
268:             position.costPosition += ledgerExecution.settledAmount; //@audit-issue Incorrect logic: realized PnL is added to position cost
269:             position.lastExecutedPrice = ledgerExecution.markPrice;
270:             position.lastSettledPrice = ledgerExecution.markPrice;
271:             // check balance + settledAmount >= 0, where balance should cast to int128 first
272:             int128 balance = account.balances[settlement.settledAssetHash];
273:             // if (balance + ledgerExecution.settledAmount < 0) {
274:             //     revert BalanceNotEnough(balance, ledgerExecution.settledAmount);
275:             // }
276:             account.balances[settlement.settledAssetHash] = balance + ledgerExecution.settledAmount;
277:             if (position.isFullSettled()) {
278:                 delete account.perpPositions[ledgerExecution.symbolHash];
279:             }
280:             emit SettlementExecution(
281:                 ledgerExecution.symbolHash,
282:                 ledgerExecution.markPrice,
283:                 ledgerExecution.sumUnitaryFundings,
284:                 ledgerExecution.settledAmount
285:             );
286:         }
...
```
The function correctly updates the user’s balance with the realized PnL (settledAmount). 
However, it also incorrectly adds this amount to position.costPosition, which is inconsistent with standard perpetual futures accounting.

According to the protocol’s documentation, settlement should only affect the user’s balance, not the position’s cost basis:
https://orderly.network/docs/introduction/trade-on-orderly/perpetual-futures/margin-leverage-and-pnl#how-the-settlement-process-works


### Example Scenario
1. A user opens a position with:
* Qty = 1,000,000,000
* costPosition = 100,000,000
* lastSumUnitaryFundings = 10,000,000,000,000,000
2. Market price increases, generating +100,000,000 PnL.
3. The user executes settlement with:
* settledAmount = 100,000,000
* sumUnitaryFundings = 20,000,000,000,000,000
4. The function updates costPosition as follows:

```
costPosition =
    original costPosition
  + funding fee adjustment
  + settledAmount

= 100,000,000
  + (1,000,000,000 * (20e15 - 10e15) / 1e17)
  + 100,000,000
= 300,000,000
```
5. This results in an artificial increase in position cost due to realized profit, which is incorrect.

## Impact Details
* Incorrect Position Accounting:
The position’s cost basis becomes inflated by realized PnL, breaking fundamental accounting assumptions.
* Protocol Invariant Violation:
Settlement is expected to transfer PnL to balance only; modifying costPosition violates this invariant.
* Downstream Risk Amplification:
Since costPosition is used in other critical calculations, this corruption can propagate.
* Loss of Protocol Trust:
Deviations from documented behavior undermine user confidence and protocol reliability.

## Suggested fixes (recommended)
LedgerImplA.executeSettlement() function should be fixed as follows.
```solidity
File: LedgerImplA.sol
237:     function executeSettlement(EventTypes.Settlement calldata settlement, uint64 eventId) external override {
...
261:         // for-loop ledger execution
262:         for (uint256 i = 0; i < length; ++i) {
263:             EventTypes.SettlementExecution calldata ledgerExecution = settlementExecutions[i];
264:             totalSettleAmount += ledgerExecution.settledAmount;
265:             if (!vaultManager.getAllowedSymbol(ledgerExecution.symbolHash)) revert SymbolNotAllowed();
266:             AccountTypes.PerpPosition storage position = account.perpPositions[ledgerExecution.symbolHash];
267:             position.chargeFundingFee(ledgerExecution.sumUnitaryFundings);
268:             // position.costPosition += ledgerExecution.settledAmount; //@audit-issue This is wrong. Settled PnL should only be applied to balance.
269:             position.lastExecutedPrice = ledgerExecution.markPrice;
270:             position.lastSettledPrice = ledgerExecution.markPrice;
271:             // check balance + settledAmount >= 0, where balance should cast to int128 first
272:             int128 balance = account.balances[settlement.settledAssetHash];
273:             // if (balance + ledgerExecution.settledAmount < 0) {
274:             //     revert BalanceNotEnough(balance, ledgerExecution.settledAmount);
275:             // }
276:             account.balances[settlement.settledAssetHash] = balance + ledgerExecution.settledAmount;
277:             if (position.isFullSettled()) {
278:                 delete account.perpPositions[ledgerExecution.symbolHash];
279:             }
280:             emit SettlementExecution(
281:                 ledgerExecution.symbolHash,
282:                 ledgerExecution.markPrice,
283:                 ledgerExecution.sumUnitaryFundings,
284:                 ledgerExecution.settledAmount
285:             );
286:         }
...
```

## References
https://github.com/OrderlyNetwork/contract-evm/blob/462e1291e3a8131f5d88ea98859796448531046e/src/LedgerImplA.sol#L268

## Proof of Concept
This is unit test code.
```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "../../src/OperatorManager.sol";
import "../../src/VaultManager.sol";
import "../../src/MarketManager.sol";
import "../../src/FeeManager.sol";
import "../mock/LedgerCrossChainManagerMock.sol";
import "../cheater/LedgerCheater.sol";
import "../../src/LedgerImplA.sol";

contract SettlementTest is Test {
    bytes32 constant BROKER_HASH = 0x083098c593f395bea1de45dda552d9f14e8fcb0be3faaa7a1903c5477d7ba7fd;
    bytes32 constant TOKEN_HASH = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant SYMBOL_HASH_BTC_USDC = 0x1111101010101010101010101010101010101010101010101010101010101010;
    bytes32 constant SYMBOL_HASH_ETH_USDC = 0x2222101010101010101010101010101010101010101010101010101010101010;
    uint256 constant CHAIN_ID = 986532;
    bytes32 constant ALICE = 0xa11ce00000000000000000000000000000000000000000000000000000000000;
    bytes32 constant BOB = 0xb0b0000000000000000000000000000000000000000000000000000000000000;
    bytes32 constant INSURANCE_FUND = 0x1234123412341234123412341234123412341234123412341234123412341234;

    ProxyAdmin admin;
    address constant operatorAddress = address(0x1234567890);
    LedgerCrossChainManagerMock ledgerCrossChainManager;
    IOperatorManager operatorManager;
    IVaultManager vaultManager;
    LedgerCheater ledger;
    IFeeManager feeManager;
    IMarketManager marketManager;
    TransparentUpgradeableProxy operatorProxy;
    TransparentUpgradeableProxy vaultProxy;
    TransparentUpgradeableProxy ledgerProxy;
    TransparentUpgradeableProxy feeProxy;
    TransparentUpgradeableProxy marketProxy;

    function setUp() public {
        admin = new ProxyAdmin();

        ledgerCrossChainManager = new LedgerCrossChainManagerMock();

        IOperatorManager operatorManagerImpl = new OperatorManager();
        IVaultManager vaultManagerImpl = new VaultManager();
        ILedger ledgerImpl = new LedgerCheater();
        IFeeManager feeImpl = new FeeManager();
        IMarketManager marketImpl = new MarketManager();
        LedgerImplA ledgerImplA = new LedgerImplA();

        bytes memory initData = abi.encodeWithSignature("initialize()");
        operatorProxy = new TransparentUpgradeableProxy(address(operatorManagerImpl), address(admin), initData);
        vaultProxy = new TransparentUpgradeableProxy(address(vaultManagerImpl), address(admin), initData);
        ledgerProxy = new TransparentUpgradeableProxy(address(ledgerImpl), address(admin), initData);
        feeProxy = new TransparentUpgradeableProxy(address(feeImpl), address(admin), initData);
        marketProxy = new TransparentUpgradeableProxy(address(marketImpl), address(admin), initData);

        operatorManager = IOperatorManager(address(operatorProxy));
        vaultManager = IVaultManager(address(vaultProxy));
        ledger = LedgerCheater(address(ledgerProxy));
        feeManager = IFeeManager(address(feeProxy));
        marketManager = IMarketManager(address(marketProxy));

        ledger.setOperatorManagerAddress(address(operatorManager));
        ledger.setCrossChainManager(address(ledgerCrossChainManager));
        ledger.setVaultManager(address(vaultManager));
        ledger.setFeeManager(address(feeManager));
        ledger.setMarketManager(address(marketManager));
        ledger.setLedgerImplA(address(ledgerImplA));

        operatorManager.setOperator(operatorAddress);
        operatorManager.setLedger(address(ledger));

        vaultManager.setLedgerAddress(address(ledger));
        if (!vaultManager.getAllowedToken(TOKEN_HASH)) {
            vaultManager.setAllowedToken(TOKEN_HASH, true);
        }
        if (!vaultManager.getAllowedBroker(BROKER_HASH)) {
            vaultManager.setAllowedBroker(BROKER_HASH, true);
        }
        if (!vaultManager.getAllowedSymbol(SYMBOL_HASH_BTC_USDC)) {
            vaultManager.setAllowedSymbol(SYMBOL_HASH_BTC_USDC, true);
        }
        if (!vaultManager.getAllowedSymbol(SYMBOL_HASH_ETH_USDC)) {
            vaultManager.setAllowedSymbol(SYMBOL_HASH_ETH_USDC, true);
        }
        vaultManager.setAllowedChainToken(TOKEN_HASH, CHAIN_ID, true);

        feeManager.setLedgerAddress(address(ledger));

        marketManager.setOperatorManagerAddress(address(operatorManager));
        marketManager.setLedgerAddress(address(ledger));

        ledgerCrossChainManager.setLedger(address(ledger));
        ledgerCrossChainManager.setOperatorManager(address(operatorManager));

        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(BOB, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 10_000_000_000, CHAIN_ID);

        ledger.cheatSetUserPosition(
            BOB,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: 1_000_000_000,
                costPosition: 100_000_000,      //@audit-note: Initial position debt value.
                lastSumUnitaryFundings: 10_000_000_000_000_000,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );
    }

    function test_one_settlement_execution() public {
        EventTypes.SettlementExecution[] memory executions = new EventTypes.SettlementExecution[](1);
        executions[0] = EventTypes.SettlementExecution({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            sumUnitaryFundings: 20_000_000_000_000_000,
            markPrice: 40_000_000,
            settledAmount: 100_000_000          //@audit-note: PnL value(Profit).
        });
        vm.prank(address(operatorManager));
        ledger.executeSettlement({
            settlement: EventTypes.Settlement({
                accountId: BOB,
                settledAmount: 100_000_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: 0x0,
                insuranceTransferAmount: 0,
                settlementExecutions: executions,
                timestamp: 0
            }),
            eventId: 1
        });

        assertEq(ledger.getUserLedgerBalance(BOB, TOKEN_HASH), 1_100_000_000);  // @audit-note: User collateral balance changed correctly!

        AccountTypes.PerpPosition memory position = ledger.getPerpPosition(BOB, SYMBOL_HASH_ETH_USDC);

        //
        //@audit-issue: Position's new debt value should be: Original value + funding fee!.
        // That is correct new costPosition = 100_000_000 + 1_000_000_000 * (20_000_000_000_000_000 - 10_000_000_000_000_000) / 1e17 = 200_000_000.
        // But the ledger.executeSettlement() function adds the PnL value into the position's debt value, which results costPosition to become 300_000_000.
        // As a result, the following test fails to pass.
        //
        assertEq(position.costPosition, 200_000_000);
        assertEq(position.lastExecutedPrice, 40_000_000);
        assertEq(position.lastSumUnitaryFundings, 20_000_000_000_000_000);
        assertEq(position.positionQty, 1_000_000_000);

        assertEq(ledger.getUserLedgerLastEngineEventId(BOB), 1);
    }
}
```

To run this test code, please run
```shell
forge test -v --mt test_one_settlement_execution
```