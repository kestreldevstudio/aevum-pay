// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AevumInvoiceEscrow.sol";

/// @notice Live QDay Aevum Testnet fork test exercising real tUSD8 (0x456569838f1d43009A91ebA4263147Afd7233483).
contract AevumTestnetForkTest is Test {
    address constant LIVE_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    string constant AEVUM_RPC = "https://rpc-test.qday.info";

    function test_LiveAevumFork_EndToEndTUSD8InvoiceEscrow() public {
        vm.createSelectFork(AEVUM_RPC);
        assertEq(block.chainid, 44005);

        IERC20Minimal tusd8 = IERC20Minimal(LIVE_TUSD8);
        assertEq(tusd8.decimals(), 6);

        AevumInvoiceEscrow escrow = new AevumInvoiceEscrow(LIVE_TUSD8);

        address merchant = makeAddr("aevum_merchant");
        address payer = makeAddr("aevum_payer");

        // Deal live tUSD8 balance on forked Aevum Testnet state to verify real ERC-20 transfer semantics.
        deal(LIVE_TUSD8, payer, 1_000e6);
        assertEq(tusd8.balanceOf(payer), 1_000e6);

        vm.prank(merchant);
        bytes32 handleHash = escrow.registerPayee("kestrel.qday", "Kestrel Studio");

        vm.prank(merchant);
        uint256 invoiceId = escrow.createInvoice(
            payer,
            handleHash,
            250e6,
            uint64(block.timestamp + 2 days),
            1 hours,
            true,
            keccak256("QDAY-AEVUM-INV-01")
        );

        vm.startPrank(payer);
        (bool ok,) = LIVE_TUSD8.call(abi.encodeWithSignature("approve(address,uint256)", address(escrow), 250e6));
        assertTrue(ok);
        escrow.fundInvoice(invoiceId, handleHash);
        assertEq(tusd8.balanceOf(address(escrow)), 250e6);

        escrow.releaseInvoice(invoiceId);
        vm.stopPrank();

        assertEq(tusd8.balanceOf(merchant), 250e6);
        assertEq(tusd8.balanceOf(payer), 750e6);
        assertEq(tusd8.balanceOf(address(escrow)), 0);
    }
}
