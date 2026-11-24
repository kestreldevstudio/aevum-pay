# AevumPay — Verified tUSD8 Invoice, Escrow & Batch Payroll on QDay Aevum

Built for the **Aevum Builder Challenge #1 (DoraHacks)** on **QDay Aevum Testnet (Chain ID `44005`)** using official test stablecoin **`tUSD8`** (`0x456569838f1d43009A91ebA4263147Afd7233483`).

## Problem Solved

On-chain stablecoin business payments (invoices, contractor milestones, and batch payroll) suffer from two operational risks:
1. **Misdirected transfers** caused by mistyped hex addresses or spoofed payment requests.
2. **Lack of delivery-contingent escrow** for milestone-based B2B invoices.

**AevumPay** combines an on-chain **Confirmation of Payee (CoP)** handle registry with **non-custodial `tUSD8` invoice escrow** and **atomic batch payroll** in a single audited-style Solidity contract.

## Architecture & Core Flows

```
Payee ── registerPayee("kestrel.aevum", "Kestrel Studio") ──► On-Chain CoP Registry
  │
  └── createInvoice(payer, handleHash, amount, dueAt, escrow?) ──► Invoice #id (OPEN)
                                                                       │
Payer ── approve(tUSD8) + fundInvoice(id, expectedHandleHash) ─────────┤
         (reverts if handle != payee address!)                         │
         ├── Instant mode  ──► tUSD8 sent directly to Payee (RELEASED)
         └── Escrow mode   ──► tUSD8 locked in contract (FUNDED)
                               ├── releaseInvoice(id) by Payer (immediate) or Payee (after window)
                               ├── disputeInvoice(id, reasonHash) by Payer
                               └── refundPayer(id) by Payee
```

## QDay Aevum Testnet Configuration

* **Network**: QDay Aevum Testnet (`Chain ID: 44005`)
* **RPC URL**: `https://rpc-test.qday.info`
* **Explorer**: `https://explorer-test.qday.info`
* **Official `tUSD8` Stablecoin (6 decimals)**: `0x456569838f1d43009A91ebA4263147Afd7233483`

## Running Tests (Unit + Fuzz + Live Aevum Testnet Fork)

```bash
forge test -vv
```

This runs both the local unit/fuzz suite (`test/AevumInvoiceEscrow.t.sol`) and the **live QDay Aevum Testnet fork test** (`test/AevumTestnetFork.t.sol`) directly against `https://rpc-test.qday.info` and the real `tUSD8` contract.

## Deploying to QDay Aevum Testnet

```bash
forge script script/DeployAevumPay.s.sol:DeployAevumPay \
  --rpc-url https://rpc-test.qday.info \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

## Web Demo UI

Open `docs/index.html` (or GitHub Pages) with MetaMask or Rabby Wallet to add/switch to QDay Aevum Testnet in one click, register a verified payee handle, and run the complete `tUSD8` invoice and escrow flow.
