# Pollen

> Peer-to-peer UDP data bus + (planned) declarative workflow
> orchestrator for [Amalgame](https://github.com/amalgame-lang/Amalgame).
> Pure-AM port of [TARMeule](https://github.com/BastienMOUGET/TARMeule).
> **Pollen is a program**, not a library — install the `pollen` CLI
> and run nodes; no `amc package add` required.

**Status:** v0.1.0-dev — Phase 1.2 shipped (UDP node + ACK echo).
Wire protocol, ACK retry, topics, persistence, workflow layer all
land in subsequent phases.

## What it is

A decentralized messaging program: every node binds a UDP socket
and talks directly to its peers. No broker process to run, no
language other than Amalgame to install. Designed for closed LANs,
IoT / industrial supervision, and symmetric peer topologies.

Pollen is built on top of `Amalgame.Net` (built-in stdlib since
amc v0.8.52 added `UdpSocket.ReceiveFrom` + ephemeral-port reporting).
Zero `@c {}` blocks, zero third-party C dependency.

## Quick start

```bash
# Install (drops `pollen` + `pollen-node` + `pollen-client` under
# ~/.local/bin and ~/.local/share/pollen/):
curl -sSL https://raw.githubusercontent.com/amalgame-lang/pollen/main/install.sh | bash

# Start a node on UDP :5000
pollen run 5000

# In another shell, send a real TARMeule v1 MESSAGE envelope and
# wait for its ACK:
pollen send 127.0.0.1 5000 my-topic-uuid 1 '{"temp":25,"unit":"C"}'
# → node prints  `recv MESSAGE <id> topic=my-topic v1 from 127.0.0.1:NNNNN ...`
# → sender prints `ACK <id> from 127.0.0.1:5000`

# Raw send (no envelope, no ACK wait — useful for SYNCHRONIZATION
# datagrams and interop probes):
pollen send 127.0.0.1 5000 "any-bytes-here"
```

## Architecture

```
              ┌────────────────────────────────────────┐
              │ Layer 2 — Workflow (v0.2 / Phase 2)    │
              │   workflow.json on shared mount.       │
              │   Hot reload via amalgame-io-filewatcher.│
              └────────────────────────────────────────┘
                              ▲ uses
              ┌────────────────────────────────────────┐
              │ Layer 1 — Transport (v0.1 / Phase 1)   │
              │   UDP socket + JSON wire format.       │
              │   ACK + retry + UUID dedup.            │
              │   Topics + Subscriptions JSON-persisted.│
              └────────────────────────────────────────┘
                              ▲ uses
              ┌────────────────────────────────────────┐
              │ Amalgame.Net (built-in stdlib, amc)    │
              │   UdpSocket — bind, send, ReceiveFrom  │
              └────────────────────────────────────────┘
```

## Why not just use RabbitMQ / Kafka / NATS / MQTT / Redis?

Amalgame already has client packages for all five. They require a
broker process to run (Erlang VM, JVM, NATS server, mosquitto,
redis-server). Pollen is broker-less: every node speaks UDP directly
to its peers. Use Kafka / RabbitMQ when you need durable replay,
multi-DC, or transactional sagas — Pollen explicitly does **not**
ship those.

## Roadmap

| Phase | Scope | Target |
|---|---|---|
| **1.2** ✅ | UDP node + ACK echo over `Amalgame.Net` | v0.1.0-dev |
| **1.3** ✅ | JSON wire (MESSAGE / ACK / SYNC), UUID dedup window | v0.1.0-dev |
| **1.4** ✅ | ACK retry + timeout (pollen-client, 5 attempts × 1 s) | v0.1.0-dev |
| **1.5** ✅ | sharedDir scan at startup + SYNC reload | v0.1.0-dev |
| **1.6** ✅ | `pollen-client` (raw + msg modes, drops `nc -u` dep) | v0.1.0-dev |
| 1.7 | Interop test vs TARMeule v1 Node.js node | v0.1.0 |
| 1.8 | Release v0.1.0 (tag + packages-index entry) | v0.1.0 |
| **2** | `workflow.json` schema + hot reload, `pollen workflow` | v0.2.0 |
| 3 | Schema validation, QoS, multicast discovery | v0.3.0 |
| 4 | AES-256 encryption, `/metrics` Prometheus, Mosaic bridge | v0.4.0 |
| 5 | Ed25519 identity, topic ACLs | v0.5.0 |

Full proposal:
[`docs/proposals/pollen.md`](https://github.com/amalgame-lang/Amalgame/blob/main/docs/proposals/pollen.md)
in the Amalgame repo.

## CLI

```
pollen run [port] [--shared <dir>]                   Start a UDP node (default port 5000; 0 = ephemeral).
                                                     --shared loads topics + subscriptions from
                                                     <dir>/topics/<uuid>.json and souscriptions/<uuid>.json
                                                     at startup, and re-reads on SYNCHRONIZATION receive.
pollen send <ip> <port> <payload>                    Raw send — payload goes verbatim on the wire.
pollen send <ip> <port> <topic-uuid> <ver> <data>    MESSAGE envelope mode — wraps data in a
                                                     TARMeule v1 MESSAGE, retries 5×1 s on missing ACK.
pollen version                                       Print version + amc binding info.
pollen help                                          Help.
```

### sharedDir layout

```
<dir>/
├── topics/<uuid>.json           { "uuid":"…", "name":"…", "version":N, "structure":{…} }
└── souscriptions/<uuid>.json    { "uuid":"…", "ip":"…", "port":N, "topics":[…] }
```

Per-file storage (vs a single `topics.json`) keeps `flock(2)` granularity at the
file level, so concurrent nodes editing different entries don't contend. SYNC
messages broadcast which file changed, peers re-read just that one.

## Wire-compatibility with TARMeule

Phase 1.3+ reproduces TARMeule v1's wire format byte-for-byte. A
mixed Pollen ↔ TARMeule Node.js cluster will be supported during
migrations.

## License

Apache 2.0. See [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md).
