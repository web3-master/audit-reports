| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-an-attacker-can-steal-funds-from-treasury) | An attacker can steal funds from treasury. |
| [H-02](#h-02-the-owner-cannot-withdraw-the-interest-from-liquidation) | The owner cannot withdraw the interest from liquidation. |
| [H-03](#h-03-an-attacker-can-increase-borrowinglastcumulativerate-much-bigger-without-limit-causing-freeze-of-borrowing) | An attacker can increase `borrowing.lastCumulativeRate` much bigger without limit causing freeze of borrowing. |
| [H-04](#h-04-liquidator-will-cause-loss-of-borrowers) | Liquidator will cause loss of borrowers. |
| [H-05](#h-05-admin-will-lose-eth-or-can-be-not-able-to-liquidate-unhealthy-position) | Admin will lose `eth` or can be not able to liquidate unhealthy position. |
| [H-06](#h-06-a-malicious-user-can-use-other-users-signature-when-withdraw-from-cds) | A malicious user can use other user's signature when withdraw from `CDS`. |
| [H-07](#h-07-an-attacker-can-freeze-cds) | An attacker can freeze CDS. |
| [M-01](#m-01-an-attacker-can-manipulate-omnichaindatacdspoolvalue-by-breaking-protocol) | An attacker can manipulate `omniChainData.cdsPoolValue` by breaking protocol. |
| [M-02](#m-02-wrong-applying-of-lastcumulativerate-can-lead-to-increasing-of-borrowers-debt-or-decreasing-borrowers-repay-amount-unexpectedly) | Wrong applying of `lastCumulativeRate` can lead to increasing of borrower's debt or decreasing borrower's repay amount, unexpectedly. |
| [M-03](#m-03-the-borrowinglastcumulaterate-is-updated-wrongly-when-withdrawal-from-borrowing) | The `borrowing.lastCumulateRate` is updated wrongly when withdrawal from borrowing. |



# [H-01] An attacker can steal funds from treasury.
## Summary
Wrong implementation of `borrowing.redeemYields()` will cause loss of eth for protocol as an attacker will redeem more yields by burning `aBond` with low `ethBacked`.

## Vulnerability Detail
- In `BorrowLib.sol:1032`, the protocol burns abond of wrong address, `msg.sender` instead of user.
```solidity
    function redeemYields(
        address user,
        uint128 aBondAmount,
        address usdaAddress,
        address abondAddress,
        address treasuryAddress,
        address borrow
    ) public returns (uint256) {
        // check abond amount is non zewro
        if (aBondAmount == 0) revert IBorrowing.Borrow_NeedsMoreThanZero();
        IABONDToken abond = IABONDToken(abondAddress);
        // get user abond state
        State memory userState = abond.userStates(user);
        // check user have enough abond
992@>   if (aBondAmount > userState.aBondBalance) revert IBorrowing.Borrow_InsufficientBalance();

        ...

        //Burn the usda from treasury
        treasury.approveTokens(
            IBorrowing.AssetName.USDa,
            borrow,
            (usdaToBurn + usdaToTransfer)
        );

        IUSDa usda = IUSDa(usdaAddress);
        // burn the usda
        bool burned = usda.contractBurnFrom(address(treasury), usdaToBurn);
        if (!burned) revert IBorrowing.Borrow_BurnFailed();

        if (usdaToTransfer > 0) {
            // transfer usda to user
            bool transferred = usda.contractTransferFrom(
                address(treasury),
                user,
                usdaToTransfer
            );
            if (!transferred) revert IBorrowing.Borrow_TransferFailed();
        }
        // withdraw eth from ext protocol
1029@>  uint256 withdrawAmount = treasury.withdrawFromExternalProtocol(user,aBondAmount);

1031    //Burn the abond from user
1032@>  bool success = abond.burnFromUser(msg.sender, aBondAmount); @ audit - this is wrong.
        if (!success) revert IBorrowing.Borrow_BurnFailed();

        return withdrawAmount;
    }
```
From `doc` on L1031, we can see about wrong implementation of L1032.   
In fact, on L992 user's state is checked, not state of `msg.sender`. And on L1029 it sends eth according to user's state.
```solidity
    File: Treasury.sol
    function withdrawFromExternalProtocol(
        address user,
        uint128 aBondAmount
    ) external onlyCoreContracts returns (uint256) {
        if (user == address(0)) revert Treasury_ZeroAddress();

        // Withdraw from external protocols
@>      uint256 redeemAmount = withdrawFromIonicByUser(user, aBondAmount);
        // Send the ETH to user
@>      (bool sent, ) = payable(user).call{value: redeemAmount}("");
        // check the transfer is successfull or not
        require(sent, "Failed to send Ether");
        return redeemAmount;
    }
    ...
    function withdrawFromIonicByUser(
        address user,
        uint128 aBondAmount
    ) internal nonReentrant returns (uint256) {
        uint256 currentExchangeRate = ionic.exchangeRateCurrent();
        uint256 currentCumulativeRate = _calculateCumulativeRate(currentExchangeRate, Protocol.Ionic);

        State memory userState = abond.userStates(user);
@>      uint128 depositedAmount = (aBondAmount * userState.ethBacked) / PRECISION;
        uint256 normalizedAmount = (depositedAmount * CUMULATIVE_PRECISION) / userState.cumulativeRate;

        //withdraw amount
        uint256 amount = (currentCumulativeRate * normalizedAmount) / CUMULATIVE_PRECISION;
        // withdraw from ionic
@>      ionic.redeemUnderlying(amount);

        protocolDeposit[Protocol.Ionic].totalCreditedTokens = ionic.balanceOf(address(this));
        protocolDeposit[Protocol.Ionic].exchangeRate = currentExchangeRate;
        // convert weth to eth
        WETH.withdraw(amount);
        return amount;
    }
```

## Impact
The protocol loses eth by an attacker using vulnerability of `borrowing.sol#redeemYields()`.

## Tool used
Manual Review

## Recommendation
`BorrowLib.sol#redeemYields()` function has to be modified as follows. We can consider changing `msg.sender` to user but then an attacker can prevent user's earning through external protocol - ionic.
```solidity
    function redeemYields(
        address user,
        uint128 aBondAmount,
        address usdaAddress,
        address abondAddress,
        address treasuryAddress,
        address borrow
    ) public returns (uint256) {
++      require(user == msg.sender);

        // check abond amount is non zewro
        if (aBondAmount == 0) revert IBorrowing.Borrow_NeedsMoreThanZero();
        IABONDToken abond = IABONDToken(abondAddress);
        // get user abond state
        State memory userState = abond.userStates(user);
        // check user have enough abond
        if (aBondAmount > userState.aBondBalance) revert IBorrowing.Borrow_InsufficientBalance();

        ...

        IUSDa usda = IUSDa(usdaAddress);
        // burn the usda
        bool burned = usda.contractBurnFrom(address(treasury), usdaToBurn);
        if (!burned) revert IBorrowing.Borrow_BurnFailed();

        if (usdaToTransfer > 0) {
            // transfer usda to user
            bool transferred = usda.contractTransferFrom(
                address(treasury),
                user,
                usdaToTransfer
            );
            if (!transferred) revert IBorrowing.Borrow_TransferFailed();
        }
        // withdraw eth from ext protocol
        uint256 withdrawAmount = treasury.withdrawFromExternalProtocol(user,aBondAmount);

        //Burn the abond from user
--      bool success = abond.burnFromUser(msg.sender, aBondAmount);
++      bool success = abond.burnFromUser(user, aBondAmount);  @ dev: this is more readable.
        if (!success) revert IBorrowing.Borrow_BurnFailed();

        return withdrawAmount;
    }
```

# [H-02] The owner cannot withdraw the interest from liquidation.
## Summary
Wrong implementation of withdrawing interest from treasury will cause revert for the owner to withdraw interest from liquidation.

## Vulnerability Detail
- In `Treasury.sol#withdrawInterest()`, there can be underflow for withdrawing the interest from liquidation.
```solidity
    function withdrawInterest(
        address toAddress,
        uint256 amount
    ) external onlyOwner {
        require(toAddress != address(0) && amount != 0,"Input address or amount is invalid");
621@>   require(amount <= (totalInterest + totalInterestFromLiquidation),"Treasury don't have enough interest");
622@>   totalInterest -= amount;
        bool sent = usda.transfer(toAddress, amount);
        require(sent, "Failed to send Ether");
    }
```
From L622, we can see withdrawable amount is `(totalInterest + totalInterestFromLiquidation)`. But if `amount > totalInterest`, `L622` is reverted.

## Impact
The owner cannot withdraw the interest of liquidation from treasury.

## Tool used
Manual Review

## Recommendation
`Treasury.sol#withdrawInterest()` function has to be modified as follows.
```solidity
    function withdrawInterest(
        address toAddress,
        uint256 amount
    ) external onlyOwner {
        require(toAddress != address(0) && amount != 0,"Input address or amount is invalid");
        require(amount <= (totalInterest + totalInterestFromLiquidation),"Treasury don't have enough interest");
--      totalInterest -= amount;
++      if(amount <= totalInterest){
++          totalInterest -= amount;
++      }else{
++          totalInterestFromLiquidation -= amount - totalInterest;
++          totalInterest = 0;
++      }
        bool sent = usda.transfer(toAddress, amount);
        require(sent, "Failed to send Ether");
    }
```

# [H-03] An attacker can increase `borrowing.lastCumulativeRate` much bigger without limit causing freeze of borrowing.
## Summary
Missing update of lastEventTime in `borrowing.sol#calculateCumulativeRate()` will cause freezing of protocol as an attacker will increase `borrowing.lastCumulativeRate` much bigger without limit.

## Vulnerability Detail
- In borrowing.sol#calculateCumulativeRate() function, lastEventTime is not updated.
```solidity
    function calculateCumulativeRate() public returns (uint256) {
        // Get the noOfBorrowers
        uint128 noOfBorrowers = treasury.noOfBorrowers();
        // Call calculateCumulativeRate in borrow library
        uint256 currentCumulativeRate = BorrowLib.calculateCumulativeRate(
            noOfBorrowers,
            ratePerSec,
            lastEventTime,
            lastCumulativeRate
        );
        lastCumulativeRate = currentCumulativeRate;
        return currentCumulativeRate;
    }
```
As you can see above, calculateCumulativeRate() function is public.


## Impact
Protocol can be frozen by an attacker.

## Tool used
Manual Review

## Recommendation
`borrowing.sol#calculateCumulativeRate()` function has to be modified as follows.
```solidity
    function calculateCumulativeRate() public returns (uint256) {
        // Get the noOfBorrowers
        uint128 noOfBorrowers = treasury.noOfBorrowers();
        // Call calculateCumulativeRate in borrow library
        uint256 currentCumulativeRate = BorrowLib.calculateCumulativeRate(
            noOfBorrowers,
            ratePerSec,
            lastEventTime,
            lastCumulativeRate
        );
        lastCumulativeRate = currentCumulativeRate;
++      lastEventTime = block.timestamp;
        return currentCumulativeRate;
    }
```

# [H-04] Liquidator will cause loss of borrowers.
## Summary
Missing update of `lastEventTime` in `borrowing.sol#liquidate()` will cause wrong cumulativeRate leading more debt to borrowers.

## Vulnerability Detail
- In borrowing.sol#liquidate() function, lastEventTime is not updated.
```solidity
    function liquidate(
        address user,
        uint64 index,
        IBorrowing.LiquidationType liquidationType
    ) external payable whenNotPaused(IMultiSign.Functions(2)) onlyAdmin {
        // Check whether the user address is non zero address
        if (user == address(0)) revert Borrow_MustBeNonZeroAddress(user);
        // Check whether the user address is admin address
        if (msg.sender == user) revert Borrow_CantLiquidateOwnAssets();

        // Call calculate cumulative rate fucntion to get interest
@>      calculateCumulativeRate();  @audit: but don't update lastEventTime.
        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // Get the deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(user, index);
        // Calculating fee for lz transaction
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(2),
            getBorrowingResult.depositDetails.assetName,
            _options,
            false
        );
        // Increment number of liquidations
        ++noOfLiquidations;
        (, uint128 ethPrice) = getUSDValue(assetAddress[AssetName.ETH]);
        // Call the liquidateBorrowPosition function in borrowLiquidation contract
        CDSInterface.LiquidationInfo memory liquidationInfo = borrowLiquidation
            .liquidateBorrowPosition{value: msg.value - fee.nativeFee}(
            user,
            index,
            uint64(ethPrice),
            liquidationType,
            lastCumulativeRate
        );

        // Calling Omnichain send function
        globalVariables.sendForLiquidation{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(2),
            noOfLiquidations,
            liquidationInfo,
            getBorrowingResult.depositDetails.assetName,
            fee,
            _options,
            msg.sender
        );
    }
```

## Impact
Missing update of lastEventTime will cause wrong increasing of lastCumulativeRate leading to increasing of borrower's debt.

## Tool used
Manual Review

## Recommendation
`borrowing.sol#liquidate()` function has to be modified as follows.
```solidity
    function liquidate(
        address user,
        uint64 index,
        IBorrowing.LiquidationType liquidationType
    ) external payable whenNotPaused(IMultiSign.Functions(2)) onlyAdmin {
        // Check whether the user address is non zero address
        if (user == address(0)) revert Borrow_MustBeNonZeroAddress(user);
        // Check whether the user address is admin address
        if (msg.sender == user) revert Borrow_CantLiquidateOwnAssets();

        // Call calculate cumulative rate fucntion to get interest
        calculateCumulativeRate();
++      lastEventTime = block.timestamp;

        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // Get the deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(user, index);
        // Calculating fee for lz transaction
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(2),
            getBorrowingResult.depositDetails.assetName,
            _options,
            false
        );
        // Increment number of liquidations
        ++noOfLiquidations;
        (, uint128 ethPrice) = getUSDValue(assetAddress[AssetName.ETH]);
        // Call the liquidateBorrowPosition function in borrowLiquidation contract
        CDSInterface.LiquidationInfo memory liquidationInfo = borrowLiquidation
            .liquidateBorrowPosition{value: msg.value - fee.nativeFee}(
            user,
            index,
            uint64(ethPrice),
            liquidationType,
            lastCumulativeRate
        );

        // Calling Omnichain send function
        globalVariables.sendForLiquidation{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(2),
            noOfLiquidations,
            liquidationInfo,
            getBorrowingResult.depositDetails.assetName,
            fee,
            _options,
            msg.sender
        );
    }
```

# [H-05] Admin will lose `eth` or can be not able to liquidate unhealthy position.
## Summary
Sending eth to wrong address will cause loss of eth for the admin or  will cause DOS of liquidation when the user rejects receiving eth.

## Vulnerability Detail
- In `borrowLiquidation.sol:303`, the protocol sends eth to the user, not liquidator.
```solidity
    if (liqAmountToGetFromOtherChain == 0) {
@>      (bool sent, ) = payable(user).call{value: msg.value}("");
        require(sent, "Failed to send Ether");
    }
```
The address `user` is the one to be liquidated.   
This is wrong.

## Impact
The admin will lose funds when liquidating or fail to liquidate unhealthy position.

## Tool used
Manual Review

## Recommendation
Mitigation steps are as follows.
1. Modify `borrowLiquidation.sol#liquidationType1()` as follows.
```solidity
    function liquidationType1(
        address user,
        uint64 index,
        uint64 currentEthPrice,
--      uint256 lastCumulativeRate
++      uint256 lastCumulativeRate,
++      address liquidator
    ) internal returns (CDSInterface.LiquidationInfo memory liquidationInfo) {
        ...

        // Burn the borrow amount
        treasury.approveTokens(IBorrowing.AssetName.USDa, address(this), depositDetail.borrowedAmount);
        bool success = usda.contractBurnFrom(address(treasury), depositDetail.borrowedAmount);
        if (!success) revert BorrowLiquidation_LiquidateBurnFailed();
        if (liqAmountToGetFromOtherChain == 0) {
--          (bool sent, ) = payable(user).call{value: msg.value}("");
++          (bool sent, ) = payable(liquidator).call{value: msg.value}("");
            require(sent, "Failed to send Ether");
        }
        // Transfer ETH to CDS Pool
        emit Liquidate(
            index,
            liquidationAmountNeeded,
            cdsProfits,
            depositDetail.depositedAmountInETH,
            cds.totalAvailableLiquidationAmount()
        );
        return liquidationInfo;
    }
```
2. Modify `borrowLiquidation.sol#liquidateBorrowPosition()` as follows.
```solidity
    function liquidateBorrowPosition(
        address user,
        uint64 index,
        uint64 currentEthPrice,
        IBorrowing.LiquidationType liquidationType,
--      uint256 lastCumulativeRate
++      uint256 lastCumulativeRate,
++      address liquidator,
    ) external payable onlyBorrowingContract returns (CDSInterface.LiquidationInfo memory liquidationInfo) {
        //? Based on liquidationType do the liquidation
        // Type 1: Liquidation through CDS
        if (liquidationType == IBorrowing.LiquidationType.ONE) {
--          return liquidationType1(user, index, currentEthPrice, lastCumulativeRate);
++          return liquidationType1(user, index, currentEthPrice, lastCumulativeRate, liquidator);
            // Type 2: Liquidation by taking short position in synthetix with 1x leverage
        } else if (liquidationType == IBorrowing.LiquidationType.TWO) {
            liquidationType2(user, index, currentEthPrice);
        }
    }
```
3. Modify `borrowing.sol#liquidate()` as follows.
```solidity
    function liquidate(
        address user,
        uint64 index,
        IBorrowing.LiquidationType liquidationType
    ) external payable whenNotPaused(IMultiSign.Functions(2)) onlyAdmin {
        ...
        // Increment number of liquidations
        ++noOfLiquidations;
        (, uint128 ethPrice) = getUSDValue(assetAddress[AssetName.ETH]);
        // Call the liquidateBorrowPosition function in borrowLiquidation contract
        CDSInterface.LiquidationInfo memory liquidationInfo = borrowLiquidation
            .liquidateBorrowPosition{value: msg.value - fee.nativeFee}(
            user,
            index,
            uint64(ethPrice),
            liquidationType,
--          lastCumulativeRate
++          lastCumulativeRate,
++          msg.sender
        );

        ...
    }
```

# [H-06] A malicious user can use other user's signature when withdraw from `CDS`.
## Summary
Signature verifying in `CDS.sol#withdraw()` does not check about msg.sender so malicious user can use other user's signature breaking protocol's logic.


## Vulnerability Detail
- In `CDS.sol:285`, `msg.sender` is not contained in parameter when calling `_verify()`.   
  And `CDS.sol#_verify()` function does not contain the check of msg.sender.

## Impact
A malicious user can use other user's signature by breaking protocol's logic and can pay low `excessProfitCumulativeValue`. Because of zero-sum, this is protocol's loss.   
The value which user withdraws is calculated from following code.
```solidity
    File: CDS.sol
    ...
343 uint256 currentValue = cdsAmountToReturn(
        msg.sender,
        index,
        omniChainData.cumulativeValue,
        omniChainData.cumulativeValueSign,
        excessProfitCumulativeValue
    ) - 1; //? subtracted extra 1 wei
    
351 cdsDepositDetails.depositedAmount = currentValue;
    ...
```
Here, `CDS.sol#cdsAmountToReturn()` function is as follows.
```solidity
    function cdsAmountToReturn(
        address _user,
        uint64 index,
        uint128 cumulativeValue,
        bool cumulativeValueSign,
        uint256 excessProfitCumulativeValue
    ) private view returns (uint256) {
        uint256 depositedAmount = cdsDetails[_user].cdsAccountDetails[index].depositedAmount;
        uint128 cumulativeValueAtDeposit = cdsDetails[msg.sender].cdsAccountDetails[index].depositValue;
        // Get the cumulative value sign at the time of deposit
        bool cumulativeValueSignAtDeposit = cdsDetails[msg.sender].cdsAccountDetails[index].depositValueSign;
        uint128 valDiff;
        uint128 cumulativeValueAtWithdraw = cumulativeValue;

        // If the depositVal and cumulativeValue both are in same sign
        if (cumulativeValueSignAtDeposit == cumulativeValueSign) {
            // Calculate the value difference
            if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                valDiff = cumulativeValueAtDeposit - cumulativeValueAtWithdraw;
            } else {
                valDiff = cumulativeValueAtWithdraw - cumulativeValueAtDeposit;
            }
            // If cumulative value sign at the time of deposit is positive
            if (cumulativeValueSignAtDeposit) {
                if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                    // Its loss since cumulative val is low
                    uint256 loss = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount - loss);
                } else {
                    // Its gain since cumulative val is high
@>                  uint256 profit = (depositedAmount * (valDiff - excessProfitCumulativeValue)) / 1e11;
                    return (depositedAmount + profit);
                }
            } else {
                if (cumulativeValueAtDeposit > cumulativeValueAtWithdraw) {
                    // Its gain since cumulative val is high
@>                  uint256 profit = (depositedAmount * (valDiff - excessProfitCumulativeValue)) / 1e11;
                    return (depositedAmount + profit);
                } else {
                    // Its loss since cumulative val is low
                    uint256 loss = (depositedAmount * valDiff) / 1e11;
                    return (depositedAmount - loss);
                }
            }
        } else {
            valDiff = cumulativeValueAtDeposit + cumulativeValueAtWithdraw;
            if (cumulativeValueSignAtDeposit) {
                // Its loss since cumulative val at deposit is positive
                uint256 loss = (depositedAmount * valDiff) / 1e11;
                return (depositedAmount - loss);
            } else {
                // Its loss since cumulative val at deposit is negative
@>              uint256 profit = (depositedAmount * (valDiff - excessProfitCumulativeValue)) / 1e11;
                return (depositedAmount + profit);
            }
        }
    }
```
As we can see above, a malicious user can use other user's signature with less `excessProfitCumulativeValue`.

## Tool used
Manual Review

## Recommendation
In `CDS.sol#withdraw()`, we have to modify code so that signature contains `msg.sender`.

# [H-07] An attacker can freeze CDS.
## Summary
Missing authorization of `CDS.sol#updateDownsideProtected()` will cause freezing of CDS as an attacker will increase downsideProtected of CDS to big value.

## Vulnerability Detail
- In `CDS.sol#updateDownsideProtected()`, there is no authorization.
```solidity
    function updateDownsideProtected(uint128 downsideProtectedAmount) external {
        downsideProtected += downsideProtectedAmount;
    }
```
- An attacker calls `CDS.sol#updateDownsideProtected()` to make `CDS.downsideProtected` to very big value.
- Then, `CDS.sol#deposit(), withdraw()` is DOSed because downsideProtected cannot be applied.

## Impact
CDS is frozen by an attacker making `downsideProtected` to big value.

## Tool used
Manual Review

## Recommendation
`CDS.sol#updateDownsideProtected()` function has to be modified as follows.
```solidity
--  function updateDownsideProtected(uint128 downsideProtectedAmount) external {
++  function updateDownsideProtected(uint128 downsideProtectedAmount) external onlyBorrowingContract{
        downsideProtected += downsideProtectedAmount;
    }
```

# [M-01] An attacker can manipulate `omniChainData.cdsPoolValue` by breaking protocol.
## Summary
Missing update of `lastEthprice` in `borrowing.sol#depositTokens()` will cause manipulation of `omniChainData.cdsPoolValue` as an attaker replays `borrowing.sol#depositTokens()` by breaking protocol.

## Vulnerability Detail
- In `borrowing.sol#depositTokens()`, `lastEthprice` is not updated.
```solidity
    function depositTokens(
        BorrowDepositParams memory depositParam
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(0)) {
        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            _options,
            false
        );
        // Get the exchange rate for a collateral and eth price
        (uint128 exchangeRate, uint128 ethPrice) = getUSDValue(assetAddress[depositParam.assetName]);

        totalNormalizedAmount = BorrowLib.deposit(
            BorrowLibDeposit_Params(
                LTV,
                APR,
                lastCumulativeRate,
                totalNormalizedAmount,
                exchangeRate,
                ethPrice,
                lastEthprice
            ),
            depositParam,
            Interfaces(treasury, globalVariables, usda, abond, cds, options),
            assetAddress
        );

        //Call calculateCumulativeRate() to get currentCumulativeRate
        calculateCumulativeRate();
        lastEventTime = uint128(block.timestamp);

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            fee,
            _options,
            msg.sender
        );
    }
```
- In BorrowLib.sol:661, omniChainData is updated with new cdsPoolValue.
```solidity
    (ratio, omniChainData) = calculateRatio(
        params.depositingAmount,
        uint128(libParams.ethPrice),
        libParams.lastEthprice,
        omniChainData.totalNoOfDepositIndices,
        omniChainData.totalVolumeOfBorrowersAmountinWei,
        omniChainData.totalCdsDepositedAmount - omniChainData.downsideProtected,
        omniChainData
    );
    // Check whether the cds have enough funds to give downside prottection to borrower
    if (ratio < (2 * RATIO_PRECISION)) revert IBorrowing.Borrow_NotEnoughFundInCDS();
```
- In `BorrowLib.sol#calculateRatio()`, cdsPoolValue is updated by difference between lastEthprice and currentEthprice.
```solidity
    function calculateRatio(
        uint256 amount,
        uint128 currentEthPrice,
        uint128 lastEthprice,
        uint256 noOfDeposits,
        uint256 totalCollateralInETH,
        uint256 latestTotalCDSPool,
        IGlobalVariables.OmniChainData memory previousData
    ) public pure returns (uint64, IGlobalVariables.OmniChainData memory) {
        uint256 netPLCdsPool;

        // Calculate net P/L of CDS Pool
        // if the current eth price is high
        if (currentEthPrice > lastEthprice) {
            // profit, multiply the price difference with total collateral
@>          netPLCdsPool = (((currentEthPrice - lastEthprice) * totalCollateralInETH) / USDA_PRECISION) / 100;
        } else {
            // loss, multiply the price difference with total collateral
@>          netPLCdsPool = (((lastEthprice - currentEthPrice) * totalCollateralInETH) / USDA_PRECISION) / 100;
        }

        uint256 currentVaultValue;
        uint256 currentCDSPoolValue;

        // Check it is the first deposit
        if (noOfDeposits == 0) {
            // Calculate the ethVault value
            previousData.vaultValue = amount * currentEthPrice;
            // Set the currentEthVaultValue to lastEthVaultValue for next deposit
            currentVaultValue = previousData.vaultValue;

            // Get the total amount in CDS
            // lastTotalCDSPool = cds.totalCdsDepositedAmount();
            previousData.totalCDSPool = latestTotalCDSPool;

            // BAsed on the eth prices, add or sub, profit and loss respectively
            if (currentEthPrice >= lastEthprice) {
@>              currentCDSPoolValue = previousData.totalCDSPool + netPLCdsPool;
            } else {
@>              currentCDSPoolValue = previousData.totalCDSPool - netPLCdsPool;
            }

            // Set the currentCDSPoolValue to lastCDSPoolValue for next deposit
@>          previousData.cdsPoolValue = currentCDSPoolValue;
@>          currentCDSPoolValue = currentCDSPoolValue * USDA_PRECISION;
        } else {
            // find current vault value by adding current depositing amount
            currentVaultValue = previousData.vaultValue + (amount * currentEthPrice);
            previousData.vaultValue = currentVaultValue;

            // BAsed on the eth prices, add or sub, profit and loss respectively
            if (currentEthPrice >= lastEthprice) {
                previousData.cdsPoolValue += netPLCdsPool;
            } else {
                previousData.cdsPoolValue -= netPLCdsPool;
            }
@>          previousData.totalCDSPool = latestTotalCDSPool;
@>          currentCDSPoolValue = previousData.cdsPoolValue * USDA_PRECISION;
        }

        // Calculate ratio by dividing currentEthVaultValue by currentCDSPoolValue,
        // since it may return in decimals we multiply it by 1e6
@>      uint64 ratio = uint64((currentCDSPoolValue * CUMULATIVE_PRECISION) / currentVaultValue);
        return (ratio, previousData);
    }
```

## Impact
- In case of increasing, `cdsPoolValue` can be much bigger than normal. Then, borrowing is allowed even if protocol is really under water.
- In case of decreasing, `cdsPoolValue` can be decreased so that ratio is small enough to touch `(2 * RATIO_PRECISION)`. Then, borrowing can be DOSed even if cds have enough funds. And withdrawal from CDS can be DOSed.

## Tool used
Manual Review

## Recommendation
`borrowing.sol#depositTokens()` function has to be modified as follows.
```solidity
    function depositTokens(
        BorrowDepositParams memory depositParam
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(0)) {
        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            _options,
            false
        );
        // Get the exchange rate for a collateral and eth price
        (uint128 exchangeRate, uint128 ethPrice) = getUSDValue(assetAddress[depositParam.assetName]);

        totalNormalizedAmount = BorrowLib.deposit(
            BorrowLibDeposit_Params(
                LTV,
                APR,
                lastCumulativeRate,
                totalNormalizedAmount,
                exchangeRate,
                ethPrice,
                lastEthprice
            ),
            depositParam,
            Interfaces(treasury, globalVariables, usda, abond, cds, options),
            assetAddress
        );

        //Call calculateCumulativeRate() to get currentCumulativeRate
        calculateCumulativeRate();
        lastEventTime = uint128(block.timestamp);
++      lastEthprice = ethPrice;

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            fee,
            _options,
            msg.sender
        );
    }
```

# [M-02] Wrong applying of `lastCumulativeRate` can lead to increasing of borrower's debt or decreasing borrower's repay amount, unexpectedly.
## Summary
Applying `lastCumulativeRate` before update it will cause wrong calculation of borrower's `normalizedAmount` leading to increasing of borrower's debt or decreasing of borrower's repay amount, unexpectedly.

## Vulnerability Detail
- In `borrowing.sol#depositTokens()` function, `lastCumulativeRate` is applied before updating it.
```solidity
    function depositTokens(
        BorrowDepositParams memory depositParam
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(0)) {
        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            _options,
            false
        );
        // Get the exchange rate for a collateral and eth price
        (uint128 exchangeRate, uint128 ethPrice) = getUSDValue(assetAddress[depositParam.assetName]);

        totalNormalizedAmount = BorrowLib.deposit(
            BorrowLibDeposit_Params(
                LTV,
                APR,
@>              lastCumulativeRate,
                totalNormalizedAmount,
                exchangeRate,
                ethPrice,
                lastEthprice
            ),
            depositParam,
            Interfaces(treasury, globalVariables, usda, abond, cds, options),
            assetAddress
        );

        //Call calculateCumulativeRate() to get currentCumulativeRate
@>      calculateCumulativeRate();
        lastEventTime = uint128(block.timestamp);

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            fee,
            _options,
            msg.sender
        );
    }
```

- In BorrowLib.sol:750, lastCumulativeRate is applied to calculate `normalizedAmount`.
```solidity
    // Calculate normalizedAmount
    uint256 normalizedAmount = calculateNormAmount(tokensToMint, libParams.lastCumulativeRate);
```

## Impact
- When depositing, borrower gets more `normalizedAmount` than normal - this means he gets more debt.
- When withdrawing, borrower repays less amount than normal - this means protocol's loss because of zero-sum.

## Tool used
Manual Review

## Recommendation
1. `borrowing.sol#depositTokens()` function has to be modified as follows.
```solidity
    function depositTokens(
        BorrowDepositParams memory depositParam
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(0)) {
        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            _options,
            false
        );
        // Get the exchange rate for a collateral and eth price
        (uint128 exchangeRate, uint128 ethPrice) = getUSDValue(assetAddress[depositParam.assetName]);

++      calculateCumulativeRate();
        totalNormalizedAmount = BorrowLib.deposit(
            BorrowLibDeposit_Params(
                LTV,
                APR,
                lastCumulativeRate,
                totalNormalizedAmount,
                exchangeRate,
                ethPrice,
                lastEthprice
            ),
            depositParam,
            Interfaces(treasury, globalVariables, usda, abond, cds, options),
            assetAddress
        );

        //Call calculateCumulativeRate() to get currentCumulativeRate
--      calculateCumulativeRate();
        lastEventTime = uint128(block.timestamp);

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            fee,
            _options,
            msg.sender
        );
    }
```

# [M-03] The `borrowing.lastCumulateRate` is updated wrongly when withdrawal from borrowing.
## Summary
Wrong calculation of `borrowing.lastCumulativeRate` will cause less debt of borrower leading to loss of protocol.

## Vulnerability Detail
- In borrowing.sol#_withdraw() function, lastCumulativeRate is updated after lastEventTime is updated.
```solidity
    function _withdraw(
        address toAddress,
        uint64 index,
        bytes memory odosAssembledData,
        uint64 ethPrice,
        uint128 exchangeRate,
        uint64 withdrawTime
    ) internal {
        ...

        lastEthprice = uint128(ethPrice);
@>      lastEventTime = uint128(block.timestamp);}

        // Call calculateCumulativeRate function to get the interest
@>      calculateCumulativeRate();

        ...
    }
```
- In borrowing.sol#calculateCumulativeRate(), lastCumulativeRate is updated from currentTime and lastEventTime.
```solidity
    function calculateCumulativeRate() public returns (uint256) {
        // Get the noOfBorrowers
        uint128 noOfBorrowers = treasury.noOfBorrowers();
        // Call calculateCumulativeRate in borrow library
@>      uint256 currentCumulativeRate = BorrowLib.calculateCumulativeRate(
            noOfBorrowers,
            ratePerSec,
@>          lastEventTime,  @audit: This is same as block.timestamp.
            lastCumulativeRate
        );
        lastCumulativeRate = currentCumulativeRate;
        return currentCumulativeRate;
    }
```

## Impact
Less lastCumulativeRate leads to less debt of borrower. Because of zero-sum, protocol loses.

## Tool used
Manual Review

## Recommendation
`borrowing.sol#_withdraw()` function has to be modified as follows.
```solidity
    function _withdraw(
        address toAddress,
        uint64 index,
        bytes memory odosAssembledData,
        uint64 ethPrice,
        uint128 exchangeRate,
        uint64 withdrawTime
    ) internal {
        ...

++      calculateCumulativeRate();
        lastEthprice = uint128(ethPrice);
        lastEventTime = uint128(block.timestamp);}

        // Call calculateCumulativeRate function to get the interest
--      calculateCumulativeRate();

        ...
    }
```