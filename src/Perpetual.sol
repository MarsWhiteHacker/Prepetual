// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "forge-std/console.sol";

/**
 * @title Perpetual
 * @author Den Sosnovskyi
 * @notice The contract is used as perpetual DeFi solution
 * Only one token can be used as collateral for both long and short positions.
 * The same token is deposited by LPs.
 * @dev Chainlink is used as a price oracle. Before creating the contract with particular
 * index and asset tokens, make sure Chainlink has a price feed pairs with the tokens ans USD
 */
contract Perpetual is ERC4626, ReentrancyGuard {
    error Perpetual__WrongDecimals();
    error Perpetual__NotEnoughAssets();
    error Perpetual__PublicMintIsNowAllowed();
    error Perpetual__PublicRedeemIsNowAllowed();
    error Perpetual__CollateralBelowMaxLeverage();
    error Perpetual__LiquidityReservesBelowThreshold();
    error Perpetual__AssetsAmountBiggerThanLiquidity();

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_LEVERAGE = 15;
    uint256 private constant MAX_UTILIZATION_PERCENTAGE = 1;

    address private immutable i_indexToken;
    AggregatorV3Interface private immutable i_assetPriceFeed;
    AggregatorV3Interface private immutable i_indexTokenPriceFeed;

    uint256 private s_depositedLiquidity;
    uint256 private s_shortOpenInterest;
    uint256 private s_shortOpenInterestInTokens;
    uint256 private s_longOpenInterest;
    uint256 private s_longOpenInterestInTokens;
    mapping(address => uint256) private s_userToCollateral;
    mapping(address => uint256) private s_userToLongOpenInterest;
    mapping(address => uint256) private s_userToShortOpenInterest;
    mapping(address => uint256) private s_userToLongOpenInterestInTokens;
    mapping(address => uint256) private s_userToShortOpenInterestInTokens;

    event UpdatedDepositedLiquidity(
        uint256 indexed _before,
        uint256 indexed _after
    );
    event AddedCollateral(uint256 indexed amount, address indexed sender);
    event AddedPosition(
        uint256 indexed amount,
        address indexed sender,
        bool indexed isLong
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

    /**
     * Count all deposists made by LPs
     * Does not count collaterals made by traders
     */
    function totalAssets() public view override returns (uint256) {
        int256 pnl = _countPnl();

        if (pnl > 0) {
            return s_depositedLiquidity - uint256(pnl);
        } else {
            return s_depositedLiquidity + uint256(-pnl);
        }
    }

    /** deposit _asset by LP */
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 deposited) {
        if (assets == 0) {
            revert Perpetual__NotEnoughAssets();
        }

        uint256 oldDepositedLiquidity = s_depositedLiquidity;
        uint256 newDepositedLiquidity = oldDepositedLiquidity + assets;

        deposited = super.deposit(assets, receiver);
        s_depositedLiquidity = newDepositedLiquidity;

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
    ) public override nonReentrant returns (uint256 withdrawn) {
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

        withdrawn = super.withdraw(assets, receiver, owner);
        s_depositedLiquidity = newDepositedLiquidity;

        if (!_checkLiquidityReservesThreshold()) {
            revert Perpetual__LiquidityReservesBelowThreshold();
        }

        emit UpdatedDepositedLiquidity(
            oldDepositedLiquidity,
            newDepositedLiquidity
        );
    }

    function addCollateral(uint256 amount) public nonReentrant {
        s_userToCollateral[msg.sender] += amount;

        SafeERC20.safeTransferFrom(
            IERC20(asset()),
            msg.sender,
            address(this),
            amount
        );

        emit AddedCollateral(amount, msg.sender);
    }

    function addPosition(uint256 amount, bool isLong) public {
        uint256 assetPriceFeedDecimals = i_assetPriceFeed.decimals();
        uint256 indexTokenPriceFeedDecimals = i_assetPriceFeed.decimals();

        uint256 generalInterest = s_userToLongOpenInterest[msg.sender] +
            s_userToShortOpenInterest[msg.sender] +
            amount;
        uint256 indexTokenAmount = (amount *
            _assetTokenToIndexTokenPrice() *
            indexTokenPriceFeedDecimals) / (assetPriceFeedDecimals * PRECISION);

        if (!_isValidLeverage(msg.sender, generalInterest)) {
            revert Perpetual__CollateralBelowMaxLeverage();
        }

        if (isLong) {
            s_longOpenInterest += amount;
            s_userToLongOpenInterest[msg.sender] += amount;
            s_longOpenInterestInTokens += indexTokenAmount;
            s_userToLongOpenInterestInTokens[msg.sender] += indexTokenAmount;
        } else {
            s_shortOpenInterest += amount;
            s_userToShortOpenInterest[msg.sender] += amount;
            s_shortOpenInterestInTokens += indexTokenAmount;
            s_userToShortOpenInterestInTokens[msg.sender] += indexTokenAmount;
        }

        if (!_checkLiquidityReservesThreshold()) {
            revert Perpetual__LiquidityReservesBelowThreshold();
        }

        emit AddedPosition(amount, msg.sender, isLong);
    }

    function openPosition(
        uint256 collateralAmount,
        uint256 positionSize,
        bool isLong
    ) external {
        addCollateral(collateralAmount);
        addPosition(positionSize, isLong);
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
        uint256 assetPriceFeedDecimals = i_assetPriceFeed.decimals();

        isValid =
            ((s_shortOpenInterest * PRECISION) / assetPriceFeedDecimals) +
                ((s_longOpenInterestInTokens * _indexTokenToAssetTokenPrice()) /
                    assetPriceFeedDecimals) <=
            ((s_depositedLiquidity * MAX_UTILIZATION_PERCENTAGE * PRECISION) /
                assetPriceFeedDecimals);
    }

    /** returns assetToken/indexToken or indexToken/assetToken price with 10e18 decimals percision */
    function _tokenPrice(
        address tokenToCalculatePrice
    ) internal view returns (uint256) {
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

        if (tokenToCalculatePrice == asset()) {
            return
                (uint256(assetPriceInUsd) *
                    indexTokenPriceFeedDecimals *
                    PRECISION) /
                (uint256(indexTokenPriceInUsd) * assetPriceFeedDecimals);
        } else {
            return
                (uint256(indexTokenPriceInUsd) *
                    assetPriceFeedDecimals *
                    PRECISION) /
                (uint256(assetPriceInUsd) * indexTokenPriceFeedDecimals);
        }
    }

    /** returns index token price in asset token with 10e18 decimals percision */
    function _indexTokenToAssetTokenPrice() internal view returns (uint256) {
        return _tokenPrice(i_indexToken);
    }

    /** returns asset token price in index token with 10e18 decimals percision */
    function _assetTokenToIndexTokenPrice() internal view returns (uint256) {
        return _tokenPrice(asset());
    }

    function _countLongPnL() internal view returns (int256) {
        return
            int256(
                (s_longOpenInterestInTokens * _indexTokenToAssetTokenPrice()) /
                    PRECISION
            ) - int256(s_longOpenInterest);
    }

    function _countLongPnL(address user) internal view returns (int256) {
        return
            int256(
                (s_userToLongOpenInterestInTokens[user] *
                    _indexTokenToAssetTokenPrice()) / PRECISION
            ) - int256(s_userToLongOpenInterest[user]);
    }

    function _countShortPnL() internal view returns (int256) {
        return
            int256(s_shortOpenInterest) -
            int256(
                (s_shortOpenInterestInTokens * _indexTokenToAssetTokenPrice()) /
                    PRECISION
            );
    }

    function _countShortPnL(address user) internal view returns (int256) {
        return
            int256(s_userToShortOpenInterest[user]) -
            int256(
                (s_userToShortOpenInterestInTokens[user] *
                    _indexTokenToAssetTokenPrice()) / PRECISION
            );
    }

    function _countPnl() internal view returns (int256) {
        return _countLongPnL() + _countShortPnL();
    }

    function _countPnl(address user) internal view returns (int256) {
        return _countLongPnL(user) + _countShortPnL(user);
    }

    function _isValidLeverage(
        address user,
        uint256 positionAmount
    ) internal view returns (bool) {
        return
            _currentUserLeverage(user, positionAmount) <
            int256(MAX_LEVERAGE * PRECISION);
    }

    /** returns leverage with 18 decimals */
    function _currentUserLeverage(
        address user,
        uint256 positionAmount
    ) internal view returns (int256) {
        int256 denominator = (int256(s_userToCollateral[user]) +
            _countPnl(user));

        if (denominator <= 0) {
            return type(int256).max;
        }

        return int256(positionAmount * PRECISION) / denominator;
    }

    function currentUserLeverage(
        address user,
        uint256 positionAmount
    ) external view returns (int256) {
        return _currentUserLeverage(user, positionAmount);
    }

    function indexTokenToAssetTokenPrice() external view returns (uint256) {
        return _indexTokenToAssetTokenPrice();
    }

    function assetTokenToIndexTokenPrice() external view returns (uint256) {
        return _assetTokenToIndexTokenPrice();
    }

    function checkLiquidityReservesThreshold()
        external
        view
        returns (bool isValid)
    {
        return _checkLiquidityReservesThreshold();
    }

    function isValidLeverage(
        address user,
        uint256 positionAmount
    ) external view returns (bool) {
        return _isValidLeverage(user, positionAmount);
    }

    function countPnl() external view returns (int256) {
        return _countPnl();
    }

    function countPnl(address user) external view returns (int256) {
        return _countPnl(user);
    }

    /// Getters

    function getIndexToken() external view returns (address) {
        return i_indexToken;
    }

    function depositedLiquidity() external view returns (uint256) {
        return s_depositedLiquidity;
    }

    function getShortOpenInterest() external view returns (uint256) {
        return s_shortOpenInterest;
    }

    function getShortOpenInterestInTokens() external view returns (uint256) {
        return s_shortOpenInterestInTokens;
    }

    function getLongOpenInterest() external view returns (uint256) {
        return s_longOpenInterest;
    }

    function getLongOpenInterestInTokens() external view returns (uint256) {
        return s_longOpenInterestInTokens;
    }

    function getUserCollatral(address user) external view returns (uint256) {
        return s_userToCollateral[user];
    }

    function getUserLongOpenInterest(
        address user
    ) external view returns (uint256) {
        return s_userToLongOpenInterest[user];
    }

    function getUserShortOpenInterest(
        address user
    ) external view returns (uint256) {
        return s_userToShortOpenInterest[user];
    }

    function getUserLongOpenInterestInTokens(
        address user
    ) external view returns (uint256) {
        return s_userToLongOpenInterestInTokens[user];
    }

    function getUserShortOpenInterestInTokens(
        address user
    ) external view returns (uint256) {
        return s_userToShortOpenInterestInTokens[user];
    }

    function getIndexTokenPriceFeed() external view returns (address) {
        return address(i_indexTokenPriceFeed);
    }

    function getAssetTokenPriceFeed() external view returns (address) {
        return address(i_assetPriceFeed);
    }
}
