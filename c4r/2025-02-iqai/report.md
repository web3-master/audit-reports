| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-an-attacker-can-dos-liquiditymanagersolmoveliquidity) | An attacker can DOS `LiquidityManager.sol#moveLiquidity()`. |

# [M-01] An attacker can DOS `LiquidityManager.sol#moveLiquidity()`.
## Proof of Concept
`LiquidityManager.sol#moveLiquidity()` function is as follows.
```solidity
    function moveLiquidity() external {
        require(!bootstrapPool.killed(), "BootstrapPool already killed");
        uint256 price = bootstrapPool.getPrice();
        (uint256 _reserveCurrencyToken, ) = bootstrapPool.getReserves();
        _reserveCurrencyToken = _reserveCurrencyToken - bootstrapPool.phantomAmount();
        uint256 factoryTargetCCYLiquidity = AgentFactory(owner).targetCCYLiquidity();
        require(
            _reserveCurrencyToken >= targetCCYLiquidity || _reserveCurrencyToken >= factoryTargetCCYLiquidity,
            "Bootstrap end-criterion not reached"
        );
        bootstrapPool.kill();

        // Determine liquidity amount to add
@>      uint256 currencyAmount = currencyToken.balanceOf(address(this));
@>      uint256 liquidityAmount = (currencyAmount * 1e18) / price;

        // Add liquidity to Fraxswap
        IFraxswapPair fraxswapPair = addLiquidityToFraxswap(liquidityAmount, currencyAmount);

        // Send all remaining tokens to the agent.
        agentToken.safeTransfer(address(agent), agentToken.balanceOf(address(this)));
        currencyToken.safeTransfer(address(agent), currencyToken.balanceOf(address(this)));
        emit LiquidityMoved(agent, address(agentToken), address(fraxswapPair));

        AgentFactory(owner).setAgentStage(agent, 1);
    }
```
As we can see above, this implementation assumes that agentToken's balance is bigger than or equal to liquidityAmount.   
But an attacker can transfer some currency token to make liquidityAmount to be bigger than real balance of agentToken.   

Then, protocol cannot move bootstrapPool's liquidity to fraxswap. 

## Tool used
Manual Review

## Recommended Mitigation Steps
Modify `LiquidityManager.sol#moveLiquidity()` function as follows.
```solidity
    function moveLiquidity() external {
        require(!bootstrapPool.killed(), "BootstrapPool already killed");
        uint256 price = bootstrapPool.getPrice();
        (uint256 _reserveCurrencyToken, ) = bootstrapPool.getReserves();
        _reserveCurrencyToken = _reserveCurrencyToken - bootstrapPool.phantomAmount();
        uint256 factoryTargetCCYLiquidity = AgentFactory(owner).targetCCYLiquidity();
        require(
            _reserveCurrencyToken >= targetCCYLiquidity || _reserveCurrencyToken >= factoryTargetCCYLiquidity,
            "Bootstrap end-criterion not reached"
        );
        bootstrapPool.kill();

        // Determine liquidity amount to add
--      uint256 currencyAmount = currencyToken.balanceOf(address(this));
++      uint256 currencyAmount = _reserveCurrencyToken;
        uint256 liquidityAmount = (currencyAmount * 1e18) / price;

        // Add liquidity to Fraxswap
        IFraxswapPair fraxswapPair = addLiquidityToFraxswap(liquidityAmount, currencyAmount);

        // Send all remaining tokens to the agent.
        agentToken.safeTransfer(address(agent), agentToken.balanceOf(address(this)));
        currencyToken.safeTransfer(address(agent), currencyToken.balanceOf(address(this)));
        emit LiquidityMoved(agent, address(agentToken), address(fraxswapPair));

        AgentFactory(owner).setAgentStage(agent, 1);
    }
```