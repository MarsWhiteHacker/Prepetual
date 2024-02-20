// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
    error Perpetual__ShouldBeMsgSender();
    error Perpetual__NotEnoughCollateral();
    error Perpetual__ShouldNotBeMsgSender();
    error Perpetual__PublicMintIsNowAllowed();
    error Perpetual__PublicRedeemIsNowAllowed();
    error Perpetual__CollateralBelowMaxLeverage();
    error Perpetual__UserPositionsAreNotLiquidatable();
    error Perpetual__NotEnoughIndexTokensInPosition();
    error Perpetual__LiquidityReservesBelowThreshold();
    error Perpetual__AssetsAmountBiggerThanLiquidity();

    /**
     * The rate is 10% per year, or 1/315_360_000 per second
     * Borrowing fee per second = size / BORROWING_PER_SHARE_PER_SECOND
     */
    uint256 private constant BORROWING_PER_SHARE_PER_SECOND = 315_360_000;
    uint256 private constant BORROWING_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint8 private constant MAX_LEVERAGE = 15;
    uint8 private constant MAX_UTILIZATION_PERCENTAGE = 1;
    uint8 private constant LIQUIDATION_FEE = 50;

    uint256 private immutable i_startingTimestamp;
    address private immutable i_indexToken;
    AggregatorV3Interface private immutable i_assetPriceFeed;
    AggregatorV3Interface private immutable i_indexTokenPriceFeed;

    uint256 private s_depositedLiquidity;
    uint256 private s_lastTimestampUpdated;
    uint256 private s_longOpenInterest;
    uint256 private s_shortOpenInterest;
    uint256 private s_longOpenInterestInTokens;
    uint256 private s_shortOpenInterestInTokens;
    uint256 private s_longPrincipal;
    uint256 private s_shortPrincipal;
    mapping(address => uint256) private s_userToCollateral;
    mapping(address => uint256) private s_userToLongOpenInterest;
    mapping(address => uint256) private s_userToShortOpenInterest;
    mapping(address => uint256) private s_userToLongOpenInterestInTokens;
    mapping(address => uint256) private s_userToShortOpenInterestInTokens;
    /** traders' long positions divided by current borrowing percent */
    mapping(address => uint256) private s_userToLongPrincipal;
    /** traders' short positions divided by current borrowing percent */
    mapping(address => uint256) private s_userToShortPrincipal;

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
    event DecreasedCollateral(uint256 indexed amount, address indexed sender);
    event DecreasedPosition(
        uint256 indexed amount,
        int256 indexed pnl,
        address indexed sender,
        bool isLong
    );
    event Liquidated(
        address indexed from,
        address indexed who,
        uint256 indexed fee,
        uint256 positionSizeInTokens
    );

    modifier notMsgSender(address user) {
        if (user == msg.sender) {
            revert Perpetual__ShouldNotBeMsgSender();
        }
        _;
    }

    modifier isMsgSender(address user) {
        if (user != msg.sender) {
            revert Perpetual__ShouldBeMsgSender();
        }
        _;
    }

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
        i_startingTimestamp = block.timestamp;

        if (
            i_assetPriceFeed.decimals() > 18 ||
            i_indexTokenPriceFeed.decimals() > 18
        ) {
            revert Perpetual__WrongDecimals();
        }
    }

    /**
     * Counts all deposists made by LPs
     * Does not count collaterals made by traders
     */
    function totalAssets() public view override returns (uint256) {
        int256 pnl = _countPnl();

        if (pnl > 0) {
            return
                s_depositedLiquidity -
                SafeCast.toUint256(pnl) +
                _accruedBorrowingFee();
        } else {
            return
                s_depositedLiquidity +
                SafeCast.toUint256(-pnl) +
                _accruedBorrowingFee();
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

        uint256 generalInterest = _generalUserOpenInterest(msg.sender) + amount;
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

            uint256 newPositionPrinciple = _countPrinciple(amount);
            s_userToLongPrincipal[msg.sender] += newPositionPrinciple;
            s_longPrincipal += newPositionPrinciple;
        } else {
            s_shortOpenInterest += amount;
            s_userToShortOpenInterest[msg.sender] += amount;
            s_shortOpenInterestInTokens += indexTokenAmount;
            s_userToShortOpenInterestInTokens[msg.sender] += indexTokenAmount;

            uint256 newPositionPrinciple = _countPrinciple(amount);
            s_userToShortPrincipal[msg.sender] += newPositionPrinciple;
            s_shortPrincipal += newPositionPrinciple;
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

    function decreaseCollateral(uint256 amount) external {
        uint256 oldCollateral = s_userToCollateral[msg.sender];

        if (amount > oldCollateral) {
            revert Perpetual__NotEnoughCollateral();
        }

        uint256 newCollateral;
        unchecked {
            newCollateral = oldCollateral - amount;
        }

        s_userToCollateral[msg.sender] = newCollateral;

        uint256 generalInterest = _generalUserOpenInterest(msg.sender);
        if (!_isValidLeverage(msg.sender, generalInterest)) {
            revert Perpetual__CollateralBelowMaxLeverage();
        }

        SafeERC20.safeTransfer(IERC20(asset()), msg.sender, amount);

        emit DecreasedCollateral(amount, msg.sender);
    }

    /**
     * @param user user whome position to decrease, should be msg.sender
     * @param indexTokenAmount amount is stated in the index token nominal
     */
    function decreasePosition(
        address user,
        uint256 indexTokenAmount,
        bool isLong
    ) external nonReentrant isMsgSender(user) {
        _decreasePosition(user, indexTokenAmount, isLong);

        if (!_isValidLeverage(user, _generalUserOpenInterest(user))) {
            revert Perpetual__CollateralBelowMaxLeverage();
        }

        if (!_checkLiquidityReservesThreshold()) {
            revert Perpetual__LiquidityReservesBelowThreshold();
        }
    }

    /**
     * @notice if user is liquidatable, both long and short positions will be closed
     * User canoot liquidate him/her-self
     * LquidationFee is taken from the collateral value after the liquidation. The collateral can be
     * reduced after the liquidation, so the fee can be less than expected before liquidation
     */
    function liquidite(
        address userToLiquidate
    ) external nonReentrant notMsgSender(userToLiquidate) {
        if (
            _isValidLeverage(
                userToLiquidate,
                _generalUserOpenInterest(userToLiquidate)
            )
        ) {
            revert Perpetual__UserPositionsAreNotLiquidatable();
        }

        uint256 userLongInterestInTokens = s_userToLongOpenInterestInTokens[
            userToLiquidate
        ];
        uint256 userShortInterestInTokens = s_userToShortOpenInterestInTokens[
            userToLiquidate
        ];

        if (userLongInterestInTokens > 0) {
            _decreasePosition(userToLiquidate, userLongInterestInTokens, true);
        }
        if (userShortInterestInTokens > 0) {
            _decreasePosition(
                userToLiquidate,
                userShortInterestInTokens,
                false
            );
        }

        uint256 userCollateral = s_userToCollateral[userToLiquidate];
        uint256 fee = (userCollateral * LIQUIDATION_FEE) / 100;
        uint256 userCollateralAfterFee = userCollateral - fee;

        s_userToCollateral[userToLiquidate] = 0;

        SafeERC20.safeTransfer(IERC20(asset()), msg.sender, fee);
        SafeERC20.safeTransfer(
            IERC20(asset()),
            userToLiquidate,
            userCollateralAfterFee
        );

        emit Liquidated(
            userToLiquidate,
            msg.sender,
            fee,
            userLongInterestInTokens + userShortInterestInTokens
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
     * @param user user whome position to decrease
     * @param indexTokenAmount amount is stated in the index token nominal
     * @dev PnL to realize is ccounted by the next formula:
     * realizedPnL = totalPositionPnL * sizeDecrease /  positionSize
     */
    function _decreasePosition(
        address user,
        uint256 indexTokenAmount,
        bool isLong
    ) internal {
        uint256 userOpenInterest;
        uint256 userOpenInterestInTokens;
        int256 totalPositionPnL;
        uint256 borrowingFee;
        uint256 userPrincipal;

        if (isLong) {
            userOpenInterest = s_userToLongOpenInterest[user];
            userOpenInterestInTokens = s_userToLongOpenInterestInTokens[user];
            totalPositionPnL = _countLongPnL(user);
            borrowingFee = _accruedBorrowingFeeLong(user);
            userPrincipal = s_userToLongPrincipal[user];
        } else {
            userOpenInterest = s_userToShortOpenInterest[user];
            userOpenInterestInTokens = s_userToShortOpenInterestInTokens[user];
            totalPositionPnL = _countShortPnL(user);
            borrowingFee = _accruedBorrowingFeeShort(user);
            userPrincipal = s_userToShortPrincipal[user];
        }

        if (
            indexTokenAmount > userOpenInterestInTokens ||
            userOpenInterestInTokens <= 0
        ) {
            revert Perpetual__NotEnoughIndexTokensInPosition();
        }

        int256 realizedPnl = (totalPositionPnL *
            SafeCast.toInt256(indexTokenAmount)) /
            SafeCast.toInt256(userOpenInterestInTokens);

        uint256 realizedBorrowingFee = (borrowingFee * indexTokenAmount) /
            userOpenInterestInTokens;

        if (realizedPnl > 0) {
            s_depositedLiquidity -= SafeCast.toUint256(realizedPnl);
            SafeERC20.safeTransfer(
                IERC20(asset()),
                user,
                SafeCast.toUint256(realizedPnl)
            );
        }
        if (realizedPnl < 0) {
            uint256 loss = SafeCast.toUint256(-realizedPnl);
            s_userToCollateral[user] -= loss;
            s_depositedLiquidity += loss;
        }

        s_userToCollateral[user] -= realizedBorrowingFee;
        s_depositedLiquidity += realizedBorrowingFee;

        if (isLong) {
            uint256 longInterest = (userOpenInterest * indexTokenAmount) /
                userOpenInterestInTokens;
            uint256 longPrinciple = (userPrincipal * indexTokenAmount) /
                userOpenInterestInTokens;

            unchecked {
                s_userToLongOpenInterest[user] -= longInterest;
                s_userToLongOpenInterestInTokens[user] -= indexTokenAmount;
                s_longOpenInterest -= longInterest;
                s_longOpenInterestInTokens -= indexTokenAmount;
                s_userToLongPrincipal[user] -= longPrinciple;
                s_longPrincipal -= longPrinciple;
            }
        } else {
            uint256 shortInterest = (userOpenInterest * indexTokenAmount) /
                userOpenInterestInTokens;
            uint256 shortPrinciple = (userPrincipal * indexTokenAmount) /
                userOpenInterestInTokens;

            unchecked {
                s_userToShortOpenInterest[user] -= shortInterest;
                s_userToShortOpenInterestInTokens[user] -= indexTokenAmount;
                s_shortOpenInterest -= shortInterest;
                s_shortOpenInterestInTokens -= indexTokenAmount;
                s_userToShortPrincipal[user] -= shortPrinciple;
                s_shortPrincipal -= shortPrinciple;
            }
        }

        emit DecreasedPosition(indexTokenAmount, realizedPnl, user, isLong);
    }

    function _generalUserOpenInterest(
        address user
    ) internal view returns (uint256) {
        return s_userToLongOpenInterest[user] + s_userToShortOpenInterest[user];
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
                (SafeCast.toUint256(assetPriceInUsd) *
                    indexTokenPriceFeedDecimals *
                    PRECISION) /
                (SafeCast.toUint256(indexTokenPriceInUsd) *
                    assetPriceFeedDecimals);
        } else {
            return
                (SafeCast.toUint256(indexTokenPriceInUsd) *
                    assetPriceFeedDecimals *
                    PRECISION) /
                (SafeCast.toUint256(assetPriceInUsd) *
                    indexTokenPriceFeedDecimals);
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
            SafeCast.toInt256(
                (s_longOpenInterestInTokens * _indexTokenToAssetTokenPrice()) /
                    PRECISION
            ) - SafeCast.toInt256(s_longOpenInterest);
    }

    function _countLongPnL(address user) internal view returns (int256) {
        return
            SafeCast.toInt256(
                (s_userToLongOpenInterestInTokens[user] *
                    _indexTokenToAssetTokenPrice()) / PRECISION
            ) - SafeCast.toInt256(s_userToLongOpenInterest[user]);
    }

    function _countShortPnL() internal view returns (int256) {
        return
            SafeCast.toInt256(s_shortOpenInterest) -
            SafeCast.toInt256(
                (s_shortOpenInterestInTokens * _indexTokenToAssetTokenPrice()) /
                    PRECISION
            );
    }

    function _countShortPnL(address user) internal view returns (int256) {
        return
            SafeCast.toInt256(s_userToShortOpenInterest[user]) -
            SafeCast.toInt256(
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
            SafeCast.toInt256(MAX_LEVERAGE * PRECISION);
    }

    /** returns leverage with 18 decimals */
    function _currentUserLeverage(
        address user,
        uint256 positionAmount
    ) internal view returns (int256) {
        int256 denominator = (SafeCast.toInt256(s_userToCollateral[user]) +
            _countPnl(user)) - SafeCast.toInt256(_accruedBorrowingFee(user));

        if (denominator <= 0 && positionAmount > 0) {
            return type(int256).max;
        }

        if (denominator <= 0) {
            return 0;
        }

        return SafeCast.toInt256(positionAmount * PRECISION) / denominator;
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }

    /**
     * Returns current borrowing index in 1e10 decimals.
     *
     * At the beginning of the contract deployment the borrowing percent equals 0,
     * and the borrowing index equals 1
     * After time passes, borrowing index equals:
     * borrowingIndex = (time passed * percent per second) + initial borrowing index =
     * = (time passed * percent per second) + 1
     *
     * As the index has 1e10 decimals (multiplied by BORROWING_PRECISION),
     * principal calculation = position size * BORROWING_PRECISION / index
     * present position size = pricniple * index / BORROWING_PRECISION
     */
    function _currenBorrowingIndex() internal view returns (uint256) {
        return
            (((_now() - i_startingTimestamp) * BORROWING_PRECISION) /
                BORROWING_PER_SHARE_PER_SECOND) + (1 * BORROWING_PRECISION);
    }

    function _countPrinciple(uint256 amount) internal view returns (uint256) {
        return (amount * BORROWING_PRECISION) / _currenBorrowingIndex();
    }

    function _countOpenLongInterestWithBorrowingFees(
        address user
    ) internal view returns (uint256) {
        return
            (s_userToLongOpenInterest[user] * _currenBorrowingIndex()) /
            BORROWING_PRECISION;
    }

    function _countOpenLongInterestWithBorrowingFees()
        internal
        view
        returns (uint256)
    {
        return
            (s_longOpenInterest * _currenBorrowingIndex()) /
            BORROWING_PRECISION;
    }

    function _countOpenShortInterestWithBorrowingFees(
        address user
    ) internal view returns (uint256) {
        return
            (s_userToShortOpenInterest[user] * _currenBorrowingIndex()) /
            BORROWING_PRECISION;
    }

    function _countOpenShortInterestWithBorrowingFees()
        internal
        view
        returns (uint256)
    {
        return
            (s_shortOpenInterest * _currenBorrowingIndex()) /
            BORROWING_PRECISION;
    }

    function _accruedBorrowingFeeLong(
        address user
    ) internal view returns (uint256) {
        return
            _countOpenLongInterestWithBorrowingFees(user) -
            s_userToLongOpenInterest[user];
    }

    function _accruedBorrowingFeeLong() internal view returns (uint256) {
        return _countOpenLongInterestWithBorrowingFees() - s_longOpenInterest;
    }

    function _accruedBorrowingFeeShort(
        address user
    ) internal view returns (uint256) {
        return
            _countOpenShortInterestWithBorrowingFees(user) -
            s_userToShortOpenInterest[user];
    }

    function _accruedBorrowingFeeShort() internal view returns (uint256) {
        return _countOpenShortInterestWithBorrowingFees() - s_shortOpenInterest;
    }

    function _accruedBorrowingFee(
        address user
    ) internal view returns (uint256) {
        return _accruedBorrowingFeeLong(user) + _accruedBorrowingFeeShort(user);
    }

    function _accruedBorrowingFee() internal view returns (uint256) {
        return _accruedBorrowingFeeLong() + _accruedBorrowingFeeShort();
    }

    // private to public external

    function accruedBorrowingFeeLong(
        address user
    ) external view returns (uint256) {
        return _accruedBorrowingFeeLong(user);
    }

    function accruedBorrowingFeeLong() external view returns (uint256) {
        return _accruedBorrowingFeeLong();
    }

    function accruedBorrowingFeeShort(
        address user
    ) external view returns (uint256) {
        return _accruedBorrowingFeeShort(user);
    }

    function accruedBorrowingFeeShort() external view returns (uint256) {
        return _accruedBorrowingFeeShort();
    }

    function accruedBorrowingFee(address user) external view returns (uint256) {
        return _accruedBorrowingFee(user);
    }

    function accruedBorrowingFee() external view returns (uint256) {
        return _accruedBorrowingFee();
    }

    function currenBorrowinIndex() external view returns (uint256) {
        return _currenBorrowingIndex();
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

    function countShortPnL(address user) external view returns (int256) {
        return _countShortPnL(user);
    }

    function countLongPnL(address user) external view returns (int256) {
        return _countLongPnL(user);
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

    function getBorrowingPerSharePerSecond() external pure returns (uint256) {
        return BORROWING_PER_SHARE_PER_SECOND;
    }

    function getUserLongPrincipal(
        address user
    ) external view returns (uint256) {
        return s_userToLongPrincipal[user];
    }

    function getUserShortPrincipal(
        address user
    ) external view returns (uint256) {
        return s_userToShortPrincipal[user];
    }
}
