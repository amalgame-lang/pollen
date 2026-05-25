#!/usr/bin/env bash
# ─────────────────────────────────────────────────────
#  pollen-bench-tcp — load test orchestrator (TCP variant)
#
#  Mirrors pollen-bench.sh but drives pollen-node-tcp (Phase 2.x
#  long-lived TCP + worker-per-accept) instead of the UDP node.
#  Output format stays compatible so a side-by-side comparison is
#  trivial.
#
#  Usage:
#    tools/pollen-bench-tcp.sh [-k K] [-m M] [-p PORT] [-t TOPIC] [-b BIN] [-F]
#
#  Defaults: K=4 publishers, M=100 messages each, receiver port
#  randomly chosen in 40000-49999.
# ─────────────────────────────────────────────────────

set -u

K=4
M=100
TOPIC="bench-topic-00000000-0000-4000-8000-000000000000"
NODE_BIN="${POLLEN_NODE_TCP_BIN:-}"
RECV_PORT_FIXED=""
FORCE_BIG=0

while [ $# -gt 0 ]; do
    case "$1" in
        -k) K="$2"; shift 2 ;;
        -m) M="$2"; shift 2 ;;
        -t) TOPIC="$2"; shift 2 ;;
        -b) NODE_BIN="$2"; shift 2 ;;
        -p) RECV_PORT_FIXED="$2"; shift 2 ;;
        -F) FORCE_BIG=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *)  echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ "$K" -gt 32 ] && [ "$FORCE_BIG" -eq 0 ]; then
    echo "pollen-bench-tcp: K=$K asks for $((K + K + 2)) threads + $((K + 1)) processes." >&2
    echo "                  Re-run with -F if your host can take it." >&2
    exit 2
fi

if [ -z "$NODE_BIN" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    for candidate in \
        "$SCRIPT_DIR/dev-built/pollen-node-tcp" \
        "$HOME/.cache/pollen-dev/pollen-node-tcp" \
        "$HOME/.local/share/pollen/bin/pollen-node-tcp"; do
        [ -x "$candidate" ] && NODE_BIN="$candidate" && break
    done
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
    echo "pollen-bench-tcp: no pollen-node-tcp binary found. Pass -b <path> or set" >&2
    echo "                  POLLEN_NODE_TCP_BIN." >&2
    exit 2
fi

TMP="$(mktemp -d -t pollen-bench-tcp-XXXXXX)"
trap 'pkill -P $$ 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; C='\033[0;36m'; NC='\033[0m'
else
    G=''; R=''; Y=''; C=''; NC=''
fi

echo ""
echo "════════════════════════════════════════════"
printf "  ${C}Pollen — Bench (TCP)${NC}\n"
echo "════════════════════════════════════════════"
echo "  binary:     $NODE_BIN"
echo "  publishers: $K"
echo "  messages:   $M each ($((K * M)) total)"
echo "  topic:      $TOPIC"
echo ""

RECV_LOG="$TMP/recv.log"
if [ -z "$RECV_PORT_FIXED" ]; then
    RECV_PORT=$(( (RANDOM % 10000) + 40000 ))
else
    RECV_PORT="$RECV_PORT_FIXED"
fi
"$NODE_BIN" "$RECV_PORT" > "$RECV_LOG" 2>&1 &
RECV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    grep -q "listening on TCP :$RECV_PORT" "$RECV_LOG" 2>/dev/null && break
done
if ! grep -q "listening on TCP :$RECV_PORT" "$RECV_LOG" 2>/dev/null; then
    echo "pollen-bench-tcp: receiver never logged 'listening on TCP :$RECV_PORT'" >&2
    cat "$RECV_LOG" >&2 || true
    exit 1
fi
echo "  receiver pid=$RECV_PID port=$RECV_PORT"

# ── Phase 2.4e: --burst flag bypasses the AM O(M) semicolon
# parse. Each publisher gets one ip:port:topic:ver:data:count
# spec and the C hot path handles all M iterations directly.
echo "  spawning $K publishers (--burst path)…"
PUB_PIDS=()
T0=$(date +%s%N)
for k in $(seq 1 "$K"); do
    payload="{\"p\":$k,\"i\":0}"
    burst="127.0.0.1:$RECV_PORT:$TOPIC:1:$payload:$M"
    "$NODE_BIN" 0 --burst "$burst" > "$TMP/pub-$k.log" 2>&1 &
    PUB_PIDS+=("$!")
done

WAIT_TIMEOUT_S=60
for k in $(seq 1 "$K"); do
    pid="${PUB_PIDS[$((k - 1))]}"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        complete=$(grep -c "publish complete" "$TMP/pub-$k.log" 2>/dev/null || echo 0)
        complete=${complete//[^0-9]/}; complete=${complete:-0}
        if [ "$complete" -ge "$M" ]; then
            kill "$pid" 2>/dev/null
            break
        fi
        sleep 0.2
        waited=$((waited + 1))
        if [ $waited -gt $((WAIT_TIMEOUT_S * 5)) ]; then
            echo "${Y}WARN${NC} publisher $k still alive after ${WAIT_TIMEOUT_S}s, killing"
            kill "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid" 2>/dev/null || true
done
T1=$(date +%s%N)
ELAPSED_MS=$(( (T1 - T0) / 1000000 ))

sleep 0.5

total_sent=$((K * M))
publish_complete=0
publish_failed=0
for k in $(seq 1 "$K"); do
    c=$(grep -c "publish complete" "$TMP/pub-$k.log" 2>/dev/null || true); c=${c//[^0-9]/}; c=${c:-0}
    f=$(grep -c "publish FAILED"   "$TMP/pub-$k.log" 2>/dev/null || true); f=${f//[^0-9]/}; f=${f:-0}
    publish_complete=$((publish_complete + c))
    publish_failed=$((publish_failed   + f))
done

recv_msg=$(grep -c "recv MESSAGE " "$RECV_LOG" 2>/dev/null || true); recv_msg=${recv_msg//[^0-9]/}; recv_msg=${recv_msg:-0}

kill "$RECV_PID" 2>/dev/null; wait "$RECV_PID" 2>/dev/null

LAT_FILE="$TMP/latencies.txt"
awk '
    /^publish [^ ]+ to / && / ts=[0-9]+$/ {
        mid = $2; ts = $NF; sub(/^ts=/, "", ts); pub[mid] = ts; next
    }
    /\(publish complete\) ts=[0-9]+$/ {
        mid = $6; ts = $NF; sub(/^ts=/, "", ts)
        if (mid in pub) print ts - pub[mid]
    }
' "$TMP"/pub-*.log | sort -n > "$LAT_FILE"

lat_n=$(wc -l < "$LAT_FILE" | tr -d ' ')
if [ "$lat_n" -gt 0 ]; then
    lat_summary=$(awk -v n="$lat_n" '
        function pct(p,   idx) {
            idx = int((n * p + 99) / 100)
            if (idx < 1) idx = 1
            if (idx > n) idx = n
            return a[idx]
        }
        { a[NR] = $1; sum += $1 }
        END {
            printf "min=%d p50=%d p95=%d p99=%d max=%d avg=%.1f",
                   a[1], pct(50), pct(95), pct(99), a[n], sum/n
        }
    ' "$LAT_FILE")
else
    lat_summary="(no matched publish→ACK pairs)"
fi

echo ""
echo "── results (TCP) ──"
printf "  elapsed:           %d ms (%.2f s)\n"      "$ELAPSED_MS" "$(awk "BEGIN{print $ELAPSED_MS/1000}")"
printf "  total sent:        %d msgs ($K × $M)\n"   "$total_sent"
printf "  publish complete:  %d (%.1f%%)\n"          "$publish_complete" "$(awk "BEGIN{print 100*$publish_complete/$total_sent}")"
printf "  publish FAILED:    %d\n"                   "$publish_failed"
printf "  recv MESSAGE:      %d\n"                   "$recv_msg"
if [ "$ELAPSED_MS" -gt 0 ]; then
    THROUGHPUT=$(awk "BEGIN{printf \"%.1f\", 1000.0*$total_sent/$ELAPSED_MS}")
    printf "  throughput:        %s msgs/s (publishers' wall time)\n" "$THROUGHPUT"
fi
printf "  latency ms (n=%d): %s\n" "$lat_n" "$lat_summary"
echo ""

if [ "$publish_complete" -eq "$total_sent" ]; then
    printf "${G}OK${NC} all $total_sent publishes ACK'd\n"
    exit 0
fi
printf "${Y}WARN${NC} $publish_complete/$total_sent complete\n"
exit 2
