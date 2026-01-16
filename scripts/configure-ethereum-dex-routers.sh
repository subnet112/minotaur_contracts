#!/bin/bash
# Configure Settlement contract with DEX routers on Ethereum Mainnet
# Usage: ./scripts/configure-ethereum-dex-routers.sh
#
# This script adds common DEX routers to the Settlement allowlist:
# - Uniswap V2, V3, Universal Router
# - SushiSwap
# - 1inch V5, V6
# - Curve
# - Balancer
# - 0x Protocol
# - Paraswap
# - CoW Protocol
# - Kyber

set -e

echo "🔧 Configuring Settlement with Ethereum Mainnet DEX Routers..."
echo ""

# Check required environment variables
if [ -z "$SETTLEMENT_ADDRESS" ]; then
    echo "❌ Error: SETTLEMENT_ADDRESS environment variable is not set"
    echo "   Please set it:"
    echo "   export SETTLEMENT_ADDRESS=0x..."
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Error: PRIVATE_KEY environment variable is not set"
    exit 1
fi

if [ -z "$MAINNET_RPC_URL" ]; then
    echo "❌ Error: MAINNET_RPC_URL environment variable is not set"
    exit 1
fi

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

echo "📝 Configuration Details:"
echo "   Settlement: $SETTLEMENT_ADDRESS"
echo "   Network: Ethereum Mainnet"
echo ""
echo "📦 DEX Routers to be added:"
echo "   • Uniswap V3 SwapRouter"
echo "   • Uniswap V3 SwapRouter02"
echo "   • Uniswap Universal Router"
echo "   • Uniswap V2 Router"
echo "   • SushiSwap Router"
echo "   • 1inch Aggregation Router V5"
echo "   • 1inch Aggregation Router V6"
echo "   • Curve Router"
echo "   • Curve Router NG"
echo "   • Balancer Vault"
echo "   • 0x Exchange Proxy"
echo "   • Paraswap Augustus V5"
echo "   • Paraswap Augustus V6"
echo "   • CoW Protocol Settlement"
echo "   • Kyber Meta Aggregation Router V2"
echo ""

# Run the configuration script
forge script script/EthereumMainnetConfig.s.sol:EthereumMainnetConfig \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    -vvvv

echo ""
echo "✅ DEX router configuration complete!"
echo ""
echo "⚠️  Important: The allowlist is now ENABLED."
echo "   Only the configured DEX routers can be called during settlement."
echo ""

