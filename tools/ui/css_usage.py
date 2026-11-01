#!/usr/bin/env python3
"""Phase 4 — CSS MORTE prouvée par l'usage. Croise les sélecteurs des feuilles chargées au démarrage avec les noms
réellement présents dans le code (web/**/*.html, web/**/*.js, Sources/**/*.swift — le moteur injecte aussi du HTML).
Règle CONSERVATRICE : une classe / un id est « vivant » s'il apparaît comme MOT n'importe où dans ce corpus, ou si une
chaîne littérale du corpus finissant par « - » ou « _ » en est le préfixe (classes construites : "hq-seg-" + c).
Une règle est morte seulement si CHACUN de ses sélecteurs exige au moins une classe/un id mort hors :not()/:is()/:where()/:has().
@keyframes morte : nom absent de tout le corpus ET de toutes les feuilles (hors sa propre déclaration).
Usage : python3 tools/ui/css_usage.py [--apply app.css ...] [--report rapport.txt]"""
import os, re, sys, glob, tinycss2
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
WEB = os.path.join(ROOT, "web"); CSSD = os.path.join(WEB, "css")
SHEETS = ["app.css", "identite.css", "tokens.css", "motion.css", "layouts.css"]
files = [f for f in glob.glob(os.path.join(WEB, "**", "*.html"), recursive=True) + glob.glob(os.path.join(WEB, "**", "*.js"), recursive=True)
         if "/vendor/" not in f] + glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True)
corpus = "\n".join(open(f, encoding="utf-8", errors="ignore").read() for f in files)
words = set(re.findall(r"[A-Za-z_][A-Za-z0-9_-]*", corpus))
prefixes = set(m for m in re.findall(r"[\"'`\s.]([A-Za-z][A-Za-z0-9_-]*[-_])[\"'`$]", corpus) if len(m) >= 2)
prefixes |= set(m for m in re.findall(r"([A-Za-z][A-Za-z0-9_-]*[-_])\$\{", corpus) if len(m) >= 2)   # gabarits `x-${y}`
suffixes = set(re.findall(r"[\"'`}]([-_][A-Za-z0-9_-]+)[\"'`\s]", corpus))   # classes construites par la fin : base + "-row"
def alive(name):
    if name in words or any(name.startswith(p) for p in prefixes): return True
    return any(name.endswith(x) and name[:-len(x)] in words for x in suffixes if len(name) > len(x))
SEL_TOKEN = re.compile(r"([.#])(-?[A-Za-z_][A-Za-z0-9_-]*)")
def strip_functional(sel):
    out, depth, i = [], 0, 0
    while i < len(sel):
        m = re.match(r":(not|is|where|has|-webkit-any|matches)\(", sel[i:])
        if m and depth == 0:
            depth = 1; i += len(m.group(0)); continue
        if depth:
            if sel[i] == "(": depth += 1
            elif sel[i] == ")": depth -= 1
            i += 1; continue
        out.append(sel[i]); i += 1
    return "".join(out)
def selector_dead(sel):
    core = strip_functional(re.sub(r"\[[^\]]*\]", "", sel))   # attributs : jamais jugés
    toks = SEL_TOKEN.findall(core)
    dead = [n for k, n in toks if not alive(n)]
    return bool(dead), dead
def prelude_dead(prelude):
    s = tinycss2.serialize([t for t in prelude if t.type != "comment"]).strip()
    if not s: return False, []
    parts = [p.strip() for p in s.split(",")]
    res = [selector_dead(p) for p in parts]
    return all(d for d, _ in res), sorted(set(x for _, xs in res for x in xs))
allcss = {n: open(os.path.join(CSSD, n), encoding="utf-8").read() for n in SHEETS if os.path.exists(os.path.join(CSSD, n))}
def kf_alive(name, sheet_text_wo_decl):
    return name in words or any(re.search(r"(?<![A-Za-z0-9_-])" + re.escape(name) + r"(?![A-Za-z0-9_-])", t) for t in sheet_text_wo_decl)
def walk(nodes, stats, sheetname):
    keep = []
    for n in nodes:
        if n.type == "qualified-rule":
            d, names = prelude_dead(n.prelude)
            if d:
                stats["rules"] += 1; stats["bytes"] += len(tinycss2.serialize([n]).encode()); stats["names"].update(names); continue
        elif n.type == "at-rule" and n.lower_at_keyword in ("media", "supports", "layer", "container") and n.content is not None:
            inner = tinycss2.parse_rule_list(n.content, skip_whitespace=False, skip_comments=False)
            kept = walk(inner, stats, sheetname)
            if not [k for k in kept if k.type not in ("whitespace", "comment")]:
                stats["bytes"] += len(tinycss2.serialize([n]).encode()); continue
            n.content = list(tinycss2.parse_component_value_list(tinycss2.serialize(kept)))
        elif n.type == "at-rule" and n.lower_at_keyword.endswith("keyframes"):
            name = tinycss2.serialize(n.prelude).strip()
            others = [t.replace(tinycss2.serialize([n]), "") for t in allcss.values()]
            if name and not kf_alive(name, others):
                stats["keyframes"] += 1; stats["bytes"] += len(tinycss2.serialize([n]).encode()); stats["names"].add("@keyframes " + name); continue
        keep.append(n)
    return keep
apply = set(sys.argv[sys.argv.index("--apply") + 1:]) if "--apply" in sys.argv else set()
report = []
tot_before = tot_after = 0
for name, txt in allcss.items():
    nodes = tinycss2.parse_stylesheet(txt, skip_whitespace=False, skip_comments=False)
    st = {"rules": 0, "keyframes": 0, "bytes": 0, "names": set()}
    kept = walk(nodes, st, name)
    out = tinycss2.serialize(kept)
    b0, b1 = len(txt.encode()), len(out.encode()); tot_before += b0; tot_after += b1
    report.append("%-14s %8d o → %8d o  (règles mortes %d, @keyframes mortes %d)" % (name, b0, b1, st["rules"], st["keyframes"]))
    report.append("   noms morts (%d) : %s" % (len(st["names"]), " ".join(sorted(st["names"]))[:3000]))
    if name in apply: open(os.path.join(CSSD, name), "w", encoding="utf-8").write(out)
report.append("TOTAL feuilles du démarrage : %d o → %d o (%.1f %%)" % (tot_before, tot_after, 100.0 * (tot_before - tot_after) / max(1, tot_before)))
report.append("corpus : %d fichiers, %d mots, %d préfixes" % (len(files), len(words), len(prefixes)))
txt = "\n".join(report); print(txt)
if "--report" in sys.argv: open(sys.argv[sys.argv.index("--report") + 1], "w").write(txt + "\n")
