#!/bin/bash
# Nova 2 — RECETTE TOTALE (V4-D, 24/10/2026). Règle : « fait = prouvé » — jamais de faux PASS.
#   PASS        : vérifié ici, maintenant, avec une preuve (code HTTP, sortie du compilateur…)
#   FAIL        : vérifié et cassé
#   NON VÉRIFIÉ : impossible à vérifier dans cet environnement (pas de Swift, Nova éteinte…) — ce n'est PAS un succès
# Usage : bash tools/recette_totale.sh            (depuis la racine du dépôt Nova2)
#         RECETTE_BUILD=0 bash tools/recette_totale.sh   (saute swift build)
set -u
cd "$(dirname "$0")/.." || exit 2
PASS=0; FAIL=0; NV=0
ok()   { PASS=$((PASS+1)); echo "  PASS        $*"; }
ko()   { FAIL=$((FAIL+1)); echo "  FAIL        $*"; }
nv()   { NV=$((NV+1));     echo "  NON VÉRIFIÉ $*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "── 1. Syntaxe des modules web (node --check, mode module) ──"
if command -v node >/dev/null 2>&1; then
  n=0; bad=0
  while IFS= read -r f; do
    n=$((n+1)); cp "$f" "$TMP/check.mjs"
    if ! node --check "$TMP/check.mjs" 2>"$TMP/err"; then bad=$((bad+1)); ko "$f"; sed 's/^/              /' "$TMP/err" | head -5; fi
  done < <(find web/js -name "*.js" -not -path "*/vendor/*" | sort)
  [ "$bad" = "0" ] && ok "$n fichiers JS : syntaxe valide"
else
  nv "node absent : syntaxe JS non contrôlée"
fi

echo "── 2. Feuilles CSS : accolades équilibrées (hors commentaires) ──"
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' > "$TMP/css" 2>&1
import re, glob
bad = 0
files = sorted(glob.glob('web/css/*.css'))
for f in files:
    s = re.sub(r'/\*.*?\*/', '', open(f, encoding='utf-8').read(), flags=re.S)
    if s.count('{') != s.count('}'):
        bad += 1; print('FAIL ' + f + ' : { ' + str(s.count('{')) + ' / } ' + str(s.count('}')))
print('TOTAL ' + str(len(files)) + ' ' + str(bad))
PY
  while IFS= read -r l; do case "$l" in FAIL*) ko "${l#FAIL }";; TOTAL*) set -- $l; [ "$3" = "0" ] && ok "$2 feuilles CSS équilibrées";; esac; done < "$TMP/css"
else
  nv "python3 absent : CSS non contrôlé"
fi

echo "── 2b. CSS : budget de la feuille unique (Bloc 1 du 24/10 — ratchet du 29/10) ──"
if [ -f web/css/app.css ]; then
  SZ=$(wc -c < web/css/app.css | tr -d ' ')
  if [ "$SZ" -le 466811 ]; then ok "app.css $SZ o ≤ ratchet de création (466811 o) — cible Bloc 1 : 65 Ko après retirage du code mort"
  else ko "app.css $SZ o — dépasse le ratchet de création (466811 o) : gel des ajouts violé"; fi
else
  ko "web/css/app.css absente (feuille unique attendue depuis la consolidation du 29/10)"
fi

echo "── 3. Routes critiques sur Nova en marche (port + jeton de ~/Library/Application Support/Nova/.session) ──"
SESSION="${NOVA_SESSION:-$HOME/Library/Application Support/Nova/.session}"
if [ -r "$SESSION" ] && command -v curl >/dev/null 2>&1; then
  read -r PORT TOKEN < "$SESSION"
  BASE="http://127.0.0.1:${PORT}"
  if curl -s -o /dev/null --max-time 3 -H "X-Nova-Token: $TOKEN" "$BASE/api/state"; then
    get() {   # route, puis vérifie HTTP 200 ET corps JSON analysable
      local r="$1" code
      code=$(curl -s -o "$TMP/body" -w "%{http_code}" --max-time 20 -H "X-Nova-Token: $TOKEN" "$BASE$r")
      if [ "$code" = "200" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/body" 2>/dev/null; then ok "GET $r → 200 JSON"
      elif [ "$code" = "404" ]; then ko "GET $r → 404 (route absente)"
      else ko "GET $r → HTTP $code"; fi
    }
    for r in /api/state /api/settings /api/today /api/dots /api/council/history /api/blackbox/verify /api/fundings; do get "$r"; done
    # Portefeuille : 423 « coffre verrouillé » = posture voulue après relance (Portfolio.swift:380) —
    # PASS si 200 JSON (coffre ouvert) OU 423 (refus honnête), KO seulement si route absente/autre.
    code=$(curl -s -o "$TMP/body" -w "%{http_code}" --max-time 20 -H "X-Nova-Token: $TOKEN" "$BASE/api/portfolio")
    if [ "$code" = "200" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/body" 2>/dev/null; then ok "GET /api/portfolio → 200 JSON (coffre ouvert)"
    elif [ "$code" = "423" ]; then ok "GET /api/portfolio → 423 coffre verrouillé (refus honnête, posture voulue)"
    elif [ "$code" = "404" ]; then ko "GET /api/portfolio → 404 (route absente)"
    else ko "GET /api/portfolio → HTTP $code"; fi
    # Live Steer : sans run en cours, la route DOIT répondre 409 (preuve qu'elle existe et refuse honnêtement)
    code=$(curl -s -o "$TMP/body" -w "%{http_code}" --max-time 5 -H "X-Nova-Token: $TOKEN" -H "Content-Type: application/json" -d '{"conv":"recette-inexistante","text":"test"}' "$BASE/api/chat/steer")
    if [ "$code" = "409" ]; then ok "POST /api/chat/steer hors run → 409 (refus honnête)"; else ko "POST /api/chat/steer hors run → HTTP $code (attendu 409)"; fi
    # Gouverneur : la réponse doit porter le champ « sources » (route effective, V4-D)
    code=$(curl -s -o "$TMP/body" -w "%{http_code}" --max-time 5 -H "X-Nova-Token: $TOKEN" -H "Content-Type: application/json" -d '{"busy":false,"source":"recette"}' "$BASE/api/perf")
    if [ "$code" = "200" ] && grep -q '"sources"' "$TMP/body"; then ok "POST /api/perf → 200 avec sources (gouverneur effectif)"; else ko "POST /api/perf → HTTP $code ou champ sources absent"; fi
    # Vision : sans explicit=1, le Témoin doit refuser (aucune capture automatique)
    code=$(curl -s -o "$TMP/body" -w "%{http_code}" --max-time 5 -H "X-Nova-Token: $TOKEN" "$BASE/api/temoin/vision")
    if [ "$code" = "200" ] && grep -q 'explicit_required' "$TMP/body"; then ok "GET /api/temoin/vision sans clic → refus explicit_required"; else ko "GET /api/temoin/vision sans explicit → HTTP $code, refus absent"; fi
  else
    nv "Nova ne répond pas sur $BASE (lance Nova puis relance la recette) — routes non testées"
  fi
else
  nv "pas de fichier .session lisible ($SESSION) ou curl absent — routes non testées (Nova doit tourner sur ce Mac)"
fi

echo "── 4. Compilation Swift (swift build -c release) ──"
if [ "${RECETTE_BUILD:-1}" = "0" ]; then
  nv "swift build sauté (RECETTE_BUILD=0)"
elif command -v swift >/dev/null 2>&1; then
  if swift build -c release > "$TMP/build" 2>&1; then
    w=$(grep -c "warning:" "$TMP/build" || true); ok "swift build -c release : 0 erreur ($w avertissement(s))"
  else
    ko "swift build -c release : $(grep -c 'error:' "$TMP/build" || true) erreur(s)"; grep "error:" "$TMP/build" | head -20 | sed 's/^/              /'
  fi
else
  nv "swift absent : sur le Mac, lance « swift build -c release » dans ~/spark-local/Nova2, puis « bash tools/package_app.sh »"
fi

echo "── 5. Non couvert par ce script (à vérifier à l'œil, dans Nova) ──"
nv "console WKWebView sans erreur, compagnons 3D, onglet Feeds › Fundings, 3 thèmes (aucune vérification headless WebKit ici)"

echo
echo "RÉSULTAT : $PASS PASS · $FAIL FAIL · $NV NON VÉRIFIÉ"
[ "$FAIL" = "0" ] || exit 1
[ "$NV" = "0" ] || exit 3
exit 0
