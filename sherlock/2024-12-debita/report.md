| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-borrowers-will-overpay-fees-when-extending-loans) | Borrowers will overpay fees when extending loans. |
| [M-02](#m-02-malicious-lender-can-delete-all-lend-offers) | Malicious lender can delete all lend offers. |
| [M-03](#m-03-rounding-error-in-debitaincentivesclaimincentives-function) | Rounding error in `DebitaIncentives.claimIncentives()` function. |
| [M-04](#m-04-extending-loan-will-revert-due-to-the-unused-variable) | Extending loan will revert due to the unused variable. |


# [M-01] Borrowers will overpay fees when extending loans.
## Summary
A logical error in the `DebitaV3Loan.extendLoan()` function causes borrowers to always pay the max fee when extending loans, regardless of the acual max deadline of loan offers. This results in borrowers overpaying fees to the protocol.

## Root Cause
- The [DebitaV3Loan.extendLoan()](https://github.com/sherlock-audit/2024-11-debita-finance-v3/blob/main/Debita-V3-Contracts/contracts/DebitaV3Loan.sol#L547-L664) function has logical error in calculating fees as follows:
```solidity
    function extendLoan() public {
        ... SKIP ...

                // if user already paid the max fee, then we dont have to charge them again
                if (PorcentageOfFeePaid != maxFee) {
                    // calculate difference from fee paid for the initialDuration vs the extra fee they should pay because of the extras days of extending the loan.  MAXFEE shouldnt be higher than extra fee + PorcentageOfFeePaid
602:                uint feeOfMaxDeadline = ((offer.maxDeadline * feePerDay) /
                        86400);
                    if (feeOfMaxDeadline > maxFee) {
605:                    feeOfMaxDeadline = maxFee;
                    } else if (feeOfMaxDeadline < feePerDay) {
                        feeOfMaxDeadline = feePerDay;
                    }

                    misingBorrowFee = feeOfMaxDeadline - PorcentageOfFeePaid;
                }
        ... SKIP ...
    }
```
As can be seen, `L602` uses the absolute `offer.maxDeadline` instead of the remaining time after loan start, making `feeOfMaxDeadline` excessively large. Therefore, `feeOfMaxDeadline` will always exceeds `maxFee` and will be set as `maxFee` in `L605`. As a result, borrowers end up paying maxFee regardless of the actual max deadline.

## Internal pre-conditions

## External pre-conditions

## Attack Path
The default value of `maxFee` is `20 * feePerDay` in the codebase.
1. A borrower takes out a loan with `maxDeadline = block.timestamp + 8 days`.
2. After `5 days` passed, the borrower extends the loan.
3. In this case, the `extendLoan()` function pays fees for `20 days` instead of `8 days`.
4. As a result, the borrower overpay fees for `12 days`.

## Impact
Loss of borrowers' funds because the borrowers overpay fees whenever they extend their loans.

## PoC
See the root cause ans attack path.

## Mitigation
Modify the `DebitaV3Loan.extendLoan()` function as follows:
```diff
        ... SKIP ...
-               uint feeOfMaxDeadline = ((offer.maxDeadline * feePerDay) /
+               uint feeOfMaxDeadline = ((offer.maxDeadline - m_loan.startedAt) * feePerDay /
                        86400);
        ... SKIP ...
```

# [M-02] Malicious lender can delete all lend offers.
## Summary
A malicious lender can exploit the the logical error in the lend offer deletion process to delete all active lend offers.

## Root Cause
- The [DebitaLendOfferFactory.deleteOrder()](https://github.com/sherlock-audit/2024-11-debita-finance-v3/blob/main/Debita-V3-Contracts/contracts/DebitaLendOfferFactory.sol#L207-L220) function doesn't delete the `isLendOrderLegit` flag.
- The [DLOImplementation.addFunds()](https://github.com/sherlock-audit/2024-11-debita-finance-v3/blob/main/Debita-V3-Contracts/contracts/DebitaLendOffer-Implementation.sol#L162-L176) function doesn't verify the `isActive` flag before allowing additional funds to be added to a lend offer.
- The [DebitaV3Aggregator.matchOffersV3()](https://github.com/sherlock-audit/2024-11-debita-finance-v3/blob/main/Debita-V3-Contracts/contracts/DebitaV3Aggregator.sol#L274-L647) function doesn't check `isActive` flag but only verify the `isLendOrderLegit` flag when processing lend offers.
- The [DLOImplementation.acceptLendingOffer()](https://github.com/sherlock-audit/2024-11-debita-finance-v3/blob/main/Debita-V3-Contracts/contracts/DebitaLendOffer-Implementation.sol#L109-L139) function doesn't check `isActive` flag but only verify the `availableAmount` value.

## Internal pre-conditions

## External pre-conditions

## Attack Path
1. A malicious lender creates a lend offer with `perpetual = false`.
2. The lend offer is fully matched with a borrow offer and is deleted from the list of active lend offers. The `isActive` flag of the lend offer is set to `false` and `availableAmount` decreases to zero. 
3. Assume that there are multiple active lend offers in the list.
4. The lender adds funds to the deleted lend offer by calling `DLOImplementation.addFunds()` to increase the `availableAmount` of the lend offer again to a non-zero value.
5. The lender fully matches the deleted lend offer to a new borrow offer by calling the `DebitaV3Aggregator.matchOffersV3()` function.
6. The `matchOffersV3()` function calls `DLOImplementation.acceptLendingOffer()`, which then calls `DebitaLendOfferFactory.deleteOrder()`.
7. Due to the logic error in the `deleteOrder()` function, the first active lend offer in the list is deleted.
8. The malicious lender repeats step 4 through 7 multiple times, deleting all active lend offers from the protocol.

## Impact
A malicious lender can delete all active lend offers, effectively disrupting the entire lending system and rendering the protocol useless.

## PoC
1. Step 3 of the attack path is possible because `DLOImplementation.addFunds()` doesn't check `isActive` flag.
2. Step 5 and is possible because `matchOffsetV3()` doesn't check the `isActive` flag but only verify the `isLendOrderLegit` flag.
3. Step 6 is possible because `acceptLendingOffer()` doesn't check the `isActive` flag but only verify the `availableAmount` value.
3. In step 7, the `DebitaLendOfferFactory.deleteOrder()` function contains the following logic:
```solidity
    function deleteOrder(address _lendOrder) external onlyLendOrder {
208:    uint index = LendOrderIndex[_lendOrder];
        LendOrderIndex[_lendOrder] = 0;

        // switch index of the last borrow order to the deleted borrow order
212:    allActiveLendOrders[index] = allActiveLendOrders[activeOrdersCount - 1];
213:    LendOrderIndex[allActiveLendOrders[activeOrdersCount - 1]] = index;

        // take out last borrow order

217:    allActiveLendOrders[activeOrdersCount - 1] = address(0);

219:    activeOrdersCount--;
    }
```
Since the `_lendOrder` has already been deleted, `index` will be `0` in `L208`. As a result, in `L212-L213`, the first lend offer (at index `0`) will be overwritten by the last lend offer (at index `activeOrdersCount - 1`). Finally, in `L217-L219`, the `activeOrdersCount` decreases by `1`, effectively deleting the first lend offer from the list, regardless of the state of `_lendOrder`. 

## Mitigation
Add the check for the `isActive` flag in both the `DLOImplementation.addFunds()` and `DLOImplementation.acceptLendingOffer()` functions to prevent inactive lend offers from being manipulated or matched.

# [M-03] Rounding error in `DebitaIncentives.claimIncentives()` function.
## Summary
There is a rounding error in `DebitaIncentives.claimIncentives()` function.

## Root Cause
- The [DebitaIncentives.claimIncentives()](https://github.com/sherlock-audit/2024-11-debita-finance-v3/blob/main/Debita-V3-Contracts/contracts/DebitaIncentives.sol#L142-L214) function contains a rounding error in calculating percents:
```solidity
    function claimIncentives(
        address[] memory principles,
        address[][] memory tokensIncentives,
        uint epoch
    ) public {
        // get information
        require(epoch < currentEpoch(), "Epoch not finished");

        for (uint i; i < principles.length; i++) {
            address principle = principles[i];
            uint lentAmount = lentAmountPerUserPerEpoch[msg.sender][
                hashVariables(principle, epoch)
            ];
            // get the total lent amount for the epoch and principle
            uint totalLentAmount = totalUsedTokenPerEpoch[principle][epoch];

            uint porcentageLent;

            if (lentAmount > 0) {
161:            porcentageLent = (lentAmount * 10000) / totalLentAmount;
            }

            uint borrowAmount = borrowAmountPerEpoch[msg.sender][
                hashVariables(principle, epoch)
            ];
            uint totalBorrowAmount = totalUsedTokenPerEpoch[principle][epoch];
            uint porcentageBorrow;

            require(
                borrowAmount > 0 || lentAmount > 0,
                "No borrowed or lent amount"
            );

175:        porcentageBorrow = (borrowAmount * 10000) / totalBorrowAmount;

            for (uint j = 0; j < tokensIncentives[i].length; j++) {
                address token = tokensIncentives[i][j];
                uint lentIncentive = lentIncentivesPerTokenPerEpoch[principle][
                    hashVariables(token, epoch)
                ];
                uint borrowIncentive = borrowedIncentivesPerTokenPerEpoch[
                    principle
                ][hashVariables(token, epoch)];
                require(
                    !claimedIncentives[msg.sender][
                        hashVariablesT(principle, epoch, token)
                    ],
                    "Already claimed"
                );
                require(
                    (lentIncentive > 0 && lentAmount > 0) ||
                        (borrowIncentive > 0 && borrowAmount > 0),
                    "No incentives to claim"
                );
                claimedIncentives[msg.sender][
                    hashVariablesT(principle, epoch, token)
                ] = true;

                uint amountToClaim = (lentIncentive * porcentageLent) / 10000;
                amountToClaim += (borrowIncentive * porcentageBorrow) / 10000;

                IERC20(token).transfer(msg.sender, amountToClaim);

                emit ClaimedIncentives(
                    msg.sender,
                    principle,
                    token,
                    amountToClaim,
                    epoch
                );
            }
        }
    }
```
As can be seen, since `porcentageLent` is less than `10000` in `L161`, a lender will lose incentives up to `0.01%`. The same problem exists in `L175`.

## Internal pre-conditions

## External pre-conditions

## Attack Path
1. Assume that a lender's lent percentage is `0.0499%`.
2. Since `porcentageLent` is calculated as `4` (`0.04%`) in `L161`, the lender will lose about `20%` (`(0.0499 - 0.04) / 0.0499`) incentives of his own.

## Impact
Loss of funds because lenders and borrowers lose incentives.

## PoC

## Mitigation
Replace `10000` with `1e18` as follows:
```diff
    function claimIncentives(
        address[] memory principles,
        address[][] memory tokensIncentives,
        uint epoch
    ) public {
        // get information
        require(epoch < currentEpoch(), "Epoch not finished");

        for (uint i; i < principles.length; i++) {
            address principle = principles[i];
            uint lentAmount = lentAmountPerUserPerEpoch[msg.sender][
                hashVariables(principle, epoch)
            ];
            // get the total lent amount for the epoch and principle
            uint totalLentAmount = totalUsedTokenPerEpoch[principle][epoch];

            uint porcentageLent;

            if (lentAmount > 0) {
-               porcentageLent = (lentAmount * 10000) / totalLentAmount;
+               porcentageLent = (lentAmount * 1e18) / totalLentAmount;
            }

            uint borrowAmount = borrowAmountPerEpoch[msg.sender][
                hashVariables(principle, epoch)
            ];
            uint totalBorrowAmount = totalUsedTokenPerEpoch[principle][epoch];
            uint porcentageBorrow;

            require(
                borrowAmount > 0 || lentAmount > 0,
                "No borrowed or lent amount"
            );

-           porcentageBorrow = (borrowAmount * 10000) / totalBorrowAmount;
+           porcentageBorrow = (borrowAmount * 1e18) / totalBorrowAmount;

            for (uint j = 0; j < tokensIncentives[i].length; j++) {
                address token = tokensIncentives[i][j];
                uint lentIncentive = lentIncentivesPerTokenPerEpoch[principle][
                    hashVariables(token, epoch)
                ];
                uint borrowIncentive = borrowedIncentivesPerTokenPerEpoch[
                    principle
                ][hashVariables(token, epoch)];
                require(
                    !claimedIncentives[msg.sender][
                        hashVariablesT(principle, epoch, token)
                    ],
                    "Already claimed"
                );
                require(
                    (lentIncentive > 0 && lentAmount > 0) ||
                        (borrowIncentive > 0 && borrowAmount > 0),
                    "No incentives to claim"
                );
                claimedIncentives[msg.sender][
                    hashVariablesT(principle, epoch, token)
                ] = true;

-               uint amountToClaim = (lentIncentive * porcentageLent) / 10000;
-               amountToClaim += (borrowIncentive * porcentageBorrow) / 10000;
+               uint amountToClaim = (lentIncentive * porcentageLent) / 1e18;
+               amountToClaim += (borrowIncentive * porcentageBorrow) / 1e18;

                IERC20(token).transfer(msg.sender, amountToClaim);

                emit ClaimedIncentives(
                    msg.sender,
                    principle,
                    token,
                    amountToClaim,
                    epoch
                );
            }
        }
    }
```

# [M-04] Extending loan will revert due to the unused variable.
## Summary
The `DebitaV3Loan.extendLoan()` function has a unused variable `extendedTime`. Extending loan will revert due to the unused variable.

## Root Cause
- The [DebitaV3Loan.extendLoan()](https://github.com/sherlock-audit/2024-11-debita-finance-v3/blob/main/Debita-V3-Contracts/contracts/DebitaV3Loan.sol#L547-L664) function has unused variable `extendedTime`:
```solidity
    function extendLoan() public {
        ... SKIP ...
588:            uint alreadyUsedTime = block.timestamp - m_loan.startedAt;

590:            uint extendedTime = offer.maxDeadline -
                    alreadyUsedTime -
                    block.timestamp;
        ... SKIP ...
    }
```
As can be seen, when `block.timestamp - m_loan.startedAt` is larger than `offer.maxDeadline - block.timestamp`, the function will revert.

## Internal pre-conditions
- More than half of the max deadline passed after the loan started.

## External pre-conditions

## Attack Path
1. A borrower takes out a loan with `maxDeadline = block.timestamp + 10 days`.
2. After `6 days` passed, the borrower attempts to extend the loan.
3. The `extendLoan()` function reverts in `L590`.
4. As a result, the borrower can't extend the loan.

## Impact
Borrowers can't extend their loan.

## PoC
In the attack path:
1. `alreadyUsedTime = 6 days` in `L588`.
2. `L590` will be modified as follows:
```solidity
    extendedTime = (offer.maxDeadline - block.timestamp) - alreadUsedTime;
```
Therefore, since `extendedTime = 4 days - 6 days < 0`, the function reverts.

## Mitigation
Remove the unused variable `extendedTime` as follows.
```diff
    function extendLoan() public {
        ... SKIP ...
                uint alreadyUsedTime = block.timestamp - m_loan.startedAt;

-               uint extendedTime = offer.maxDeadline -
-                   alreadyUsedTime -
-                   block.timestamp;
        ... SKIP ...
    }
```
