// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {ExponentialCurve} from "src/bonding-curves/ExponentialCurve.sol";
import {Test721Enumerable} from "test/mocks/Test721Enumerable.sol";
import {IERC721Mintable} from "test/interfaces/IERC721Mintable.sol";
import {ICurve} from "src/interfaces/ICurve.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Configurable} from "./Configurable.sol";

abstract contract UsingExponentialCurve is Configurable {
    function setupCurve() public override returns (ICurve) {
        return new ExponentialCurve();
    }

    function modifyDelta(uint64 delta) public pure override returns (uint64) {
        if (delta <= FixedPointMathLib.WAD) {
            return uint64(FixedPointMathLib.WAD + delta + 1);
        } else if (delta >= 2*FixedPointMathLib.WAD) {
          return uint64(2*FixedPointMathLib.WAD);
        }
        else {
            return delta;
        }
    }

    function modifySpotPrice(uint56 spotPrice)
        public
        pure
        override
        returns (uint56)
    {
        if (spotPrice < 1 gwei) {
            return 1 gwei;
        } else {
            return spotPrice;
        }
    }

    // Return 1 eth as spot price and 10% as the delta scaling
    function getParamsForPartialFillTest() public pure override returns (uint128 spotPrice, uint128 delta) {
      return (10**18, 1.1*(10**18));
    }
}
