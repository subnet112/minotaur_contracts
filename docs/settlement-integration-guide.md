# Settlement Contract Integration Guide

This document explains how aggregators, validators, and miners interact with the deployed `Settlement` contract. It covers the intent lifecycle, required signatures, emitted telemetry, and operational guardrails that surround the single-order settlement flow.

> **Who should read this?**
> - **Aggregators / relayers** that assemble calldata and submit `executeOrder` transactions on behalf of users.
> - **Validators** that replay settlements, audit solver performance, and monitor security invariants.
> - **Miners / scorers** that attribute fills, positive slippage, and gas usage for incentive distribution.

## Deployment Checklist

| Network | Contract Address | Deployment Block | Notes |
| ------- | ---------------- | ---------------- | ----- |
| Mainnet | _fill-in_        | _fill-in_        | Production deployment |
| Sepolia | _fill-in_        | _fill-in_        | Staging / QA |

Populate the table above before circulating this guide. All instructions in this document assume the contract is already deployed and accessible at the addresses listed.

## Core Primitives

### Order Intent Schema

The user intent signed off-chain and consumed on-chain matches the Solidity struct below.

```64:87:src/Settlement.sol
    struct OrderIntent {
        bytes32 quoteId;
        address user;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address receiver;
        uint256 deadline;
        uint256 nonce;
        PermitData permit;
        bytes32 interactionsHash;
        uint256 callValue;
        uint256 gasEstimate;
        bytes userSignature;
    }
```

Key details:

- `quoteId` uniquely identifies the off-chain quote, enabling downstream analytics.
- `permit` encodes the allowance or authorization payload to pull `tokenIn`.
- `interactionsHash` is the canonical hash of `ExecutionPlan` (pre/main/post interactions).
- `userSignature` is the EIP-712 signature over all fields (including nested permit data).

### Entry Point & Events

Aggregators submit orders through `executeOrder(OrderIntent intent, ExecutionPlan plan)`.

The contract emits the following events for telemetry and monitoring:

```120:138:src/Settlement.sol
    event SwapSettled(
        bytes32 indexed quoteId,
        address indexed user,
        IERC20 tokenIn,
        uint256 amountIn,
        IERC20 tokenOut,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 gasEstimate,
        uint256 timestamp
    );

    event InteractionExecuted(bytes32 indexed quoteId, address target, uint256 value, bytes callData);

    event SwapFailed(bytes32 indexed quoteId, address indexed user, string reason);
```

- `SwapSettled` is the canonical success signal. `feeAmount` reflects the positive-slippage skim routed to `feeRecipient`.
- `InteractionExecuted` is emitted for every low-level call inside the execution plan (optional for validators to consume).
- `SwapFailed` surfaces the decoded revert reason whenever the settlement reverts.

## Aggregator / Relayer Workflow

### 1. Collect Solver Output

1. Receive an `ExecutionPlan` proposal from the solver (arrays of `Interaction` structs).
2. Verify the solver-supplied `interactionsHash` by recomputing it locally via the ABI-encoded canonical hashing scheme:
   - `hashExecutionPlan` concatenates `abi.encodePacked(target, value, keccak256(callData))` for every interaction in order (pre → main → post) and hashes the result.
3. Reject proposals that include non-allowlisted targets if `allowlistEnabled` is set (see “Operational Guardrails”).

### 2. Construct the Order Intent

Populate each field before presenting it to the user:

1. `quoteId`: value supplied by the solver or market coordinator.
2. `user`, `receiver`, `tokenIn`, `tokenOut`: pulled from the user session.
3. `amountIn`, `minAmountOut`: enforce the bid/ask and slippage protection agreed off-chain.
4. `deadline`: strict UNIX timestamp after which intents must not settle.
5. `nonce`: assign a unique per-user nonce. You may prefetch used nonces by calling `isNonceUsed`.
6. `gasEstimate`: optional hint used downstream for scoring.
7. `permit`: see “Permit Handling Cheatsheet”.
8. `callValue`: sum of `interaction.value` across the plan.
9. `interactionsHash`: recomputed from the exact plan.

### 3. Obtain the User Signature

1. Build the EIP-712 typed data payload using domain `name = "OIF Settlement"`, `version = "1"`, `chainId` = network id, `verifyingContract` = settlement address.
2. Serialize nested permit data exactly as the contract expects:
   - `permitType` (uint8 enum index)
   - `permitCall` (raw ABI bytes)
   - `amount`
   - `deadline`
3. Present the signing request to the user wallet. Store the returned signature bytes (r || s || v) in `intent.userSignature`.

### 4. Permit Handling Cheatsheet

| PermitType | Value | Expected `permitCall` payload | Notes |
| ---------- | ----- | ----------------------------- | ----- |
| `None` | 0 | `bytes(0)` | Requires pre-existing allowance ≥ `amountIn` |
| `EIP2612` | 1 | `abi.encode(owner, spender, value, deadline, v, r, s)` | `owner` must equal `intent.user`; `spender` must equal settlement address |
| `EIP3009` | 2 | `abi.encode(from, to, value, validAfter, validBefore, nonce, v, r, s)` | The contract internally calls `transferWithAuthorization`; `nonce` must be unique |
| `StandardApproval` | 3 | empty bytes | Signals that a traditional allowance is already set |
| `Custom` | 4 | Arbitrary ABI calldata | Called via `address(tokenIn).call(permitCall)` before collection |

Best practices:

- Always pre-validate deadlines (`deadline > now`) before collecting the signature.
- For `EIP2612` and `Custom`, the aggregator should verify the token’s current allowance/authorization after signature capture to catch token-specific quirks.

### 5. Submit the Transaction

1. Encode `executeOrder(intent, plan)` using the ABI generated from the deployed contract.
2. Set `msg.value` equal to `intent.callValue` (zero for ERC20-only flows).
3. Optionally run `eth_call` against the RPC with the assembled calldata before broadcasting.
4. Send the transaction from a relayer that is trusted when `relayerRestrictionEnabled` is true. You can query the allowlist via `trustedRelayers(relayerAddress)`.

#### Failure Handling

- If the transaction reverts, the on-chain revert data is bubbled up. `SwapFailed` will include the decoded reason string (`EMPTY_REVERT_DATA` if none).
- On failure, the user nonce remains consumed. Resubmissions must use a fresh nonce and signature.

### 6. Quote Simulation Helper

To keep solvers honest before collecting a user signature, the repository ships a Foundry script that replays an execution plan on a fork:

```bash
SIM_FORK_URL=https://rpc... \
SIM_INPUT_PATH=configs/sim-run.json \
forge script script/ExecutionPlanSimulator.s.sol --sig "simulate()"
```

**Inputs** (`SIM_INPUT_PATH` JSON):

```json
{
  "intent": {
    "chainId": "1",
    "quoteId": "0x1234...",
    "user": "0x0000000000000000000000000000000000000000",    // optional – defaults to script user
    "tokenIn": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606e48",   // USDC
    "tokenOut": "0xC02aaA39b223FE8D0A0E5C4F27eAD9083C756Cc2",  // WETH
    "amountIn": "100000000",                                  // 100 USDC (6 decimals)
    "minAmountOut": "50000000000000000",                      // 0.05 WETH
    "receiver": "0x0000000000000000000000000000000000000000", // defaults to user
    "deadline": 1893456000,
    "nonce": 1,
    "callValue": "0",
    "gasEstimate": 250000,
    "permit": {
      "type": "StandardApproval",
      "amount": "100000000"
    }
  },
  "executionPlan": {
    "blockNumber": "23746829",
    "preInteractions": [
      {
        "target": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606e48",
        "value": "0",
        "callData": "0x095ea7b3000000000000000000000000..."
      }
    ],
    "interactions": [
      {
        "target": "0x1111111254fb6c44bac0bed2854e76f90643097d", // 1inch router
        "value": "0",
        "callData": "0x12aa3caf0000..."
      }
    ],
    "postInteractions": []
  },
  "funding": {
    "tokenInHolder": "0xf977814e90da44bfa03b6295a0616a897441acec" // rich USDC account to impersonate
  }
}
```

The script:

- Spins up a fork specified by `SIM_FORK_URL`.
- If `executionPlan.blockNumber` is provided, the fork is pinned to that block. Otherwise it uses the latest head.
- Deploys a fresh `Settlement` contract owned by the script.
- Funds a deterministic “sim user” by impersonating `funding.tokenInHolder` (required for real mainnet tokens).
- Reconstructs the intent, computes `interactionsHash`, signs with the scripted user key, and executes `executeOrder`.
- Logs the aggregate `amountOut`, user/receiver deltas, and highlights whether the plan meets `minAmountOut`.

**Limitations & Notes**

- `tokenInHolder` must be an address with sufficient balance on the fork; the script simply impersonates it and transfers `amountIn` to the simulated user.
- If the solver relies on `EIP2612` permits, omit `permit.callData` and the script will craft a valid permit targeting the deployed settlement. For `EIP3009` or custom permits you must supply the full `callData` blob.
- The tool does not provision liquidity for downstream protocols. You are responsible for forking at the appropriate block so pools contain the expected reserves.
- Positive-slippage fees are determined by the deployed settlement configuration. Adjust script-owner settings or the JSON to mirror production parameters before interpreting results.
- `SIM_FORK_URL` takes precedence when present. If it is unset, the script will look for `INFURA_API_KEY` in your `.env` and fall back to `https://mainnet.infura.io/v3/$INFURA_API_KEY` automatically.
- Optional `SIM_QUOTER` overrides the default Uniswap Quoter V2 address if you need to query another deployment for previewed swap outputs.

## Validator Playbook

### Event Ingestion

1. Subscribe to `SwapSettled`, `SwapFailed`, and `InteractionExecuted` (optional) via websockets or log polling.
2. Maintain an indexed store keyed by `(quoteId, tx hash)` with the decoded event payloads.
3. Track user nonce usage by reading `NonceInvalidated` and inspecting `SwapSettled` success events.

### Deterministic Replays

1. Upon receiving `SwapSettled`, reconstruct the calldata from the emitted data (`quoteId`, `user`, `amountOut`, etc.) and the cached solver plan.
2. Execute `eth_call` against an archival node with the original calldata at the settlement block to verify deterministic replay.
3. Confirm:
   - Token transfers match the observed `amountIn`/`amountOut` deltas.
   - `feeAmount` equals `(amountOut - minAmountOut) * positiveSlippageFeeBps / 10_000` when fees are enabled.
   - `gasEstimate` lines up with actual gas used to detect solver misreporting.

### Fraud & Safety Monitoring

- Alert on replays that deviate from on-chain results or when `InteractionCallFailed` errors surface.
- Watch for repeated `PermitCallFailed` or `InvalidInteractionTarget` errors indicating malicious plans or stale allowlists.
- Keep an eye on native balances: `sweepNative` and `sweepToken` events signal treasury maintenance operations that should occur infrequently.

## Scoring Guidance

1. Consume `SwapSettled` and correlate `quoteId` with off-chain solver or miner metadata to accrue performance metrics.
2. Use `gasEstimate` in conjunction with actual gas usage (`tx.gasUsed`) to measure solver accuracy and penalize outliers.
3. Calculate positive slippage share:
   - `userPayout = amountOut - feeAmount`
   - `feeAmount` should match protocol configuration retrieved via `positiveSlippageFeeBps`.
4. Review `SwapFailed` to flag relayers or solvers associated with repeated failures or invalid plans.

## Operational Guardrails

### Relayer Restrictions

- `relayerRestrictionEnabled` gatekeeps `executeOrder`. Only addresses set via `setTrustedRelayer` may relay when true.
- Aggregators should monitor `RelayerRestrictionUpdated` and `TrustedRelayerUpdated` to ensure their relayer keys remain authorized.

### Interaction Allowlist

- When `allowlistEnabled` is true, each `Interaction.target` must be pre-approved via `setInteractionTarget(target, allowed)`.
- Validators should cross-check plans against the on-chain allowlist state to detect unauthorized targets.

### Fee Configuration

- `feeRecipient` and `positiveSlippageFeeBps` can be updated by the owner. Plan scoring must reference live values (`FeeParametersUpdated`).

## Appendix

### EIP-712 Domain

- **Name:** `OIF Settlement`
- **Version:** `1`
- **Chain ID:** depend on deployment network
- **Verifying Contract:** settlement contract address from the Deployment Checklist

Type Hash constants defined on-chain:

```94:101:src/Settlement.sol
    bytes32 private constant PERMIT_DATA_TYPEHASH =
        keccak256("PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)");

    bytes32 private constant ORDER_INTENT_TYPEHASH = keccak256(
        "OrderIntent(bytes32 quoteId,address user,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,address receiver,uint256 deadline,uint256 nonce,bytes32 interactionsHash,uint256 callValue,uint256 gasEstimate,PermitData permit)PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)"
    );
```

Refer to these constants when configuring client-side signing libraries to prevent mismatched digests.

### Recommended Pre-Flight Checks

| Check | Service | Description |
| ----- | ------- | ----------- |
| `isNonceUsed(user, nonce)` | Aggregator | Reject nonces already consumed |
| `hashExecutionPlan(plan)` | Aggregator / Validator | Ensure plan aligns with `interactionsHash` |
| `eth_call` dry-run | Aggregator / Validator | Catch obvious reverts before broadcast |
| `allowlistEnabled()` + `interactionTargetAllowed(target)` | Aggregator | Prevent unauthorized interactions |
| `trustedRelayers(relayer)` | Aggregator | Confirm relayer is permitted when restrictions are active |

### Useful References

- Source contract: `src/Settlement.sol`
- Test suite examples: `test/Settlement.t.sol`
- Foundry config: `foundry.toml`

Keep this guide versioned alongside the repository so that future contract upgrades can update integration instructions in lockstep.

