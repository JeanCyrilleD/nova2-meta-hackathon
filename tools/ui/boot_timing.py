#!/usr/bin/env python3
"""Phase 4 — temps de démarrage de la coquille (Chromium sans tête, données simulées, cache désactivé) : médiane sur N
chargements de FCP, DOMContentLoaded et « __novaBooted » (premier module monté), + octets CSS transférés.
Indicatif : ce n'est pas WKWebView sur le Mac. Usage : python3 tools/ui/boot_timing.py [N]"""
import os, sys, time, subprocess, statistics
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__)); port = 8795; N = int(sys.argv[1]) if len(sys.argv) > 1 else 8
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(port)]); time.sleep(0.8)
R = {"fcp": [], "dcl": [], "booted": [], "css_bytes": [], "css_parse_ms": []}
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        for i in range(N + 1):
            ctx = b.new_context(viewport={"width": 1280, "height": 800}); pg = ctx.new_page()
            cdp = ctx.new_cdp_session(pg); cdp.send("Network.enable"); cdp.send("Network.setCacheDisabled", {"cacheDisabled": True})
            pg.goto("http://127.0.0.1:%d/index.html" % port)
            pg.wait_for_function("() => window.__novaBooted", timeout=20000)
            t_boot = pg.evaluate("() => performance.now()")
            m = pg.evaluate("""() => { const n = performance.getEntriesByType('navigation')[0]; const f = performance.getEntriesByName('first-contentful-paint')[0];
              const css = performance.getEntriesByType('resource').filter(r => /\\.css/.test(r.name));
              return { dcl: n.domContentLoadedEventEnd, fcp: f ? f.startTime : null, css: css.reduce((a, r) => a + (r.decodedBodySize || 0), 0) }; }""")
            if i:   # le premier chargement chauffe le navigateur : écarté
                R["fcp"].append(m["fcp"] or 0); R["dcl"].append(m["dcl"]); R["booted"].append(t_boot); R["css_bytes"].append(m["css"])
            ctx.close()
        b.close()
finally:
    srv.terminate()
med = lambda k: statistics.median(R[k])
print("N=%d · FCP médiane %.0f ms · DOMContentLoaded %.0f ms · premier module (approx.) %.0f ms · CSS décodée %d o" % (N, med("fcp"), med("dcl"), med("booted"), med("css_bytes")))
print("FCP min/max %.0f/%.0f ms" % (min(R["fcp"]), max(R["fcp"])))
