#!/usr/bin/env python3
"""Phase 4 — captures sans tête (Playwright/Chromium) de web/ servi par mock_server.py (données SIMULÉES).
Usage : python3 tools/ui/capture.py <dossier_sortie> [page ...]   ex. accueil couts approbations
Options d'environnement : THEMES="harmattan-nuit,harmattan-jour" ; EMULATE="reduce-motion,more-contrast,reduce-transparency"."""
import os, sys, time, subprocess, json
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1]; pages = sys.argv[2:] or ["accueil"]
os.makedirs(out, exist_ok=True)
port = 8799
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(port)])
time.sleep(0.8)
themes = os.environ.get("THEMES", "harmattan-nuit").split(",")
emu = [e for e in os.environ.get("EMULATE", "").split(",") if e]
W, Hh = int(os.environ.get("W", "1280")), int(os.environ.get("H", "800"))
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        for th in themes:
            mode = th.rsplit("-", 1)[1]
            ctx = b.new_context(viewport={"width": W, "height": Hh}, device_scale_factor=1,
                                color_scheme="dark" if mode == "nuit" else "light",
                                reduced_motion="reduce" if "reduce-motion" in emu else "no-preference",
                                forced_colors="none")
            ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s');localStorage.setItem('nova2_identite_v1','1');}catch(e){}" % th)
            pg = ctx.new_page()
            errs = []
            pg.on("pageerror", lambda e: errs.append(str(e)[:160]))
            if "more-contrast" in emu or "reduce-transparency" in emu:
                cdp = ctx.new_cdp_session(pg)
                feats = []
                if "more-contrast" in emu: feats.append({"name": "prefers-contrast", "value": "more"})
                if "reduce-transparency" in emu: feats.append({"name": "prefers-reduced-transparency", "value": "reduce"})
                cdp.send("Emulation.setEmulatedMedia", {"features": feats})
            for pgid in pages:
                if pg.url == "about:blank": pg.goto("http://127.0.0.1:%d/index.html" % port); pg.wait_for_timeout(1500)
                pg.click('.rail-btn[data-page="%s"]' % pgid)   # navigation réelle par le rail
                pg.wait_for_timeout(int(os.environ.get("WAIT", "2500")))
                bad = pg.evaluate("() => [...document.querySelectorAll('.errbox')].map(e => e.textContent.slice(0, 120))")
                if bad: errs.append("module en erreur : " + " | ".join(bad))
                tag = "-".join([pgid, th] + emu)
                pg.screenshot(path=os.path.join(out, tag + ".png"), type="png", full_page=os.environ.get("FULL") == "1")
                print(tag, "erreurs JS:", len(errs), (errs[:2] if errs else ""))
            ctx.close()
        b.close()
finally:
    srv.terminate()
