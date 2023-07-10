// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Clone} from "solady/utils/Clone.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FrontPageERC721} from "src/frontPage/FrontPageERC721.sol";
import {Page} from "src/Page.sol";

contract FrontPage is Clone, Page {
    using SafeTransferLib for address payable;

    // Fixed clone immutable arg byte offsets
    uint256 private constant IMMUTABLE_ARG_OFFSET_COLLECTION = 0;
    uint256 private constant IMMUTABLE_ARG_OFFSET_CREATOR = 20;
    uint256 private constant IMMUTABLE_ARG_OFFSET_MAX_SUPPLY = 40;
    uint256 private constant IMMUTABLE_ARG_OFFSET_MINT_PRICE = 72;

    // Next NFT ID to be minted
    uint256 public nextId;

    event Mint();
    event BatchMint();

    error Zero();
    error Soldout();
    error InvalidMsgValue();

    function collection() public pure override returns (ERC721) {
        return ERC721(_getArgAddress(IMMUTABLE_ARG_OFFSET_COLLECTION));
    }

    // TODO: Make `creator` updateable
    function creator() public pure returns (address payable) {
        return payable(_getArgAddress(IMMUTABLE_ARG_OFFSET_CREATOR));
    }

    function maxSupply() public pure returns (uint256) {
        return _getArgUint256(IMMUTABLE_ARG_OFFSET_MAX_SUPPLY);
    }

    function mintPrice() public pure returns (uint256) {
        return _getArgUint256(IMMUTABLE_ARG_OFFSET_MINT_PRICE);
    }

    /**
     * @notice Withdraw proceeds to `creator`
     */
    function withdrawProceeds() external {
        // BUG: Must limit withdrawals to mint proceeds only
        // TODO: Restrict this method to being called only by `creator`
        creator().safeTransferETH(address(this).balance);
    }

    /**
     * @notice Mint the FrontPage token representing the redeemable NFT
     */
    function mint() external payable {
        uint256 _nextId = nextId;

        // Revert if the max NFT supply has already been minted
        if (_nextId > maxSupply()) revert Soldout();

        // Revert if the value sent does not equal the mint price
        if (msg.value != mintPrice()) revert InvalidMsgValue();

        // Set the owner of the token ID to the minter
        ownerOf[_nextId] = msg.sender;

        // Will not overflow since nextId is less than or equal to maxSupply
        unchecked {
            // Increment nextId to the next NFT ID to be minted
            ++nextId;
        }

        emit Mint();
    }

    /**
     * @notice Mint multiple FrontPage tokens representing the redeemable NFTs
     * @param  quantity  uint256  Number of FPTs to mint
     */
    function batchMint(uint256 quantity) external payable {
        // Revert if the value sent does not equal the mint price
        if (msg.value != mintPrice() * quantity) revert InvalidMsgValue();

        unchecked {
            // Update nextId to reflect the additional tokens to be minted
            // Virtually impossible to overflow due to the msg.value check above
            uint256 _nextId = (nextId += quantity);

            // Revert if the max NFT supply has been or will be exceeded post-mint
            if (_nextId > maxSupply()) revert Soldout();

            // If quantity is zero, the loop logic will never be executed
            for (uint256 i = quantity; i > 0; --i) {
                // Set the owner of the token ID to the minter
                ownerOf[_nextId - i] = msg.sender;
            }
        }

        emit BatchMint();
    }

    /**
     * @notice Redeem the FrontPage token for the underlying NFT
     * @param  id  uint256  FrontPage token ID
     */
    function redeem(uint256 id) external {
        if (ownerOf[id] != msg.sender) revert Unauthorized();

        // Burn the token to prevent the double-spending
        delete ownerOf[id];

        // Mint the NFT for msg.sender with the same ID as the FrontPage token
        FrontPageERC721(_getArgAddress(IMMUTABLE_ARG_OFFSET_COLLECTION)).mint(msg.sender, id);
    }

    /**
     * @notice Redeem the FrontPage tokens for the underlying NFTs
     * @param  ids  uint256[]  FrontPage token IDs
     */
    function batchRedeem(uint256[] calldata ids) external {
        uint256 id;
        uint256 idsLength = ids.length;

        for (uint256 i = 0; i < idsLength; ) {
            id = ids[i];

            if (ownerOf[id] != msg.sender) revert Unauthorized();

            // Burn the token to prevent the double-spending
            delete ownerOf[id];

            unchecked {
                ++i;
            }
        }

        // Mint the NFTs for msg.sender with the same IDs as the FrontPage tokens
        FrontPageERC721(_getArgAddress(IMMUTABLE_ARG_OFFSET_COLLECTION)).batchMint(msg.sender, ids);
    }
}
