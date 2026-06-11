# Pollen

> Peer-to-peer message bus + declarative workflow engine for
> [Amalgame](https://github.com/amalgame-lang/Amalgame).
> Pure-AM port of [TARMeule](https://github.com/BastienMOUGET/TARMeule).
> **Pollen is a program**, not a library — install the `pollen` CLI
> and run nodes; no `amc package add` required.

**Status:** v0.2.0-dev.

What is **shipped** today:

- **Workflow engine** — a tree-walking interpreter that executes a
  `workflow.json` per node: `if` / `while` / `for` / `set` / `goto` /
  `call` actions, persistent `state.X`, and a CEL-lite expression
  evaluator (dotted paths, `and`/`or`/`not`, `in` / `not_in`). Landed
  incrementally through Phase 6.0a (see git history).
- **Decentralized message bus** — every node is an autonomous peer
  that receives a message, runs its action tree, and forwards to the
  next node(s). No central orchestrator.
- **Shared-directory coordination** — `workflow.json`, `topics/`,
  `souscriptions/` live on a shared mount (NFS/SMB), re-read on a
  SYNC message. See the honesty note under *Coordination model*.

What is **roadmap** (proposal-only, not yet in this repo): schema
validation, QoS, multicast discovery, AES-256 encryption,
`/metrics`, Ed25519 identity, topic ACLs. See
[`docs/proposals/pollen.md`](https://github.com/amalgame-lang/Amalgame/blob/main/docs/proposals/pollen.md).

## Transport: TCP

Pollen's **canonical transport is TCP** (newline-framed JSON),
matching the extracted
[`amalgame-pollen`](https://github.com/amalgame-lang/amalgame-pollen)
package. TCP gives us reliable, ordered delivery and simple framing
without hand-rolling ACK / retry / dedup / reordering.

> ⚠️ **Migration in progress.** An earlier UDP prototype
> (`tools/pollen-node.am`) is **deprecated** and kept only for
> reference / TARMeule interop archaeology. The TCP node lives in
> `tools/pollen-node-tcp.am`. The installer (`install.sh`) currently
> still builds the legacy UDP node by default — flipping it to the
> TCP node (and retiring the UDP path) is the next code task. Until
> that lands, `pollen run` starts the legacy UDP node; treat TCP as
> the supported, documented direction.

## What it is

A decentralized messaging program: every node is a peer that talks
directly to its neighbours — no broker process to operate, no
language other than Amalgame to install. Designed for closed LANs,
IoT / industrial supervision, and symmetric peer topologies.

Pollen is built on top of `Amalgame.Net` (built-in stdlib).
Zero `@c {}` blocks, zero third-party C dependency.

## Coordination model (honest framing)

Pollen is **broker-less** in the sense that there is no broker
*process* (no Erlang VM, JVM, NATS server, mosquitto, redis-server)
to run and operate. It is **not** infrastructure-free: nodes
coordinate through a **shared directory** (`workflow.json`,
`topics/`, `capabilities/`, `state/`). That shared mount is a real
coordination point — it is your I/O bottleneck and a potential
single point of failure, and write access to it is effectively
trust. Pick Pollen when "no broker daemon + a shared folder" fits
your topology (closed LAN, edge mesh); pick a real broker when you
need consensus, ACLs, backpressure, or durable replay.

## Why not just use RabbitMQ / Kafka / NATS / MQTT / Redis?

Amalgame already has client packages for all five. They require a
broker process to run. Pollen is broker-less: peers talk directly,
coordinating via the shared directory above. Use Kafka / RabbitMQ /
Temporal when you need **durable replay, multi-DC, transactional
sagas, or execution history** — Pollen explicitly does **not** ship
those (they are stated non-goals).

## Quick start

```bash
# Install (drops `pollen` + `pollen-node` + `pollen-client` under
# ~/.local/bin and ~/.local/share/pollen/):
curl -sSL https://raw.githubusercontent.com/amalgame-lang/pollen/main/install.sh | bash

# Start a node on :5000  (legacy UDP node today — see migration note)
pollen run 5000

# Send a MESSAGE envelope and wait for its ACK:
pollen send 127.0.0.1 5000 my-topic-uuid 1 '{"temp":25,"unit":"C"}'

# Raw send (no envelope, no ACK wait):
pollen send 127.0.0.1 5000 "any-bytes-here"
```

## CLI

```
pollen run [port] [--shared <dir>]                   Start a node (default port 5000; 0 = ephemeral).
                                                     --shared loads topics + subscriptions from
                                                     <dir>/topics/<uuid>.json and souscriptions/<uuid>.json
                                                     at startup, and re-reads on a SYNC message.
pollen send <ip> <port> <payload>                    Raw send — payload goes verbatim on the wire.
pollen send <ip> <port> <topic-uuid> <ver> <data>    MESSAGE envelope mode — wraps data in a
                                                     TARMeule v1 MESSAGE, retries on missing ACK.
pollen version                                       Print version + amc binding info.
pollen help                                          Help.
```

### Load test (built-in)

A bench harness is provided to drive K publishers × M messages and
report delivery / retry / throughput:

```bash
tools/pollen-bench-tcp.sh      # TCP bench (canonical)
tools/pollen-bench.sh          # legacy UDP bench
```

> Note: no benchmark figures are quoted here on purpose — they must
> be (re)measured on the TCP node before being published, so we don't
> ship stale UDP-era numbers as if they were current.

### sharedDir layout

```
<dir>/
├── topics/<uuid>.json           { "uuid":"…", "name":"…", "version":N, "structure":{…} }
└── souscriptions/<uuid>.json    { "uuid":"…", "ip":"…", "port":N, "topics":[…] }
```

Per-file storage (vs a single `topics.json`) keeps `flock(2)`
granularity at the file level, so concurrent nodes editing different
entries don't contend. SYNC messages broadcast which file changed;
peers re-read just that one.

## The visual side: Pollen Manager

[`pollen-manager`](https://github.com/amalgame-lang/pollen-manager)
is a Mosaic web app to design `workflow.json` visually (flowchart),
inject messages, and **step through a distributed workflow with
conditional breakpoints** — pause a message in flight, inspect /
edit its payload, step or continue. It is a development &
observability tool, not a production control plane.

## Wire-compatibility with TARMeule

The MESSAGE / ACK / SYNC envelope format reproduces TARMeule v1's
wire format, so a mixed Pollen ↔ TARMeule Node.js cluster can be run
during migrations. (This compat path predates the TCP decision and
applies to the legacy UDP node.)

## License

Apache 2.0. See [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md).
