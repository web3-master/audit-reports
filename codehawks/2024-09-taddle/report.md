| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-attacker-can-drain-capitalpool) | Attacker can drain `CapitalPool`. |
| [H-02](#h-02-tokens-cant-be-withdrawn-from-capitalpool) | Tokens can't be withdrawn from `CapitalPool`. |
| [H-03](#h-03-referrer-cant-receive-referrerreferralbonus-from-others) | Referrer can't receive `referrerReferralBonus` from others. |
| [H-04](#h-04-attacker-can-drain-the-capital-pool) | Attacker can drain the capital pool. |


# [H-01] Attacker can drain `CapitalPool`.
## Summary
`PreMarkets.sol#listOffer` function uses mistakenly `offerInfo.collateralRate` instead of `_collateralRate` to calculate `transferAmount` in the `Protected` mode.
This vulnerability causes the protocol insolvency.

## Vulnerability Detail
`PreMarkets.sol#listOffer` function is the following.
```solidity
    function listOffer(
        address _stock,
        uint256 _amount,
        uint256 _collateralRate
    ) external payable {
        if (_amount == 0x0) {
            revert Errors.AmountIsZero();
        }

        if (_collateralRate < Constants.COLLATERAL_RATE_DECIMAL_SCALER) {
            revert InvalidCollateralRate();
        }

        StockInfo storage stockInfo = stockInfoMap[_stock];
        if (_msgSender() != stockInfo.authority) {
            revert Errors.Unauthorized();
        }

        OfferInfo storage offerInfo = offerInfoMap[stockInfo.preOffer];
        MakerInfo storage makerInfo = makerInfoMap[offerInfo.maker];

        /// @dev market place must be online
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();
        MarketPlaceInfo memory marketPlaceInfo = systemConfig
            .getMarketPlaceInfo(makerInfo.marketPlace);

        marketPlaceInfo.checkMarketPlaceStatus(
            block.timestamp,
            MarketPlaceStatus.Online
        );

        if (stockInfo.offer != address(0x0)) {
            revert OfferAlreadyExist();
        }

        if (stockInfo.stockType != StockType.Bid) {
            revert InvalidStockType(StockType.Bid, stockInfo.stockType);
        }

        /// @dev change abort offer status when offer settle type is turbo
        if (makerInfo.offerSettleType == OfferSettleType.Turbo) {
            address originOffer = makerInfo.originOffer;
            OfferInfo memory originOfferInfo = offerInfoMap[originOffer];

            if (_collateralRate != originOfferInfo.collateralRate) {
                revert InvalidCollateralRate();
            }
            originOfferInfo.abortOfferStatus = AbortOfferStatus.SubOfferListed;
        }

        /// @dev transfer collateral when offer settle type is protected
        if (makerInfo.offerSettleType == OfferSettleType.Protected) {
            uint256 transferAmount = OfferLibraries.getDepositAmount(
                offerInfo.offerType,
349:            offerInfo.collateralRate,
                _amount,
                true,
                Math.Rounding.Ceil
            );

            ITokenManager tokenManager = tadleFactory.getTokenManager();
            tokenManager.tillIn{value: msg.value}(
                _msgSender(),
                makerInfo.tokenAddress,
                transferAmount,
                false
            );
        }

        address offerAddr = GenerateAddress.generateOfferAddress(stockInfo.id);
        if (offerInfoMap[offerAddr].authority != address(0x0)) {
            revert OfferAlreadyExist();
        }

        /// @dev update offer info
        offerInfoMap[offerAddr] = OfferInfo({
            id: stockInfo.id,
            authority: _msgSender(),
            maker: offerInfo.maker,
            offerStatus: OfferStatus.Virgin,
            offerType: offerInfo.offerType,
            abortOfferStatus: AbortOfferStatus.Initialized,
            points: stockInfo.points,
            amount: _amount,
379:        collateralRate: _collateralRate,
            usedPoints: 0,
            tradeTax: 0,
            settledPoints: 0,
            settledPointTokenAmount: 0,
            settledCollateralAmount: 0
        });

        stockInfo.offer = offerAddr;

        emit ListOffer(
            offerAddr,
            _stock,
            _msgSender(),
            stockInfo.points,
            _amount
        );
    }
```
As can be seen in `349`, in `Protected` mode, the function uses `offer.collateralRate` to calculate the collateral amount which will be transferred to the `CapitalPool`
However, the function records the collateral rate of the listed offer as `_collateralRate` in `L379`.
Therefore, when settle the listed offer, protocol refund the collateral amount based on `_collateralRate`.
If attacker set `_collateralRate` bigger than `offer.collateralRate`, he can drain the protocol as much as he/she want.

## Impact
Using this vulnerability, attacker can drain `CapitalPool`.
This can cause the protocol insolvency.

## Code Snippet
- [src/core/PreMarkets.sol#L349](https://github.com/Cyfrin/2024-08-tadle/tree/main/src/core/PreMarkets.sol#L349)

## Tool used
Manual Review

## Recommendation
Modify `PreMarkets.sol#listOffer` function as follows.
```solidity
    function listOffer(
        address _stock,
        uint256 _amount,
        uint256 _collateralRate
    ) external payable {
        --- SKIP ---

        /// @dev transfer collateral when offer settle type is protected
        if (makerInfo.offerSettleType == OfferSettleType.Protected) {
            uint256 transferAmount = OfferLibraries.getDepositAmount(
                offerInfo.offerType,
--              offerInfo.collateralRate,
++              _collateralRate,
                _amount,
                true,
                Math.Rounding.Ceil
            );

            ITokenManager tokenManager = tadleFactory.getTokenManager();
            tokenManager.tillIn{value: msg.value}(
                _msgSender(),
                makerInfo.tokenAddress,
                transferAmount,
                false
            );
        }

        --- SKIP ---
    }
```

# [H-02] Tokens can't be withdrawn from `CapitalPool`.
## Summary
`TokenManager.sol#_transfer` function has error on approving tokens on `CapitalPool`.
Therefore, tokens can't be withdrawn from `CapitalPool`.

## Vulnerability Detail
`TokenManager.sol#_transfer` function is the following.
```solidity
    function _transfer(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        address _capitalPoolAddr
    ) internal {
        uint256 fromBalanceBef = IERC20(_token).balanceOf(_from);
        uint256 toBalanceBef = IERC20(_token).balanceOf(_to);

        if (
            _from == _capitalPoolAddr &&
            IERC20(_token).allowance(_from, address(this)) == 0x0
        ) {
247:        ICapitalPool(_capitalPoolAddr).approve(address(this));
        }

        _safe_transfer_from(_token, _from, _to, _amount);

        uint256 fromBalanceAft = IERC20(_token).balanceOf(_from);
        uint256 toBalanceAft = IERC20(_token).balanceOf(_to);

        if (fromBalanceAft != fromBalanceBef - _amount) {
            revert TransferFailed();
        }

        if (toBalanceAft != toBalanceBef + _amount) {
            revert TransferFailed();
        }
    }
```
The function calls the following `CapitalPool.sol#approve` function with `address(this)` as `tokenaAddr` parameter in `L247`.
```solidity
    function approve(address tokenAddr) external {
        address tokenManager = tadleFactory.relatedContracts(
            RelatedContractLibraries.TOKEN_MANAGER
        );
28:     (bool success, ) = tokenAddr.call(
            abi.encodeWithSelector(
                APPROVE_SELECTOR,
                tokenManager,
                type(uint256).max
            )
        );

        if (!success) {
            revert ApproveFailed();
        }
    }
```
As can be seen, the function call will be reverted in `L28`.

## Impact
Tokens can't be withdrawn from `CapitalPool`.

## Code Snippet
- [src/core/TokenManager.sol#L247](https://github.com/Cyfrin/2024-08-tadle/tree/main/src/core/TokenManager.sol#L247)

## Tool used
Manual Review

## Recommendation
Modify `TokenManager.sol#_transfer` function as follows.
```solidity
    function _transfer(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        address _capitalPoolAddr
    ) internal {
        uint256 fromBalanceBef = IERC20(_token).balanceOf(_from);
        uint256 toBalanceBef = IERC20(_token).balanceOf(_to);

        if (
            _from == _capitalPoolAddr &&
            IERC20(_token).allowance(_from, address(this)) == 0x0
        ) {
--          ICapitalPool(_capitalPoolAddr).approve(_address(this));
++          ICapitalPool(_capitalPoolAddr).approve(_token);
        }

        _safe_transfer_from(_token, _from, _to, _amount);

        uint256 fromBalanceAft = IERC20(_token).balanceOf(_from);
        uint256 toBalanceAft = IERC20(_token).balanceOf(_to);

        if (fromBalanceAft != fromBalanceBef - _amount) {
            revert TransferFailed();
        }

        if (toBalanceAft != toBalanceBef + _amount) {
            revert TransferFailed();
        }
    }
```

# [H-03] Referrer can't receive `referrerReferralBonus` from others.
## Summary
`SystemConfig.sol#updateReferrerInfo` function set `referrerInfo` for `referrer` instead of `msg.sender`.
Therefore, referrer can't receive `referrerReferralBonus` from others who signed up using referrer's referral link.

## Vulnerability Detail
`SystemConfig.sol#updateReferrerInfo` function is the following.
```solidity
    function updateReferrerInfo(
        address _referrer,
        uint256 _referrerRate,
        uint256 _authorityRate
    ) external {
        if (_msgSender() == _referrer) {
            revert InvalidReferrer(_referrer);
        }

        if (_referrer == address(0x0)) {
            revert Errors.ZeroAddress();
        }

        if (_referrerRate < baseReferralRate) {
            revert InvalidReferrerRate(_referrerRate);
        }

        uint256 referralExtraRate = referralExtraRateMap[_referrer];
        uint256 totalRate = baseReferralRate + referralExtraRate;

        if (totalRate > Constants.REFERRAL_RATE_DECIMAL_SCALER) {
            revert InvalidTotalRate(totalRate);
        }

        if (_referrerRate + _authorityRate != totalRate) {
            revert InvalidRate(_referrerRate, _authorityRate, totalRate);
        }

69:     ReferralInfo storage referralInfo = referralInfoMap[_referrer];
        referralInfo.referrer = _referrer;
        referralInfo.referrerRate = _referrerRate;
        referralInfo.authorityRate = _authorityRate;

        emit UpdateReferrerInfo(
            msg.sender,
            _referrer,
            _referrerRate,
            _authorityRate
        );
    }
```
As can be seen, the function set `referralInfo` for `referrer` instead of `msg.sender`.
Therefore, referrer can't receive `referrerReferralBonus` from `msg.sender`.

In more detail, `PreMarket.sol#createTaker` function is the following.
```solidity
    function createTaker(address _offer, uint256 _points) external payable {
        --- SKIP ---

199:    ReferralInfo memory referralInfo = systemConfig.getReferralInfo(
            _msgSender()
        );

        --- SKIP ---

        offerId = offerId + 1;
254:    uint256 remainingPlatformFee = _updateReferralBonus(
            platformFee,
            depositAmount,
            stockAddr,
            makerInfo,
            referralInfo,
            tokenManager
        );

        --- SKIP ---
    }
```
Where `SystemConfig.sol#getReferralInfo` is the following.
```solidity
    function getReferralInfo(
        address _referrer
    ) external view returns (ReferralInfo memory) {
        return referralInfoMap[_referrer];
    }
```
Therefore, the `_msgSender() == referralInfo.referrer` always holds true in `L199` and the `PreMarket.sol#_updateReferralBonus` function will give the `referrerReferralBonus` to the `msg.sender` instead of `referrer` in `L870`.
```solidity
    function _updateReferralBonus(
        uint256 platformFee,
        uint256 depositAmount,
        address stockAddr,
        MakerInfo storage makerInfo,
        ReferralInfo memory referralInfo,
        ITokenManager tokenManager
    ) internal returns (uint256 remainingPlatformFee) {
        if (referralInfo.referrer == address(0x0)) {
            remainingPlatformFee = platformFee;
        } else {
            /**
             * @dev calculate referrer referral bonus and authority referral bonus
             * @dev calculate remaining platform fee
             * @dev remaining platform fee = platform fee - referrer referral bonus - authority referral bonus
             * @dev referrer referral bonus = platform fee * referrer rate
             * @dev authority referral bonus = platform fee * authority rate
             * @dev emit ReferralBonus
             */
            uint256 referrerReferralBonus = platformFee.mulDiv(
                referralInfo.referrerRate,
                Constants.REFERRAL_RATE_DECIMAL_SCALER,
                Math.Rounding.Floor
            );

            /**
             * @dev update referrer referral bonus
             * @dev update authority referral bonus
             */
            tokenManager.addTokenBalance(
                TokenBalanceType.ReferralBonus,
870:            referralInfo.referrer,
                makerInfo.tokenAddress,
                referrerReferralBonus
            );

            --- SKIP ---
        }
    }
```

## Impact
Referrer can't receive `referrerReferralBonus` from others who signed up using referrer's referral link.
In other words, referrer can only receive `referrerReferralBonus` from the referrer himself.
This make the referral program useless.

## Code Snippet
- [src/core/SystemConfig.sol#L69](https://github.com/Cyfrin/2024-08-tadle/tree/main/src/core/SystemConfig.sol#L69)

## Tool used
Manual Review

## Recommendation
Modify `SystemConfig.sol#updateReferrerInfo` function as follows.
```solidity
    function updateReferrerInfo(
        address _referrer,
        uint256 _referrerRate,
        uint256 _authorityRate
    ) external {
        --- SKIP ---

--      ReferralInfo storage referralInfo = referralInfoMap[_referrer];
++      ReferralInfo storage referralInfo = referralInfoMap[_msgSender()];
        referralInfo.referrer = _referrer;
        referralInfo.referrerRate = _referrerRate;
        referralInfo.authorityRate = _authorityRate;

        --- SKIP ---
    }
```

# [H-04] Attacker can drain the capital pool.
## Summary
`TokenManager.sol#withdraw` function doesn't decrease `userTokenBalanceMap` state variable at all.
Exploiting this vulnerability, attacker can calls `TokenManager.sol#withdraw` function multiple times until the capital pool drains empty.

## Vulnerability Detail
`TokenManager.sol#withdraw` function is the following.
```solidity
    function withdraw(
        address _tokenAddress,
        TokenBalanceType _tokenBalanceType
    ) external whenNotPaused {
        uint256 claimAbleAmount = userTokenBalanceMap[_msgSender()][
            _tokenAddress
        ][_tokenBalanceType];

        if (claimAbleAmount == 0) {
            return;
        }

        address capitalPoolAddr = tadleFactory.relatedContracts(
            RelatedContractLibraries.CAPITAL_POOL
        );

        if (_tokenAddress == wrappedNativeToken) {
            /**
             * @dev token is native token
             * @dev transfer from capital pool to msg sender
             * @dev withdraw native token to token manager contract
             * @dev transfer native token to msg sender
             */
            _transfer(
                wrappedNativeToken,
                capitalPoolAddr,
                address(this),
                claimAbleAmount,
                capitalPoolAddr
            );

            IWrappedNativeToken(wrappedNativeToken).withdraw(claimAbleAmount);
            payable(msg.sender).transfer(claimAbleAmount);
        } else {
            /**
             * @dev token is ERC20 token
             * @dev transfer from capital pool to msg sender
             */
            _safe_transfer_from(
                _tokenAddress,
                capitalPoolAddr,
                _msgSender(),
                claimAbleAmount
            );
        }

        emit Withdraw(
            _msgSender(),
            _tokenAddress,
            _tokenBalanceType,
            claimAbleAmount
        );
    }
```
As can be seen, the above function doesn't decrease `userTokenBalanceMap` state variable at all.
Therefore, attacker can calls `TokenManager.sol#withdraw` function multiple times until the capital pool drains empty.

## Impact
Attacker can drain the capital pool empty.

## Code Snippet
- [src/core/TokenManager.sol#L137-L189](https://github.com/Cyfrin/2024-08-tadle/tree/main/src/core/TokenManager.sol#L137-L189)

## Tool used
Manual Review

## Recommendation
Modify `TokenManager.sol#withdraw` function as follows.
```solidity
    function withdraw(
        address _tokenAddress,
        TokenBalanceType _tokenBalanceType
    ) external whenNotPaused {
        uint256 claimAbleAmount = userTokenBalanceMap[_msgSender()][
            _tokenAddress
        ][_tokenBalanceType];

        if (claimAbleAmount == 0) {
            return;
        }
++      userTokenBalanceMap[_msgSender()][_tokenAddress][_tokenBalanceType] = 0;

        --- SKIP ---
    }
```