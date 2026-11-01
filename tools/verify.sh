#!/bin/bash
# Nova 2 — vérification locale (à relancer après chaque modification de web/).
# Aucune de ces vérifications n'exige le Mac ni Xcode.
set -u
FAIL=0
echo "── 1. Syntaxe JS (mode module) ──"
for f in $(find web -name "*.js"); do
  cp "$f" /tmp/nova2check.mjs
  if node --check /tmp/nova2check.mjs 2>/tmp/nova2err; then echo "  OK  $f"; else echo "  FAIL $f"; cat /tmp/nova2err; FAIL=1; fi
done
echo "── 2. CSS : feuille unique (consolidation du 29/10), ratchets fichiers + taille + !important ──"
# PHASE 1 (31/10) : ces cliquets du 26-29/10 étaient DÉJÀ dépassés à la base Phase 0 (6 fichiers, 480 751 o, 193 !important :
# verify.sh était rouge avant toute intervention). Le brief fixe la base des cliquets à la Phase 0 : valeurs rebasées sur elle,
# elles ne peuvent plus que baisser (Phase 4 : CSS morte retirée seulement sur preuve d'usage).
N=$(find web -name "*.css" | wc -l | tr -d ' '); echo "  fichiers .css : $N (cliquet base Phase 0 : jamais plus de 6)"; [ "$N" -le 6 ] || { echo "  FAIL cliquet fichiers CSS"; FAIL=1; }
SZ=$(wc -c < web/css/app.css | tr -d ' '); echo "  app.css : $SZ o (cliquet base Phase 0 : ≤ 480751 o — cible Bloc 1 : 65 Ko après retirage du code mort)"; [ "$SZ" -le 480751 ] || { echo "  FAIL cliquet taille app.css"; FAIL=1; }
I=$(python3 -c "
import re, glob
n=0
for f in glob.glob('web/css/*.css'):
    s=open(f).read(); s=re.sub(r'/\\*.*?\\*/','',s,flags=re.S); n+=s.count('!important')
print(n)")
echo "  !important total (hors commentaires) : $I (cliquet base Phase 0 : 193 — ne doit jamais remonter, Phase 4 le fait baisser)"; [ "$I" -le 193 ] || { echo "  FAIL cliquet !important"; FAIL=1; }
python3 -c "
import glob
for f in sorted(glob.glob('web/css/*.css')):
    s=open(f).read(); assert s.count('{')==s.count('}'), 'accolades déséquilibrées: '+f
print('  accolades CSS équilibrées (tous fichiers)')"
echo "── 3. HTML : structure ──"
python3 << 'PY'
from html.parser import HTMLParser
VOID={'meta','link','input','br','img','hr','source'}
class V(HTMLParser):
    def __init__(s):
        super().__init__(); s.stack=[]; s.errs=[]
    def handle_starttag(s,t,a):
        if t not in VOID: s.stack.append(t)
    def handle_endtag(s,t):
        if t in VOID: return
        if not s.stack or s.stack[-1]!=t: s.errs.append(f'</{t}> inattendu (pile: {s.stack[-3:]})')
        elif s.stack: s.stack.pop()
import sys
for f in ['web/index.html','web/panel.html']:
    v=V(); v.feed(open(f).read())
    ok = not v.errs and not v.stack
    print(f'  {"OK " if ok else "FAIL"} {f}', v.errs, ('reste: '+str(v.stack)) if v.stack else '')
    if not ok: sys.exit(1)
PY
[ $? -ne 0 ] && FAIL=1
echo "── 4. Cohérence : icônes ⊆ registre, modules du rail résolus, matières alignées ──"
python3 << 'PYEOF4'
import re, glob, sys
icons = set(re.findall(r'^  "?([a-z0-9-]+)"?: \'', open('web/js/icons.js').read(), re.M))
used = set()
for f in glob.glob('web/js/**/*.js', recursive=True):
    src = open(f).read()
    used |= set(re.findall(r'ic\("([a-z0-9-]+)"', src))
    used |= set(re.findall(r'icon: "([a-z0-9-]+)"', src))
missing = used - icons
print('  icônes utilisées :', len(used), '| manquantes :', sorted(missing) if missing else 'aucune')
shell = open('web/js/shell.js').read()
rail = re.findall(r'\{ id: "(\w+)", icon:', shell)
fmap = dict(re.findall(r'(\w+): "(\w+)"', shell.split('MODULE_FILES = {')[1].split('}')[0])) if 'MODULE_FILES' in shell else {}
files = {p.split('/')[-1][:-3] for p in glob.glob('web/js/modules/*.js')}
unresolved = [m for m in rail if fmap.get(m, m) not in files]
extras = sorted(files - {fmap.get(m, m) for m in rail})
print('  modules rail :', len(rail), '| non résolus :', unresolved if unresolved else 'aucun', '| fichiers hors rail (sous-modules) :', extras)
core = open('web/js/core.js').read()
mats_js = set(re.findall(r'material: "(\w+)"', core.split('THEMES = [')[1].split('];')[0]))
css = ''.join(open(f).read() for f in glob.glob('web/css/*.css'))
mats_css = set(re.findall(r'\[data-material="(\w+)"\]', css))
modes_css = set(re.findall(r'\[data-mode="(\w+)"\]', css))
print('  matières JS :', sorted(mats_js), '| CSS :', sorted(mats_css), '| modes CSS :', sorted(modes_css))
ok = not missing and not unresolved and mats_js == mats_css and {'jour', 'nuit'} <= modes_css
print(' ', 'OK' if ok else 'FAIL')
sys.exit(0 if ok else 1)
PYEOF4
[ $? -ne 0 ] && FAIL=1
echo "── 5. Swift : correctifs NOVA2 en place, morts retirés ──"
grep -c "NOVA2" Sources/NovaMac/main.swift Sources/NovaCore/Router.swift Sources/NovaCore/Brains.swift
grep -q '"spark-1.4"' Sources/NovaCore/Brains.swift && { echo "  FAIL spark-1.4 encore présent"; FAIL=1; } || echo "  OK  spark-1.4 absent du catalogue"
# Version hackathon Meta : aucun hôte d'API de modèle non Meta dans le code livré (Sources, web, Config).
grep -rniE 'api\.anthropic\.com|api\.openai\.com|generativelanguage\.googleapis|api\.deepseek\.com|api\.moonshot|api\.z\.ai|api\.x\.ai|api\.mistral\.ai|api\.groq\.com|openrouter\.ai|api\.elevenlabs\.io|assemblyai\.com|intern-ai\.org|api\.perplexity\.ai|api\.together\.xyz|nebius\.ai|127\.0\.0\.1:11434|127\.0\.0\.1:20128' Sources web Config | grep . && { echo "  FAIL hôte de modèle non Meta présent"; FAIL=1; } || echo "  OK  aucun hôte de modèle non Meta (Sources, web, Config)"
ls Sources/NovaCore/*.swift | wc -l | xargs echo "  fichiers NovaCore :"
find Sources Tests tools web -name "*.bak*" -o -name "*.tgz" | grep . && { echo "  FAIL artefacts .bak/.tgz dans le code (Sources/Tests/tools/web)"; FAIL=1; } || echo "  OK  aucun .bak/.tgz dans le code (dormant/ et archives exclus : stockage, pas code)"
echo "── 6. Vague 3 : portes E3, profondeurs, écrans des partiels ──"
grep -q "PBKDF2" web/js/vaultgate.js && echo "  OK  vaultgate.js : dérivation PBKDF2 présente" || { echo "  FAIL vaultgate.js sans PBKDF2"; FAIL=1; }
for m in finance systeme vault; do grep -q "vaultgate" web/js/modules/$m.js && echo "  OK  porte E3 branchée dans $m.js" || { echo "  FAIL porte E3 absente de $m.js"; FAIL=1; }; done
grep -q "manquement" web/js/modules/ame.js && grep -q "autoeval" web/js/modules/ame.js && echo "  OK  P5 (auto-éval + manquements) dans ame.js" || { echo "  FAIL P5 incomplet dans ame.js"; FAIL=1; }
grep -q "kind: \"pensee\"" web/js/modules/ame.js && echo "  OK  n°24 transmission (kind pensee) dans ame.js" || { echo "  FAIL n°24 absent de ame.js"; FAIL=1; }
# FIX-WEB (24/10) : /api/missions* n'a AUCUNE route moteur — les écrans qui l'appelaient (Vie deuil, Journal trajectoires, Dots missions) sont retirés ; on vérifie désormais qu'aucun appel client n'y subsiste.
grep -rqE "api\.(get|post)\(\"/api/missions" web/js && { echo "  FAIL appel client vers /api/missions (route absente du moteur)"; FAIL=1; } || echo "  OK  aucun appel client vers /api/missions (route absente du moteur)"
grep -q "deep" web/js/depth.js && grep -q "depthBody" web/js/modules/dots.js && grep -q "depthBody" web/js/modules/agent.js && echo "  OK  n°14 profondeurs branchées (accueil + agent)" || { echo "  FAIL n°14 non branché"; FAIL=1; }
grep -q "api/ame/llm" web/js/modules/relations.js && grep -q "api/journal" web/js/modules/journal.js && echo "  OK  n°10 relations + n°17/n°2 journal présents" || { echo "  FAIL modules vague 3 incomplets"; FAIL=1; }
grep -q "loadAudit" web/js/modules/systeme.js && echo "  OK  C6 audit complet dans systeme.js" || { echo "  FAIL C6 absent de systeme.js"; FAIL=1; }
echo "── 6b. META-MUSE (26/10) : famille Meta Model API branchée, Contributor actif sur ordre nommé ──"
grep -q '"wonder-1.0"' Sources/NovaCore/Brains.swift && grep -q 'muse-wonder-1.0' Sources/NovaCore/Brains.swift && echo "  OK  Muse Wonder (muse-wonder-1.0) au catalogue" || { echo "  FAIL Wonder absent du catalogue"; FAIL=1; }
grep -q '"spark-1.2"' Sources/NovaCore/Brains.swift && echo "  OK  repli Spark 1.2 au catalogue" || { echo "  FAIL Spark 1.2 absent"; FAIL=1; }
python3 -c "
import re
s = open('Sources/NovaCore/Brains.swift').read()
def decl(name):
    m = re.search(r'static let ' + name + r'\b[^=\n]*= \[([^\]]*)\]', s)   # PHASE 1 : ancre sur la déclaration (l'ancienne regex tombait sur un commentaire)
    return m.group(1) if m else ''
assert 'spark-1.3-contributor' not in decl('stagedDisabledByDefault'), 'Contributor re-desactive par code'
assert 'spark-1.3-contributor' not in decl('hiddenByDefault'), 'Contributor re-masque'
# PHASE 1 : tetes de chaine alignees sur la politique en vigueur « Claude d'abord » (decision d'Ahadi du 29/10, Brains.swift) ;
# l'ancienne exigence « Muse d'abord » (26/10) est caduque. La regle 7 (Contributor jamais automatique) reste exigee, elargie.
head = lambda o: decl(o).split(',')[0].strip().strip(chr(34))
assert head('fastOrder') == 'spark-1.3', 'fastOrder doit demarrer par Spark 1.3 (version Meta)'
assert head('bulkOrder') == 'spark-1.3', 'bulkOrder doit demarrer par Spark 1.3 (version Meta)'
assert head('deepOrder') == 'spark-1.3', 'deepOrder doit demarrer par Spark 1.3 (version Meta)'
for o in ('fastOrder','bulkOrder','deepOrder'): assert 'contributor' not in decl(o) and 'muse-code' not in decl(o), 'Contributor/Muse Code dans ' + o + ' : interdit en chaine auto (mission regle 7)'
print('  OK  Contributor EXPLICITE SEULEMENT (mission regle 7) : catalogue oui, chaines auto non ; tetes Spark 1.3 (version Meta)')"
[ $? -ne 0 ] && FAIL=1
grep -q '"/api/meta/status"' Sources/NovaCore/MetaCapabilities.swift && grep -q 'muse-image-1.0' Sources/NovaCore/MetaCapabilities.swift && grep -q 'sam-3.1' Sources/NovaCore/MetaCapabilities.swift && grep -q 'muse-voice-transcribe-1.0' Sources/NovaCore/MetaCapabilities.swift && echo "  OK  capacités Muse Image / SAM 3.1 / Voice + route /api/meta/status" || { echo "  FAIL capacités Meta incomplètes"; FAIL=1; }
grep -q 'confirm_cloud' Sources/NovaCore/MetaCapabilities.swift && echo "  OK  garde Politique A (confirm_cloud par appel) sur les routes cloud Meta" || { echo "  FAIL garde confirm_cloud absente"; FAIL=1; }
grep -q 'metaRoutes()' Sources/NovaCore/Extras.swift && echo "  OK  routes Meta enregistrées (Extras.extraRoutes)" || { echo "  FAIL metaRoutes non branchée"; FAIL=1; }
grep -q '"meta"' Sources/NovaCore/App.swift && echo "  OK  slot de clé « Meta Model API » dans Réglages (nova-meta)" || { echo "  FAIL slot clé Meta absent"; FAIL=1; }
echo "── 6c. MUSE PARTOUT (26/10, ordre d'Ahadi) : outils et agents sur Muse par défaut ──"
N=$(grep -rl "MUSE-PARTOUT" Sources/NovaCore/*.swift | wc -l | tr -d ' '); echo "  fichiers basculés Muse par défaut : $N (attendu ≥ 7)"; [ "$N" -ge 7 ] || FAIL=1
# PHASE 1 : « aucun défaut épinglé Claude » contredisait la politique du 29/10 (Claude d'abord ; Feat_AutoEval épingle Haiku).
# Contrôle remplacé par la règle de confidentialité toujours en vigueur : aucun défaut épinglé sur un palier Contributor / Muse Code.
grep -rnE 'preferred: "(spark-1\.[0-9]-contributor|muse-code)' Sources/NovaCore/*.swift | grep . && { echo "  FAIL un défaut est épinglé sur un palier Contributor / Muse Code"; FAIL=1; } || echo "  OK  aucun défaut épinglé sur un palier Contributor / Muse Code"
grep -q 'chairPreferred: \[String\] = \["wonder-1.0"\]' Sources/NovaCore/Council.swift && echo "  OK  Conseil présidé par Muse Wonder" || { echo "  FAIL présidence du Conseil non Muse"; FAIL=1; }
grep -q 'v7-premium.css' web/css/app.css && grep -q 'css/app.css' web/index.html && echo "  OK  finition visuelle V7 incluse dans la feuille unique app.css (chargée par index.html)" || { echo "  FAIL V7 absente d app.css ou app.css non chargée"; FAIL=1; }
echo "── 7. NOVA2-DOC : production documentaire CAFU (PDF / Office / XLSX / aperçus) ──"
grep -q "Livrables.register" Sources/NovaCore/Extras.swift && echo "  OK  routes /api/livrables enregistrées (Extras.swift)" || { echo "  FAIL routes livrables non enregistrées"; FAIL=1; }
grep -q "LivrableHooks.htmlToPDF" Sources/NovaMac/main.swift && echo "  OK  hook de rendu PDF (WebKit + pagination) dans NovaMac" || { echo "  FAIL hook PDF absent de main.swift"; FAIL=1; }
grep -q "nova-livrable" web/js/core.js && echo "  OK  carte livrable dans le fil de conversation (core.js)" || { echo "  FAIL carte livrable absente de core.js"; FAIL=1; }
grep -q "cafu_format_pdf" Sources/NovaCore/Tools.swift && grep -q "cafu_format_table" Sources/NovaCore/Tools.swift && echo "  OK  outils chat cafu_format_pdf / cafu_format_table (Tools.swift)" || { echo "  FAIL outils chat PDF/table absents de Tools.swift"; FAIL=1; }
echo "── 8. Vague 3 : doctrine ZÉRO ÉCHEC + skills de la maison ──"
[ "$(grep -c '## 9. Doctrine' Sources/NovaCore/AmePack.swift)" = "2" ] && echo "  OK  doctrine §9 dans AmePack (fullText + promptBlock)" || { echo "  FAIL doctrine §9 absente ou incomplète dans AmePack.swift"; FAIL=1; }
[ "$(grep -c "ARRIÈRE-PLAN D'ABORD" Sources/NovaCore/AmePack.swift)" -ge 2 ] && echo "  OK  règle verrouillée ARRIÈRE-PLAN D'ABORD dans le prompt effectif" || { echo "  FAIL règle arrière-plan absente du prompt"; FAIL=1; }
grep -q "NovaSkills" Sources/NovaCore/Skills.swift && echo "  OK  magasin NovaSkills : store runtime Paths.home/skills (l'ancien chemin ../nova-skills n'existe plus — vérif alignée le 26/10)" || { echo "  FAIL magasin skills absent"; FAIL=1; }
echo "── 9. PHASE 1 : cliquets (base Phase 0, docs/NOVA_STATE.md §2) ──"
NF=$(ls Sources/NovaCore/Feat_*.swift | wc -l | tr -d ' ')
echo "  fichiers Feat_* : $NF (cliquet : ≤ 89)"; [ "$NF" -le 89 ] || { echo "  FAIL cliquet Feat_* dépassé (nouveau Feat_* interdit sauf exigence du brief)"; FAIL=1; }
python3 - << 'PYEOF9'
import glob, sys
def biggest(paths):
    best = (0, "")
    for f in paths:
        try: n = sum(1 for _ in open(f, encoding="utf-8", errors="replace"))
        except OSError: continue
        best = max(best, (n, f))
    return best
sw = biggest(glob.glob("Sources/**/*.swift", recursive=True))
wb = biggest([f for f in glob.glob("web/**/*.*", recursive=True) if f.endswith((".js", ".css", ".html")) and "/vendor/" not in f])
ok = True
for (n, f), cap, what in ((sw, 1926, "Swift (App.swift, Phase 0)"), (wb, 5768, "web hors vendor/ (app.css, Phase 0)")):
    good = n <= cap; ok = ok and good
    print(f"  {'OK  ' if good else 'FAIL'} plus gros fichier {what} : {f} = {n} lignes (cliquet ≤ {cap})")
sys.exit(0 if ok else 1)
PYEOF9
[ $? -ne 0 ] && FAIL=1
echo "── 10. PHASE 1 : motifs de secrets (fichiers suivis + non suivis non ignorés) ──"
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks dir . --config .gitleaks.toml --redact --no-banner >/tmp/nova2_gitleaks.txt 2>&1; then echo "  OK  gitleaks : aucun secret ($(gitleaks version 2>/dev/null))"
  else echo "  FAIL gitleaks : secret probable (valeurs masquées) :"; grep -E "File:|RuleID:|Line:" /tmp/nova2_gitleaks.txt | head -20; FAIL=1; fi
else
  # Repli sans gitleaks : motifs à forte confiance (clé complète, pas un préfixe). Valeurs jamais affichées : fichier:ligne seulement.
  python3 - << 'PYEOF10'
import re, subprocess, sys
RX = re.compile(r'sk-ant-[A-Za-z0-9_-]{20,}|sk-(?:proj-)?[A-Za-z0-9]{32,}|(?:AKIA|ASIA)[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,}'
                r'|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----|hf_[A-Za-z0-9]{30,}|https://[0-9a-f]{32}@[a-z0-9.]*sentry\.io')
import os
g = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "-z"], capture_output=True)
files = g.stdout.decode("utf-8", "replace").split("\0") if g.returncode == 0 else []
if not [f for f in files if f]:   # git indisponible (worktree dont le .git pointe vers la VM) : parcours du disque, dossiers ignorés exclus
    skip = {".git", ".build", "build", "releves", "dormant", "dsym-archive", "node_modules"}
    files = []
    for r, ds, ns in os.walk("."):
        ds[:] = [d for d in ds if d not in skip]
        files += [os.path.relpath(os.path.join(r, n)) for n in ns]
hits = []
for f in files:
    if not f or f.startswith("web/vendor/"): continue
    try: data = open(f, "rb").read()
    except OSError: continue
    if b"\0" in data[:8000]: continue   # binaire
    for i, line in enumerate(data.decode("utf-8", "replace").split("\n"), 1):
        if RX.search(line): hits.append(f"{f}:{i}")
if hits:
    print("  FAIL motif de secret (fichier:ligne, valeur jamais affichée) :"); [print("   ", h) for h in hits[:20]]; sys.exit(1)
print(f"  OK  aucun motif de secret dans {len([f for f in files if f])} fichiers (repli Python : gitleaks absent de cette machine)")
PYEOF10
  [ $? -ne 0 ] && FAIL=1
fi
echo "── 11. PHASE 1 : swift build + swift test sous Thread Sanitizer ──"
if [ "${NOVA_VERIFY_SKIP_SWIFT:-0}" = "1" ]; then
  echo "  SAUTÉ  NOVA_VERIFY_SKIP_SWIFT=1 (contrôles statiques seulement — ce n'est PAS un vert complet)"; FAIL=1
elif ! command -v swift >/dev/null 2>&1; then
  echo "  FAIL swift absent : tests non exécutés"; FAIL=1
else
  # Même dossier de build que tools/build_watch.sh (dépôt principal) : pas de second .build dans un worktree (disque).
  GCD=$(git rev-parse --git-common-dir 2>/dev/null)
  if [ -n "${NOVA_SCRATCH:-}" ]; then SCRATCH="$NOVA_SCRATCH"
  elif [ -n "$GCD" ] && [ -d "$GCD" ]; then SCRATCH="$(cd "$GCD/.." && pwd)/.build"
  else case "$PWD" in */Nova2-wt/*) SCRATCH="${PWD%%/Nova2-wt/*}/Nova2/.build" ;; *) SCRATCH="$PWD/.build" ;; esac; fi   # worktree dont le .git pointe ailleurs (VM)
  echo "  dossier de build : $SCRATCH"
  T0=$(date +%s)
  TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=0 second_deadlock_stack=1}" swift test --package-path . --scratch-path "$SCRATCH" --sanitize=thread > /tmp/nova2_tsan.txt 2>&1
  RC=$?
  NT=$(grep -c "WARNING: ThreadSanitizer" /tmp/nova2_tsan.txt)
  grep -E "Executed [0-9]+ tests?|error:|failed \(" /tmp/nova2_tsan.txt | grep -v "^Test Case.*passed" | tail -12 | sed 's/^/  /'
  echo "  swift test --sanitize=thread : code $RC, avertissements TSan $NT, $(( $(date +%s) - T0 )) s"
  if [ $RC -ne 0 ]; then echo "  FAIL tests (ou TSan) en échec"; FAIL=1; fi
  if [ "$NT" -ne 0 ]; then echo "  FAIL Thread Sanitizer : $NT course(s) — premières piles :"; grep -A6 "WARNING: ThreadSanitizer" /tmp/nova2_tsan.txt | grep -E "WARNING|#[0-3] " | head -24 | sed 's/^/    /'; FAIL=1; fi
  grep -qE "Executed [0-9]+ tests" /tmp/nova2_tsan.txt || { echo "  FAIL aucun test exécuté"; FAIL=1; }
fi
echo "── 12. PHASE 5 : présence 3D optionnelle (chargement à la demande, aucun réseau, 5 états) ──"
node tools/test_presence3d.mjs || FAIL=1
echo "── 13. PILOTAGE (01/11) : navigation interne déterministe (résolution des écrans, sections, lignes) ──"
node tools/test_pilotage.mjs || FAIL=1
echo
[ $FAIL -eq 0 ] && echo "✅ VÉRIFICATION NOVA 2 : TOUT PASSE" || echo "❌ VÉRIFICATION NOVA 2 : ÉCHECS (voir ci-dessus)"
exit $FAIL
