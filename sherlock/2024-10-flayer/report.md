| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-user-can-pay-less-protected-listing-fees) | User can pay less protected listing fees. |
| [H-02](#h-02-user-can-unlock-protected-listing-without-paying-any-fee) | User can unlock protected listing without paying any fee. |
| [H-03](#h-03-taxcalculatorcalculatecompoundedfactor-function-inflate-the-compounded-factor-by-10-times) | `TaxCalculator.calculateCompoundedFactor()` function inflate the compounded factor by 10 times. |
| [H-04](#h-04-attacker-can-lock-all-ethers-after-shutdown-executed-and-collection-liquidation-completed) | Attacker can lock all ethers after shutdown executed and collection liquidation completed. |
| [H-05](#h-05-listingsrelist-function-doesnt-set-listingcreated-as-blocktimestamp) | `Listings.relist()` function doesn't set `listing.created` as `block.timestamp`. |
| [H-06](#h-06-user-can-avoid-protected-listing-fee) | User can avoid protected listing fee. |
| [H-07](#h-07-attacker-can-take-out-users-repaid-protected-listing-nft-with-only-1-ether) | Attacker can take out user's repaid protected listing NFT with only `1 ether`. |
| [H-08](#h-08-attacker-can-lock-shutdown-voters-collectiontokens-forever) | Attacker can lock shutdown voters' collectionTokens forever. |
| [M-01](#m-01-attacker-can-disable-collectionshutdownpreventshutdown-function) | Attacker can disable `CollectionShutdown.preventShutdown()` function. |
| [M-02](#m-02-user-may-lose-fund-when-modify-listings) | User may lose fund when modify listings. |
| [M-03](#m-03-beneficiary-will-lose-unclaimed-fees) | Beneficiary will lose unclaimed fees. |


# [H-01] User can pay less protected listing fees.
## Summary
`ProtectedListings.unlockProtectedListing()` function create checkpoint after decrease `listingCount[_collection]`.
Therefore, when user unlock multiple protected listings, user will pay less fees for the second and thereafter listings than the first listing.

## Vulnerability Detail
`ProtectedListings.unlockProtectedListing()` function is following.
```solidity
    function unlockProtectedListing(address _collection, uint _tokenId, bool _withdraw) public lockerNotPaused {
        // Ensure this is a protected listing
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];

        // Ensure the caller owns the listing
        if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

        // Ensure that the protected listing has run out of collateral
        int collateral = getProtectedListingHealth(_collection, _tokenId);
        if (collateral < 0) revert InsufficientCollateral();

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);
        uint denomination = collectionToken.denomination();
        uint96 tokenTaken = _protectedListings[_collection][_tokenId].tokenTaken;

        // Repay the loaned amount, plus a fee from lock duration
        uint fee = unlockPrice(_collection, _tokenId) * 10 ** denomination;
        collectionToken.burnFrom(msg.sender, fee);

        // We need to burn the amount that was paid into the Listings contract
        collectionToken.burn((1 ether - tokenTaken) * 10 ** denomination);

        // Remove our listing type
311:    unchecked { --listingCount[_collection]; }

        // Delete the listing objects
        delete _protectedListings[_collection][_tokenId];

        // Transfer the listing ERC721 back to the user
        if (_withdraw) {
            locker.withdrawToken(_collection, _tokenId, msg.sender);
            emit ListingAssetWithdraw(_collection, _tokenId);
        } else {
            canWithdrawAsset[_collection][_tokenId] = msg.sender;
        }

        // Update our checkpoint to reflect that listings have been removed
325:    _createCheckpoint(_collection);

        // Emit an event
        emit ListingUnlocked(_collection, _tokenId, fee);
    }
```
As can be seen, the above function decrease `listingCount[_collection]` in `L311` before creating checkpoint in `L325`.
However, creating checkpoint uses utilization rate and the utilization rate depends on `listingCount[_collection]`.
Since `listingCount[_collection]` is already decreased at `L311`, the utilization rate is calculated incorrect and so the checkpoint will be incorrect.

PoC:
Add the following test code into `ProtectedListings.t.sol`.
```solidity
    function test_unlockProtectedListingError() public {
        erc721a.mint(address(this), 0);
        erc721a.mint(address(this), 1);
        
        erc721a.setApprovalForAll(address(protectedListings), true);

        uint[] memory _tokenIds = new uint[](2); _tokenIds[0] = 0; _tokenIds[1] = 1;

        // create protected listing for tokenId = 0 and tokenId = 1
        IProtectedListings.CreateListing[] memory _listings = new IProtectedListings.CreateListing[](1);
        _listings[0] = IProtectedListings.CreateListing({
            collection: address(erc721a),
            tokenIds: _tokenIds,
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.4 ether,
                checkpoint: 0
            })
        });
        protectedListings.createListings(_listings);

        vm.warp(block.timestamp + 7 days);

        // unlock protected listing for tokenId = 0
        assertEq(protectedListings.unlockPrice(address(erc721a), 0), 402485479451875840);
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), 402485479451875840);
        protectedListings.unlockProtectedListing(address(erc721a), 0, true);

        // unlock protected listing for tokenId = 0, but the unlock price for tokenId = 1 is 402055890410801920 < 402485479451875840 for tokenId = 0.
        assertEq(protectedListings.unlockPrice(address(erc721a), 1), 402055890410801920);
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), 402055890410801920);
        protectedListings.unlockProtectedListing(address(erc721a), 1, true);
    }
```
In the above test code, we can see that user paid less fees for tokenId = 1 than tokenId = 0.

## Impact
Users will pay less fees. It meanas loss of funds for the protocol.

## Code Snippet
- [ProtectedListings.unlockProtectedListing()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/ProtectedListings.sol#L287-L329)

## Tool used
Manual Review

## Recommendation
Change the order of decreasing `listingCount[_collection]` and creating checkpoint in `ProtectedListings.unlockProtectedListing()` function as follows.
```solidity
    function unlockProtectedListing(address _collection, uint _tokenId, bool _withdraw) public lockerNotPaused {
        // Ensure this is a protected listing
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];

        // Ensure the caller owns the listing
        if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

        // Ensure that the protected listing has run out of collateral
        int collateral = getProtectedListingHealth(_collection, _tokenId);
        if (collateral < 0) revert InsufficientCollateral();

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);
        uint denomination = collectionToken.denomination();
        uint96 tokenTaken = _protectedListings[_collection][_tokenId].tokenTaken;

        // Repay the loaned amount, plus a fee from lock duration
        uint fee = unlockPrice(_collection, _tokenId) * 10 ** denomination;
        collectionToken.burnFrom(msg.sender, fee);

        // We need to burn the amount that was paid into the Listings contract
        collectionToken.burn((1 ether - tokenTaken) * 10 ** denomination);

        // Remove our listing type
--      unchecked { --listingCount[_collection]; }

        // Delete the listing objects
        delete _protectedListings[_collection][_tokenId];

        // Transfer the listing ERC721 back to the user
        if (_withdraw) {
            locker.withdrawToken(_collection, _tokenId, msg.sender);
            emit ListingAssetWithdraw(_collection, _tokenId);
        } else {
            canWithdrawAsset[_collection][_tokenId] = msg.sender;
        }

        // Update our checkpoint to reflect that listings have been removed
        _createCheckpoint(_collection);
++      unchecked { --listingCount[_collection]; }

        // Emit an event
        emit ListingUnlocked(_collection, _tokenId, fee);
    }
```

# [H-02] User can unlock protected listing without paying any fee.
## Summary
`ProtectedListings.adjustPosition()` function adjust `listing.tokenTaken` without considering compounded factor. Exploiting this vulnerability, user can unlock protected listing without paying any fee.

## Vulnerability Detail
`ProtectedListings.adjustPosition()` function is following.
```solidity
    function adjustPosition(address _collection, uint _tokenId, int _amount) public lockerNotPaused {
        // Ensure we don't have a zero value amount
        if (_amount == 0) revert NoPositionAdjustment();

        // Load our protected listing
        ProtectedListing memory protectedListing = _protectedListings[_collection][_tokenId];

        // Make sure caller is owner
        if (protectedListing.owner != msg.sender) revert CallerIsNotOwner(protectedListing.owner);

        // Get the current debt of the position
        int debt = getProtectedListingHealth(_collection, _tokenId);

        // Calculate the absolute value of our amount
        uint absAmount = uint(_amount < 0 ? -_amount : _amount);

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);

        // Check if we are decreasing debt
        if (_amount < 0) {
            // The user should not be fully repaying the debt in this way. For this scenario,
            // the owner would instead use the `unlockProtectedListing` function.
            if (debt + int(absAmount) >= int(MAX_PROTECTED_TOKEN_AMOUNT)) revert IncorrectFunctionUse();

            // Take tokens from the caller
            collectionToken.transferFrom(
                msg.sender,
                address(this),
                absAmount * 10 ** collectionToken.denomination()
            );

            // Update the struct to reflect the new tokenTaken, protecting from overflow
399:        _protectedListings[_collection][_tokenId].tokenTaken -= uint96(absAmount);
        }
        // Otherwise, the user is increasing their debt to take more token
        else {
            // Ensure that the user is not claiming more than the remaining collateral
            if (_amount > debt) revert InsufficientCollateral();

            // Release the token to the caller
            collectionToken.transfer(
                msg.sender,
                absAmount * 10 ** collectionToken.denomination()
            );

            // Update the struct to reflect the new tokenTaken, protecting from overflow
413:        _protectedListings[_collection][_tokenId].tokenTaken += uint96(absAmount);
        }

        emit ListingDebtAdjusted(_collection, _tokenId, _amount);
    }
```
As can be seen in `L399` and `L413`, `_protectedListings[_collection][_tokenId].tokenTaken` is updated without considering compounded factor. Exploiting this vulnerability, user can unlock protected listing without paying any fee.

PoC:
Add the following test code into `ProtectedListings.t.sol`.
```solidity
    function test_adjustPositionError() public {
        erc721a.mint(address(this), 0);
        
        erc721a.setApprovalForAll(address(protectedListings), true);

        uint[] memory _tokenIds = new uint[](2); _tokenIds[0] = 0; _tokenIds[1] = 1;

        IProtectedListings.CreateListing[] memory _listings = new IProtectedListings.CreateListing[](1);
        _listings[0] = IProtectedListings.CreateListing({
            collection: address(erc721a),
            tokenIds: _tokenIdToArray(0),
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.4 ether,
                checkpoint: 0
            })
        });
        protectedListings.createListings(_listings);

        vm.warp(block.timestamp + 7 days);

        // unlock protected listing for tokenId = 0
        assertEq(protectedListings.unlockPrice(address(erc721a), 0), 402055890410801920);
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), 0.4 ether);
        protectedListings.adjustPosition(address(erc721a), 0, -0.4 ether);
        assertEq(protectedListings.unlockPrice(address(erc721a), 0), 0);
        protectedListings.unlockProtectedListing(address(erc721a), 0, true);
    }
```
In the above test code, we can see that `unlockPrice(address(erc721a), 0)` is `402055890410801920`, but after calling `adjustPosition(address(erc721a), 0, -0.4 ether)`, `unlockPrice(address(erc721a), 0)` decreases to `0`. So we unlocked protected listing paying only `0.4 ether` without paying any fee.

## Impact
User can unlock protected listing without paying any fee. It means loss of funds for the protocol.
On the other hand, if user increase `tokenTaken` in `adjustPosition()` function, increasement of fee will be inflated by compounded factor. it means loss of funds for the user.

## Code Snippet
- [ProtectedListings.adjustPosition()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/ProtectedListings.sol#L366-L417)

## Tool used
Manual Review

## Recommendation
Adjust `tokenTaken` considering compounded factor in `ProtectedListings.adjustPosition()` function. That is, divide `absAmount` by compounded factor before updating `tokenTaken`.

# [H-03] `TaxCalculator.calculateCompoundedFactor()` function inflate the compounded factor by 10 times.
## Summary
`TaxCalculator.calculateCompoundedFactor()` function inflate the compounded factor by 10 times.

## Vulnerability Detail
`TaxCalculator.calculateCompoundedFactor()` function is the following.
```solidity
    function calculateCompoundedFactor(uint _previousCompoundedFactor, uint _utilizationRate, uint _timePeriod) public view returns (uint compoundedFactor_) {
        // Get our interest rate from our utilization rate
82:     uint interestRate = this.calculateProtectedInterest(_utilizationRate);

        // Ensure we calculate the compounded factor with correct precision. `interestRate` is
        // in basis points per annum with 1e2 precision and we convert the annual rate to per
        // second rate.
        uint perSecondRate = (interestRate * 1e18) / (365 * 24 * 60 * 60);

        // Calculate new compounded factor
90:     compoundedFactor_ = _previousCompoundedFactor * (1e18 + (perSecondRate / 1000 * _timePeriod)) / 1e18;
    }
```
The `calculateProtectedInterest()` function of `L82` is following. 
```solidity
    /**
     * Calculates the interest rate for Protected Listings based on the utilization rate
     * for the collection.
     *
     * This maps to a hockey puck style chart, with a slow increase until we reach our
     * kink, which will subsequently rapidly increase the interest rate.
     *
53:  * @dev The interest rate is returned to 2 decimal places (200 = 2%)
     *
     * @param _utilizationRate The utilization rate for the collection
     *
     * @return interestRate_ The annual interest rate for the collection
     */
    function calculateProtectedInterest(uint _utilizationRate) public pure returns (uint interestRate_) {
        // If we haven't reached our kink, then we can just return the base fee
        if (_utilizationRate <= UTILIZATION_KINK) {
            // Calculate percentage increase for input range 0 to 0.8 ether (2% to 8%)
            interestRate_ = 200 + (_utilizationRate * 600) / UTILIZATION_KINK;
        }
        // If we have passed our kink value, then we need to calculate our additional fee
        else {
            // Convert value in the range 0.8 to 1 to the respective percentage between 8% and
            // 100% and make it accurate to 2 decimal places.
            interestRate_ = (((_utilizationRate - UTILIZATION_KINK) * (100 - 8)) / (1 ether - UTILIZATION_KINK) + 8) * 100;
        }
    }
```
As can be seen, the above function returns `10000` for `100%`. It can also be verified in the comments of `L53`. But in `L90`, the function divides the `perSecondRate` by `1000` instead of `10_000`, and thus inflate the compounded factor by 10.

## Impact
Users will pay 10 times more tax than they should. It means Loss of funds.

## Code Snippet
- [TaxCalculator.calculateCompoundedFactor()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/TaxCalculator.sol#L80-L91)

## Tool used
Manual Review

## Recommendation
Modify `TaxCalculator.calculateCompoundedFactor()` function as below.
```solidity
    function calculateCompoundedFactor(uint _previousCompoundedFactor, uint _utilizationRate, uint _timePeriod) public view returns (uint compoundedFactor_) {
        // Get our interest rate from our utilization rate
        uint interestRate = this.calculateProtectedInterest(_utilizationRate);

        // Ensure we calculate the compounded factor with correct precision. `interestRate` is
        // in basis points per annum with 1e2 precision and we convert the annual rate to per
        // second rate.
        uint perSecondRate = (interestRate * 1e18) / (365 * 24 * 60 * 60);

        // Calculate new compounded factor
--      compoundedFactor_ = _previousCompoundedFactor * (1e18 + (perSecondRate / 1000 * _timePeriod)) / 1e18;
++      compoundedFactor_ = _previousCompoundedFactor * (1e18 + (perSecondRate * _timePeriod / 10000)) / 1e18;
    }
```

# [H-04] Attacker can lock all ethers after shutdown executed and collection liquidation completed.
## Summary
When there are less than `MAX_SHUTDOWN_TOKENS` collection NFTs in the protocol, there will be shutdown vote. If totalSupply exceeds `MAX_SHUTDOWN_TOKENS`, after shutdown executed, attacker can cancel votes and lock all ethers into the contract forever.

## Vulnerability Detail
At first, the `CollectionShutdown.execute()` function is following.
```solidity
    function execute(address _collection, uint[] calldata _tokenIds) public onlyOwner whenNotPaused {
        // Ensure that the vote count has reached quorum
        CollectionShutdownParams storage params = _collectionParams[_collection];
        if (!params.canExecute) revert ShutdownNotReachedQuorum();

        // Ensure we have specified token IDs
        uint _tokenIdsLength = _tokenIds.length;
        if (_tokenIdsLength == 0) revert NoNFTsSupplied();

        // Check that no listings currently exist
        if (_hasListings(_collection)) revert ListingsExist();

        // Refresh total supply here to ensure that any assets that were added during
        // the shutdown process can also claim their share.
        uint newQuorum = params.collectionToken.totalSupply() * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT;
        if (params.quorumVotes != newQuorum) {
            params.quorumVotes = uint88(newQuorum);
        }

        // Lockdown the collection to prevent any new interaction
        locker.sunsetCollection(_collection);

        // Iterate over our token IDs and transfer them to this contract
        IERC721 collection = IERC721(_collection);
        for (uint i; i < _tokenIdsLength; ++i) {
            locker.withdrawToken(_collection, _tokenIds[i], address(this));
        }

        // Approve sudoswap pair factory to use our NFTs
        collection.setApprovalForAll(address(pairFactory), true);

        // Map our collection to a newly created pair
        address pool = _createSudoswapPool(collection, _tokenIds);

        // Set the token IDs that have been sent to our sweeper pool
        params.sweeperPoolTokenIds = _tokenIds;
        sweeperPoolCollection[pool] = _collection;

        // Update our collection parameters with the pool
        params.sweeperPool = pool;

        // Prevent the collection from being executed again
273:    params.canExecute = false;
        emit CollectionShutdownExecuted(_collection, pool, _tokenIds);
    }
```
As can be seen, admin can execute shutdown vote even if totalSupply exceeds `MAX_SHUTDOWN_TOKENS`. Also, the above function change the `params.canExecute` to `false` in `L273` after shutdown executed.

Next, the `CollectionShutdown._vote()` function is following.
```solidity
    function _vote(address _collection, CollectionShutdownParams memory params) internal returns (CollectionShutdownParams memory) {
        // Take tokens from the user and hold them in this escrow contract
        uint userVotes = params.collectionToken.balanceOf(msg.sender);
        if (userVotes == 0) revert UserHoldsNoTokens();

        // Pull our tokens in from the user
        params.collectionToken.transferFrom(msg.sender, address(this), userVotes);

        // Register the amount of votes sent as a whole, and store them against the user
        params.shutdownVotes += uint96(userVotes);

        // Register the amount of votes for the collection against the user
        unchecked { shutdownVoters[_collection][msg.sender] += userVotes; }

        emit CollectionShutdownVote(_collection, msg.sender, userVotes);

        // If we can execute, then we need to fire another event
        if (!params.canExecute && params.shutdownVotes >= params.quorumVotes) {
209:        params.canExecute = true;
            emit CollectionShutdownQuorumReached(_collection);
        }

        return params;
    }
```
As can be seen, the above function doesn't check if vote has already executed, so attacker can vote using only 1 wei even after vote executed, and can change `params.canExecute` to `true` again in `L209`.
After that, attacker can call `CollectionShutdown.cancel()` function and delete `_collectionParams[_collection]` totally.

PoC:
1. Assume that `denomination` is 1 and totalSupplay of a collection are `MAX_SHUTDOWN_TOKENS = 4 ethers`.
2. Shutdown vote starts and the votes can execute since total votes are larger than quorum threshold.
3. TotalSupply increases again and exceeds `MAX_SHUTDOWN_TOKENS` for some reason.
4. Admin executes shutdown vote and transfer all NFTs of Locker to sweeper pool and swap them to ethers.
5. Attacker votes using only 1 wei collectionToken (which he can buy in uniswap pool) and change `params.canExecute` to `true` again.
6. Attacker calls `CollectionShutdown.cancel()` function and delete `_collectionParams[_collection]` totally.
7. After collection liquidation completed, all protocol users can't claim ethers for their collectionTokens because `_collectionParams[_collection]` is deleted.

## Impact
Attacker can lock all ethers using only 1 wei collectionToken after shutdownn executed and collection liquidation completed.
Here, not only voters but also other users can't claim ethers for their collectionToken holdings.

## Code Snippet
- [CollectionShutdown._vote()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/utils/CollectionShutdown.sol#L191-L214)

## Tool used
Manual Review

## Recommendation
Add check if vote has already executed into the `CollectionShutdown._vote()` function.

# [H-05] `Listings.relist()` function doesn't set `listing.created` as `block.timestamp`.
## Summary
`Listings.relist()` function doesn't set `listing.created` as `block.timestamp`.
It causes several serious problems to the user.

## Vulnerability Detail
`Listings.createListings()` function set `listing.created` as `block.timestamp` but the following `Listings.relist()` function doesn't set `listing.created` as `block.timestamp`.
```solidity
    function relist(CreateListing calldata _listing, bool _payTaxWithEscrow) public nonReentrant lockerNotPaused {
        // Load our tokenId
        address _collection = _listing.collection;
        uint _tokenId = _listing.tokenIds[0];

        // Read the existing listing in a single read
        Listing memory oldListing = _listings[_collection][_tokenId];

        // Ensure the caller is not the owner of the listing
        if (oldListing.owner == msg.sender) revert CallerIsAlreadyOwner();

        // Load our new Listing into memory
        Listing memory listing = _listing.listing;

        // Ensure that the existing listing is available
        (bool isAvailable, uint listingPrice) = getListingPrice(_collection, _tokenId);
        if (!isAvailable) revert ListingNotAvailable();

        // We can process a tax refund for the existing listing
        (uint _fees,) = _resolveListingTax(oldListing, _collection, true);
        if (_fees != 0) {
            emit ListingFeeCaptured(_collection, _tokenId, _fees);
        }

        // Find the underlying {CollectionToken} attached to our collection
        ICollectionToken collectionToken = locker.collectionToken(_collection);

        // If the floor multiple of the original listings is different, then this needs
        // to be paid to the original owner of the listing.
        uint listingFloorPrice = 1 ether * 10 ** collectionToken.denomination();
        if (listingPrice > listingFloorPrice) {
            unchecked {
                collectionToken.transferFrom(msg.sender, oldListing.owner, listingPrice - listingFloorPrice);
            }
        }

        // Validate our new listing
        _validateCreateListing(_listing);

        // Store our listing into our Listing mappings
665:    _listings[_collection][_tokenId] = listing;

        // Pay our required taxes
668:    payTaxWithEscrow(address(collectionToken), getListingTaxRequired(listing, _collection), _payTaxWithEscrow);

        // Emit events
        emit ListingRelisted(_collection, _tokenId, listing);
    }
```
As can be seen, the above function doesn't set `_listings[_collection][_tokenId].created` as `block.timestamp` in `L665`. Although the test codes of `Listings.t.sol` are setting `listing.created` as `block.timestamp` when calling `Listings.relist()` function, users can set `listing.created` arbitrarily when calling `Listings.relist()` function. 
Even in the case that user (or frontend) try to set `listing.created` as `block.timestamp`, since the user's tx will be stayed in mempool for unexpected period, `listing.created` will be different with `block.timestamp`. 

If `listing.created` is before than `block.timestamp`, user will lose part of tax required for relisting (which is paid in `L668`). If `listing.created` is much smaller than `block.timestamp`, user's NFT will be auctioned at low price as soon as it is relisted.
If `listing.created` is greater than `block.timestamp`, user's NFT can't be filled for a period from `block.timestamp` to `listing.created`.

## Impact
User will lose the tax required for relisting or user's NFT listing will be auctioned at low price. It means loss of funds.
User's NFT listing can't be filled for a period. It means lock of funds.

## Code Snippet
- [Listings.relist()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/Listings.sol#L625-L672)

## Tool used
Manual Review

## Recommendation
Modify `Listings.relist()` function as below.
```solidity
    function relist(CreateListing calldata _listing, bool _payTaxWithEscrow) public nonReentrant lockerNotPaused {
        --- SKIP ---

        // Load our new Listing into memory
        Listing memory listing = _listing.listing;
++      listing.created = block.timestamp;

        --- SKIP ---
    }
```

# [H-06] User can avoid protected listing fee.
## Summary
`ProtectedListings._createCheckpoint()` function returns incorrect index when the timestamp of last checkpoint is equal to `block.timestamp`. Exploiting this vulnerability, user can avoid protected listing fee.

## Vulnerability Detail
`ProtectedListings.createListings()` function is following.
```solidity
    function createListings(CreateListing[] calldata _createListings) public nonReentrant lockerNotPaused {
        // Loop variables
        uint checkpointIndex;
        bytes32 checkpointKey;
        uint tokensIdsLength;
        uint tokensReceived;

        // Loop over the unique listing structures
        for (uint i; i < _createListings.length; ++i) {
            // Store our listing for cheaper access
            CreateListing calldata listing = _createListings[i];

            // Ensure our listing will be valid
            _validateCreateListing(listing);

            // Update our checkpoint for the collection if it has not been done yet for
            // the listing collection.
            checkpointKey = keccak256(abi.encodePacked('checkpointIndex', listing.collection));
            assembly { checkpointIndex := tload(checkpointKey) }
            if (checkpointIndex == 0) {
137:            checkpointIndex = _createCheckpoint(listing.collection);
                assembly { tstore(checkpointKey, checkpointIndex) }
            }

            // Map our listings
            tokensIdsLength = listing.tokenIds.length;
            tokensReceived = _mapListings(listing, tokensIdsLength, checkpointIndex) * 10 ** locker.collectionToken(listing.collection).denomination();

            // Register our listing type
            unchecked {
                listingCount[listing.collection] += tokensIdsLength;
            }

            // Deposit the tokens into the locker and distribute ERC20 to user
            _depositNftsAndReceiveTokens(listing, tokensReceived);

            // Event fire
            emit ListingsCreated(listing.collection, listing.tokenIds, listing.listing, tokensReceived, msg.sender);
        }
    }
```
The above function get the last checkpoint index of the collection on `L137` and save it to calculate the compound factor in `unlockPrice()` function.
`ProtectedListings.createListings()` function is following.
```solidity
    function _createCheckpoint(address _collection) internal returns (uint index_) {
        // Determine the index that will be created
        index_ = collectionCheckpoints[_collection].length;

        // Register the checkpoint that has been created
        emit CheckpointCreated(_collection, index_);

        // If this is our first checkpoint, then our logic will be different as we won't have
        // a previous checkpoint to compare against and we don't want to underflow the index.
        if (index_ == 0) {
            // Calculate the current interest rate based on utilization
            (, uint _utilizationRate) = utilizationRate(_collection);

            // We don't have a previous checkpoint to calculate against, so we initiate our
            // first checkpoint with base data.
            collectionCheckpoints[_collection].push(
                Checkpoint({
                    compoundedFactor: locker.taxCalculator().calculateCompoundedFactor({
                        _previousCompoundedFactor: 1e18,
                        _utilizationRate: _utilizationRate,
                        _timePeriod: 0
                    }),
                    timestamp: block.timestamp
                })
            );

            return index_;
        }

        // Get our new (current) checkpoint
        Checkpoint memory checkpoint = _currentCheckpoint(_collection);

        // If no time has passed in our new checkpoint, then we just need to update the
        // utilization rate of the existing checkpoint.
        if (checkpoint.timestamp == collectionCheckpoints[_collection][index_ - 1].timestamp) {
            collectionCheckpoints[_collection][index_ - 1].compoundedFactor = checkpoint.compoundedFactor;
566:        return index_; // @audit index is out-of-bound of collectionCheckpoints[_collection]
        }

        // Store the new (current) checkpoint
        collectionCheckpoints[_collection].push(checkpoint);
    }
```
As can be seen in `L566`, the above function returns `last index of collectionCheckpoints[_collection]` + `1` when the timestamp of last checkpoint is equal to `block.timestamp`. Exploiting this vulnerability, user can avoid protected listing fee.

PoC:
Add the following test code into `ProtectedListings.t.sol`.
```solidity
    function test_CreateListingsError() public {
        erc721a.mint(address(this), 0);
        erc721a.mint(address(this), 1);
        
        erc721a.setApprovalForAll(address(protectedListings), true);
        erc721b.setApprovalForAll(address(protectedListings), true);

        // create listing for tokenId = 0
        IProtectedListings.CreateListing[] memory _listings = new IProtectedListings.CreateListing[](1);
        _listings[0] = IProtectedListings.CreateListing({
            collection: address(erc721a),
            tokenIds: _tokenIdToArray(0),
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.4 ether,
                checkpoint: 0
            })
        });
        protectedListings.createListings(_listings);

        // create listing for tokenId = 1 within the same block
        _listings[0].tokenIds = _tokenIdToArray(1);
        protectedListings.createListings(_listings);

        vm.warp(block.timestamp + 7 days);

        // unlock price for tokenId = 0 is increased.
        assertEq(protectedListings.unlockPrice(address(erc721a), 0), 402485479451875840);

        // ulockPrice() for tokenId = 1 will revert because of out-of-bound access.
        vm.expectRevert();
        protectedListings.unlockPrice(address(erc721a), 1);

        vm.startPrank(address(listings));
        protectedListings.createCheckpoint(address(erc721a));
        vm.stopPrank();
        
        // unlock price for tokenId = 1 is not increased at all.
        assertEq(protectedListings.unlockPrice(address(erc721a), 1), 0.4 ether);
    }
```
In the above test code, user avoid fees for tokenId = 1 by creating the listing for tokenId = 1 within the same block for tokenId = 0.

## Impact
User can avoid protected listing fee. It meanas loss of funds for the protocol.

## Code Snippet
- [ProtectedListings._createCheckpoint()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/ProtectedListings.sol#L566)

## Tool used
Manual Review

## Recommendation
Modify `ProtectedListings._createCheckpoint()` function as below.
```solidity
    function _createCheckpoint(address _collection) internal returns (uint index_) {
        // Determine the index that will be created
        index_ = collectionCheckpoints[_collection].length;

        // Register the checkpoint that has been created
        emit CheckpointCreated(_collection, index_);

        // If this is our first checkpoint, then our logic will be different as we won't have
        // a previous checkpoint to compare against and we don't want to underflow the index.
        if (index_ == 0) {
            // Calculate the current interest rate based on utilization
            (, uint _utilizationRate) = utilizationRate(_collection);

            // We don't have a previous checkpoint to calculate against, so we initiate our
            // first checkpoint with base data.
            collectionCheckpoints[_collection].push(
                Checkpoint({
                    compoundedFactor: locker.taxCalculator().calculateCompoundedFactor({
                        _previousCompoundedFactor: 1e18,
                        _utilizationRate: _utilizationRate,
                        _timePeriod: 0
                    }),
                    timestamp: block.timestamp
                })
            );

            return index_;
        }

        // Get our new (current) checkpoint
        Checkpoint memory checkpoint = _currentCheckpoint(_collection);

        // If no time has passed in our new checkpoint, then we just need to update the
        // utilization rate of the existing checkpoint.
        if (checkpoint.timestamp == collectionCheckpoints[_collection][index_ - 1].timestamp) {
            collectionCheckpoints[_collection][index_ - 1].compoundedFactor = checkpoint.compoundedFactor;
--          return index_;
++          return index_ - 1;
        }

        // Store the new (current) checkpoint
        collectionCheckpoints[_collection].push(checkpoint);
    }
```

# [H-07] Attacker can take out user's repaid protected listing NFT with only `1 ether`.
## Summary
`ProtectedListings.unlockProtectedListing()` function deletes `_protectedListings[_collection][_tokenId]` while not withdraw it from `Locker` when `_withdraw` parameter is `false`. Therefore, attacker can take out user's repaid protected listing NFT with only `1 ether` before user withdraw it.

## Vulnerability Detail
`ProtectedListings.unlockProtectedListing()` function is following.
```solidity
    function unlockProtectedListing(address _collection, uint _tokenId, bool _withdraw) public lockerNotPaused {
        // Ensure this is a protected listing
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];

        // Ensure the caller owns the listing
        if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);

        // Ensure that the protected listing has run out of collateral
        int collateral = getProtectedListingHealth(_collection, _tokenId);
        if (collateral < 0) revert InsufficientCollateral();

        // cache
        ICollectionToken collectionToken = locker.collectionToken(_collection);
        uint denomination = collectionToken.denomination();
        uint96 tokenTaken = _protectedListings[_collection][_tokenId].tokenTaken;

        // Repay the loaned amount, plus a fee from lock duration
        uint fee = unlockPrice(_collection, _tokenId) * 10 ** denomination;
        collectionToken.burnFrom(msg.sender, fee);

        // We need to burn the amount that was paid into the Listings contract
        collectionToken.burn((1 ether - tokenTaken) * 10 ** denomination);

        // Remove our listing type
        unchecked { --listingCount[_collection]; }

        // Delete the listing objects
314:    delete _protectedListings[_collection][_tokenId];

        // Transfer the listing ERC721 back to the user
        if (_withdraw) {
            locker.withdrawToken(_collection, _tokenId, msg.sender);
            emit ListingAssetWithdraw(_collection, _tokenId);
        } else {
            canWithdrawAsset[_collection][_tokenId] = msg.sender;
        }

        // Update our checkpoint to reflect that listings have been removed
        _createCheckpoint(_collection);

        // Emit an event
        emit ListingUnlocked(_collection, _tokenId, fee);
    }
```
The above function doesn't withdraw NFT when `_withdraw` parameter is `false`, but deletes `_protectedListings[_collection][_tokenId]` in `L314`.
In the meantime, `Locker.redeem()` function is following.
```solidity
    function redeem(address _collection, uint[] calldata _tokenIds, address _recipient) public nonReentrant whenNotPaused collectionExists(_collection) {
        uint tokenIdsLength = _tokenIds.length;
        if (tokenIdsLength == 0) revert NoTokenIds();

        // Burn the ERC20 tokens from the caller
        ICollectionToken collectionToken_ = _collectionToken[_collection];
        collectionToken_.burnFrom(msg.sender, tokenIdsLength * 1 ether * 10 ** collectionToken_.denomination());

        // Define our collection token outside the loop
        IERC721 collection = IERC721(_collection);

        // Loop through the tokenIds and redeem them
        for (uint i; i < tokenIdsLength; ++i) {
            // Ensure that the token requested is not a listing
223:        if (isListing(_collection, _tokenIds[i])) revert TokenIsListing(_tokenIds[i]);

            // Transfer the collection token to the caller
            collection.transferFrom(address(this), _recipient, _tokenIds[i]);
        }

        emit TokenRedeem(_collection, _tokenIds, msg.sender, _recipient);
    }
``` 
`Locker.isListing()` function of `L223` is following.
```solidity
    function isListing(address _collection, uint _tokenId) public view returns (bool) {
        IListings _listings = listings;

        // Check if we have a liquid or dutch listing
        if (_listings.listings(_collection, _tokenId).owner != address(0)) {
            return true;
        }

        // Check if we have a protected listing
447:    if (_listings.protectedListings().listings(_collection, _tokenId).owner != address(0)) {
            return true;
        }

        return false;
    }
```
Since `_protectedListings[_collection][_tokenId]` is already deleted in `ProtectedListings.sol#L314`, the condition of `L447` is `false` and `isListing()` function returns `false`. Therefore, attacker can take out user's repaid protected listing NFT by calling `Locker.redeem()` function.

PoC:
Add the following test code into `ProtectedListings.t.sol`.
```solidity
    function test_withdrawProtectedListingError() public {
        erc721a.mint(address(this), 0);
        
        erc721a.setApprovalForAll(address(protectedListings), true);

        uint[] memory _tokenIds = new uint[](2); _tokenIds[0] = 0; _tokenIds[1] = 1;

        // create protected listing for tokenId = 0
        IProtectedListings.CreateListing[] memory _listings = new IProtectedListings.CreateListing[](1);
        _listings[0] = IProtectedListings.CreateListing({
            collection: address(erc721a),
            tokenIds: _tokenIdToArray(0),
            listing: IProtectedListings.ProtectedListing({
                owner: payable(address(this)),
                tokenTaken: 0.4 ether,
                checkpoint: 0
            })
        });
        protectedListings.createListings(_listings);

        vm.warp(block.timestamp + 7 days);

        // attacker can't take out protected listing
        locker.collectionToken(address(erc721a)).approve(address(locker), 1 ether);
        vm.expectRevert();
        locker.redeem(address(erc721a), _tokenIdToArray(0), address(this));

        // user unlock protected listing without withdrawing
        locker.collectionToken(address(erc721a)).approve(address(protectedListings), 402055890410801920);
        protectedListings.unlockProtectedListing(address(erc721a), 0, false);

        // attacker can take out protected listing with only 1 ether
        locker.redeem(address(erc721a), _tokenIdToArray(0), address(this));

        // user lost his NFT
        vm.expectRevert();
        protectedListings.withdrawProtectedListing(address(erc721a), 0);
    }
```
As can be seen above, attacker can take out user's repaid protected listing NFT with only `1 ether` before user withdraw it.

## Impact
In general, the price of protected listing NFT will be more than `1 ether`. However, attacker can take out user's repaid protected listing NFT with only `1 ether`. This means loss of funds for user.

## Code Snippet
- [ProtectedListings.unlockProtectedListing()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/ProtectedListings.sol#L287-L329)

## Tool used
Manual Review

## Recommendation
Don't delete `_protectedListings[_collection][_tokenId]` when `_withdraw` parameter is `false`. And then delete it in the `ProtectedListings.withdrawProtectedListing()` function.

# [H-08] Attacker can lock shutdown voters' collectionTokens forever.
## Summary
When there are less than `MAX_SHUTDOWN_TOKENS` collection NFTs in the protocol, there will be shutdown vote. When shutdown vote exceeds quorum threshold and can execute, attacker can deposit NFTs to increase totalSupply of collectionTokens and cancel vote. As a result, voters' collectionTokens will be locked forever.

## Vulnerability Detail
The `CollectionShutdown.cancel()` function is following.
```solidity
    function cancel(address _collection) public whenNotPaused {
        // Ensure that the vote count has reached quorum
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (!params.canExecute) revert ShutdownNotReachedQuorum();

        // Check if the total supply has surpassed an amount of the initial required
        // total supply. This would indicate that a collection has grown since the
        // initial shutdown was triggered and could result in an unsuspected liquidation.
        if (params.collectionToken.totalSupply() <= MAX_SHUTDOWN_TOKENS * 10 ** locker.collectionToken(_collection).denomination()) {
            revert InsufficientTotalSupplyToCancel();
        }

        // Remove our execution flag
403:    delete _collectionParams[_collection];
        emit CollectionShutdownCancelled(_collection);
    }
```
As can be seen, the above function deletes the `_collectionParams[_collection]` in `L403` when totalSupply is larger than `MAX_SHUTDOWN_TOKENS`.
After shudown vote is canceled, voters should reclaim their votes to refund their voted collectionTokens. However, `CollectionShutdown.reclaimVote()` function is following.
```solidity
    function reclaimVote(address _collection) public whenNotPaused {
        // If the quorum has passed, then we can no longer reclaim as we are pending
        // an execution.
        CollectionShutdownParams storage params = _collectionParams[_collection];
        if (params.canExecute) revert ShutdownQuorumHasPassed();

        // Get the amount of votes that the user has cast for this collection
        uint userVotes = shutdownVoters[_collection][msg.sender];

        // If the user has not cast a vote, then we can revert early
        if (userVotes == 0) revert NoVotesPlacedYet();

        // We delete the votes that the user has attributed to the collection
369:    params.shutdownVotes -= uint96(userVotes);
        delete shutdownVoters[_collection][msg.sender];

        // We can now return their tokens
373:    params.collectionToken.transfer(msg.sender, userVotes);

        // Notify our stalkers that a vote has been reclaimed
        emit CollectionShutdownVoteReclaim(_collection, msg.sender, userVotes);
    }
```
As can be seen, since `_collectionParams[_collection]` has been deleted, the above function will revert at `L369` and `L373`.
As a result, voters' collectionTokens will be locked in the `CollectionShutdown` contract.

PoC:
1. Assume that `denomination` is 1 and totalSupplay of a collection are `MAX_SHUTDOWN_TOKENS = 4 ethers`.
2. Shutdown vote starts and the votes can execute since total votes are larger than quorum threshold.
3. Attacker deposits 1 NFT to the collection and cancel shutdown vote.
4. Voters' collectionTokens will be locked since they can't reclaim their votes.
5. Attacker can redeem his NFT if necessary.

## Impact
Attacker can lock shutdown voters' collectionTokens without any risk and loss.
Since majority amount of collectionTokens are locked, new shutdown vote can't execute again. Therefore, the voters' collectionTokens will be locked forever.

## Code Snippet
- [CollectionShutdown.reclaimVote()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/utils/CollectionShutdown.sol#L356-L377)
- [CollectionShutdown.cancel()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/utils/CollectionShutdown.sol#L390-L405)

## Tool used
Manual Review

## Recommendation
Add a function to reclaim votes in the case of canceling shutdown vote.

# [M-01] Attacker can disable `CollectionShutdown.preventShutdown()` function.
## Summary
The protocol has function of preventing shudown for a certain collection by admin.
However, attacker can start shutdown by calling `CollectionShutdown.start()` function with only 1 wei before admin calls `CollectionShutdown.preventShutdown()` function.

## Vulnerability Detail
The following `CollectionShutdown.preventShudown()` function will revert if shutdown is already in progress.
```solidity
    function preventShutdown(address _collection, bool _prevent) public {
        // Make sure our user is a locker manager
        if (!locker.lockerManager().isManager(msg.sender)) revert ILocker.CallerIsNotManager();

        // Make sure that there isn't currently a shutdown in progress
@>      if (_collectionParams[_collection].shutdownVotes != 0) revert ShutdownProcessAlreadyStarted();

        // Update the shutdown to be prevented
        shutdownPrevented[_collection] = _prevent;
        emit CollectionShutdownPrevention(_collection, _prevent);
    }
```
On the other hand, the following `CollectionShutdown.start()` function can be called and succeeded before the collection is initialized by `Locker.initializeCollection()` function.
```solidity
    function start(address _collection) public whenNotPaused {
        // Confirm that this collection is not prevented from being shutdown
        if (shutdownPrevented[_collection]) revert ShutdownPrevented();

        // Ensure that a shutdown process is not already actioned
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (params.shutdownVotes != 0) revert ShutdownProcessAlreadyStarted();

        // Get the total number of tokens still in circulation, specifying a maximum number
        // of tokens that can be present in a "dormant" collection.
        params.collectionToken = locker.collectionToken(_collection);
        uint totalSupply = params.collectionToken.totalSupply();
147:    if (totalSupply > MAX_SHUTDOWN_TOKENS * 10 ** params.collectionToken.denomination()) revert TooManyItems();

        // Set our quorum vote requirement
        params.quorumVotes = uint88(totalSupply * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT);

        // Notify that we are processing a shutdown
        emit CollectionShutdownStarted(_collection);

        // Cast our vote from the user
156:    _collectionParams[_collection] = _vote(_collection, params);
    }
```
As can be seen, the above function doesn't check if collection is already initialized and the condition of `L147` will be true because collection is not initialized yet.
In addition, `_vote()` function of `L156` requires `msg.sender` should hold non-zero `collectionToken`s.

From above reasoning, the following scenario is available.
1. Admin create collection by calling `Locker.createCollection()` function.
2. Before admin initialize the collection by calling `Locker.initializeCollection()` function, using frontrun, attacker deposit 1 NFT and receive corresponding `collectionToken`s.
3. Attacker(`attackerAddress1`) transfer `1 wei` `collectionToken` to some other `attackerAddress2`.
4. Attacker(`attackerAddress2`) start shutdown by calling `CollectionShutdown.start()` function. It will succeed because number of deposited NFT is only one which is less than `MAX_SHUTDOWN_TOKENS = 4`.
5. After that, admin can't prevent shutdown for the collection by calling `CollectionShutdown.preventShutdown()` function because there is already a shutdown in progress.

## Impact
Comment of `CollectionShutdown.start()` function has following paragraph:
```solidity
     * When the trigger is set, it will only be available for a set duration.
     * If this duration passes, then the process will need to start again.
```
But in fact, there is no such restriction in the current implementation.
Therefore, once if a shutdown is in progress, it will be available for unlimited time and the `preventShutdown()` function will be DOSed for unlimited time too.

## Code Snippet
- [CollectionShutdown.start()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/utils/CollectionShutdown.sol#L124-L157)

## Tool used
Manual Review

## Recommendation
Disable the `CollectionShutdown.start()` function before collection is initialized.

# [M-02] User may lose fund when modify listings.
## Summary
`Listings.modifyListings()` function doesn't update `listing.created` when user doesn't change duration (i.e. `params.duration == 0`). Therefore, user will pay tax again for the period from `listing.created` to `block.timestamp`.

## Vulnerability Detail
`Listings.modifyListings()` function is following.
```solidity
    function modifyListings(address _collection, ModifyListing[] calldata _modifyListings, bool _payTaxWithEscrow) public nonReentrant lockerNotPaused returns (uint taxRequired_, uint refund_) {
        uint fees;

        for (uint i; i < _modifyListings.length; ++i) {
            // Store the listing
            ModifyListing memory params = _modifyListings[i];
            Listing storage listing = _listings[_collection][params.tokenId];

            --- SKIP ---

            // Collect tax on the existing listing
323:        (uint _fees, uint _refund) = _resolveListingTax(listing, _collection, false);
            emit ListingFeeCaptured(_collection, params.tokenId, _fees);

            fees += _fees;
            refund_ += _refund;

            // Check if we are altering the duration of the listing
            if (params.duration != 0) {
                // Ensure that the requested duration falls within our listing range
                if (params.duration < MIN_LIQUID_DURATION) revert ListingDurationBelowMin(params.duration, MIN_LIQUID_DURATION);
                if (params.duration > MAX_LIQUID_DURATION) revert ListingDurationExceedsMax(params.duration, MAX_LIQUID_DURATION);

                emit ListingExtended(_collection, params.tokenId, listing.duration, params.duration);

337:            listing.created = uint40(block.timestamp);
                listing.duration = params.duration;
            }

            --- SKIP ---
        }

        --- SKIP ---
    }
```
The tax which user pays in `L323` are calculated depends on `block.timestamp - listings.created` and `listing.floorMultiple`.
However, the above function pays tax up to `block.timestamp` in `L323`, but doesn't update `listing.created` when `params.duration == 0`.
Therefore, user should pay tax again for the period from `listing.created` to `block.timestamp` after that.

PoC:
Add the following test code into `Listings.t.sol`
```solidity
    function test_PayTaxAgainWhenModifyListings() public {
        // Flatten our token balance before processi for ease of calculation
        ICollectionToken token = locker.collectionToken(address(erc721a));
        deal(address(token), address(this), 0);

        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = 0;
        erc721a.mint(address(this), 0);

        erc721a.setApprovalForAll(address(listings), true);

        // Set up multiple listings
        IListings.CreateListing[] memory _listings = new IListings.CreateListing[](1);
        _listings[0] = IListings.CreateListing({
            collection: address(erc721a),
            tokenIds: tokenIds,
            listing: IListings.Listing({
                owner: payable(address(this)),
                created: uint40(block.timestamp),
                duration: VALID_LIQUID_DURATION * 2,
                floorMultiple: 200
            })
        });

        // Create our listings
        listings.createListings(_listings);

        vm.warp(block.timestamp + VALID_LIQUID_DURATION);

        token.approve(address(listings), type(uint).max);

        // first modifyListings
        uint balance1 = token.balanceOf(address(this));

        IListings.ModifyListing[] memory params = new IListings.ModifyListing[](1);
        params[0] = IListings.ModifyListing(0, 0/* no change for duration */, 300);

        listings.modifyListings(address(erc721a), params, true);

        uint balance2 = token.balanceOf(address(this));
        int diff1 = int(balance2) - int(balance1);
        console.log("balance diff 1:", diff1);
        console.log("OK: Since floorMultiple increase, balance should be decreased.");

        // second modifyListings
        params[0].floorMultiple = 200;

        listings.modifyListings(address(erc721a), params, true);

        uint balance3 = token.balanceOf(address(this));
        int diff2 = int(balance3) - int(balance2);
        console.log("balance diff 2:", diff2);
        console.log("ERROR: Although floorMultiple decrease and no time passed, balance is decreased.");
    }
```
The result of test code is following.
```sh
Logs:
  balance diff 1: -85000000000000000
  OK: Since floorMultiple increase, balance should be decreased.
  balance diff 2: -17500000000000000
  ERROR: Although floorMultiple decrease and no time passed, balance is decreased.
```

## Impact
User will pay tax again for the period from `listing.created` to `block.timestamp` when modify listings.
That is, there is loss of user's fund.

## Code Snippet
- [Listings.modifyListings()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/Listings.sol#L303-L384)

## Tool used
Manual Review

## Recommendation
Modify `modifyListings()` function as follows.
```solidity
    function modifyListings(address _collection, ModifyListing[] calldata _modifyListings, bool _payTaxWithEscrow) public nonReentrant lockerNotPaused returns (uint taxRequired_, uint refund_) {
        uint fees;

        for (uint i; i < _modifyListings.length; ++i) {
            // Store the listing
            ModifyListing memory params = _modifyListings[i];
            Listing storage listing = _listings[_collection][params.tokenId];

            --- SKIP ---

            // Collect tax on the existing listing
            (uint _fees, uint _refund) = _resolveListingTax(listing, _collection, false);
            emit ListingFeeCaptured(_collection, params.tokenId, _fees);
++          listing.created = uint40(block.timestamp);

            fees += _fees;
            refund_ += _refund;

            // Check if we are altering the duration of the listing
            if (params.duration != 0) {
                // Ensure that the requested duration falls within our listing range
                if (params.duration < MIN_LIQUID_DURATION) revert ListingDurationBelowMin(params.duration, MIN_LIQUID_DURATION);
                if (params.duration > MAX_LIQUID_DURATION) revert ListingDurationExceedsMax(params.duration, MAX_LIQUID_DURATION);

                emit ListingExtended(_collection, params.tokenId, listing.duration, params.duration);

--              listing.created = uint40(block.timestamp);
                listing.duration = params.duration;
            }

            --- SKIP ---
        }

        --- SKIP ---
    }
```

# [M-03] Beneficiary will lose unclaimed fees.
## Summary
If `BaseImplementation.setBeneficiary()` sets new beneficiary which is a Flayer pool, old beneficiary can not claim the unclaimed fees.

## Vulnerability Detail
`BaseImplementation.setBeneficiary()` function is following.
```solidity
    /**
     * Allows our beneficiary address to be updated, changing the address that will
@>   * be allocated fees moving forward. The old beneficiary will still have access
     * to `claim` any fees that were generated whilst they were set.
     *
     * @param _beneficiary The new fee beneficiary
     * @param _isPool If the beneficiary is a Flayer pool
     */
    function setBeneficiary(address _beneficiary, bool _isPool) public onlyOwner {
        beneficiary = _beneficiary;
        beneficiaryIsPool = _isPool;

        // If we are setting the beneficiary to be a Flayer pool, then we want to
        // run some additional logic to confirm that this is a valid pool by checking
        // if we can match it to a corresponding {CollectionToken}.
        if (_isPool && address(locker.collectionToken(_beneficiary)) == address(0)) {
            revert BeneficiaryIsNotPool();
        }

        emit BeneficiaryUpdated(_beneficiary, _isPool);
    }
```
As can be seen, the comment of the above function says that "The old beneficiary will still have access to `claim` any fees that were generated whilst they were set.". However, if `_isPool` parameter is `true`, `beneficiaryIsPool` state variable will be set as `true`. Therefore, after that, the following `BaseImplementation.claim()` function will revert in `L171` for old beneficiary.
```solidity
    function claim(address _beneficiary) public nonReentrant {
        // Ensure that the beneficiary has an amount available to claim. We don't revert
        // at this point as it could open an external protocol to DoS.
        uint amount = beneficiaryFees[_beneficiary];
        if (amount == 0) return;

        // We cannot make a direct claim if the beneficiary is a pool
171:    if (beneficiaryIsPool) revert BeneficiaryPoolCannotClaim();

        // Reduce the amount of fees allocated to the `beneficiary` for the token. This
        // helps to prevent reentrancy attacks.
        beneficiaryFees[_beneficiary] = 0;

        // Claim ETH equivalent available to the beneficiary
        IERC20(nativeToken).transfer(_beneficiary, amount);
        emit BeneficiaryFeesClaimed(_beneficiary, amount);
    }
``` 

## Impact
The comment "The old beneficiary will still have access to `claim` any fees that were generated whilst they were set." means that admin may not call `claim()` function for old beneficiary before calling `setBeneficiary()` function. By Sherlock rule, the code comments stands above all judging rules. Therefore, the old beneficiary may lose the unclaimed fees. Lock of Funds.

## Code Snippet
- [BaseImplemenation.setBeneficiary()](https://github.com/sherlock-audit/2024-08-flayer/blob/main/flayer/src/contracts/implementation/BaseImplementation.sol#L211-L223)

## Tool used
Manual Review

## Recommendation
Insert the following condition check in `BaseImplementation.setBeneficiary()` function.
```solidity
    if (_isPool && beneficiaryFees[_beneficiary] > 0) {
        revert;
    }
```
Or, fix the comment as the following.
```
Admin should call `claim()` function for old beneficiary before calling `setBeneficiary()` function when `_isPool` is true.
```