#!/usr/bin/env python3
"""Phase 4 — vide en JSON les propriétés personnalisées CALCULÉES sur <html> et <body>, et quelques styles calculés
d'éléments de la coquille (#rail, #view, .rail-btn), pour chaque thème × mode × préférence d'accessibilité.
Sert de test de non-régression des jetons : dump avant / après, puis diff (doit être vide).
Usage : python3 tools/ui/root_vars_dump.py sortie.json"""
import os, sys, json, time, subprocess
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__)); port = int(os.environ.get("PORT", "8798"))   # PORT : deux dumps en parallèle (NOVA_WEB=<base> pour l'avant)
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(port)]); time.sleep(0.8)
MATS = ["harmattan", "fleuve", "sentinelle", "obsidienne", "verre", "graphite", "sable"]
JS = """() => { const out = {}; for (const [k, el] of [["html", document.documentElement], ["body", document.body],
 ["rail", document.getElementById("rail")], ["view", document.getElementById("view")], ["btn", document.querySelector(".rail-btn")]]) {
 if (!el) continue; const cs = getComputedStyle(el); const o = {};
 for (let i = 0; i < cs.length; i++) { const p = cs[i]; if (k === "html" || k === "body" || !p.startsWith("--")) o[p] = cs.getPropertyValue(p).trim(); }
 out[k] = o; } return out; }"""
res = {}
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        for mat in MATS:
            for mode in ["jour", "nuit"]:
                for pref in ["base", "contrast", "transparency", "motion"]:
                    ctx = b.new_context(viewport={"width": 1100, "height": 700}, color_scheme="dark" if mode == "nuit" else "light",
                                        reduced_motion="reduce" if pref == "motion" else "no-preference")
                    ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s-%s');localStorage.setItem('nova2_identite_v1','1');}catch(e){}" % (mat, mode))
                    pg = ctx.new_page()
                    if pref in ("contrast", "transparency"):
                        c = ctx.new_cdp_session(pg)
                        c.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-contrast", "value": "more"}] if pref == "contrast" else [{"name": "prefers-reduced-transparency", "value": "reduce"}]})
                    pg.goto("http://127.0.0.1:%d/index.html#settings" % port); pg.wait_for_timeout(900)
                    res["%s-%s-%s" % (mat, mode, pref)] = pg.evaluate(JS)
                    ctx.close()
        b.close()
finally:
    srv.terminate()
json.dump(res, open(sys.argv[1], "w"), indent=0, sort_keys=True)
print("combinaisons:", len(res))
