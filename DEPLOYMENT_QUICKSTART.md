# Deployment Quick Start

Quick reference for deploying Settlement contracts to Ethereum and Base.

## Prerequisites

- Foundry installed
- `.env` file configured (copy from `env.template`)
- RPC access to Ethereum and Base networks
- Deployer account with sufficient ETH

## Quick Commands

### 1. Setup Environment

```bash
cp env.template .env
# Edit .env with your keys and RPC URLs
```

### 2. Deploy Contracts

**Ethereum:**
```bash
make deploy-ethereum
```

**Base:**
```bash
make deploy-base
```

### 3. Configure Contracts

After deployment, save the contract address and configure:

**Ethereum:**
```bash
make configure-ethereum SETTLEMENT_ADDRESS=0x...
```

**Base:**
```bash
make configure-base SETTLEMENT_ADDRESS=0x...
```

## Required Environment Variables

Minimum required for deployment:

```bash
PRIVATE_KEY=your_key_without_0x
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/tCMAPrjXUlMZqpkxMfLRr
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/tCMAPrjXUlMZqpkxMfLRr
```

Optional for verification:

```bash
ETHERSCAN_API_KEY=your_key
BASESCAN_API_KEY=your_key
```

## Network Information

| Network | Chain ID | Explorer | RPC (Alchemy) |
|---------|----------|----------|---------------|
| Ethereum | 1 | [Etherscan](https://etherscan.io) | `https://eth-mainnet.g.alchemy.com/v2/tCMAPrjXUlMZqpkxMfLRr` |
| Base | 8453 | [Basescan](https://basescan.org) | `https://base-mainnet.g.alchemy.com/v2/tCMAPrjXUlMZqpkxMfLRr` |

## Full Documentation

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for complete deployment guide.


