| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-the-calldata-checks-which-dont-overlap-partially-cant-be-added) | The calldata checks which don't overlap partially can't be added. |


# [M-01] The calldata checks which don't overlap partially can't be added.

## Links to affected code
- [Timelock._addCalldataCheck()](https://github.com/code-423n4/2024-10-kleidi/blob/main/src/Timelock.sol#L1120-L1121)

## Root cause
`Timelock._addCalldataCheck()` function is the following.
```solidity
    function _addCalldataCheck(
        address contractAddress,
        bytes4 selector,
        uint16 startIndex,
        uint16 endIndex,
        bytes[] memory data
    ) private {
        --- SKIP ---
            bool found;
            for (uint256 i = 0; i < indexes.length; i++) {
                if (
                    indexes[i].startIndex == startIndex
                        && indexes[i].endIndex == endIndex
                ) {
                    targetIndex = i;
                    found = true;
                    break;
                }
                /// all calldata checks must be isolated to predefined calldata segments
                /// for example given calldata with three parameters:

                ///                    1.                              2.                             3.
                ///       000000000000000112818929111111
                ///                                     000000000000000112818929111111
                ///                                                                   000000000000000112818929111111

                /// checks must be applied in a way such that they do not overlap with each other.
                /// having checks that check 1 and 2 together as a single parameter would be valid,
                /// but having checks that check 1 and 2 together, and then check one separately
                /// would be invalid.
                /// checking 1, 2, and 3 separately is valid
                /// checking 1, 2, and 3 as a single check is valid
                /// checking 1, 2, and 3 separately, and then the last half of 2 and the first half
                /// of 3 is invalid

                require(
1121:               startIndex > indexes[i].endIndex
1122:                   || endIndex < indexes[i].startIndex,
                    "CalldataList: Partial check overlap"
                );
            }
        --- SKIP ---
    }
```
As can be seen, `L1121` uses strict inequality `>` instead of `>=` and `L1122` uses strict inequality '<' instead of `<=`. Therefore, the function will revert if the two calldatas are for two consecutive parameters respectively.

## Proof of Concept
For instance, assume that the `contractAddress` is the address of the following [MockLending](https://github.com/code-423n4/2024-10-kleidi/blob/main/test/mock/MockLending.sol) contract and the `selector` is for the `deposit()` function.
```solidity
contract MockLending {
    mapping(address owner => uint256 amount) _balance;

    function deposit(address to, uint256 amount) external {
        _balance[to] += amount;

        /// token.transferFrom(msg.sender, address(this), amount);
    }
    --- SKIP ---
}
```
Then, in the calldata to `deposit()` function, `0~3` bytes are for function selector, `4~23` bytes are for `to` parameter and `24~55` bytes are for `amount` parameter.
Assume that we want to whitelist the calls for two cases where `to = 0x1234` or `amount = 1e18` respectively: For the first case, We have to call `addCalldataCheck()` function with `startIndex = 4, endIndex = 24, to = 0x1234`. And after that, for the second case, we have to call `addCalldataCheck()` function with `startIndex = 24, endIndex = 56, amount = 1e18`. In the second call, the function will revert at `L1121` because `startIndex = 24` and `indexes[0].endIndex = 24` is equal. 

Add the following test code into [`CalldataList.t.sol`](https://github.com/code-423n4/2024-10-kleidi/blob/main/test/unit/CalldataList.t.sol).
```solidity
    function testAddCalldataCheckFailsWithConsecutiveParameters() public {
        // targetAddress is the MockLending contract
        address[] memory targetAddresses = new address[](2);
        targetAddresses[0] = address(lending);
        targetAddresses[1] = address(lending);

        // selector is deposit() function
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MockLending.deposit.selector;
        selectors[1] = MockLending.deposit.selector;

        /// add two calldata to deposit(address to, uint256 amount) function
        uint16[] memory startIndexes = new uint16[](2);
        uint16[] memory endIndexes = new uint16[](2);

        // first calldata is for `to` parameter
        startIndexes[0] = 4;
        endIndexes[0] = 24;

        // second calldata is for `amount` parameter 
        startIndexes[1] = 24;
        endIndexes[1] = 56;

        bytes[][] memory checkedCalldatas = new bytes[][](2);

        // `to` parameter is `address(0x1234)`
        bytes[] memory checkedCalldata1 = new bytes[](1);
        checkedCalldata1[0] = abi.encodePacked(address(0x1234));
        checkedCalldatas[0] = checkedCalldata1;

        // `amount` parameter is `1e18`
        bytes[] memory checkedCalldata2 = new bytes[](1);
        checkedCalldata2[0] = abi.encodePacked(uint256(1e18));
        checkedCalldatas[1] = checkedCalldata2;

        vm.expectRevert("CalldataList: Partial check overlap");
        vm.prank(address(timelock));
        timelock.addCalldataChecks(
            targetAddresses,
            selectors,
            startIndexes,
            endIndexes,
            checkedCalldatas
        );
    }
```
The output of the above test code is the following.
```bash
Ran 1 test for test/unit/CalldataList.t.sol:CalldataListUnitTest
[PASS] testAddCalldataCheckFailsWithConsecutiveParameters() (gas: 142328)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 2.88ms (685.20µs CPU time)

Ran 1 test suite in 28.61ms (2.88ms CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
```
As can be seen, although The two calldata check don't overlap (4~23 and 24~55 bytes), the function call was reverted.

## Impact
The calldata checks which don't overlap partially can't be added.

## Recommended Mitigation Steps
Modify the `Timelock._addCalldataCheck()` function as follows.
```solidity
    function _addCalldataCheck(
        address contractAddress,
        bytes4 selector,
        uint16 startIndex,
        uint16 endIndex,
        bytes[] memory data
    ) private {
        --- SKIP ---
            bool found;
            for (uint256 i = 0; i < indexes.length; i++) {
                --- SKIP ---
                require(
--                  startIndex > indexes[i].endIndex
--                      || endIndex < indexes[i].startIndex,
++                  startIndex >= indexes[i].endIndex
++                      || endIndex <= indexes[i].startIndex,
                    "CalldataList: Partial check overlap"
                );
            }
        --- SKIP ---
    }
```
