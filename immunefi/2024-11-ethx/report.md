## Summary
Operator can't complete his pending liquidation just in time when he has non terminal validators, even though his balance is enough.

## Vulnerability Detail
There is an error in the balance checking logic in `OperatorRewardsCollector._completeLiquidationIfExists()` function.
```solidity
File: OperatorRewardsCollector.sol
121:     function _completeLiquidationIfExists(address operator) internal {
122:         // Retrieve operator liquidation details
123:         ISDUtilityPool sdUtilityPool = ISDUtilityPool(staderConfig.getSDUtilityPool());
124:         OperatorLiquidation memory operatorLiquidation = sdUtilityPool.getOperatorLiquidation(operator);
125: 
126:         // If the liquidation is not repaid, check balance and then proceed with repayment
127:         if (!operatorLiquidation.isRepaid && operatorLiquidation.totalAmountInEth > 0) {
128:             (uint8 poolId, uint256 operatorId, uint256 nonTerminalKeys) = ISDCollateral(staderConfig.getSDCollateral())
129:                 .getOperatorInfo(operator);
130:             // Ensure that the balance is sufficient
131:             if (balances[operator] < operatorLiquidation.totalAmountInEth && nonTerminalKeys > 0) {    // audit: Code block - A. This check should be done after the next bock.
132:                 revert InsufficientBalance();
133:             }
134:             address permissionlessNodeRegistry = staderConfig.getPermissionlessNodeRegistry();         // audit: Code block - B.
135:             if (INodeRegistry(permissionlessNodeRegistry).POOL_ID() == poolId) {
136:                 address nodeELVault = IPermissionlessNodeRegistry(permissionlessNodeRegistry)
137:                     .nodeELRewardVaultByOperatorId(operatorId);
138:                 if (nodeELVault.balance > 0) {
139:                     INodeELRewardVault(nodeELVault).withdraw();
140:                 }
141:             }
...
173:         }
174:     }
```
Let's take a look into L131~L133's code block(A) and L134~L141's code block(B).
These two code blocks' order is wrong.
At first, L134~L141's meaning is to withdraw any reward from `NodeELRewardVault` and increase operator's `balances[]` value.
L131~L133's code checks if the operator has enough collected balance for liquidation and if he has active validators(non terminal) but not enough balance, it should revert.
But because A is called before B, it misses a possibility of balance increasement from `NodeELVault`'s reward when he has active validators.

This logic should be coded as follows.
```solidity
File: OperatorRewardsCollector.sol
121:     function _completeLiquidationIfExists(address operator) internal {
122:         // Retrieve operator liquidation details
123:         ISDUtilityPool sdUtilityPool = ISDUtilityPool(staderConfig.getSDUtilityPool());
124:         OperatorLiquidation memory operatorLiquidation = sdUtilityPool.getOperatorLiquidation(operator);
125: 
126:         // If the liquidation is not repaid, check balance and then proceed with repayment
127:         if (!operatorLiquidation.isRepaid && operatorLiquidation.totalAmountInEth > 0) {
128:             (uint8 poolId, uint256 operatorId, uint256 nonTerminalKeys) = ISDCollateral(staderConfig.getSDCollateral())
129:                 .getOperatorInfo(operator);
130:             address permissionlessNodeRegistry = staderConfig.getPermissionlessNodeRegistry();
131:             if (INodeRegistry(permissionlessNodeRegistry).POOL_ID() == poolId) {
132:                 address nodeELVault = IPermissionlessNodeRegistry(permissionlessNodeRegistry)
133:                     .nodeELRewardVaultByOperatorId(operatorId);
134:                 if (nodeELVault.balance > 0) {
135:                     INodeELRewardVault(nodeELVault).withdraw();
136:                 }
137:             }
138:             // Ensure that the balance is sufficient
139:             if (balances[operator] < operatorLiquidation.totalAmountInEth && nonTerminalKeys > 0) {
140:                 revert InsufficientBalance();
141:             }
...
173:         }
174:     }
```

## Impact
Operator can't complete his pending liquidation in time when he has non terminal validators, even though his balance is enough.
And liquidator can't get liquidation reward in time as well.


## Code Snippet
https://github.com/stader-labs/ethx/blob/1cf1efeec3c18f60316d451f3ac3d32098d51ac3/contracts/OperatorRewardsCollector.sol#L137-L147

## Tool used
Manual Review

## Proof of Concept
```solidity

/////////////////////////////////////////////////////////////////////////
// 
// I prepared 2 test cases.
//
/////////////////////////////////////////////////////////////////////////
//
// Test 1: test_claimLiquidationOriginalCode()
//
// Test scenario.
// 1. Patch test & mock files.
// 2. forge test -vv --mt test_claimLiquidationOriginalCode
//
/////////////////////////////////////////////////////////////////////////
//
// Test 2: test_claimLiquidationAfterFix()
//
// Test scenario.
// 1. Patch test & mock & OperatorRewardsCollector(Fixed Version).sol file.
// 2. forge test -vv --mt test_claimLiquidationAfterFix()
//
/////////////////////////////////////////////////////////////////////////

    function test_claimLiquidationOriginalCode() public {
        uint256 utilizeAmount = 1e22;
        uint256 operatorRewardsCollectorBalance = 90 ether;

        address operator = vm.addr(110);
        address liquidator = vm.addr(109);

        operatorRewardsCollector.depositFor{ value: operatorRewardsCollectorBalance }(operator);
        assertEq(operatorRewardsCollector.balances(operator), operatorRewardsCollectorBalance);

        staderToken.approve(address(sdUtilityPool), utilizeAmount * 10);
        sdUtilityPool.delegate(utilizeAmount * 10);

        vm.startPrank(operator);
        sdUtilityPool.utilize(utilizeAmount);
        vm.stopPrank();

        vm.mockCall(
            sdCollateralMock,
            abi.encodeWithSelector(ISDCollateral.operatorUtilizedSDBalance.selector),
            abi.encode(utilizeAmount)
        );

        vm.mockCall(
            address(staderOracle),
            abi.encodeWithSelector(IStaderOracle.getSDPriceInETH.selector),
            abi.encode(1e14)
        );

        vm.mockCall(
            permissionlessNodeRegistryMock,
            abi.encodeWithSelector(IPermissionlessNodeRegistry.nodeELRewardVaultByOperatorId.selector),
            abi.encode(address(nodeELRewardVaultImpl))
        );

        nodeELRewardVaultImpl.setMockOperator(operator);

        vm.roll(block.number + 1900000000);

        UserData memory userData = sdUtilityPool.getUserData(operator);
        staderToken.transfer(liquidator, userData.totalInterestSD);
        vm.startPrank(liquidator);
        staderToken.approve(address(sdUtilityPool), userData.totalInterestSD);
        assertEq(operatorRewardsCollector.withdrawableInEth(operator), 0);
        sdUtilityPool.liquidationCall(operator);
        OperatorLiquidation memory operatorLiquidation = sdUtilityPool.getOperatorLiquidation(operator);
        vm.stopPrank();

        //
        // Check current status.
        //
        console.log("operatorLiquidation.totalAmountInEth", operatorLiquidation.totalAmountInEth);                  // operatorLiquidation.totalAmountInEth 97602739724700000000. ~ 97.6 ether.
        console.log("operatorRewardsCollector.balances(operator)", operatorRewardsCollector.balances(operator));    // operatorRewardsCollector.balances(operator) 90000000000000000000. = 90 ether.

        address permissionlessNodeRegistry = staderConfig.getPermissionlessNodeRegistry();
        address nodeELVault = IPermissionlessNodeRegistry(permissionlessNodeRegistry).nodeELRewardVaultByOperatorId(0);
        console.log("nodeELVault.balance", nodeELVault.balance);                                                    // nodeELVault.balance 10000000000000000000. = 10 ether.

        //
        // Claim and complete liquidation.
        // This will revert because current code doesn't consider nodeELVault.balance.
        //
        vm.expectRevert(IOperatorRewardsCollector.InsufficientBalance.selector);
        operatorRewardsCollector.claimLiquidation(operator);
    }

    function test_claimLiquidationAfterFix() public {
        uint256 utilizeAmount = 1e22;
        uint256 operatorRewardsCollectorBalance = 90 ether;

        address operator = vm.addr(110);
        address liquidator = vm.addr(109);

        operatorRewardsCollector.depositFor{ value: operatorRewardsCollectorBalance }(operator);
        assertEq(operatorRewardsCollector.balances(operator), operatorRewardsCollectorBalance);

        staderToken.approve(address(sdUtilityPool), utilizeAmount * 10);
        sdUtilityPool.delegate(utilizeAmount * 10);

        vm.startPrank(operator);
        sdUtilityPool.utilize(utilizeAmount);
        vm.stopPrank();

        vm.mockCall(
            sdCollateralMock,
            abi.encodeWithSelector(ISDCollateral.operatorUtilizedSDBalance.selector),
            abi.encode(utilizeAmount)
        );

        vm.mockCall(
            address(staderOracle),
            abi.encodeWithSelector(IStaderOracle.getSDPriceInETH.selector),
            abi.encode(1e14)
        );

        vm.mockCall(
            permissionlessNodeRegistryMock,
            abi.encodeWithSelector(IPermissionlessNodeRegistry.nodeELRewardVaultByOperatorId.selector),
            abi.encode(address(nodeELRewardVaultImpl))
        );

        nodeELRewardVaultImpl.setMockOperator(operator);

        vm.roll(block.number + 1900000000);

        UserData memory userData = sdUtilityPool.getUserData(operator);
        staderToken.transfer(liquidator, userData.totalInterestSD);
        vm.startPrank(liquidator);
        staderToken.approve(address(sdUtilityPool), userData.totalInterestSD);
        assertEq(operatorRewardsCollector.withdrawableInEth(operator), 0);
        sdUtilityPool.liquidationCall(operator);
        OperatorLiquidation memory operatorLiquidation = sdUtilityPool.getOperatorLiquidation(operator);
        vm.stopPrank();

        //
        // Check current status.
        //
        console.log("operatorLiquidation.totalAmountInEth", operatorLiquidation.totalAmountInEth);                  // operatorLiquidation.totalAmountInEth 97602739724700000000. ~ 97.6 ether.
        console.log("operatorRewardsCollector.balances(operator)", operatorRewardsCollector.balances(operator));    // operatorRewardsCollector.balances(operator) 90000000000000000000. = 90 ether.

        address permissionlessNodeRegistry = staderConfig.getPermissionlessNodeRegistry();
        address nodeELVault = IPermissionlessNodeRegistry(permissionlessNodeRegistry).nodeELRewardVaultByOperatorId(0);
        console.log("nodeELVault.balance", nodeELVault.balance);                                                    // nodeELVault.balance 10000000000000000000. = 10 ether.
        uint256 nodeELVaultBalance = nodeELVault.balance;

        //
        // Claim and complete liquidation.
        //
        operatorRewardsCollector.claimLiquidation(operator);

        //
        // Must succeed.
        //
        console.log("operatorRewardsCollector.balances(operator)", operatorRewardsCollector.balances(operator));
        assertEq(operatorRewardsCollector.balances(operator), operatorRewardsCollectorBalance + nodeELVaultBalance - operatorLiquidation.totalAmountInEth);
    }
```