# Pollen TCP bench — methodology & reproducible results

> Phase 2.4 (v0.2.0-dev) — last updated 2026-05-25

This document describes how the [`pollen-bench-tcp.sh`](../tools/pollen-bench-tcp.sh)
load-test orchestrator works, the hardware it ran on, and the
numbers Pollen v0.2 TCP currently hits. Everything is reproducible
from `git clone` + the commands at the end.

## TL;DR

On the audit hardware below, **`pollen-node-tcp` sustains ~63,500
messages per second peer-to-peer with full per-message ACK
round-trip and UUID-unique messageIds**, measured at K=32 publishers
× M=1000 messages each (32,000 publishes total, 100% ACKed).
Stable across 5 runs (mean 63,486 ± 4,450 msg/s, CV 7%).

> Peer-to-peer = no broker hop. Every publisher opens its own TCP
> connection to the receiver, fires its batch through the
> [hot-path C](../tools/pollen-node-tcp.am) (Phase 2.4d/e),
> drains ACKs, and exits.

## Test hardware

| | |
|---|---|
| Hypervisor | KVM (Linux host) |
| vCPUs | **2** (Intel Core i5-10400H @ 2.60 GHz, host-passthrough) |
| RAM | 3.8 GiB |
| OS | Debian 12 (bookworm), kernel 6.1.0-47 |
| Compiler | gcc 12.2.0 |
| amc | 0.8.55 |
| `net.core.rmem_max` | 212,992 (Debian default — **not bumped**) |
| `net.core.somaxconn` | 4096 |

Anyone reproducing should expect higher numbers on (a) a bare-metal
4+ core box, (b) a host with `net.core.rmem_max=16777216` set, or
(c) a kernel newer than 6.1. Conversely, lower numbers on
oversubscribed cloud VMs (T-series instances throttle CPU).

## What's measured

The bench script:

1. Spawns one `pollen-node-tcp` as a **receiver** on a random
   high port. It binds the TCP socket and waits for connections.
2. Spawns **K parallel `pollen-node-tcp` processes as publishers**.
   Each one is invoked with:
   ```
   --burst <recv-ip>:<recv-port>:<topic-uuid>:1:<json-data>:<M>
   ```
   The `--burst` flag tells the publisher to open one TCP connection
   to the receiver and fire M MESSAGEs back-to-back, then drain M
   ACKs, then exit. UUIDv4 messageIds (16 bytes of `getrandom` +
   RFC 4122 version/variant bits) are generated inline in C.
3. Polls each publisher's log file every 200 ms for `M`
   `publish complete` lines (one per ACKed message). Marks the
   publisher done once its log shows `complete >= M`.
4. Records `T0` (just before spawning) and `T1` (after all K
   publishers complete). Computes:
   - **throughput** = total / (T1 − T0)
   - **latency percentiles** = parses every `publish <mid> … ts=<T_send>`
     and matching `recv ACK … for <mid> … ts=<T_recv>` line, joins
     by messageId, sorts the (T_recv − T_send) deltas, picks
     p50 / p95 / p99 / min / max / avg.

Every MESSAGE is **independently ACKed** by the receiver. There's
no batching, no auto-ack, no fire-and-forget mode. Each publisher
waits for all its sends to be ACKed before exiting.

## Wire format

JSON envelopes, newline-delimited:

```
client → server: {"messageId":"<uuid>","type":"MESSAGE","topic":{"uuid":"<topic>","version":1},"data":<...>,"timestamp":<ms>}\n
server → client: {"type":"ACK","messageId":"<uuid>","timestamp":<ms>}\n
```

A single TCP connection carries the whole peer-pair conversation
(M MESSAGEs + M ACKs).

## Results (v0.2.0-dev, 2026-05-25)

All numbers are stable across 5 runs unless noted. Format:
mean (min – max). Latencies are publisher-observed end-to-end
(publish ts → ACK reception ts).

| K | M | total msgs | **throughput msg/s** | p50 | p99 | CV |
|---|---|---|---|---|---|---|
| 4 | 100 | 400 | 9,667 (8,333 – 11,111) | < 1 ms | 2 ms | 46 % * |
| 8 | 500 | 4,000 | **13,954** (12,903 – 14,760) | 19 ms | 69 ms | 4 % |
| 16 | 500 | 8,000 | **23,899** (19,370 – 25,806) | 23 ms | 95 ms | 10 % |
| 32 | 100 | 3,200 | 6,897 (5,776 – 8,060) | 36 ms | 51 ms | 12 % |
| 32 | 500 | 16,000 | **31,668** (28,725 – 36,199) | 75 ms | 125 ms | 9 % |
| **32** | **1000** | **32,000** | **🚀 63,486 (58,287 – 71,588)** | 97 ms | 145 ms | **7 %** |

*K=4 M=100 has a 400-msg total — small enough that bench startup
jitter dominates. Larger batches are stable.*

Sample bench output (K=32 M=1000):

```
══════════════════════════════════════════════
  Pollen — Bench (TCP)
══════════════════════════════════════════════
  binary:     ~/.cache/pollen-dev/pollen-node-tcp
  publishers: 32
  messages:   1000 each (32000 total)
  topic:      bench-topic-00000000-0000-4000-8000-000000000000

  receiver pid=292793 port=47668
  spawning 32 publishers (--burst path)…

── results (TCP) ──
  elapsed:           483 ms (0.48 s)
  total sent:        32000 msgs (32 × 1000)
  publish complete:  32000 (100.0%)
  publish FAILED:    0
  recv MESSAGE:      0          ← server hot-path skips per-msg log
  throughput:        66252.6 msgs/s
  latency ms (n=32000): min=48 p50=97 p95=140 p99=145 max=153 avg=101.2

OK all 32000 publishes ACK'd
```

`recv MESSAGE: 0` is by design: the server hot-path
(`pollen_hot_conn_loop`, [pollen-node-tcp.am](../tools/pollen-node-tcp.am))
drops per-msg logging — the publisher-side `recv ACK … (publish complete)`
count is the source of truth.

## How this compares to other message brokers

> ⚠️ Cross-broker benchmarks are notoriously unfair because every
> system has different defaults, persistence modes, ACK semantics
> and hardware. The numbers below are **public claims from the
> respective projects' docs / benchmarks**, not numbers we re-ran
> ourselves. Take them as ballpark, not gospel.

| Broker | Mode | Typical throughput | Per-msg ACK? | Broker hop? | Persistence? |
|---|---|---|---|---|---|
| RabbitMQ | persistent + manual ACK | 4–6 k msg/s | ✅ | ✅ | ✅ (disk fsync) |
| RabbitMQ | transient + auto ACK | 100 k – 1 M msg/s | ❌ | ✅ | ❌ |
| Kafka | batched, replicated | 100 k – 1 M msg/s | per-batch | ✅ | ✅ |
| NATS Core | pub/sub | 5 M – 10 M msg/s | ❌ | ✅ | ❌ |
| NATS JetStream | durable | 100 k – 200 k msg/s | ✅ | ✅ | ✅ |
| Redis Pub/Sub | best-effort | 50 k – 150 k msg/s | ❌ | ✅ | ❌ |
| ZeroMQ | PUB/SUB loopback | 5 M – 6 M msg/s | ❌ | ❌ (lib) | ❌ |
| **Pollen v0.2 TCP** | **P2P + manual ACK** | **63 k msg/s (this VM)** | ✅ | **❌** | ❌ (yet) |

The fairest comparison is **RabbitMQ persistent + manual ACK**,
where every published message round-trips through the broker and
gets durably stored before the producer is told "delivered". In
that mode RabbitMQ on similar hardware sits at 4–6 k/s. Pollen at
63 k/s is **~10–15× faster** because it eliminates the broker hop
and the disk fsync.

When persistence is needed in Pollen (Phase 3+), expect numbers to
drop into RabbitMQ persistent territory (4–10 k/s) — disk fsync is
disk fsync regardless of who's calling it. The Pollen advantage
should hold for non-persistent or eventually-persistent workflows.

The **fire-and-forget / no-ACK** tier (NATS Core, ZeroMQ, RabbitMQ
transient) goes 100× faster than us. But "every message ACKed
back to the producer" is a different feature set; you'd build it
on top of those brokers and pay the same costs we do.

## How to reproduce

```bash
# 1. Clone Pollen + Amalgame
git clone https://github.com/amalgame-lang/Amalgame ~/Développement/Amalgame
git clone https://github.com/amalgame-lang/pollen   ~/Développement/pollen
cd ~/Développement/Amalgame && ./build_amc.sh
export PATH=$HOME/.local/bin:$PATH

# 2. Install Pollen's runtime deps
amc package add datetime
amc package add random
amc package add threading

# 3. First run of `pollen run` (or any pollen tool) builds
#    pollen-node-tcp into $HOME/.cache/pollen-dev/. After that
#    pollen-bench-tcp.sh picks it up automatically.
~/Développement/pollen/tools/pollen run 0 &   # spawns + warms cache
kill %1   # we just wanted the build

# 4. Run the bench (5 runs, peak config):
for i in 1 2 3 4 5; do
    ~/Développement/pollen/tools/pollen-bench-tcp.sh -F -k 32 -m 1000
done
```

Each run prints a result block as shown above.

## Hardware ceiling — what's actually possible on this VM

To know how much headroom Pollen has left, we ran a **pure-C
pipelined ping-pong** with the same protocol shape (32 concurrent
TCP connections, each pipelining 1,000 JSON-shaped MESSAGE + ACK
round-trips). Same VM, same kernel, same wire format, no AM stack,
no GC, no closures:

```
RAW C K=32 M=1000 — 5 runs:
  271,186 msg/s  (118 ms)
  163,265 msg/s  (196 ms)
  152,381 msg/s  (210 ms)
  130,612 msg/s  (245 ms)
  139,130 msg/s  (230 ms)
  ---
  mean ≈ 171,300 msg/s  (high variance, CV ~30%)
```

So the **architectural ceiling on this 2-vCPU VM with this wire
shape is ~170 k msg/s** (sustained), peaking at 271 k. Pollen's
63 k stable / 71 k peak puts us at **37 %** of that ceiling.

The remaining gap lives in the **AM Main** path that runs once per
publisher before the hot-path C function takes over:

- `String_Split` on the `--burst` spec (6-field split + colon
  re-join of the data field)
- `String_ToInt` on port + version + count
- amc closure setup for the worker spawn
- Process startup / dynamic loader / GC initial state

Per-publisher AM startup is ~5-10 ms on this hardware. At K=32
those 32 × ~7 ms startups happen partly in parallel but with the
2-vCPU scheduler they serialise enough to add ~50-100 ms of wall
time on top of the actual send/recv burst.

In other words: we are not bottlenecked by the network, the TCP
stack, or our per-message C work. We are bottlenecked by **how
many publisher processes the kernel can wake and AM-bootstrap per
millisecond on a 2-core VM**. A 4-core box or a single multi-
worker publisher process should land us closer to 100 k msg/s.

## What's left on the perf ladder

Audit-able opportunities:

1. **Bump `net.core.rmem_max`** — current default 208 KiB caps
   the TCP receive buffer. `sudo sysctl -w net.core.rmem_max=16777216`
   should reduce per-publisher serialisation in the kernel.
2. **More cores** — we max out at K ≈ 32 on 2 vCPUs because the
   bash loop spawns N processes serially and the kernel scheduler
   has to time-slice. A 4 / 8 / 16-core host should scale K higher.
3. **Persistent storage** (Phase 3) will trade some of this
   throughput for durability. Plan budget: drop to ~5–10 k/s on
   the same hardware once we fsync per message; faster with
   batched fsync.
4. **Multi-host bench** — these numbers are all loopback. Real
   LAN with a 1 GbE NIC should give similar absolute throughput
   (we're nowhere near saturating 1 Gbps with 150-byte envelopes)
   but real-world p99 numbers will be dominated by network RTT.

## Caveats / honest disclosure

- Numbers above are **loopback only** on a 2-core KVM guest.
  No NUMA effects, no real network. We expect single-LAN-hop
  numbers to be in the same ballpark on the same hardware.
- The bench uses a single shared topic UUID across all 32k
  publishes. Real workflows with many distinct topics may see
  different patterns (server-side topic dispatch isn't optimised
  yet — Phase 3).
- The server's per-message `recv MESSAGE` log is suppressed in
  the hot path (Phase 2.4c). Validation that all 32,000 MESSAGEs
  arrived is by the publisher's matched-ACK count, not a
  server-side counter. Server-side accounting will return in
  Phase 3 when topics + persistence land.
- `publish FAILED` is always 0 in the audit runs (32k/32k ACKed),
  but a degraded TCP path (peer crash, partial close) would
  surface as `publish-stream EOF after got=<N>/<M>` in the
  publisher log. Phase 2.6 will add reconnect + retry on EOF.

If you re-run these benches and see substantially different
numbers, please [open an issue](https://github.com/amalgame-lang/pollen/issues)
with the output + your hardware specs. The aim of this document
is to give a credible, reproducible baseline — not to claim a
record.
