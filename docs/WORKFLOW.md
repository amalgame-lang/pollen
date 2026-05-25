# Pollen workflow.json — schema & semantics

> Phase 3.0 scaffolding (v0.2.0-dev, 2026-05-25)

A Pollen network reads its topology from a single JSON file
hosted on a shared network mount (NFS, SMB, or just a checked-in
file when nodes share a workspace). Every Pollen node on the
network reads the same file, finds **its own role** in the
`nodes` table, and configures itself: which topics it consumes,
which it emits to whom.

There is **no central scheduler**. The workflow is choreography
(every node knows its part), not orchestration (a master telling
nodes what to do).

## Minimum viable schema

```json
{
  "name": "telemetry-pipeline",
  "version": 3,
  "nodes": {
    "acquisition-1": {
      "host": "sensor-gw-01.lan",
      "port": 5000,
      "emits":   ["temperature.raw"],
      "next":    ["filter-1"]
    },
    "filter-1": {
      "host": "proc-01.lan",
      "port": 5000,
      "consumes": ["temperature.raw"],
      "emits":    ["temperature.filtered"],
      "next":     ["aggregator-1", "archive-1"]
    },
    "aggregator-1": {
      "host": "proc-02.lan",
      "port": 5000,
      "consumes": ["temperature.filtered"],
      "emits":    ["temperature.minute-avg"],
      "next":     ["dashboard-1"]
    },
    "archive-1": {
      "host": "storage-01.lan",
      "port": 5000,
      "consumes": ["temperature.filtered"]
    },
    "dashboard-1": {
      "host": "web-01.lan",
      "port": 5000,
      "consumes": ["temperature.minute-avg"]
    }
  }
}
```

### Top-level fields

| field | required | description |
|---|---|---|
| `name` | yes | Human-readable workflow name. Logged at startup; future tooling will key topology versions by this. |
| `version` | yes | Integer. Bumped whenever the file changes so nodes can detect stale reads in the filewatcher reload path (Phase 3.x). |
| `nodes` | yes | Object whose keys are unique node-role names (`acquisition-1`, `filter-1`, …) and whose values describe each node. |

### Per-node fields

| field | required | description |
|---|---|---|
| `host` | yes | DNS name or IP of the host running this node. Used to figure out which role belongs to the local process. |
| `port` | yes | TCP port the node listens on. Identity within a multi-node-per-host setup. |
| `consumes` | optional | Array of topic names this node accepts. Pollen will not deliver MESSAGEs on other topics. Default `[]` (pure publisher). |
| `emits` | optional | Array of topic names this node publishes. Default `[]`. Declared for documentation + future validation; runtime behaviour is driven by `next`. |
| `next` | optional | Array of node-role names that should receive the MESSAGE this node emits. Empty = sink. |

### Topic names

Topic names are free-form strings. Convention: dot-namespaced
(`telemetry.raw`, `webhook.github`, etc.). They are matched
case-sensitively. A future schema bump may add per-topic JSON
structure declarations for validation.

## Self-identification on startup

When `pollen-node-tcp` launches with `--workflow <path>` it:

1. Reads + parses the file.
2. Resolves its own identity:
   - First match where `host == <local hostname>` and `port ==
     <its bound port>`.
   - Override: `--node-name <role>` skips the host/port lookup
     and uses the named role directly. Useful for testing on
     loopback where every node sits on `127.0.0.1`.
3. Logs the role it picked, the consume / emit / next lists,
   and the workflow name + version.

If no match is found, the node logs `workflow: no role for
<hostname>:<port>` and **falls back to free-form mode** (still
ACKs every MESSAGE it receives, but doesn't enforce consume
filtering or auto-route on emit).

## Phase 3.x roadmap

| Phase | Scope |
|---|---|
| **3.0** ✅ | Parse workflow.json, self-identify, log role. No runtime dispatch — every MESSAGE still ACKed via the Phase 2.4 hot path. |
| **3.1** ✅ | Consume filtering: drop MESSAGEs whose `topic.uuid` ∉ `consumes`. |
| **3.2** ✅ | Auto-emit on receive: after ACKing a MESSAGE on a consumed topic, publish to every node in `next` using the local handler's output. |
| **3.3** ✅ | Hot-reload via mtime polling watcher thread. Re-read workflow.json when its mtime changes; atomic swap under mutex. |
| **3.4** ✅ | parentMessageId chaining: forwarded envelopes get a fresh messageId, and `,"parentMessageId":"<previous>"` is appended so any downstream node can walk back to the producer. Hot-path log distinguishes `(root)` (no parent) from `parent=<uuid>` (descendant). |
| 3.5 | sharedDir/executions/ persistent state for the DAG (subscriptions and topic registry already shipped in Phase 1.5). |
| 4 | Mosaic web-based workflow designer (WYSIWYG drag-and-drop, per
the user notes). Edits workflow.json, broadcasts a SYNC packet
to all listed nodes to trigger their reload. |

## Wire envelope (recap)

Every MESSAGE carries the topic info needed for workflow
dispatch:

```json
{
  "messageId": "<uuid-v4>",
  "type":      "MESSAGE",
  "topic": {
    "uuid":    "<topic-name>",
    "version": 1
  },
  "data":      { /* arbitrary, per-topic */ },
  "timestamp": 1779712464885,
  "parentMessageId": "<uuid-v4 or null>"   // Phase 3.4+
}
```

The `topic.uuid` field is what Pollen matches against `consumes`
arrays in workflow.json. (The `uuid` keyword is historical from
TARMeule v1 — Pollen plans to rename it to `name` in a future wire
revision.)

## Example: smoke-test a 3-node pipeline

```bash
# All three nodes on loopback, one shared workflow.json
cat > /tmp/pollen-wf.json <<'EOF'
{
  "name": "demo",
  "version": 1,
  "nodes": {
    "producer":  { "host":"127.0.0.1","port":7901,"emits":["x.raw"], "next":["xformer"] },
    "xformer":   { "host":"127.0.0.1","port":7902,"consumes":["x.raw"],"emits":["x.cooked"],"next":["sink"] },
    "sink":      { "host":"127.0.0.1","port":7903,"consumes":["x.cooked"] }
  }
}
EOF

pollen-node-tcp 7901 --workflow /tmp/pollen-wf.json --node-name producer &
pollen-node-tcp 7902 --workflow /tmp/pollen-wf.json --node-name xformer  &
pollen-node-tcp 7903 --workflow /tmp/pollen-wf.json --node-name sink     &
```

Each node logs its self-resolved role on startup. With Phase 3.1
+ 3.2 wired, sending `--publish 127.0.0.1:7902:x.raw:1:hello`
from a fourth ephemeral node walks the chain:

```
xformer: workflow: consumed topic=x.raw msg=<A> (root)
         → forward to 1 next-node(s) (emit topic=x.cooked)
sink:    workflow: consumed topic=x.cooked msg=<B> parent=<A>
         → terminal (sink)
```

(`<A>` is the producer's messageId; `<B>` is the fresh UUID the
xformer minted when forwarding — Phase 3.4 chain visualization.)
