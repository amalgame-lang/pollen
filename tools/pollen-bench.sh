#!/usr/bin/env bash
# ─────────────────────────────────────────────────────
#  pollen-bench — load test orchestrator
#
#  Spawns 1 receiver node + K concurrent publisher nodes (each
#  firing M MESSAGE envelopes at startup via --publish). Once
#  every publisher has finished its retry budget (5 × 1 s), parses
#  the logs to extract:
#    - total messages sent (K × M)
#    - publish complete count (= ACKs matched by publishers)
#    - publish retry count (= ack-timeout resends)
#    - publish TIMEOUT count (= exhausted retries)
#    - receiver MESSAGE recv count (first-sight + duplicates)
#    - dedup hit count (duplicates the receiver swallowed)
#    - throughput msg/s (publishers' completion wall time)
#
#  Usage:
#    tools/pollen-bench.sh [-k K] [-m M] [-p PORT] [-t TOPIC]
#
#  Defaults: K=4 publishers, M=100 messages each, receiver port
#  picked by the kernel (ephemeral, printed at startup), topic UUID
#  fixed ('bench-topic-…').
#
#  Bench env vars:
#    POLLEN_NODE_BIN  override node binary path
#                     (default: ./tools/dev-built or installed share)
# ─────────────────────────────────────────────────────

set -u

K=4
M=100
TOPIC="bench-topic-00000000-0000-4000-8000-000000000000"
NODE_BIN="${POLLEN_NODE_BIN:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        -k) K="$2"; shift 2 ;;
        -m) M="$2"; shift 2 ;;
        -t) TOPIC="$2"; shift 2 ;;
        -b) NODE_BIN="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *)
            echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── locate pollen-node binary ────────────────────────
if [ -z "$NODE_BIN" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    for candidate in \
        "$SCRIPT_DIR/dev-built/pollen-node" \
        "$HOME/.local/share/pollen/bin/pollen-node"; do
        [ -x "$candidate" ] && NODE_BIN="$candidate" && break
    done
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
    echo "pollen-bench: no pollen-node binary. Build via install.sh or pass -b <path>." >&2
    exit 2
fi

# ── tmpdir + colour ──────────────────────────────────
TMP="$(mktemp -d -t pollen-bench-XXXXXX)"
trap 'pkill -P $$ 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; C='\033[0;36m'; NC='\033[0m'
else
    G=''; R=''; Y=''; C=''; NC=''
fi

echo ""
echo "════════════════════════════════════════════"
printf "  ${C}Pollen — Bench${NC}\n"
echo "════════════════════════════════════════════"
echo "  binary:     $NODE_BIN"
echo "  publishers: $K"
echo "  messages:   $M each ($((K * M)) total)"
echo "  topic:      $TOPIC"
echo ""

# ── 1. spawn receiver ────────────────────────────────
RECV_LOG="$TMP/recv.log"
"$NODE_BIN" 0 > "$RECV_LOG" 2>&1 &
RECV_PID=$!
# wait for the listening line
RECV_PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    RECV_PORT=$(grep -oE "UDP :[0-9]+" "$RECV_LOG" 2>/dev/null | head -1 | grep -oE "[0-9]+" || true)
    [ -n "$RECV_PORT" ] && break
done
[ -n "$RECV_PORT" ] || { echo "pollen-bench: receiver never logged its port" >&2; exit 1; }
echo "  receiver pid=$RECV_PID port=$RECV_PORT"

# ── 2. build publish spec for one publisher ──────────
# M envelopes, semicolon-joined. Distinct data per envelope so the
# receiver's dedup doesn't fold them (each publisher uses its own
# index range to keep things readable in logs).
build_spec() {
    local p_index=$1
    local spec=""
    local i=0
    while [ $i -lt $M ]; do
        local payload="{\"p\":$p_index,\"i\":$i}"
        if [ -z "$spec" ]; then
            spec="127.0.0.1:$RECV_PORT:$TOPIC:1:$payload"
        else
            spec="$spec;127.0.0.1:$RECV_PORT:$TOPIC:1:$payload"
        fi
        i=$((i + 1))
    done
    echo "$spec"
}

# ── 3. spawn K publishers in parallel ────────────────
echo "  spawning $K publishers…"
PUB_PIDS=()
T0=$(date +%s%N)
for k in $(seq 1 "$K"); do
    spec="$(build_spec "$k")"
    "$NODE_BIN" 0 --publish "$spec" > "$TMP/pub-$k.log" 2>&1 &
    PUB_PIDS+=("$!")
done

# Wait for every publisher to either ACK-complete all its M sends
# or exhaust its retries (max ~5 s per pending entry).
WAIT_TIMEOUT_S=$(( (5 * 6) + 30 ))   # 30 s slack on top of the 5 s retry envelope
for k in $(seq 1 "$K"); do
    pid="${PUB_PIDS[$((k - 1))]}"
    # Poll until log says it processed everything OR the publisher exited.
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        complete=$(grep -c "publish complete" "$TMP/pub-$k.log" 2>/dev/null || echo 0)
        timeouts=$(grep -c "publish TIMEOUT" "$TMP/pub-$k.log" 2>/dev/null || echo 0)
        # ensure they are integers
        complete=${complete//[^0-9]/}; complete=${complete:-0}
        timeouts=${timeouts//[^0-9]/}; timeouts=${timeouts:-0}
        if [ $((complete + timeouts)) -ge $M ]; then
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

# ── 4. brief grace before sampling receiver log ──────
# Receiver may still be flushing the last batch.
sleep 0.5

# ── 5. parse logs ────────────────────────────────────
total_sent=$((K * M))

publish_complete=0
publish_retry=0
publish_timeout=0
for k in $(seq 1 "$K"); do
    c=$(grep -c "publish complete" "$TMP/pub-$k.log" 2>/dev/null || true); c=${c//[^0-9]/}; c=${c:-0}
    r=$(grep -c "publish retry"    "$TMP/pub-$k.log" 2>/dev/null || true); r=${r//[^0-9]/}; r=${r:-0}
    t=$(grep -c "publish TIMEOUT"  "$TMP/pub-$k.log" 2>/dev/null || true); t=${t//[^0-9]/}; t=${t:-0}
    publish_complete=$((publish_complete + c))
    publish_retry=$((publish_retry    + r))
    publish_timeout=$((publish_timeout  + t))
done

recv_msg=$(grep -c "recv MESSAGE " "$RECV_LOG" 2>/dev/null || true); recv_msg=${recv_msg//[^0-9]/}; recv_msg=${recv_msg:-0}
recv_dup=$(grep -c "recv MESSAGE dup" "$RECV_LOG" 2>/dev/null || true); recv_dup=${recv_dup//[^0-9]/}; recv_dup=${recv_dup:-0}
recv_first_sight=$((recv_msg - recv_dup))

# Stop receiver
kill "$RECV_PID" 2>/dev/null; wait "$RECV_PID" 2>/dev/null

# ── 6. summary ───────────────────────────────────────
echo ""
echo "── results ──"
printf "  elapsed:           %d ms (%.2f s)\n"      "$ELAPSED_MS" "$(awk "BEGIN{print $ELAPSED_MS/1000}")"
printf "  total sent:        %d msgs ($K × $M)\n"   "$total_sent"
printf "  publish complete:  %d (%.1f%%)\n"          "$publish_complete" "$(awk "BEGIN{print 100*$publish_complete/$total_sent}")"
printf "  publish retry:     %d\n"                   "$publish_retry"
printf "  publish TIMEOUT:   %d\n"                   "$publish_timeout"
printf "  recv MESSAGE (total recv events): %d\n"    "$recv_msg"
printf "  recv first-sight:  %d\n"                   "$recv_first_sight"
printf "  recv duplicates:   %d (dedup'd)\n"         "$recv_dup"
if [ "$ELAPSED_MS" -gt 0 ]; then
    THROUGHPUT=$(awk "BEGIN{printf \"%.1f\", 1000.0*$total_sent/$ELAPSED_MS}")
    printf "  throughput:        %s msgs/s (publishers' wall time)\n" "$THROUGHPUT"
fi
echo ""

# ── 7. exit code ─────────────────────────────────────
if [ "$publish_complete" -eq "$total_sent" ]; then
    printf "${G}OK${NC} all $total_sent publishes ACK'd\n"
    exit 0
fi
if [ "$publish_timeout" -gt 0 ]; then
    printf "${R}FAIL${NC} $publish_timeout publish TIMEOUTs — receiver overloaded or unreachable\n"
    exit 1
fi
printf "${Y}WARN${NC} $publish_complete/$total_sent complete (rest still in flight when we stopped)\n"
exit 2
