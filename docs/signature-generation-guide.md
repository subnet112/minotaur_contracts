# Frontend Signature Generation Guide

This guide explains how to generate a valid EIP-712 signature for the Settlement contract's `OrderIntent` on your frontend.

## Overview

The signature is an EIP-712 typed data signature that authorizes the Settlement contract to execute a swap on behalf of the user. The signature must be generated using the exact same structure and domain separator that the contract expects.

## EIP-712 Domain

The Settlement contract uses the following EIP-712 domain:
- **name**: `"OIF Settlement"`
- **version**: `"1"`
- **chainId**: The chain ID where the Settlement contract is deployed (e.g., `1` for mainnet)
- **verifyingContract**: The Settlement contract address (e.g., `0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3`)

## Type Definitions

### OrderIntent Type
```
OrderIntent(
  bytes32 quoteId,
  address user,
  address tokenIn,
  address tokenOut,
  uint256 amountIn,
  uint256 minAmountOut,
  address receiver,
  uint256 deadline,
  uint256 nonce,
  bytes32 interactionsHash,
  uint256 callValue,
  uint256 gasEstimate,
  PermitData permit
)
```

### PermitData Type
```
PermitData(
  uint8 permitType,
  bytes permitCall,
  uint256 amount,
  uint256 deadline
)
```

**PermitType enum values:**
- `0` = None
- `1` = StandardApproval
- `2` = EIP2612
- `3` = EIP3009
- `4` = Custom

## Implementation Examples

### Using ethers.js v6 (Recommended)

**Note**: The manual hashing approach below is complex and error-prone. We recommend using the simplified approach at the bottom of this section, which uses ethers.js's built-in `signTypedData` function.

```typescript
import { ethers } from 'ethers';

interface OrderIntent {
  quoteId: string; // Will be hashed to bytes32
  user: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: string; // BigNumber as string
  minAmountOut: string;
  receiver: string;
  deadline: number;
  nonce: string; // Can be hex string or number
  interactionsHash: string;
  callValue: string;
  gasEstimate: string;
  permit: {
    permitType: number; // 0-4
    permitCall: string; // Hex string, "0x" for empty
    amount: string;
    deadline: number;
  };
}

async function generateSignature(
  signer: ethers.Signer,
  orderIntent: OrderIntent,
  settlementAddress: string,
  chainId: number
): Promise<string> {
  // Hash the quoteId string to bytes32
  const quoteIdBytes32 = ethers.keccak256(ethers.toUtf8Bytes(orderIntent.quoteId));
  
  // Prepare permitCall - use "0x" if empty
  const permitCall = orderIntent.permit.permitCall === "0x" || !orderIntent.permit.permitCall
    ? "0x"
    : orderIntent.permit.permitCall;
  
  const domain = {
    name: "OIF Settlement",
    version: "1",
    chainId: chainId,
    verifyingContract: settlementAddress
  };
  
  const types = {
    OrderIntent: [
      { name: "quoteId", type: "bytes32" },
      { name: "user", type: "address" },
      { name: "tokenIn", type: "address" },
      { name: "tokenOut", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "interactionsHash", type: "bytes32" },
      { name: "callValue", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
      { name: "permit", type: "PermitData" }
    ],
    PermitData: [
      { name: "permitType", type: "uint8" },
      { name: "permitCall", type: "bytes" },
      { name: "amount", type: "uint256" },
      { name: "deadline", type: "uint256" }
    ]
  };
  
  const value = {
    quoteId: quoteIdBytes32,
    user: orderIntent.user,
    tokenIn: orderIntent.tokenIn,
    tokenOut: orderIntent.tokenOut,
    amountIn: orderIntent.amountIn.toString(),
    minAmountOut: orderIntent.minAmountOut.toString(),
    receiver: orderIntent.receiver,
    deadline: orderIntent.deadline.toString(),
    nonce: orderIntent.nonce.toString(),
    interactionsHash: orderIntent.interactionsHash,
    callValue: orderIntent.callValue.toString(),
    gasEstimate: orderIntent.gasEstimate.toString(),
    permit: {
      permitType: orderIntent.permit.permitType,
      permitCall: permitCall,
      amount: orderIntent.permit.amount.toString(),
      deadline: orderIntent.permit.deadline.toString()
    }
  };
  
  // Sign the typed data - ethers.js handles all the EIP-712 encoding automatically
  const signature = await signer.signTypedData(domain, types, value);
  return signature;
}
```

### Using viem

```typescript
import { keccak256, stringToBytes } from 'viem';
import { signTypedData } from 'viem/accounts';

interface OrderIntent {
  quoteId: string;
  user: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  minAmountOut: bigint;
  receiver: `0x${string}`;
  deadline: bigint;
  nonce: bigint;
  interactionsHash: `0x${string}`;
  callValue: bigint;
  gasEstimate: bigint;
  permit: {
    permitType: number;
    permitCall: `0x${string}`;
    amount: bigint;
    deadline: bigint;
  };
}

async function generateSignature(
  account: any, // viem account object
  orderIntent: OrderIntent,
  settlementAddress: `0x${string}`,
  chainId: number
): Promise<`0x${string}`> {
  // Hash the quoteId string to bytes32
  const quoteIdBytes32 = keccak256(stringToBytes(orderIntent.quoteId));
  
  // Prepare permitCall - use "0x" if empty
  const permitCall = orderIntent.permit.permitCall === "0x" || !orderIntent.permit.permitCall
    ? "0x" as `0x${string}`
    : orderIntent.permit.permitCall;
  
  const domain = {
    name: "OIF Settlement",
    version: "1",
    chainId: chainId,
    verifyingContract: settlementAddress
  };
  
  const types = {
    OrderIntent: [
      { name: "quoteId", type: "bytes32" },
      { name: "user", type: "address" },
      { name: "tokenIn", type: "address" },
      { name: "tokenOut", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "interactionsHash", type: "bytes32" },
      { name: "callValue", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
      { name: "permit", type: "PermitData" }
    ],
    PermitData: [
      { name: "permitType", type: "uint8" },
      { name: "permitCall", type: "bytes" },
      { name: "amount", type: "uint256" },
      { name: "deadline", type: "uint256" }
    ]
  };
  
  const value = {
    quoteId: quoteIdBytes32,
    user: orderIntent.user,
    tokenIn: orderIntent.tokenIn,
    tokenOut: orderIntent.tokenOut,
    amountIn: orderIntent.amountIn,
    minAmountOut: orderIntent.minAmountOut,
    receiver: orderIntent.receiver,
    deadline: orderIntent.deadline,
    nonce: orderIntent.nonce,
    interactionsHash: orderIntent.interactionsHash,
    callValue: orderIntent.callValue,
    gasEstimate: orderIntent.gasEstimate,
    permit: {
      permitType: orderIntent.permit.permitType,
      permitCall: permitCall,
      amount: orderIntent.permit.amount,
      deadline: orderIntent.permit.deadline
    }
  };
  
  // Sign the typed data - viem handles all the EIP-712 encoding automatically
  const signature = await signTypedData({
    account,
    domain,
    types,
    primaryType: "OrderIntent",
    message: value
  });
  
  return signature;
}
```

## Important Notes

1. **quoteId**: Must be hashed from the string to bytes32 using `keccak256(utf8Bytes(quoteId))` before passing to `signTypedData`
2. **interactionsHash**: Must match the hash computed from the execution plan. You can compute it using the Settlement contract's `hashExecutionPlan` function or replicate the hashing logic (see below).
3. **Domain Separator**: Must match exactly:
   - `name`: `"OIF Settlement"` (case-sensitive)
   - `version`: `"1"`
   - `chainId`: Must match the chain where the contract is deployed (e.g., `1` for mainnet)
   - `verifyingContract`: Must be the exact Settlement contract address (e.g., `0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3`)
4. **PermitData**: 
   - If `permitType` is `0` (None), the `permitCall` should be `"0x"` (empty bytes). The EIP-712 library will handle hashing it correctly.
   - `permitCall` should be `"0x"` if empty, otherwise the full hex string
   - The contract automatically handles `permitType = 0` by returning `bytes32(0)` for the permit hash
5. **Nonce**: Can be provided as a hex string (e.g., `"0x339df6ce3bcdc67d7d0c8878c1f5f86a"`) or as a number/bigint. The contract expects a `uint256`. When using `signTypedData`, convert to string or bigint as appropriate.
6. **Address Format**: All addresses must be valid Ethereum addresses (20 bytes, hex-encoded with `0x` prefix). The contract extracts addresses from InteropAddress format if needed, but for signatures, use the plain 20-byte address.

## Computing interactionsHash

The `interactionsHash` is computed by hashing the execution plan. You can either:

1. **Call the contract**: Use the Settlement contract's `hashExecutionPlan` function
2. **Replicate the logic**: Hash the interactions as follows:
   ```typescript
   function hashExecutionPlan(plan: {
     preInteractions: Array<{target: string, value: string, callData: string}>;
     interactions: Array<{target: string, value: string, callData: string}>;
     postInteractions: Array<{target: string, value: string, callData: string}>;
   }): string {
     let encoded = "0x";
     
     // Encode preInteractions
     for (const interaction of plan.preInteractions) {
       const target = interaction.target.slice(2).padStart(64, '0');
       const value = BigInt(interaction.value).toString(16).padStart(64, '0');
       const callDataHash = keccak256(interaction.callData);
       encoded += target + value + callDataHash.slice(2);
     }
     
     // Encode interactions
     for (const interaction of plan.interactions) {
       const target = interaction.target.slice(2).padStart(64, '0');
       const value = BigInt(interaction.value).toString(16).padStart(64, '0');
       const callDataHash = keccak256(interaction.callData);
       encoded += target + value + callDataHash.slice(2);
     }
     
     // Encode postInteractions
     for (const interaction of plan.postInteractions) {
       const target = interaction.target.slice(2).padStart(64, '0');
       const value = BigInt(interaction.value).toString(16).padStart(64, '0');
       const callDataHash = keccak256(interaction.callData);
       encoded += target + value + callDataHash.slice(2);
     }
     
     return keccak256(encoded);
   }
   ```

## Example Usage

```typescript
// Example order intent data
const orderIntent = {
  quoteId: "quote-paper-11bb3d4f-0a60-4cf6-9788-5ccab44520c9",
  user: "0x9996E4253e938D81A360b353C4FCefa67E7120Bc",
  tokenIn: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  tokenOut: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  amountIn: "1000000000",
  minAmountOut: "304664226045999527",
  receiver: "0x9996E4253e938D81A360b353C4FCefa67E7120Bc",
  deadline: 4102444800,
  nonce: "1",
  interactionsHash: "0x98329bfdd7093f0138e29930e064b0cc7e08d4dcf267334a5fef811c34560914",
  callValue: "0",
  gasEstimate: "450000",
  permit: {
    permitType: 1, // StandardApproval
    permitCall: "0x",
    amount: "1000000000",
    deadline: 4102444800
  }
};

const settlementAddress = "0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3";
const chainId = 1; // Mainnet

// Get signer from wallet
const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();

// Generate signature
const signature = await generateSignature(signer, orderIntent, settlementAddress, chainId);
console.log("Signature:", signature);
```

## Verification

To verify your signature is correct, you can:

1. **Use the simulator**: Run the simulation with your signature in the JSON
2. **Call the contract**: Use the Settlement contract's `domainSeparator()` to verify the domain matches
3. **Recover the signer**: Use `ECDSA.recover(digest, signature)` and verify it matches the user address

## Common Issues

1. **Domain separator mismatch**: Ensure the Settlement contract address and chain ID are correct
2. **quoteId not hashed**: Remember to hash the quoteId string to bytes32
3. **interactionsHash mismatch**: Ensure the hash matches the execution plan exactly
4. **PermitData hash incorrect**: For `permitType = 0`, use `bytes32(0)`, otherwise hash the permitCall bytes
5. **Type mismatches**: Ensure all uint256 values are provided as strings or bigints, not numbers (to avoid precision loss)

