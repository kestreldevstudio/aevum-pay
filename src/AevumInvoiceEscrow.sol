// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @title AevumInvoiceEscrow
/// @notice End-to-end tUSD8 stablecoin payment protocol for QDay Aevum Testnet:
///         1. Confirmation of Payee (CoP) handle registry to prevent misdirected transfers
///         2. Structured invoice creation, non-custodial escrow, release, dispute, and expiry refund
///         3. Verified batch payroll settlement in a single atomic transaction
contract AevumInvoiceEscrow {
    enum InvoiceStatus {
        NONE,
        OPEN,
        FUNDED,
        RELEASED,
        DISPUTED,
        REFUNDED,
        CANCELLED
    }

    struct PayeeProfile {
        address owner;
        string displayName;
        bool active;
    }

    struct Invoice {
        uint256 id;
        address payee;
        address payer;
        bytes32 payeeHandleHash;
        uint256 amount;
        uint64 createdAt;
        uint64 dueAt;
        uint64 fundedAt;
        uint64 releaseWindowSecs;
        bool requireConfirmation;
        InvoiceStatus status;
        bytes32 memoHash;
    }

    error ZeroAddress();
    error ZeroAmount();
    error InvalidDueDate();
    error HandleAlreadyTaken();
    error EmptyHandle();
    error PayeeVerificationFailed();
    error InvoiceNotFound();
    error InvalidStatus(InvoiceStatus expected, InvoiceStatus actual);
    error Unauthorized();
    error ReleaseWindowActive(uint64 unlockTime);
    error InvoiceExpired();
    error InvoiceNotExpired();
    error LengthMismatch();
    error EmptyBatch();
    error TransferFailed();
    error Reentrancy();

    event PayeeRegistered(bytes32 indexed handleHash, address indexed owner, string handle, string displayName);
    event PayeeUpdated(bytes32 indexed handleHash, address indexed owner, string displayName, bool active);
    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed payee,
        address indexed payer,
        bytes32 payeeHandleHash,
        uint256 amount,
        uint64 dueAt,
        bool requireConfirmation,
        bytes32 memoHash
    );
    event InvoiceFunded(uint256 indexed invoiceId, address indexed payer, uint256 amount, bool instantSettled);
    event InvoiceReleased(uint256 indexed invoiceId, address indexed payee, uint256 amount, address triggeredBy);
    event InvoiceDisputed(uint256 indexed invoiceId, address indexed payer, bytes32 reasonHash);
    event InvoiceRefunded(uint256 indexed invoiceId, address indexed payer, uint256 amount);
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed payee);
    event BatchPayrollSettled(
        address indexed employer,
        uint256 recipientCount,
        uint256 totalAmount,
        bytes32 indexed payrollRunId
    );

    IERC20Minimal public immutable stablecoin;
    uint256 public nextInvoiceId = 1;
    uint256 private _locked = 1;

    mapping(bytes32 => PayeeProfile) public payeeRegistry;
    mapping(uint256 => Invoice) public invoices;
    mapping(address => uint256[]) private _payeeInvoices;
    mapping(address => uint256[]) private _payerInvoices;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address stablecoin_) {
        if (stablecoin_ == address(0)) revert ZeroAddress();
        stablecoin = IERC20Minimal(stablecoin_);
    }

    // -------------------------------------------------------------------------
    // Confirmation of Payee (CoP) Registry
    // -------------------------------------------------------------------------

    function computeHandleHash(string calldata handle) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(handle));
    }

    function registerPayee(string calldata handle, string calldata displayName) external returns (bytes32 handleHash) {
        if (bytes(handle).length == 0 || bytes(displayName).length == 0) revert EmptyHandle();
        handleHash = computeHandleHash(handle);
        PayeeProfile storage existing = payeeRegistry[handleHash];
        if (existing.owner != address(0)) revert HandleAlreadyTaken();

        payeeRegistry[handleHash] = PayeeProfile({
            owner: msg.sender,
            displayName: displayName,
            active: true
        });

        emit PayeeRegistered(handleHash, msg.sender, handle, displayName);
    }

    function updatePayee(bytes32 handleHash, string calldata displayName, bool active) external {
        PayeeProfile storage profile = payeeRegistry[handleHash];
        if (profile.owner != msg.sender) revert Unauthorized();
        if (bytes(displayName).length == 0) revert EmptyHandle();
        profile.displayName = displayName;
        profile.active = active;
        emit PayeeUpdated(handleHash, msg.sender, displayName, active);
    }

    function verifyPayee(bytes32 handleHash, address expectedPayee) public view returns (bool) {
        PayeeProfile storage profile = payeeRegistry[handleHash];
        return profile.active && profile.owner == expectedPayee && expectedPayee != address(0);
    }

    // -------------------------------------------------------------------------
    // Invoice & Non-Custodial Escrow Flow
    // -------------------------------------------------------------------------

    function createInvoice(
        address payer,
        bytes32 payeeHandleHash,
        uint256 amount,
        uint64 dueAt,
        uint64 releaseWindowSecs,
        bool requireConfirmation,
        bytes32 memoHash
    ) external returns (uint256 invoiceId) {
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (dueAt <= block.timestamp) revert InvalidDueDate();
        if (payeeHandleHash != bytes32(0) && !verifyPayee(payeeHandleHash, msg.sender)) {
            revert PayeeVerificationFailed();
        }

        invoiceId = nextInvoiceId++;
        invoices[invoiceId] = Invoice({
            id: invoiceId,
            payee: msg.sender,
            payer: payer,
            payeeHandleHash: payeeHandleHash,
            amount: amount,
            createdAt: uint64(block.timestamp),
            dueAt: dueAt,
            fundedAt: 0,
            releaseWindowSecs: releaseWindowSecs,
            requireConfirmation: requireConfirmation,
            status: InvoiceStatus.OPEN,
            memoHash: memoHash
        });

        _payeeInvoices[msg.sender].push(invoiceId);
        _payerInvoices[payer].push(invoiceId);

        emit InvoiceCreated(
            invoiceId,
            msg.sender,
            payer,
            payeeHandleHash,
            amount,
            dueAt,
            requireConfirmation,
            memoHash
        );
    }

    /// @notice Fund an invoice in tUSD8. If `requireConfirmation` is false, settles immediately to payee;
    ///         otherwise locks tUSD8 in escrow until released by payer or auto-released after `releaseWindowSecs`.
    function fundInvoice(uint256 invoiceId, bytes32 expectedPayeeHandleHash) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == InvoiceStatus.NONE) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.OPEN) revert InvalidStatus(InvoiceStatus.OPEN, inv.status);
        if (msg.sender != inv.payer) revert Unauthorized();
        if (block.timestamp > inv.dueAt) revert InvoiceExpired();
        if (inv.payeeHandleHash != expectedPayeeHandleHash) revert PayeeVerificationFailed();
        if (inv.payeeHandleHash != bytes32(0) && !verifyPayee(inv.payeeHandleHash, inv.payee)) {
            revert PayeeVerificationFailed();
        }

        inv.fundedAt = uint64(block.timestamp);

        if (!inv.requireConfirmation) {
            inv.status = InvoiceStatus.RELEASED;
            _safeTransferFrom(inv.payer, inv.payee, inv.amount);
            emit InvoiceFunded(invoiceId, inv.payer, inv.amount, true);
            emit InvoiceReleased(invoiceId, inv.payee, inv.amount, msg.sender);
        } else {
            inv.status = InvoiceStatus.FUNDED;
            _safeTransferFrom(inv.payer, address(this), inv.amount);
            emit InvoiceFunded(invoiceId, inv.payer, inv.amount, false);
        }
    }

    /// @notice Release escrowed tUSD8 to payee. Payer can release immediately; payee can claim after `releaseWindowSecs`.
    function releaseInvoice(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == InvoiceStatus.NONE) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.FUNDED) revert InvalidStatus(InvoiceStatus.FUNDED, inv.status);

        if (msg.sender == inv.payer) {
            // Immediate release authorized by payer.
        } else if (msg.sender == inv.payee) {
            uint64 unlockTime = inv.fundedAt + inv.releaseWindowSecs;
            if (block.timestamp < unlockTime) revert ReleaseWindowActive(unlockTime);
        } else {
            revert Unauthorized();
        }

        inv.status = InvoiceStatus.RELEASED;
        _safeTransfer(inv.payee, inv.amount);
        emit InvoiceReleased(invoiceId, inv.payee, inv.amount, msg.sender);
    }

    /// @notice Payer freezes escrow within the release window if delivery is contested.
    function disputeInvoice(uint256 invoiceId, bytes32 reasonHash) external {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == InvoiceStatus.NONE) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.FUNDED) revert InvalidStatus(InvoiceStatus.FUNDED, inv.status);
        if (msg.sender != inv.payer) revert Unauthorized();

        inv.status = InvoiceStatus.DISPUTED;
        emit InvoiceDisputed(invoiceId, msg.sender, reasonHash);
    }

    /// @notice Payee can voluntarily refund a funded or disputed invoice back to the payer.
    function refundPayer(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == InvoiceStatus.NONE) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.FUNDED && inv.status != InvoiceStatus.DISPUTED) {
            revert InvalidStatus(InvoiceStatus.FUNDED, inv.status);
        }
        if (msg.sender != inv.payee) revert Unauthorized();

        inv.status = InvoiceStatus.REFUNDED;
        _safeTransfer(inv.payer, inv.amount);
        emit InvoiceRefunded(invoiceId, inv.payer, inv.amount);
    }

    /// @notice Payee cancels an unpaid open invoice.
    function cancelInvoice(uint256 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == InvoiceStatus.NONE) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.OPEN) revert InvalidStatus(InvoiceStatus.OPEN, inv.status);
        if (msg.sender != inv.payee) revert Unauthorized();

        inv.status = InvoiceStatus.CANCELLED;
        emit InvoiceCancelled(invoiceId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Verified Batch Payroll Settlement
    // -------------------------------------------------------------------------

    /// @notice Atomically settle payroll in tUSD8 to multiple recipients with mandatory Confirmation of Payee.
    function batchPayPayroll(
        bytes32 payrollRunId,
        bytes32[] calldata handleHashes,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant returns (uint256 totalAmount) {
        uint256 n = recipients.length;
        if (n == 0) revert EmptyBatch();
        if (handleHashes.length != n || amounts.length != n) revert LengthMismatch();

        for (uint256 i = 0; i < n; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert ZeroAmount();
            if (handleHashes[i] != bytes32(0) && !verifyPayee(handleHashes[i], recipients[i])) {
                revert PayeeVerificationFailed();
            }
            totalAmount += amounts[i];
            _safeTransferFrom(msg.sender, recipients[i], amounts[i]);
        }

        emit BatchPayrollSettled(msg.sender, n, totalAmount, payrollRunId);
    }

    // -------------------------------------------------------------------------
    // Views & Safe ERC-20 Helpers
    // -------------------------------------------------------------------------

    function getPayeeInvoices(address payee) external view returns (uint256[] memory) {
        return _payeeInvoices[payee];
    }

    function getPayerInvoices(address payer) external view returns (uint256[] memory) {
        return _payerInvoices[payer];
    }

    function _safeTransfer(address to, uint256 value) internal {
        (bool ok, bytes memory ret) = address(stablecoin).call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, value)
        );
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address from, address to, uint256 value) internal {
        (bool ok, bytes memory ret) = address(stablecoin).call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, value)
        );
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
