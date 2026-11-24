// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AevumInvoiceEscrow.sol";

contract MockTUSD8 {
    string public name = "Test USD8";
    string public symbol = "tUSD8";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AevumInvoiceEscrowTest is Test {
    MockTUSD8 token;
    AevumInvoiceEscrow escrow;

    address merchant = makeAddr("merchant");
    address contractor = makeAddr("contractor");
    address client = makeAddr("client");
    address attacker = makeAddr("attacker");

    function setUp() public {
        token = new MockTUSD8();
        escrow = new AevumInvoiceEscrow(address(token));
        token.mint(client, 100_000e6);
    }

    function test_RegisterPayeeAndInstantInvoiceFlow() public {
        vm.prank(merchant);
        bytes32 handleHash = escrow.registerPayee("kestrel.aevum", "Kestrel Studio");
        assertTrue(escrow.verifyPayee(handleHash, merchant));
        assertFalse(escrow.verifyPayee(handleHash, attacker));

        vm.prank(merchant);
        uint256 id = escrow.createInvoice(
            client,
            handleHash,
            1_250e6,
            uint64(block.timestamp + 7 days),
            0,
            false,
            keccak256("INV-2026-001")
        );

        vm.startPrank(client);
        token.approve(address(escrow), 1_250e6);
        escrow.fundInvoice(id, handleHash);
        vm.stopPrank();

        assertEq(token.balanceOf(merchant), 1_250e6);
        assertEq(token.balanceOf(address(escrow)), 0);
        (, , , , , , , , , , AevumInvoiceEscrow.InvoiceStatus st, ) = escrow.invoices(id);
        assertEq(uint8(st), uint8(AevumInvoiceEscrow.InvoiceStatus.RELEASED));
    }

    function test_EscrowInvoicePayerReleaseAndAutoRelease() public {
        vm.prank(merchant);
        bytes32 handleHash = escrow.registerPayee("acme.aevum", "Acme Dev");

        vm.prank(merchant);
        uint256 id = escrow.createInvoice(
            client,
            handleHash,
            500e6,
            uint64(block.timestamp + 3 days),
            2 days,
            true,
            keccak256("MILESTONE-1")
        );

        vm.startPrank(client);
        token.approve(address(escrow), 500e6);
        escrow.fundInvoice(id, handleHash);
        vm.stopPrank();

        assertEq(token.balanceOf(address(escrow)), 500e6);
        assertEq(token.balanceOf(merchant), 0);

        // Merchant cannot release early.
        vm.prank(merchant);
        vm.expectRevert();
        escrow.releaseInvoice(id);

        // Warp past 2-day release window -> merchant can auto-claim.
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(merchant);
        escrow.releaseInvoice(id);

        assertEq(token.balanceOf(merchant), 500e6);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_DisputeBlocksAutoReleaseAndAllowsRefund() public {
        vm.prank(merchant);
        bytes32 handleHash = escrow.registerPayee("shop.aevum", "Shop Co");

        vm.prank(merchant);
        uint256 id = escrow.createInvoice(
            client,
            handleHash,
            300e6,
            uint64(block.timestamp + 5 days),
            1 days,
            true,
            keccak256("INV-DISPUTE")
        );

        vm.startPrank(client);
        token.approve(address(escrow), 300e6);
        escrow.fundInvoice(id, handleHash);
        escrow.disputeInvoice(id, keccak256("DELIVERY-INCOMPLETE"));
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.prank(merchant);
        vm.expectRevert();
        escrow.releaseInvoice(id);

        // Merchant refunds client cleanly.
        uint256 beforeBal = token.balanceOf(client);
        vm.prank(merchant);
        escrow.refundPayer(id);
        assertEq(token.balanceOf(client), beforeBal + 300e6);
    }

    function test_ConfirmationOfPayeeMismatchReverts() public {
        vm.prank(merchant);
        bytes32 handleHash = escrow.registerPayee("verified.aevum", "Verified Payee");

        vm.prank(merchant);
        uint256 id = escrow.createInvoice(
            client,
            handleHash,
            100e6,
            uint64(block.timestamp + 1 days),
            0,
            false,
            keccak256("INV-COP")
        );

        vm.startPrank(client);
        token.approve(address(escrow), 100e6);
        vm.expectRevert(AevumInvoiceEscrow.PayeeVerificationFailed.selector);
        escrow.fundInvoice(id, keccak256("wrong.aevum"));
        vm.stopPrank();
    }

    function test_BatchPayrollWithConfirmationOfPayee() public {
        vm.prank(merchant);
        bytes32 h1 = escrow.registerPayee("alice.aevum", "Alice");
        vm.prank(contractor);
        bytes32 h2 = escrow.registerPayee("bob.aevum", "Bob");

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = h1;
        hashes[1] = h2;

        address[] memory recipients = new address[](2);
        recipients[0] = merchant;
        recipients[1] = contractor;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2_000e6;
        amounts[1] = 1_500e6;

        vm.startPrank(client);
        token.approve(address(escrow), 3_500e6);
        uint256 total = escrow.batchPayPayroll(keccak256("PAYROLL-2026-11"), hashes, recipients, amounts);
        vm.stopPrank();

        assertEq(total, 3_500e6);
        assertEq(token.balanceOf(merchant), 2_000e6);
        assertEq(token.balanceOf(contractor), 1_500e6);
    }

    function test_BatchPayrollRevertsOnWrongRecipientAddress() public {
        vm.prank(merchant);
        bytes32 h1 = escrow.registerPayee("alice.aevum", "Alice");

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = h1;
        address[] memory recipients = new address[](1);
        recipients[0] = attacker; // Wrong address for alice.aevum!
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e6;

        vm.startPrank(client);
        token.approve(address(escrow), 500e6);
        vm.expectRevert(AevumInvoiceEscrow.PayeeVerificationFailed.selector);
        escrow.batchPayPayroll(keccak256("PAYROLL-BAD"), hashes, recipients, amounts);
        vm.stopPrank();
    }

    function testFuzz_InstantInvoiceSettlement(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 50_000e6);
        vm.prank(merchant);
        bytes32 h = escrow.registerPayee("fuzz.aevum", "Fuzz Merchant");

        vm.prank(merchant);
        uint256 id = escrow.createInvoice(client, h, amount, uint64(block.timestamp + 1 days), 0, false, bytes32(0));

        vm.startPrank(client);
        token.approve(address(escrow), amount);
        escrow.fundInvoice(id, h);
        vm.stopPrank();

        assertEq(token.balanceOf(merchant), amount);
    }
}
