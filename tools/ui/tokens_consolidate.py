#!/usr/bin/env python3
"""Phase 4 — regroupe dans web/css/tokens.css (fichier UNIQUE des jetons) toutes les règles de NIVEAU RACINE
(:root / html[...] , aussi dans @media) qui ne déclarent QUE des propriétés personnalisées (--x), prises dans
app.css puis identite.css, dans leur ordre de cascade, AVANT le contenu existant de tokens.css.
Les règles mixtes (propriétés ordinaires + --x) restent en place. Mode --dry : rapport seulement.
Preuve d'innocuité : tools/ui/root_vars_dump.py avant/après (diff des variables calculées sur <html>)."""
import re, sys, os, tinycss2
HERE = os.path.dirname(os.path.abspath(__file__)); CSS = os.path.join(HERE, "..", "..", "web", "css")
ROOT = re.compile(r'^\s*(?::root|html)(?:\[[^\]]*\]|:not\((?:[^()]|\([^)]*\))*\)|:root)*\s*$')
def is_root_sel(prelude):
    s = tinycss2.serialize([t for t in prelude if t.type != "comment"])
    return all(ROOT.match(p) for p in s.split(",")) if s.strip() else False
def pure_vars(rule):
    decls = [d for d in tinycss2.parse_blocks_contents(rule.content, skip_whitespace=True, skip_comments=True) if d.type == "declaration" or d.type == "error"]
    return bool(decls) and all(d.type == "declaration" and d.name.startswith("--") for d in decls)
def movable(node):
    if node.type == "qualified-rule": return is_root_sel(node.prelude) and pure_vars(node)
    if node.type == "at-rule" and node.at_keyword == "media" and node.content:
        inner = [n for n in tinycss2.parse_rule_list(node.content, skip_whitespace=True, skip_comments=True)]
        return bool(inner) and all(n.type == "qualified-rule" and movable(n) for n in inner)
    return False
NODES = {}
def split(path):
    nodes = tinycss2.parse_stylesheet(open(path, encoding="utf-8").read(), skip_whitespace=False, skip_comments=False)
    NODES[path] = nodes
    keep, move = [], []
    for n in nodes:
        (move if movable(n) else keep).append(n)
    return keep, move
def var_names(node):
    if node.type == "qualified-rule":
        return {d.name for d in tinycss2.parse_blocks_contents(node.content, skip_whitespace=True, skip_comments=True) if d.type == "declaration" and d.name.startswith("--")}
    if node.type == "at-rule" and node.content:
        r = set()
        for n in tinycss2.parse_rule_list(node.content, skip_whitespace=True, skip_comments=True): r |= var_names(n)
        return r
    return set()
def root_level(node):
    if node.type == "qualified-rule": return is_root_sel(node.prelude)
    if node.type == "at-rule" and node.content:
        return any(root_level(n) for n in tinycss2.parse_rule_list(node.content, skip_whitespace=True, skip_comments=True))
    return False
# Garde-fou de cascade : une règle d'app.css ne part que si AUCUNE règle racine restée dans identite.css
# (feuille chargée entre app.css et tokens.css) ne déclare l'une de ses variables.
ID_KEEP, _ = split(os.path.join(CSS, "identite.css"))
BLOCKED = set().union(*[var_names(n) for n in ID_KEEP if root_level(n)])
dry = "--dry" in sys.argv
moved_txt = []
for name in ["app.css", "identite.css"]:
    p = os.path.join(CSS, name)
    keep, move = split(p)
    if name == "app.css":
        back = [n for n in move if var_names(n) & BLOCKED]
        move = [n for n in move if n not in back]
        keep = keep + back   # l'ordre réel est rétabli ci-dessous
        print("app.css : règles gardées en place (conflit de cascade possible)", len(back))
    ids = {id(n) for n in move}
    keep = [n for n in NODES[p] if id(n) not in ids]
    mt = "".join(tinycss2.serialize([n]) for n in move)
    print(name, ": règles déplacées", len(move), "·", len(mt.encode()), "octets")
    moved_txt.append("/* ── Jetons venus de %s (ordre de cascade conservé) ── */\n%s\n" % (name, "\n".join(tinycss2.serialize([n]) for n in move)))
    if not dry:
        open(p, "w", encoding="utf-8").write(tinycss2.serialize(keep))
if not dry:
    t = os.path.join(CSS, "tokens.css"); old = open(t, encoding="utf-8").read()
    head = ("/* tokens.css — FICHIER UNIQUE DES JETONS DE DESIGN de Nova 2 (Phase 4, 31/10/2026 ; règles : docs/DESIGN_RULES.md).\n"
            "   Partie A : jetons de thème anciennement dispersés dans app.css et identite.css, déplacés ici par\n"
            "   tools/ui/tokens_consolidate.py SANS modification (même ordre ; variables calculées identiques : tools/ui/root_vars_dump.py).\n"
            "   Partie B : système « NOVA Liquid Glass » (Gemini) + pont. Partie C (fin) : jetons Phase 4 (surfaces pleines, espacement,\n"
            "   rayons, mouvement, préférences d'accessibilité). Aucune autre feuille ne doit déclarer de jeton global. */\n")
    open(t, "w", encoding="utf-8").write(head + "".join(moved_txt) + "\n/* ══ Partie B ══ */\n" + old)
