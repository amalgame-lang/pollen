# Pollen debug-stepper proposal

> Draft — 2026-05-25
> Status : design, **non-implémenté**. Cible Pollen v0.4 / Pollen
> Manager 4.5+. Successeur du sharedDir/executions/ post-hoc audit
> (Phase 3.5) — ajoute un step-through **live** à travers le DAG.

## Pourquoi

Aujourd'hui on peut auditer après coup (post-hoc) via les
records `executions/<mid>-<role>.json`. Mais on ne peut pas :
- **Suspendre** un message en vol pour inspecter son state
- **Step-through** un workflow hop-par-hop comme dans un debugger
- **Conditionner** la suspension sur un nœud ou une condition
  (breakpoint)

L'idée : trois modes opérationnels au niveau du message.

## 1. Les trois modes

```
   Normal         Debug step          Debug breakpoint
   ──────         ──────────          ────────────────
                                        bp@xformer
                                            ▼
   ●─►●─►●         ●⏸️●⏸️●⏸️             ●─►●⏸️●⏸️
                  step step              auto bp step
```

| Mode | Comportement | Use case |
|---|---|---|
| **normal** | Le hot path Phase 2.4 d'aujourd'hui : MESSAGE → ACK → forward. Aucune pause. | Production. |
| **debug step** | À chaque hop le node pause, phone home au Manager, attend un signal "step" avant de forwarder. | Inspection complète d'un msg du début à la fin. Lent. |
| **debug breakpoint** | Le node ne pause QUE si son rôle (ou topic ou condition) est dans la liste des breakpoints courants. Sinon, comportement normal. Une fois un breakpoint atteint, le reste de la chaîne passe automatiquement en mode `step`. | "Stop quand encode-video est appelé". Comme un debugger classique. |

Le mode est **par-message**, pas par-node. Pollen continue à
servir le trafic prod en parallèle d'une session de debug — seuls
les messages explicitement marqués debug sont affectés.

## 2. Envelope enrichi

```jsonc
{
  "messageId":       "...",
  "parentMessageId": "...",
  "topic":           { "uuid":"sensor.raw", "version":1 },
  "data":            { ... },
  "timestamp":       1779730000000,

  // NEW : debug field, optional. Absent → mode normal.
  "debug": {
    "session": "<uuid>",        // ID de la session debug
    "mode":    "step",          // "step" | "breakpoint"
    "breakpoints": [             // utilisé seulement en mode="breakpoint"
      { "role": "xformer" },
      { "role": "audit" }
    ],
    "hit_bp": false              // false jusqu'au premier hit en mode "breakpoint",
                                  // puis true → derniers hops en step auto
  }
}
```

Le champ `debug` se propage à chaque hop (réécrit dans
l'envelope rebuild de Phase 3.4) jusqu'au sink terminal.

## 3. Wire protocol pause ↔ step

Quand un node Pollen reçoit un MESSAGE avec `debug` et doit
pauser (selon le mode + bp list), il :

1. **ACK upstream** comme d'habitude (pour ne pas timeout
   l'émetteur) — il a bien reçu, il prend juste son temps.
2. **Ouvre une connexion TCP** vers le Manager déclaré dans
   l'env de la session (cf. §4).
3. **Envoie** un JSON `DEBUG_PAUSE` :
   ```json
   {
     "type":      "DEBUG_PAUSE",
     "session":   "<uuid>",
     "messageId": "<incoming mid>",
     "role":      "xformer",
     "topicIn":   "sensor.raw",
     "topicOut":  "sensor.cooked",
     "next":      ["sink","audit","alerts"],
     "data":      { ... payload ... },
     "treePath":  "..."           // si Phase 5 tree shipped
   }
   ```
4. **Bloque** en attente d'une ligne de réponse du Manager :
   - `{"type":"DEBUG_STEP"}` → forward au prochain hop, repause si
     le mode l'exige.
   - `{"type":"DEBUG_CONTINUE"}` → forward et désactive le debug
     pour ce message (les hops downstream redeviennent normaux).
   - `{"type":"DEBUG_MUTATE","data":{...}}` → réécrit `msg.data`
     avec le nouveau payload avant de forward. Permet à
     l'opérateur de réinjecter avec un état modifié.
   - `{"type":"DEBUG_CANCEL"}` → drop le message, ne forward pas.
   - timeout (default 60s) → assume `CANCEL`, log la perte.
5. **Resume** : selon la réponse, forward ou drop.

Côté Manager :
- Endpoint `/api/debug/listen` : un TCP serveur (port séparé de
  HTTP/1.1, par exemple 3001) qui accepte les connexions
  `DEBUG_PAUSE` entrantes.
- WebSocket vers le browser pour push les events de pause +
  recevoir les commandes step/continue/etc.
- Side panel UI : "Debug session running" avec controls Step,
  Continue, Cancel, et un éditeur du payload pour Mutate.

## 4. Démarrer une session

L'opérateur veut tester avec un workflow donné. Deux entry points :

**Producer side (CLI)** — l'utilisateur publie un msg debug
explicitement :

```bash
pollen-node-tcp 0 --publish 127.0.0.1:7902:sensor.raw:1:hello \
    --debug step \
    --debug-manager 127.0.0.1:3001 \
    --debug-session $(uuidgen)
```

L'envelope sortante contient `debug: {session, mode: "step",
manager: "127.0.0.1:3001"}` (le `manager` field est nécessaire
pour que les nodes downstream sachent où phone home, voir §5).

**Manager UI side** — bouton "Inject debug message" dans
l'inspector : l'opérateur sélectionne un node de départ, choisit
mode + breakpoints, click "Start". Le Manager forge l'envelope,
ouvre une TCP au node de départ, envoie le MESSAGE flaggué debug.

## 5. Adresse Manager : 3 options

Le node Pollen doit savoir où phone home quand il pause. 3 façons :

**(a) Dans le debug field de l'envelope** :
```json
"debug": { "session":"...", "mode":"step", "manager":"192.168.1.10:3001" }
```
Avantage : self-contained, le Manager n'a pas besoin de configurer
les nodes au préalable. Désavantage : tout node qui reçoit ce msg
peut connecter à l'IP fournie — risque d'injection si un node
malveillant injecte un debug avec un faux manager (Phase 7
sécurité).

**(b) Env var au boot du node** :
```bash
pollen-node-tcp --debug-manager 192.168.1.10:3001 ...
```
Avantage : config opérateur, pas une URL dans le wire. Désavantage :
chaque node doit être lancé avec la bonne adresse → friction.

**(c) Discovery via sharedDir** :
```
<sharedDir>/debug-manager.txt   ← contient "host:port"
```
Avantage : aucun arg, aucun field dans le wire. Le Manager écrit
ce fichier au démarrage. Désavantage : ajoute un layer de
discovery.

**Recommandation** : (a) avec validation : le Manager publie une
clé crypto signée au startup (Phase 7), les nodes vérifient la
signature de l'adresse `manager` dans l'envelope. Pour Phase
4.5 ship-now, (a) en mode trust-the-network suffit.

## 6. Breakpoints — schéma

```jsonc
"breakpoints": [
  { "role": "xformer" },                    // pause when this role processes
  { "topic": "sensor.cooked" },             // pause on consume of this topic
  { "messageId_prefix": "abcd1234" },        // pause on messages matching uuid
  {                                          // conditional (Phase 5+)
    "role": "xformer",
    "when": { "op": ">", "left": {"var": "msg.data.amount"}, "right": {"const": 1000} }
  }
]
```

Pour la première impl Phase 4.5 : **`role` uniquement**. Les autres
restent dans le schema pour évolution future. Conditions
dépendent de Phase 5 tree expressions.

Sémantique :
- En mode `step`, breakpoints ignorés (chaque hop pause).
- En mode `breakpoint`, pause uniquement si le node match au
  moins un breakpoint actif. Sinon, pas de phone home — le hot
  path d'aujourd'hui s'exécute.
- Au premier breakpoint atteint, `hit_bp` passe à `true` dans
  l'envelope. Tous les hops suivants pausent (devient step
  automatique) — c'est le pattern classique de debugger.

## 7. UI Manager — Phase 4.5

Nouveau panneau "Debug session" qui apparaît quand une session
est active. Sous le DAG, à côté du panel Live :

```
┌─ Debug session ─────────────────────────────────┐
│ ▶ Inject debug msg from [producer ▾]            │
│   Mode : ( ) step  (•) breakpoint               │
│   Breakpoints : [ xformer ] [+ add bp]          │
│   [ Start session ]                              │
│                                                  │
│ Active : sess-7a9f-... · paused at xformer      │
│ ┌────────────────────────────────────────────┐  │
│ │ Hop info                                    │  │
│ │   role:     xformer                         │  │
│ │   mid:      72df1289...                     │  │
│ │   topic:    sensor.raw → sensor.cooked      │  │
│ │   data:     { "value": 42, "ts": ... }      │  │
│ │   [Edit data]                               │  │
│ └────────────────────────────────────────────┘  │
│ [ Step ] [ Continue ] [ Cancel ]                │
└─────────────────────────────────────────────────┘
```

Le DAG montre :
- Le node actuellement paused → glow accent + animation "pulse"
- Les nodes déjà traversés → background plus clair, badge "✓ done"
- Les nodes pas encore atteints → background normal

Breakpoint toggle : right-click sur un node → menu "Toggle
breakpoint", ou icone dans l'inspector.

## 8. Roadmap d'implémentation

| Phase | Scope |
|---|---|
| **4.5.0** | Ce proposal. |
| **4.5.1** | Wire schema : `debug` field dans l'envelope. Le hot path C reconnaît le flag, ne fait rien encore. Ship-clean (pas de pause). |
| **4.5.2** | Pollen : pause + phone-home en mode `step`. C-side via @c block ouvre TCP au manager, envoie DEBUG_PAUSE, blocque sur recv. |
| **4.5.3** | Manager : TCP server sur :3001 (séparé de :3000 HTTP). Reçoit DEBUG_PAUSE, push événement via WebSocket vers le browser. Browser → Manager → renvoie DEBUG_STEP au socket en attente. |
| **4.5.4** | Mode `breakpoint` : Pollen filtre par role contre la bp list avant de pauser. |
| **4.5.5** | UI : panel Debug, controls Step/Continue/Cancel, visualisation DAG des hops traversés. |
| **4.5.6** | `DEBUG_MUTATE` : éditeur de payload dans l'UI, réinjection avec nouveau data. |
| **4.5.7** | Right-click sur le DAG → toggle breakpoint sur un node. |
| **4.5.8** | Session timeout + cleanup (60s sans réponse → cancel auto). |
| **4.6** | Breakpoints conditionnels (dépend Phase 5 tree expressions). |
| **4.7** | Sécurité : signature Manager + auth des connexions debug (Phase 7-like). |

## 9. Questions ouvertes

1. **Threading dans Pollen** : aujourd'hui un worker-per-accept
   thread bloque pendant le ACK + forward. Si on pause 60s en
   debug, on bloque ce thread 60s. Pour la prod où d'autres
   messages arrivent en parallèle, c'est OK (worker-per-accept
   alloue un thread frais à chaque conn). Mais à valider que la
   conn TCP entrante reste healthy pendant qu'on attend le step
   du Manager.

2. **Phone-home retry** : si le Manager n'écoute pas (crashé,
   déco), le node attend timeout (60s) et cancel le msg. Faut-il
   un retry-with-backoff ? Probablement non — debug ≠ prod, on
   préfère un fail-fast.

3. **Inter-Manager** : si plusieurs Managers ouverts simultanément
   et que chacun démarre une session debug, chaque envelope debug
   va à son Manager d'origine (via le field `manager` dans
   l'envelope). Pas de partage. Suffit.

4. **Persistance de la session** : la session vit en RAM côté
   Manager. Crash Manager → session perdue → nodes paused
   timeout → cancel auto. Acceptable.

5. **Records executions/** : pendant une session debug, les nodes
   continuent d'écrire dans executions/ ? Probablement oui — la
   session est visible dans le log d'audit. À confirmer.

6. **Reverse-step / rewind** : pas implémenté. Une fois un hop
   passé, on ne peut pas revenir. Possible à terme via replay
   depuis le record stocké, mais distinct du live-debug.

7. **MUTATE conflicte avec parentMessageId** : si on réécrit
   `data`, le record `executions/<mid>-<role>.json` du hop
   suivant aura les nouvelles données. La chaîne parent reste
   valide (par messageId). À noter dans la doc.

## 10. Liens

- Aujourd'hui : `docs/WORKFLOW.md` + `docs/proposals/workflow-tree.md`
  (Phase 5) + `docs/proposals/capability-lb-ha.md` (Phase 6)
- Modes inspirés des debuggers IDE classiques (gdb, lldb, VS Code)
- Phase 4.5 vit dans `amalgame-lang/pollen-manager` (UI) +
  `amalgame-lang/pollen` (runtime support dans pollen-node-tcp)
- Côté UI : la version (a) post-hoc replay (zéro change Pollen)
  reste utile en complément et peut shipper en parallèle.
