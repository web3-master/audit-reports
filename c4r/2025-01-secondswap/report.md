| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-attacker-can-steal-funds-from-secondswap_stepvesting) | Attacker can steal funds from `SecondSwap_StepVesting`. |
| [M-01](#m-01-partial-listing-can-be-created-with-minpurchaseamt--0) | Partial listing can be created with `minPurchaseAmt = 0`. |
| [M-02](#m-02-referral-fee-is-calculated-wrongly-when-spotpurchase) | Referral fee is calculated wrongly when `spotPurchase`. |

# [H-01] Attacker can steal funds from `SecondSwap_StepVesting`.
## Impact
An attacker can steal funds from protocol by using vulnerability in `transferVesting()` function.

## Proof of Concept
`SecondSwap_StepVesting.sol#transferVesting()` function is as follows.
```solidity
    function transferVesting(address _grantor, address _beneficiary, uint256 _amount) external {
        require(
            msg.sender == tokenIssuer || msg.sender == manager || msg.sender == vestingDeployer,
            "SS_StepVesting: unauthorized"
        );
        require(_beneficiary != address(0), "SS_StepVesting: beneficiary is zero");
        require(_amount > 0, "SS_StepVesting: amount is zero");
        Vesting storage grantorVesting = _vestings[_grantor];
        require(
            grantorVesting.totalAmount - grantorVesting.amountClaimed >= _amount,
            "SS_StepVesting: insufficient balance"
        ); // 3.8. Claimed amount not checked in transferVesting function

        grantorVesting.totalAmount -= _amount;
230     grantorVesting.releaseRate = grantorVesting.totalAmount / numOfSteps;

        _createVesting(_beneficiary, _amount, grantorVesting.stepsClaimed, true);

        emit VestingTransferred(_grantor, _beneficiary, _amount);
    }
```
L230 does not consider `amountClaimed`.   
So if `amountClaimed > 0` and `stepsClaimed > 0`, claimable amount can be more than remained amount.

By using this vulnerability, an attacker can steal funds through claim().
We can see this fact from `SecondSwap_StepVesting.sol#claimable()` function.
```solidity
    function claimable(address _beneficiary) public view returns (uint256, uint256) {
        Vesting memory vesting = _vestings[_beneficiary];
        if (vesting.totalAmount == 0) {
            return (0, 0);
        }

        uint256 currentTime = Math.min(block.timestamp, endTime);
        if (currentTime < startTime) {
            return (0, 0);
        }

        uint256 elapsedTime = currentTime - startTime;
        uint256 currentStep = elapsedTime / stepDuration;
        uint256 claimableSteps = currentStep - vesting.stepsClaimed;

        uint256 claimableAmount;

        if (vesting.stepsClaimed + claimableSteps >= numOfSteps) {
            //[BUG FIX] user can buy more than they are allocated
            claimableAmount = vesting.totalAmount - vesting.amountClaimed;
            return (claimableAmount, claimableSteps);
        }

@>      claimableAmount = vesting.releaseRate * claimableSteps;
        return (claimableAmount, claimableSteps);
    }
```

## Lines of code
https://github.com/code-423n4/2024-12-secondswap/blob/main/contracts/SecondSwap_StepVesting.sol#L230

## Tool used
Manual Review

## Recommended Mitigation Steps
`SecondSwap_StepVesting.sol#transferVesting()` function has to be modified as follows.
```solidity
    function transferVesting(address _grantor, address _beneficiary, uint256 _amount) external {
        require(
            msg.sender == tokenIssuer || msg.sender == manager || msg.sender == vestingDeployer,
            "SS_StepVesting: unauthorized"
        );
        require(_beneficiary != address(0), "SS_StepVesting: beneficiary is zero");
        require(_amount > 0, "SS_StepVesting: amount is zero");
        Vesting storage grantorVesting = _vestings[_grantor];
        require(
            grantorVesting.totalAmount - grantorVesting.amountClaimed >= _amount,
            "SS_StepVesting: insufficient balance"
        ); // 3.8. Claimed amount not checked in transferVesting function

        grantorVesting.totalAmount -= _amount;
--      grantorVesting.releaseRate = grantorVesting.totalAmount / numOfSteps;
++      grantorVesting.releaseRate = (grantorVesting.totalAmount - grantorVesting.amountClaimed) / (numOfSteps - grantorVesting.stepsClaimed);

        _createVesting(_beneficiary, _amount, grantorVesting.stepsClaimed, true);

        emit VestingTransferred(_grantor, _beneficiary, _amount);
    }
```


# [M-01] Partial listing can be created with `minPurchaseAmt = 0`.
## Impact
Minimum purchase amount check is wrong, so desired protocol logic can be broken.

## Proof of Concept
`SecondSwap_Marketplace.sol#listVesting()` function is as follows.
```solidity
    function listVesting(
        address _vestingPlan,
        uint256 _amount,
        uint256 _price,
        uint256 _discountPct,
        ListingType _listingType,
        DiscountType _discountType,
        uint256 _maxWhitelist,
        address _currency,
        uint256 _minPurchaseAmt,
        bool _isPrivate
    ) external isFreeze {
        require(
253         _listingType != ListingType.SINGLE || (_minPurchaseAmt > 0 && _minPurchaseAmt <= _amount),
            "SS_Marketplace: Minimum Purchase Amount cannot be more than listing amount"
        );

        ...

        listings[_vestingPlan][listingId] = Listing({
            seller: msg.sender,
            total: _amount,
            balance: _amount,
            pricePerUnit: _price,
            listingType: _listingType,
            discountType: _discountType,
            discountPct: _discountPct,
            listTime: block.timestamp,
            whitelist: whitelistAddress,
            currency: _currency,
            minPurchaseAmt: _minPurchaseAmt,
            status: Status.LIST,
            vestingPlan: _vestingPlan
        });
        emit Listed(_vestingPlan, listingId);
    }
```
As we can see on L253, In case of `_listingType == ListingType.PARTIAL` L253 is not reverted.   
So _minPurchaseAmt can be zero.   

On the other hand, `SecondSwap_Marketplace.sol#_validatePurchase()` function is as follows.
```solidty
    function _validatePurchase(Listing storage listing, uint256 _amount, address _referral) private view {
        ...
        require(
395         listing.listingType == ListingType.SINGLE ||
396             (_amount >= listing.minPurchaseAmt || _amount == listing.balance),
            "SS_Marketplace: Invalid Purchase amount"
        );
        require(
            listing.listingType != ListingType.SINGLE || _amount == listing.total,
            "SS_Marketplace: Invalid amount"
        );
        require(_amount <= listing.balance, "SS_Marketplace: Insufficient");
    }
```
From L395~396, `listing.minPurchaseAmt` means minimum amount of purchase in partial listing.   
In case of single listing, minimum amount does not interact.   

From these facts, we can see `L253` is wrong.

## Lines of code
https://github.com/code-423n4/2024-12-secondswap/blob/main/contracts/SecondSwap_Marketplace.sol#L253

## Tool used
Manual Review

## Recommended Mitigation Steps
`SecondSwap_Marketplace.sol#listVesting()` function has to be modifed as follows.
```solidity
    function listVesting(
        address _vestingPlan,
        uint256 _amount,
        uint256 _price,
        uint256 _discountPct,
        ListingType _listingType,
        DiscountType _discountType,
        uint256 _maxWhitelist,
        address _currency,
        uint256 _minPurchaseAmt,
        bool _isPrivate
    ) external isFreeze {
        require(
--          _listingType != ListingType.SINGLE || (_minPurchaseAmt > 0 && _minPurchaseAmt <= _amount),
++          _listingType == ListingType.SINGLE || (_minPurchaseAmt > 0 && _minPurchaseAmt <= _amount),
            "SS_Marketplace: Minimum Purchase Amount cannot be more than listing amount"
        );

        ...
    }
```

# [M-02] Referral fee is calculated wrongly when `spotPurchase`.
## Impact
`referralReward` of `Purchased` event is recored wrongly, so the protocol can suffer.

## Proof of Concept
`SecondSwap_Marketplace.sol#Purchased` event is as follows.
```solidity
    /**
     * @notice Emitted when a purchase is completed
     * @param vestingPlan Address of the vesting plan contract
     * @param listingId Unique identifier of the listing
     * @param buyer Address of the buyer
     * @param amount Amount of tokens purchased
     * @param referral Address of the referrer
     * @param buyerFee Amount of fees paid by buyer
     * @param sellerFee Amount of fees paid by seller
@>   * @param referralReward Amount of reward paid to referrer
     */
    event Purchased(
        address indexed vestingPlan,
        uint256 indexed listingId,
        address buyer,
        uint256 amount,
        address referral,
        uint256 buyerFee,
        uint256 sellerFee,
@>      uint256 referralReward
    );
```
As we can see, referralReward is the amount of reward paid to referrer.

On the other hand, `SecondSwap_MarketplaceSetting.sol#referralFee` variable is as follows.
```solidity
    /**
     * @notice Percentage of fees allocated to referrals (in basis points)
     */
    uint256 public referralFee;
```
From `doc`,  `MarketplaceSetting.sol#referralFee` means percentage of fees allocated to referrals.

But `SecondSwap_Marketplace.sol#_handleTransfers()` function is as follows.
```solidity
    function _handleTransfers(
        Listing storage listing,
        uint256 _amount,
        uint256 discountedPrice,
        uint256 bfee,
        uint256 sfee,
        address _referral
    ) private returns (uint256 buyerFeeTotal, uint256 sellerFeeTotal, uint256 referralFeeCost) {
        ...

        buyerFeeTotal = (baseAmount * bfee) / BASE;
        sellerFeeTotal = (baseAmount * sfee) / BASE;

        ...

        referralFeeCost = 0;
        if (_referral != address(0) && listing.whitelist == address(0)) {
479         referralFeeCost =
480             buyerFeeTotal -
                (baseAmount * bfee * IMarketplaceSetting(marketplaceSetting).referralFee()) /
483             (BASE * BASE);
        }

        ...
    }
```
As you can see above, `referralFeeCost` is calculated with `buyerFeeTotal` substracted by the amount allocated to referral.

And `SecondSwap_Marketplace.sol#spotPurchase()` function is as follows.
```solidity
    function spotPurchase(
        address _vestingPlan,
        uint256 _listingId,
        uint256 _amount,
        address _referral
    ) external isFreeze {
        ...

        // Process all transfers
        (uint256 buyerFeeTotal, uint256 sellerFeeTotal, uint256 referralFeeCost) = _handleTransfers(
            listing,
            _amount,
            discountedPrice,
            bfee,
            sfee,
            _referral
        );

        ...

        // Emit purchase event
        emit Purchased(
            _vestingPlan,
            _listingId,
            msg.sender,
            _amount,
            _referral,
            buyerFeeTotal,
            sellerFeeTotal,
@>          referralFeeCost
        );
    }
```

As we can see, `referralReward` of `Purchased` event is recored wrongly.

## Lines of code
https://github.com/code-423n4/2024-12-secondswap/blob/main/contracts/SecondSwap_Marketplace.sol#L481

## Tool used
Manual Review

## Recommended Mitigation Steps
`SecondSwap_Marketplace.sol#_handleTransfers()` function has to be modifed as follows.
```solidity
    function _handleTransfers(
        Listing storage listing,
        uint256 _amount,
        uint256 discountedPrice,
        uint256 bfee,
        uint256 sfee,
        address _referral
    ) private returns (uint256 buyerFeeTotal, uint256 sellerFeeTotal, uint256 referralFeeCost) {
        ...

        buyerFeeTotal = (baseAmount * bfee) / BASE;
        sellerFeeTotal = (baseAmount * sfee) / BASE;

        ...

        referralFeeCost = 0;
        if (_referral != address(0) && listing.whitelist == address(0)) {
            referralFeeCost =
--              buyerFeeTotal -
                (baseAmount * bfee * IMarketplaceSetting(marketplaceSetting).referralFee()) /
                (BASE * BASE);
        }

        ...
    }
```