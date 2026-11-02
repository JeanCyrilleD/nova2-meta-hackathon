# Architecture — Nova 2

**Date :** 2026-10-20 · **Base :** audit forensique du 2026-10-20 (`audit_2026-10-20.md`) + recherche design 2026 (`recherche_design_2026.md`)
**Principe fondateur :** Nova 1 ne souffre pas de bugs mais d'**empilement**. Nova 2 ne rajoute rien : elle **retire**. Chaque symptôme de l'audit a ci-dessous sa correction nommée (§9, table de correspondance) et un code correspondant dans `nova2/`.

---

## 1. Vue d'ensemble

```
┌─────────────────────────────────────────────────────────────┐
│ NovaMac (UN SEUL exécutable, UN SEUL point d'entrée)        │
│  ├─ NovaApp (NovaCore) — moteur intégré, démarré en-process  │
│  │    ├─ Server.swift : HTTP 127.0.0.1:47615 (inchangé)      │
│  │    ├─ Router + Brains : chaîne IA réduite, délai global   │
│  │    ├─ Store / Vault / Dots / Council / Veille / Portfolio │
│  │    └─ UltraDatabase (SQLite) : persistance unique         │
│  └─ WKWebView principale (toujours présente)                │
│       └─ web/ : shell + modules chargés à la demande        │
│  Volets web externes (WhatsApp, Outlook…) : créés à la      │
│  demande, détruits à la fermeture ou après 10 min inactifs  │
└─────────────────────────────────────────────────────────────┘
```

Décisions tranchées (Nova 1 en avait 2 ou 3 en concurrence pour chacune) :

| Question | Nova 1 | **Nova 2** |
|---|---|---|
| Point d'entrée moteur | NovaMac intégré **ou** NovaEngine (LaunchAgent) **ou** nova-server, choisi par une sonde HTTP bloquante au lancement | **NovaMac intégré, toujours.** NovaEngine et nova-server sortent du package. La sonde `externalEngine()` et le fichier `engine-mode` disparaissent. |
| Transport UI ↔ moteur | HTTP 127.0.0.1 (actif) + schéma `nova://` (dormant, maintenu) | **HTTP 127.0.0.1 uniquement.** Le handler `nova://` est conservé dans l'arbre comme code mort documenté, non enregistré par défaut (interrupteur inchangé = désactivé). |
| Événements serveur → UI | Bus SSE partagé de `core.js` (bon) + modules non migrés interceptés par un wrapper | **Le bus SSE de core.js, seul.** Un unique `EventSource` sur `/api/events`. Le wrapper de compatibilité reste dans core.js (il ne coûte rien), mais aucun module Nova 2 n'ouvre le sien. |
| Persistance d'état | Fichiers JSON read-modify-write (`DotScheduler.ack()`) + SQLite | **SQLite (`UltraDatabase`) pour l'état chaud ; JSON seulement pour l'export.** (Chantier Core documenté §8 — la couche web n'en dépend pas.) |
| Veille du Mac | `beginActivity` avec `idleSystemSleepDisabled` + 5 scripts `caffeinate*.command` concurrents | **Le Mac peut dormir.** `beginActivity` réduit à `[.suddenTerminationDisabled]` (protection des écritures en cours, rien d'autre). Les scripts racine ne sont pas repris. |
| Anti-crash WebContent | Aucun handler | `webViewWebContentProcessDidTerminate` → rechargement de la vue principale avec restauration d'état (recherche §3.1). |

---

## 2. Coquille Swift (NovaMac)

Base reprise : `Sources/NovaMac/main.swift` (47 032 o) + `NovaSchemeHandler.swift` (9 250 o), **copies byte-exactes de la live**, puis 4 correctifs chirurgicaux (marqués `// NOVA2:` dans le code) :

1. **NOVA2-ENTRÉE** — Suppression de la branche `externalEngine()` dans `applicationDidFinishLaunching` et de la fonction `externalEngine()` elle-même : démarrage toujours intégré, aucun `DispatchSemaphore.wait` bloquant, plus de comportement variable d'un lancement à l'autre. `loadHTTP` utilise toujours `core.server.token`.
2. **NOVA2-VEILLE** — `beginActivity(options: [.suddenTerminationDisabled])` : le Mac retrouve sa veille système ; Nova ne protège que ses écritures contre une terminaison brutale.
3. **NOVA2-VOLETS** — Les volets restent créés à la demande (`makePane`), mais un **récolteur d'inactivité** (timer 60 s) détruit tout volet « silencieux » (`quiet == true`, Outlook/Teams en lecture d'arrière-plan) inutilisé depuis **10 minutes** : horodatage `paneLastUsed` mis à jour à chaque `push()` et à chaque commande d'affichage. Fini les ~7 processus WebContent plein régime 24/7 (cause des `.cpu_resource.diag` du 15–16/10).
4. **NOVA2-PUSH** — `PaneDelegate.push()` est **coalescé** : au plus 1 `evaluateJavaScript` par volet par tranche de 250 ms (les événements didCommit/didStart/didFinish d'Outlook/Teams partent en rafales ; le thread principal n'est plus un bus d'événements).
5. **NOVA2-CRASH** — `webViewWebContentProcessDidTerminate` : recharge la vue principale (le processus de rendu WebGL peut mourir sans laisser un écran blanc définitif — recherche §3.1.1).

Le panneau flottant « assistant » est conservé (une seule WebView secondaire, créée avec la fenêtre principale).

---

## 3. Cerveaux IA — chaîne réduite, échec rapide

Tous les cerveaux appelés à l'exécution sont des modèles Meta (Muse Spark 1.3, Muse Wonder 1.0, Muse Spark 1.2, Muse Spark Open via Baseten ; voir README, section 3). `Brains.swift` et `Router` encadrent la chaîne :

1. **NOVA2-CATALOGUE** — les modèles prouvés morts (404) sortent du catalogue et des trois listes d'ordre (`fastOrder`, `bulkOrder`, `deepOrder`) ; un cerveau sans clé est sauté par `plan()`.
2. **NOVA2-DÉLAI** — `Router.firstTokenTimeout` : **6 s** (cloud). Au-delà, le cerveau suivant prend la main ; l'utilisateur voit l'événement.
3. **NOVA2-PLAFOND** — `plan()` plafonne la chaîne effective à **6 candidats**.
4. **NOVA2-DEADLINE** — `Router.chat()` reçoit une **échéance globale de 25 s** (`globalDeadline`) : passé ce délai, la boucle de repli s'arrête et le dit.

---

## 4. Couche web — structure

```
web/
├─ index.html            ← LE shell : rail + zone module + palette + orbe. Rien d'autre.
├─ css/
│   └─ nova2.css         ← LE fichier CSS : tokens + composants. Un seul.
└─ js/
    ├─ core.js           ← repris de Nova 1 (bus SSE, every, esc, h, md, erreurs) + registre de thèmes Nova 2
    ├─ icons.js          ← registre SVG unique et complet (voir §6)
    ├─ bg.js             ← LE fond animé (voir §5)
    ├─ shell.js          ← navigation rail, chargeur paresseux de modules, mini-lecteur persistant
    ├─ palette.js        ← ⌘K (8 états)
    ├─ orb.js            ← l'orbe 4 états + cartes d'approbation
    └─ modules/
        ├─ dots.js       ← accueil bento
        ├─ finance.js    ← BRVM
        ├─ radio.js      ← radio / podcasts
        ├─ messages.js   ← messageries (volets Swift à la demande)
        ├─ vault.js      ← coffre
        └─ settings.js   ← paramètres 4 écrans
```

**Chargement paresseux, règle d'or :** `index.html` ne charge que `core.js`, `icons.js`, `bg.js`, `shell.js`, `palette.js`, `orb.js`. Chaque module est importé **à la première ouverture** (`import()` dynamique), monté dans la zone module, et **démonté** à la fermeture (ses intervalles meurent avec lui — `AbortController` par module, passé à `every()`/écouteurs). Aucun `modulepreload` en bloc, aucun rendu invisible permanent. Le DOM inactif d'un module fermé est **détruit**, pas masqué.

**État du monde :** un seul fetch initial groupé (`GET /api/state`) puis le bus SSE pousse les changements (`nova:dot-run`, `nova:brief-new`…). Zéro polling par module ; `every()` (suspendu quand `document.hidden`) est le seul mécanisme de rafraîchissement périodique autorisé, réservé aux cours BRVM (60 s).

---

## 5. Le fond animé — un seul, discipliné

Base reprise : `spatial-bg.js` (WebGL maison, le mieux conçu des trois), corrigé selon le playbook (recherche §3.4) dans `bg.js` :

- **UN seul fond.** `constellation.js` et le fond CSS `#aurora/#floor` ne sont pas repris. Aucune concurrence de `requestAnimationFrame`.
- **DPR plafonné à 1,5** et échelle de rendu 0,5 (le fond est ambiant et flou par nature).
- **Zéro allocation par frame** : géométrie et uniformes pré-calculés.
- **Lecture du thème découplée du rendu** : Nova 1 relisait le thème via `getComputedStyle` + `getImageData` à **chaque mutation de classe du body** (deux `MutationObserver`) et redessinait dans la foulée. Nova 2 lit le thème **une fois** au démarrage, puis uniquement sur l'événement `nova:theme`. Plus aucun observer.
- **Pause hors écran** : `visibilitychange` + `IntersectionObserver` sur le canvas ; si un module plein écran recouvre le fond, le canvas est masqué (`display:none`) et la boucle arrêtée — un canvas caché qui rend est du lag pur.
- **Garde-fou FPS** : si le FPS moyen < 30 pendant 3 s, bascule automatique sur le **dégradé CSS statique** (mêmes tokens) et événement `nova:bg-static`. Réglage utilisateur : Fond animé = Auto / Toujours / Jamais.
- **Budget** : cible 30 fps pour le fond seul (mouvement lent), jamais d'animation CSS concurrente sur un élément `backdrop-filter` pendant un scroll.

---

## 6. Icônes — un registre, complet, bruyant en cas d'erreur

Diagnostic (audit §4.2) : `icons.js` ne définit que 34 clés et se termine par `P[n] || P.orb` — toute icône inconnue s'affiche **silencieusement** comme l'orbe générique. `appicons.js` (15 Ko) existe en 3 copies byte-identiques : impossible de savoir laquelle est importée.

Nova 2 (`js/icons.js`) :
- **Un seul registre**, héritier des 34 glyphes d'origine (mêmes tracés, grille 24, trait 1.6, `currentColor`), **étendu à tous les modules** : navigation (dots, finance, radio, messages, vault, settings), transport audio (play, pause, next, prev, volume, list), finance (chart, up, down, wallet, refresh), messagerie (send, attach, mic, check lu), coffre (lock, unlock, key, eye, eye-off), système (search, command, close, back, plus, alert, info, external, download, sun/moon pour les fonds).
- **Aucun repli silencieux** : `icon(name)` inconnu → en développement, cadre rouge pointillé + `console.error` + entrée au journal d'erreurs (`NovaErrors`) ; en production, carré vide **avec le nom en `title`** — jamais une autre icône trompeuse.
- Le double registre `appicons.js` n'est pas repris.

---

## 7. Navigation — une seule vérité

Nova 1 affichait **4 systèmes simultanés** (`#side`, `#side2`, `#ribbon`, `#dock`) + 2 modes de layout. Nova 2 :

1. **Rail gauche fixe 72 px** (verre depth-1) : Dots, Finance, Radio, Messages, Coffre ; Réglages en bas, séparé. État actif = pastille accent + verre renforcé, transition ressort 200 ms. Libellés en tooltip ; mode « rail étendu » en réglage.
2. **⌘K** — palette de commandes globale : modules, actions (« joue RFI », « cours SONATEL », « verrouille le coffre »), recherche unifiée. 8 états explicites (défaut/récents, saisie en une frame, aucun résultat avec sortie, skeleton à géométrie finale, erreur/offline — les commandes locales marchent, sous-pages avec fil d'Ariane, multi-sélection, commande désactivée **avec raison affichée**). Matching par sous-séquence, classement par frecency, autofocus immédiat.
3. **L'accueil Dots en bento** — un état du monde, pas une page : hero 6×2 (orbe + phrase de situation), finance 3×2 (sparkline), audio 3×1, messages 3×1, coffre 2×1, actions rapides 4×1. **Exactement une tuile dominante.**

L'orbe (dans le hero et en mini-lecteur flottant) a **4 états** et seulement 4 : `repos` (respiration 4 s), `ecoute` (pulsation sur niveau micro), `reflexion` (contraction + anneau), `parole` (ondulation). Morphing ressort ~350 ms entre états, jamais de coupure. Les réponses de l'assistant sont des **cartes typées** (cours, message, audio, approbation), jamais un mur de texte ; toute action proposée passe par la **carte d'approbation** (action, destinataire, Approuver / Modifier / Refuser) — pattern Fuselab, cœur de la démo hackathon.

---

## 8. CSS et thèmes — un système, des thèmes qui s'appliquent

Diagnostic (audit §3.4, §4.3) : 19 fichiers CSS (~366 Ko), 494 `!important` dans le seul `app.css`, 21 `backdrop-filter`, z-index jusqu'à 100 000 — et un thème stocké `"theme":"cafu-imperial"` qui **n'existe pas** dans le registre (`hc-cafu` oui, `cafu-imperial` non) : `applyTheme()` retombait silencieusement sur Tahoe Auto. Les thèmes « Haute Couture » pointaient sur un fichier vidé par un nettoyage (1 402 o contre 20 773 o pour sa sauvegarde).

Nova 2 :
- **Un seul fichier** `css/nova2.css` : d'abord les **tokens** (palette « observatoire spatial » de la recherche §5.1 : `--void #07080F`, `--glass`, `--glass-strong`, `--stroke`, `--ink/-2/-3`, `--accent #FF7A29`, `--up/--down` finance uniquement, `--danger`), puis les composants. Échelle typo fermée 28/20/15/13/11, SF Pro système, `tabular-nums` pour les chiffres financiers.
- **Budget `!important` : 0** hors utilitaires documentés en tête de fichier (il n'y en a aucun au lancement ; tout ajout doit être justifié dans le commentaire du fichier). Vérifié mécaniquement (§10).
- **`backdrop-filter` rationné** : rail, cartes hero du bento, palette ⌘K, mini-lecteur, modales. Interdit sur les lignes de listes qui scrollent (recherche §3.1.4).
- **Thèmes = variantes de tokens, pas des fichiers.** Un thème est un bloc `[data-theme="…"]` dans `nova2.css` qui ne redéfinit que des variables. Registre unique dans `core.js` (`THEMES`) : `observatoire` (défaut, sombre), `encre` (noir OLED), `sahel` (clair chaud), `cafu` (clair, accent rouge SCI #C00000 — le vrai héritier de l'intention « cafu-imperial »). `applyTheme(id)` : id inconnu → **erreur visible** (journal + toast « thème inconnu : X ») et conservation du thème courant — plus jamais de repli silencieux.
- **Source de vérité unique pour les réglages** : `/api/settings` (serveur). `localStorage` ne sert plus qu'au cache d'affichage immédiat au démarrage (thème, avant le premier fetch) et au journal d'erreurs. Les clés éparses de Nova 1 (`nova_night`, `nova_rendu_leger`, `nova_liquid_glass`, `nova27`, layout dans `layout.js`, apparence dans `tabs/apparence.js`) ne sont pas reprises.

### Paramètres — 4 écrans plats cherchables
Un champ de recherche filtre en direct les 4 écrans (modèle macOS) :
1. **Général** — lancement, fond animé (Auto/Toujours/Jamais), réduire les animations.
2. **Assistant** — cerveau par défaut (liste alimentée par `/api/brains`, états réels), voix, approbations (toujours demander / envoi seulement).
3. **Données & comptes** — sources connectées, clés (état Trousseau, jamais les valeurs), cache, tout effacer.
4. **Apparence & accès** — thème (les 4, appliqués en direct), rail étendu, contraste renforcé, réduire la transparence.
Chaque réglage : libellé court + une ligne de description + contrôle à droite + écriture immédiate vers `/api/settings`. Zéro page « avancé » fourre-tout, zéro réglage orphelin.

---

## 9. Table de correspondance — symptôme de l'audit → correction Nova 2

| # | Symptôme (audit) | Correction | Code |
|---|---|---|---|
| 1 | ~7 WebView permanentes, `.cpu_resource.diag` (§2.1–2.2) | Volets paresseux + récolteur d'inactivité 10 min ; 1 vue principale + 1 panneau | `NovaMac/main.swift` NOVA2-VOLETS |
| 2 | Anti-veille permanent + scripts concurrents (§2.3) | `beginActivity` réduit ; scripts non repris | `main.swift` NOVA2-VEILLE |
| 3 | 17/21 cerveaux morts, attentes en cascade (§2.4) | Catalogue élagué (2 modèles 404 retirés), timeout 1er token 6 s, chaîne ≤ 6, deadline globale 25 s | `Brains.swift`, `Router.swift` NOVA2-* |
| 4 | Serveur HTTP artisanal, pool fragile (§2.5) | Conservé (fonctionne) mais **un seul moteur** ; plus de sonde de démarrage | `main.swift` NOVA2-ENTRÉE |
| 5 | Sonde de démarrage bloquante 2 s, double architecture (§2.6) | Supprimée ; démarrage intégré déterministe | `main.swift` NOVA2-ENTRÉE |
| 6 | Saturation connexions HTTP/1.1 par EventSource multiples (§3.1) | Bus SSE unique de core.js, seul transport événements | `web/js/core.js` (repris) |
| 7 | Pollings/repaints permanents par onglet (§3.2) | Modules démontés à la fermeture ; `every()` suspendu si caché ; aucun intervalle orphelin | `web/js/shell.js` + modules |
| 8 | 3 fonds animés concurrents (§3.3) | **Un seul** fond WebGL discipliné (DPR ≤ 1,5, pause hors écran, fallback statique, thème lu sur événement) | `web/js/bg.js` |
| 9 | Guerre des `!important` : 494, 19 CSS (§3.4) | 1 fichier CSS, budget `!important` = 0 | `web/css/nova2.css` |
| 10 | État JSON read-modify-write (§3.5) | SQLite cible pour l'état chaud (chantier Core §8) ; la web ne persiste que via `/api/settings` | doc §1, §8 |
| 11 | `evaluateJavaScript` en rafale depuis les volets (§3.6) | `push()` coalescé à 250 ms/volet | `main.swift` NOVA2-PUSH |
| 12 | 4 systèmes de navigation simultanés (§4.1) | Rail 72 px + ⌘K + bento. Rien d'autre. | `web/index.html`, `shell.js`, `palette.js` |
| 13 | Icônes : 34 noms, repli silencieux sur « orb », double registre (§4.2) | Registre unique complet (~60 noms), erreur visible en dev | `web/js/icons.js` |
| 14 | Thème stocké inexistant (`cafu-imperial`), repli silencieux ; couture vidé (§4.3) | Thèmes = variantes de tokens dans l'unique CSS ; registre unique ; inconnu = erreur visible ; thème `cafu` réel | `core.js` (THEMES), `nova2.css` |
| 15 | 3 sources de vérité des réglages (§4.3) | `/api/settings` seule ; localStorage = cache d'amorçage | `modules/settings.js` |
| 16 | Bootguard d'écran blanc (§4.4) | Remplacé par un état d'erreur sobre dans le shell (message + bouton Recharger + lien journal) ; handler WebContent natif | `index.html`, `main.swift` NOVA2-CRASH |
| 17 | `.bak-*` dans l'arbre et le bundle (§1, §5) | Arbre Nova 2 neuf : aucun `.bak`, aucune archive, aucun document de travail dans `web/` | `nova2/` entier |
| 18 | Trois points d'entrée moteur (§5) | Un : NovaMac. Package réduit à 2 cibles + tests | `Package.swift` |
| 19 | `testTarget` casse (`Tests/` vs `tests/`) (§1.2) | Dossier `Tests/NovaCoreTests` créé au bon nom | `Tests/` |
| 20 | Version figée 1.0.0 build 1 (§5) | Nova 2 = version **2.0.0** (à appliquer dans l'Info.plist lors de l'assemblage du bundle, étape manuelle Xcode) | doc §10 |

---

## 10. Vérification et limites assumées

- **JS** : `node --check` sur chaque fichier de `web/js/` (core.js est un module ES : vérifié via `node --check` en mode module).
- **CSS** : comptage mécanique des `!important` (cible 0), un seul fichier `.css` dans `web/`.
- **HTML** : structure du shell validée (balises fermées, ids uniques, aucun `<script>` de module lourd au démarrage hors liste §4).
- **Swift** : pas de compilateur macOS sur la machine de build (VM Linux, Mac sans shell) — les correctifs `NOVA2-*` sont chirurgicaux et relus, mais **la compilation Xcode par Ahadi reste l'étape de vérité** (voir rapport de livraison). Le `Package.swift` Nova 2 ne déclare que NovaCore + NovaMac + tests : si un fichier NovaCore référençait NovaEngine/nova-server (vérifié : ce sont des exécutables feuilles), la compilation le dira immédiatement.
- **Écarts assumés** : (a) le remplacement de la persistance JSON de `DotScheduler` par SQLite est spécifié mais non implémenté dans cette passe (risque élevé sans compilation) ; (b) `NovaSchemeHandler.swift` est repris tel quel, non activé ; (c) les modules web consomment les API existantes (`/api/state`, `/api/settings`, `/api/brains`, flux SSE) et affichent des squelettes à géométrie finale si une route est absente — jamais de fausses données.
