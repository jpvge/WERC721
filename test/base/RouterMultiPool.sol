// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {DSTest} from "ds-test/test.sol";
import {ERC721Holder} from "openzeppelin/token/ERC721/utils/ERC721Holder.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

import {ICurve} from "src/interfaces/ICurve.sol";
import {PairFactory} from "sudoswap/PairFactory.sol";
import {Pair} from "src/sudoswap/Pair.sol";
import {PairETH} from "sudoswap/PairETH.sol";
import {PairERC20} from "sudoswap/PairERC20.sol";
import {PairEnumerableETH} from "sudoswap/PairEnumerableETH.sol";
import {PairMissingEnumerableETH} from "sudoswap/PairMissingEnumerableETH.sol";
import {PairEnumerableERC20} from "sudoswap/PairEnumerableERC20.sol";
import {PairMissingEnumerableERC20} from "sudoswap/PairMissingEnumerableERC20.sol";
import {Router} from "sudoswap/Router.sol";
import {IERC721Mintable} from "../interfaces/IERC721Mintable.sol";
import {Configurable} from "test/mixins/Configurable.sol";
import {RouterCaller} from "test/mixins/RouterCaller.sol";

// Gives more realistic scenarios where swaps have to go through multiple pools, for more accurate gas profiling
abstract contract RouterMultiPool is
    DSTest,
    ERC721Holder,
    Configurable,
    RouterCaller
{
    IERC721Mintable test721;
    ICurve bondingCurve;
    PairFactory factory;
    Router router;
    mapping(uint256 => Pair) pairs;
    address payable constant feeRecipient = payable(address(69));
    uint256 constant protocolFeeMultiplier = 3e15;
    uint256 numInitialNFTs = 10;

    function setUp() public {
        bondingCurve = setupCurve();
        test721 = setup721();
        PairEnumerableETH enumerableETHTemplate = new PairEnumerableETH();
        PairMissingEnumerableETH missingEnumerableETHTemplate = new PairMissingEnumerableETH();
        PairEnumerableERC20 enumerableERC20Template = new PairEnumerableERC20();
        PairMissingEnumerableERC20 missingEnumerableERC20Template = new PairMissingEnumerableERC20();
        factory = new PairFactory(
            enumerableETHTemplate,
            missingEnumerableETHTemplate,
            enumerableERC20Template,
            missingEnumerableERC20Template,
            feeRecipient,
            protocolFeeMultiplier
        );
        router = new Router(factory);
        factory.setBondingCurveAllowed(bondingCurve, true);
        factory.setRouterAllowed(router, true);

        // set NFT approvals
        test721.setApprovalForAll(address(factory), true);
        test721.setApprovalForAll(address(router), true);

        // mint NFT #1-10 to caller
        for (uint256 i = 1; i <= numInitialNFTs; i++) {
            test721.mint(address(this), i);
        }

        // Pair 1 has NFT#1 at 1 ETH price, willing to also buy at the same price
        // Pair 2 has NFT#2 at 2 ETH price, willing to also buy at the same price
        // Pair 3 has NFT#3 at 3 ETH price, willing to also buy at the same price
        // Pair 4 has NFT#4 at 4 ETH price, willing to also buy at the same price
        // Pair 5 has NFT#5 at 5 ETH price, willing to also buy at the same price
        // For all, assume no price changes
        for (uint256 i = 1; i <= 5; i++) {
            uint256[] memory idList = new uint256[](1);
            idList[0] = i;
            pairs[i] = this.setupPair{value: modifyInputAmount(i * 1 ether)}(
                factory,
                test721,
                bondingCurve,
                payable(address(0)),
                Pair.PoolType.TRADE,
                modifyDelta(0),
                0,
                uint128(i * 1 ether),
                idList,
                (i * 1 ether),
                address(router)
            );
        }
    }

    function test_swapTokenForAny5NFTs() public {
        // Swap across all 5 pools
        Router.PairSwapAny[]
            memory swapList = new Router.PairSwapAny[](5);
        uint256 totalInputAmount = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 inputAmount;
            (, , , inputAmount, ) = pairs[i + 1].getBuyNFTQuote(1);
            totalInputAmount += inputAmount;
            swapList[i] = Router.PairSwapAny({
                pair: pairs[i + 1],
                numItems: 1
            });
        }
        uint256 startBalance = test721.balanceOf(address(this));
        this.swapTokenForAnyNFTs{value: modifyInputAmount(totalInputAmount)}(
            router,
            swapList,
            payable(address(this)),
            address(this),
            block.timestamp,
            totalInputAmount
        );
        uint256 endBalance = test721.balanceOf(address(this));
        require((endBalance - startBalance) == 5, "Too few NFTs acquired");
    }

    function test_swapTokenForSpecific5NFTs() public {
        // Swap across all 5 pools
        Router.PairSwapSpecific[]
            memory swapList = new Router.PairSwapSpecific[](5);
        uint256 totalInputAmount = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 inputAmount;
            (, , , inputAmount, ) = pairs[i + 1].getBuyNFTQuote(1);
            totalInputAmount += inputAmount;
            uint256[] memory nftIds = new uint256[](1);
            nftIds[0] = i + 1;
            swapList[i] = Router.PairSwapSpecific({
                pair: pairs[i + 1],
                nftIds: nftIds
            });
        }
        uint256 startBalance = test721.balanceOf(address(this));
        this.swapTokenForSpecificNFTs{
            value: modifyInputAmount(totalInputAmount)
        }(
            router,
            swapList,
            payable(address(this)),
            address(this),
            block.timestamp,
            totalInputAmount
        );
        uint256 endBalance = test721.balanceOf(address(this));
        require((endBalance - startBalance) == 5, "Too few NFTs acquired");
    }

    function test_swap5NFTsForToken() public {
        // Swap across all 5 pools
        Router.PairSwapSpecific[]
            memory swapList = new Router.PairSwapSpecific[](5);
        uint256 totalOutputAmount = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 outputAmount;
            (, , , outputAmount, ) = pairs[i + 1].getSellNFTQuote(1);
            totalOutputAmount += outputAmount;
            uint256[] memory nftIds = new uint256[](1);
            // Set it to be an ID we own
            nftIds[0] = i + 6;
            swapList[i] = Router.PairSwapSpecific({
                pair: pairs[i + 1],
                nftIds: nftIds
            });
        }
        uint256 startBalance = test721.balanceOf(address(this));
        router.swapNFTsForToken(
            swapList,
            totalOutputAmount,
            payable(address(this)),
            block.timestamp
        );
        uint256 endBalance = test721.balanceOf(address(this));
        require((startBalance - endBalance) == 5, "Too few NFTs sold");
    }
}
