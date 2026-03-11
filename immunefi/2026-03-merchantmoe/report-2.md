## Title
Blacklisted USDC token owner will lose his Moe and can't claim other non blacklisted reward tokens permanently as well.

## Brief/Intro
USDC token has banned address feature, that any banned address can't receive USDC.
If StableMoe has USDC as a reward token and a legitimate MerchantMoe user who is a banned USDC user stakes his legitimate Moe into MoeStaking,
1. he losses his staked Moe permanently.
2. If StableMoe has other reward tokens, he can't claim these non USDC reward tokens as well.  

## Vulnerability Details
`MoeStaking.unstake()` function follows this call stack.
```
MoeStaking.unstake()
    -> MoeStaking._modify()                     : MoeStaking.sol#L95
        -> StableMoe.onModify()                 : MoeStaking.sol#L118
            -> StableMoe._claim()               : StableMoe.sol#L136
                -> StableMoe._safeTransferTo()  : StableMoe.sol#L230
                    -> token.safeTransfer()     : StableMoe.sol#L249
```
MoeStaking.claim()'s call stack is similar, too.
If token is USDC and moe staker is banned, then `token.safeTransfer()` will fail in StableMoe.sol#L249.
1. This means `MoeStaking.unstake()` function call always fails, and he losses his staked Moe permanently.
2. And if StableMoe has other non USDC reward tokens as well, then moe staker losses all these rewards permanently.

## Impact Details
If StableMoe has USDC as a reward token and,
if a moe staker is banned in USDC and,
if he staked some moe into MoeStaking for rewarding then;
1. He losses his staked Moe permanently.
2. And if StableMoe has other non USDC reward tokens as well, then moe staker losses all these rewards permanently.

## References
https://github.com/merchant-moe/moe-core/blob/f567b2cdee5b1a5024b185462599498fdafa591e/src/StableMoe.sol#L230

## Proof of Concept
This is unit test code.
```
File: StableMoe.t.sol
01: // SPDX-License-Identifier: MIT
02: pragma solidity ^0.8.20;
03: 
04: import "forge-std/Test.sol";
05: 
06: import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
07: import "../src/transparent/TransparentUpgradeableProxy2Step.sol";
08: 
09: import "../src/StableMoe.sol";
10: import "../src/MoeStaking.sol";
11: import "../src/Moe.sol";
12: import "./mocks/MockNoRevert.sol";
13: import "./mocks/MockERC20.sol";
14: import "./mocks/MockUSDC.sol";
15: 
16: contract StableMoeTest is Test {
17:     MoeStaking staking;
18:     Moe moe;
19:     StableMoe sMoe;
20: 
21:     address veMoe;
22: 
23:     IERC20 mockUSDC;
24:     IERC20 mockUSDT;
25: 
26:     address alice = makeAddr("alice");
27: 
28:     function setUp() public {
29:         moe = new Moe(address(this), 0, Constants.MAX_SUPPLY);
30:         mockUSDC = new MockUSDC("Mock USDC", "mUSDC", 6, alice);    // alice has been banned for testing.
31:         mockUSDT = new MockERC20("USDT", "mUSDT", 6);
32: 
33:         veMoe = address(new MockNoRevert());
34: 
35:         uint256 nonce = vm.getNonce(address(this));
36: 
37:         address stakingAddress = computeCreateAddress(address(this), nonce);
38:         address sMoeAddress = computeCreateAddress(address(this), nonce + 2);
39: 
40:         staking = new MoeStaking(moe, IVeMoe(veMoe), IStableMoe(sMoeAddress));
41:         sMoe = new StableMoe(IMoeStaking(stakingAddress));
42: 
43:         TransparentUpgradeableProxy2Step proxy = new TransparentUpgradeableProxy2Step(
44:             address(sMoe),
45:             ProxyAdmin2Step(address(1)),
46:             abi.encodeWithSelector(StableMoe.initialize.selector, address(this))
47:         );
48: 
49:         sMoe = StableMoe(payable(address(proxy)));
50: 
51:         assertEq(address(staking.getSMoe()), address(sMoe), "setUp::1");
52: 
53:         moe.mint(alice, 100e18);
54: 
55:         vm.prank(alice);
56:         moe.approve(address(staking), type(uint256).max);
57:     }
58: 
59:     function test_BlackListedStaker_LossMoe_Permanently() public {
60:         sMoe.addReward(mockUSDC);
61: 
62:         vm.prank(alice);
63:         staking.stake(1e18);
64: 
65:         MockERC20(address(mockUSDC)).mint(address(sMoe), 100e18);
66: 
67:         vm.prank(alice);
68:         vm.expectRevert();
69:         staking.unstake(1e18);
70:     }
71: 
72:     function test_BlackListedStaker_CantClaim_NonBlackListedRewardTokens() public {
73:         sMoe.addReward(mockUSDC);
74:         sMoe.addReward(mockUSDT);
75: 
76:         vm.prank(alice);
77:         staking.stake(1e18);
78: 
79:         MockERC20(address(mockUSDC)).mint(address(sMoe), 100e18);
80:         MockERC20(address(mockUSDT)).mint(address(sMoe), 100e18);
81: 
82:         vm.prank(alice);
83:         
84:         (IERC20[] memory aliceTokens, uint256[] memory aliceRewards) = sMoe.getPendingRewards(alice);
85: 
86:         emit log_named_uint("Alice's USDC balance:", aliceRewards[0]);
87:         emit log_named_uint("Alice's USDT balance:", aliceRewards[1]);
88: 
89:         vm.prank(alice);
90:         vm.expectRevert();
91:         staking.claim();
92:     }
93: }
94: 

File: MockUSDC.sol
01: // SPDX-License-Identifier: MIT
02: pragma solidity ^0.8.0;
03: 
04: import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
05: 
06: contract MockUSDC is ERC20 {
07:     uint8 private immutable _decimals;
08:     address public immutable BANNED_ADDRESS;
09: 
10:     constructor(string memory name, string memory symbol, uint8 decimals_, address bannedAddress) ERC20(name, symbol) {
11:         _decimals = decimals_;
12:         BANNED_ADDRESS = bannedAddress;
13:     }
14: 
15:     function decimals() public view override returns (uint8) {
16:         return _decimals;
17:     }
18: 
19:     function mint(address account, uint256 amount) external {
20:         _mint(account, amount);
21:     }
22:     
23:     /**
24:      * This function simulates blacklist feature for test.
25:      */
26:     function transfer(address to, uint256 value) public virtual override returns (bool) {
27:         if (to == BANNED_ADDRESS) {
28:             return false;
29:         }
30: 
31:         address owner = _msgSender();
32:         _transfer(owner, to, value);
33:         return true;
34:     }
35: }
36: 

```

To run these test codes, please run
```
forge test -vvvv --match-test test_BlackListedStaker_LossMoe_Permanently
forge test -vvvv --match-test test_BlackListedStaker_CantClaim_NonBlackListedRewardTokens
```