# 🏦 NFT Lending Protocol

A fully on-chain peer-to-peer NFT-collateralized lending protocol built with Solidity. Lenders create loan offers for whitelisted NFT collections, and borrowers can accept these offers by depositing their NFTs as collateral.

> 📚 **Learning Project** — Built to practice Solidity development, testing patterns, and DeFi mechanics. Feedback welcome!

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity)
![Foundry](https://img.shields.io/badge/Foundry-Framework-yellow)
![License](https://img.shields.io/badge/License-MIT-green)

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Deployment](#deployment)
- [Testing](#testing)
- [Configuration](#configuration)
- [Security](#security)
- [License](#license)

---

## Overview

NFT Lending enables trustless, collateralized loans using NFTs:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              LOAN LIFECYCLE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. OFFER CREATION          2. LOAN ACCEPTANCE         3. REPAYMENT/DEFAULT │
│  ┌──────────────┐           ┌──────────────┐           ┌──────────────┐     │
│  │   Lender     │           │   Borrower   │           │   Outcome    │     │
│  │  creates     │  ──────►  │   accepts    │  ──────►  │              │     │
│  │  offer       │           │   offer      │           │  ┌─────────┐ │     │
│  └──────────────┘           └──────────────┘           │  │ Repay   │ │     │
│        │                          │                    │  │ ───────►│ │     │
│        ▼                          ▼                    │  │ NFT back│ │     │
│  ┌──────────────┐           ┌──────────────┐           │  └─────────┘ │     │
│  │ Offer stored │           │ NFT locked   │           │       OR     │     │
│  │ on-chain     │           │ as collateral│           │  ┌─────────┐ │     │
│  │              │           │              │           │  │ Default │ │     │
│  │ No funds     │           │ Principal    │           │  │ ───────►│ │     │
│  │ locked yet   │           │ sent to      │           │  │ Lender  │ │     │
│  └──────────────┘           │ borrower     │           │  │ claims  │ │     │
│                             └──────────────┘           │  │ NFT     │ │     │
│                                                        │  └─────────┘ │     │
│                                                        └──────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### How It Works

1. **Lender** creates a loan offer specifying principal, interest rate, duration, and target NFT collection
2. **Borrower** accepts by depositing NFT collateral → receives principal (minus protocol fee)
3. **Resolution**: Borrower repays to reclaim NFT, or loan expires and lender claims collateral

---

## Features

### Core Functions

| Function | Description |
|----------|-------------|
| `createLoanOffer` | Create a loan offer for a whitelisted collection |
| `acceptLoanOffer` | Accept an offer by depositing NFT collateral |
| `cancelLoanOffer` | Cancel an active offer (lender only) |
| `repayLoan` | Repay principal + interest to reclaim NFT |
| `claimCollateral` | Claim defaulted NFT (lender only, after expiry) |

### Batch Operations

All core functions have batch variants (`batchCreateLoanOffers`, `batchAcceptLoanOffers`, etc.) for gas-efficient bulk operations.

---

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd nft-lending

# Install dependencies
forge install

# Build
forge build
```

---

## Usage

### Creating a Loan Offer (Lender)

```solidity
// 1. Approve wrapped native tokens
IERC20(wrappedNative).approve(nftLending, principal);

// 2. Create offer
uint256 offerId = nftLending.createLoanOffer(
    nftCollection,      // Whitelisted NFT collection
    1 ether,            // Principal: 1 WHYPE
    1000,               // Interest: 10% APR (basis points)
    7 days,             // Duration
    block.timestamp + 3 days  // Offer expiry
);
```

### Accepting a Loan Offer (Borrower)

```solidity
// 1. Approve NFT transfer
IERC721(nftCollection).approve(nftLending, tokenId);

// 2. Accept offer
uint256 loanId = nftLending.acceptLoanOffer(offerId, tokenId);
```

### Repaying a Loan (Borrower)

```solidity
// Approve repayment amount, then repay
IERC20(wrappedNative).approve(nftLending, repaymentAmount);
nftLending.repayLoan(loanId);
```

### Claiming Defaulted Collateral (Lender)

```solidity
// After loan expiry
nftLending.claimCollateral(loanId);
```

---

## Deployment

### Environment Setup

```env
DEFAULT_ANVIL_DEPLOYER=0x...
PRIVATE_KEY=0x...
```

### Deploy to HyperEVM

```bash
forge script script/DeployNFTLending.s.sol:DeployNFTLending \
    --rpc-url hyperevm \
    --broadcast
```

### Deploy Locally

```bash
anvil
forge script script/DeployNFTLending.s.sol:DeployNFTLending \
    --rpc-url http://localhost:8545 \
    --broadcast
```

---

## Testing

```bash
# Run all tests
forge test

# Verbose output
forge test -vvv

# Gas report
forge test --gas-report

# Coverage
forge coverage
```

### Coverage

| Metric | Coverage |
|--------|----------|
| Lines | 98%+ |
| Branches | 100% |
| Functions | 100% |

Unit tests + fuzz tests for all core functionality.

---

## Configuration

### Default Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Protocol Fee | 5% (500 bps) | Deducted from principal at loan creation |
| Loan Duration | 1 - 30 days | Allowed range |
| Interest Rate | 1% - 300% APR | Allowed range (basis points) |
| Batch Limit | 8 | Max items per batch operation |

### Interest Calculation

```
Interest = Principal × InterestRateBps × Duration / (10000 × 365 days)
```

---

## Security

### Protections

- **ReentrancyGuard** on all state-changing functions
- **Ownable2Step** for safe ownership transfers
- **SafeERC20** for token transfers
- **Collection Whitelist** — only approved NFTs accepted

### Considerations

- No price oracle — principal is fixed by lender
- One NFT per loan, no partial collateralization

> ⚠️ **This contract has not been audited. Use at your own risk.**

---

## Project Structure

```
nft-lending/
├── src/
│   └── NFTLending.sol          # Main contract
├── script/
│   ├── DeployNFTLending.s.sol  # Deployment
│   └── HelperConfig.s.sol      # Network configs
├── test/
│   ├── BaseTest.t.sol          # Test setup
│   ├── unit/                   # Unit tests
│   ├── fuzz/                   # Fuzz tests
│   └── mocks/                  # Mock contracts
└── foundry.toml
```

---

## License

MIT

---