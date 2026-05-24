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
# Install (drops `pollen` + `pollen-node` into ~/.local/bin and
# ~/.local/share/pollen/):
curl -sSL https://raw.githubusercontent.com/amalgame-lang/pollen/main/install.sh | bash

# Start a node on UDP :5000
pollen run 5000

# In another shell, send a packet
pollen send 127.0.0.1 5000 "hello pollen"
# → node prints `recv 12 bytes from 127.0.0.1:NNNNN: hello pollen`
# → sender receives `ACK hello pollen` back
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
| 1.3 | JSON wire (MESSAGE / ACK / SYNC), UUID dedup | v0.1.0 |
| 1.4 | ACK retry + timeout machinery | v0.1.x |
| 1.5 | Topics + Subscriptions persistence (JSON files) | v0.1.x |
| **2** | `workflow.json` schema + hot reload, `pollen workflow` | v0.2.0 |
| 3 | Schema validation, QoS, multicast discovery | v0.3.0 |
| 4 | AES-256 encryption, `/metrics` Prometheus, Mosaic bridge | v0.4.0 |
| 5 | Ed25519 identity, topic ACLs | v0.5.0 |

Full proposal:
[`docs/proposals/pollen.md`](https://github.com/amalgame-lang/Amalgame/blob/main/docs/proposals/pollen.md)
in the Amalgame repo.

## CLI

```
pollen run [port]                    Start a UDP node (default 5000; 0 = ephemeral)
pollen send <ip> <port> <payload>    One-shot send a UDP datagram
pollen version                       Print version + amc binding info
pollen help                          Help
```

## Wire-compatibility with TARMeule

Phase 1.3+ reproduces TARMeule v1's wire format byte-for-byte. A
mixed Pollen ↔ TARMeule Node.js cluster will be supported during
migrations.

## License

Apache 2.0. See [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md).
