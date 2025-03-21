| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-curatorrewardsdistributorsoldistribute-may-dos) | `CuratorRewardsDistributor.sol#distribute()` may DOS. |
| [M-01](#m-01-phifactory-does-not-refund-excess-eth-to-the-user-when-createart) | `PhiFactory` does not refund excess `eth` to the user when `createArt`. |

# [H-01] `CuratorRewardsDistributor.sol#distribute()` may DOS.
## Impact
`CuratorRewardsDistributor.sol#distribute()` may DOS.

## Proof of Concept
`CuratorRewardsDistributor.sol#distribute()` function is as follows.
```
    function distribute(uint256 credId) external {
        if (!credContract.isExist(credId)) revert InvalidCredId();
        uint256 totalBalance = balanceOf[credId];
        if (totalBalance == 0) {
            revert NoBalanceToDistribute();
        }

        address[] memory distributeAddresses = credContract.getCuratorAddresses(credId, 0, 0);
        uint256 totalNum;

        for (uint256 i = 0; i < distributeAddresses.length; i++) {
            totalNum += credContract.getShareNumber(credId, distributeAddresses[i]);
        }

        if (totalNum == 0) {
            revert NoSharesToDistribute();
        }

        uint256[] memory amounts = new uint256[](distributeAddresses.length);
        bytes4[] memory reasons = new bytes4[](distributeAddresses.length);

        uint256 royaltyfee = (totalBalance * withdrawRoyalty) / RATIO_BASE;
        uint256 distributeAmount = totalBalance - royaltyfee;

        // actualDistributeAmount is used to avoid rounding errors
        // amount[0] = 333 333 333 333 333 333
        // amount[1] = 333 333 333 333 333 333
        // amount[2] = 333 333 333 333 333 333
        uint256 actualDistributeAmount = 0;
        for (uint256 i = 0; i < distributeAddresses.length; i++) {
            address user = distributeAddresses[i];

            uint256 userAmounts = credContract.getShareNumber(credId, user);
            uint256 userRewards = (distributeAmount * userAmounts) / totalNum;

            if (userRewards > 0) {
                amounts[i] = userRewards;
                actualDistributeAmount += userRewards;
            }
        }

        balanceOf[credId] -= totalBalance;

        _msgSender().safeTransferETH(royaltyfee + distributeAmount - actualDistributeAmount);

        //slither-disable-next-line arbitrary-send-eth
        phiRewardsContract.depositBatch{ value: actualDistributeAmount }(
            distributeAddresses, amounts, reasons, "deposit from curator rewards distributor"
        );

        emit RewardsDistributed(
            credId, _msgSender(), royaltyfee + distributeAmount - actualDistributeAmount, distributeAmount, totalBalance
        );
    }
```
If the number of curators of a `credId` is big, this transaction may dos because of gas limit.    
On the other hand, there is no upper limit of the number of curators for a `credId`.   

## Lines of code
- ./src/reward/CuratorRewardsDistributor.sol
- ./src/Cred.sol

## Tool used
Manual Review

## Recommended Mitigation Steps
Mitigation steps for this vulnerability are as follows.
1. Set maximum count for the number of curators for a `credId` in `Cred.sol`.
2. Set minimum amount for result share of `curator` when buying and selling cred.

# [M-01] `PhiFactory` does not refund excess `eth` to the user when `createArt`.
## Impact
`PhiFactory` does not refund excess `eth` to the user, so the user lose funds.

## Proof of Concept
`PhiFactory.sol#createArt()` function is as follows.
```
    function createArt(
        bytes calldata signedData_,
        bytes calldata signature_,
        CreateConfig memory createConfig_
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (address)
    {
        _validateArtCreationSignature(signedData_, signature_);
        (, string memory uri_, bytes memory credData) = abi.decode(signedData_, (uint256, string, bytes));
        ERC1155Data memory erc1155Data = _createERC1155Data(artIdCounter, createConfig_, uri_, credData);
210@>   address artAddress = createERC1155Internal(artIdCounter, erc1155Data);
        artIdCounter++;
        return artAddress;
    }
```
And `createERC1155Internal()` function which is called on L210 is as follows.
```
    function createERC1155Internal(uint256 newArtId, ERC1155Data memory createData_) internal returns (address) {
        // Todo check if artid exists, if artid exists, reverts
        _validateArtCreation(createData_);
        PhiArt storage currentArt = arts[newArtId];
        _initializePhiArt(currentArt, createData_);

        (uint256 credId,, string memory verificationType, uint256 credChainId,) =
            abi.decode(createData_.credData, (uint256, address, string, uint256, bytes32));

        address artAddress;
        if (credNFTContracts[credChainId][credId] == address(0)) {
@>          artAddress = _createNewNFTContract(currentArt, newArtId, createData_, credId, credChainId, verificationType);
        } else {
@>          artAddress = _useExistingNFTContract(currentArt, newArtId, createData_, credId, credChainId);
        }

        return artAddress;
    }
```
Here, `_createNewNFTContract(), _useExistingNFTContract()` functions are as follows.
```
    function _createNewNFTContract(
        PhiArt storage art,
        uint256 newArtId,
        ERC1155Data memory createData_,
        uint256 credId,
        uint256 credChainId,
        string memory verificationType
    )
        private
        returns (address)
    {
        address payable newArt =
            payable(erc1155ArtAddress.cloneDeterministic(keccak256(abi.encodePacked(block.chainid, newArtId, credId))));

        art.artAddress = newArt;

        IPhiNFT1155Ownable(newArt).initialize(credChainId, credId, verificationType, protocolFeeDestination);

        credNFTContracts[credChainId][credId] = address(newArt);

        (bool success_, bytes memory response) =
@>          newArt.call{ value: msg.value }(abi.encodeWithSignature("createArtFromFactory(uint256)", newArtId));

        if (!success_) revert CreateFailed();
        uint256 tokenId = abi.decode(response, (uint256));
        emit ArtContractCreated(createData_.artist, address(newArt), credId);
        emit NewArtCreated(createData_.artist, credId, credChainId, newArtId, createData_.uri, address(newArt), tokenId);

        return address(newArt);
    }
    function _useExistingNFTContract(
        PhiArt storage art,
        uint256 newArtId,
        ERC1155Data memory createData_,
        uint256 credId,
        uint256 credChainId
    )
        private
        returns (address)
    {
        address existingArt = credNFTContracts[credChainId][credId];
        art.artAddress = existingArt;
        (bool success_, bytes memory response) =
@>          existingArt.call{ value: msg.value }(abi.encodeWithSignature("createArtFromFactory(uint256)", newArtId));

        if (!success_) revert CreateFailed();
        uint256 tokenId = abi.decode(response, (uint256));
        emit NewArtCreated(createData_.artist, credId, credChainId, newArtId, createData_.uri, existingArt, tokenId);

        return existingArt;
    }
```
And `PhiNFT1155.sol#createArtFromFactory()` function is as follows.
```
    function createArtFromFactory(uint256 artId_) external payable onlyPhiFactory whenNotPaused returns (uint256) {
        _artIdToTokenId[artId_] = tokenIdCounter;
        _tokenIdToArtId[tokenIdCounter] = artId_;

        uint256 artFee = phiFactoryContract.artCreateFee();

        protocolFeeDestination.safeTransferETH(artFee);
        emit ArtCreated(artId_, tokenIdCounter);
        uint256 createdTokenId = tokenIdCounter;

        unchecked {
            tokenIdCounter += 1;
        }
        if ((msg.value - artFee) > 0) {
152@>       _msgSender().safeTransferETH(msg.value - artFee);
        }

        return createdTokenId;
    }
```
As se can see on L152, it transfers excess eth to `PhiFactory`.   
But `PhiFactory` does not transfer that to the user.

## Lines of code
- ./src/PhiFactory.sol
- ./src/art/PhiNFT1155.sol

## Tool used
Manual Review

## Recommended Mitigation Steps
`PhiFactory.sol#createArt()` function has to be modified as follows.
```
    function createArt(
        bytes calldata signedData_,
        bytes calldata signature_,
        CreateConfig memory createConfig_
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (address)
    {
        _validateArtCreationSignature(signedData_, signature_);
        (, string memory uri_, bytes memory credData) = abi.decode(signedData_, (uint256, string, bytes));
        ERC1155Data memory erc1155Data = _createERC1155Data(artIdCounter, createConfig_, uri_, credData);
+       uint256 prevBalance = address(this).balance - msg.value;
        address artAddress = createERC1155Internal(artIdCounter, erc1155Data);
        artIdCounter++;
+       uint256 excessAmount = address(this).balance - prevBalance;
+       if(excessAmount > 0){
+           _msgSender().safeTransferETH(excessAmount);
+       }
        return artAddress;
    }
```