# Phase 5 — Présence 3D optionnelle

**Ce que c'est.** Un seul objet 3D (une goutte procédurale, créée en code : icosphère de 5 120 triangles déformée dans le shader, aucun fichier 3D, aucun modèle) qui montre l'état de Nova :

| État de l'objet | États Nova qui y mènent | Lecture |
|---|---|---|
| repos | repos, écoute, parole, done | bleu, respiration lente, 30 i/s |
| réflexion | réflexion, outil, lecture | violet, surface qui travaille, 60 i/s |
| attente | approval (une approbation attend) | ambre, battement lent, 30 i/s |
| erreur | erreur | rouge, secousse brève, 30 i/s |
| plafond | plafond de budget atteint (prioritaire) | gris, immobile : la boucle s'arrête |

Captures (Chromium sans tête, rendu logiciel SwiftShader) : `docs/captures-phase5/etats-webgpu.png`, `docs/captures-phase5/etats-webgl2.png`.

**Fichiers.** `web/js/presence3d.js` (moteur, sans dépendance), `web/js/avatar.js` (montage à la demande), `web/js/modules/settings.js` (bascule), `tools/test_presence3d.mjs` (tests, lancés par `tools/verify.sh` §9).

## Couper / activer
- **Réglages › Apparence › « Présence 3D (expérimental) »** : bascule. **Coupé par défaut.**
- Côté moteur : clé `presence_3d` de `/api/settings` (`false` = coupé). Cache d'amorçage : `localStorage["nova2_presence_3d"]` (`"1"` / `"0"`).
- Coupé, `presence3d.js` n'est **jamais** chargé : aucun import statique (index.html et shell.js ne le citent pas ; test « démarrage »). Activé, il est importé seulement quand la présence est à l'écran et la fenêtre visible.
- Actif, l'objet remplace l'orbe et l'avatar (vidéo, verre, panda…) : un seul objet. Sans WebGPU ni WebGL2, l'orbe CSS reste.

## Garanties
- WebGPU d'abord (`navigator.gpu`), repli WebGL2.
- Pause quand la fenêtre est cachée (`visibilitychange`) ou la présence hors écran (`IntersectionObserver`).
- `prefers-reduced-motion` (ou `html[data-reduce-motion="1"]`) : une image fixe par changement d'état, aucune boucle.
- Aucun appel de modèle ni réseau dans `presence3d.js` (test : ni `fetch`, ni `/api/`, ni `import`).

## Plafond de budget (contrat pour la Phase 2)
L'objet passe à « plafond » quand `window.__novaBudgetCap === true` au montage, ou sur l'événement
`window.dispatchEvent(new CustomEvent("nova:budget-cap", { detail: { reached: true } }))` (`false` pour revenir).
Cette branche n'émet pas encore cet événement : le budget client arrive avec la Phase 2.

## Mesure GPU
`window.__novaPresence3d.stats()` (console de l'inspecteur) : moteur, méthode (`webgpu-timestamp`, `webgl-timer` ou `indisponible`), médiane / moyenne / p95 / max en ms (une image sur 20). Si le WebKit du Mac n'expose ni `timestamp-query` ni `EXT_disjoint_timer_query_webgl2`, la mesure GPU n'est pas disponible dans l'app.
