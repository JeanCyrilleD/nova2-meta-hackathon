#!/usr/bin/env python3
"""Captures « fenêtre étroite » (données SIMULÉES, mock_server + mock_api_etroit.json) : Conversations (fil ouvert,
puis tiroir de la liste ouvert sous le seuil), Messages, Dossiers, à plusieurs largeurs, thèmes clair et sombre.
Usage : python3 tools/ui/capture_etroit.py <dossier_sortie>   (env. WIDTHS="1400,1000,760,650,520,420", THEMES, MODS)"""
import os, sys, time, subprocess, json
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
port = int(os.environ.get("PORT", "8811"))
env = dict(os.environ, MOCK_EXTRA=os.environ.get("MOCK_EXTRA", "mock_api_etroit.json"))
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(port)], env=env)
time.sleep(0.8)
widths = [int(x) for x in os.environ.get("WIDTHS", "1400,1000,760,650,520,420").split(",")]
themes = os.environ.get("THEMES", "harmattan-jour,harmattan-nuit").split(",")
mods = os.environ.get("MODS", "conversations,messages,dossiers").split(",")
H = int(os.environ.get("H", "820"))
report = []
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        for th in themes:
            mode = th.rsplit("-", 1)[1]
            for w in widths:
                ctx = b.new_context(viewport={"width": w, "height": H}, device_scale_factor=1, color_scheme="dark" if mode == "nuit" else "light")
                ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s');localStorage.setItem('nova2_identite_v1','1');}catch(e){}" % th)
                pg = ctx.new_page(); errs = []
                pg.on("pageerror", lambda e: errs.append(str(e)[:160]))
                pg.goto("http://127.0.0.1:%d/index.html" % port); pg.wait_for_timeout(1500)
                for m in mods:
                    pg.evaluate("(id) => { const b = document.querySelector('.rail-btn[data-page=\"' + id + '\"]'); if (b) b.click(); else if (window.__novaNavigate) window.__novaNavigate(id); }", m)
                    pg.wait_for_timeout(1800)
                    tag = "%s-%d-%s" % (m, w, mode)
                    if m == "conversations":
                        pg.evaluate("() => { const r = [...document.querySelectorAll('.cs-row')].find(x => /Mais que/.test(x.textContent)); if (r) r.click(); }")
                        pg.wait_for_timeout(1500)
                        info = pg.evaluate("""() => { const l = document.querySelector('.cs-layout'); const s = l && l.querySelector('.cs-side'); const cs = s && getComputedStyle(s);
                          return { layoutW: l ? l.clientWidth : 0, side: cs ? cs.display + '/' + cs.position + '/' + cs.backgroundColor : '' , peek: l ? l.classList.contains('side-peek') : null }; }""")
                        pg.screenshot(path=os.path.join(out, tag + "-fil.png"))
                        report.append((tag + "-fil", info))
                        if info["layoutW"] and info["layoutW"] <= 760:
                            pg.evaluate("() => { const b = document.querySelector('.cs-layout .cs-iconbtn[title*=\"liste des conversations\"]'); if (b) b.click(); }")
                            pg.wait_for_timeout(700)
                            info2 = pg.evaluate("""() => { const l = document.querySelector('.cs-layout'); const s = l.querySelector('.cs-side'); const cs = getComputedStyle(s); const sc = l.querySelector('.cs-scrim');
                              return { side: cs.display + '/' + cs.position + '/' + cs.backgroundColor + '/w' + s.offsetWidth, peek: l.classList.contains('side-peek'), scrim: sc ? getComputedStyle(sc).display : 'absent' }; }""")
                            pg.screenshot(path=os.path.join(out, tag + "-tiroir.png"))
                            report.append((tag + "-tiroir", info2))
                            pg.evaluate("() => { const r = [...document.querySelectorAll('.cs-row')].find(x => /Qui dois/.test(x.textContent)); if (r) r.click(); }")
                            pg.wait_for_timeout(600)
                            report.append((tag + "-apres-choix", pg.evaluate("() => document.querySelector('.cs-layout').classList.contains('side-peek')")))
                    else:
                        pg.screenshot(path=os.path.join(out, tag + ".png"))
                        if m == "messages":   # deux volets côte à côte
                            pg.evaluate("() => { const b = document.querySelector('.ms-split'); if (b && b.getAttribute('aria-pressed') !== 'true') b.click(); }")
                            pg.wait_for_timeout(700)
                            pg.screenshot(path=os.path.join(out, tag + "-split.png"))
                            pg.evaluate("() => { const b = document.querySelector('.ms-split'); if (b && b.getAttribute('aria-pressed') === 'true') b.click(); }")
                if errs: report.append(("erreurs-%d-%s" % (w, mode), errs[:3]))
                ctx.close()
        b.close()
finally:
    srv.terminate()
for r in report: print(*r)
