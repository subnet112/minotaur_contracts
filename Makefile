# Makefile for mino-simulation Docker operations

.PHONY: help build run start stop restart status exec shell clean

# Configuration
CONTAINER_NAME ?= mino-simulation-container
IMAGE_NAME ?= mino-simulation:latest
RPC_URL ?= https://mainnet.infura.io/v3/

help: ## Show this help message
	@echo "Mino Simulation Docker Commands"
	@echo ""
	@echo "Usage: make [target] [VARIABLE=value]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  CONTAINER_NAME  Container name (default: mino-simulation-container)"
	@echo "  IMAGE_NAME      Docker image (default: mino-simulation:latest)"
	@echo "  RPC_URL         RPC endpoint URL"
	@echo "  JSON_FILE       JSON file to simulate"
	@echo ""
	@echo "Examples:"
	@echo "  make start"
	@echo "  make exec JSON_FILE=configs/test-sim.json RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY"
	@echo "  make stop"

build: ## Build the Docker image
	docker build -t $(IMAGE_NAME) .

start: ## Start a reusable container
	@if docker ps --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "✅ Container '$(CONTAINER_NAME)' is already running"; \
	elif docker ps -a --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "🔄 Starting existing container '$(CONTAINER_NAME)'..."; \
		docker start $(CONTAINER_NAME) > /dev/null; \
		echo "✅ Container started"; \
	else \
		echo "🚀 Creating and starting container '$(CONTAINER_NAME)'..."; \
		docker run -d \
			--name $(CONTAINER_NAME) \
			--entrypoint /bin/bash \
			$(IMAGE_NAME) \
			-c "tail -f /dev/null" > /dev/null; \
		echo "✅ Container '$(CONTAINER_NAME)' is running"; \
	fi

stop: ## Stop the container
	@if docker ps --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "🛑 Stopping container '$(CONTAINER_NAME)'..."; \
		docker stop $(CONTAINER_NAME) > /dev/null; \
		echo "✅ Container stopped"; \
	else \
		echo "⚠️  Container '$(CONTAINER_NAME)' is not running"; \
	fi

restart: stop start ## Restart the container

status: ## Check container status
	@if docker ps --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "✅ Container '$(CONTAINER_NAME)' is running"; \
		docker ps --filter "name=$(CONTAINER_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"; \
	elif docker ps -a --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "⏸️  Container '$(CONTAINER_NAME)' exists but is stopped"; \
		docker ps -a --filter "name=$(CONTAINER_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"; \
	else \
		echo "❌ Container '$(CONTAINER_NAME)' does not exist"; \
		echo "   Run 'make start' to create it"; \
	fi

exec: ## Run a simulation (requires JSON_FILE)
	@if [ -z "$(JSON_FILE)" ]; then \
		echo "❌ Error: JSON_FILE is required"; \
		echo "Usage: make exec JSON_FILE=configs/test-sim.json [RPC_URL=...]"; \
		exit 1; \
	fi
	@if [ ! -f "$(JSON_FILE)" ]; then \
		echo "❌ Error: File not found: $(JSON_FILE)"; \
		exit 1; \
	fi
	@if ! docker ps --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "⚠️  Container not running. Starting it..."; \
		$(MAKE) start; \
	fi
	@echo "🔄 Running simulation: $(JSON_FILE)"
	@docker cp $(JSON_FILE) $(CONTAINER_NAME):/app/tmp/input.json > /dev/null
	@docker exec -i $(CONTAINER_NAME) /app/bin/run_simulation.sh "" "$(RPC_URL)"

run: ## Run a one-off simulation with --rm (requires JSON_FILE)
	@if [ -z "$(JSON_FILE)" ]; then \
		echo "❌ Error: JSON_FILE is required"; \
		echo "Usage: make run JSON_FILE=configs/test-sim.json [RPC_URL=...]"; \
		exit 1; \
	fi
	@cat $(JSON_FILE) | docker run -i --rm $(IMAGE_NAME) "" "$(RPC_URL)"

shell: ## Open a shell in the container
	@if ! docker ps --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "⚠️  Container not running. Starting it..."; \
		$(MAKE) start; \
	fi
	@docker exec -it $(CONTAINER_NAME) /bin/bash

clean: ## Remove the container
	@if docker ps -a --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "🗑️  Removing container '$(CONTAINER_NAME)'..."; \
		docker rm -f $(CONTAINER_NAME) > /dev/null; \
		echo "✅ Container removed"; \
	else \
		echo "⚠️  Container '$(CONTAINER_NAME)' does not exist"; \
	fi

logs: ## Show container logs
	@docker logs $(CONTAINER_NAME)

# =============================================================================
# Deployment Targets
# =============================================================================

.PHONY: deploy-ethereum deploy-base configure-ethereum configure-base

deploy-ethereum: ## Deploy Settlement contract to Ethereum Mainnet
	@if [ ! -f .env ]; then \
		echo "⚠️  Warning: .env file not found. Using environment variables."; \
	fi
	@chmod +x scripts/deploy-ethereum.sh
	@./scripts/deploy-ethereum.sh

deploy-base: ## Deploy Settlement contract to Base Mainnet
	@if [ ! -f .env ]; then \
		echo "⚠️  Warning: .env file not found. Using environment variables."; \
	fi
	@chmod +x scripts/deploy-base.sh
	@./scripts/deploy-base.sh

configure-ethereum: ## Configure Settlement contract on Ethereum Mainnet
	@if [ -z "$(SETTLEMENT_ADDRESS)" ]; then \
		echo "❌ Error: SETTLEMENT_ADDRESS is required"; \
		echo "Usage: make configure-ethereum SETTLEMENT_ADDRESS=0x..."; \
		exit 1; \
	fi
	@chmod +x scripts/configure-ethereum.sh
	@./scripts/configure-ethereum.sh

configure-ethereum-dex: ## Configure Ethereum Settlement with DEX router allowlist
	@if [ -z "$(SETTLEMENT_ADDRESS)" ]; then \
		echo "❌ Error: SETTLEMENT_ADDRESS is required"; \
		echo "Usage: make configure-ethereum-dex SETTLEMENT_ADDRESS=0x..."; \
		exit 1; \
	fi
	@chmod +x scripts/configure-ethereum-dex-routers.sh
	@./scripts/configure-ethereum-dex-routers.sh

configure-base: ## Configure Settlement contract on Base Mainnet
	@if [ -z "$(SETTLEMENT_ADDRESS)" ]; then \
		echo "❌ Error: SETTLEMENT_ADDRESS is required"; \
		echo "Usage: make configure-base SETTLEMENT_ADDRESS=0x..."; \
		exit 1; \
	fi
	@chmod +x scripts/configure-base.sh
	@./scripts/configure-base.sh

configure-base-dex: ## Configure Base Settlement with DEX router allowlist
	@if [ -z "$(SETTLEMENT_ADDRESS)" ]; then \
		echo "❌ Error: SETTLEMENT_ADDRESS is required"; \
		echo "Usage: make configure-base-dex SETTLEMENT_ADDRESS=0x..."; \
		exit 1; \
	fi
	@chmod +x scripts/configure-base-dex-routers.sh
	@./scripts/configure-base-dex-routers.sh


