#!/bin/bash
# Configure Settlement contract on Base Mainnet
# Usage: ./scripts/configure-base.sh

set -e

echo "⚙️  Configuring Settlement contract on Base Mainnet..."

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

echo "📝 Configuring Settlement contract..."
echo "   Contract: $SETTLEMENT_ADDRESS"
echo "   RPC URL: $BASE_RPC_URL"

forge script script/SettlementConfig.s.sol:SettlementConfig \
    --rpc-url $BASE_RPC_URL \
    --broadcast \
    -vvvv

echo ""
echo "✅ Configuration complete!"


