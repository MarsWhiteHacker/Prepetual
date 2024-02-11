// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

contract HelperConfig is Script {
    struct Config {
        address vaultAsset;
        address indexAsset;
        address vaultAssetPriceFeed;
        address indexAssetPriceFeed;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant USDC_USD_PRICE = 1e8;
    int256 public constant BTC_USD_PRICE = 10000e8;

    Config public config;

    constructor() {
        if (block.chainid == 11155111) {
            config = getSepoliaEthConfig();
        } else {
            config = getAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public pure returns (Config memory) {
        /**
         * vaultAsset = USDC
         * indexAsset = BTC
         * vaultAssetPriceFeed = USDC/USD
         * indexAssetPriceFeed = BTC/USD
         */
        return
            Config({
                vaultAsset: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
                indexAsset: 0x29f2D40B0605204364af54EC677bD022dA425d03,
                vaultAssetPriceFeed: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E,
                indexAssetPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43
            });
    }

    function getAnvilEthConfig() public returns (Config memory) {
        if (config.vaultAsset != address(0)) {
            return config;
        }

        vm.startBroadcast();
        ERC20Mock vaultAssetMock = new ERC20Mock();
        ERC20Mock indexAssetMock = new ERC20Mock();
        MockV3Aggregator vaultAssetUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            USDC_USD_PRICE
        );
        MockV3Aggregator indexAssetUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            BTC_USD_PRICE
        );
        vm.stopBroadcast();

        return
            Config({
                vaultAsset: address(vaultAssetMock),
                indexAsset: address(indexAssetMock),
                vaultAssetPriceFeed: address(vaultAssetUsdPriceFeed),
                indexAssetPriceFeed: address(indexAssetUsdPriceFeed)
            });
    }
}
