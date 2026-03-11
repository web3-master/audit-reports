## Title
Wrong calculation in MoeLens.

## Brief/Intro
MoeLens.getVeMoeData() function's maxVeMoe calcuation is wrong.

## Vulnerability Details
MoeLens.getVeMoeData() function is as follows.
```
File: MoeLens.sol
392:     function getVeMoeData(uint256 start, uint256 nb, address user) public view returns (VeMoeData memory data) {
393:         uint256 nbFarms = _masterchef.getNumberOfFarms();
394: 
395:         nb = start >= nbFarms ? 0 : (start + nb > nbFarms ? nbFarms - start : nb);
396: 
397:         uint256 balance = _veMoe.balanceOf(user);
398: 
399:         data = VeMoeData({
400:             moeStakingAddress: address(_moeStaking),
401:             veMoeAddress: address(_veMoe),
402:             totalVotes: _veMoe.getTotalVotes(),
403:             totalWeight: _veMoe.getTotalWeight(),
404:             alpha: _veMoe.getAlpha(),
405:             maxVeMoe: balance * _veMoe.getMaxVeMoePerMoe() / Constants.PRECISION,
406:             veMoePerSecondPerMoe: _veMoe.getVeMoePerSecondPerMoe(),
407:             topPoolsIds: _veMoe.getTopPoolIds(),
408:             votes: new Vote[](nb),
409:             userTotalVeMoe: balance,
410:             userTotalVotes: _veMoe.getTotalVotesOf(user)
411:         });
412: 
413:         for (uint256 i; i < nb; ++i) {
414:             try this.getVeMoeDataAt(start + i, user) returns (Vote memory vote) {
415:                 data.votes[i] = vote;
416:             } catch {}
417:         }
```
L405's calculation is wrong.
`maxVeMoe` value should be multiplication of current moe staking value and `_maxVeMoePerMoe` but now it used current veMoe balance in calculation, which is wrong.

L405 should be fixed as follows.
```
maxVeMoe: _moeStaking.getDeposit(user) * _veMoe.getMaxVeMoePerMoe() / Constants.PRECISION,
```

## Impact Details
I think MoeLens will be used generally in web3 frontend of the MerchantMoe service.
That means, all users will see invalid max ve moe value in their web page.
Or in worse case, MoeLens might be used as interface to other contracts or services. In this case, the impact might be more serious.

## References
https://github.com/merchant-moe/moe-core/blob/f567b2cdee5b1a5024b185462599498fdafa591e/src/MoeLens.sol#L405


## Proof of Concept
This is unit test code.
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../src/transparent/TransparentUpgradeableProxy2Step.sol";
import "../src/VeMoe.sol";
import "../src/MoeStaking.sol";
import "../src/Moe.sol";
import "../src/MasterChef.sol";
import "../src/rewarders/VeMoeRewarder.sol";
import "../src/rewarders/RewarderFactory.sol";
import "./mocks/MockNoRevert.sol";
import "./mocks/MockERC20.sol";
import "../src/MoeLens.sol";

contract VeMoeTest is Test {
    MoeStaking staking;
    Moe moe;
    VeMoe veMoe;
    MasterChef masterChef;
    RewarderFactory factory;
    MoeLens moeLens;

    IERC20 token18d;
    IERC20 token6d;

    VeMoeRewarder bribes0;
    VeMoeRewarder bribes0Bis;
    VeMoeRewarder bribes1;

    address sMoe;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        moe = new Moe(address(this), 0, Constants.MAX_SUPPLY);
        token18d = new MockERC20("18d", "18d", 18);
        token6d = new MockERC20("6d", "6d", 6);

        sMoe = address(new MockNoRevert());

        uint256 nonce = vm.getNonce(address(this));

        address stakingAddress = computeCreateAddress(address(this), nonce);
        address masterChefAddress = computeCreateAddress(address(this), nonce + 3);
        address veMoeAddress = computeCreateAddress(address(this), nonce + 4);
        address factoryAddress = computeCreateAddress(address(this), nonce + 6);
        
        staking = new MoeStaking(moe, IVeMoe(veMoeAddress), IStableMoe(sMoe));
        masterChef = new MasterChef(moe, IVeMoe(veMoeAddress), IRewarderFactory(factoryAddress), address(0), 0);
        veMoe = new VeMoe(
            IMoeStaking(stakingAddress), IMasterChef(masterChefAddress), IRewarderFactory(factoryAddress), 100e18
        );

        TransparentUpgradeableProxy2Step masterChefProxy = new TransparentUpgradeableProxy2Step(
            address(masterChef),
            ProxyAdmin2Step(address(1)),
            abi.encodeWithSelector(
                MasterChef.initialize.selector, address(this), address(this), address(this), address(this), 0, 0
            )
        );

        TransparentUpgradeableProxy2Step veMoeProxy = new TransparentUpgradeableProxy2Step(
            address(veMoe),
            ProxyAdmin2Step(address(1)),
            abi.encodeWithSelector(VeMoe.initialize.selector, address(this))
        );

        veMoe = VeMoe(address(veMoeProxy));
        masterChef = MasterChef(address(masterChefProxy));

        address factoryImpl = address(new RewarderFactory());
        factory = RewarderFactory(
            address(
                new TransparentUpgradeableProxy2Step(
                    factoryImpl,
                    ProxyAdmin2Step(address(1)),
                    abi.encodeWithSelector(
                        RewarderFactory.initialize.selector, address(this), new uint8[](0), new address[](0)
                    )
                )
            )
        );
        factory.setRewarderImplementation(
            IRewarderFactory.RewarderType.VeMoeRewarder, new VeMoeRewarder(address(veMoe))
        );

        bribes0 = VeMoeRewarder(
            payable(address(factory.createRewarder(IRewarderFactory.RewarderType.VeMoeRewarder, token18d, 0)))
        );
        bribes0Bis = VeMoeRewarder(
            payable(address(factory.createRewarder(IRewarderFactory.RewarderType.VeMoeRewarder, token18d, 0)))
        );
        bribes1 = VeMoeRewarder(
            payable(address(factory.createRewarder(IRewarderFactory.RewarderType.VeMoeRewarder, token6d, 1)))
        );

        assertEq(address(masterChef.getVeMoe()), address(veMoe), "setUp::1");

        masterChef.add(token18d, IMasterChefRewarder(address(0)));
        masterChef.add(token6d, IMasterChefRewarder(address(0)));

        moe.mint(alice, 100e18);
        moe.mint(bob, 100e18);

        vm.prank(alice);
        moe.approve(address(staking), type(uint256).max);

        vm.prank(bob);
        moe.approve(address(staking), type(uint256).max);

        //
        // Create MoeLens for testing.
        //
        moeLens = new MoeLens(IMasterChef(masterChef), IJoeStaking(address(0)), "");
    }

    function test_MoeLens_GetVeMoeData() public {
        veMoe.setVeMoePerSecondPerMoe(1e18);

        vm.prank(alice);
        staking.stake(1e18);

        vm.prank(bob);
        staking.stake(9e18);

        assertEq(veMoe.balanceOf(alice), 0, "test_OnModifyAndClaim::1");
        assertEq(veMoe.balanceOf(bob), 0, "test_OnModifyAndClaim::2");

        vm.warp(block.timestamp + 50);

        assertEq(veMoe.balanceOf(alice), 50e18, "test_OnModifyAndClaim::3");
        assertEq(veMoe.balanceOf(bob), 450e18, "test_OnModifyAndClaim::4");

        vm.prank(alice);
        staking.claim();

        assertEq(veMoe.balanceOf(alice), 50e18, "test_OnModifyAndClaim::5");
        assertEq(veMoe.balanceOf(bob), 450e18, "test_OnModifyAndClaim::6");

        vm.warp(block.timestamp + 25);

        veMoe.setVeMoePerSecondPerMoe(1e18);

        assertEq(veMoe.balanceOf(alice), 75e18, "test_OnModifyAndClaim::7");
        assertEq(veMoe.balanceOf(bob), 675e18, "test_OnModifyAndClaim::8");

        vm.prank(bob);
        veMoe.claim(new uint256[](10));

        assertEq(veMoe.balanceOf(alice), 75e18, "test_OnModifyAndClaim::9");
        assertEq(veMoe.balanceOf(bob), 675e18, "test_OnModifyAndClaim::10");

        vm.warp(block.timestamp + 25);

        assertEq(veMoe.balanceOf(alice), 100e18, "test_OnModifyAndClaim::11");
        assertEq(veMoe.balanceOf(bob), 900e18, "test_OnModifyAndClaim::12");

        vm.warp(block.timestamp + 1);

        assertEq(veMoe.balanceOf(alice), 100e18, "test_OnModifyAndClaim::13");
        assertEq(veMoe.balanceOf(bob), 900e18, "test_OnModifyAndClaim::14");

        //
        // Get VeMoeData from MoeLens.
        //
        MoeLens.VeMoeData memory veMoeData = moeLens.getVeMoeData(0, 0, alice);
        // console.log(veMoe.balanceOf(alice));     // 100000000000000000000 = 1e20
        // console.log(staking.getDeposit(alice));  // 1000000000000000000 = 1e18
        // console.log(veMoe.getMaxVeMoePerMoe());  // 100000000000000000000 = 1e20
        assertEq(veMoeData.maxVeMoe, staking.getDeposit(alice) * veMoe.getMaxVeMoePerMoe() / 1e18); // This is correct logic, that should be passed!!
        // assertEq(veMoeData.maxVeMoe, veMoe.balanceOf(alice) * veMoe.getMaxVeMoePerMoe() / 1e18); // This is incorrect logic, that is being passed!!
    }
}

contract MaliciousBribe {
    IVeMoe public immutable veMoe;

    constructor(IVeMoe _veMoe) {
        veMoe = _veMoe;
    }

    function onModify(address, uint256 pid, uint256 oldBalance, uint256, uint256) external returns (uint256) {
        if (oldBalance == 0) return 0;

        uint256[] memory pids = new uint256[](1);
        IVeMoeRewarder[] memory bribes = new IVeMoeRewarder[](1);

        pids[0] = pid;
        bribes[0] = IVeMoeRewarder(address(this));

        veMoe.setBribes(pids, bribes);

        return 0;
    }

    fallback() external {}
}

contract BadBribes {
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    fallback() external {
        if (shouldRevert) revert();
        assembly {
            mstore(0, 0)
            return(0, 32)
        }
    }
}
```

To run this test code, please run
```
forge test -vvvv --match-test test_MoeLens_GetVeMoeData
```