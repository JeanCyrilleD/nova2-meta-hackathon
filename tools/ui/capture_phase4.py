#!/usr/bin/env python3
"""Phase 4 v2 — captures des NOUVEAUX écrans (données SIMULÉES, PNG quantifiés) : Approbations, Coûts, alerte de coût
d'une profondeur plus chère (Éclats), entrées ⌘K. Les écrans existants sont prouvés par tools/ui/compare_base.py.
Usage : python3 tools/ui/capture_phase4.py docs/captures-phase4-v2/nouveaux"""
import os, sys, time, subprocess
from playwright.sync_api import sync_playwright
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__)); out = sys.argv[1]; os.makedirs(out, exist_ok=True); port = int(os.environ.get("PORT", "8793"))
ONLY = [x for x in os.environ.get("ONLY", "").split(",") if x]
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(port)]); time.sleep(0.8)
def shot(pg, name, full=False):
    p = os.path.join(out, name + ".png"); pg.screenshot(path=p, full_page=full)
    im = Image.open(p).convert("RGB")
    if im.height > 2400: im = im.crop((0, 0, im.width, 2400))
    im.quantize(colors=128, method=Image.Quantize.MEDIANCUT).save(p, optimize=True)
    print(name, os.path.getsize(p) // 1024, "Ko", flush=True)
def page(b, theme, feats=()):
    mode = theme.rsplit("-", 1)[1]
    ctx = b.new_context(viewport={"width": 1280, "height": 800}, color_scheme="dark" if mode == "nuit" else "light")
    ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s');localStorage.setItem('nova2_identite_v1','1');localStorage.setItem('nova2_depth','1');}catch(e){}" % theme)
    pg = ctx.new_page(); errs = []; pg.on("pageerror", lambda e: errs.append(str(e)[:120]))
    if feats: ctx.new_cdp_session(pg).send("Emulation.setEmulatedMedia", {"features": [{"name": n, "value": v} for n, v in feats]})
    pg.goto("http://127.0.0.1:%d/index.html" % port); pg.wait_for_timeout(2000)
    return ctx, pg, errs
def go(pg, mid, wait=2500):
    pg.evaluate("(s) => document.querySelector(s).click()", '.rail-btn[data-page="%s"]' % mid); pg.wait_for_timeout(wait)
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        def want(k): return not ONLY or k in ONLY
        if want("approbations"):
            for th, name, full in [("harmattan-nuit", "01-approbations-harmattan-nuit", True), ("fleuve-jour", "02-approbations-fleuve-jour", False), ("sentinelle-nuit", "03-approbations-sentinelle-nuit", False)]:
                ctx, pg, errs = page(b, th); go(pg, "taches", 13000); shot(pg, name, full); print("  erreurs JS :", errs); ctx.close()
        if want("couts"):
            ctx, pg, errs = page(b, "harmattan-nuit"); go(pg, "couts"); shot(pg, "04-couts-harmattan-nuit", True); print("  erreurs JS :", errs); ctx.close()
            ctx, pg, errs = page(b, "harmattan-jour", feats=[("prefers-contrast", "more")]); go(pg, "couts"); shot(pg, "05-couts-harmattan-jour-contraste-plus"); print("  erreurs JS :", errs); ctx.close()
        if want("alerte"):
            # Conversations : « Réfléchi ⌄ » ouvre les réglages de la conversation, puis clic réel sur « Conseil » (plus cher).
            ctx, pg, errs = page(b, "harmattan-nuit")
            pg.evaluate("() => document.querySelector('.rail-conv-btn').click()"); pg.wait_for_timeout(2500)
            pg.evaluate("() => { const s = [...document.querySelectorAll('button')].find(x => /^Profondeur de réflexion/.test(x.title || '') && x.offsetParent); if (s) s.click(); }"); pg.wait_for_timeout(700)
            pg.evaluate("() => { const b = [...document.querySelectorAll('.seg button')].find(x => x.textContent.trim() === 'Conseil' && x.offsetParent); if (b) { b.scrollIntoView({ block: 'center' }); b.click(); } }")
            pg.wait_for_timeout(900)
            print("  alerte affichée :", pg.evaluate("() => !!document.querySelector('.depth-costalert')"))
            pg.evaluate("() => { const c = document.querySelector('.depth-costalert'); if (c) c.scrollIntoView({ block: 'center' }); }"); pg.wait_for_timeout(300)
            shot(pg, "06-alerte-cout-conseil-conversations-harmattan-nuit"); print("  erreurs JS :", errs); ctx.close()
        if want("palette"):
            ctx, pg, errs = page(b, "harmattan-nuit")
            pg.evaluate("() => document.querySelector('.sb-search').click()"); pg.wait_for_timeout(500)
            pg.keyboard.type("Approb"); pg.wait_for_timeout(500); shot(pg, "07-palette-approbations-harmattan-nuit")
            pg.keyboard.press("Escape"); pg.wait_for_timeout(300)
            pg.evaluate("() => document.querySelector('.sb-search').click()"); pg.wait_for_timeout(500)
            pg.keyboard.type("Profondeur"); pg.wait_for_timeout(500); shot(pg, "08-palette-profondeur-harmattan-nuit")
            pg.keyboard.press("Enter"); pg.wait_for_timeout(600); shot(pg, "09-palette-profondeurs-liste-harmattan-nuit")
            pg.keyboard.press("Escape"); pg.wait_for_timeout(300)
            pg.evaluate("() => document.querySelector('.sb-search').click()"); pg.wait_for_timeout(500)
            pg.keyboard.type("Touch ID"); pg.wait_for_timeout(500); shot(pg, "10-palette-coffre-touchid-harmattan-nuit")
            print("  erreurs JS :", errs); ctx.close()
        b.close()
finally:
    srv.terminate()
