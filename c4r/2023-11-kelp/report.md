| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-miscalculation-of-rsethamounttomint-when-a-user-deposits-asset) | Miscalculation of rsethAmountToMint when a user deposits asset. |
| [M-01](#m-01-lrtconfigsolupdateassetstrategy-function-may-cause-the-protocol-lose-funds-and-the-value-of-rseth-may-fall-down) | LRTConfig.sol#updateAssetStrategy function may cause the protocol lose funds and the value of rsETH may fall down. |


# [H-01] Miscalculation of rsethAmountToMint when a user deposits asset.
## Impact
When a user deposits asset with LRTDepositPool.sol#depositAsset function, the minted amount of rsETHToken to the user is miscalculated. So the user loses funds. And when a user deposits asset, rsETHPrice becomes bigger and bigger.

## Proof of Concept
LRTDepositPool.sol#depositAsset is as follows.
```solidity
File: LRTDepositPool.sol
119:     function depositAsset(
120:         address asset,
121:         uint256 depositAmount
122:     )
123:         external
124:         whenNotPaused
125:         nonReentrant
126:         onlySupportedAsset(asset)
127:     {
128:         // checks
129:         if (depositAmount == 0) {
130:             revert InvalidAmount();
131:         }
132:         if (depositAmount > getAssetCurrentLimit(asset)) {
133:             revert MaximumDepositLimitReached();
134:         }
135: 
136:         if (!IERC20(asset).transferFrom(msg.sender, address(this), depositAmount)) {
137:             revert TokenTransferFailed();
138:         }
139: 
140:         // interactions
141:         uint256 rsethAmountMinted = _mintRsETH(asset, depositAmount);
142: 
143:         emit AssetDeposit(asset, depositAmount, rsethAmountMinted);
144:     }
```
As we can see above, L136 transfers asset token from msg.sender first and then L141 mints rsETHToken to the user.
_mintRsETH function is as follows.
```solidity
File: LRTDepositPool.sol
151:     function _mintRsETH(address _asset, uint256 _amount) private returns (uint256 rsethAmountToMint) {
152:         (rsethAmountToMint) = getRsETHAmountToMint(_asset, _amount);
153: 
154:         address rsethToken = lrtConfig.rsETH();
155:         // mint rseth for user
156:         IRSETH(rsethToken).mint(msg.sender, rsethAmountToMint);
157:     }
```
L152 calculates the amount of rsETHToken to mint.
getRsETHAmountToMint function is as follows.
```solidity
File: LRTDepositPool.sol
095:     function getRsETHAmountToMint(
096:         address asset,
097:         uint256 amount
098:     )
099:         public
100:         view
101:         override
102:         returns (uint256 rsethAmountToMint)
103:     {
104:         // setup oracle contract
105:         address lrtOracleAddress = lrtConfig.getContract(LRTConstants.LRT_ORACLE);
106:         ILRTOracle lrtOracle = ILRTOracle(lrtOracleAddress);
107: 
108:         // calculate rseth amount to mint based on asset amount and asset exchange rate
109:         rsethAmountToMint = (amount * lrtOracle.getAssetPrice(asset)) / lrtOracle.getRSETHPrice();
110:     }
```
L109 calculates rsETHPrice through lrtOracle.getRSETHPrice().
lrtOracle.getRSETHPrice() is as follows.
```solidity
File: LRTOracle.sol
52:     function getRSETHPrice() external view returns (uint256 rsETHPrice) {
53:         address rsETHTokenAddress = lrtConfig.rsETH();
54:         uint256 rsEthSupply = IRSETH(rsETHTokenAddress).totalSupply();
55: 
56:         if (rsEthSupply == 0) {
57:             return 1 ether;
58:         }
59: 
60:         uint256 totalETHInPool;
61:         address lrtDepositPoolAddr = lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL);
62: 
63:         address[] memory supportedAssets = lrtConfig.getSupportedAssetList();
64:         uint256 supportedAssetCount = supportedAssets.length;
65: 
66:         for (uint16 asset_idx; asset_idx < supportedAssetCount;) {
67:             address asset = supportedAssets[asset_idx];
68:             uint256 assetER = getAssetPrice(asset);
69: 
70:             uint256 totalAssetAmt = ILRTDepositPool(lrtDepositPoolAddr).getTotalAssetDeposits(asset);
71:             totalETHInPool += totalAssetAmt * assetER;
72: 
73:             unchecked {
74:                 ++asset_idx;
75:             }
76:         }
77: 
78:         return totalETHInPool / rsEthSupply;
79:     }
```
As we can see above, rsETHPrice equals to the eth amount of total supported assets divided by total supply of rsETHToken. Therefore, this means eth price about a unit amount of rsETHToken.

But in LRTDepositPool.sol#depositAsset function, first transfered asset token from msg.sender and then calculated rsETHPrice. So the rsETHPrice at this time, is bigger than real.
Threfore, the amount of rsETHToken to mint is smaller than real.

## Lines of code
https://github.com/code-423n4/2023-11-kelp/blob/main/src/LRTDepositPool.sol#L136

## Tool used
Manual Review

## Recommended Mitigation Steps
LRTDepositPool.sol#depositAsset function has to be modified as follows.
```solidity
    function depositAsset(
        address asset,
        uint256 depositAmount
    )
        external
        whenNotPaused
        nonReentrant
        onlySupportedAsset(asset)
    {
        // checks
        if (depositAmount == 0) {
            revert InvalidAmount();
        }
        if (depositAmount > getAssetCurrentLimit(asset)) {
            revert MaximumDepositLimitReached();
        }

-       if (!IERC20(asset).transferFrom(msg.sender, address(this), depositAmount)) {
-           revert TokenTransferFailed();
-       }

        // interactions
        uint256 rsethAmountMinted = _mintRsETH(asset, depositAmount);

+       if (!IERC20(asset).transferFrom(msg.sender, address(this), depositAmount)) {
+           revert TokenTransferFailed();
+       }

        emit AssetDeposit(asset, depositAmount, rsethAmountMinted);
    }
```

# [M-01] LRTConfig.sol#updateAssetStrategy function may cause the protocol lose funds and the value of rsETH may fall down.
## Impact
When the manager update the strategy for an asset, the protocol may lose funds deposited already to the previous strategy.
At the same time, the price of rsETH may fall down.

## Proof of Concept
LRTConfig.sol#updateAssetStrategy function is as follows.
```solidity
File: LRTConfig.sol
109:    function updateAssetStrategy(
110:        address asset,
111:        address strategy
112:    )
113:        external
114:        onlyRole(DEFAULT_ADMIN_ROLE)
115:        onlySupportedAsset(asset)
116:    {
117:        UtilLib.checkNonZeroAddress(strategy);
118:        if (assetStrategy[asset] == strategy) {
119:            revert ValueAlreadyInUse();
120:        }
126:        assetStrategy[asset] = strategy;
127:    }
```
That is, the above function does not check the existence of funds already deposited to the old strategy in the case that the assetStrategy[asset] !== address(0).
Thus, the protocol may not refund assets from the old strategy.
The price of rsETH is determined in the LRTOracle.sol#getRSETHPrice function by the ratio of the total price of assets to the totalSupply() of rsETH.
Therefore, the value of rsETH may fall, depending on the amount of funds deposited to the old strategy.

The example is as follows.

The user A deposits 100eth of asset1 to LRTDepositPool and receive 100eth of rsETH, the user B deposits 100eth of asset2 and receive 100eth of rsETH.
The manager calls updateAssetStrategy and set assetStrategy[asset1] = strategy1.
The manager deposits all of asset1 to strategy1 through NodeDelegator. At this time, the price of rsETH will be getRSETHPrice() == 1 ether.
The manager calls updateAssetStrategy and update to assetStrategy[asset1] = strategy2 and the protocol lose 100eth of asset1.
The price of rsETH will fall down to getRSETHPrice() == 0.5 ether. Thus, at this time, if user C deposits 100eth of asset1 to the deposit pool, he will receive 200eth of rsETH.

## Lines of code
https://github.com/code-423n4/2023-11-kelp/blob/main/src/LRTConfig.sol#L121

## Tool used
Manual Review

## Recommended Mitigation Steps
Modify LRTConfig.sol#updateAssetStrategy function to check the existence of funds deposited.
At first, add the followin function to LRTDepositPool.sol.
```solidity
File: interfaces/ILRTDepositPool.sol
21: +    function getTotalAssetStaked(address asset) external view returns (uint256);
File: LRTDepositPool.sol
91: +    function getTotalAssetStaked(address asset)
92: +        external
93: +        view
94: +        onlySupportedAsset(asset)
95: +        returns (uint256 amount)
96: +    {
97: +        uint256 ndcsCount = nodeDelegatorQueue.length;
98: +        for (uint256 i; i < ndcsCount;) {
99: +            amount += INodeDelegator(nodeDelegatorQueue[i]).getAssetBalance(asset);
100: +            unchecked {
101: +                ++i;
102: +            }
103: +        }
104: +    }
```
Next, add the following check to LRTConfig.sol#updateAssetStrategy function.
```solidity
File: LRTConfig.sol
109:    function updateAssetStrategy(
110:        address asset,
111:        address strategy
112:    )
113:        external
114:        onlyRole(DEFAULT_ADMIN_ROLE)
115:        onlySupportedAsset(asset)
116:    {
117:        UtilLib.checkNonZeroAddress(strategy);
118:        if (assetStrategy[asset] == strategy) {
119:            revert ValueAlreadyInUse();
120:        }
121: +      if (assetStrategy[asset] !== address(0)) {
122: +          address depositPoolAddress = getContract(LRTConstants.LRT_DEPOSIT_POOL);
123: +          require(ILRTDepositPool(depositPoolAddress).getTotalAssetStaked() == 0, 'Please, refund staked assets first');
124: +      }
125:        assetStrategy[asset] = strategy;
126:    }
```