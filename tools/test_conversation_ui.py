import json, pathlib, subprocess, time, urllib.request, sys
import websocket

base = pathlib.Path.home() / "Library/Application Support/Nova"
parts = (base / ".session").read_text().split()
port, tok = parts[0], parts[1]
url = f"http://127.0.0.1:{port}/?t={tok}"
chrome = subprocess.Popen([
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "--headless=new", "--disable-gpu", "--no-first-run",
    "--remote-debugging-port=9333", "--user-data-dir=/tmp/nova-test-profile",
    "--window-size=1440,1000", url,
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    ws_url = None
    for _ in range(50):
        try:
            tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9333/json", timeout=3))
            for t in tabs:
                if t.get("type") == "page" and "webSocketDebuggerUrl" in t:
                    ws_url = t["webSocketDebuggerUrl"]; break
            if ws_url: break
        except Exception: pass
        time.sleep(0.4)
    if not ws_url: print("CDP introuvable"); sys.exit(1)
    ws = websocket.create_connection(ws_url, timeout=30)
    seq = [0]
    def ev(expr, wait=0):
        seq[0] += 1; seq_id = seq[0]
        ws.send(json.dumps({"id": seq_id, "method": "Runtime.evaluate",
                            "params": {"expression": expr, "returnByValue": True}}))
        while True:
            m = json.loads(ws.recv())
            if m.get("id") == seq_id:
                r = m.get("result", {}).get("result", {})
                if r.get("subtype") == "error": return "ERR: " + str(r.get("description"))[:200]
                return r.get("value")
    ev("1"); time.sleep(6)
    print("titre page:", ev("document.title"))
    print("texte nav (extrait):", str(ev("document.body ? document.body.innerText.slice(0,200).replace(/\\n/g,' | ') : 'no body'"))[:220])
    ev("""(() => { const els=[...document.querySelectorAll('button,a,[role=button]')];
      const b=els.find(e=>/Conversations/.test(e.textContent||'')); if(b){b.click(); return 'cliqué';} return 'introuvable'; })()""")
    time.sleep(5)
    print("lignes conversations:", ev("document.querySelectorAll('.cs-row').length"))
    print("errbox visible:", str(ev("(() => { const e=document.querySelector('.errbox'); return e ? e.innerText.slice(0,200) : ''; })()"))[:220])
    r = ev("""(() => { const rows=[...document.querySelectorAll('.cs-row')];
      const t=rows.find(x=>/C'est bien fini/.test(x.textContent||'')) || rows[2];
      if(!t) return 'aucune ligne'; t.click(); return 'cliqué: ' + (t.textContent||'').slice(0,60); })()""")
    print("clic conversation:", r)
    time.sleep(6)
    print("messages affichés:", ev("document.querySelectorAll('.msg').length"))
    print("errbox après clic:", str(ev("(() => { const e=document.querySelector('.errbox'); return e ? e.innerText.slice(0,240) : ''; })()"))[:260])
    print("toast:", str(ev("(() => { const e=document.querySelector('[class*=toast]'); return e ? e.innerText.slice(0,160) : ''; })()"))[:180])
    print("aperçu fil:", str(ev("(() => { const e=document.querySelector('.cs-log, .msg-log, [class*=log]'); return e ? e.innerText.slice(0,240).replace(/\\n/g,' | ') : 'log introuvable'; })()"))[:260])
finally:
    chrome.terminate()
    try: chrome.wait(timeout=8)
    except Exception: chrome.kill()
