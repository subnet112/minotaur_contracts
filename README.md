# Mino Settlement Contracts

This repository implements the single-order settlement flow for decentralized exchange orders. The system mirrors CoW Protocol's GPv2 settlement guarantees while supporting multiple permit standards, on-chain interaction plans, and configurable relayer and target allowlisting.

## Table of Contents

- [Contracts](#contracts)
- [Execution Plan Simulator](#execution-plan-simulator)
- [Building and Running the Simulator](#building-and-running-the-simulator)
- [Settlement Contract](#settlement-contract)
- [Simulator Limitations](#simulator-limitations)
- [Development](#development)

---

## Contracts

### Settlement Contract (`src/Settlement.sol`)

The main settlement entry point that handles:
- **EIP-712 Intent Verification**: Validates user-signed order intents
- **Permit Execution**: Supports multiple permit standards (EIP-2612, EIP-3009, Standard Approval, Custom)
- **Nonce Management**: Prevents replay attacks via per-user nonce tracking
- **Interaction Replay**: Executes solver-provided interaction plans atomically
- **Positive-Slippage Fee Skimming**: Configurable fee collection on positive slippage
- **Settlement Telemetry**: Emits events for monitoring and analytics

### Interfaces

- `src/interfaces/ITransferWithAuthorization.sol` – Minimal EIP-3009 interface for tokens like USDC

---

## Execution Plan Simulator

The simulator (`script/ExecutionPlanSimulator.s.sol`) is a Foundry script that validates execution plans by replaying them on a forked blockchain state. It's packaged as a Docker image for easy distribution and integration.

### How It Works

The simulator performs the following steps:

1. **Parse Input JSON**: Reads the order intent and execution plan from the provided JSON
2. **Fork Blockchain**: Creates a fork at the specified block number (or latest if not specified)
3. **Deploy Settlement Contract**: Deploys the Settlement contract at a fixed address (`0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3`) for consistency
4. **Prepare State**:
   - Mints/transfers `amountIn` tokens to the user address
   - Sets up token approvals if needed (via permit or direct approval)
   - Funds the relayer with ETH for `callValue`
5. **Execute Order**: Calls `settlement.executeOrder()` with the parsed intent and execution plan
6. **Capture Results**: Records gas usage, output amounts, fees, and any errors
7. **Return JSON Summary**: Outputs a structured JSON result with execution details

### What the Simulator Validates

✅ **Signature Validation**: Verifies EIP-712 signature matches the order intent  
✅ **Order Structure**: Validates deadline, nonce, addresses, amounts  
✅ **Execution Plan**: Verifies interactions hash matches what was signed  
✅ **Token Transfers**: Ensures user funds collection and output amount meet `minAmountOut`  
✅ **Interactions Execution**: Verifies all interactions in the plan succeed  
✅ **Slippage Protection**: Confirms output meets minimum requirements  

### What the Simulator Does NOT Validate

⚠️ **BlockNumber Recency**: Does not validate that `blockNumber` is recent (see [Limitations](#simulator-limitations))  
⚠️ **Relayer Authorization**: Does not check if relayer is trusted (if restrictions enabled)  
⚠️ **Nonce State**: Uses fresh fork state, so nonces always appear unused  
⚠️ **User Balance**: Mints tokens in simulation, doesn't verify real user balance  
⚠️ **Contract State**: Uses fork state, which may differ from current on-chain state  

See `docs/simulation-security-analysis.md` for detailed security analysis.

---

## Building and Running the Simulator

### Building Docker Image Locally

```bash
# Build the image
docker build -t mino-simulation .

# Or build with a specific tag
docker build -t mino-simulation:v1.0.0 .
```

The Dockerfile:
- Uses Foundry base image (`ghcr.io/foundry-rs/foundry:latest`)
- Pre-compiles contracts during build for faster execution
- Sets up the simulation script and entrypoint
- Configures default fork URL (can be overridden at runtime)

### Running the Simulator

#### Basic Usage

```bash
# Using stdin (recommended for large payloads)
cat configs/usdc-weth-univ3.json | docker run -i --rm mino-simulation "" "https://mainnet.infura.io/v3/YOUR_KEY"

# Using command-line argument (may truncate for large JSON files)
docker run --rm mino-simulation "$(cat configs/usdc-weth-univ3.json)" "https://mainnet.infura.io/v3/YOUR_KEY"
```

**Note**: For large JSON files, use stdin (with `-i` flag) to avoid truncation issues with command-line arguments.

#### Arguments

1. **JSON Payload** (first argument or stdin):
   - The complete order intent and execution plan in JSON format
   - Can be passed as argument or piped via stdin
   - Must be valid JSON

2. **Fork URL** (second argument):
   - RPC URL for the blockchain fork (e.g., Infura, Alchemy, Anvil)
   - Can also be set via `SIM_FORK_URL` environment variable
   - Format: `https://mainnet.infura.io/v3/YOUR_KEY` or `http://localhost:8545`

#### Environment Variables

- `SIM_FORK_URL`: RPC URL for the fork (if not provided as argument)
- `SIM_INPUT_PATH`: Path to input JSON file (used internally by the script)

**Note**: The simulator requires a signature to be provided in the JSON payload (see [Input JSON Format](#input-json-format)). Signatures must be generated externally using the user's private key. See `docs/signature-generation-guide.md` for instructions.

#### Example with Signature in JSON

The JSON payload must include a `signature` field at the root level. Generate the signature using the user's private key (see `docs/signature-generation-guide.md`):

```json
{
  "quoteDetails": { ... },
  "signature": "0x..."  // Required: EIP-712 signature
}
```

Then run:

```bash
docker run --rm \
  mino-simulation \
  "$(cat configs/usdc-weth-univ3.json)" \
  "https://mainnet.infura.io/v3/YOUR_KEY"
```

### Output Format

The simulator returns a JSON object with the following fields:

```json
{
  "success": true,
  "quoteId": "quote-paper-11bb3d4f-0a60-4cf6-9788-5ccab44520c9",
  "settlement": "0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3",
  "user": "0x9996E4253e938D81A360b353C4FCefa67E7120Bc",
  "receiver": "0x9996E4253e938D81A360b353C4FCefa67E7120Bc",
  "tokenIn": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  "tokenOut": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  "amountIn": "1000000000",
  "amountOut": "304664226045999527",
  "receiverDelta": "304664226045999527",
  "feeAmount": "0",
  "gasUsed": "185432",
  "callValue": "0"
}
```

On failure, the output includes:
- `success: false`
- `errorData`: Raw error bytes (hex string)
- `errorMessage`: Human-readable error message with debugging details

---

## Input JSON Format

The simulator accepts a nested JSON structure describing the order intent and execution plan.

### Schema

```json
{
  "quoteDetails": {
    "quoteId": "string",  // Any string identifier (will be hashed to bytes32)
    "settlement": {
      "contractAddress": "0x...",  // Settlement contract address
      "deadline": 4102444800,      // Unix timestamp (seconds)
      "nonce": "1",                // User nonce (can be hex string or decimal)
      "callValue": "0",            // ETH value to send with interactions
      "gasEstimate": 450000,       // Gas estimate hint
      "interactionsHash": "0x...", // Optional: hash of execution plan (validated if provided)
      "executionPlan": {
        "blockNumber": "23746829", // Block number to fork at (optional, uses latest if omitted)
        "preInteractions": [...],  // Interactions before main swap
        "interactions": [...],     // Main swap interactions
        "postInteractions": []     // Interactions after main swap
      },
      "permit": {
        "permitType": "standard_approval",  // none, standard_approval, eip2612, eip3009, custom
        "permitCall": "0x",                 // ABI-encoded permit call (for EIP2612/EIP3009/Custom)
        "amount": "1000000000",             // Permit/approval amount
        "deadline": 4102444800              // Permit deadline (if applicable)
      }
    },
    "details": {
      "availableInputs": [
        {
          "user": "0x000000019996e4253e938d81a360b353c4fcefa67e7120bc",  // InteropAddress or regular address
          "asset": "0x00000001a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",  // InteropAddress or regular address
          "amount": "1000000000"
        }
      ],
      "requestedOutputs": [
        {
          "receiver": "0x000000019996e4253e938d81a360b353c4fcefa67e7120bc",  // InteropAddress or regular address
          "asset": "0x00000001c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",      // InteropAddress or regular address
          "amount": "304664226045999527"  // minAmountOut (minimum acceptable output)
        }
      ]
    }
  },
  "signature": "0x..."  // Required: EIP-712 signature (must be provided)
}
```

### Address Formats

The simulator supports two address formats:

1. **Regular Address**: Standard 20-byte Ethereum address
   - Example: `"0x9996E4253e938D81A360b353C4FCefa67E7120Bc"`

2. **InteropAddress**: Extended format with chain ID prefix
   - Format: `0x[4 bytes chainId][20 bytes address]`
   - Example: `"0x000000019996e4253e938d81a360b353c4fcefa67e7120bc"` (chain ID 1)
   - Chain ID is extracted automatically from the first 4 bytes

### Interaction Format

Each interaction in the execution plan has the following structure:

```json
{
  "target": "0xE592427A0AEce92De3Edee1F18E0157C05861564",  // Contract to call
  "value": "0",                                            // ETH value to send
  "callData": "0x414bf389..."                              // ABI-encoded function call
}
```

### Permit Types

- **`none`**: No permit needed (user must have pre-approved)
- **`standard_approval`**: Checks existing allowance (no permit call)
- **`eip2612`**: EIP-2612 permit (requires `permitCall` with signature)
- **`eip3009`**: EIP-3009 transferWithAuthorization (requires `permitCall`)
- **`custom`**: Custom permit logic (requires `permitCall`)

### Example: Uniswap V3 Swap

See `configs/usdc-weth-univ3.json` for a complete example of a USDC → WETH swap via Uniswap V3.

---

## Settlement Contract

### How It Works

The Settlement contract (`src/Settlement.sol`) executes user-signed order intents atomically:

1. **Validation Phase**:
   - Checks relayer authorization (if restrictions enabled)
   - Validates signature using EIP-712
   - Verifies nonce hasn't been used
   - Checks order hasn't expired
   - Validates execution plan hash matches signed hash

2. **Fund Collection Phase**:
   - Applies permit/approval if needed
   - Transfers `amountIn` tokens from user to Settlement contract

3. **Execution Phase**:
   - Executes pre-interactions (setup)
   - Executes main interactions (swap)
   - Executes post-interactions (cleanup)

4. **Settlement Phase**:
   - Verifies output amount meets `minAmountOut`
   - Calculates and collects positive slippage fees
   - Transfers remaining output to receiver
   - Returns any native ETH surplus to user

### Key Features

- **Atomic Execution**: All interactions succeed or fail together
- **Slippage Protection**: Enforces `minAmountOut` requirement
- **Fee Collection**: Configurable positive slippage fees
- **Nonce Management**: Prevents replay attacks
- **Permit Support**: Multiple permit standards for gasless approvals
- **Allowlist Control**: Optional allowlist for interaction targets
- **Relayer Restrictions**: Optional trusted relayer enforcement

### Security Guarantees

- ✅ **Signature Validation**: Only the user who signed can authorize the order
- ✅ **Nonce Replay Protection**: Each nonce can only be used once
- ✅ **Execution Plan Integrity**: Interactions hash ensures plan matches what was signed
- ✅ **Slippage Protection**: `minAmountOut` ensures minimum output
- ✅ **Atomic Execution**: All-or-nothing execution prevents partial failures

See `docs/settlement-integration-guide.md` for integration details and `docs/expiry-and-nonce-mechanisms.md` for nonce/expiry details.

---

## Simulator Limitations

The simulator has several important limitations that validators and users should be aware of:

### 1. **BlockNumber Recency Not Validated** ⚠️ CRITICAL

**Issue**: The simulator uses the `blockNumber` from the execution plan without validating it's recent.

**Risk**: Solvers can provide stale block numbers (e.g., from hours/days ago) when liquidity/prices were better. Simulation passes on historical state, but on-chain execution happens at current block with potentially worse conditions.

**Mitigation**:
- Validators should reject orders with `blockNumber` older than 256 blocks (~1 hour on mainnet)
- Check: `currentBlock - executionPlan.blockNumber <= 256`
- See `docs/blocknumber-security-analysis.md` for detailed analysis

### 2. **User Balance Not Verified**

**Issue**: The simulator mints tokens to the user address, so it doesn't verify the user actually has sufficient balance on-chain.

**Risk**: Simulation passes, but on-chain execution fails if user lacks balance/allowance.

**Mitigation**: Validators should verify user balance/allowance before accepting orders:
```solidity
require(token.balanceOf(user) >= amountIn, "Insufficient balance");
require(token.allowance(user, settlement) >= amountIn, "Insufficient allowance");
```

### 3. **Nonce State Not Reflected**

**Issue**: Simulation uses a fresh fork state, so nonces always appear unused.

**Risk**: Simulation passes, but on-chain execution fails if nonce was already consumed.

**Mitigation**: Validators should check nonce status:
```solidity
require(!settlement.isNonceUsed(user, nonce), "Nonce already used");
```

### 4. **Relayer Restrictions Not Checked**

**Issue**: Simulation doesn't verify if the relayer is trusted (if restrictions enabled).

**Risk**: Simulation passes, but on-chain execution fails if relayer isn't authorized.

**Mitigation**: Validators should verify relayer authorization before accepting orders.

### 5. **Contract State May Differ**

**Issue**: Simulation uses fork state, which may differ from current on-chain state (fee parameters, allowlists, etc.).

**Risk**: Simulation passes, but on-chain execution behaves differently due to state changes.

**Mitigation**: Validators should verify contract state matches expected values.

### 6. **Expiration Not Enforced in Simulation**

**Issue**: Simulation uses fork block timestamp, not current timestamp.

**Risk**: Simulation passes, but on-chain execution fails if order expired.

**Mitigation**: Validators should check: `block.timestamp <= intent.deadline`

### 7. **Gas Estimation Not Validated**

**Issue**: Simulation measures gas but doesn't validate it matches `intent.gasEstimate`.

**Risk**: Order might pass simulation but fail on-chain due to gas limits.

**Mitigation**: Validators should ensure sufficient gas is provided.

### 8. **Settlement Address Assumption**

**Issue**: Simulation deploys Settlement at a fixed address, but on-chain it might be different.

**Risk**: Domain separator differs, causing signature validation to fail.

**Mitigation**: Validators should verify Settlement contract address matches expected address.

### Summary

**A passing simulation means the order CAN be executed on-chain IF:**
- The blockchain state matches the fork state
- The `blockNumber` is recent (within last 256 blocks)
- The relayer is authorized (if restrictions enabled)
- The user has sufficient balance/allowance
- The order hasn't expired
- The nonce hasn't been used
- The Settlement contract address matches

**Validators must perform additional pre-execution checks** before accepting orders. See `docs/simulation-security-analysis.md` for complete security analysis.

---

## Development

### Toolchain

- **Solidity 0.8.23** (via `foundry.toml`, compiled with `viaIR` and optimizer)
- **Dependencies**: `openzeppelin-contracts` v5.0.2 and `forge-std`

### Building

```bash
forge build
```

### Formatting

```bash
forge fmt
```

### Tests

Run the full test suite:

```bash
forge test
```

Test coverage includes:
- Happy-path settlement with EIP-2612 permit
- Replay attacks via nonce reuse
- Tampered execution plan hashing
- Standard approval flows (no permit)
- Slippage protection reverts
- EIP-3009 `transferWithAuthorization` flow
- Relayer restriction checks

### Deployment

For detailed deployment instructions, see [DEPLOYMENT.md](docs/DEPLOYMENT.md).

**Quick Start:**

1. Copy the environment template:
   ```bash
   cp env.template .env
   # Edit .env with your configuration
   ```

2. Deploy to Ethereum Mainnet:
   ```bash
   make deploy-ethereum
   # Or: ./scripts/deploy-ethereum.sh
   ```

3. Deploy to Base Mainnet:
   ```bash
   make deploy-base
   # Or: ./scripts/deploy-base.sh
   ```

**Manual Deployment:**

```bash
forge script script/SettlementDeploy.s.sol:SettlementDeploy \
  --rpc-url $RPC_URL \
  --broadcast
```

**Environment variables**:
- `PRIVATE_KEY` – Deployer key (hex string without the `0x` prefix)
- `SETTLEMENT_OWNER` – Optional owner address; defaults to the deployer when unset
- `MAINNET_RPC_URL` – Ethereum Mainnet RPC endpoint
- `BASE_RPC_URL` – Base Mainnet RPC endpoint

### Post-Deployment Configuration

Configure relayer restrictions, interaction allowlists, and fee parameters:

```bash
export SETTLEMENT_ADDRESS=0x...             # required
export PRIVATE_KEY=<admin-key>             # required (owner/admin key)
export UPDATE_RELAYER_RESTRICTION=true     # optional toggle
export SET_RELAYER_RESTRICTION=true        # desired value
export TRUSTED_RELAYER=0x...               # optional
export TRUSTED_RELAYER_ALLOWED=true        # default true
export UPDATE_ALLOWLIST_STATUS=true        # optional toggle
export SET_ALLOWLIST_ENABLED=true          # desired value
export INTERACTION_TARGET=0x...            # optional
export INTERACTION_TARGET_ALLOWED=true     # default true
export UPDATE_FEE_PARAMETERS=true          # optional toggle
export FEE_RECIPIENT=0x...                 # address receiving positive slippage fees
export FEE_BPS=1000                        # fee in basis points (max 10000)

forge script script/SettlementConfig.s.sol:SettlementConfig \
  --rpc-url $RPC_URL \
  --broadcast
```

### Local Development

For local testing and development:

```bash
# Start Anvil fork
anvil --fork-url https://mainnet.infura.io/v3/YOUR_KEY

# Run simulation script directly
forge script script/ExecutionPlanSimulator.s.sol --sig "simulate()" \
  --rpc-url http://localhost:8545 \
  --env-file .env
```

The Foundry book provides detailed configuration options: <https://book.getfoundry.sh/>

---

## Documentation

- **`docs/DEPLOYMENT.md`** – Complete guide for deploying contracts to Ethereum and Base
- **`docs/simulation-security-analysis.md`** – Comprehensive security analysis of the simulator
- **`docs/blocknumber-security-analysis.md`** – Analysis of blockNumber validation gap
- **`docs/expiry-and-nonce-mechanisms.md`** – Detailed explanation of deadline and nonce systems
- **`docs/signature-generation-guide.md`** – Guide for generating EIP-712 signatures on frontend
- **`docs/settlement-integration-guide.md`** – Integration guide for Settlement contract

---

## License

MIT
