# Pollen capability + LB + HA proposal

> Draft — 2026-05-25
> Status : design, **non-implémenté**. Cible Pollen v0.4+ (Phase 6).
> Layer **orthogonal** au workflow-tree (Phase 5, cf.
> `workflow-tree.md`) — peut être implémenté indépendamment.

## Pourquoi

Aujourd'hui (Phase 3.x shipped) et même dans le proposal tree
(Phase 5), un node Pollen est référencé par UUID figé. Un seul
process implémente un rôle. Si on déploie 3 workers identiques
qui savent tous `encode-video`, le workflow.json doit nommer les
3 explicitement et l'opérateur doit choisir.

Ce proposal introduit une couche d'**abstraction d'action** :
- Le workflow déclare des **actions** (concept logique)
- Chaque instance Pollen annonce les actions qu'elle implémente
  (concept physique)
- Le runtime résout `action → instance` au moment de chaque hop,
  en équilibrant la charge entre les candidats vivants

Résultat : LB + HA "gratuit" pour tout workflow.

## 1. Le découplage Action ↔ Instance

```
┌─ workflow.json ──────────────────────────────────┐
│   actions: [                                     │
│     { id: "encode-video",                        │
│       params: { bitrate: 4500, preset: "fast" } },│
│     { id: "send-email", params: {…} }            │
│   ]                                              │
│   tree: { type: "call", action: "encode-video" } │
└──────────────────────────────────────────────────┘
                       ↓
┌─ Capability registry (mémoire, par instance) ────┐
│   "encode-video" → [ worker-3 (load=3),          │
│                      worker-7 (load=12),         │
│                      worker-9 (STALE, ignoré) ]  │
└──────────────────────────────────────────────────┘
                       ↓
                    LB algo
                       ↓
                  forward TCP
                  (avec failover si échec)
```

**Le workflow.json ne nomme plus jamais d'instance.** Aucune
référence à un host:port ou un uuid d'instance dans le tree.
Le `pin` (§5) est l'unique mécanisme de forçage.

### Migration

L'ancien `{type:"call", node:"<uuid>"}` de Phase 5.1 devient
`{type:"call", action:"<role-name>"}` après un script qui :
1. Récupère le `label` de chaque node
2. Réécrit chaque `node:` du tree en `action:` avec le label
3. Crée la section `actions` à partir des `consumes`/`emits`/labels

Compat layer : un node Phase 6 qui reçoit un workflow.json où
`tree` utilise `node:` (Phase 5) le résout en cherchant
l'instance dont `instanceId == node`, sans LB. Permet rolling
upgrade sans bigbang.

## 2. Schéma workflow.json v3 (additions)

```json
{
  "schema": "workflow-tree/v2",
  "actions": [
    {
      "id":       "encode-video",
      "label":    "Encode video to MP4 4500kbps",
      "consumes": ["video.raw"],
      "emits":    ["video.encoded"],
      "params":   { "bitrate": 4500, "preset": "fast" },
      "timeout":  30000
    },
    {
      "id":       "send-email",
      "params":   { "from": "noreply@…", "templateId": "welcome" },
      "timeout":  5000
    }
  ],
  "vars": { … },
  "tree": <Action>
}
```

Les `consumes`/`emits` migrent du node (Phase 3.x) vers
l'**action** (Phase 6). C'est l'action qui définit son contrat
d'entrée/sortie ; toute instance qui revendique l'action doit
respecter ce contrat.

`params` sont injectés dans le `msg.data._params` quand le tree
exécute l'action. L'instance les lit pour configurer son
traitement (bitrate, etc.).

`timeout` (ms) : si l'action ne renvoie pas d'ACK dans ce délai,
le runtime considère l'instance morte et failover (cf. §6).

## 3. Capability advertisement

Chaque instance écrit périodiquement (toutes les 5s par défaut) :

```json
// <sharedDir>/capabilities/<instanceId>.json
{
  "instanceId":  "8f7a6b5c-…",
  "host":        "192.168.1.10",
  "port":        7902,
  "label":       "worker-3",        // human-readable, pin par label
  "actions":     ["encode-video", "decode-video", "send-email"],
  "load": {
    "encode-video": {
      "inFlight":       3,           // primaire pour LB
      "lastMinuteMsgs": 124,
      "p99Ms":          230,
      "errorRate1m":    0.02
    },
    "decode-video": {
      "inFlight": 0, "lastMinuteMsgs": 0, "p99Ms": 0, "errorRate1m": 0
    },
    "send-email": {
      "inFlight": 1, "lastMinuteMsgs": 18, "p99Ms": 85, "errorRate1m": 0
    }
  },
  "system": {                        // signaux secondaires, optionnels
    "cpuPct":  42.1,
    "memPct":  18.3,
    "uptimeS": 86400
  },
  "heartbeat": 1779716180474,        // ms epoch, requis
  "version":   "v0.2.0-dev"
}
```

### Write side (chaque instance)

- Boucle dédiée (thread léger via `Threading.ThreadSpawn`) :
  toutes les 5s, écrit son capability file atomic
  (tmp + rename).
- inFlight : compteur atomique incrementé sur ACK envoyé,
  décrémenté sur ACK reçu en réponse upstream (ou timeout).
- lastMinuteMsgs : ring buffer 60 buckets de 1s.
- p99Ms : t-digest ou histogramme HDR pauvre (32 buckets log).
- cpuPct/memPct : lu de `/proc/self/stat` + `/proc/meminfo`.

### Read side (chaque instance)

- Boucle dédiée : toutes les 2s, scan
  `<sharedDir>/capabilities/*.json`, parse, vérifie
  `heartbeat > now - 15s` (3× période d'écriture), filtre les
  staled, reconstruit le registry action → [instances].
- Threshold 3× est conservateur : tolère une instance dont le
  thread d'écriture a buffer-stall une fois sans la déclarer
  morte.

## 4. Routing : Power-of-two-choices

Quand le tree atteint `{type:"call", action:"encode-video"}` :

```
candidates = registry["encode-video"]
candidates = filter(alive, candidates)   # heartbeat frais
if pin: candidates = filter(pin, candidates)  # voir §5

if len(candidates) == 0: return ERROR_NO_PROVIDER
if len(candidates) == 1: target = candidates[0]
else:
    # Power-of-two-choices (Mitzenmacher 2001) — évite les herd
    # effects du least-loaded, marche bien avec un registry
    # potentiellement stale de quelques secondes.
    a, b = random_two(candidates)
    target = a if a.load.inFlight <= b.load.inFlight else b

# Failover (§6)
for attempt in 1..3:
    result = forward_tcp(target, msg, timeout=action.timeout)
    if result == OK: return
    candidates.remove(target)
    if len(candidates) == 0: return ERROR_ALL_FAILED
    target = pick_again(candidates)
```

### Score function

Score par défaut = `load.inFlight`. Les autres métriques
(p99Ms, cpuPct, errorRate1m) sont **observabilité** pas LB —
elles alimentent le Pollen Manager dashboard mais n'influencent
pas le pick.

Pourquoi pas combiner ? Parce qu'un score multi-critère
introduit des coefficients à tuner (`0.3 * inFlight + 0.5 * p99 +
0.2 * cpu`). Power-of-two sur inFlight seul est robuste, simple,
et marche bien dans 95% des cas. Si un user veut un score
custom, c'est une extension Phase 6.x via une fonction AM
plug-in.

## 5. Pin override

```json
{ "type": "call", "action": "encode-video" }                              // LB pur
{ "type": "call", "action": "encode-video", "pin": { "host": "worker-3" } }
{ "type": "call", "action": "encode-video", "pin": { "instanceId": "<uuid>" } }
{ "type": "call", "action": "encode-video", "pin": { "label": "worker-vip" } }
{ "type": "call", "action": "encode-video", "pin": { "host": "worker-3", "port": 7902 } }
```

Sémantique :
- Le pin est un **filtre** appliqué AVANT le power-of-two.
- Si le filtre laisse 1 candidat → forward direct (pas de LB).
- Si plusieurs candidats matchent le filtre → power-of-two sur le
  sous-ensemble.
- Si 0 candidat → `ERROR_PIN_NOT_FOUND` (pas de fallback sur le
  pool global — le pin est strict, c'est l'intention de
  l'utilisateur).

Cas d'usage :
- `pin.host = "gpu-rack-1"` → forcer une famille de machines
- `pin.instanceId = ...` → tests reproductibles
- `pin.label = "primary"` → master/follower-style routing

## 6. Failure detection : heartbeat + TCP failover

### Couche 1 : heartbeat staleness (filtre)

Une instance dont `heartbeat < now - 15s` (3× période) est
exclue du registry à la prochaine refresh. Robuste,
NAT/firewall-friendly, mais peut avoir un retard de 15s sur la
réalité.

### Couche 2 : TCP failover (réactif)

Au moment du forward :
- Si `connect()` échoue (ECONNREFUSED, EHOSTUNREACH) :
  retry immédiat avec le 2e meilleur candidat.
- Si `connect()` OK mais pas d'ACK avant `action.timeout` :
  abort, retry avec le 2e candidat.
- Max 3 tentatives. Si toutes échouent → propage
  `ERROR_ALL_FAILED` en amont (devient un NACK).

Quand le TCP failover triggert, on **invalide proactivement** le
heartbeat de l'instance défaillante en l'écrasant avec un
`{ ..., "force_stale": true }` (autre instance peut le faire si
elle a un write access au sharedDir/capabilities/ — décidé en
§9). Évite que les autres instances tombent sur la même morte
pendant les 15s suivants.

## 7. Capability registry — data structure

En mémoire dans chaque instance Pollen (mis à jour toutes les 2s) :

```
action_id → [
    { instanceId, host, port, label, load, heartbeat },
    { instanceId, host, port, label, load, heartbeat },
    ...
]
```

C-side : `_pollen_registry_actions[POLLEN_MAX_ACTIONS]`, chaque
entrée = `{ char id[64]; int n_providers; PollenProvider providers[POLLEN_MAX_PROVIDERS_PER_ACTION]; }`.
Lock-free read (le hot path consulte sans contention) ; le
refresh thread fait l'atomic swap d'un pointer.

Sizing par défaut : 64 actions × 32 providers chacune = 2048
entrées max. Suffisant pour 95% des cas.

## 8. Métriques publiées — sources

| Champ | Source | Méthode |
|---|---|---|
| `load.inFlight` | Compteur atomic local | `atomic_fetch_add(&inflight[action], 1)` à la réception, `-1` à l'ACK |
| `load.lastMinuteMsgs` | Ring buffer 60 buckets | Boucle 1Hz pousse un bucket, somme tout |
| `load.p99Ms` | HDR histogramme | `hdr_record(now - msg_received_at_ms)` au moment de l'ACK |
| `load.errorRate1m` | Ring buffer (err, total) | idem lastMinute mais avec succès/échec |
| `system.cpuPct` | `/proc/self/stat` | Diff utime+stime entre 2 reads / élapsed |
| `system.memPct` | `/proc/self/status` (VmRSS) + `/proc/meminfo` (MemTotal) | Ratio |
| `system.uptimeS` | Local clock | `now - boot_time` |

## 9. Questions ouvertes

1. **Ecriture concurrente sharedDir/capabilities/`<id>`.json** :
   chaque instance n'écrit QUE son propre file → pas de race.
   Mais §6 propose qu'une autre instance écrive
   `force_stale=true` sur le file d'un mort — soit on accepte le
   race, soit on a un sous-dir séparé `<sharedDir>/dead/<id>`
   où n'importe qui peut signaler une mort.

2. **NFS / SMB cross-host** : le polling 2Hz sur un sharedDir
   distant fait ~20 IOPS × N instances. Pour 50 instances, 1000
   IOPS soutenues. NFS le gère, SMB aussi, mais à vérifier sur
   le déploiement cible (latency cluster vs WAN-share).
   Alternative : SYNC TCP packets push au lieu de polling pull.

3. **Bootstrap** : la première instance qui démarre voit un
   capabilities/ vide. Elle s'auto-déclare. La 2e voit la 1ère.
   Pas de chicken-and-egg. Mais si une instance a une dep "action
   X obligatoire pour démarrer", on a un deadlock si X n'est pas
   encore là. Workaround : timeout de bootstrap qui passe en
   mode dégradé après 30s.

4. **Cleanup des morts** : un capability file dont `heartbeat`
   est vieux de 1h reste sur disque. Garbage collection
   périodique (toutes les heures) — qui le fait ? Tous les nodes
   en parallèle (idempotent) ou un nœud désigné ? Décision §6
   utilise des écritures opportunistes, donc tous peuvent GC,
   c'est idempotent.

5. **Action versioning** : si l'action `encode-video` change son
   contrat (params différents), comment gérer un pool mixte
   v1+v2 ? Mettre `encode-video@v1` vs `encode-video@v2` comme
   ids distincts ? Ou un field `actionVersion` dans le
   capability file que le tree filtre ?

6. **Sécurité** : n'importe qui qui a write access au sharedDir
   peut s'auto-déclarer comme provider d'`encode-video` et
   recevoir des messages sensibles. Faut-il une signature
   crypto des capability files ? Phase 7+.

7. **Multi-tenant** : un sharedDir partagé entre plusieurs
   workflows (par ex. dans une org) — comment isoler les
   actions ? Namespace dans l'action id (`team-a/encode-video`)
   ou sub-dir `<sharedDir>/<workflow-name>/capabilities/` ?

## 10. Roadmap d'implémentation Phase 6

| # | Scope |
|---|---|
| 6.0 | Schéma actions[] dans workflow.json + migration tool depuis le tree Phase 5 |
| 6.1 | Capability file writer (thread 5Hz, atomic rename), inFlight counter, structure registry C-side |
| 6.2 | Capability registry reader (thread 2Hz, scan + parse + filter staled) |
| 6.3 | LB resolver : action → registry → power-of-two-choices → forward target |
| 6.4 | Pin override (host / instanceId / label filter avant LB) |
| 6.5 | TCP failover : retry-with-other au timeout/refused, opportunistic stale-mark |
| 6.6 | Métriques complètes : lastMinuteMsgs (ring), p99Ms (HDR), errorRate, cpu/mem |
| 6.7 | Pollen Manager v3 UI : dashboard live des capabilities + drag-and-drop assignment d'actions aux instances |
| 6.8 | SYNC push optionnel pour cluster cross-WAN (alternative au polling NFS) |

## 11. Dependencies cross-proposal

| Bloque | Sur |
|---|---|
| Phase 6.0 | Phase 5.0 (schema v2 du workflow-tree) — le `tree` doit exister pour qu'on y mette `action:` au lieu de `node:` |
| Phase 6.4 (pin label) | nothing (label est juste un string dans capability file) |
| Phase 6.5 (failover) | Phase 5.3 (state.X persistance) — si une action mute du state.X et failover en cours d'écriture, il faut un mécanisme de rollback. Probablement : state.set est idempotent par messageId, donc OK. Mais à vérifier. |
| Phase 6.7 (UI) | Phase 4.x Pollen Manager opérationnel (bloqué par bug multi-source build) |

## 12. Net effect sur Pollen

Après Phase 6 :
- Pollen reste **P2P** : pas d'orchestrateur central.
- Chaque instance reste **autonome** : décide elle-même où
  forwarder.
- LB **émergent** : pas configuré, pas de fichier `lb.conf` —
  juste la mécanique discovery + power-of-two.
- HA **émergent** : ajoute une instance → elle s'auto-déclare,
  les autres la voient au prochain refresh, le trafic se rebalance.
- Toujours **zéro SPOF** : sharedDir est partagé mais lecture
  seule pour la majorité des opérations ; l'écriture est juste
  son propre file.

Pollen devient ~équivalent à : NATS JetStream consumers, Kafka
consumer-groups, Temporal task queues — mais **sans serveur**,
juste avec un sharedDir.
