// PHASE 5 (brief Nova 2) — tests de la présence 3D optionnelle (node, sans navigateur, sans réseau).
// Lancer : node tools/test_presence3d.mjs   (depuis la racine du dépôt ; appelé par tools/verify.sh)
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const web = join(root, "web");
const src = (p) => readFileSync(join(root, p), "utf8");
let n = 0;
const ok = (name, fn) => { fn(); n++; console.log("  OK  " + name); };

const P3D = src("web/js/presence3d.js");
const m = await import(new URL("../web/js/presence3d.js", import.meta.url).href);   // importable sans DOM

ok("cinq états, et seulement cinq", () => {
  assert.deepEqual(m.PRESENCE_STATES, ["repos", "reflexion", "attente", "erreur", "plafond"]);
  assert.deepEqual(Object.keys(m.LOOKS).sort(), [...m.PRESENCE_STATES].sort());
});
ok("états Nova → états de l'objet", () => {
  const cases = { repos: "repos", ecoute: "repos", parole: "repos", done: "repos", reflexion: "reflexion", outil: "reflexion",
    approval: "attente", erreur: "erreur", plafond: "plafond", inconnu: "repos", "": "repos" };
  for (const [k, v] of Object.entries(cases)) assert.equal(m.presenceOf(k, false), v, k);
});
ok("plafond atteint l'emporte sur toute activité", () => {
  for (const s of ["repos", "reflexion", "approval", "erreur"]) assert.equal(m.presenceOf(s, true), "plafond");
});
ok("repos ≤ 30 i/s ; plafond immobile (boucle arrêtée)", () => {
  assert.ok(m.LOOKS.repos.fps <= 30);
  assert.equal(m.LOOKS.plafond.still, true);
  assert.equal(m.LOOKS.plafond.v[4], 0); assert.equal(m.LOOKS.plafond.v[6], 0); assert.equal(m.LOOKS.plafond.v[7], 0);
});
ok("icosphère : 2 562 sommets, 5 120 triangles, faces tournées vers l'extérieur (CCW)", () => {
  const g = m.icosphere(4);
  assert.equal(g.positions.length / 3, 2562); assert.equal(g.indices.length / 3, 5120);
  const V = (i) => [g.positions[i * 3], g.positions[i * 3 + 1], g.positions[i * 3 + 2]];
  for (let f = 0; f < g.indices.length; f += 3) {
    const [a, b, c] = [V(g.indices[f]), V(g.indices[f + 1]), V(g.indices[f + 2])];
    const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]], w = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
    const nx = u[1] * w[2] - u[2] * w[1], ny = u[2] * w[0] - u[0] * w[2], nz = u[0] * w[1] - u[1] * w[0];
    assert.ok(nx * (a[0] + b[0] + c[0]) + ny * (a[1] + b[1] + c[1]) + nz * (a[2] + b[2] + c[2]) > 0, "face " + f / 3);
  }
  assert.ok(g.indices.byteLength % 4 === 0 && g.positions.byteLength % 4 === 0);
});
ok("uniformes : 16 flottants (64 octets), mêmes champs WGSL/GLSL", () => {
  const u = m.packUniforms(new Float32Array(16), m.LOOKS.repos.v, { time: 1, phase: 2, spin: 3, shake: 0 });
  assert.equal(u.byteLength, 64); assert.equal(u[4], 1); assert.equal(u[7], 2); assert.equal(u[8], 3);
  assert.ok(P3D.includes("uniform vec4 u[4];") && P3D.includes("struct U { c: vec4f, a: vec4f, b: vec4f, d: vec4f };"));
});
ok("aucun appel de modèle ni réseau dans presence3d.js", () => {
  const code = P3D.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  for (const bad of ["fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "/api/", "import(", "http:", "https:"]) assert.ok(!code.includes(bad), bad);
  assert.ok(!/^\s*import\s/m.test(code), "aucun import (ni bibliothèque, ni CDN)");
});
ok("WebGPU d'abord, repli WebGL2, pause fenêtre cachée, image fixe sous Réduire les animations", () => {
  assert.ok(P3D.includes('navigator.gpu') && P3D.includes('getContext("webgl2"'));
  assert.ok(P3D.includes('"visibilitychange"') && P3D.includes("document.hidden"));
  assert.ok(P3D.includes("prefers-reduced-motion: reduce") && P3D.includes("still()"));
  assert.ok(P3D.includes('"timestamp-query"') && P3D.includes("EXT_disjoint_timer_query_webgl2"));
});
ok("démarrage : presence3d.js n'est référencé QUE par avatar.js, en import() dynamique", () => {
  const files = [];
  const walk = (d) => { for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) { if (f !== "vendor") walk(p); } else if (/\.(js|html)$/.test(f)) files.push(p); } };
  walk(web);
  const code = (f) => readFileSync(f, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/<!--[\s\S]*?-->/g, "");   // commentaires exclus : seul le code compte
  const refs = files.filter((f) => !f.endsWith("presence3d.js") && code(f).includes("presence3d.js")).map((f) => f.slice(web.length + 1));
  assert.deepEqual(refs, ["js/avatar.js"]);
  const av = src("web/js/avatar.js");
  assert.ok(av.includes('await import("./presence3d.js")'));
  assert.ok(!/from\s+["']\.\/presence3d\.js["']/.test(av), "jamais d'import statique");
  for (const f of ["web/index.html", "web/js/shell.js"]) assert.ok(!src(f).includes("presence3d"), f);
});
ok("réglage coupé par défaut (serveur, cache local, Réglages)", () => {
  const av = src("web/js/avatar.js");
  assert.ok(av.includes('localStorage.getItem("nova2_presence_3d") === "1"'));
  assert.ok(av.includes('typeof p === "boolean"'));
  assert.ok(src("web/js/modules/settings.js").includes('get("presence_3d", false) === true'));
  assert.ok(av.includes('if (presence3dOn()) { await mountPresence3d(); return; }'));
  assert.ok(av.includes("await whenVisible(wrap, visHold);"), "import seulement quand la présence est visible");
});
console.log("  " + n + " tests présence 3D : OK");
