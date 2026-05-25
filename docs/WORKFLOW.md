# Pollen workflow.json — schema & semantics

> **Document scope:** Pollen workflow.json **v1** — what ships
> today (Phase 3.0–3.5, v0.2.0-dev, 2026-05-25). The schema is
> a flat DAG with `next: [...]`. No conditional, no loop.
>
> **Future evolutions are spec'd in separate proposals:**
> - [`workflow-tree.md`](proposals/workflow-tree.md) — Phase 5 :
>   replaces `next: [...]` with an **execution tree** carrying
>   `if` / `while` / `for` / `set` / `sequence` / `fan_out` /
>   `call` nodes. Conditions in JSON-structured form ;
>   variables routed across `msg.data.X` (volatile) and
>   `state.X` (persisted in `sharedDir/state/`). Decentralised
>   evaluation — every Pollen node embarks the tree + an
>   evaluator. **Proposal — non-implémenté.**
> - [`capability-lb-ha.md`](proposals/capability-lb-ha.md) —
>   Phase 6 : workflow.json refers to **actions** (abstract) ;
>   each instance writes its `capabilities/<id>.json` under
>   the shared dir, advertising which actions it implements +
>   its current load. Each instance maintains a local
>   `action → [providers, …]` registry refreshed every 2 s and
>   resolves each hop via **power-of-two-choices** LB.
>   Heartbeat staleness + TCP failover for HA. **Proposal —
>   non-implémenté ; layer orthogonal à la Phase 5.**

A Pollen network reads its topology from a single JSON file
hosted on a shared network mount (NFS, SMB, or just a checked-in
file when nodes share a workspace). Every Pollen node on the
network reads the same file, finds **its own role** in the
`nodes` table, and configures itself: which topics it consumes,
which it emits to whom.

There is **no central scheduler**. The workflow is choreography
(every node knows its part), not orchestration (a master telling
nodes what to do). Phase 5/6 keep this property: even with `if` /
`while` / LB, the runtime stays decentralised — each node decides
its next hop on its own.

## Tooling

- **Editing :** Pollen Manager (Mosaic web app,
  [amalgame-lang/pollen-manager](https://github.com/amalgame-lang/pollen-manager),
  local au commit `cbf23c9` au 2026-05-25). Read/edit du fichier
  workflow.json depuis le navigateur, SVG render du DAG, dashboard
  live des executions/ (à venir Phase 4.2).
- **Hot-reload :** chaque node Pollen poll `mtime(workflow.json)`
  toutes les 2 s. Une edition (à la main ou via Pollen Manager)
  est prise en compte sans restart.
- **Persistance :** chaque node Pollen lancé avec `--shared-dir`
  écrit un record JSON par hop sous `<dir>/executions/<mid>-<role>.json`
  (Phase 3.5).

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

## Roadmap

### Phase 3 — DAG plat (shipped)

| Phase | Scope |
|---|---|
| **3.0** ✅ | Parse workflow.json, self-identify, log role. No runtime dispatch — every MESSAGE still ACKed via the Phase 2.4 hot path. |
| **3.1** ✅ | Consume filtering: drop MESSAGEs whose `topic.uuid` ∉ `consumes`. |
| **3.2** ✅ | Auto-emit on receive: after ACKing a MESSAGE on a consumed topic, publish to every node in `next` using the local handler's output. |
| **3.3** ✅ | Hot-reload via mtime polling watcher thread. Re-read workflow.json when its mtime changes; atomic swap under mutex. |
| **3.4** ✅ | parentMessageId chaining: forwarded envelopes get a fresh messageId, and `,"parentMessageId":"<previous>"` is appended so any downstream node can walk back to the producer. Hot-path log distinguishes `(root)` (no parent) from `parent=<uuid>` (descendant). |
| **3.5** ✅ | sharedDir/executions/ persistent state. Pass `--shared-dir <path>`; each node writes one record per MESSAGE it touches under `<path>/executions/<mid>-<role>.json`. Same-mid records from emitter + consumer coexist (different `role`); chain walk reads `parentMessageId` and re-globs. |

### Phase 4 — Pollen Manager (Mosaic web app, in progress)

Repo séparé : `amalgame-lang/pollen-manager`. Scaffold local au
commit `cbf23c9`. Workflow.json reste v1 dans cette phase ; le
manager édite/visualise du JSON v1 plat.

| Phase | Scope |
|---|---|
| **4.0** ✅ scaffold | GET `/api/workflow` + SVG read-only render + textarea editor + Copy-to-clipboard (PUT à venir 4.0.5) |
| 4.0.5 | PUT `/api/workflow` (bloqué : amalgame-web v0.13.3 WebContext ne expose pas `Request.Body` — fix upstream requis) |
| 4.1 | WYSIWYG drag-and-drop des nodes sur le SVG + édition panel-side de consumes/emits/next. Positions persistées dans `_layout` sidecar de workflow.json (ignoré par Pollen). |
| 4.2 | Live executions dashboard : poll `/api/executions`, overlay des status sur le DAG |
| 4.3 | SYNC broadcast à chaque save (au lieu du watcher 2 s) |
| 4.4 | Intervention manuelle (force-ACK, replay, cancel) — besoin endpoint côté pollen-node-tcp |

### Phase 5 — Execution tree (proposal, non implémenté)

[`docs/proposals/workflow-tree.md`](proposals/workflow-tree.md)

Le `next: [...]` v1 disparaît. Le workflow gagne un `tree:`
contenant `if` / `while` / `for` / `set` / `sequence` / `fan_out` /
`call` / `end`. Schema v2 : nodes deviennent un array indexé par
UUID + section `vars` pour les constantes globales. Évaluation
décentralisée — chaque node Pollen embarque le tree et un
évaluateur d'expressions JSON-structurées. État partagé survie-crash
via `<sharedDir>/state/<root>.json`.

### Phase 6 — Capability discovery + LB + HA (proposal, non implémenté)

[`docs/proposals/capability-lb-ha.md`](proposals/capability-lb-ha.md)

Le workflow référence des **actions** abstraites (`encode-video`)
au lieu d'instances. Chaque instance Pollen advertise ses
capabilities + sa charge sous `<sharedDir>/capabilities/<id>.json`
toutes les 5 s. Routage via power-of-two-choices sur `load.inFlight`.
HA via heartbeat staleness + TCP failover. Layer orthogonal à
la Phase 5 — peut être impl indépendamment.

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

## Persistent execution state (Phase 3.5)

Pass `--shared-dir <path>` to every node and they will each write
one record per MESSAGE traversal under
`<path>/executions/<mid>-<role>.json`:

```bash
mkdir -p /tmp/pollen-shared
pollen-node-tcp 7902 --workflow … --node-name xformer --shared-dir /tmp/pollen-shared &
pollen-node-tcp 7903 --workflow … --node-name sink    --shared-dir /tmp/pollen-shared &
pollen-node-tcp 0    --publish 127.0.0.1:7902:x.raw:1:hello

ls /tmp/pollen-shared/executions/
# c760701d-…-xformer.json    ← xformer just emitted c760701d
# c760701d-…-sink.json       ← sink just consumed c760701d
```

Each record schema:

```json
{
  "messageId":       "<mid touched at this hop>",
  "parentMessageId": "<incoming envelope's parent>" /* or null */,
  "role":            "xformer",
  "topicIn":         "x.raw",
  "topicOut":        "x.cooked" /* "" for terminal sink */,
  "nextCount":       1,
  "node":            "127.0.0.1:7902",
  "timestamp":       1779716180474
}
```

Same-mid records from emitter + consumer coexist because the
filename is keyed by `<mid>-<role>` — the emitter just minted that
mid, the consumer just received it. Chain walk: read any record
for X, follow `parentMessageId` back, repeat until null (root
producer was an ephemeral `--publish` and has no node-side
record).

File create uses `O_CREAT|O_EXCL` so a duplicate mid (re-replay,
shouldn't happen given fresh UUIDv4 per hop) silently skips
rather than overwriting.
