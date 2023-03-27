// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ERC165Checker} from "openzeppelin/utils/introspection/ERC165Checker.sol";
import {IERC165} from "openzeppelin/utils/introspection/IERC165.sol";
import {IERC721Enumerable} from "openzeppelin/token/ERC721/extensions/IERC721Enumerable.sol";

// @dev Solmate's ERC20 is used instead of OZ's ERC20 so we can use safeTransferLib for cheaper safeTransfers for
// ETH and ERC20 tokens
import {Owned} from "solmate/auth/Owned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Pair} from "sudoswap/Pair.sol";
import {Router} from "sudoswap/Router.sol";
import {PairETH} from "sudoswap/PairETH.sol";
import {PairERC20} from "sudoswap/PairERC20.sol";
import {PairMissingEnumerableERC20} from "sudoswap/PairMissingEnumerableERC20.sol";
import {PairEnumerableERC20} from "sudoswap/PairEnumerableERC20.sol";
import {ICurve} from "src/interfaces/ICurve.sol";
import {PairCloner} from "src/lib/PairCloner.sol";
import {IPairFactoryLike} from "src/interfaces/IPairFactoryLike.sol";
import {PairMissingEnumerableETH} from "src/MoonPairMissingEnumerableETH.sol";
import {PairEnumerableETH} from "src/MoonPairEnumerableETH.sol";
import {Moon} from "src/Moon.sol";

contract PairFactory is Owned, IPairFactoryLike {
    using PairCloner for address;
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;

    /**
        @notice Creates a pair contract using EIP-1167.
        @param _nft The NFT contract of the collection the pair trades
        @param _bondingCurve The bonding curve for the pair to price NFTs, must be whitelisted
        @param _assetRecipient The address that will receive the assets traders give during trades.
                                If set to address(0), assets will be sent to the pool address.
                                Not available to TRADE pools.
        @param _poolType TOKEN, NFT, or TRADE
        @param _delta The delta value used by the bonding curve. The meaning of delta depends
        on the specific curve.
        @param _fee The fee taken by the LP in each trade. Can only be non-zero if _poolType is Trade.
        @param _spotPrice The initial selling spot price, in ETH
        @param _initialNFTIDs The list of IDs of NFTs to transfer from the sender to the pair
        @param _initialTokenBalance The initial token balance sent from the sender to the new pair
        @return pair The new pair
     */
    struct CreateERC20PairParams {
        ERC20 token;
        IERC721 nft;
        ICurve bondingCurve;
        address payable assetRecipient;
        Pair.PoolType poolType;
        uint128 delta;
        uint96 fee;
        uint128 spotPrice;
        uint256[] initialNFTIDs;
        uint256 initialTokenBalance;
    }

    struct RouterStatus {
        bool allowed;
        bool wasEverAllowed;
    }

    bytes4 private constant INTERFACE_ID_ERC721_ENUMERABLE =
        type(IERC721Enumerable).interfaceId;

    uint256 internal constant MAX_PROTOCOL_FEE = 0.10e18; // 10%, must <= 1 - MAX_FEE

    PairEnumerableETH public immutable enumerableETHTemplate;
    PairMissingEnumerableETH public immutable missingEnumerableETHTemplate;
    PairEnumerableERC20 public immutable enumerableERC20Template;
    PairMissingEnumerableERC20 public immutable missingEnumerableERC20Template;
    address payable public override protocolFeeRecipient;

    // Units are in base 1e18
    uint256 public override protocolFeeMultiplier;

    // MOON token
    Moon public moon;

    mapping(ICurve => bool) public bondingCurveAllowed;
    mapping(address => bool) public override callAllowed;
    mapping(Router => RouterStatus) public override routerStatus;

    event SetMoon(Moon);
    event NewPair(address poolAddress);
    event TokenDeposit(address poolAddress);
    event NFTDeposit(address poolAddress);
    event ProtocolFeeRecipientUpdate(address recipientAddress);
    event ProtocolFeeMultiplierUpdate(uint256 newMultiplier);
    event BondingCurveStatusUpdate(ICurve bondingCurve, bool isAllowed);
    event CallTargetStatusUpdate(address target, bool isAllowed);
    event RouterStatusUpdate(Router router, bool isAllowed);

    error InvalidFee();
    error InvalidAddress();
    error AlreadySet();

    constructor(
        PairEnumerableETH _enumerableETHTemplate,
        PairMissingEnumerableETH _missingEnumerableETHTemplate,
        PairEnumerableERC20 _enumerableERC20Template,
        PairMissingEnumerableERC20 _missingEnumerableERC20Template,
        address payable _protocolFeeRecipient,
        uint256 _protocolFeeMultiplier
    ) Owned(msg.sender) {
        enumerableETHTemplate = _enumerableETHTemplate;
        missingEnumerableETHTemplate = _missingEnumerableETHTemplate;
        enumerableERC20Template = _enumerableERC20Template;
        missingEnumerableERC20Template = _missingEnumerableERC20Template;
        protocolFeeRecipient = _protocolFeeRecipient;

        if (_protocolFeeMultiplier > MAX_PROTOCOL_FEE) revert InvalidFee();

        protocolFeeMultiplier = _protocolFeeMultiplier;
    }

    /**
     * External functions
     */

    /**
     * @notice Enables the owner to set the MOON protocol token
     * @dev    Separate method instead of constructor to minimize test changes
     * @param  _moon  Moon  MOON token contract
     */
    function setMoon(Moon _moon) external onlyOwner {
        if (address(_moon) == address(0)) revert InvalidAddress();

        // Token cannot be re-set
        if (address(moon) != address(0)) revert AlreadySet();

        moon = _moon;

        emit SetMoon(_moon);
    }

    /**
        @notice Creates a pair contract using EIP-1167.
        @param _nft The NFT contract of the collection the pair trades
        @param _bondingCurve The bonding curve for the pair to price NFTs, must be whitelisted
        @param _assetRecipient The address that will receive the assets traders give during trades.
                              If set to address(0), assets will be sent to the pool address.
                              Not available to TRADE pools.
        @param _poolType TOKEN, NFT, or TRADE
        @param _delta The delta value used by the bonding curve. The meaning of delta depends
        on the specific curve.
        @param _fee The fee taken by the LP in each trade. Can only be non-zero if _poolType is Trade.
        @param _spotPrice The initial selling spot price
        @param _initialNFTIDs The list of IDs of NFTs to transfer from the sender to the pair
        @return pair The new pair
     */
    function createPairETH(
        IERC721 _nft,
        ICurve _bondingCurve,
        address payable _assetRecipient,
        Pair.PoolType _poolType,
        uint128 _delta,
        uint96 _fee,
        uint128 _spotPrice,
        uint256[] calldata _initialNFTIDs
    ) external payable returns (PairETH pair) {
        require(
            bondingCurveAllowed[_bondingCurve],
            "Bonding curve not whitelisted"
        );

        // Check to see if the NFT supports Enumerable to determine which template to use
        address template;
        try
            IERC165(address(_nft)).supportsInterface(
                INTERFACE_ID_ERC721_ENUMERABLE
            )
        returns (bool isEnumerable) {
            template = isEnumerable
                ? address(enumerableETHTemplate)
                : address(missingEnumerableETHTemplate);
        } catch {
            template = address(missingEnumerableETHTemplate);
        }

        pair = PairETH(
            payable(
                template.cloneETHPair(
                    this,
                    _bondingCurve,
                    _nft,
                    uint8(_poolType)
                )
            )
        );

        _initializePairETH(
            pair,
            _nft,
            _assetRecipient,
            _delta,
            _fee,
            _spotPrice,
            _initialNFTIDs
        );

        // Set the MOON token on the pair
        PairEnumerableETH(payable(address(pair))).setMoon(moon);

        // Enable pair contract to issue MOON rewards (ETH pairs only)
        moon.addMinter(address(pair));

        emit NewPair(address(pair));
    }

    function createPairERC20(
        CreateERC20PairParams calldata params
    ) external returns (PairERC20 pair) {
        require(
            bondingCurveAllowed[params.bondingCurve],
            "Bonding curve not whitelisted"
        );

        // Check to see if the NFT supports Enumerable to determine which template to use
        address template;
        try
            IERC165(address(params.nft)).supportsInterface(
                INTERFACE_ID_ERC721_ENUMERABLE
            )
        returns (bool isEnumerable) {
            template = isEnumerable
                ? address(enumerableERC20Template)
                : address(missingEnumerableERC20Template);
        } catch {
            template = address(missingEnumerableERC20Template);
        }

        pair = PairERC20(
            payable(
                template.cloneERC20Pair(
                    this,
                    params.bondingCurve,
                    params.nft,
                    uint8(params.poolType),
                    params.token
                )
            )
        );

        _initializePairERC20(
            pair,
            params.token,
            params.nft,
            params.assetRecipient,
            params.delta,
            params.fee,
            params.spotPrice,
            params.initialNFTIDs,
            params.initialTokenBalance
        );

        emit NewPair(address(pair));
    }

    /**
        @notice Checks if an address is a Pair. Uses the fact that the pairs are EIP-1167 minimal proxies.
        @param potentialPair The address to check
        @param variant The pair variant (NFT is enumerable or not, pair uses ETH or ERC20)
        @return True if the address is the specified pair variant, false otherwise
     */
    function isPair(
        address potentialPair,
        PairVariant variant
    ) public view override returns (bool) {
        if (variant == PairVariant.ENUMERABLE_ERC20) {
            return
                PairCloner.isERC20PairClone(
                    address(this),
                    address(enumerableERC20Template),
                    potentialPair
                );
        } else if (variant == PairVariant.MISSING_ENUMERABLE_ERC20) {
            return
                PairCloner.isERC20PairClone(
                    address(this),
                    address(missingEnumerableERC20Template),
                    potentialPair
                );
        } else if (variant == PairVariant.ENUMERABLE_ETH) {
            return
                PairCloner.isETHPairClone(
                    address(this),
                    address(enumerableETHTemplate),
                    potentialPair
                );
        } else if (variant == PairVariant.MISSING_ENUMERABLE_ETH) {
            return
                PairCloner.isETHPairClone(
                    address(this),
                    address(missingEnumerableETHTemplate),
                    potentialPair
                );
        } else {
            // invalid input
            return false;
        }
    }

    /**
        @notice Allows receiving ETH in order to receive protocol fees
     */
    receive() external payable {}

    /**
     * Admin functions
     */

    /**
        @notice Withdraws the ETH balance to the protocol fee recipient.
        Only callable by the owner.
     */
    function withdrawETHProtocolFees() external onlyOwner {
        protocolFeeRecipient.safeTransferETH(address(this).balance);
    }

    /**
        @notice Withdraws ERC20 tokens to the protocol fee recipient. Only callable by the owner.
        @param token The token to transfer
        @param amount The amount of tokens to transfer
     */
    function withdrawERC20ProtocolFees(
        ERC20 token,
        uint256 amount
    ) external onlyOwner {
        token.safeTransfer(protocolFeeRecipient, amount);
    }

    /**
        @notice Changes the protocol fee recipient address. Only callable by the owner.
        @param _protocolFeeRecipient The new fee recipient
     */
    function changeProtocolFeeRecipient(
        address payable _protocolFeeRecipient
    ) external onlyOwner {
        require(_protocolFeeRecipient != address(0), "0 address");
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdate(_protocolFeeRecipient);
    }

    /**
        @notice Changes the protocol fee multiplier. Only callable by the owner.
        @param _protocolFeeMultiplier The new fee multiplier, 18 decimals
     */
    function changeProtocolFeeMultiplier(
        uint256 _protocolFeeMultiplier
    ) external onlyOwner {
        require(_protocolFeeMultiplier <= MAX_PROTOCOL_FEE, "Fee too large");
        protocolFeeMultiplier = _protocolFeeMultiplier;
        emit ProtocolFeeMultiplierUpdate(_protocolFeeMultiplier);
    }

    /**
        @notice Sets the whitelist status of a bonding curve contract. Only callable by the owner.
        @param bondingCurve The bonding curve contract
        @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setBondingCurveAllowed(
        ICurve bondingCurve,
        bool isAllowed
    ) external onlyOwner {
        bondingCurveAllowed[bondingCurve] = isAllowed;
        emit BondingCurveStatusUpdate(bondingCurve, isAllowed);
    }

    /**
        @notice Sets the whitelist status of a contract to be called arbitrarily by a pair.
        Only callable by the owner.
        @param target The target contract
        @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setCallAllowed(
        address payable target,
        bool isAllowed
    ) external onlyOwner {
        // ensure target is not / was not ever a router
        if (isAllowed) {
            require(
                !routerStatus[Router(target)].wasEverAllowed,
                "Can't call router"
            );
        }

        callAllowed[target] = isAllowed;
        emit CallTargetStatusUpdate(target, isAllowed);
    }

    /**
        @notice Updates the router whitelist. Only callable by the owner.
        @param _router The router
        @param isAllowed True to whitelist, false to remove from whitelist
     */
    function setRouterAllowed(
        Router _router,
        bool isAllowed
    ) external onlyOwner {
        // ensure target is not arbitrarily callable by pairs
        if (isAllowed) {
            require(!callAllowed[address(_router)], "Can't call router");
        }
        routerStatus[_router] = RouterStatus({
            allowed: isAllowed,
            wasEverAllowed: true
        });

        emit RouterStatusUpdate(_router, isAllowed);
    }

    /**
     * Internal functions
     */

    function _initializePairETH(
        PairETH _pair,
        IERC721 _nft,
        address payable _assetRecipient,
        uint128 _delta,
        uint96 _fee,
        uint128 _spotPrice,
        uint256[] calldata _initialNFTIDs
    ) internal {
        // initialize pair
        _pair.initialize(msg.sender, _assetRecipient, _delta, _fee, _spotPrice);

        // transfer initial ETH to pair
        payable(address(_pair)).safeTransferETH(msg.value);

        // transfer initial NFTs from sender to pair
        uint256 numNFTs = _initialNFTIDs.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.safeTransferFrom(
                msg.sender,
                address(_pair),
                _initialNFTIDs[i]
            );

            unchecked {
                ++i;
            }
        }
    }

    function _initializePairERC20(
        PairERC20 _pair,
        ERC20 _token,
        IERC721 _nft,
        address payable _assetRecipient,
        uint128 _delta,
        uint96 _fee,
        uint128 _spotPrice,
        uint256[] calldata _initialNFTIDs,
        uint256 _initialTokenBalance
    ) internal {
        // initialize pair
        _pair.initialize(msg.sender, _assetRecipient, _delta, _fee, _spotPrice);

        // transfer initial tokens to pair
        _token.safeTransferFrom(
            msg.sender,
            address(_pair),
            _initialTokenBalance
        );

        // transfer initial NFTs from sender to pair
        uint256 numNFTs = _initialNFTIDs.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.safeTransferFrom(
                msg.sender,
                address(_pair),
                _initialNFTIDs[i]
            );

            unchecked {
                ++i;
            }
        }
    }

    /**
      @dev Used to deposit NFTs into a pair after creation and emit an event for indexing (if recipient is indeed a pair)
    */
    function depositNFTs(
        IERC721 _nft,
        uint256[] calldata ids,
        address recipient
    ) external {
        // transfer NFTs from caller to recipient
        uint256 numNFTs = ids.length;
        for (uint256 i; i < numNFTs; ) {
            _nft.safeTransferFrom(msg.sender, recipient, ids[i]);

            unchecked {
                ++i;
            }
        }
        if (
            isPair(recipient, PairVariant.ENUMERABLE_ERC20) ||
            isPair(recipient, PairVariant.ENUMERABLE_ETH) ||
            isPair(recipient, PairVariant.MISSING_ENUMERABLE_ERC20) ||
            isPair(recipient, PairVariant.MISSING_ENUMERABLE_ETH)
        ) {
            emit NFTDeposit(recipient);
        }
    }

    /**
      @dev Used to deposit ERC20s into a pair after creation and emit an event for indexing (if recipient is indeed an ERC20 pair and the token matches)
     */
    function depositERC20(
        ERC20 token,
        address recipient,
        uint256 amount
    ) external {
        token.safeTransferFrom(msg.sender, recipient, amount);
        if (
            isPair(recipient, PairVariant.ENUMERABLE_ERC20) ||
            isPair(recipient, PairVariant.MISSING_ENUMERABLE_ERC20)
        ) {
            if (token == PairERC20(recipient).token()) {
                emit TokenDeposit(recipient);
            }
        }
    }
}
