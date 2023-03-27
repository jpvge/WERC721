// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";

import {LinearCurve} from "src/bonding-curves/LinearCurve.sol";
import {PairMissingEnumerableETH} from "src/MoonPairMissingEnumerableETH.sol";
import {PairEnumerableERC20} from "sudoswap/PairEnumerableERC20.sol";
import {PairMissingEnumerableERC20} from "sudoswap/PairMissingEnumerableERC20.sol";
import {PairEnumerableETH} from "src/MoonPairEnumerableETH.sol";
import {PairFactory} from "src/MoonPairFactory.sol";
import {RouterWithRoyalties} from "src/MoonRouter.sol";
import {Moon} from "src/Moon.sol";

contract MoonTest is Test {
    address private immutable testFactory = address(this);

    // Moonbase
    Moon private immutable moon;

    event SetFactory(address);
    event AddMinter(address);

    constructor() {
        // Deploy Moon
        moon = new Moon(address(this));

        // Set to this contract's address for testing purposes
        moon.setFactory(testFactory);
    }

    /*///////////////////////////////////////////////////////////////
                            setFactory
    //////////////////////////////////////////////////////////////*/

    function testCannotSetFactoryUnauthorized() external {
        vm.prank(address(0));
        vm.expectRevert(bytes("UNAUTHORIZED"));

        moon.setFactory(testFactory);
    }

    function testCannotSetFactoryInvalidAddress() external {
        vm.expectRevert(PairFactory.InvalidAddress.selector);

        moon.setFactory(address(0));
    }

    function testSetFactoryFuzz(address _factory) external {
        vm.assume(_factory != address(0));

        assertTrue(_factory != moon.factory());

        vm.expectEmit(false, false, false, true, address(moon));

        emit SetFactory(_factory);

        moon.setFactory(_factory);

        assertTrue(_factory == moon.factory());
    }

    /*///////////////////////////////////////////////////////////////
                                addMinter
    //////////////////////////////////////////////////////////////*/

    function testCannotAddMinterUnauthorized() external {
        vm.prank(address(0));
        vm.expectRevert(Moon.Unauthorized.selector);

        moon.addMinter(address(this));
    }

    function testCannotAddMinterInvalidAddress() external {
        vm.expectRevert(Moon.InvalidAddress.selector);

        moon.addMinter(address(0));
    }

    function testAddMinter(address _minter) external {
        assertFalse(moon.minters(_minter));

        vm.expectEmit(false, false, false, true, address(moon));

        emit AddMinter(_minter);

        moon.addMinter(_minter);

        assertTrue(moon.minters(_minter));
    }
}
