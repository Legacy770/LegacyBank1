// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LegacyBank} from "../src/LegacyBank.sol";

contract Deploy is Script {
    function run() external {
        address aavePool = vm.envAddress("AAVE_POOL");
        address treasury = vm.envAddress("TREASURY");
        address usdc = vm.envAddress("USDC");
        address aUsdc = vm.envAddress("AUSDC");

        vm.startBroadcast();
        LegacyBank bank = new LegacyBank(msg.sender, treasury, aavePool, 7_000); // 70% cap
        bank.configureToken(usdc, true, aUsdc);
        vm.stopBroadcast();

        console.log("LegacyBank:", address(bank));
    }
}