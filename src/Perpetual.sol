// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title Perpetual
 * @author Den Sosnovskyi
 * @notice The contract is used as perpetual DeFi solution
 * Only one token can be used as collateral for both long and short positions.
 * The same token is deposited by LPs.
 * @dev Chainlink is used as a price oracle. Before creating the contract with particular
 * index and asset tokens, make sure Chainlink has a price feed pairs with the tokens ans USD
 */
contract Perpetual is ERC4626 {
    error Perpetual__WrongDecimals();
    error Perpetual__NotEnoughAssets();
    error Perpetual__PublicMintIsNowAllowed();
    error Perpetual__PublicRedeemIsNowAllowed();
    error Perpetual__LiquidityReservesBelowThreshold();
    error Perpetual__AssetsAmountBiggerThanLiquidity();

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_UTILIZATION_PERCENTAGE = 1;

    address private immutable i_indexToken;
    AggregatorV3Interface private immutable i_assetPriceFeed;
    AggregatorV3Interface private immutable i_indexTokenPriceFeed;

    uint256 private s_depositedLiquidity;
    uint256 private s_shortOpenInterest;
    uint256 private s_shortOpenInterestInTokens;
    uint256 private s_longOpenInterest;
    uint256 private s_longOpenInterestInTokens;

    event UpdatedDepositedLiquidity(
        uint256 indexed _before,
        uint256 indexed _after
    );

    /**
     * @param _asset a token used for deposting by LPs and for collateral
     * @param _indexToken a token traders are going to trade with by using collateral
     * @param _assetPriceFeed asset price feed in USD
     * @param _indexTokenPriceFeed indexToken price feed in USD
     */
    constructor(
        address _asset,
        address _indexToken,
        address _assetPriceFeed,
        address _indexTokenPriceFeed
    ) ERC4626(IERC20(_asset)) ERC20("Perpetual", "PTL") {
        i_indexToken = _indexToken;
        i_assetPriceFeed = AggregatorV3Interface(_assetPriceFeed);
        i_indexTokenPriceFeed = AggregatorV3Interface(_indexTokenPriceFeed);
        if (
            i_assetPriceFeed.decimals() > 18 ||
            i_indexTokenPriceFeed.decimals() > 18
        ) {
            revert Perpetual__WrongDecimals();
        }
    }

    /** deposit _asset by LP */
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 deposited) {
        if (assets == 0) {
            revert Perpetual__NotEnoughAssets();
        }

        uint256 oldDepositedLiquidity = s_depositedLiquidity;
        uint256 newDepositedLiquidity = oldDepositedLiquidity + assets;
        s_depositedLiquidity = newDepositedLiquidity;

        deposited = super.deposit(assets, receiver);

        emit UpdatedDepositedLiquidity(
            oldDepositedLiquidity,
            newDepositedLiquidity
        );
    }

    /** withdraw _asset by LP */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 withdrawn) {
        if (assets == 0) {
            revert Perpetual__NotEnoughAssets();
        }

        uint256 oldDepositedLiquidity = s_depositedLiquidity;

        if (assets > oldDepositedLiquidity) {
            revert Perpetual__AssetsAmountBiggerThanLiquidity();
        }

        uint256 newDepositedLiquidity;
        unchecked {
            newDepositedLiquidity = oldDepositedLiquidity - assets;
        }
        s_depositedLiquidity = newDepositedLiquidity;

        if (!_checkLiquidityReservesThreshold()) {
            revert Perpetual__LiquidityReservesBelowThreshold();
        }

        withdrawn = super.withdraw(assets, receiver, owner);

        emit UpdatedDepositedLiquidity(
            oldDepositedLiquidity,
            newDepositedLiquidity
        );
    }

    /** The ERC4626 mint public function is not allowed */
    function mint(uint256, address) public pure override returns (uint256) {
        revert Perpetual__PublicMintIsNowAllowed();
    }

    /** The ERC4626 redeem public function is not allowed */
    function redeem(
        uint256,
        address,
        address
    ) public pure override returns (uint256) {
        revert Perpetual__PublicRedeemIsNowAllowed();
    }

    /**
     * The valiadtion is made by the next formula:
     * (shortOpenInterest) + (longOpenInterestInTokens * currentIndexTokenPrice) < (depositedLiquidity * maxUtilizationPercentage)
     */
    function _checkLiquidityReservesThreshold()
        internal
        view
        returns (bool isValid)
    {
        isValid =
            (s_shortOpenInterest) +
                (s_longOpenInterestInTokens * _indexTokenToAssetTokenPrice()) <
            (s_depositedLiquidity * MAX_UTILIZATION_PERCENTAGE * PRECISION);
    }

    /** returns index token price in asset token with 10e18 decimals percision */
    function _indexTokenToAssetTokenPrice() internal view returns (uint256) {
        (, int assetPriceInUsd, , , ) = i_assetPriceFeed.latestRoundData();
        uint256 assetPriceFeedDecimals = i_assetPriceFeed.decimals();

        (, int indexTokenPriceInUsd, , , ) = i_indexTokenPriceFeed
            .latestRoundData();
        uint256 indexTokenPriceFeedDecimals = i_assetPriceFeed.decimals();

        if (assetPriceFeedDecimals == 0) {
            assetPriceFeedDecimals = 1;
        }
        if (indexTokenPriceFeedDecimals == 0) {
            indexTokenPriceFeedDecimals = 1;
        }

        return
            (uint256(indexTokenPriceInUsd) *
                assetPriceFeedDecimals *
                PRECISION) /
            (uint256(assetPriceInUsd) * indexTokenPriceFeedDecimals);
    }

    function indexTokenToAssetTokenPrice() external view returns (uint256) {
        return _indexTokenToAssetTokenPrice();
    }

    function checkLiquidityReservesThreshold()
        external
        view
        returns (bool isValid)
    {
        return _checkLiquidityReservesThreshold();
    }

    /// Getters

    function getIndexToken() external view returns (address) {
        return i_indexToken;
    }

    function depositedLiquidity() external view returns (uint256) {
        return s_depositedLiquidity;
    }
}
