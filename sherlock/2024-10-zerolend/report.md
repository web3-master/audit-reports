| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-the-protocol-considers-shares-as-amount-when-liquidation) | The protocol considers shares as amount when liquidation. |
| [H-02](#h-02-wrong-calculation-of-supply-balance-and-debt-balance-when-withdraw-and-repay) | Wrong calculation of supply balance and debt balance when withdraw and repay. |
| [M-01](#m-01-the-protocol-updates-interest-rates-of-collateral-wrongly-when-liquidation) | The protocol updates interest rates of collateral wrongly when liquidation. |
| [M-02](#m-02-allocator-will-not-be-able-to-withdraw-all-assets-from-pool) | Allocator will not be able to withdraw all assets from pool. |
| [M-03](#m-03-partial-repayment-is-reverted-because-of-rounding-error) | Partial repayment is reverted because of rounding error. |


# [H-01] The protocol considers shares as amount when liquidation.
## Summary
Liquidation process used shares as amount. 

## Vulnerability Detail
`LiquidationLogic.sol#executeLiquidationCall()` function which is called when liquidation is as follows.
```solidity
  function executeLiquidationCall(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances,
    mapping(address => DataTypes.ReserveSupplies) storage totalSupplies,
    mapping(bytes32 => DataTypes.UserConfigurationMap) storage usersConfig,
    DataTypes.ExecuteLiquidationCallParams memory params
  ) external {
    LiquidationCallLocalVars memory vars;

    DataTypes.ReserveData storage collateralReserve = reservesData[params.collateralAsset];
    DataTypes.ReserveData storage debtReserve = reservesData[params.debtAsset];
    DataTypes.UserConfigurationMap storage userConfig = usersConfig[params.position];
    vars.debtReserveCache = debtReserve.cache(totalSupplies[params.debtAsset]);
    debtReserve.updateState(params.reserveFactor, vars.debtReserveCache);

    (,,,, vars.healthFactor,) = GenericLogic.calculateUserAccountData(
      balances,
      reservesData,
      reservesList,
      DataTypes.CalculateUserAccountDataParams({userConfig: userConfig, position: params.position, pool: params.pool})
    );

117 (vars.userDebt, vars.actualDebtToLiquidate) = _calculateDebt(
      // vars.debtReserveCache,
      params,
      vars.healthFactor,
      balances
    );

    ...

    (vars.collateralPriceSource, vars.debtPriceSource, vars.liquidationBonus) = _getConfigurationData(collateralReserve, params);

136 vars.userCollateralBalance = balances[params.collateralAsset][params.position].supplyShares;

138 (vars.actualCollateralToLiquidate, vars.actualDebtToLiquidate, vars.liquidationProtocolFeeAmount) =
    _calculateAvailableCollateralToLiquidate(
      collateralReserve,
      vars.debtReserveCache,
      vars.actualDebtToLiquidate,
      vars.userCollateralBalance,
      vars.liquidationBonus,
      IPool(params.pool).getAssetPrice(params.collateralAsset),
      IPool(params.pool).getAssetPrice(params.debtAsset),
      IPool(params.pool).factory().liquidationProtocolFeePercentage()
    );

    ...

    // Transfers the debt asset being repaid to the aToken, where the liquidity is kept
192 IERC20(params.debtAsset).safeTransferFrom(msg.sender, address(params.pool), vars.actualDebtToLiquidate);

    emit PoolEventsLib.LiquidationCall(
      params.collateralAsset, params.debtAsset, params.position, vars.actualDebtToLiquidate, vars.actualCollateralToLiquidate, msg.sender
    );
  }
```
From L192, we can see that `vars.actualDebtToLiquidate` is amount of debt asset, not share.   
And `_calculateAvailableCollateralToLiquidate()` function called on L138 is as follows.
```solidity
  function _calculateAvailableCollateralToLiquidate(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ReserveCache memory debtReserveCache,
    uint256 debtToCover,
    uint256 userCollateralBalance,
    uint256 liquidationBonus,
    uint256 collateralPrice,
    uint256 debtAssetPrice,
    uint256 liquidationProtocolFeePercentage
  ) internal view returns (uint256, uint256, uint256) {
    AvailableCollateralToLiquidateLocalVars memory vars;

    vars.collateralPrice = collateralPrice; // oracle.getAssetPrice(collateralAsset);
    vars.debtAssetPrice = debtAssetPrice; // oracle.getAssetPrice(debtAsset);

    vars.collateralDecimals = collateralReserve.configuration.getDecimals();
    vars.debtAssetDecimals = debtReserveCache.reserveConfiguration.getDecimals();

    unchecked {
      vars.collateralAssetUnit = 10 ** vars.collateralDecimals;
      vars.debtAssetUnit = 10 ** vars.debtAssetDecimals;
    }

    // This is the base collateral to liquidate based on the given debt to cover
    vars.baseCollateral = ((vars.debtAssetPrice * debtToCover * vars.collateralAssetUnit)) / (vars.collateralPrice * vars.debtAssetUnit);

    vars.maxCollateralToLiquidate = vars.baseCollateral.percentMul(liquidationBonus);

    if (vars.maxCollateralToLiquidate > userCollateralBalance) {
      vars.collateralAmount = userCollateralBalance;
      vars.debtAmountNeeded = (
        (vars.collateralPrice * vars.collateralAmount * vars.debtAssetUnit) / (vars.debtAssetPrice * vars.collateralAssetUnit)
      ).percentDiv(liquidationBonus);
    } else {
      vars.collateralAmount = vars.maxCollateralToLiquidate;
363   vars.debtAmountNeeded = debtToCover;
    }

    if (liquidationProtocolFeePercentage != 0) {
      vars.bonusCollateral = vars.collateralAmount - vars.collateralAmount.percentDiv(liquidationBonus);
      vars.liquidationProtocolFee = vars.bonusCollateral.percentMul(liquidationProtocolFeePercentage);
      return (vars.collateralAmount - vars.liquidationProtocolFee, vars.debtAmountNeeded, vars.liquidationProtocolFee);
    } else {
      return (vars.collateralAmount, vars.debtAmountNeeded, 0);
    }
  }
```
From L363, we can see that parameter `debtToCover` is amount of asset.   
This value is calculated on L117 as `vars.actualDebtToLiquidate` through `_calculateDebt()` function.   
```solidity
  function _calculateDebt(
    DataTypes.ExecuteLiquidationCallParams memory params,
    uint256 healthFactor,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances
  ) internal view returns (uint256, uint256) {
    uint256 userDebt = balances[params.debtAsset][params.position].debtShares;

    uint256 closeFactor = healthFactor > CLOSE_FACTOR_HF_THRESHOLD ? DEFAULT_LIQUIDATION_CLOSE_FACTOR : MAX_LIQUIDATION_CLOSE_FACTOR;

    uint256 maxLiquidatableDebt = userDebt.percentMul(closeFactor);

    uint256 actualDebtToLiquidate = params.debtToCover > maxLiquidatableDebt ? maxLiquidatableDebt : params.debtToCover;

    return (userDebt, actualDebtToLiquidate);
  }
```
As we can see above, userDebt is share, so `actualDebtToLiquidate` is share, too.    
So the protocol used shares as amount not considering `borrowIndex`.   

On the other hand, on L136 it gets collateral balance as share, not considering `liquidityIndex`.   

As a result, liquidityIndex and borrowIndex rises more, liquidation process becomes worse.

## Impact
The protocol considers shares as amount when liquidation, so liquidation process breaks.

## Code Snippet
- [zerolend-one/contracts/core/pool/logic/LiquidationLogic.sol](zerolend-one/contracts/core/pool/logic/LiquidationLogic.sol)#L94~197, L259~272, L328~373
- [zerolend-one/contracts/core/pool/Pool.sol](zerolend-one/contracts/core/pool/Pool.sol)#L148~176
- [zerolend-one/contracts/core/pool/PoolSetters.sol](zerolend-one/contracts/core/pool/PoolSetters.sol)#L130~132

## Tool used
Manual Review

## Recommendation
Convert debt and collateral shares to balance by using liquidityIndex and borrowIndex when liquidation.
1. `LiquidationLogic.sol#_calculateDebt()` function has to be modified as follows.
```solidity
  function _calculateDebt(
+   DataTypes.ReserveCache memory cache,
    DataTypes.ExecuteLiquidationCallParams memory params,
    uint256 healthFactor,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances
  ) internal view returns (uint256, uint256) {
-   uint256 userDebt = balances[params.debtAsset][params.position].debtShares;
+   uint256 userDebt = balances[params.debtAsset][params.position].debtShares.rayMul(cache.nextBorrowIndex);

    uint256 closeFactor = healthFactor > CLOSE_FACTOR_HF_THRESHOLD ? DEFAULT_LIQUIDATION_CLOSE_FACTOR : MAX_LIQUIDATION_CLOSE_FACTOR;

    uint256 maxLiquidatableDebt = userDebt.percentMul(closeFactor);

    uint256 actualDebtToLiquidate = params.debtToCover > maxLiquidatableDebt ? maxLiquidatableDebt : params.debtToCover;

    return (userDebt, actualDebtToLiquidate);
  }
```
2. `LiquidationLogic.sol#executeLiquidationCall()` function has to be modified as follows.
```solidity
  function executeLiquidationCall(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances,
    mapping(address => DataTypes.ReserveSupplies) storage totalSupplies,
    mapping(bytes32 => DataTypes.UserConfigurationMap) storage usersConfig,
    DataTypes.ExecuteLiquidationCallParams memory params
  ) external {
    LiquidationCallLocalVars memory vars;

    DataTypes.ReserveData storage collateralReserve = reservesData[params.collateralAsset];
    DataTypes.ReserveData storage debtReserve = reservesData[params.debtAsset];
    DataTypes.UserConfigurationMap storage userConfig = usersConfig[params.position];
    vars.debtReserveCache = debtReserve.cache(totalSupplies[params.debtAsset]);
    debtReserve.updateState(params.reserveFactor, vars.debtReserveCache);

    (,,,, vars.healthFactor,) = GenericLogic.calculateUserAccountData(
      balances,
      reservesData,
      reservesList,
      DataTypes.CalculateUserAccountDataParams({userConfig: userConfig, position: params.position, pool: params.pool})
    );

    (vars.userDebt, vars.actualDebtToLiquidate) = _calculateDebt(
-     // vars.debtReserveCache,
+     vars.debtReserveCache,
      params,
      vars.healthFactor,
      balances
    );

    ValidationLogic.validateLiquidationCall(
      userConfig,
      collateralReserve,
      DataTypes.ValidateLiquidationCallParams({
        debtReserveCache: vars.debtReserveCache,
        totalDebt: vars.userDebt,
        healthFactor: vars.healthFactor
      })
    );

    (vars.collateralPriceSource, vars.debtPriceSource, vars.liquidationBonus) = _getConfigurationData(collateralReserve, params);

-   vars.userCollateralBalance = balances[params.collateralAsset][params.position].supplyShares;
+   vars.userCollateralBalance = balances[params.collateralAsset][params.position].supplyShares.rayMul(collateralReserve.getNormalizedIncome());

    (vars.actualCollateralToLiquidate, vars.actualDebtToLiquidate, vars.liquidationProtocolFeeAmount) =
    _calculateAvailableCollateralToLiquidate(
      collateralReserve,
      vars.debtReserveCache,
      vars.actualDebtToLiquidate,
      vars.userCollateralBalance,
      vars.liquidationBonus,
      IPool(params.pool).getAssetPrice(params.collateralAsset),
      IPool(params.pool).getAssetPrice(params.debtAsset),
      IPool(params.pool).factory().liquidationProtocolFeePercentage()
    );

   ...
  }
```

# [H-02] Wrong calculation of supply balance and debt balance when withdraw and repay.
## Summary
The protocol calculates supply balance from supply share wrongly when withdraw.   
As same way, it calculates wrongly debt balance from debt share wrongly when repay.

## Vulnerability Detail
`SupplyLogic.sol#executeWithdraw()` function which is called when withdraw is as follows.
```solidity
  function executeWithdraw(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    DataTypes.UserConfigurationMap storage userConfig,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances,
    DataTypes.ReserveSupplies storage totalSupplies,
    DataTypes.ExecuteWithdrawParams memory params
  ) external returns (DataTypes.SharesType memory burnt) {
    DataTypes.ReserveData storage reserve = reservesData[params.asset];
    DataTypes.ReserveCache memory cache = reserve.cache(totalSupplies);
    reserve.updateState(params.reserveFactor, cache);

118 uint256 balance = balances[params.asset][params.position].getSupplyBalance(cache.nextLiquidityIndex);

    // repay with max amount should clear off all debt
    if (params.amount == type(uint256).max) params.amount = balance;

    ValidationLogic.validateWithdraw(params.amount, balance);

    ...
  }
```
Here, `balances[params.asset][params.position]` is the amount of supply share.
`PositionBalanceConfiguration.sol#getSupplyBalance()` function called on L118 is as follows.
```solidity
  function getSupplyBalance(DataTypes.PositionBalance storage self, uint256 index) public view returns (uint256 supply) {
127    uint256 increase = self.supplyShares.rayMul(index) - self.supplyShares.rayMul(self.lastSupplyLiquidtyIndex);
128    return self.supplyShares + increase;
  }
```
As we can see above, it adds share and amount.    
As same way, it calculates debt amount wrongly from debt share in `PositionBalanceConfiguration.sol#getDebtBalance()`.
```solidity
  function getDebtBalance(DataTypes.PositionBalance storage self, uint256 index) internal view returns (uint256 debt) {
    uint256 increase = self.debtShares.rayMul(index) - self.debtShares.rayMul(self.lastDebtLiquidtyIndex);
    return self.debtShares + increase;
  }
```

## Impact
A user cannot withdraw full balance. And it calculates debt balance of user wrongly, so it can cause unexpected error.

## Code Snippet
- [zerolend-one/contracts/core/pool/configuration/PositionBalanceConfiguration.sol](zerolend-one/contracts/core/pool/configuration/PositionBalanceConfiguration.sol)
- [zerolend-one/contracts/core/pool/logic/SupplyLogic.sol](zerolend-one/contracts/core/pool/logic/SupplyLogic.sol)
- [zerolend-one/contracts/core/pool/logic/BorrowLogic.sol](zerolend-one/contracts/core/pool/logic/BorrowLogic.sol)
- [zerolend-one/contracts/core/pool/Pool.sol](zerolend-one/contracts/core/pool/Pool.sol)
- [zerolend-one/contracts/core/pool/PoolSetters.sol](zerolend-one/contracts/core/pool/PoolSetters.sol)

## Tool used
Manual Review

## Recommendation
`PositionBalanceConfiguration.sol#getSupplyBalance(), getDebtBalance()` functions have to be modified as follows.
```solidity
  function getSupplyBalance(DataTypes.PositionBalance storage self, uint256 index) public view returns (uint256 supply) {
-   uint256 increase = self.supplyShares.rayMul(index) - self.supplyShares.rayMul(self.lastSupplyLiquidtyIndex);
-   return self.supplyShares + increase;
+   return self.supplyShares.rayMul(index);
  }
  
  function getDebtBalance(DataTypes.PositionBalance storage self, uint256 index) internal view returns (uint256 debt) {
-   uint256 increase = self.debtShares.rayMul(index) - self.debtShares.rayMul(self.lastDebtLiquidtyIndex);
-   return self.debtShares + increase;
+   return self.debtShares.rayMul(index);
  }
```

# [M-01] The protocol updates interest rates of collateral wrongly when liquidation.
## Summary
The protocol does not consider `liquidationProtocolFee` which transfers to treasury when update interest rates of collateral.

## Vulnerability Detail
`LiquidationLogic.sol#executeLiquidationCall()` is as follows.
```solidity
  function executeLiquidationCall(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances,
    mapping(address => DataTypes.ReserveSupplies) storage totalSupplies,
    mapping(bytes32 => DataTypes.UserConfigurationMap) storage usersConfig,
    DataTypes.ExecuteLiquidationCallParams memory params
  ) external {
    LiquidationCallLocalVars memory vars;

    DataTypes.ReserveData storage collateralReserve = reservesData[params.collateralAsset];
    DataTypes.ReserveData storage debtReserve = reservesData[params.debtAsset];
    DataTypes.UserConfigurationMap storage userConfig = usersConfig[params.position];
    vars.debtReserveCache = debtReserve.cache(totalSupplies[params.debtAsset]);
    debtReserve.updateState(params.reserveFactor, vars.debtReserveCache);

    ...

    (vars.actualCollateralToLiquidate, vars.actualDebtToLiquidate, vars.liquidationProtocolFeeAmount) =
    _calculateAvailableCollateralToLiquidate(
      collateralReserve,
      vars.debtReserveCache,
      vars.actualDebtToLiquidate,
      vars.userCollateralBalance,
      vars.liquidationBonus,
      IPool(params.pool).getAssetPrice(params.collateralAsset),
      IPool(params.pool).getAssetPrice(params.debtAsset),
      IPool(params.pool).factory().liquidationProtocolFeePercentage()
    );

    ...

174 _burnCollateralTokens(
      collateralReserve, params, vars, balances[params.collateralAsset][params.position], totalSupplies[params.collateralAsset]
    );

    // Transfer fee to treasury if it is non-zero
    if (vars.liquidationProtocolFeeAmount != 0) {
      uint256 liquidityIndex = collateralReserve.getNormalizedIncome();
      uint256 scaledDownLiquidationProtocolFee = vars.liquidationProtocolFeeAmount.rayDiv(liquidityIndex);
      uint256 scaledDownUserBalance = balances[params.collateralAsset][params.position].supplyShares;

      if (scaledDownLiquidationProtocolFee > scaledDownUserBalance) {
        vars.liquidationProtocolFeeAmount = scaledDownUserBalance.rayMul(liquidityIndex);
      }

188   IERC20(params.collateralAsset).safeTransfer(IPool(params.pool).factory().treasury(), vars.liquidationProtocolFeeAmount);
    }

    // Transfers the debt asset being repaid to the aToken, where the liquidity is kept
    IERC20(params.debtAsset).safeTransferFrom(msg.sender, address(params.pool), vars.actualDebtToLiquidate);

    emit PoolEventsLib.LiquidationCall(
      params.collateralAsset, params.debtAsset, params.position, vars.actualDebtToLiquidate, vars.actualCollateralToLiquidate, msg.sender
    );
  }
```
As we can see above, on L188 it transfers `liquidationProtocolFee` to treasury.   
And `_burnCollateralTokens()` function called on L174 is as follows.
```solidity
  function _burnCollateralTokens(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ExecuteLiquidationCallParams memory params,
    LiquidationCallLocalVars memory vars,
    DataTypes.PositionBalance storage balances,
    DataTypes.ReserveSupplies storage totalSupplies
  ) internal {
    DataTypes.ReserveCache memory collateralReserveCache = collateralReserve.cache(totalSupplies);
    collateralReserve.updateState(params.reserveFactor, collateralReserveCache);
    collateralReserve.updateInterestRates(
      totalSupplies,
      collateralReserveCache,
      params.collateralAsset,
      IPool(params.pool).getReserveFactor(),
      0,
@>    vars.actualCollateralToLiquidate,
      params.position,
      params.data.interestRateData
    );

    // Burn the equivalent amount of aToken, sending the underlying to the liquidator
    balances.withdrawCollateral(totalSupplies, vars.actualCollateralToLiquidate, collateralReserveCache.nextLiquidityIndex);
    IERC20(params.collateralAsset).safeTransfer(msg.sender, vars.actualCollateralToLiquidate);
  }
```
As we can see above, the protocol does not consider `liquidationProtocolFeeAmount` to transfers to treasury.   
So `interestRates` is updated wrongly.

## Impact
When liquidation, the protocol updates interestRates wrongly, so protocol `interestRates` and indexes can be corrupted by liquidation as time goes by.

## Code Snippet
- [zerolend-one/contracts/core/pool/logic/LiquidationLogic.sol](zerolend-one/contracts/core/pool/logic/LiquidationLogic.sol)
- [zerolend-one/contracts/core/pool/Pool.sol](zerolend-one/contracts/core/pool/Pool.sol)
- [zerolend-one/contracts/core/pool/PoolSetters.sol](zerolend-one/contracts/core/pool/PoolSetters.sol)

## Tool used

Manual Review

## Recommendation
The `_burnCollateralTokens()` function has to be modified as follows.
```solidity
  function _burnCollateralTokens(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ExecuteLiquidationCallParams memory params,
    LiquidationCallLocalVars memory vars,
    DataTypes.PositionBalance storage balances,
    DataTypes.ReserveSupplies storage totalSupplies
  ) internal {
    DataTypes.ReserveCache memory collateralReserveCache = collateralReserve.cache(totalSupplies);
    collateralReserve.updateState(params.reserveFactor, collateralReserveCache);
    collateralReserve.updateInterestRates(
      totalSupplies,
      collateralReserveCache,
      params.collateralAsset,
      IPool(params.pool).getReserveFactor(),
      0,
-     vars.actualCollateralToLiquidate,
+     vars.actualCollateralToLiquidate + vars.liquidationProtocolFeeAmount,
      params.position,
      params.data.interestRateData
    );

    // Burn the equivalent amount of aToken, sending the underlying to the liquidator
    balances.withdrawCollateral(totalSupplies, vars.actualCollateralToLiquidate, collateralReserveCache.nextLiquidityIndex);
    IERC20(params.collateralAsset).safeTransfer(msg.sender, vars.actualCollateralToLiquidate);
  }
```

# [M-02] Allocator will not be able to withdraw all assets from pool.
## Summary
`CuratedVault.reallocate()` function passes zero mistakenly to `Pool.withdrawSimple()` function as `amount` to withdraw all assets which should be `type(uint256).max)`.
Therefore, allocator will withdraw zero amount of assets instead of all supplied assets to the pool.

## Vulnerability Detail
`CuratedVault.reallocate()` function is following.
```solidity
  function reallocate(MarketAllocation[] calldata allocations) external onlyAllocator {
    uint256 totalSupplied;
    uint256 totalWithdrawn;

    for (uint256 i; i < allocations.length; ++i) {
      MarketAllocation memory allocation = allocations[i];
      IPool pool = allocation.market;

      (uint256 supplyAssets, uint256 supplyShares) = _accruedSupplyBalance(pool);
      uint256 toWithdraw = supplyAssets.zeroFloorSub(allocation.assets);

      if (toWithdraw > 0) {
        if (!config[pool].enabled) revert CuratedErrorsLib.MarketNotEnabled(pool);

        // Guarantees that unknown frontrunning donations can be withdrawn, in order to disable a market.
        uint256 shares;
        if (allocation.assets == 0) {
          shares = supplyShares;
250:      toWithdraw = 0;
        }

        DataTypes.SharesType memory burnt = pool.withdrawSimple(asset(), address(this), toWithdraw, 0);
        emit CuratedEventsLib.ReallocateWithdraw(_msgSender(), pool, burnt.assets, burnt.shares);
        totalWithdrawn += burnt.assets;
      } else {
        --- SKIP ---
      }
    }

    if (totalWithdrawn != totalSupplied) revert CuratedErrorsLib.InconsistentReallocation();
  }
```
As can be seen, the above function set `toWithdraw = 0` on `L250` when `allocation.assets == 0`.
Then, `toWithdraw` is passed to `Pool.withdrawSimple()` function as `amount` on `L253`.
The `amount` goes through `Pool.withdrawSimple()` -> `PoolSetters._withdraw()` -> `SupplyLogic.executeWithdraw()` functions.
```solidity
  function executeWithdraw(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    DataTypes.UserConfigurationMap storage userConfig,
    mapping(address => mapping(bytes32 => DataTypes.PositionBalance)) storage balances,
    DataTypes.ReserveSupplies storage totalSupplies,
    DataTypes.ExecuteWithdrawParams memory params
  ) external returns (DataTypes.SharesType memory burnt) {
    DataTypes.ReserveData storage reserve = reservesData[params.asset];
    DataTypes.ReserveCache memory cache = reserve.cache(totalSupplies);
    reserve.updateState(params.reserveFactor, cache);

    uint256 balance = balances[params.asset][params.position].getSupplyBalance(cache.nextLiquidityIndex);

    // repay with max amount should clear off all debt
121:if (params.amount == type(uint256).max) params.amount = balance;

    --- SKIP ---
  }
```
As can be seen on `L121`, `params.amount` should be `type(uint256).max` to withdraw all assets from pool.

## Impact
Allocator will not be able to withdraw all assets from pool.

## Code Snippet
- [CureatedVault.reallocate()](https://github.com/sherlock-audit/2024-06-new-scope/blob/main/zerolend-one/contracts/core/vaults/CuratedVault.sol#L250)

## Tool used
Manual Review

## Recommendation
Modify `CuratedVault.reallocate()` function as follows.
```solidity
  function reallocate(MarketAllocation[] calldata allocations) external onlyAllocator {
    uint256 totalSupplied;
    uint256 totalWithdrawn;

    for (uint256 i; i < allocations.length; ++i) {
      MarketAllocation memory allocation = allocations[i];
      IPool pool = allocation.market;

      (uint256 supplyAssets, uint256 supplyShares) = _accruedSupplyBalance(pool);
      uint256 toWithdraw = supplyAssets.zeroFloorSub(allocation.assets);

      if (toWithdraw > 0) {
        if (!config[pool].enabled) revert CuratedErrorsLib.MarketNotEnabled(pool);

        // Guarantees that unknown frontrunning donations can be withdrawn, in order to disable a market.
        uint256 shares;
        if (allocation.assets == 0) {
          shares = supplyShares;
--        toWithdraw = 0;
++        toWithdraw = type(uint256).max;
        }

        DataTypes.SharesType memory burnt = pool.withdrawSimple(asset(), address(this), toWithdraw, 0);
        emit CuratedEventsLib.ReallocateWithdraw(_msgSender(), pool, burnt.assets, burnt.shares);
        totalWithdrawn += burnt.assets;
      } else {
        --- SKIP ---
      }
    }

    if (totalWithdrawn != totalSupplied) revert CuratedErrorsLib.InconsistentReallocation();
  }
```

# [M-03] Partial repayment is reverted because of rounding error.
## Summary
`NFTPositionManagerSetters.sol#_repay()` strictly checks that difference of debt balance before and after repayment is same as transfered amount.   
But because of rounding error, the difference of debt balance can be not same as transfered amount.

## Vulnerability Detail
`NFTPositionManagerSetters.sol#_repay()` function is as follows.
```solidity
  function _repay(AssetOperationParams memory params) internal nonReentrant {
    if (params.amount == 0) revert NFTErrorsLib.ZeroValueNotAllowed();
    if (params.tokenId == 0) {
      if (msg.sender != _ownerOf(_nextId - 1)) revert NFTErrorsLib.NotTokenIdOwner();
      params.tokenId = _nextId - 1;
    }

    Position memory userPosition = _positions[params.tokenId];

    IPool pool = IPool(userPosition.pool);
    IERC20 asset = IERC20(params.asset);

    asset.forceApprove(userPosition.pool, params.amount);

    uint256 previousDebtBalance = pool.getDebt(params.asset, address(this), params.tokenId);
    DataTypes.SharesType memory repaid = pool.repay(params.asset, params.amount, params.tokenId, params.data);
    uint256 currentDebtBalance = pool.getDebt(params.asset, address(this), params.tokenId);

123 if (previousDebtBalance - currentDebtBalance != repaid.assets) {
      revert NFTErrorsLib.BalanceMisMatch();
    }

    if (currentDebtBalance == 0 && repaid.assets < params.amount) {
      asset.safeTransfer(msg.sender, params.amount - repaid.assets);
    }

    // update incentives
    _handleDebt(address(pool), params.asset, params.tokenId, currentDebtBalance);

    emit NFTEventsLib.Repay(params.asset, params.amount, params.tokenId);
  }
```
On L123, it strictly checks that difference of debt balance is same as transfered amount for repaying.   
And `BorrowLogic.sol#executeRepay()` is as follows.
```solidity
  function executeRepay(
    DataTypes.ReserveData storage reserve,
    DataTypes.PositionBalance storage balances,
    DataTypes.ReserveSupplies storage totalSupplies,
    DataTypes.UserConfigurationMap storage userConfig,
    DataTypes.ExecuteRepayParams memory params
  ) external returns (DataTypes.SharesType memory payback) {
    DataTypes.ReserveCache memory cache = reserve.cache(totalSupplies);
    reserve.updateState(params.reserveFactor, cache);
    payback.assets = balances.getDebtBalance(cache.nextBorrowIndex);

    // Allows a user to max repay without leaving dust from interest.
    if (params.amount == type(uint256).max) {
      params.amount = payback.assets;
    }

    ValidationLogic.validateRepay(params.amount, payback.assets);

    // If paybackAmount is more than what the user wants to payback, the set it to the
    // user input (ie params.amount)
    if (params.amount < payback.assets) payback.assets = params.amount;

    reserve.updateInterestRates(
      totalSupplies,
      cache,
      params.asset,
      IPool(params.pool).getReserveFactor(),
      payback.assets,
      0,
      params.position,
      params.data.interestRateData
    );

    // update balances and total supplies
@>  payback.shares = balances.repayDebt(totalSupplies, payback.assets, cache.nextBorrowIndex);
    cache.nextDebtShares = totalSupplies.debtShares;

    if (balances.getDebtBalance(cache.nextBorrowIndex) == 0) {
      userConfig.setBorrowing(reserve.id, false);
    }

    IERC20(params.asset).safeTransferFrom(msg.sender, address(this), payback.assets);
    emit PoolEventsLib.Repay(params.asset, params.position, msg.sender, payback.assets);
  }
```
Here, `PositionBalanceConfiguration.sol#repayDebt()` function is as follows.
```solidity
  function repayDebt(
    DataTypes.PositionBalance storage self,
    DataTypes.ReserveSupplies storage supply,
    uint256 amount,
    uint128 index
  ) internal returns (uint256 sharesBurnt) {
113 sharesBurnt = amount.rayDiv(index);
    require(sharesBurnt != 0, PoolErrorsLib.INVALID_BURN_AMOUNT);
    self.lastDebtLiquidtyIndex = index;
    self.debtShares -= sharesBurnt;
    supply.debtShares -= sharesBurnt;
  }
```
As we can see, it calculates shares burnt on L113.   
There is rounding error here.   

Let's see following example.   
1. A user has 1e18 shares and current debt index is 3e27. Then, user's debt balance is 3e18.
2. A user repays 1e18 assets. Then, burnt shares become `(1e18 * 1e27 + 0.5e27) / 3e27 = 0.33...3e18`. Then, result shares becomes `0.66...7e18`.
  Therefore, result debt balance becomes `(0.66...7e18 * 3e27 + 0.5e27) / 1e27 = 2.00..1e18`.
3. The difference of balance becomes `3e18 - 2.00...1e18 = 0.99...9e18`. And transfered assets for repaying is 1e18.
4. As a result, `NFTPositionManagerSetters.sol#_repay()` is reverted by L123.

## Impact
Legitimate partial repayment is reverted.

## Code Snippet
- [zerolend-one/contracts/core/positions/NFTPositionManagerSetters.sol](zerolend-one/contracts/core/positions/NFTPositionManagerSetters.sol)#L105~135
- [zerolend-one/contracts/core/pool/logic/BorrowLogic.sol](zerolend-one/contracts/core/pool/logic/BorrowLogic.sol)#L117~160
- [zerolend-one/contracts/core/pool/configuration/PositionBalanceConfiguration.sol](zerolend-one/contracts/core/pool/configuration/PositionBalanceConfiguration.sol)#L107~118

## Tool used

Manual Review

## Recommendation
`NFTPositionManagerSetters.sol#_repay()` function has to be modified as follows.
```solidity
  function _repay(AssetOperationParams memory params) internal nonReentrant {
    if (params.amount == 0) revert NFTErrorsLib.ZeroValueNotAllowed();
    if (params.tokenId == 0) {
      if (msg.sender != _ownerOf(_nextId - 1)) revert NFTErrorsLib.NotTokenIdOwner();
      params.tokenId = _nextId - 1;
    }

    Position memory userPosition = _positions[params.tokenId];

    IPool pool = IPool(userPosition.pool);
    IERC20 asset = IERC20(params.asset);

    asset.forceApprove(userPosition.pool, params.amount);

    uint256 previousDebtBalance = pool.getDebt(params.asset, address(this), params.tokenId);
    DataTypes.SharesType memory repaid = pool.repay(params.asset, params.amount, params.tokenId, params.data);
    uint256 currentDebtBalance = pool.getDebt(params.asset, address(this), params.tokenId);

-   if (previousDebtBalance - currentDebtBalance != repaid.assets) {
-     revert NFTErrorsLib.BalanceMisMatch();
-   }

    if (currentDebtBalance == 0 && repaid.assets < params.amount) {
      asset.safeTransfer(msg.sender, params.amount - repaid.assets);
    }

    // update incentives
    _handleDebt(address(pool), params.asset, params.tokenId, currentDebtBalance);

    emit NFTEventsLib.Repay(params.asset, params.amount, params.tokenId);
  }
```
