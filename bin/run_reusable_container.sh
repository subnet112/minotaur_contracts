#!/usr/bin/env bash
# Helper script to manage a reusable simulation container

set -euo pipefail

CONTAINER_NAME="${MINO_CONTAINER_NAME:-mino-simulation-container}"
IMAGE_NAME="${MINO_IMAGE_NAME:-mino-simulation:latest}"

usage() {
    cat <<EOF
Usage: $0 {start|stop|restart|status|exec|shell}

Manage a reusable Docker container for running multiple simulations.

Commands:
  start    - Start a reusable container (keeps running)
  stop     - Stop the container
  restart  - Restart the container
  status   - Check if container is running
  exec     - Run a simulation in the container
             Usage: $0 exec <json-file> [rpc-url]
  shell    - Open a shell in the container

Environment Variables:
  MINO_CONTAINER_NAME  - Container name (default: mino-simulation-container)
  MINO_IMAGE_NAME      - Docker image name (default: mino-simulation:latest)
  MINO_RPC_URL         - Default RPC URL (can be overridden per exec)

Examples:
  # Start container
  $0 start

  # Run a simulation
  $0 exec configs/test-sim.json "https://mainnet.infura.io/v3/YOUR_KEY"

  # Run multiple simulations
  $0 exec configs/order1.json
  $0 exec configs/order2.json
  $0 exec configs/order3.json

  # Open shell for debugging
  $0 shell

  # Stop container
  $0 stop
EOF
    exit 1
}

start_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo "✅ Container '${CONTAINER_NAME}' is already running"
            return 0
        else
            echo "🔄 Starting existing container '${CONTAINER_NAME}'..."
            docker start "${CONTAINER_NAME}" > /dev/null
            echo "✅ Container started"
            return 0
        fi
    fi

    echo "🚀 Creating and starting container '${CONTAINER_NAME}'..."
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --entrypoint /bin/bash \
        "${IMAGE_NAME}" \
        -c "tail -f /dev/null" > /dev/null
    
    echo "✅ Container '${CONTAINER_NAME}' is running"
    echo ""
    echo "💡 Tips:"
    echo "   - Run simulations: $0 exec <json-file> [rpc-url]"
    echo "   - Open shell: $0 shell"
    echo "   - Stop container: $0 stop"
}

stop_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "⚠️  Container '${CONTAINER_NAME}' is not running"
        return 0
    fi

    echo "🛑 Stopping container '${CONTAINER_NAME}'..."
    docker stop "${CONTAINER_NAME}" > /dev/null
    echo "✅ Container stopped"
}

restart_container() {
    stop_container
    start_container
}

container_status() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✅ Container '${CONTAINER_NAME}' is running"
        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
        return 0
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "⏸️  Container '${CONTAINER_NAME}' exists but is stopped"
        docker ps -a --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
        return 1
    else
        echo "❌ Container '${CONTAINER_NAME}' does not exist"
        echo "   Run '$0 start' to create it"
        return 1
    fi
}

run_simulation() {
    local json_file="${1:-}"
    local rpc_url="${2:-${MINO_RPC_URL:-}}"

    if [[ -z "$json_file" ]]; then
        echo "❌ Error: JSON file required"
        echo "Usage: $0 exec <json-file> [rpc-url]"
        exit 1
    fi

    if [[ ! -f "$json_file" ]]; then
        echo "❌ Error: File not found: $json_file"
        exit 1
    fi

    if ! container_status > /dev/null 2>&1; then
        echo "⚠️  Container not running. Starting it..."
        start_container
    fi

    echo "🔄 Running simulation: $json_file"
    
    # Copy JSON file into container and run simulation
    docker cp "$json_file" "${CONTAINER_NAME}:/app/tmp/input.json" > /dev/null
    
    # Run the simulation script inside the container
    if [[ -n "$rpc_url" ]]; then
        docker exec -i "${CONTAINER_NAME}" /app/bin/run_simulation.sh "" "$rpc_url"
    else
        docker exec -i "${CONTAINER_NAME}" /app/bin/run_simulation.sh "" ""
    fi
}

open_shell() {
    if ! container_status > /dev/null 2>&1; then
        echo "⚠️  Container not running. Starting it..."
        start_container
    fi

    echo "🐚 Opening shell in container '${CONTAINER_NAME}'..."
    echo "💡 Tip: Run simulations manually with:"
    echo "   cat /app/tmp/input.json | /app/bin/run_simulation.sh '' 'RPC_URL'"
    echo ""
    docker exec -it "${CONTAINER_NAME}" /bin/bash
}

# Main command dispatcher
case "${1:-}" in
    start)
        start_container
        ;;
    stop)
        stop_container
        ;;
    restart)
        restart_container
        ;;
    status)
        container_status
        ;;
    exec)
        shift
        run_simulation "$@"
        ;;
    shell)
        open_shell
        ;;
    *)
        usage
        ;;
esac


