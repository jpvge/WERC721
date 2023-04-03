// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";

import {MoonPool} from "src/MoonPool.sol";

contract MoonPoolTest is Test, ERC721TokenReceiver {
    ERC721 private constant AZUKI =
        ERC721(0xED5AF388653567Af2F388E6224dC7C4b3241C544);
    address private constant AZUKI_OWNER =
        0x2aE6B0630EBb4D155C6e04fCB16840FFA77760AA;

    MoonPool private immutable pool;
    uint128 private immutable feeBpsBase;
    uint128 private immutable feeBps;
    address private immutable owner;

    // NFT IDs that are owned by the impersonated/pranked address
    uint256[] private initialNftIds = [0, 2, 7];

    event SetFeeRecipient(address indexed feeRecipient);
    event List(address indexed seller, uint256 indexed id, uint96 price);
    event ListMany(address indexed seller, uint256[] ids, uint96[] prices);
    event CancelListing(address indexed seller, uint256 indexed id);
    event EditListing(address indexed seller, uint256 indexed id, uint96 price);
    event Buy(
        address indexed buyer,
        address indexed seller,
        uint256 indexed id,
        uint96 price,
        uint256 totalFees
    );
    event BuyMany(
        address indexed buyer,
        uint256[] ids,
        uint256 totalPrice,
        uint256 totalFees
    );
    event MakeOffer(address indexed buyer, uint256 offer);
    event CancelOffer(address indexed buyer, uint256 offer);
    event TakeOffer(
        address indexed seller,
        address indexed buyer,
        uint256 id,
        uint256 offer
    );

    constructor() {
        vm.startPrank(AZUKI_OWNER);

        uint256 iLen = initialNftIds.length;

        // Transfer NFTs from owner to self
        for (uint256 i; i < iLen; ) {
            uint256 id = initialNftIds[i];

            assertTrue(AZUKI.ownerOf(id) == AZUKI_OWNER);

            AZUKI.safeTransferFrom(AZUKI_OWNER, address(this), id);

            assertTrue(AZUKI.ownerOf(id) == address(this));

            unchecked {
                ++i;
            }
        }

        vm.stopPrank();

        pool = new MoonPool(address(this), AZUKI);
        feeBpsBase = pool.FEE_BPS_BASE();
        feeBps = pool.FEE_BPS();
        owner = pool.owner();
    }

    /*///////////////////////////////////////////////////////////////
                            setFeeRecipient
    //////////////////////////////////////////////////////////////*/

    function testCannotSetFeeRecipientUnauthorized() external {
        vm.prank(address(0));
        vm.expectRevert(bytes("UNAUTHORIZED"));

        pool.setFeeRecipient(address(this));
    }

    function testCannotSetFeeRecipientInvalidAddress() external {
        assertEq(address(this), owner);

        vm.expectRevert(MoonPool.InvalidAddress.selector);

        pool.setFeeRecipient(address(0));
    }

    function testSetFeeRecipient(address feeRecipient) external {
        vm.assume(feeRecipient != address(0));

        assertEq(address(this), owner);
        assertEq(address(0), pool.feeRecipient());

        vm.expectEmit(true, false, false, true, address(pool));

        emit SetFeeRecipient(feeRecipient);

        pool.setFeeRecipient(feeRecipient);

        assertEq(feeRecipient, pool.feeRecipient());
    }
}
