#!/bin/bash
# Deploy Settlement contract to Ethereum Mainnet
# Usage: ./scripts/deploy-ethereum.sh

set -e

echo "🚀 Deploying Settlement contract to Ethereum Mainnet..."

# Check required environment variables
if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Error: PRIVATE_KEY environment variable is not set"
    echo "   Please set it in your .env file or export it:"
    echo "   export PRIVATE_KEY=your_private_key_without_0x"
    exit 1
fi

if [ -z "$MAINNET_RPC_URL" ]; then
    echo "❌ Error: MAINNET_RPC_URL environment variable is not set"
    echo "   Please set it in your .env file or export it:"
    echo "   export MAINNET_RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY"
    exit 1
fi

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Deploy the contract
echo "📝 Deploying Settlement contract..."
echo "   RPC URL: $MAINNET_RPC_URL"
if command -v cast &> /dev/null; then
    echo "   Deployer: $(cast wallet address $PRIVATE_KEY)"
fi

SETTLEMENT_OWNER=${SETTLEMENT_OWNER:-""}

if [ -n "$SETTLEMENT_OWNER" ]; then
    echo "   Owner: $SETTLEMENT_OWNER"
    forge script script/SettlementDeploy.s.sol:SettlementDeploy \
        --rpc-url $MAINNET_RPC_URL \
        --broadcast \
        --verify \
        --etherscan-api-key ${ETHERSCAN_API_KEY:-""} \
        -vvvv
else
    echo "   Owner: (will be set to deployer)"
    forge script script/SettlementDeploy.s.sol:SettlementDeploy \
        --rpc-url $MAINNET_RPC_URL \
        --broadcast \
        --verify \
        --etherscan-api-key ${ETHERSCAN_API_KEY:-""} \
        -vvvv
fi

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📋 Next steps:"
echo "   1. Save the deployed contract address"
echo "   2. Run configuration script if needed:"
echo "      SETTLEMENT_ADDRESS=<address> ./scripts/configure-ethereum.sh"
echo "   3. Verify the contract on Etherscan"

