// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Owned} from "solmate/auth/Owned.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Clones} from "openzeppelin/proxy/Clones.sol";
import {MoonPage} from "src/MoonPage.sol";

contract MoonBook is
    Owned,
    ERC20("Redeemable Token", "MOON", 18),
    ReentrancyGuard
{
    using SafeTransferLib for ERC20;
    using SafeTransferLib for ERC4626;
    using SafeTransferLib for address payable;
    using FixedPointMathLib for uint256;

    // Paired with the collection address to compute the CREATE2 salt
    bytes12 public constant SALT_FRAGMENT = bytes12("JPAGE||EGAPJ");

    // Maximum duration users must wait to redeem the full ETH value of MOON
    uint256 public constant MAX_REDEMPTION_DURATION = 28 days;

    // For calculating the instant redemption amount
    uint256 public constant INSTANT_REDEMPTION_VALUE_BASE = 100;

    // MoonPage implementation contract address
    address public immutable pageImplementation;

    // ETH staker contract
    ERC20 public staker;

    // Vault contract
    ERC4626 public vault;

    // Instant redemptions enable users to redeem their ETH rebates immediately
    // by giving up a portion of MOON. The default instant redemption value is
    // 75% of the redeemed MOON amount, but may be tweaked in production
    uint256 public instantRedemptionValue = 75;

    // ERC721 collections mapped to their MoonPage contracts
    mapping(ERC721 => address) public pages;

    mapping(address => mapping(uint256 => uint256)) public pendingRedemptions;

    event SetStaker(address indexed msgSender, ERC20 staker);
    event SetVault(address indexed msgSender, ERC4626 vault);
    event SetInstantRedemptionValue(
        address indexed msgSender,
        uint256 instantRedemptionValue
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidRedemption();
    error AlreadyExists();

    constructor(ERC20 _staker, ERC4626 _vault) Owned(msg.sender) {
        if (address(_staker) == address(0)) revert InvalidAddress();
        if (address(_vault) == address(0)) revert InvalidAddress();

        pageImplementation = address(new MoonPage());
        staker = _staker;
        vault = _vault;

        // Allow the vault to transfer stETH on this contract's behalf
        staker.safeApprove(address(_vault), type(uint256).max);
    }

    /**
     * @notice Stake ETH
     * @return balance  uint256  ETH balance staked
     * @return assets   uint256  Vault assets deposited
     * @return shares   uint256  Vault shares received
     */
    function _stakeETH()
        private
        returns (uint256 balance, uint256 assets, uint256 shares)
    {
        balance = address(this).balance;

        // Only execute ETH-staking functions if the ETH balance is non-zero
        if (balance != 0) {
            // Stake ETH balance - reverts if msg.value is zero
            payable(address(staker)).safeTransferETH(balance);

            // Fetch staked ETH balance, the amount which will be deposited into the vault
            assets = staker.balanceOf(address(this));

            // Maximize returns with the staking vault - the Moon contract receives shares
            shares = vault.deposit(assets, address(this));
        }
    }

    /**
     * @notice Instantly redeem MOON for the underlying assets at partial value
     * @param  amount    uint256  MOON amount
     * @return redeemed  uint256  Redeemed MOON
     * @return shares    uint256  Redeemed vault shares
     */
    function _instantRedemption(
        uint256 amount
    ) private returns (uint256 redeemed, uint256 shares) {
        // NOTE: Due to rounding, the redeemed amount will be zero if `amount` is too small
        // The remainder of the function logic assumes that the caller is a logical actor
        // since redeeming extremely small amounts of MOON is uneconomical due to gas fees
        redeemed = amount.mulDivDown(
            instantRedemptionValue,
            INSTANT_REDEMPTION_VALUE_BASE
        );

        // Stake ETH first to ensure that the contract's vault share balance is current
        _stakeETH();

        // Calculate the amount of vault shares redeemed - based on the proportion of
        // the redeemed MOON amount to the total MOON supply
        shares = vault.balanceOf(address(this)).mulDivDown(
            redeemed,
            totalSupply
        );

        // Burn MOON from msg.sender - reverts if their balance is insufficient
        _burn(msg.sender, amount);

        // Mint MOON for the owner, equal to the unredeemed amount
        _mint(owner, amount - redeemed);

        // Transfer the redeemed amount to msg.sender (vault shares, as good as ETH)
        vault.safeTransfer(msg.sender, shares);
    }

    function createPage(ERC721 collection) external returns (address page) {
        // Prevent pages from being re-deployed and overwritten
        if (pages[collection] != address(0)) revert AlreadyExists();

        page = Clones.cloneDeterministic(
            pageImplementation,
            keccak256(abi.encodePacked(collection, SALT_FRAGMENT))
        );

        // Initialize minimal proxy with the owner and collection
        MoonPage(page).initialize(owner, collection);

        // Update the mapping to point the collection to its page
        pages[collection] = page;
    }

    /**
     * @notice Set staker
     * @param  _staker  ERC20  Staker contract
     */
    function setStaker(ERC20 _staker) external onlyOwner {
        if (address(_staker) == address(0)) revert InvalidAddress();

        address vaultAddr = address(vault);

        // Set the vault's allowance to zero for the previous staker
        staker.safeApprove(vaultAddr, 0);

        // Set the new staker
        staker = _staker;

        // Set the vault's allowance to the maximum for the current staker
        _staker.safeApprove(vaultAddr, type(uint256).max);

        emit SetStaker(msg.sender, _staker);
    }

    /**
     * @notice Set the instant redemption value
     * @param  _vault  ERC4626  Vault contract
     */
    function setVault(ERC4626 _vault) external onlyOwner {
        if (address(_vault) == address(0)) revert InvalidAddress();

        // Set the previous vault's allowance to zero
        staker.safeApprove(address(vault), 0);

        // Set the new vault
        vault = _vault;

        // Set the new vault's allowance to the maximum
        staker.safeApprove(address(_vault), type(uint256).max);

        emit SetVault(msg.sender, _vault);
    }

    /**
     * @notice Set the instant redemption value
     * @param  _instantRedemptionValue  uint256  Instant redemption value
     */
    function setInstantRedemptionValue(
        uint256 _instantRedemptionValue
    ) external onlyOwner {
        if (_instantRedemptionValue > INSTANT_REDEMPTION_VALUE_BASE)
            revert InvalidAmount();

        // Set the new instantRedemptionValue
        instantRedemptionValue = _instantRedemptionValue;

        emit SetInstantRedemptionValue(msg.sender, _instantRedemptionValue);
    }

    /**
     * @notice Deposit ETH, receive MOON
     * @param  recipient  address  MOON recipient address
     */
    function depositETH(address recipient) external payable {
        if (msg.value == 0) revert InvalidAmount();

        // Mint MOON for msg.sender, equal to the ETH deposited
        _mint(recipient, msg.value);
    }

    /**
     * @notice Stake ETH
     * @return uint256  ETH balance staked
     * @return uint256  Vault assets deposited
     * @return uint256  Vault shares received
     */
    function stakeETH()
        external
        nonReentrant
        returns (uint256, uint256, uint256)
    {
        return _stakeETH();
    }

    /**
     * @notice Begin a MOON redemption
     * @param  amount    uint256  MOON amount
     * @param  duration  uint256  Queue duration in seconds
     * @return redeemed  uint256  Redeemed MOON
     * @return shares    uint256  Redeemed vault shares
     */
    function initiateRedemption(
        uint256 amount,
        uint256 duration
    ) external nonReentrant returns (uint256 redeemed, uint256 shares) {
        if (amount == 0) revert InvalidAmount();
        if (duration > MAX_REDEMPTION_DURATION) revert InvalidAmount();

        // Perform an instant redemption if the duration is zero
        if (duration == 0) {
            return _instantRedemption(amount);
        }

        // The redeemed amount is based on the total duration the user is willing
        // to wait for their redemption to complete (waiting the max duration
        // results in 100% of the underlying ETH-based assets being redeemed)
        redeemed = amount.mulDivDown(duration, MAX_REDEMPTION_DURATION);

        // Stake ETH first to ensure that the contract's vault share balance is current
        _stakeETH();

        // Calculate the amount of vault shares redeemed - based on the proportion of
        // the redeemed MOON amount to the total MOON supply
        shares = vault.balanceOf(address(this)).mulDivDown(
            redeemed,
            totalSupply
        );

        // Burn MOON from msg.sender - reverts if their balance is insufficient
        _burn(msg.sender, amount);

        // If amount does not equal redeemed, then `duration` is less than the maximum
        if (duration != MAX_REDEMPTION_DURATION) {
            _mint(owner, amount - redeemed);
        }

        // Set the amount of shares that the user can claim after the duration has elapsed
        pendingRedemptions[msg.sender][block.timestamp + duration] += shares;
    }

    /**
     * @notice Fulfill a MOON redemption
     * @param  redemptionTimestamp  uint256  MOON amount
     * @return shares               uint256  Redeemed vault shares
     */
    function fulfillRedemption(
        uint256 redemptionTimestamp
    ) external nonReentrant returns (uint256 shares) {
        // If the redemption timestamp is before the current time, then it's too early - revert
        if (redemptionTimestamp < block.timestamp) revert InvalidRedemption();

        shares = pendingRedemptions[msg.sender][redemptionTimestamp];

        // If the redeemable amount is zero then the redemption was already claimed or non-existent
        if (shares == 0) revert InvalidRedemption();

        // Zero out the pending redemption amount prior to transferring shares
        pendingRedemptions[msg.sender][redemptionTimestamp] = 0;

        // Stake ETH to ensure there are sufficient shares to fulfill the redemption
        _stakeETH();

        vault.safeTransfer(msg.sender, shares);
    }
}
