// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {PerpetualScript} from "../script/Perpetual.s.sol";

contract PerpetualTest is Test {
    event UpdatedDepositedLiquidity(
        uint256 indexed _before,
        uint256 indexed _after
    );

    Perpetual public perpetual;
    address public asset;
    address public indexToken;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MINT_ASSET_AMOUNT = 10e18;

    function setUp() public {
        perpetual = (new PerpetualScript()).run();
        asset = perpetual.asset();
        indexToken = perpetual.getIndexToken();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
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

        assertEq((assetERC20).balanceOf(PLAYER), MINT_ASSET_AMOUNT);
        assertEq(assetERC20.balanceOf(address(perpetual)), 0);

        vm.startPrank(PLAYER);
        assetERC20.approve(address(perpetual), MINT_ASSET_AMOUNT);
        vm.expectEmit(true, true, false, false);
        emit UpdatedDepositedLiquidity(0, MINT_ASSET_AMOUNT);
        perpetual.deposit(MINT_ASSET_AMOUNT, PLAYER);
        vm.stopPrank();

        assertEq(assetERC20.balanceOf(PLAYER), 0);
        assertEq(assetERC20.balanceOf(address(perpetual)), MINT_ASSET_AMOUNT);
        assertEq(perpetual.depositedLiquidity(), MINT_ASSET_AMOUNT);
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

    function testShouldRevertOnWithdrawingBelowReservesLiquidityThreshold()
        public
        skipSepolia
        playerDepositedAsset
    {
        ERC20Mock assetERC20 = ERC20Mock(asset);

        assertEq((assetERC20).balanceOf(PLAYER), 0);
        assertEq(assetERC20.balanceOf(address(perpetual)), MINT_ASSET_AMOUNT);

        vm.startPrank(PLAYER);
        vm.expectRevert(
            Perpetual.Perpetual__LiquidityReservesBelowThreshold.selector
        );
        perpetual.withdraw(MINT_ASSET_AMOUNT, PLAYER, PLAYER);
        vm.stopPrank();
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

    function testShouldHaveInvalidLiquidityReservesThresholdInTheStart()
        public
    {
        assertFalse(perpetual.checkLiquidityReservesThreshold());
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
}
