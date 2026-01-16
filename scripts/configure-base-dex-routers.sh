#!/bin/bash
# Configure Settlement contract with DEX routers on Base Mainnet
# Usage: ./scripts/configure-base-dex-routers.sh
#
# This script adds common DEX routers to the Settlement allowlist:
# - Uniswap V3, Universal Router
# - Aerodrome (Base native DEX)
# - SushiSwap V3
# - BaseSwap
# - Balancer
# - 1inch V5, V6
# - 0x Protocol
# - Paraswap
# - Odos
# - KyberSwap
# - WooFi

set -e

echo "🔧 Configuring Settlement with Base Mainnet DEX Routers..."
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

if [ -z "$BASE_RPC_URL" ]; then
    echo "❌ Error: BASE_RPC_URL environment variable is not set"
    exit 1
fi

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

echo "📝 Configuration Details:"
echo "   Settlement: $SETTLEMENT_ADDRESS"
echo "   Network: Base Mainnet"
echo ""
echo "📦 DEX Routers to be added:"
echo "   • Uniswap V3 SwapRouter"
echo "   • Uniswap Universal Router"
echo "   • Aerodrome Router (Base native)"
echo "   • Aerodrome Router V2"
echo "   • SushiSwap V3 Router"
echo "   • BaseSwap Router"
echo "   • Balancer Vault"
echo "   • 1inch Aggregation Router V5"
echo "   • 1inch Aggregation Router V6"
echo "   • 0x Exchange Proxy"
echo "   • Paraswap Augustus V6"
echo "   • Odos Router V2"
echo "   • Kyber Meta Aggregation Router V2"
echo "   • WooFi Router"
echo ""

# Run the configuration script
forge script script/BaseMainnetConfig.s.sol:BaseMainnetConfig \
    --rpc-url $BASE_RPC_URL \
    --broadcast \
    -vvvv

echo ""
echo "✅ DEX router configuration complete!"
echo ""
echo "⚠️  Important: The allowlist is now ENABLED."
echo "   Only the configured DEX routers can be called during settlement."
echo ""

