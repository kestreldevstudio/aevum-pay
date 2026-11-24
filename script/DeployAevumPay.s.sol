// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AevumInvoiceEscrow.sol";

contract DeployAevumPay is Script {
    address public constant AEVUM_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (AevumInvoiceEscrow deployed) {
        vm.startBroadcast();
        deployed = new AevumInvoiceEscrow(AEVUM_TUSD8);
        vm.stopBroadcast();
        console2.log("AevumInvoiceEscrow deployed at:", address(deployed));
        console2.log("Configured tUSD8 stablecoin:", AEVUM_TUSD8);
    }
}
