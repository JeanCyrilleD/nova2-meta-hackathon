#!/usr/bin/env python3
"""Phase 4 v2 — PREUVE « rendu identique » : captures avant (web/ du commit de base, servi tel quel) / après (web/ du
worktree) de chaque écran existant × thème, mêmes données SIMULÉES (mock_server.py), même horloge figée, animations
CSS figées (screenshot animations="disabled"), puis diff de pixels (seuil 8 niveaux par canal, comme png_diff.py). Neutralisés (rendus invisibles des deux côtés, sans effet de mise en page) : .pv-companion (avatar 3D animé) et
#spatialbg + #lgcanvas (fond WebGL et réfraction « Liquid Glass » animés : bruit de trame mesuré même base contre base) ;
bg.js, glass.js et les avatars sont
identiques octet pour octet à la base.
Côté « après » : une capture « sans les 2 entrées de navigation ajoutées » (boutons Approbations et
Coûts retirés du DOM du rail juste avant la capture) — c'est celle-ci qui doit valoir 0 pixel ; et, pour les écrans de RAW_FOR (défaut : accueil), la capture brute.
Usage : python3 tools/ui/compare_base.py <web_de_base> <dossier_sortie> [ecran ...]
Env : THEMES (défaut : les 14 thèmes jour/nuit), SMALL=1 (copie réduite quantifiée dans <sortie>/png pour docs/)."""
import os, sys, time, json, subprocess
from playwright.sync_api import sync_playwright
from PIL import Image, ImageChops
HERE = os.path.dirname(os.path.abspath(__file__))
base_web, out = sys.argv[1], sys.argv[2]
SCREENS = sys.argv[3:] or ["accueil", "conversations", "attente", "messages", "veille", "finance", "temps", "dots", "engagements", "systeme"]
MATS = ["harmattan", "fleuve", "sentinelle", "obsidienne", "verre", "graphite", "sable"]
THEMES = os.environ.get("THEMES", ",".join(m + "-" + x for m in MATS for x in ("jour", "nuit"))).split(",")
raw = os.path.join(out, "raw"); small = os.path.join(out, "png"); os.makedirs(raw, exist_ok=True); os.makedirs(small, exist_ok=True)
def serve(web, port):
    env = dict(os.environ, NOVA_WEB=os.path.abspath(web)); return subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(port)], env=env)
PA = int(os.environ.get("PORT", "8811")); PB = PA + 1
RAW_FOR = os.environ.get("RAW_FOR", "accueil").split(",")   # écrans où l'on garde aussi la capture « après » brute (avec les 2 entrées du rail)
srvA = serve(base_web, PA); srvB = serve(os.environ.get("NOVA_WEB_B") or os.path.join(HERE, "..", "..", "web"), PB)   # NOVA_WEB_B=<base> : mesure du bruit (base contre base); time.sleep(1.0)
SEL = lambda s: '.rail-conv-btn' if s == "conversations" else '.rail-btn[data-page="%s"]' % s
DROP_NEW = """(scr) => {
  for (const id of ['taches', 'couts']) document.querySelectorAll('.rail-btn[data-page="' + id + '"]').forEach(e => e.remove());
  /* Le rail fait défiler l'entrée active dans la vue (shell.js revealRailBtn) : avec 2 entrées de plus, le défilement
     diffère. On rejoue la même arithmétique depuis 0, après retrait, pour comparer à l'identique. */
  const z = document.querySelector('.rail-mods'); if (!z) return;
  z.scrollTop = 0;
  const b = scr === 'conversations' ? document.querySelector('.rail-conv-btn') : z.querySelector('.rail-btn[data-page="' + scr + '"]');
  if (b && z.contains(b) && b.offsetParent) { const zr = z.getBoundingClientRect(), br = b.getBoundingClientRect();
    if (br.top < zr.top + 4) z.scrollTop -= (zr.top + 4 - br.top); else if (br.bottom > zr.bottom - 10) z.scrollTop += (br.bottom - zr.bottom + 10); }
  z.dispatchEvent(new Event('scroll'));
}"""
def diff(a, b):
    A, B = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if A.size != B.size: return None, None
    d = ImageChops.difference(A, B).convert("L").point(lambda v: 255 if v > 8 else 0)
    return d.histogram()[255], d.getbbox()
def shoot(b, port, theme, scr, path, drop=False):
    mode = theme.rsplit("-", 1)[1]
    ctx = b.new_context(viewport={"width": 1280, "height": 800}, device_scale_factor=1, color_scheme="dark" if mode == "nuit" else "light", reduced_motion="no-preference")
    ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s');localStorage.setItem('nova2_identite_v1','1');}catch(e){}" % theme)
    pg = ctx.new_page(); errs = []; pg.on("pageerror", lambda e: errs.append(str(e)[:140]))
    # Horloge SIMULÉE (Date, performance.now, minuteries, requestAnimationFrame) avancée par pas identiques des deux côtés :
    # le fond animé WebGL, l'anneau du jour et les minuteries d'écran rendent la même trame (sinon : bruit mesuré base contre base).
    pg.clock.install(time="2026-10-31T10:00:00Z")
    def tick(n):
        for _ in range(n): pg.clock.run_for(250); pg.wait_for_timeout(120)
    pg.goto("http://127.0.0.1:%d/index.html" % port); tick(8)
    if scr != "accueil": pg.evaluate("(s) => { const e = document.querySelector(s); if (e) e.click(); }", SEL(scr)); tick(11)
    else: tick(4)
    if drop: pg.evaluate(DROP_NEW, scr); tick(1)
    pg.mouse.move(1279, 799)
    # Seul élément neutralisé (des deux côtés) : le compagnon 3D animé (WebGL, il flotte et change à chaque trame) est rendu
    # invisible (visibility:hidden — aucune incidence sur la mise en page) ; ce qu'il recouvre est donc comparé aussi.
    # Idem pour le fond WebGL animé #spatialbg (le fond statique qu'il recouvre est comparé).
    pg.add_style_tag(content=".pv-companion,#spatialbg,#lgcanvas{visibility:hidden!important}"); tick(1)
    pg.screenshot(path=path, animations="disabled", caret="hide")
    ctx.close(); return errs
res = []
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        for th in THEMES:
            for scr in SCREENS:
                n = "%s-%s" % (scr, th)
                fa, fb, fbd = [os.path.join(raw, n + s + ".png") for s in ("-avant", "-apres", "-apres-sans-nouvelles-entrees")]
                ea = shoot(b, PA, th, scr, fa); eb = shoot(b, PB, th, scr, fbd, drop=True)
                px, box = diff(fa, fbd); px_raw, box_raw = None, None
                if scr in RAW_FOR: shoot(b, PB, th, scr, fb); px_raw, box_raw = diff(fa, fb)
                else: fb = fbd
                r = {"capture": n, "pixels_diff_sans_nouvelles_entrees": px, "boite": box, "pixels_diff_brut": px_raw, "boite_brut": box_raw, "erreurs_js_avant": len(ea), "erreurs_js_apres": len(eb)}
                res.append(r); print(json.dumps(r, ensure_ascii=False), flush=True)
                with open(os.path.join(out, "diff.jsonl"), "a") as f: f.write(json.dumps(r, ensure_ascii=False) + "\n")
                if os.environ.get("SMALL") == "1":
                    for f, suf in ((fa, "avant"), (fb, "apres")):
                        Image.open(f).convert("RGB").resize((640, 400), Image.LANCZOS).quantize(colors=96, method=Image.Quantize.MEDIANCUT).save(os.path.join(small, n + "-" + suf + ".png"), optimize=True)
        b.close()
finally:
    srvA.terminate(); srvB.terminate()
