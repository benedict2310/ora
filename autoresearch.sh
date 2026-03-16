#!/bin/bash
set -euo pipefail

# autoresearch.sh — Measure LLM TTFT via AgentBench benchmark
# Outputs METRIC lines consumed by the autoresearch harness.
#
# Usage: ./autoresearch.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTSUITE_DIR="$SCRIPT_DIR/agent-tools/TestSuite"
RESULTS_DIR="$TESTSUITE_DIR/results"
BINARY="$TESTSUITE_DIR/.build/arm64-apple-macosx/release/AgentBench"
MODEL="mlx-community/Qwen3-4B-Instruct-2507-4bit"

# ── 1. Build (incremental, fast after first run) ─────────────────────────────
cd "$TESTSUITE_DIR"
swift build -c release 2>&1 | grep -E "^Build|error:" || true

# Ensure metallib is in place for CLI Metal execution
METALLIB_SRC=".build/arm64-apple-macosx/debug/default.metallib"
METALLIB_DST=".build/arm64-apple-macosx/release/mlx.metallib"
if [[ -f "$METALLIB_SRC" && ! -f "$METALLIB_DST" ]]; then
    cp "$METALLIB_SRC" "$METALLIB_DST"
fi

# ── 2. Run benchmark ──────────────────────────────────────────────────────────
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="$RESULTS_DIR/autoresearch-${TIMESTAMP}.json"

"$BINARY" \
    --model "$MODEL" \
    --suite benchmarks/ \
    --output "$OUTPUT_FILE" \
    2>&1 | grep -E "^\[|^Running|^Done|^Error" || true

# ── 3. Parse results and emit METRIC lines ────────────────────────────────────
python3 - "$OUTPUT_FILE" << 'PYEOF'
import sys, json, math

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

results = data.get("results", [])
if not results:
    print("ERROR: no results in output", file=sys.stderr)
    sys.exit(1)

ttfts = [r["metrics"]["time_to_first_token_ms"]
         for r in results
         if r.get("metrics", {}).get("time_to_first_token_ms") is not None]

total = len(results)
passed = sum(1 for r in results if r.get("status") == "pass")

if not ttfts:
    print("ERROR: no TTFT data", file=sys.stderr)
    sys.exit(1)

avg_ttft   = sum(ttfts) / len(ttfts)
min_ttft   = min(ttfts)
max_ttft   = max(ttfts)
pass_rate  = passed / total if total > 0 else 0.0

print(f"METRIC avg_ttft_ms={avg_ttft:.1f}")
print(f"METRIC min_ttft_ms={min_ttft:.1f}")
print(f"METRIC max_ttft_ms={max_ttft:.1f}")
print(f"METRIC pass_rate={pass_rate:.3f}")
print(f"METRIC tests_passed={passed}")
print(f"METRIC tests_total={total}")
PYEOF
