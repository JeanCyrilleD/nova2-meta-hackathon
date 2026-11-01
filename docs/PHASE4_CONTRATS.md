# Phase 4 — contrats d'interface avec les Phases 2 et 3 (31/10/2026, v2)

> **v2 (31/10, après la décision d'Ahadi de 19:51)** : l'écran Approbations lit le contrat **réel** de la branche `phase-3`
> (§0 ci-dessous, vérifié dans `Sources/NovaCore/AgentsV2.swift`). Le format v1 (§1) reste celui du **simulateur** et la cible
> proposée si la Phase 3 ajoute un flux d'évènements. Coûts : la branche `phase-2` n'expose **aucune** route HTTP (§2).

## 0. Contrat RÉEL de la Phase 3 (branche phase-3, `AgentsV2.swift`) — consommé par `web/js/tasks-feed.js`
| Route | Réponse / corps | Comportement de l'interface |
|---|---|---|
| `GET /api/agents2` | `{ ok, enabled, agents:[{id,label,capMicros,maxSteps,…}], tasks:[{id, agent, state, dataClass, content, contentSha256, approved, spentMicros, reason, createdAt, steps:[{tool,status,attempts,receipt}]}] }` | `enabled:true` → données réelles, relues toutes les 4 s (pas de SSE côté Phase 3) ; `enabled:false` (réglage `agents_v2` faux, défaut), 403, 404 ou erreur → **simulateur annoncé** |
| `POST /api/agents2/approve` | `{ id, sha256 }` + en-tête `x-nova-provenance: window.__novaProv` ; 409 `modifie_depuis_apercu` si le contenu a changé | bouton Approuver ; `sha256` = `contentSha256` affiché ; sans `__novaProv` rien n'est envoyé |
| `POST /api/agents2/cancel` | `{ id }` | bouton Annuler |
| (pas de route d'édition) | — | « Modifier » n'est proposé qu'en simulé |
Correspondance : `fromAgents2()` (tasks-feed.js) — `steps[].status` pending/started/done/failed → brouillon/en cours/terminée/échec ;
reçu = dernier `receipt` non vide (jamais inventé) ; plafond et étapes max lus dans la spec de l'agent. Test : `node tools/ui/test_tasks_feed.mjs`.


L'interface consomme ces formats. Tant qu'une route répond 404, l'écran affiche un jeu **simulé, annoncé en tête** (« Données
simulées … ») et ses boutons n'envoient rien. Argent : **micro-dollars entiers** (1 USD = 1 000 000), jamais de flottant.

## 1. Format v1 (simulateur ; cible proposée pour un futur flux Phase 3)

### Instantané : `GET /api/tasks?active=1`
```json
{ "tasks": [ {
  "id": "t-…", "agent": "Mail", "title": "Réponse à Mariam", "state": "awaiting_approval",
  "profile": "main", "data_class": "personal", "cap_usd_micro": 750000, "steps_max": 6, "deadline": "2026-11-01T10:00:00Z",
  "spent_usd_micro": 8532, "estimated_usd_micro": 0, "reserved_usd_micro": 30000, "last_seq": 4, "updated_at": "…",
  "steps": [ { "seq": 2, "at": "…", "kind": "step", "label": "Lecture du fil", "state": "running",
               "model": "claude-haiku-5-5", "profile": "triage", "cost": { "usd_micro": 412, "actual": true } } ],
  "approval": { "content_preview": "…texte exact montré…", "content_sha256": "hex", "destination": "mariam@… (Gmail)",
                "data_leaving": ["texte du brouillon", "adresse"], "estimated_usd_micro": 0 },
  "receipt": null } ] }
```
`state` ∈ `draft · awaiting_approval · running · verifying · done · failed · cancelled · paused · unknown` (autre valeur → `unknown`).
« done » n'est montré comme tel qu'avec `receipt` (ex. ID de message).

### Flux : évènement SSE nommé `task` sur `/api/events` (flux partagé, `bus.on("task", …)`)
```json
{ "v": 1, "task_id": "t-…", "seq": 5, "at": "2026-10-31T18:41:03Z", "kind": "step",
  "state": "running", "label": "Rédaction du brouillon", "model": "claude-sonnet-5-5", "profile": "main",
  "cost": { "usd_micro": 8120, "actual": true }, "reserved_usd_micro": 30000 }
```
- `kind` : `created` (porte agent, title, profile, data_class, cap_usd_micro, deadline, steps_max) · `step` · `approval_requested`
  (porte `approval`) · `approval_granted` · `approval_cleared` · `receipt` (porte `receipt`) · `cancelled` · `error` (porte `error`).
- `seq` strictement croissant **par tâche** : un évènement de `seq` ≤ dernier connu est ignoré (rejeu idempotent après reconnexion).
- `cost.actual=false` = estimation (affichée « ≈ … estimé »), `true` = usage rapporté par le fournisseur.
- Tout évènement qui fait quitter `awaiting_approval` efface l'approbation affichée.
- Aucun pourcentage n'est attendu ni affiché.

### Actions (l'écran les envoie ; la Phase 3 répond puis émet l'évènement qui fait foi)
| Route | Corps | Règle |
|---|---|---|
| `POST /api/tasks/{id}/approve` | `{ "content_sha256": "…" }` | refuser si l'empreinte ne correspond plus au contenu en attente |
| `POST /api/tasks/{id}/edit` | `{ "content": "…" }` | la tâche revient en `draft` ; nouvelle approbation sur le nouveau SHA-256 |
| `POST /api/tasks/{id}/cancel` | `{}` | état `cancelled` |

Tests : `node tools/ui/test_tasks_feed.mjs` (réducteur sur le script simulé ; rejeu ; état inconnu ; pas de pourcentage).

## 2. Grand livre des coûts (Phase 2) — écran « Coûts » (`modules/couts.js`), alerte de coût des profondeurs (`depth.js`)

**Vérifié le 31/10 dans la branche `phase-2`** (`CostLedger.swift`, `RoutingV2.swift`, `docs/ROUTAGE_V2.md`) : aucune route HTTP
n'expose le grand livre ; seule une fonction `RoutingV2.status()` (engagé du mois, plafond, prix > 30 jours) existe côté Swift. L'écran
Coûts reste donc sur son **jeu simulé annoncé**, et l'alerte de coût sur les prix du brief (datés). Route proposée à la Phase 2 :

### `GET /api/costs/summary`
```json
{ "month": "2026-10", "timezone": "UTC",
  "cap_usd_micro": 125000000, "planned_usd_micro": 110000000, "spent_usd_micro": 41270000, "reserved_usd_micro": 480000,
  "alert_thresholds_pct": [50, 80, 95],
  "by_profile": [ { "profile": "main", "spent_usd_micro": 17900000, "calls": 412 } ],
  "by_model":   [ { "model": "claude-sonnet-5-5", "provider": "anthropic", "spent_usd_micro": 17900000, "allocated_usd_micro": 30000000, "calls": 412 } ],
  "reservations": [ { "id": "r-…", "task_id": "t-…", "model": "claude-opus-5-5", "profile": "deep", "reserved_usd_micro": 420000, "at": "…" } ],
  "savings": { "cache_usd_micro": 6120000, "fingerprint_usd_micro": 1880000, "fingerprint_hits": 342, "batch_usd_micro": 2950000 },
  "prices": [ { "model": "claude-sonnet-5-5", "in": 2.0, "out": 10.0, "verified": "2026-10-31", "note": "" } ] }
```
- `prices` en USD par million de jetons, recopiés de `Config/brains.json` avec leur date `verified` ; l'écran alerte au-delà de 30 jours.
- Champ obligatoire pour être reconnu : `cap_usd_micro`. Sinon → jeu simulé.
- L'alerte de coût des modes (Auto/Rapide/Profond) lit `prices` ; sans la route, elle utilise les prix du brief (datés du 2026-10-31) et le dit.

## 3. Coffre derrière Touch ID (NovaMac + NovaCore)
| Route | Effet |
|---|---|
| `GET /api/vault/biometric/status` | `registered`, `available`, `biometry`, `enabled`, `item_present`, `legacy_item_kept` — jamais de valeur |
| `POST /api/vault/biometric/enable` | coffre ouvert (`X-Vault`) : copie la clé dans un élément `.biometryCurrentSet`, relit derrière Touch ID, compare l'empreinte, bascule `key_store=biometric` ; ne supprime rien |
| `POST /api/vault/biometric/disable` | repasse sur l'élément classique ; ne supprime rien |
Une fois activé : `openKey()` ne lit la clé que derrière Touch ID ; `POST /api/vault/unlock/system` n'affiche qu'**une** invite (la lecture
Trousseau) et la fait **avant** tout ticket/jeton ; un refus ou une annulation ferme la porte (pas de repli « coffre en clair »).

## Couper chaque intégration
| Intégration | Comment la couper |
|---|---|
| Approbations | retirer `taches` de `MODULES` et de `GROUPS` (shell.js) ; `tasks-feed.js` n'est importé que par `modules/taches.js` |
| Coûts | retirer `couts` de `MODULES` et de `GROUPS` (shell.js) |
| Alerte de coût des profondeurs | `depth.js` : `confirmCostIncrease` renvoie `true` d'emblée et `costIncreaseText` renvoie `null` |
| Entrées ⌘K | palette.js : retirer `page:modes` et `act:vault-touchid` |
| Touch ID au Trousseau | `POST /api/vault/biometric/disable` ; ou retirer `VaultBiometric.register(...)` de `Sources/NovaMac/main.swift` (tout devient inerte) |
| Correctif « Augmenter le contraste » | supprimer la Partie C en fin de `tokens.css` |
| Jetons regroupés / CSS morte retirée | `git revert` de cd88b5a / 69b6dd9 (rendu mesuré identique : `docs/captures-phase4-v2/RESULTATS.md`) |
