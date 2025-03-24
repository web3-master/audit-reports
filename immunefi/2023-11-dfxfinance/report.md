## Summary
Unzap from quoteToken to ETH will always fail.

## Vulnerability Detail
Zap.unzap function is as follows.
```solidity
File: Zap.sol
063:     function unzap(
064:         address _curve,
065:         uint256 _lpAmount,
066:         uint256 _deadline,
067:         uint256 _minTokenAmount,
068:         address _token,
069:         bool _toETH
070:     ) public isDFXCurve(_curve) returns (uint256) {
071:         address wETH = ICurve(_curve).getWeth();
072:         IERC20Metadata base = IERC20Metadata(Curve(payable(_curve)).numeraires(0));
073:         IERC20Metadata quote = IERC20Metadata(Curve(payable(_curve)).numeraires(1));
074:         require(_token == address(base) || _token == address(quote), "zap/token-not-supported");
075:         IERC20Metadata(_curve).safeTransferFrom(msg.sender, address(this), _lpAmount);
076:         Curve(payable(_curve)).withdraw(_lpAmount, _deadline);
077:         // from base
078:         if (_token == address(base)) {
079:             uint256 baseAmount = base.balanceOf(address(this));
080:             base.safeApprove(_curve, 0);
081:             base.safeApprove(_curve, type(uint256).max);
082:             Curve(payable(_curve)).originSwap(address(base), address(quote), baseAmount, 0, _deadline);
083:             uint256 quoteAmount = quote.balanceOf(address(this));
084:             require(quoteAmount >= _minTokenAmount, "!Unzap/not-enough-token-amount");
085:             if (address(quote) == wETH && _toETH) {
086:                 IWETH(wETH).withdraw(quoteAmount);
087:                 (bool success,) = payable(msg.sender).call{value: quoteAmount}("");
088:                 require(success, "zap/unzap-to-eth-failed");
089:             } else {
090:                 quote.safeTransfer(msg.sender, quoteAmount);
091:             }
092:             return quoteAmount;
093:         } else {
094:             uint256 quoteAmount = quote.balanceOf(address(this));
095:             quote.safeApprove(_curve, 0);
096:             quote.safeApprove(_curve, type(uint256).max);
097:             Curve(payable(_curve)).originSwap(address(quote), address(base), quoteAmount, 0, _deadline);
098:             uint256 baseAmount = base.balanceOf(address(this));
099:             require(baseAmount >= _minTokenAmount, "!Unzap/not-enough-token-amount");
100:             if (address(base) == wETH && _toETH) {
101:                 IWETH(wETH).withdraw(quoteAmount);
102:                 (bool success,) = payable(msg.sender).call{value: baseAmount}("");
103:                 require(success, "zap/unzap-to-eth-failed");
104:             } else {
105:                 base.safeTransfer(msg.sender, baseAmount);
106:             }
107:             return baseAmount;
108:         }
109:     }
```
In L101, withdraw() function's parameter is wrong. It must be baseAmount. 
If quoteAmount > baseAmount, L101 will fail because Zap contract's current WETH balance is baseAmount. 
If quoteAmount < baseAmount, L102 will fail because Zap contract's current native ETH balance is quoteAmount.


## Impact
Zap.unzap() will always fail if base is wETH and _toETH is true. 
That is, any legitimate user can not withdraw his curve liquidity into native ETH. 
DeFi Zap is a frequently used feature so unzap operation's unexpected failure will severely damage the system's reputation.

## Code Snippet
https://github.com/dfx-finance/protocol-v3/blob/main/src/Zap.sol#L101

## Tool used
Manual Review

## Recommendation
Zap.sol#L101 should be modified as follows.
```solidity
File: Zap.sol
100:             if (address(base) == wETH && _toETH) {
101:  ---          IWETH(wETH).withdraw(quoteAmount);
101:  +++          IWETH(wETH).withdraw(baseAmount);
102:                 (bool success,) = payable(msg.sender).call{value: baseAmount}("");
```