// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {PerpetualScript} from "../script/Perpetual.s.sol";

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

        assertEq(perpetual.getUserCollatral(PLAYER), MINT_ASSET_AMOUNT / 2);

        vm.startPrank(PLAYER);
        ERC20Mock(asset).approve(address(perpetual), MINT_ASSET_AMOUNT / 2);
        perpetual.addCollateral(MINT_ASSET_AMOUNT / 2);
        vm.stopPrank();

        assertEq(assetERC20.balanceOf(PLAYER), 0);
        assertEq(perpetual.balanceOf(PLAYER), 0);
        assertEq(perpetual.getUserCollatral(PLAYER), MINT_ASSET_AMOUNT);
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

        assertEq(perpetual.getUserCollatral(PLAYER2), ASSET_BALANCE_PLAYER2);
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
}
