# syntax=docker/dockerfile:1
FROM ghcr.io/foundry-rs/foundry:latest

WORKDIR /app

# Switch to root for all setup
USER root

# Install jq for JSON validation
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*

# Copy dependency files first for better caching
COPY foundry.toml /app/

# Copy dependencies
COPY lib /app/lib

# Copy source files
COPY src /app/src
COPY script /app/script

# Create output directory and set permissions
RUN mkdir -p /app/out /app/cache /app/tmp && \
    chown -R foundry:foundry /app

# Switch to foundry user for building
USER foundry

# Pre-compile contracts during build
# This ensures the compiled artifacts are baked into the image
RUN forge build --force && \
    echo "Build complete. Checking artifacts..." && \
    ls -la /app/out/ && \
    ls -la /app/out/Settlement.sol/ || echo "Warning: Settlement artifacts not found"

# Copy entrypoint script (switch to root temporarily)
USER root
COPY --chmod=755 bin/run_simulation.sh /app/bin/run_simulation.sh
RUN chown foundry:foundry /app/bin/run_simulation.sh

# Switch back to foundry user
USER foundry

# Default fork URL (empty - must be provided at runtime)
ENV SIM_FORK_URL=""

ENTRYPOINT ["/app/bin/run_simulation.sh"]
