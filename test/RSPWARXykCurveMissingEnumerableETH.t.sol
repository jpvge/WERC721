// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {RouterSinglePoolWithAssetRecipient} from "test/base/RouterSinglePoolWithAssetRecipient.sol";
import {UsingXykCurve} from "test/mixins/UsingXykCurve.sol";
import {UsingMissingEnumerable} from "test/mixins/UsingMissingEnumerable.sol";
import {UsingETH} from "test/mixins/UsingETH.sol";

contract RSPWARXykCurveMissingEnumerableETHTest is RouterSinglePoolWithAssetRecipient, UsingXykCurve, UsingMissingEnumerable, UsingETH {}
