#!/bin/bash
#
# Memory comparison script for Ora
# Usage: ./scripts/memory-compare.sh [baseline|compare]
#

ORA_PID=$(pgrep -x Ora | head -1)

if [ -z "$ORA_PID" ]; then
    echo "Error: Ora is not running"
    exit 1
fi

BASELINE_FILE="/tmp/ora_heap_baseline.txt"
COMPARE_FILE="/tmp/ora_heap_after.txt"

case "${1:-compare}" in
    baseline)
        echo "Taking baseline snapshot..."
        heap $ORA_PID 2>&1 > "$BASELINE_FILE"
        RSS=$(ps -p $ORA_PID -o rss= | awk '{print $1/1024}')
        echo "Baseline RSS: $RSS MB"
        echo ""
        echo "Key MLX allocations:"
        grep -E "mlx::core::array::ArrayDesc|AGXG15XFamilyBuffer|MLXArray " "$BASELINE_FILE" | head -5
        echo ""
        echo "Baseline saved. Now use Ora, then run: $0 compare"
        ;;
        
    compare)
        if [ ! -f "$BASELINE_FILE" ]; then
            echo "No baseline found. Run: $0 baseline"
            exit 1
        fi
        
        echo "Taking comparison snapshot..."
        heap $ORA_PID 2>&1 > "$COMPARE_FILE"
        
        RSS=$(ps -p $ORA_PID -o rss= | awk '{print $1/1024}')
        echo "Current RSS: $RSS MB"
        echo ""
        
        echo "=== COMPARISON ==="
        echo ""
        echo "Allocation                              | Baseline  | After     | Delta"
        echo "----------------------------------------|-----------|-----------|-------"
        
        # Extract key metrics
        for pattern in "mlx::core::array::ArrayDesc" "AGXG15XFamilyBuffer" "MLXArray "; do
            BASE=$(grep "$pattern" "$BASELINE_FILE" | head -1 | awk '{print $1}')
            AFTER=$(grep "$pattern" "$COMPARE_FILE" | head -1 | awk '{print $1}')
            BASE=${BASE:-0}
            AFTER=${AFTER:-0}
            DELTA=$((AFTER - BASE))
            NAME=$(echo "$pattern" | sed 's/ $//')
            printf "%-40s| %9s | %9s | %+d\n" "$NAME" "$BASE" "$AFTER" "$DELTA"
        done
        
        echo ""
        echo "=== TOP GROWING ALLOCATIONS ==="
        # Show what grew the most
        echo "(Comparing counts - positive = growth)"
        echo ""
        
        # Create a simple diff of counts
        awk '{print $1, $4}' "$BASELINE_FILE" | grep -E "^[0-9]" | sort -k2 > /tmp/base_counts.txt
        awk '{print $1, $4}' "$COMPARE_FILE" | grep -E "^[0-9]" | sort -k2 > /tmp/after_counts.txt
        
        # Join and calculate deltas
        join -1 2 -2 2 /tmp/base_counts.txt /tmp/after_counts.txt 2>/dev/null | \
            awk '{delta=$3-$2; if(delta>100) printf "%+8d  %s\n", delta, $1}' | \
            sort -rn | head -15
        ;;
        
    *)
        echo "Usage: $0 [baseline|compare]"
        echo ""
        echo "  baseline - Take a baseline heap snapshot"
        echo "  compare  - Compare current heap to baseline"
        ;;
esac
