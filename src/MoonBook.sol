// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Moon} from "src/Moon.sol";

contract MoonBook is ERC721TokenReceiver, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint96;
    using SafeTransferLib for address payable;

    struct Listing {
        // NFT seller, receives ETH upon sale
        address seller;
        // Denominated in ETH
        uint96 price;
    }

    // Fees are 1%
    uint128 public constant MOON_FEE_PERCENT = 1;

    // Used for calculating fees
    uint128 public constant MOON_FEE_PERCENT_BASE = 100;

    // MOON token contract
    Moon public immutable moon;

    // NFT collection contract
    ERC721 public immutable collection;

    // NFT collection listings
    mapping(uint256 id => Listing listing) public collectionListings;

    // NFT collection offers (ID agnostic)
    // There may be many offers made by many different buyers
    mapping(uint256 offer => address[] buyers) public collectionOffers;

    event List(
        address indexed msgSender,
        uint256 indexed id,
        address indexed seller,
        uint96 price
    );
    event EditListing(
        address indexed msgSender,
        uint256 indexed id,
        address indexed newSeller,
        uint96 newPrice
    );
    event CancelListing(address indexed msgSender, uint256 indexed id);
    event Buy(
        address indexed buyer,
        address indexed seller,
        uint256 indexed id,
        uint96 price,
        uint256 totalFees
    );
    event MakeOffer(address indexed buyer, uint256 offer);
    event CancelOffer(address indexed buyer, uint256 offer);
    event TakeOffer(
        address indexed buyer,
        address indexed seller,
        uint256 id,
        uint256 offer
    );
    event MatchOffer(
        address indexed matcher,
        address indexed buyer,
        address indexed seller,
        uint256 id,
        uint256 offer
    );

    error InvalidAddress();
    error InvalidPrice();
    error OnlySeller();
    error Unauthorized();
    error InvalidOffer();
    error InvalidListing();
    error EmptyArray();
    error MismatchedArrays();
    error InsufficientFunds();
    error NotSeller();
    error NotBuyer();
    error ZeroOffer();
    error ZeroMsgValue();
    error OfferTooLow();

    /**
     * @param _moon        Moon    Moon protocol contract
     * @param _collection  ERC721  NFT collection contract
     */
    constructor(Moon _moon, ERC721 _collection) {
        if (address(_moon) == address(0)) revert InvalidAddress();
        if (address(_collection) == address(0)) revert InvalidAddress();

        moon = _moon;
        collection = _collection;
    }

    /**
     * @notice List a NFT for sale
     * @param  id      uint256  NFT ID
     * @param  seller  address  NFT seller
     * @param  price   uint96   NFT price in ETH
     */
    function list(
        uint256 id,
        address seller,
        uint96 price
    ) external nonReentrant {
        if (seller == address(0)) revert InvalidAddress();
        if (price == 0) revert InvalidPrice();

        // Reverts if the NFT is not owned by msg.sender
        collection.safeTransferFrom(msg.sender, address(this), id);

        // Set listing details
        collectionListings[id] = Listing(seller, price);

        emit List(msg.sender, id, seller, price);
    }

    /**
     * @notice Edit NFT listing seller and/or price
     * @param  id         uint256  NFT ID
     * @param  newSeller  address  New NFT seller
     * @param  newPrice   uint96   New NFT price
     */
    function editListing(
        uint256 id,
        address newSeller,
        uint96 newPrice
    ) external {
        if (newSeller == address(0)) revert InvalidAddress();
        if (newPrice == 0) revert InvalidPrice();

        Listing storage listing = collectionListings[id];

        // msg.sender must be the listing seller, otherwise they cannot edit
        if (listing.seller != msg.sender) revert OnlySeller();

        listing.seller = newSeller;
        listing.price = newPrice;

        emit EditListing(msg.sender, id, newSeller, newPrice);
    }

    /**
     * @notice Cancel NFT listing and reclaim NFT
     * @param  id  uint256  NFT ID
     */
    function cancelListing(uint256 id) external nonReentrant {
        // msg.sender must be the listing seller, otherwise they cannot cancel
        if (collectionListings[id].seller != msg.sender) revert OnlySeller();

        delete collectionListings[id];

        // Return the NFT to the seller
        collection.safeTransferFrom(address(this), msg.sender, id);

        emit CancelListing(msg.sender, id);
    }

    /**
     * @notice Buy a single NFT
     * @param  id           uint256  NFT ID
     * @return userRewards  uint256  Reward amount for each user
     */
    function buy(
        uint256 id
    ) external payable nonReentrant returns (uint256 userRewards) {
        if (msg.value == 0) revert ZeroMsgValue();

        Listing memory listing = collectionListings[id];

        // Reverts if msg.value does not equal listing price and if listing is non-existent
        if (msg.value != listing.price) revert InsufficientFunds();

        // Delete listing before exchanging tokens
        delete collectionListings[id];

        // Send NFT to buyer after confirming sufficient ETH was sent
        collection.safeTransferFrom(address(this), msg.sender, id);

        // Calculate protocol fees
        uint256 fees = listing.price.mulDivDown(
            MOON_FEE_PERCENT,
            MOON_FEE_PERCENT_BASE
        );

        // Transfer the post-fee sale proceeds to the seller
        payable(listing.seller).safeTransferETH(listing.price - fees);

        // Deposit fees into the MOON token contract, enabling them to be claimed by token holders
        // and distribute MOON rewards to both the buyer and seller, equal to the fees paid
        userRewards = moon.depositFees{value: fees}(msg.sender, listing.seller);

        emit Buy(msg.sender, listing.seller, id, listing.price, fees);
    }

    /**
     * @notice Make an offer at a single price point
     */
    function makeOffer() external payable nonReentrant {
        if (msg.value == 0) revert ZeroMsgValue();

        // User offer is the amount of ETH sent with the transaction
        collectionOffers[msg.value].push(msg.sender);

        emit MakeOffer(msg.sender, msg.value);
    }

    /**
     * @notice Take offer
     * @param  id          uint256  NFT ID
     * @param  offer       uint256  Offer amount
     * @param  buyerIndex  uint256  Buyer index
     */
    function takeOffer(
        uint256 id,
        uint256 offer,
        uint256 buyerIndex
    ) external nonReentrant returns (uint256 userRewards) {
        address buyer = collectionOffers[offer][buyerIndex];

        // Revert if offer does not exist
        if (buyer == address(0)) revert InvalidOffer();

        // Remove the offer prior to exchanging tokens between buyer and seller
        delete collectionOffers[offer][buyerIndex];

        // Transfer NFT to the buyer - reverts if msg.sender does not have the NFT
        collection.safeTransferFrom(msg.sender, buyer, id);

        uint256 fees = offer.mulDivDown(
            MOON_FEE_PERCENT,
            MOON_FEE_PERCENT_BASE
        );

        // Transfer the post-fee sale proceeds to the seller
        payable(msg.sender).safeTransferETH(offer - fees);

        userRewards = moon.depositFees{value: fees}(buyer, msg.sender);

        emit TakeOffer(buyer, msg.sender, id, offer);
    }

    /**
     * @notice Match an offer with a listing
     * @param  id          uint256  NFT ID
     * @param  offer       uint256  Offer amount
     * @param  buyerIndex  uint256  Buyer index
     */
    function matchOffer(
        uint256 id,
        uint256 offer,
        uint256 buyerIndex
    ) external nonReentrant returns (uint256 userRewards) {
        address buyer = collectionOffers[offer][buyerIndex];

        // Revert if offer does not exist
        if (buyer == address(0)) revert InvalidOffer();

        Listing memory listing = collectionListings[id];

        // Revert if listing does not exist
        if (listing.seller == address(0)) revert InvalidListing();

        // Revert if offer is less than listing price
        if (offer < listing.price) revert OfferTooLow();

        // Delete offer and listing prior to exchanging tokens
        delete collectionOffers[offer][buyerIndex];
        delete collectionListings[id];

        // Transfer NFT to the buyer (account that made offer)
        collection.safeTransferFrom(address(this), buyer, id);

        uint256 fees = listing.price.mulDivDown(
            MOON_FEE_PERCENT,
            MOON_FEE_PERCENT_BASE
        );

        // Transfer the post-fee sale proceeds to the seller
        payable(listing.seller).safeTransferETH(listing.price - fees);

        if (offer > listing.price) {
            // Send the spread (margin between ETH offer and listing price) to the matcher
            payable(msg.sender).safeTransferETH(offer - listing.price);
        }

        userRewards = moon.depositFees{value: fees}(buyer, listing.seller);

        emit MatchOffer(msg.sender, buyer, listing.seller, id, offer);
    }

    /**
     * @notice Cancel offer and reclaim ETH
     * @param  offer       uint256  Offer amount
     * @param  buyerIndex  uint256  Buyer index
     */
    function cancelOffer(
        uint256 offer,
        uint256 buyerIndex
    ) external nonReentrant {
        // Only the buyer can cancel their own offer
        if (collectionOffers[offer][buyerIndex] != msg.sender)
            revert NotBuyer();

        // Delete offer prior to transferring ETH to the buyer
        delete collectionOffers[offer][buyerIndex];

        // Return ETH to the offer maker
        payable(msg.sender).safeTransferETH(offer);

        emit CancelOffer(msg.sender, offer);
    }
}
