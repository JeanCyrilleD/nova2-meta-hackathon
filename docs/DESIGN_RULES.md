# Nova 2 — Règles de design (Phase 4, v2 du 31/10/2026)

**Décision d'Ahadi (31/10, 19:51) : « On garde notre UI actuelle en intégrant les nouvelles features sans changer notre rendu. »**
La v1 de la Phase 4 (accueil calme par défaut, verre limité à la navigation, couleurs d'état retouchées, profondeur « Nuit »
retirée) est **annulée** ; seuls restent les ajouts qui ne changent pas le rendu par défaut. Preuve chiffrée :
`docs/captures-phase4-v2/RESULTATS.md`.

## 1. Rendu par défaut = rendu d'avant (commit de base `bfdcf7a`)
- Accueil complet, verre partout comme avant, mêmes couleurs, mêmes quatre profondeurs (Éclair, Réfléchi, Conseil, Nuit).
- `web/css/layouts.css`, `web/js/modules/accueil.js`, `web/index.html` sont **identiques octet pour octet** à `bfdcf7a`.
- Jetons : `web/css/tokens.css` regroupe les règles racine de variables d'`app.css` et d'`identite.css` (Partie A, déplacées sans
  modification par `tools/ui/tokens_consolidate.py`) ; CSS morte retirée d'`app.css` sur preuve d'usage (`tools/ui/css_usage.py`,
  liste `docs/css-usage-phase4.txt`). Gardés parce que le rendu mesuré est identique (captures avant/après, §5).
- **Aucun jeton nouveau ni modifié par défaut.** La Partie C de `tokens.css` ne contient que le correctif « Augmenter le contraste ».

## 2. Nouvelles fonctions : composants existants seulement
- Écrans **Approbations** (`modules/taches.js`) et **Coûts** (`modules/couts.js`) : `ds.js` (pageHead, section, card, row, pill,
  kpis, empty), tableau `.ds-table`, champ `.fld.fld-area`, boutons `.ds-btn-*`, classe d'écran `mod--data`. **Aucune classe CSS
  nouvelle, aucune couleur nouvelle** (les classes `p4-*` / `hq-calm*` / `hq-today*` de la v1 ont été retirées).
- Alerte de coût d'une profondeur plus chère : carte `.ds-card` sous le sélecteur (Accueil, Conversations) ; dans ⌘K, le toast
  existant avec l'action « Passer en … ».
- Accès : rail (Approbations dans le premier groupe, Coûts dans « Moi ») et ⌘K (tous les modules + « Profondeur de réflexion… »,
  « Coffre : Touch ID… »). Rien d'ajouté sur l'Accueil.

## 3. Préférences du Mac
| Préférence macOS | Effet |
|---|---|
| Réduire les animations | comportement existant (app.css, 23 blocs `prefers-reduced-motion` ; réglage Nova `data-reduce-motion`) — inchangé |
| Réduire la transparence | comportement existant (`appearance-boot.js` → `data-transparency="reduced"`, @media d'identite.css/tokens.css) — inchangé |
| Augmenter le contraste (`prefers-contrast: more`) ou réglage Nova `data-contrast="more"` | **seul correctif ajouté** : `--text-2` et `--text-3` = `--text-1`, filets forts (la règle d'app.css dans `@layer accessibility` perdait face aux jetons de thème). N'agit que si la préférence est active. Échappatoire : `data-contrast="normal"` |

## 4. Écrans nouveaux — règles de contenu
- **Aucun chiffre inventé** : pas de pourcentage d'avancement, pas de barre sans dénominateur réel ; source absente → « — » ;
  données simulées annoncées en tête d'écran (carte `.ds-card.is-muted`).
- Argent : micro-dollars entiers côté données, affichage `0,0123 $` ; un coût estimé est toujours marqué « estimé ».
- Un seul bouton principal par bloc (Approuver), « Annuler » toujours présent.

## 5. Vérifier avant de livrer
```
python3 tools/ui/compare_base.py <web de bfdcf7a> <sortie>   # PREUVE : avant/après de chaque écran × 14 thèmes, diff de pixels
python3 tools/ui/root_vars_dump.py a.json                    # variables calculées (avant/après) + json_diff.py
python3 tools/ui/contrast_check.py                           # contraste des jetons (informatif)
sh tools/ui/js_check.sh web/js/x.js                          # syntaxe réelle des modules ES
node tools/ui/test_tasks_feed.mjs                            # réducteur d'évènements + contrat /api/agents2
```
Web de base : `git archive bfdcf7a web | tar -x -C ~/p4base`. Prérequis VM : `pip install playwright tinycss2` +
`playwright install chromium` ; `LD_LIBRARY_PATH=$HOME/libroot/usr/lib/aarch64-linux-gnu` (libXdamage extraite du .deb).
