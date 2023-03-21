// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {RouterSinglePoolWithRoyalties} from "test/base/RouterSinglePoolWithRoyalties.sol";
import {UsingXykCurve} from "test/mixins/UsingXykCurve.sol";
import {UsingEnumerable} from "test/mixins/UsingEnumerable.sol";
import {UsingERC20} from "test/mixins/UsingERC20.sol";

contract RSPWRXykCurveEnumerableERC20Test is RouterSinglePoolWithRoyalties, UsingXykCurve, UsingEnumerable, UsingERC20 {}
