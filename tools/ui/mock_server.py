#!/usr/bin/env python3
"""Phase 4 — serveur STATIQUE de web/ avec réponses /api/* SIMULÉES (aucun appel réel, aucune clé).
Usage : python3 tools/ui/mock_server.py [port]   (défaut 8799, 127.0.0.1 seulement)
Les réponses simulées viennent de tools/ui/mock_api.json (clé = chemin sans requête) ;
une route inconnue rend {} et est notée dans tools/ui/.mock_unknown.txt (hors git)."""
import json, os, sys, http.server, urllib.parse
HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.environ.get("NOVA_WEB") or os.path.normpath(os.path.join(HERE, "..", "..", "web"))   # NOVA_WEB : servir un autre web/ (ex. base bfdcf7a pour les captures avant/après)
MOCK = json.load(open(os.path.join(HERE, "mock_api.json"), encoding="utf-8"))
UNKNOWN = set()
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=WEB, **k)
    def log_message(self, *a): pass
    def _api(self):
        p = urllib.parse.urlparse(self.path).path
        if p == "/api/events":   # flux SSE simulé : un commentaire puis fermeture
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            self.wfile.write(b": mock\n\n"); return
        body = MOCK.get(p)
        if body == "__404__":   # route pas encore livrée par le moteur (état réel au 31/10)
            self.send_response(404); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b'{"error":"not found"}'); return
        if body is None:
            body = {}
            if p not in UNKNOWN:
                UNKNOWN.add(p)
                with open(os.path.join(HERE, ".mock_unknown.txt"), "a") as f: f.write(self.command + " " + p + "\n")
        d = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        if self.path.startswith("/api/"): return self._api()
        return super().do_GET()
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); self.rfile.read(n)
        return self._api()
if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
    http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
