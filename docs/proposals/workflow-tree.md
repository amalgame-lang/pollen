# Pollen workflow-tree proposal

> Draft — 2026-05-25
> Status : design, **non-implémenté**. Cible Pollen v0.3+.
> Successeur du workflow.json plat de Phase 3.0 (cf. `docs/WORKFLOW.md`).

## Pourquoi

Le workflow.json actuel (Phase 3.0–3.5) est un DAG statique :
chaque nœud a un `next: [...]` figé, on fait du fan-out vers une
liste de cibles, point. Pas de conditionnel, pas de boucle. C'est
trop pauvre dès qu'on veut router selon le contenu du message
(`if data.kind == "vip"`) ou itérer (`while error and retry < 3`).

Ce proposal remplace `next: [...]` par un **arbre d'exécution**
(`tree`) qui décrit le contrôle de flot — `if`, `while`, `for`,
`sequence`, `fan_out`, `call`. Le tree reste **statique** (figé
dans workflow.json), mais l'évaluation est dynamique : chaque
nœud Pollen embarque le tree complet + un évaluateur, et décide
localement où forwarder en fonction du message reçu et de l'état
partagé.

## Modèle d'exécution

**Décentralisé** (décision utilisateur 2026-05-25, cf.
[[project_pollen_manager]]) :

- Chaque nœud Pollen lit le workflow.json complet au boot.
- À la réception d'un MESSAGE M, le nœud localise sa position
  dans le tree (via le champ `treePath` de M, voir §4), évalue
  la prochaine action, et forward.
- **Pas d'orchestrateur central.** Pollen reste P2P.
- Coût : chaque nœud embarque un évaluateur d'expressions + un
  walker de tree (~500 LOC AM + un peu de C-side pour le hot
  path).

## 1. Schéma workflow.json v2

```json
{
  "name":    "demo-pipeline",
  "version": 2,
  "schema":  "workflow-tree/v1",
  "nodes": [
    {
      "id":       "<uuid>",
      "host":     "192.168.1.10",
      "port":     7902,
      "label":    "xformer-vip",
      "consumes": ["x.raw"],
      "emits":    ["x.cooked"]
    },
    ...
  ],
  "vars": {
    "vipThreshold": 1000
  },
  "tree": <Action>
}
```

### Différences vs. v1 (Phase 3.0)

| v1 | v2 |
|---|---|
| `nodes` est un object `{role: spec}` indexé par nom de rôle | `nodes` est un array, chaque entrée a un `id` UUID propre |
| `next: [...]` dans chaque node | `next` supprimé — remplacé par le `tree` racine |
| Pas de variables globales | `vars` : constantes accessibles via `{"var": "vars.X"}` |
| Pas de schema field | `schema = "workflow-tree/v1"` permet aux nodes de détecter et refuser un workflow trop récent |

### Migration v1 → v2

L'ancien `next: ["xformer", "sink"]` devient :

```json
"tree": {
  "type": "fan_out",
  "nodes": ["<uuid-xformer>", "<uuid-sink>"]
}
```

Un script `tools/migrate-v1-to-v2.sh` génère les UUIDs + recrée
le tree à partir d'un workflow.json v1.

## 2. Action — les nœuds du tree

```jsonc
// Action ::= une des formes suivantes :

// Forward vers UN nœud spécifique
{ "type": "call", "node": "<uuid>" }

// Fan-out vers plusieurs nœuds en parallèle
{ "type": "fan_out", "nodes": ["<uuid>", "<uuid>"] }

// Pipeline : exécute steps[0], puis steps[1], ...
{ "type": "sequence", "steps": [<Action>, <Action>, ...] }

// Branchement
{
  "type": "if",
  "branches": [
    { "cond": <Expr>, "action": <Action> },
    { "cond": <Expr>, "action": <Action> }
  ],
  "else": <Action>           // optionnel
}

// While avec garde anti-runaway obligatoire
{
  "type":     "while",
  "cond":     <Expr>,
  "body":     <Action>,
  "maxIter":  1000           // requis
}

// For-each sur une collection
{
  "type": "for",
  "var":  "item",            // nom de la variable d'itération
  "in":   <Expr>,            // doit évaluer à un array
  "body": <Action>           // body peut référencer {"var": "item"}
}

// Mutation d'état (continue après)
{ "type": "set", "path": "state.X" | "msg.data.X", "value": <Expr> }

// Termine la chaîne (le node sink implicite)
{ "type": "end" }
```

## 3. Expr — expressions

```jsonc
// Littéraux
{ "const": 42 }
{ "const": "hello" }
{ "const": true }
{ "const": null }

// Variables
{ "var": "msg.data.amount" }       // depuis l'envelope courant
{ "var": "state.counter" }         // depuis sharedDir/state
{ "var": "vars.vipThreshold" }     // depuis workflow.json:vars
{ "var": "item" }                  // depuis un for-loop (introduit par `var`)
{ "var": "msg.parentMessageId" }   // métadonnées d'envelope

// Opérateurs binaires
{ "op": "<",  "left": <Expr>, "right": <Expr> }
{ "op": "<=", "left": <Expr>, "right": <Expr> }
{ "op": ">",  "left": <Expr>, "right": <Expr> }
{ "op": ">=", "left": <Expr>, "right": <Expr> }
{ "op": "==", "left": <Expr>, "right": <Expr> }
{ "op": "!=", "left": <Expr>, "right": <Expr> }
{ "op": "+",  "left": <Expr>, "right": <Expr> }
{ "op": "-",  "left": <Expr>, "right": <Expr> }
{ "op": "*",  "left": <Expr>, "right": <Expr> }
{ "op": "/",  "left": <Expr>, "right": <Expr> }

// Booléens variadiques
{ "op": "and", "args": [<Expr>, <Expr>, ...] }
{ "op": "or",  "args": [<Expr>, <Expr>, ...] }
{ "op": "not", "arg":  <Expr> }

// Containment
{ "op": "in", "value": <Expr>, "list": <Expr> }

// Accès indexé (déjà fait par dotted path dans `var`, mais pour
// les indices dynamiques)
{ "op": "index", "container": <Expr>, "key": <Expr> }

// Typages — pour ne pas crasher silencieusement
{ "op": "type_of", "arg": <Expr> }   // "int" | "string" | "bool" | "null" | "array" | "object"
```

## 4. Tree position : `treePath`

> **C'est la décision la plus importante** du proposal, encore à
> trancher. Sans une notion de "où je suis dans le tree", on ne
> peut pas faire de boucle correctement en mode décentralisé.

Chaque MESSAGE envelope gagne un nouveau champ :

```json
{
  "messageId":       "...",
  "parentMessageId": "...",
  "topic":           {"uuid":"...", "version":1},
  "data":            {...},
  "timestamp":       ...,
  "treePath":        "tree.if.branches.0.action.body.1"
}
```

Le `treePath` est une chaîne dotted-path qui pointe l'**action
actuellement en cours** dans le tree. À chaque hop :

1. Le node reçoit M avec `M.treePath = X`.
2. Il évalue l'action à `tree[X]` :
   - Si `call` → forwarder M (avec treePath modifié pour pointer
     vers le sibling suivant ou le parent suivant).
   - Si `if` → évaluer les conds, choisir la branche, mettre à
     jour treePath.
   - Si `while` → évaluer cond, si true → mettre treePath vers
     `body` ; si false → sortir.
   - Si `for` → idem avec compteur d'itération.
3. Le forward suivant porte le treePath mis à jour.

### Pourquoi treePath et pas "node ID match"

Sans treePath, on devrait deviner "à quel endroit du tree je suis"
en regardant juste qui m'a envoyé le msg. Ça marche pour un DAG
simple, mais dès qu'un node apparaît à plusieurs endroits (cas
courant : un node de log appelé partout), c'est ambigu.

### Coût

- ~30–60 bytes par envelope (un chemin court "tree.body.if.0.action")
- Un walker côté node pour résoudre `tree[X]` → ~80 LOC

## 5. Variable scopes (récapitulatif)

| Scope | Source | Persistence | Mutable via `set` |
|---|---|---|---|
| `msg.data.X` | Champ `data` de l'envelope courant | Volatile (perdu si node crash en plein hop) | oui — `set` mute le data du msg en flight |
| `msg.messageId` | Champ messageId de l'envelope | Volatile | non (read-only) |
| `msg.parentMessageId` | idem | Volatile | non |
| `msg.timestamp` | idem | Volatile | non |
| `state.X` | Fichier `<sharedDir>/state/<root-mid>.json` | **Persistante** (survit crash) | oui — `set` réécrit le fichier (lock + atomic rename) |
| `vars.X` | Section `vars` du workflow.json | Immutable au runtime | non |
| `item` | Variable d'itération (loop body) | Volatile | non |

**Choix dev :** une condition qui doit survivre une coupure
électrique → `state.X`. Une condition transitoire (ex. "le data
contient une signature valide") → `msg.data.X`. Les deux peuvent
être combinés dans une même condition.

Le file `<sharedDir>/state/<root-mid>.json` est créé au premier
`set` d'une chaîne. Atomic write : temp file + `rename(2)`. Lock
optionnel via `flock(2)` si deux nodes mutent en parallèle —
mais l'usage typique est qu'un seul node mute à un instant donné
(parce que le treePath sérialise l'exécution).

## 6. Sémantique des boucles

### while

```json
{
  "type": "while",
  "cond": {"op": "<", "left": {"var": "state.iter"}, "right": {"var": "vars.maxAttempts"}},
  "body": {
    "type": "sequence",
    "steps": [
      {"type": "set", "path": "state.iter",
       "value": {"op": "+", "left": {"var": "state.iter"}, "right": {"const": 1}}},
      {"type": "call", "node": "<uuid-retry>"}
    ]
  },
  "maxIter": 1000
}
```

Itération counter persisté dans `state.iter` → survit un crash.
La garde `maxIter` est un seuil hardware indépendant du counter
applicatif : même si l'user oublie d'incrémenter `state.iter`, le
runtime décroche après 1000 itérations et émet une erreur log.

### for

```json
{
  "type": "for",
  "var":  "item",
  "in":   {"var": "msg.data.batch"},
  "body": {"type": "call", "node": "<uuid-handle-one>"}
}
```

Le `in` doit évaluer à un array. Le runtime émet **un MESSAGE par
item** vers le body, en parallèle (fan-out style). L'item est
exposé via `{"var": "item"}` dans le body.

## 7. Évolution depuis Phase 3.x

| Phase | Scope |
|---|---|
| **3.0–3.5** | DAG statique (`next: [...]`), parentMessageId chaining, sharedDir/executions, hot-reload. **Tout shipped.** |
| **4.0–4.4** | Pollen Manager (Mosaic web app) sur le workflow.json v1. Pas encore tree. |
| **5.0** | Schema workflow.json v2 : passage de l'object `nodes` à l'array avec UUIDs + section `vars`. Compat layer qui sait lire les deux. |
| **5.1** | `tree` minimal : `call`, `fan_out`, `sequence`, `end`. Sémantiquement équivalent à v1, prouve que le walker treePath marche. |
| **5.2** | `if` + expressions structurées (`const`, `var`, `==`, `<`, `and`, `or`, `not`). |
| **5.3** | `set` + scope `state.X` + `<sharedDir>/state/<root>.json` persisté. |
| **5.4** | `while` (avec maxIter) + `for`. |
| **5.5** | Pollen Manager v2 UI : édition du tree visuel (par-dessus le workflow.json v2). |
| **5.6** | Migration tool v1→v2. |
| **6.0** | Opérateurs avancés : arithmétiques (`+ - * /`), `in`, `index`, fonctions custom plug-in. |

## 8. Questions ouvertes

1. **Threading runtime AM** : un `for` parallèle a besoin de
   spawner N hops simultanés. Aujourd'hui le worker-per-accept de
   Pollen (Phase 2.2) gère ça côté serveur, mais le côté émetteur
   ne fait qu'un seul forward à la fois. Un fan_out vers 10
   nodes en parallèle au lieu de 10 séquentiels demande de
   re-architecter `_pollen_wf_forward_all` (peut-être en
   thread-pool C).
2. **Backpressure** : si un while produit 1000 hops/s pendant 60s,
   le sharedDir/executions/ explose (60000 fichiers). À voir si on
   garbage-collect les records terminés ou si on les compacte
   dans un binaire.
3. **Erreurs** : aujourd'hui un node qui rejette un msg (NACK ou
   timeout) tue silencieusement la chaîne. Avec un `try/catch`-
   like dans le tree, on pourrait router vers un branch d'erreur.
   À spécifier dans un proposal séparé.
4. **Sécurité expressions** : un `state.X` injecté par un node
   compromis peut affoler un `while` → DoS. Whitelist d'ops ?
   Limite de profondeur d'évaluation ?
5. **Versioning runtime** : un node v1 reçoit un msg avec
   treePath → il doit refuser proprement. Le `schema` field
   permet de détecter au boot, mais pendant un rolling deploy on
   peut avoir des msgs v2 qui arrivent à un node v1. Stratégie
   d'incompat à définir.

## 9. Open work

Avant impl, on tranche en compagnie :

- [ ] Format du `treePath` (dotted-path ? array d'indices ?)
- [ ] Format de `state.X` (un seul fichier par root-mid ?
      Ou un fichier par variable ?)
- [ ] Comportement si un `if` n'a aucune branche qui matche et
      pas de `else` (erreur ? skip ? fallback à `end` ?)
- [ ] Atomicity du `set state.X` cross-node : flock + rename
      suffisent localement, mais sur NFS le rename est plus
      subtil. Décision : v5.3 ship sans cross-NFS guarantee, on
      ajoute si besoin réel
- [ ] Ordering : pour `fan_out`, les ACKs reviennent dans quel
      ordre ? On bloque jusqu'à tous reçus ?

## 10. Notes de design

Le choix décentralisé fait que **chaque node est un mini-orchestrateur
sur sa portion** du tree. Avantage : zero SPOF, on garde l'esprit
Pollen P2P intact. Coût : la complexité opérationnelle migre
dans le node lui-même, et le `pollen-node-tcp` binary grossit
mécaniquement (eval expressions + tree walker).

Le `Pollen Manager` (Phase 4.x) reste **un éditeur**, pas un
runtime — même s'il pourrait éventuellement devenir aussi un
observateur du sharedDir/state pour offrir une visualisation
temps réel des `state.X` actuels.
