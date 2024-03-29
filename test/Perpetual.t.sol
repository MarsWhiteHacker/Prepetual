// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {PerpetualScript} from "../script/Perpetual.s.sol";

/**
 * Test cases are written particularly for PerpetualScript mocks
 * Asset and index tokens are mocked with 1e18 decimals
 * Price feeds are mocked with 1e8 deimals
 * Initial price is mocked as 1/10_000 BTC/USDC
 */
contract PerpetualTest is Test {
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

    Perpetual public perpetual;
    address public asset;
    address public indexToken;

    address public PLAYER = makeAddr("player");
    address public PLAYER2 = makeAddr("player2");
    uint256 public constant MINT_ASSET_AMOUNT = 10e18;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        perpetual = (new PerpetualScript()).run();
        asset = perpetual.asset();
        indexToken = perpetual.getIndexToken();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
        vm.deal(PLAYER2, STARTING_USER_BALANCE);
    }

    modifier skipSepolia() {
        if (block.chainid == 11155111) {} else {
            _;
        }
    }

    modifier mintAssetToPlayer() {
        // mock on Anvil testnet
        ERC20Mock(asset).mint(PLAYER, MINT_ASSET_AMOUNT);
        _;
    }

    modifier playerDepositedAsset() {
        // on Anvil testnet
        ERC20Mock(asset).mint(PLAYER, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.deposit(MINT_ASSET_AMOUNT, PLAYER);
        vm.stopPrank();
        _;
    }

    function testShouldReturnVaultAssetName() public {
        assertEq(perpetual.name(), "Perpetual");
    }

    function testShouldReturnVaultAssetSymbol() public {
        assertEq(perpetual.symbol(), "PTL");
    }

    function testShouldReturnVaultShareDecimals() public {
        if (block.chainid == 11155111) {
            assertEq(perpetual.decimals(), 6);
        } else {
            assertEq(perpetual.decimals(), 18);
        }
    }

    function testShouldReturnVaultAssetDecimals() public {
        if (block.chainid == 11155111) {
            assertEq(ERC20(asset).decimals(), 6);
        } else {
            assertEq(ERC20(asset).decimals(), 18);
        }
    }

    function testShouldReturnIndexTokenDecimals() public {
        if (block.chainid == 11155111) {
            assertEq(ERC20(indexToken).decimals(), 8);
        } else {
            assertEq(ERC20(indexToken).decimals(), 18);
        }
    }

    function testShouldReturnCorrectIndexTokenPriceInAssetToken() public {
        if (block.chainid == 11155111) {
            assert(perpetual.indexTokenToAssetTokenPrice() != 0);
        } else {
            assertEq(perpetual.indexTokenToAssetTokenPrice(), 10000 * 1e18);
        }
    }

    function testShouldReturnCorrectAssetTokenPriceInIndexToken() public {
        if (block.chainid == 11155111) {
            assert(perpetual.assetTokenToIndexTokenPrice() != 0);
        } else {
            assertEq(perpetual.assetTokenToIndexTokenPrice(), 1 * 1e14);
        }
    }

    function testShouldRevertOnZeroDeposit() public {
        vm.prank(PLAYER);
        vm.expectRevert(Perpetual.Perpetual__NotEnoughAssets.selector);
        perpetual.deposit(0, PLAYER);
    }

    function testShouldSuccessfullyDepositLiquidity()
        public
        skipSepolia
        mintAssetToPlayer
    {
        ERC20Mock assetERC20 = ERC20Mock(asset);

        assertEq(assetERC20.balanceOf(PLAYER), MINT_ASSET_AMOUNT);
        assertEq(assetERC20.balanceOf(address(perpetual)), 0);
        assertEq(perpetual.balanceOf(PLAYER), 0);
        assertEq(perpetual.balanceOf(address(perpetual)), 0);
        assertEq(perpetual.totalSupply(), 0);

        vm.startPrank(PLAYER);
        assetERC20.approve(address(perpetual), MINT_ASSET_AMOUNT);
        vm.expectEmit(true, true, false, false);
        emit UpdatedDepositedLiquidity(0, MINT_ASSET_AMOUNT);
        perpetual.deposit(MINT_ASSET_AMOUNT, PLAYER);
        vm.stopPrank();

        assertEq(assetERC20.balanceOf(PLAYER), 0);
        assertEq(assetERC20.balanceOf(address(perpetual)), MINT_ASSET_AMOUNT);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT);
        assertEq(perpetual.totalSupply(), MINT_ASSET_AMOUNT);
        assertEq(perpetual.balanceOf(PLAYER), MINT_ASSET_AMOUNT);
    }

    function testShouldSuccessfullyDepositSmallLiquidity()
        public
        skipSepolia
        mintAssetToPlayer
    {
        ERC20Mock assetERC20 = ERC20Mock(asset);
        vm.startPrank(PLAYER);
        assetERC20.approve(address(perpetual), 1);
        vm.expectEmit(true, true, false, false);
        emit UpdatedDepositedLiquidity(0, 1);
        perpetual.deposit(1, PLAYER);
        vm.stopPrank();

        assertEq(assetERC20.balanceOf(address(perpetual)), 1);
        assertEq(perpetual.depositedLiquidity(), 1);
        assertEq(perpetual.totalSupply(), 1);
        assertEq(perpetual.balanceOf(PLAYER), 1);
    }

    function testShouldHaveSameSharesAmountForTwoDepositors()
        public
        skipSepolia
    {
        ERC20Mock(asset).mint(PLAYER, MINT_ASSET_AMOUNT);
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);

        assertEq(ERC20Mock(asset).balanceOf(PLAYER), MINT_ASSET_AMOUNT);
        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), MINT_ASSET_AMOUNT);

        vm.startPrank(PLAYER);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.deposit(MINT_ASSET_AMOUNT, PLAYER);
        vm.stopPrank();
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.deposit(MINT_ASSET_AMOUNT, PLAYER2);
        vm.stopPrank();

        assertEq(perpetual.depositedLiquidity(), 2 * MINT_ASSET_AMOUNT);
        assertEq(perpetual.totalSupply(), 2 * MINT_ASSET_AMOUNT);
        assertEq(perpetual.balanceOf(PLAYER), MINT_ASSET_AMOUNT);
        assertEq(perpetual.balanceOf(PLAYER2), MINT_ASSET_AMOUNT);
    }

    function testShouldRevertOnZeroWithdraw() public {
        vm.prank(PLAYER);
        vm.expectRevert(Perpetual.Perpetual__NotEnoughAssets.selector);
        perpetual.withdraw(0, PLAYER, PLAYER);
    }

    function testShouldRevertOnWithdrawingMoreThanLiquidity()
        public
        skipSepolia
        playerDepositedAsset
    {
        vm.prank(PLAYER);
        vm.expectRevert(
            Perpetual.Perpetual__AssetsAmountBiggerThanLiquidity.selector
        );
        perpetual.withdraw(MINT_ASSET_AMOUNT + 1, PLAYER, PLAYER);
    }

    function testShouldWithdrawSuccessfully()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock assetERC20 = ERC20Mock(asset);
        uint256 WITHDRAW_AMOUNT = MINT_ASSET_AMOUNT - 1;

        assertEq((assetERC20).balanceOf(PLAYER), 0);
        assertEq(assetERC20.balanceOf(address(perpetual)), MINT_ASSET_AMOUNT);

        vm.startPrank(PLAYER);
        vm.expectEmit(true, true, false, false);
        emit UpdatedDepositedLiquidity(MINT_ASSET_AMOUNT, 1);
        perpetual.withdraw(WITHDRAW_AMOUNT, PLAYER, PLAYER);
        vm.stopPrank();

        assertEq(assetERC20.balanceOf(PLAYER), WITHDRAW_AMOUNT);
        assertEq(assetERC20.balanceOf(address(perpetual)), 1);
        assertEq(perpetual.depositedLiquidity(), 1);
    }

    function testShouldHaveValidLiquidityReservesThresholdInTheStart() public {
        assertTrue(perpetual.checkLiquidityReservesThreshold());
    }

    function testShouldHaveValidLiquidityReservesThresholdAfterFirstDeposit()
        public
        skipSepolia
        playerDepositedAsset
    {
        assertTrue(perpetual.checkLiquidityReservesThreshold());
    }

    function testShouldRevertOnMint() public {
        vm.prank(PLAYER);
        vm.expectRevert(Perpetual.Perpetual__PublicMintIsNowAllowed.selector);
        perpetual.mint(MINT_ASSET_AMOUNT, PLAYER);
    }

    function testShouldRevertOnRedeem() public {
        vm.prank(PLAYER);
        vm.expectRevert(Perpetual.Perpetual__PublicRedeemIsNowAllowed.selector);
        perpetual.redeem(MINT_ASSET_AMOUNT, PLAYER, PLAYER);
    }

    function testUserShouldAddCollateralSucccessfully()
        public
        skipSepolia
        mintAssetToPlayer
    {
        ERC20Mock assetERC20 = ERC20Mock(asset);

        vm.startPrank(PLAYER);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT / 2);
        vm.expectEmit(true, true, false, false);
        emit AddedCollateral(MINT_ASSET_AMOUNT / 2, PLAYER);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 2);
        vm.stopPrank();

        assertEq(perpetual.getUserCollateral(PLAYER), MINT_ASSET_AMOUNT / 2);

        vm.startPrank(PLAYER);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT / 2);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 2);
        vm.stopPrank();

        assertEq(assetERC20.balanceOf(PLAYER), 0);
        assertEq(perpetual.balanceOf(PLAYER), 0);
        assertEq(perpetual.getUserCollateral(PLAYER), MINT_ASSET_AMOUNT);
    }

    function testShouldRevertWhenOpeningPositionWithLowLeverage()
        public
        skipSepolia
        mintAssetToPlayer
    {
        vm.startPrank(PLAYER);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        vm.expectRevert(
            Perpetual.Perpetual__CollateralBelowMaxLeverage.selector
        );
        perpetual.addPosition(MINT_ASSET_AMOUNT * 16, true);
        vm.stopPrank();
    }

    function testShouldRevertWhenOpneningPositionBiggerThanReserves()
        public
        skipSepolia
        mintAssetToPlayer
    {
        vm.startPrank(PLAYER);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        vm.expectRevert(
            Perpetual.Perpetual__LiquidityReservesBelowThreshold.selector
        );
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();
    }

    function testShouldCreatePositionSuccessfully()
        public
        skipSepolia
        playerDepositedAsset
    {
        uint256 ASSET_BALANCE_PLAYER2 = MINT_ASSET_AMOUNT / 2;
        ERC20Mock(asset).mint(PLAYER2, ASSET_BALANCE_PLAYER2);

        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), ASSET_BALANCE_PLAYER2);
        vm.expectEmit(true, true, false, false);
        emit AddedCollateral(ASSET_BALANCE_PLAYER2, PLAYER2);
        perpetual.addCollateral(ASSET_BALANCE_PLAYER2);

        vm.expectEmit(true, true, true, false);
        emit AddedPosition(MINT_ASSET_AMOUNT, PLAYER2, true);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        assertEq(perpetual.getUserCollateral(PLAYER2), ASSET_BALANCE_PLAYER2);
        assertEq(perpetual.totalAssets(), MINT_ASSET_AMOUNT);
        assertEq(
            ERC20Mock(asset).balanceOf(address(perpetual)),
            ASSET_BALANCE_PLAYER2 + MINT_ASSET_AMOUNT
        );
        assertEq(perpetual.getShortOpenInterest(), 0);
        assertEq(perpetual.getShortOpenInterestInTokens(), 0);
        assertEq(perpetual.getLongOpenInterest(), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getLongOpenInterestInTokens(),
            MINT_ASSET_AMOUNT / 10000
        );
    }

    function testShouldRevertOnWithdrawingBelowReservesLiquidityThreshold()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        ERC20Mock assetERC20 = ERC20Mock(asset);

        assertEq((assetERC20).balanceOf(PLAYER), 0);
        assertEq(
            assetERC20.balanceOf(address(perpetual)),
            MINT_ASSET_AMOUNT * 2
        );

        vm.startPrank(PLAYER);
        vm.expectRevert(
            Perpetual.Perpetual__LiquidityReservesBelowThreshold.selector
        );
        perpetual.withdraw(MINT_ASSET_AMOUNT, PLAYER, PLAYER);
        vm.stopPrank();
    }

    function testUserShouldBeAbleToAddPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT / 2, true);
        vm.stopPrank();

        assertTrue(perpetual.checkLiquidityReservesThreshold());

        vm.startPrank(PLAYER2);
        perpetual.addPosition(MINT_ASSET_AMOUNT / 2, true);
        vm.stopPrank();

        assertTrue(perpetual.checkLiquidityReservesThreshold());

        vm.startPrank(PLAYER2);
        vm.expectRevert(
            Perpetual.Perpetual__LiquidityReservesBelowThreshold.selector
        );
        perpetual.addPosition(MINT_ASSET_AMOUNT / 2, true);
        vm.stopPrank();

        assertTrue(perpetual.checkLiquidityReservesThreshold());
    }

    function testUserShouldHaveProfitWhenIndexTokenPriceRisesWithLongPoisition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        uint256 POISTION_SIZE = MINT_ASSET_AMOUNT * 2;
        uint256 COLLATERAL_SIZE = MINT_ASSET_AMOUNT;

        ERC20Mock(asset).mint(PLAYER2, COLLATERAL_SIZE);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), COLLATERAL_SIZE);
        perpetual.addCollateral(COLLATERAL_SIZE);
        perpetual.addPosition(POISTION_SIZE, true);
        vm.stopPrank();

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2)
            ),
            int256((POISTION_SIZE * 1e18) / COLLATERAL_SIZE)
        );
        assertEq(perpetual.countPnl(), 0);
        assertEq(perpetual.countPnl(PLAYER2), 0);

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );

        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 20000e8;
        uint256 pnl = (uint256(NEW_INDEX_TOKEN_PRICE / OLD_INDEX_TOKEN_PRICE) *
            POISTION_SIZE) - POISTION_SIZE;

        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        assertEq(perpetual.indexTokenToAssetTokenPrice(), 20000 * 1e18);
        assertEq(pnl, POISTION_SIZE);
        assertEq(pnl, uint256(perpetual.countPnl()));
        assertEq(pnl, uint256(perpetual.countPnl(PLAYER2)));

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2)
            ),
            int256((POISTION_SIZE * 1e18) / (COLLATERAL_SIZE + pnl))
        );
    }

    function testUserShouldHaveProfitWhenIndexTokenPriceFallWithShortPoisition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        uint256 POISTION_SIZE = MINT_ASSET_AMOUNT * 2;
        uint256 COLLATERAL_SIZE = MINT_ASSET_AMOUNT;

        ERC20Mock(asset).mint(PLAYER2, COLLATERAL_SIZE);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), COLLATERAL_SIZE);
        perpetual.addCollateral(COLLATERAL_SIZE);
        perpetual.addPosition(POISTION_SIZE, false);
        vm.stopPrank();

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserShortOpenInterest(PLAYER2)
            ),
            int256((POISTION_SIZE * 1e18) / COLLATERAL_SIZE)
        );
        assertEq(perpetual.countPnl(), 0);
        assertEq(perpetual.countPnl(PLAYER2), 0);

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );

        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 5000e8;
        uint256 pnl = POISTION_SIZE -
            (POISTION_SIZE /
                uint256(OLD_INDEX_TOKEN_PRICE / NEW_INDEX_TOKEN_PRICE));

        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        assertEq(perpetual.indexTokenToAssetTokenPrice(), 5000 * 1e18);
        assertEq(pnl, POISTION_SIZE / 2);
        assertEq(pnl, uint256(perpetual.countPnl()));
        assertEq(pnl, uint256(perpetual.countPnl(PLAYER2)));

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserShortOpenInterest(PLAYER2)
            ),
            int256((POISTION_SIZE * 1e18) / (COLLATERAL_SIZE + pnl))
        );
    }

    function testUserShouldHaveLossWhenIndexTokenPriceFallsWithLongPoisition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        uint256 POISTION_SIZE = MINT_ASSET_AMOUNT * 2;
        uint256 COLLATERAL_SIZE = MINT_ASSET_AMOUNT;

        ERC20Mock(asset).mint(PLAYER2, COLLATERAL_SIZE);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), COLLATERAL_SIZE);
        perpetual.addCollateral(COLLATERAL_SIZE);
        perpetual.addPosition(POISTION_SIZE, true);
        vm.stopPrank();

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2)
            ),
            int256((POISTION_SIZE * 1e18) / COLLATERAL_SIZE)
        );
        assertEq(perpetual.countPnl(), 0);
        assertEq(perpetual.countPnl(PLAYER2), 0);

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );

        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 5000e8;
        int256 pnl = (
            ((NEW_INDEX_TOKEN_PRICE * int256(POISTION_SIZE)) /
                OLD_INDEX_TOKEN_PRICE)
        ) - int256(POISTION_SIZE);

        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        assertEq(perpetual.indexTokenToAssetTokenPrice(), 5000 * 1e18);
        assertEq((-pnl), int256(POISTION_SIZE / 2));
        assertEq(pnl, perpetual.countPnl());
        assertEq(pnl, perpetual.countPnl(PLAYER2));

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2)
            ),
            type(int256).max
        );
    }

    function testUserShouldHaveLossWhenIndexTokenPriceRisesWithShortPoisition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        uint256 POISTION_SIZE = MINT_ASSET_AMOUNT * 2;
        uint256 COLLATERAL_SIZE = MINT_ASSET_AMOUNT;

        ERC20Mock(asset).mint(PLAYER2, COLLATERAL_SIZE);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), COLLATERAL_SIZE);
        perpetual.addCollateral(COLLATERAL_SIZE);
        perpetual.addPosition(POISTION_SIZE, false);
        vm.stopPrank();

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserShortOpenInterest(PLAYER2)
            ),
            int256((POISTION_SIZE * 1e18) / COLLATERAL_SIZE)
        );
        assertEq(perpetual.countPnl(), 0);
        assertEq(perpetual.countPnl(PLAYER2), 0);

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );

        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 20000e8;
        int256 pnl = int256(POISTION_SIZE) -
            (
                ((NEW_INDEX_TOKEN_PRICE * int256(POISTION_SIZE)) /
                    OLD_INDEX_TOKEN_PRICE)
            );

        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        assertEq(perpetual.indexTokenToAssetTokenPrice(), 20000 * 1e18);
        assertEq((-pnl), int256(POISTION_SIZE));
        assertEq(pnl, perpetual.countPnl());
        assertEq(pnl, perpetual.countPnl(PLAYER2));

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserShortOpenInterest(PLAYER2)
            ),
            type(int256).max
        );
    }

    function testUserShouldDecreaseCollateralSuccessfullyWithoutOpenPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        uint256 COLLATERAL_SIZE = MINT_ASSET_AMOUNT;

        ERC20Mock(asset).mint(PLAYER2, COLLATERAL_SIZE);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), COLLATERAL_SIZE);
        perpetual.addCollateral(COLLATERAL_SIZE);
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(
            ERC20Mock(asset).balanceOf(address(perpetual)),
            MINT_ASSET_AMOUNT + COLLATERAL_SIZE
        );
        assertEq(perpetual.getUserCollateral(PLAYER2), COLLATERAL_SIZE);

        vm.startPrank(PLAYER2);
        vm.expectEmit(true, true, false, false);
        emit DecreasedCollateral(COLLATERAL_SIZE, PLAYER2);
        perpetual.decreaseCollateral(COLLATERAL_SIZE);
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), COLLATERAL_SIZE);
        assertEq(
            ERC20Mock(asset).balanceOf(address(perpetual)),
            MINT_ASSET_AMOUNT
        );
        assertEq(perpetual.getUserCollateral(PLAYER2), 0);
    }

    function testUserShouldFailToDecreaseTooLargeCollateral()
        public
        skipSepolia
        playerDepositedAsset
    {
        uint256 COLLATERAL_SIZE = MINT_ASSET_AMOUNT;

        vm.startPrank(PLAYER2);
        vm.expectRevert(Perpetual.Perpetual__NotEnoughCollateral.selector);
        perpetual.decreaseCollateral(1);
        vm.stopPrank();

        ERC20Mock(asset).mint(PLAYER2, COLLATERAL_SIZE);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), COLLATERAL_SIZE);
        perpetual.addCollateral(COLLATERAL_SIZE);
        vm.stopPrank();

        vm.startPrank(PLAYER2);
        vm.expectRevert(Perpetual.Perpetual__NotEnoughCollateral.selector);
        perpetual.decreaseCollateral(COLLATERAL_SIZE + 1);
        vm.stopPrank();
    }

    function testUserShouldFailToDecreaseCollateralThatCoversPosition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        uint256 POISTION_SIZE = MINT_ASSET_AMOUNT * 2;
        uint256 COLLATERAL_SIZE = MINT_ASSET_AMOUNT;

        ERC20Mock(asset).mint(PLAYER2, COLLATERAL_SIZE);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), COLLATERAL_SIZE);
        perpetual.addCollateral(COLLATERAL_SIZE);
        perpetual.addPosition(POISTION_SIZE, true);
        vm.stopPrank();

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2)
            ),
            int256((POISTION_SIZE * 1e18) / COLLATERAL_SIZE)
        );

        vm.startPrank(PLAYER2);
        perpetual.decreaseCollateral(COLLATERAL_SIZE / 2);
        vm.stopPrank();

        assertEq(
            perpetual.currentUserLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2)
            ),
            int256(((POISTION_SIZE * 1e18) / COLLATERAL_SIZE) * 2)
        );

        vm.startPrank(PLAYER2);
        vm.expectRevert(
            Perpetual.Perpetual__CollateralBelowMaxLeverage.selector
        );
        perpetual.decreaseCollateral(COLLATERAL_SIZE / 2);
        vm.stopPrank();
    }

    function testShouldFailWhenDecreasingPositionWithNotEnoughTokens()
        public
        skipSepolia
        playerDepositedAsset
    {
        vm.startPrank(PLAYER2);
        vm.expectRevert(
            Perpetual.Perpetual__NotEnoughIndexTokensInPosition.selector
        );
        perpetual.decreasePosition(PLAYER2, 1, true);
        vm.expectRevert(
            Perpetual.Perpetual__NotEnoughIndexTokensInPosition.selector
        );
        perpetual.decreasePosition(PLAYER2, 1, false);
        vm.stopPrank();

        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        assertEq(
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            MINT_ASSET_AMOUNT / 10000
        );

        vm.startPrank(PLAYER2);
        vm.expectRevert(
            Perpetual.Perpetual__NotEnoughIndexTokensInPosition.selector
        );
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 + 1,
            true
        );
        vm.stopPrank();
    }

    function testShouldDecreasePositionSuccessfullyWithNoPnl()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(perpetual.getUserLongOpenInterest(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            MINT_ASSET_AMOUNT / 10000
        );

        vm.startPrank(PLAYER2);
        vm.expectEmit(true, true, true, true);
        emit DecreasedPosition(MINT_ASSET_AMOUNT / 2 / 10000, 0, PLAYER2, true);
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 2,
            true
        );
        vm.stopPrank();

        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserLongOpenInterest(PLAYER2),
            MINT_ASSET_AMOUNT / 2
        );
        assertEq(
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            MINT_ASSET_AMOUNT / 10000 / 2
        );

        vm.startPrank(PLAYER2);
        vm.expectEmit(true, true, true, true);
        emit DecreasedPosition(MINT_ASSET_AMOUNT / 2 / 10000, 0, PLAYER2, true);
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 2,
            true
        );
        vm.stopPrank();

        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(perpetual.getUserLongOpenInterest(PLAYER2), 0);
        assertEq(perpetual.getUserLongOpenInterestInTokens(PLAYER2), 0);
    }

    function testShouldFailToDecreasePositionWithInvalidLeverage()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 14);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        // old price is 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 5000e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        vm.startPrank(PLAYER2);
        vm.expectRevert(
            Perpetual.Perpetual__CollateralBelowMaxLeverage.selector
        );
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 14,
            true
        );
        vm.stopPrank();
    }

    function testShouldFailToDecreasePositionWithLowDepositValue()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 14);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        // old price is 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 20000e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        vm.startPrank(PLAYER2);
        vm.expectRevert(
            Perpetual.Perpetual__LiquidityReservesBelowThreshold.selector
        );
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 14,
            true
        );
        vm.stopPrank();
    }

    function testShouldDecreasePositionWithCorrectProfitForLongPosition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        assertEq(perpetual.depositedLiquidity(), 2 * MINT_ASSET_AMOUNT);
        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(perpetual.getUserLongOpenInterest(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            MINT_ASSET_AMOUNT / 10000
        );
        assertEq(perpetual.getLongOpenInterest(), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getLongOpenInterestInTokens(),
            MINT_ASSET_AMOUNT / 10000
        );

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 15000e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        uint256 pnl = ((uint256(NEW_INDEX_TOKEN_PRICE) * MINT_ASSET_AMOUNT) /
            uint256(OLD_INDEX_TOKEN_PRICE)) - MINT_ASSET_AMOUNT;
        assertEq(int256(pnl), perpetual.countPnl(PLAYER2));

        vm.startPrank(PLAYER2);
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 4,
            true
        );
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), pnl / 4);
        assertEq(
            perpetual.depositedLiquidity(),
            (2 * MINT_ASSET_AMOUNT) - (pnl / 4)
        );
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserLongOpenInterest(PLAYER2),
            (MINT_ASSET_AMOUNT / 4) * 3
        );
        assertEq(
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
        assertEq(perpetual.getLongOpenInterest(), (MINT_ASSET_AMOUNT / 4) * 3);
        assertEq(
            perpetual.getLongOpenInterestInTokens(),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
    }

    function testShouldDecreasePositionWithCorrectProfitForShortPosition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, false);
        vm.stopPrank();

        assertEq(perpetual.depositedLiquidity(), 2 * MINT_ASSET_AMOUNT);
        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserShortOpenInterest(PLAYER2),
            MINT_ASSET_AMOUNT
        );
        assertEq(
            perpetual.getUserShortOpenInterestInTokens(PLAYER2),
            MINT_ASSET_AMOUNT / 10000
        );
        assertEq(perpetual.getShortOpenInterest(), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getShortOpenInterestInTokens(),
            MINT_ASSET_AMOUNT / 10000
        );

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 5000e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        uint256 pnl = MINT_ASSET_AMOUNT -
            ((uint256(NEW_INDEX_TOKEN_PRICE) * MINT_ASSET_AMOUNT) /
                uint256(OLD_INDEX_TOKEN_PRICE));
        assertEq(int256(pnl), perpetual.countPnl(PLAYER2));

        vm.startPrank(PLAYER2);
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 4,
            false
        );
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), pnl / 4);
        assertEq(
            perpetual.depositedLiquidity(),
            (2 * MINT_ASSET_AMOUNT) - (pnl / 4)
        );
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserShortOpenInterest(PLAYER2),
            (MINT_ASSET_AMOUNT / 4) * 3
        );
        assertEq(
            perpetual.getUserShortOpenInterestInTokens(PLAYER2),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
        assertEq(perpetual.getShortOpenInterest(), (MINT_ASSET_AMOUNT / 4) * 3);
        assertEq(
            perpetual.getShortOpenInterestInTokens(),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
    }

    function testShouldDecreasePositionWithCorrectLossForLongPosition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        assertEq(perpetual.depositedLiquidity(), 2 * MINT_ASSET_AMOUNT);
        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(perpetual.getUserLongOpenInterest(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            MINT_ASSET_AMOUNT / 10000
        );
        assertEq(perpetual.getLongOpenInterest(), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getLongOpenInterestInTokens(),
            MINT_ASSET_AMOUNT / 10000
        );

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 5000e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        int256 pnl = ((NEW_INDEX_TOKEN_PRICE * int256(MINT_ASSET_AMOUNT)) /
            OLD_INDEX_TOKEN_PRICE) - int256(MINT_ASSET_AMOUNT);
        assertEq(int256(pnl), perpetual.countPnl(PLAYER2));

        vm.startPrank(PLAYER2);
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 4,
            true
        );
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(
            perpetual.depositedLiquidity(),
            (2 * MINT_ASSET_AMOUNT) + (uint256(-pnl) / 4)
        );
        assertEq(
            perpetual.getUserCollateral(PLAYER2),
            MINT_ASSET_AMOUNT - (uint256(-pnl) / 4)
        );
        assertEq(
            perpetual.getUserLongOpenInterest(PLAYER2),
            (MINT_ASSET_AMOUNT / 4) * 3
        );
        assertEq(
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
        assertEq(perpetual.getLongOpenInterest(), (MINT_ASSET_AMOUNT / 4) * 3);
        assertEq(
            perpetual.getLongOpenInterestInTokens(),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
    }

    function testShouldDecreasePositionWithCorrectLossForShortPosition()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, false);
        vm.stopPrank();

        assertEq(perpetual.depositedLiquidity(), 2 * MINT_ASSET_AMOUNT);
        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserShortOpenInterest(PLAYER2),
            MINT_ASSET_AMOUNT
        );
        assertEq(
            perpetual.getUserShortOpenInterestInTokens(PLAYER2),
            MINT_ASSET_AMOUNT / 10000
        );
        assertEq(perpetual.getShortOpenInterest(), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getShortOpenInterestInTokens(),
            MINT_ASSET_AMOUNT / 10000
        );

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        int256 OLD_INDEX_TOKEN_PRICE = 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 15000e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        int256 pnl = int256(MINT_ASSET_AMOUNT) -
            ((NEW_INDEX_TOKEN_PRICE * int256(MINT_ASSET_AMOUNT)) /
                OLD_INDEX_TOKEN_PRICE);
        assertEq(int256(pnl), perpetual.countPnl(PLAYER2));

        vm.startPrank(PLAYER2);
        perpetual.decreasePosition(
            PLAYER2,
            MINT_ASSET_AMOUNT / 10000 / 4,
            false
        );
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(
            perpetual.depositedLiquidity(),
            (2 * MINT_ASSET_AMOUNT + (uint256(-pnl) / 4))
        );
        assertEq(
            perpetual.getUserCollateral(PLAYER2),
            MINT_ASSET_AMOUNT - (uint256(-pnl) / 4)
        );
        assertEq(
            perpetual.getUserShortOpenInterest(PLAYER2),
            (MINT_ASSET_AMOUNT / 4) * 3
        );
        assertEq(
            perpetual.getUserShortOpenInterestInTokens(PLAYER2),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
        assertEq(perpetual.getShortOpenInterest(), (MINT_ASSET_AMOUNT / 4) * 3);
        assertEq(
            perpetual.getShortOpenInterestInTokens(),
            (MINT_ASSET_AMOUNT / 10000 / 4) * 3
        );
    }

    function testShouldFailToDecreasePositionOfOtherPerson() public {
        vm.startPrank(PLAYER2);
        vm.expectRevert(Perpetual.Perpetual__ShouldBeMsgSender.selector);
        perpetual.decreasePosition(PLAYER, 1, true);
        vm.stopPrank();
    }

    function testShouldFailToLiquidateYourself() public {
        vm.startPrank(PLAYER);
        vm.expectRevert(Perpetual.Perpetual__ShouldNotBeMsgSender.selector);
        perpetual.liquidate(PLAYER);
        vm.stopPrank();
    }

    function testShouldFailToLiquidateValidPositions()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        vm.startPrank(PLAYER);
        vm.expectRevert(
            Perpetual.Perpetual__UserPositionsAreNotLiquidatable.selector
        );
        perpetual.liquidate(PLAYER2);
        vm.stopPrank();
    }

    function testShouldLiquidateInvalidLongPositionSuccessfully()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 10);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        // old price is 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 9500e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        assertFalse(
            perpetual.isValidLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2)
            )
        );

        // leverage = 20, maxLeverage is 15
        assertEq(
            uint256(
                perpetual.currentUserLeverage(
                    PLAYER2,
                    perpetual.getUserLongOpenInterest(PLAYER2)
                )
            ) / 1e18,
            20
        );
        assertEq(
            ERC20Mock(asset).balanceOf(PLAYER2),
            (MINT_ASSET_AMOUNT / 10) * 9
        );
        assertEq(ERC20Mock(asset).balanceOf(PLAYER), 0);

        uint256 userLoss = uint256(-perpetual.countPnl(PLAYER2));
        uint256 userCollateralAfterLiquidation = perpetual.getUserCollateral(
            PLAYER2
        ) - userLoss;
        uint256 liquidateionFee = (userCollateralAfterLiquidation * 50) / 100;

        vm.startPrank(PLAYER);
        vm.expectEmit(true, true, true, true);
        emit Liquidated(
            PLAYER2,
            PLAYER,
            liquidateionFee,
            perpetual.getUserLongOpenInterestInTokens(PLAYER2)
        );
        perpetual.liquidate(PLAYER2);
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER), liquidateionFee);
        assertEq(
            ERC20Mock(asset).balanceOf(PLAYER2),
            ((MINT_ASSET_AMOUNT / 10) * 9) +
                (userCollateralAfterLiquidation - liquidateionFee)
        );
        assertEq(perpetual.getUserCollateral(PLAYER2), 0);
        assertEq(perpetual.getUserLongOpenInterest(PLAYER2), 0);
        assertEq(perpetual.getUserShortOpenInterest(PLAYER2), 0);
        assertEq(perpetual.getUserLongOpenInterestInTokens(PLAYER2), 0);
        assertEq(perpetual.getUserShortOpenInterestInTokens(PLAYER2), 0);
        assertEq(perpetual.getLongOpenInterest(), 0);
        assertEq(perpetual.getLongOpenInterestInTokens(), 0);
        assertEq(perpetual.getShortOpenInterest(), 0);
        assertEq(perpetual.getShortOpenInterestInTokens(), 0);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT + userLoss);
    }

    function testShouldLiquidateInvalidShortPositionSuccessfully()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 10);
        perpetual.addPosition(MINT_ASSET_AMOUNT, false);
        vm.stopPrank();

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        // old price is 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 10500e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        assertFalse(
            perpetual.isValidLeverage(
                PLAYER2,
                perpetual.getUserShortOpenInterest(PLAYER2)
            )
        );

        // leverage = 20, maxLeverage is 15
        assertEq(
            uint256(
                perpetual.currentUserLeverage(
                    PLAYER2,
                    perpetual.getUserShortOpenInterest(PLAYER2)
                )
            ) / 1e18,
            20
        );
        assertEq(
            ERC20Mock(asset).balanceOf(PLAYER2),
            (MINT_ASSET_AMOUNT / 10) * 9
        );
        assertEq(ERC20Mock(asset).balanceOf(PLAYER), 0);

        uint256 userLoss = uint256(-perpetual.countPnl(PLAYER2));
        uint256 userCollateralAfterLiquidation = perpetual.getUserCollateral(
            PLAYER2
        ) - userLoss;
        uint256 liquidateionFee = (userCollateralAfterLiquidation * 50) / 100;

        vm.startPrank(PLAYER);
        vm.expectEmit(true, true, true, true);
        emit Liquidated(
            PLAYER2,
            PLAYER,
            liquidateionFee,
            perpetual.getUserShortOpenInterestInTokens(PLAYER2)
        );
        perpetual.liquidate(PLAYER2);
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER), liquidateionFee);
        assertEq(
            ERC20Mock(asset).balanceOf(PLAYER2),
            ((MINT_ASSET_AMOUNT / 10) * 9) +
                (userCollateralAfterLiquidation - liquidateionFee)
        );
        assertEq(perpetual.getUserCollateral(PLAYER2), 0);
        assertEq(perpetual.getUserLongOpenInterest(PLAYER2), 0);
        assertEq(perpetual.getUserShortOpenInterest(PLAYER2), 0);
        assertEq(perpetual.getUserLongOpenInterestInTokens(PLAYER2), 0);
        assertEq(perpetual.getUserShortOpenInterestInTokens(PLAYER2), 0);
        assertEq(perpetual.getLongOpenInterest(), 0);
        assertEq(perpetual.getLongOpenInterestInTokens(), 0);
        assertEq(perpetual.getShortOpenInterest(), 0);
        assertEq(perpetual.getShortOpenInterestInTokens(), 0);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT + userLoss);
    }

    function testShouldLiquidateInvalidBothShortAndLongPositionSuccessfully()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 10);
        perpetual.addPosition(MINT_ASSET_AMOUNT / 5, true);
        perpetual.addPosition(MINT_ASSET_AMOUNT, false);
        vm.stopPrank();

        MockV3Aggregator indexTokenPriceFeed = MockV3Aggregator(
            perpetual.getIndexTokenPriceFeed()
        );
        // old price is 10000e8;
        int256 NEW_INDEX_TOKEN_PRICE = 10500e8;
        indexTokenPriceFeed.updateAnswer(NEW_INDEX_TOKEN_PRICE);

        assertFalse(
            perpetual.isValidLeverage(
                PLAYER2,
                perpetual.getUserLongOpenInterest(PLAYER2) +
                    perpetual.getUserShortOpenInterest(PLAYER2)
            )
        );

        // leverage = 20, maxLeverage is 15
        assertEq(
            uint256(
                perpetual.currentUserLeverage(
                    PLAYER2,
                    perpetual.getUserLongOpenInterest(PLAYER2) +
                        perpetual.getUserShortOpenInterest(PLAYER2)
                )
            ) / 1e18,
            20
        );
        assertEq(
            ERC20Mock(asset).balanceOf(PLAYER2),
            ((MINT_ASSET_AMOUNT * 9) / 10)
        );
        assertEq(ERC20Mock(asset).balanceOf(PLAYER), 0);

        uint256 userLongProfit = uint256(perpetual.countLongPnL(PLAYER2));
        uint256 userShortLoss = uint256(-perpetual.countShortPnL(PLAYER2));
        uint256 userCollateralAfterLiquidation = perpetual.getUserCollateral(
            PLAYER2
        ) - userShortLoss;
        uint256 liquidateionFee = (userCollateralAfterLiquidation * 50) / 100;

        vm.startPrank(PLAYER);
        vm.expectEmit(true, true, true, true);
        emit Liquidated(
            PLAYER2,
            PLAYER,
            liquidateionFee,
            perpetual.getUserLongOpenInterestInTokens(PLAYER2) +
                perpetual.getUserShortOpenInterestInTokens(PLAYER2)
        );
        perpetual.liquidate(PLAYER2);
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER), liquidateionFee);
        assertEq(
            ERC20Mock(asset).balanceOf(PLAYER2),
            ((MINT_ASSET_AMOUNT / 10) * 9) +
                (userCollateralAfterLiquidation - liquidateionFee) +
                userLongProfit
        );
        assertEq(perpetual.getUserCollateral(PLAYER2), 0);
        assertEq(perpetual.getUserLongOpenInterest(PLAYER2), 0);
        assertEq(perpetual.getUserShortOpenInterest(PLAYER2), 0);
        assertEq(perpetual.getUserLongOpenInterestInTokens(PLAYER2), 0);
        assertEq(perpetual.getUserShortOpenInterestInTokens(PLAYER2), 0);
        assertEq(perpetual.getLongOpenInterest(), 0);
        assertEq(perpetual.getLongOpenInterestInTokens(), 0);
        assertEq(perpetual.getShortOpenInterest(), 0);
        assertEq(perpetual.getShortOpenInterestInTokens(), 0);
        assertEq(
            perpetual.depositedLiquidity(),
            (MINT_ASSET_AMOUNT * 2) + userShortLoss - userLongProfit
        );
    }

    function testCurrentBorrowingIndexShouldEqualOneAtTheBeginnigBlock()
        public
    {
        assertEq(perpetual.currenBorrowinIndex(), 1e10);
    }

    function testCurrentBorrowingIndexShouldGrowInNextBlocks() public {
        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        assert(perpetual.currenBorrowinIndex() > 1e10);
        assertEq(perpetual.currenBorrowinIndex(), newBorrowingIndex);
    }

    function testShouldSaveCorrectLongPrincipalAfterAddingPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        uint256 principal = (MINT_ASSET_AMOUNT * 1e10) / newBorrowingIndex;

        assertEq(perpetual.getUserLongPrincipal(PLAYER2), principal);
    }

    function testShouldSaveCorrectShortPrincipalAfterAddingPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, false);
        vm.stopPrank();

        uint256 principal = (MINT_ASSET_AMOUNT * 1e10) / newBorrowingIndex;

        assertEq(perpetual.getUserShortPrincipal(PLAYER2), principal);
    }

    function testShouldSaveCorrectLongPrincipalAfterAddingTwoPositions()
        public
        skipSepolia
        playerDepositedAsset
        playerDepositedAsset
    {
        uint256 initialTime = block.timestamp;

        uint256 secondsPassed = 10_000;

        uint256 newFirstBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(initialTime + secondsPassed);

        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        uint256 principal = (MINT_ASSET_AMOUNT * 1e10) / newFirstBorrowingIndex;

        assertEq(perpetual.getUserLongPrincipal(PLAYER2), principal);

        uint256 newSecondBorrowingIndex = 1e10 +
            (secondsPassed * 2 * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(initialTime + (secondsPassed * 2));

        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        uint256 newPrincipal = (MINT_ASSET_AMOUNT * 1e10) /
            newSecondBorrowingIndex;

        assertEq(
            perpetual.getUserLongPrincipal(PLAYER2),
            principal + newPrincipal
        );
    }

    function testShouldAccrueCorrectBorrowingFeeForLongPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        uint256 positionWithBorrowingFees = (MINT_ASSET_AMOUNT *
            newBorrowingIndex) / 1e10;

        assertEq(
            perpetual.accruedBorrowingFeeLong(PLAYER2),
            positionWithBorrowingFees - MINT_ASSET_AMOUNT
        );
        assertEq(
            perpetual.accruedBorrowingFee(PLAYER2),
            positionWithBorrowingFees - MINT_ASSET_AMOUNT
        );
    }

    function testShouldAccrueCorrectBorrowingFeeForShortPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, false);
        vm.stopPrank();

        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        uint256 positionWithBorrowingFees = (MINT_ASSET_AMOUNT *
            newBorrowingIndex) / 1e10;

        assertEq(
            perpetual.accruedBorrowingFeeShort(PLAYER2),
            positionWithBorrowingFees - MINT_ASSET_AMOUNT
        );
        assertEq(
            perpetual.accruedBorrowingFee(PLAYER2),
            positionWithBorrowingFees - MINT_ASSET_AMOUNT
        );
    }

    function testShouldAccrueCorrectBorrowingFeeForShortAndLongPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT / 2, true);
        perpetual.addPosition(MINT_ASSET_AMOUNT / 2, false);
        vm.stopPrank();

        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        uint256 positionWithBorrowingFees = (MINT_ASSET_AMOUNT *
            newBorrowingIndex) / 1e10;

        assertEq(
            perpetual.accruedBorrowingFeeShort(PLAYER2),
            (positionWithBorrowingFees / 2) - (MINT_ASSET_AMOUNT / 2)
        );
        assertEq(
            perpetual.accruedBorrowingFeeLong(PLAYER2),
            (positionWithBorrowingFees / 2) - (MINT_ASSET_AMOUNT / 2)
        );
        assertEq(
            perpetual.accruedBorrowingFee(PLAYER2),
            positionWithBorrowingFees - MINT_ASSET_AMOUNT
        );
    }

    function testShouldAccrueTenPercentPerYearOfBorrowingFee()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        uint256 secondsPassed = 31536000; // one year

        vm.warp(block.timestamp + secondsPassed);

        assertEq(
            perpetual.accruedBorrowingFeeLong(PLAYER2),
            MINT_ASSET_AMOUNT / 10
        );
    }

    function testUserShouldPayBorrowingFeeAfterDecreasingLongPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, true);
        vm.stopPrank();

        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        uint256 positionWithBorrowingFees = (MINT_ASSET_AMOUNT *
            newBorrowingIndex) / 1e10;
        uint256 fees = positionWithBorrowingFees - MINT_ASSET_AMOUNT;

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT);
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserLongPrincipal(PLAYER2),
            (positionWithBorrowingFees * 1e10) / newBorrowingIndex
        );
        assertEq(perpetual.accruedBorrowingFeeLong(PLAYER2), fees);
        assertEq(perpetual.accruedBorrowingFee(), fees);

        vm.startPrank(PLAYER2);
        perpetual.decreasePosition(
            PLAYER2,
            perpetual.getUserLongOpenInterestInTokens(PLAYER2),
            true
        );
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT + fees);
        assertEq(
            perpetual.getUserCollateral(PLAYER2),
            MINT_ASSET_AMOUNT - fees
        );
        assertEq(perpetual.getUserLongPrincipal(PLAYER2), 0);
        assertEq(perpetual.accruedBorrowingFeeLong(PLAYER2), 0);
        assertEq(perpetual.accruedBorrowingFee(), 0);
    }

    function testUserShouldPayBorrowingFeeAfterDecreasingShortPosition()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock(asset).mint(PLAYER2, MINT_ASSET_AMOUNT);
        vm.startPrank(PLAYER2);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT);
        perpetual.addCollateral(MINT_ASSET_AMOUNT);
        perpetual.addPosition(MINT_ASSET_AMOUNT, false);
        vm.stopPrank();

        uint256 secondsPassed = 10_000;

        uint256 newBorrowingIndex = 1e10 +
            (secondsPassed * 1e10) /
            perpetual.getBorrowingPerSharePerSecond();

        vm.warp(block.timestamp + secondsPassed);

        uint256 positionWithBorrowingFees = (MINT_ASSET_AMOUNT *
            newBorrowingIndex) / 1e10;
        uint256 fees = positionWithBorrowingFees - MINT_ASSET_AMOUNT;

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT);
        assertEq(perpetual.getUserCollateral(PLAYER2), MINT_ASSET_AMOUNT);
        assertEq(
            perpetual.getUserShortPrincipal(PLAYER2),
            (positionWithBorrowingFees * 1e10) / newBorrowingIndex
        );
        assertEq(perpetual.accruedBorrowingFeeShort(PLAYER2), fees);
        assertEq(perpetual.accruedBorrowingFee(), fees);

        vm.startPrank(PLAYER2);
        perpetual.decreasePosition(
            PLAYER2,
            perpetual.getUserShortOpenInterestInTokens(PLAYER2),
            false
        );
        vm.stopPrank();

        assertEq(ERC20Mock(asset).balanceOf(PLAYER2), 0);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT + fees);
        assertEq(
            perpetual.getUserCollateral(PLAYER2),
            MINT_ASSET_AMOUNT - fees
        );
        assertEq(perpetual.getUserShortPrincipal(PLAYER2), 0);
        assertEq(perpetual.accruedBorrowingFeeShort(PLAYER2), 0);
        assertEq(perpetual.accruedBorrowingFee(), 0);
    }
}
