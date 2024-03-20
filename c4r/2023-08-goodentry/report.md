| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-users-dont-receive-token-change-when-use-v3proxyswaptokensforexacteth-method) | Users don't receive token change when use V3Proxy.swapTokensForExactETH() method. |


# [H-01] Users don't receive token change when use V3Proxy.swapTokensForExactETH() method.
## Impact
When users call the V3Proxy.swapTokensForExactETH() method to swap ERC20 token for the amountOut ETH and if amountInMax is greater than the exact token amount for the ETH, he doesn't receive change.
That lost change amount is amountInMax - amounts[0].

## Proof of Concept
V3Proxy.swapTokensForExactETH() is following.
```solidity
File: V3Proxy.sol
160:     function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) payable external returns (uint[] memory amounts) {
161:         require(path.length == 2, "Direct swap only");
162:         require(path[1] == ROUTER.WETH9(), "Invalid path");
163:         ERC20 ogInAsset = ERC20(path[0]);
164:         ogInAsset.safeTransferFrom(msg.sender, address(this), amountInMax);
165:         ogInAsset.safeApprove(address(ROUTER), amountInMax);
166:         amounts = new uint[](2);
167:         amounts[0] = ROUTER.exactOutputSingle(ISwapRouter.ExactOutputSingleParams(path[0], path[1], feeTier, address(this), deadline, amountOut, amountInMax, 0));         
168:         amounts[1] = amountOut; 
169:         ogInAsset.safeApprove(address(ROUTER), 0);
170:         IWETH9 weth = IWETH9(ROUTER.WETH9());
171:         acceptPayable = true;
172:         weth.withdraw(amountOut);
173:         acceptPayable = false;
174:         payable(msg.sender).call{value: amountOut}("");
175:         emit Swap(msg.sender, path[0], path[1], amounts[0], amounts[1]); 
176:     }
```
This method's role is to swap ERC20 token into exact amount of ETH.
For this purpose, user will pass maximum amount of input token value to pay as amountInMax parameter.
In L164, the contract transfers amountInMax tokens into itself.
In L167, ROUTER.exactOutputSingle() call will swap ERC20 token into the amountOut of ETH. The contract will pay some input token to ROUTER and the paid token amount will be returned.
This value is set into amounts[0] variable.
If the paid token value is smaller than amountInMax value, the contract must give the caller his/her change.
Change value is amountInMax - amounts[0].
But there is no such processing in the implementation of the swapTokensForExactETH() method.

This logic, meanwhile, is implemented correctly in swapTokensForExactTokens() method's L132.
```solidity
File: V3Proxy.sol
124:     function swapTokensForExactTokens(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts) {
125:         require(path.length == 2, "Direct swap only");
126:         ERC20 ogInAsset = ERC20(path[0]);
127:         ogInAsset.safeTransferFrom(msg.sender, address(this), amountInMax);
128:         ogInAsset.safeApprove(address(ROUTER), amountInMax);
129:         amounts = new uint[](2);
130:         amounts[0] = ROUTER.exactOutputSingle(ISwapRouter.ExactOutputSingleParams(path[0], path[1], feeTier, msg.sender, deadline, amountOut, amountInMax, 0));         
131:         amounts[1] = amountOut; 
132:         ogInAsset.safeTransfer(msg.sender, ogInAsset.balanceOf(address(this))); //<--------@audit This call is correct!
133:         ogInAsset.safeApprove(address(ROUTER), 0);
134:         emit Swap(msg.sender, path[0], path[1], amounts[0], amounts[1]); 
135:     }
```
## Lines of code
https://github.com/code-423n4/2023-08-goodentry/blob/main/contracts/helper/V3Proxy.sol#L160-L176

## Tool used
Manual Review

## Recommended Mitigation Steps
```solidity
File: V3Proxy.sol
160:     function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) payable external returns (uint[] memory amounts) {
161:         require(path.length == 2, "Direct swap only");
162:         require(path[1] == ROUTER.WETH9(), "Invalid path");
163:         ERC20 ogInAsset = ERC20(path[0]);
164:         ogInAsset.safeTransferFrom(msg.sender, address(this), amountInMax);
165:         ogInAsset.safeApprove(address(ROUTER), amountInMax);
166:         amounts = new uint[](2);
167:         amounts[0] = ROUTER.exactOutputSingle(ISwapRouter.ExactOutputSingleParams(path[0], path[1], feeTier, address(this), deadline, amountOut, amountInMax, 0));         
168:         amounts[1] = amountOut; 
169: + 	     ogInAsset.safeTransfer(msg.sender, ogInAsset.balanceOf(address(this)));	//<--------@audit This call is necessary!
170:         ogInAsset.safeApprove(address(ROUTER), 0);
...
177:     }
```