| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-users-attempt-to-deposit--withdraw-reverts-due-to-the-calculation-style-inside-_calculateshares) | User's attempt to deposit & withdraw reverts due to the calculation style inside _calculateShares() |

# [M-01] User's attempt to deposit & withdraw reverts due to the calculation style inside _calculateShares()
## Summary & Impact
Scenario 1 :

The following flow of events (one among many) causes a revert:

Alice calls depositExactAmountETH() to deposit 1 ether. This executes successfully, as expected.
Bob calls depositExactAmountETH() to deposit 1.5 ether (or 0.5 ether or 1 ether or 2 ether or any other value). This reverts unexpectedly.
In case Bob were attempting to make this deposit to rescue his soon-to-become or already bad debt and to avoid liquidation, this revert will delay his attempt which could well be enough for him to be liquidated by any liquidator, causing loss of funds for Bob. Here's a concrete example with numbers:

Bob calls depositExactAmountETH() to deposit 1 ether. This executes successfully, as expected.
Bob calls borrowExactAmountETH() to borrow 0.7 ether. This executes successfully, as expected.
Bob can see that price is soon going to spiral downwards and cause a bad debt. He plans to deposit some additional collateral to safeguard himself. He calls depositExactAmountETH() again to deposit 0.5 ether. This reverts unexpectedly.
Prices go down and he is liquidated.

Scenario 2 :

A similar revert occurs when the following flow of events occur:

Alice calls depositExactAmountETH() to deposit 10 ether. This executes successfully, as expected.
Bob calls withdrawExactAmountETH() to withdraw 10 ether (or 10 ether - 1 or 10 ether - 1000 or 9.5 ether or 9.1 ether). This reverts unexpectedly.
Bob is not able to withdraw his entire deposit. If he leaves behind 1 ether and withdraws only 9 ether, then he does not face a revert.




In both of the above cases, eventually the revert is caused by the validation failure on L234-L237 due to the check inside _validateParameter():
```solidity
  File: contracts/WiseLending.sol

  210:              function _compareSharePrices(
  211:                  address _poolToken,
  212:                  uint256 _lendSharePriceBefore,
  213:                  uint256 _borrowSharePriceBefore
  214:              )
  215:                  private
  216:                  view
  217:              {
  218:                  (
  219:                      uint256 lendSharePriceAfter,
  220:                      uint256 borrowSharePriceAfter
  221:                  ) = _getSharePrice(
  222:                      _poolToken
  223:                  );
  224:
  225:                  uint256 currentSharePriceMax = _getCurrentSharePriceMax(
  226:                      _poolToken
  227:                  );
  228:
  229:                  _validateParameter(
  230:                      _lendSharePriceBefore,
  231:                      lendSharePriceAfter
  232:                  );
  233:
  234: @--->            _validateParameter(
  235: @--->                lendSharePriceAfter,
  236: @--->                currentSharePriceMax
  237:                  );
  238:
  239:                  _validateParameter(
  240:                      _borrowSharePriceBefore,
  241:                      currentSharePriceMax
  242:                  );
  243:
  244:                  _validateParameter(
  245:                      borrowSharePriceAfter,
  246:                      _borrowSharePriceBefore
  247:                  );
  248:              }
```
Root Cause
_compareSharePrices() is called by _syncPoolAfterCodeExecution() which is executed due to the syncPool modifier attached to depositExactAmountETH().
Before _syncPoolAfterCodeExecution() in the above step is executed, the following internal calls are made by depositExactAmountETH():
The _handleDeposit() function is called on L407 which in-turn calls calculateLendingShares() on L115
The calculateLendingShares() function now calls _calculateShares() on L26
_calculateShares() decreases the calculated shares by 1 which is represented by the variable lendingPoolData[_poolToken].totalDepositShares inside _getSharePrice().
The _getSharePrice() functions uses this lendingPoolData[_poolToken].totalDepositShares variable in the denominator on L185-187 and hence in many cases, returns an increased value ( in this case it evaluates to 1000000000000000001 ) which is captured in the variable lendSharePriceAfter inside _compareSharePrices().
Circling back to our first step, this causes the validation to fail on L234-L237 inside _compareSharePrices() since the lendSharePriceAfter is now greater than currentSharePriceMax i.e. 1000000000000000001 > 1000000000000000000. Hence the transaction reverts.
The reduction by 1 inside _calculateShares() is done by the protocol in its own favour to safeguard itself. The lendingPoolData[_poolToken].pseudoTotalPool however is never modified. This mismatch eventually reaches a significant divergence, and is the root cause of these reverts. See

the last comment inside the Proof of Concept-2 (Withdraw scenario) section later in the report.
Option1 inside the Recommended Mitigation Steps section later in the report.


Click to visualize better through relevant code snippets


Proof of Concept-1 (Deposit scenario)
Add the following tests inside contracts/WisenLendingShutdown.t.sol and run via forge test --fork-url mainnet -vvvv --mt test_t0x1c_DepositsRevert to see the tests fail.
```solidity
    function test_t0x1c_DepositsRevert_Simple() 
        public
    {
        uint256 nftId;
        nftId = POSITION_NFTS_INSTANCE.mintPosition(); 
        LENDING_INSTANCE.depositExactAmountETH{value: 1 ether}(nftId); // @audit-info : If you want to make the test pass, change this to `2 ether`

        address bob = makeAddr("Bob");
        vm.deal(bob, 10 ether); // give some ETH to Bob
        vm.startPrank(bob);

        uint256 nftId_bob = POSITION_NFTS_INSTANCE.mintPosition(); 
        LENDING_INSTANCE.depositExactAmountETH{value: 1.5 ether}(nftId_bob); // @audit : REVERTS incorrectly (reverts for numerous values like `0.5 ether`, `1 ether`, `2 ether`, etc.)
    }

    function test_t0x1c_DepositsRevert_With_Borrow() 
        public
    {
        address bob = makeAddr("Bob");
        vm.deal(bob, 10 ether); // give some ETH to Bob
        vm.startPrank(bob);

        uint256 nftId = POSITION_NFTS_INSTANCE.mintPosition(); 
        LENDING_INSTANCE.depositExactAmountETH{value: 1 ether}(nftId); // @audit-info : If you want to make the test pass, change this to `2 ether`

        LENDING_INSTANCE.borrowExactAmountETH(nftId, 0.7 ether);

        LENDING_INSTANCE.depositExactAmountETH{value: 0.5 ether}(nftId); // @audit : REVERTS incorrectly; Bob can't deposit additional collateral to save himself
    }
```
If you want to check with values which make the test pass, change the following line in both the tests and run again:
```solidity
-     LENDING_INSTANCE.depositExactAmountETH{value: 1 ether}(nftId); // @audit-info : If you want to make the test pass, change this to `2 ether`
+     LENDING_INSTANCE.depositExactAmountETH{value: 2 ether}(nftId); // @audit-info : If you want to make the test pass, change this to `2 ether`\
```
There are numerous combinations which will cause such a "revert" scenario to occur. Just to provide another example:

Four initial deposits are made in either Style1 or Style2:

Style1:
Alice makes 4 deposits of 2.5 ether each. Total deposits made by Alice = 4 * 2.5 ether = 10 ether.
Style2:
Alice makes a deposit of 2.5 ether
Bob makes a deposit of 2.5 ether
Carol makes a deposit of 2.5 ether
Dan makes a deposit of 2.5 ether. Total deposits made by 4 users = 4 * 2.5 ether = 10 ether.
Now, Emily tries to make a deposit of 2.5 ether. This reverts.

Proof of Concept-2 (Withdraw scenario)
Add the following test inside contracts/WisenLendingShutdown.t.sol and run via forge test --fork-url mainnet -vvvv --mt test_t0x1c_WithdrawRevert to see the test fail.
```solidity
    function test_t0x1c_WithdrawRevert() 
        public
    {
        address bob = makeAddr("Bob");
        vm.deal(bob, 100 ether); // give some ETH to Bob
        vm.startPrank(bob);

        uint256 nftId = POSITION_NFTS_INSTANCE.mintPosition(); 
        LENDING_INSTANCE.depositExactAmountETH{value: 10 ether}(nftId); 
        
        LENDING_INSTANCE.withdrawExactAmountETH(nftId, 9.1 ether); // @audit : Reverts incorrectly for all values greater than `9 ether`.
    }
```
If you want to check with values which make the test pass, change the following line of the test case like shown below and run again:
```solidity
-     LENDING_INSTANCE.withdrawExactAmountETH(nftId, 9.1 ether); // @audit : Reverts incorrectly for all values greater than `9 ether`.
+     LENDING_INSTANCE.withdrawExactAmountETH(nftId, 9 ether); // @audit : Reverts incorrectly for all values greater than `9 ether`.
```
This failure happened because the moment lendingPoolData[_poolToken].pseudoTotalPool and lendingPoolData[_poolToken].totalDepositShares go below 1 ether, their divergence is significant enough to result in lendSharePrice being calculated as greater than 1000000000000000000 or 1 ether:
```solidity
  lendSharePrice = lendingPoolData[_poolToken].pseudoTotalPool * 1e18 / lendingPoolData[_poolToken].totalDepositShares
```
which in this case evaluates to 1000000000000000001. This brings us back to our root cause of failure. Due to the divergence, lendSharePrice of 1000000000000000001 has become greater than currentSharePriceMax of 1000000000000000000 and fails the validation on L234-L237 inside _compareSharePrices().

Severity
Likelihood: High (possible for a huge number of value combinations, as shown above)

Impact: High / Med (If user is trying to save his collateral, this is high impact. Otherwise he can try later with modified values making it a medium impact.)


Hence severity: High

## Lines of code
https://github.com/code-423n4/2024-02-wise-lending/blob/main/contracts/WiseCore.sol#L115

## Tool used
Manual Review

## Recommended Mitigation Steps
Since the reduction by 1 inside _calculateShares() is being done to round-down in favour of the protocol, removing that without a deeper analysis could prove to be risky as it may open up other attack vectors. Still, two points come to mind which can be explored -

Option1: Reducing lendingPoolData[_poolToken].pseudoTotalPool too would keep it in sync with lendingPoolData[_poolToken].totalDepositShares and hence will avoid the current issue.

Option2: Not reducing it by 1 seems to solve the immediate problem at hand (needs further impact analysis):
```solidity
  File: contracts/MainHelper.sol

  33:               function _calculateShares(
  34:                   uint256 _product,
  35:                   uint256 _pseudo,
  36:                   bool _maxSharePrice
  37:               )
  38:                   private
  39:                   pure
  40:                   returns (uint256)
  41:               {
  42:                   return _maxSharePrice == true
  43:                       ? _product / _pseudo + 1
- 44:                       : _product / _pseudo - 1;
+ 44:                       : _product / _pseudo;
  45:               }
```