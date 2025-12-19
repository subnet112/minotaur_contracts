#!/usr/bin/env bash
set -uo pipefail

INPUT_PAYLOAD="${1-}"
FORK_URL="${2-}"

# If first argument is empty or not provided, try to read from stdin
if [[ -z "$INPUT_PAYLOAD" ]]; then
    # Check if stdin is available (not a TTY)
    # Note: Docker requires -i flag to read from stdin: docker run -i --rm ...
    if [[ -t 0 ]]; then
        echo "error: no simulation payload provided (use stdin with -i flag or pass as argument)" >&2
        exit 1
    fi
    # Read from stdin directly to the final temp file to avoid double reading
    mkdir -p /app/tmp
    TMP_JSON="/app/tmp/input.json"
    cat > "$TMP_JSON"
    # Mark that we've already written to TMP_JSON
    INPUT_FROM_STDIN=true
else
    INPUT_FROM_STDIN=false
fi

if [[ "$INPUT_FROM_STDIN" != "true" && -z "$INPUT_PAYLOAD" ]]; then
    echo "error: no simulation payload provided" >&2
    exit 1
fi

# Use FORK_URL argument if provided, otherwise use SIM_FORK_URL env var (set via Docker -e)
if [[ -n "$FORK_URL" ]]; then
    export SIM_FORK_URL="$FORK_URL"
fi

# Write input to a file within the project directory (Foundry can read from here)
# If we read from stdin, TMP_JSON is already set and file is already written
if [[ "$INPUT_FROM_STDIN" != "true" ]]; then
    mkdir -p /app/tmp
    TMP_JSON="/app/tmp/input.json"
    trap 'rm -f "$TMP_JSON"' EXIT
    # Write payload to file
    printf '%s' "$INPUT_PAYLOAD" > "$TMP_JSON"
else
    # TMP_JSON was already set and written to when reading from stdin
    trap 'rm -f "$TMP_JSON"' EXIT
fi

# Validate JSON from the file (more reliable than validating from variable)
if ! jq . "$TMP_JSON" > /dev/null 2>&1; then
    # Try to get jq error message
    JQ_ERROR=$(jq . "$TMP_JSON" 2>&1 || true)
    echo "error: invalid JSON payload provided" >&2
    PAYLOAD_LENGTH=$(wc -c < "$TMP_JSON" | tr -d ' ')
    echo "Payload length: $PAYLOAD_LENGTH bytes" >&2
    echo "" >&2
    if [[ -n "$JQ_ERROR" ]]; then
        echo "jq error message:" >&2
        echo "$JQ_ERROR" >&2
        echo "" >&2
    fi
    echo "First 200 chars of payload:" >&2
    head -c 200 "$TMP_JSON" >&2
    echo "" >&2
    echo "" >&2
    if [[ $PAYLOAD_LENGTH -gt 0 ]]; then
        echo "Last 200 chars of payload:" >&2
        tail -c 200 "$TMP_JSON" >&2
        echo "" >&2
        echo "" >&2
    fi
    
    # Check if payload looks truncated (doesn't end with } or ])
    # Get last non-whitespace character
    LAST_NON_WS=$(tail -c 100 "$TMP_JSON" | tr -d '[:space:]' | tail -c 1)
    if [[ "$LAST_NON_WS" != "}" && "$LAST_NON_WS" != "]" ]]; then
        echo "WARNING: Payload appears to be truncated (doesn't end with } or ])" >&2
        echo "This often happens when passing large JSON files as command-line arguments." >&2
        echo "" >&2
        echo "Solution: Use stdin instead:" >&2
        echo "  cat configs/file.json | docker run -i --rm mino-simulation '' 'FORK_URL'" >&2
        echo "" >&2
    fi
    exit 1
fi

if [[ ! -f "$TMP_JSON" ]]; then
    echo "error: failed to write input file to $TMP_JSON"
    exit 1
fi

# Verify the file was written correctly
if [[ ! -s "$TMP_JSON" ]]; then
    echo "error: input file is empty: $TMP_JSON"
    exit 1
fi

export SIM_INPUT_PATH="$TMP_JSON"

# Run forge script and capture output
# Note: We filter output to only show console.log lines (starting with "Log" or containing JSON)
FORGE_OUTPUT=""
FORGE_EXIT_CODE=0
RAW_OUTPUT=$(forge script script/ExecutionPlanSimulator.s.sol --sig "simulate()" 2>&1) || FORGE_EXIT_CODE=$?

# Filter to only keep console.log output (lines starting with "Log", "===", or containing JSON objects)
# Foundry console.log output typically starts with prefixes like "Log" or appears as-is
FORGE_OUTPUT=$(printf '%s\n' "$RAW_OUTPUT" | grep -E '(^Log|^===|^\s*\{|Simulation Summary)' || true)

# If no filtered output, check if there was any output at all
if [[ -z "$FORGE_OUTPUT" && -n "$RAW_OUTPUT" ]]; then
    # If we have raw output but no filtered output, show last 10 lines for debugging
    echo "Warning: No console.log output found. Last 10 lines of forge output:" >&2
    printf '%s\n' "$RAW_OUTPUT" | tail -10 >&2
    FORGE_OUTPUT="$RAW_OUTPUT"
fi

if [[ -z "$FORGE_OUTPUT" && $FORGE_EXIT_CODE -ne 0 ]]; then
    echo "Error: forge script failed with exit code $FORGE_EXIT_CODE and produced no output"
    exit 1
fi

if [[ $FORGE_EXIT_CODE -ne 0 ]]; then
    # On error, try to extract JSON summary first
    SUMMARY_LINE=$(printf '%s\n' "$FORGE_OUTPUT" | grep -oE '\{.*\}' | tail -n 1 || true)
    if [[ -n "$SUMMARY_LINE" && "$SUMMARY_LINE" =~ ^\{ ]]; then
        # Found JSON error summary, output it
        printf '%s\n' "$SUMMARY_LINE"
        exit 1
    fi
    # No JSON found, show full output for debugging
    echo "Error: Simulation failed with exit code $FORGE_EXIT_CODE"
    echo "Full output (${#FORGE_OUTPUT} chars):"
    printf '%s\n' "$FORGE_OUTPUT"
    exit 1
fi

# Extract JSON summary - look for JSON object (may span multiple lines or be on single line)
# First try to find JSON after "=== Simulation Summary ===" marker
SUMMARY_JSON=""
if printf '%s\n' "$FORGE_OUTPUT" | grep -q "=== Simulation Summary ==="; then
    # Extract everything after the marker
    SUMMARY_JSON=$(printf '%s\n' "$FORGE_OUTPUT" | sed -n '/=== Simulation Summary ===/,$p' | grep -oE '\{.*\}' | head -n 1)
fi

# If not found, try to find any JSON object in the output
if [[ -z "$SUMMARY_JSON" ]]; then
    SUMMARY_JSON=$(printf '%s\n' "$FORGE_OUTPUT" | grep -oE '\{.*\}' | tail -n 1)
fi

# If still not found, try to find line starting with {
if [[ -z "$SUMMARY_JSON" ]]; then
    SUMMARY_JSON=$(printf '%s\n' "$FORGE_OUTPUT" | grep -E '^\s*\{' | tail -n 1)
fi

if [[ -z "$SUMMARY_JSON" ]]; then
    # If no JSON found, output everything for debugging
    echo "Warning: Could not extract JSON summary from output (${#FORGE_OUTPUT} chars)"
    echo "Looking for lines containing 'Simulation Summary' or '{':"
    printf '%s\n' "$FORGE_OUTPUT" | grep -E "(Simulation Summary|^\{|^\s*\{)" || echo "(none found)"
    echo ""
    echo "Last 20 lines of output:"
    printf '%s\n' "$FORGE_OUTPUT" | tail -n 20
    exit 1
fi

# Output the JSON result
printf '%s\n' "$SUMMARY_JSON"
