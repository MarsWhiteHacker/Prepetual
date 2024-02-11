// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract PerpetualScript is Script {
    function run() external returns (Perpetual) {
        HelperConfig config = new HelperConfig();
        (
            address vaultAddress,
            address indexAsset,
            address vaultAssetPriceFeed,
            address indexAssetPriceFeed
        ) = config.config();

        vm.startBroadcast();
        Perpetual perpetual = new Perpetual(
            vaultAddress,
            indexAsset,
            vaultAssetPriceFeed,
            indexAssetPriceFeed
        );
        vm.stopBroadcast();

        return perpetual;
    }
}
