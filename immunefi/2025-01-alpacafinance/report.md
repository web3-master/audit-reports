## Summary
Admin can't remove whitelisted non collat borrower after 6 borrowers have been whitelisted.

## Vulnerability Detail
There is an error in the max non collateral borrower checking logic in `AdminFacet.setNonCollatBorrowerOk()` function.
```solidity
File: AdminFacet.sol
227:   function setNonCollatBorrowerOk(address _borrower, bool _isOk) external onlyOwner {
228:     LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
229: 
230:     if (moneyMarketDs.countNonCollatBorrowers > 5) {           // @audit: This logic should be run after the following increase/decrease logic.
231:       revert AdminFacet_ExceedMaxNonCollatBorrowers();
232:     }
233:     // if adding the borrower to the whitelist, increase the count
234:     if (_isOk) {
235:       if (!moneyMarketDs.nonCollatBorrowerOk[_borrower]) {
236:         moneyMarketDs.countNonCollatBorrowers++;
237:       }
238:       // else, decrease the count
239:     } else {
240:       if (moneyMarketDs.nonCollatBorrowerOk[_borrower]) {
241:         moneyMarketDs.countNonCollatBorrowers--;
242:       }
243:     }
244: 
245:     moneyMarketDs.nonCollatBorrowerOk[_borrower] = _isOk;
246:     emit LogsetNonCollatBorrowerOk(_borrower, _isOk);
247:   }
248: 
```

Let's take a look into L230~L232's code block(A) and L234~L243's code block(B).
These two code blocks' order is wrong.
At first, code block A's checking is to limit money market's max non collateral borrowers count to 5.
And after pass this checking, the code block B is executed which increase or decrease the current non collat borrower count.
But because A is called before B, there should be 2 problems.
1. Money market's max non collateral borrowers can be 6, but not 5.
This is not so dangerous to the system.

2. When the whitelisted non collat borrowers count is full(6 borrowers total), admin can't blacklist any borrower from the list.
Because L230's test result will be false in this time.
And the whitelisted borrower list is bricked from this time forever.
This second issue is somewhat critical.

This logic should be coded as follows.
```solidity
File: AdminFacet.sol
227:   function setNonCollatBorrowerOk(address _borrower, bool _isOk) external onlyOwner {
228:     LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();
229: 
230:     // if adding the borrower to the whitelist, increase the count
231:     if (_isOk) {
232:       if (!moneyMarketDs.nonCollatBorrowerOk[_borrower]) {
233:         moneyMarketDs.countNonCollatBorrowers++;
234:       }
235:       // else, decrease the count
236:     } else {
237:       if (moneyMarketDs.nonCollatBorrowerOk[_borrower]) {
238:         moneyMarketDs.countNonCollatBorrowers--;
239:       }
240:     }
241: 
242:     if (moneyMarketDs.countNonCollatBorrowers > 5) {       // @audit: This checking should be done after increase/decrease logic.
243:       revert AdminFacet_ExceedMaxNonCollatBorrowers();
244:     }
245: 
246:     moneyMarketDs.nonCollatBorrowerOk[_borrower] = _isOk;
247:     emit LogsetNonCollatBorrowerOk(_borrower, _isOk);
248:   }
```

## Impact
1. Money market's max non collateral borrowers can be 6, but not 5.
This is not so dangerous to the system.

2. When the whitelisted non collat borrowers count is full(6 borrowers total), admin can't blacklist any borrower from the list.
And the whitelisted borrower list is bricked from this time forever.
This second issue is somewhat critical.


## Code Snippet
https://github.com/alpaca-finance/alpaca-v2-money-market/blob/ebadc646e32d7b627014d3201245c7d62839ff9f/solidity/contracts/money-market/facets/AdminFacet.sol#L230-L232

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
// Test 1: testRevert_WhenAdminBlocklistAfterMaxNonCollatBorrowersStatus()
//
// Test scenario.
// 1. Add and patch test files.
// 2. forge test -vvvvv --match-test testRevert_WhenAdminBlocklistAfterMaxNonCollatBorrowersStatus
//
/////////////////////////////////////////////////////////////////////////
//
// Test 2: testNonRevert_WhenAdminBlocklistAfterMaxNonCollatBorrowersStatus()
//
// Test scenario.
// 1. Add and patch test & AdminFacet(Fixed Version).sol file.
// 2. forge test -vv --mt testNonRevert_WhenAdminBlocklistAfterMaxNonCollatBorrowersStatus
//
/////////////////////////////////////////////////////////////////////////
contract MoneyMarket_Admin_NonCollatBorrowerTest is MoneyMarket_BaseTest {

  function setUp() public override {
    super.setUp();
  }

  /**
   * Admin can't remove whitelisted non collat borrower after 6 borrowers have been whitelisted.
   * This means, the non collat borrower list is bricked.
   */
  function testRevert_WhenAdminBlocklistAfterMaxNonCollatBorrowersStatus() external {
    //
    // 6 whitelisted non collat borrowers.
    //
    address ronaldino = address(0x101);
    address messi = address(0x102);
    address iniesta = address(0x103);
    address neimar = address(0x104);
    address suarez = address(0x105);
    address c_ronaldo = address(0x106);

    //
    // Whitelist them.
    //
    adminFacet.setNonCollatBorrowerOk(ronaldino, true);
    adminFacet.setNonCollatBorrowerOk(messi, true);
    adminFacet.setNonCollatBorrowerOk(iniesta, true);
    adminFacet.setNonCollatBorrowerOk(neimar, true);
    adminFacet.setNonCollatBorrowerOk(suarez, true);
    adminFacet.setNonCollatBorrowerOk(c_ronaldo, true);

    //
    // New admin is barcelona's fan so he decided to remove c_ronaldo.
    // But he can't do.
    //
    vm.expectRevert(IAdminFacet.AdminFacet_ExceedMaxNonCollatBorrowers.selector);
    adminFacet.setNonCollatBorrowerOk(c_ronaldo, false);
  }

  /**
   * Admin can remove whitelisted non collat borrower after 5 borrowers have been whitelisted in the patched AdminFacet.sol.
   */
  function testNonRevert_WhenAdminBlocklistAfterMaxNonCollatBorrowersStatus() external {
    //
    // 5 whitelisted non collat borrowers.
    //
    address ronaldino = address(0x101);
    address messi = address(0x102);
    address iniesta = address(0x103);
    address neimar = address(0x104);
    address c_ronaldo = address(0x106);

    //
    // Whitelist them.
    //
    adminFacet.setNonCollatBorrowerOk(ronaldino, true);
    adminFacet.setNonCollatBorrowerOk(messi, true);
    adminFacet.setNonCollatBorrowerOk(iniesta, true);
    adminFacet.setNonCollatBorrowerOk(neimar, true);
    adminFacet.setNonCollatBorrowerOk(c_ronaldo, true);

    //
    // New admin is barcelona's fan so he decided to remove c_ronaldo.
    //
    adminFacet.setNonCollatBorrowerOk(c_ronaldo, false);
  }
}
```