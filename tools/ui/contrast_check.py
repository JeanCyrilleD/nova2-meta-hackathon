#!/usr/bin/env python3
"""Phase 4 — contraste MESURÉ sur les jetons (WCAG 2.x, seuil 4,5:1 pour le texte) dans chaque thème × mode,
avec et sans « Augmenter le contraste ». Les couleurs sont RÉSOLUES par Chromium (var(), color-mix(), alpha) puis
composées sur la surface pleine par un canevas : on mesure ce qui s'affiche, pas ce qui est écrit.
v2 (décision d'Ahadi 31/10 19:51, rendu d'avant gardé) : surfaces = --pane-solid (surface pleine EXISTANTE des thèmes) ; le
rendu par défaut est mesuré pour information seulement ; le code 1 ne concerne que « Augmenter le contraste », seul mode corrigé.
Usage : python3 tools/ui/contrast_check.py [--json sortie.json]   → code 1 si une paire « contraste plus » est sous le seuil."""
import os, sys, json, time, subprocess
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__)); port = 8796
MATS = ["harmattan", "fleuve", "sentinelle", "obsidienne", "verre", "graphite", "sable"]
SURF = ["--pane-solid"]
TEXT = ["--text-1", "--text-2", "--text-3"]
EXTRA = []
JS = """([surf, text, extra]) => {
  const probe = document.createElement('i'); document.body.append(probe);
  const cv = document.createElement('canvas'); cv.width = cv.height = 1; const g = cv.getContext('2d', { willReadFrequently: true });
  const res = (v) => { probe.style.color = 'var(' + v + ')'; return getComputedStyle(probe).color; };
  const px = (layers) => { g.clearRect(0, 0, 1, 1); g.globalCompositeOperation = 'source-over'; for (const c of layers) { g.fillStyle = '#000'; g.fillStyle = c; g.fillRect(0, 0, 1, 1); } return Array.from(g.getImageData(0, 0, 1, 1).data); };
  const out = []; const pairs = [];
  for (const s of surf) for (const t of text) pairs.push([t, s]);
  for (const p of extra) pairs.push(p);
  for (const [t, s] of pairs) {
    const sc = res(s), tc = res(t);
    const bg = px([sc]); const fg = px([sc, tc]);
    out.push({ text: t, surface: s, surface_css: sc, text_css: tc, bg, fg });
  }
  probe.remove(); return out; }"""
def lum(c):
    def ch(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])
def ratio(a, b):
    la, lb = lum(a), lum(b); hi, lo = max(la, lb), min(la, lb); return (hi + 0.05) / (lo + 0.05)
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(port)]); time.sleep(0.8)
rows = []
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        for mat in MATS:
            for mode in ["jour", "nuit"]:
                for pref in ["base", "contrast"]:
                    ctx = b.new_context(color_scheme="dark" if mode == "nuit" else "light")
                    ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s-%s');localStorage.setItem('nova2_identite_v1','1');}catch(e){}" % (mat, mode))
                    pg = ctx.new_page()
                    if pref == "contrast":
                        ctx.new_cdp_session(pg).send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-contrast", "value": "more"}]})
                    pg.goto("http://127.0.0.1:%d/index.html" % port); pg.wait_for_timeout(700)
                    for r in pg.evaluate(JS, [SURF, TEXT, EXTRA]):
                        r.update(theme="%s-%s" % (mat, mode), pref=pref, ratio=round(ratio(r["fg"], r["bg"]), 2), opaque=r["bg"][3] == 255)
                        rows.append(r)
                    ctx.close()
        b.close()
finally:
    srv.terminate()
bad = [r for r in rows if r["ratio"] < 4.5 or not r["opaque"]]
info = [r for r in bad if r["pref"] != "contrast"]; bad = [r for r in bad if r["pref"] == "contrast"]
print("rendu par défaut (inchangé, information) : paires sous 4,5:1 :", len(info))
print("paires mesurées :", len(rows), "· « contraste plus » sous 4,5:1 ou surface non pleine :", len(bad))
for r in sorted(bad, key=lambda r: r["ratio"])[:60]:
    print("  %-18s %-8s %-16s sur %-24s %5.2f%s" % (r["theme"], r["pref"], r["text"], r["surface"], r["ratio"], "" if r["opaque"] else "  (SURFACE NON PLEINE)"))
mins = {}
for r in rows: mins[r["text"]] = min(mins.get(r["text"], 99), r["ratio"])
print("minimum par jeton de texte :", ", ".join("%s %.2f" % kv for kv in sorted(mins.items())))
if "--json" in sys.argv: json.dump(rows, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=0)
sys.exit(1 if bad else 0)
