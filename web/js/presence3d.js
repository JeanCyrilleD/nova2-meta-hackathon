/* presence3d.js — PHASE 5 (brief Nova 2) : la présence 3D OPTIONNELLE de Nova.
   UN seul objet (une goutte procédurale : icosphère déformée en code, aucun fichier 3D, aucun modèle)
   qui montre l'état de Nova en cinq lectures :
     repos       bleu calme, respiration lente, 30 i/s
     reflexion   violet, surface qui travaille, rotation plus vive, 60 i/s
     attente     ambre, battement lent (une approbation attend Ahadi), 30 i/s
     erreur      rouge, secousse brève qui s'amortit, 30 i/s
     plafond     gris, immobile (plafond de budget atteint) : la boucle S'ARRÊTE une fois la pose atteinte
   Règles (brief §Phase 5) :
   - chargé à la demande : avatar.js l'importe par import() SEULEMENT si le réglage presence_3d est actif ET
     la présence visible ; index.html / shell.js ne le référencent pas (tools/test_presence3d.mjs le vérifie) ;
   - WebGPU d'abord, repli WebGL2 ; sans l'un ni l'autre → null (l'appelant garde l'orbe CSS) ;
   - pause fenêtre cachée (visibilitychange) et hors écran (IntersectionObserver) ;
   - prefers-reduced-motion (ou html[data-reduce-motion="1"]) → une image fixe par changement d'état, aucune boucle ;
   - n'appelle JAMAIS de modèle ni le réseau : aucune requête dans ce fichier (vérifié par le test) ;
   - budget < 2 ms GPU par image au repos : mesuré par timestamp-query (WebGPU) ou EXT_disjoint_timer_query_webgl2
     (WebGL2) quand le navigateur l'expose, une image sur 20 ; sinon stats().timing = "indisponible".
   Plafond : source = événement window « nova:budget-cap » {reached} et/ou window.__novaBudgetCap === true
   (contrat à brancher par la Phase 2 — le budget n'existe pas encore côté client sur cette branche).
   Contrat moteur (avatar.js) : setState(étatNova), setCap(bool), setLevel/setMood/react/setFocus (sans effet),
   stats(), destroy(). */

export const PRESENCE_STATES = ["repos", "reflexion", "attente", "erreur", "plafond"];

const FROM_NOVA = {
  repos: "repos", ecoute: "repos", parole: "repos", done: "repos", celebrate: "repos", sleep: "repos",
  reflexion: "reflexion", reading: "reflexion", outil: "reflexion", tool: "reflexion", thinking: "reflexion",
  approval: "attente", attente: "attente",
  erreur: "erreur", error: "erreur",
  plafond: "plafond",
};
/* Le plafond est une CONDITION (pas une activité) : il l'emporte sur tout le reste tant qu'il dure. */
export function presenceOf(novaState, capReached) {
  if (capReached) return "plafond";
  return FROM_NOVA[String(novaState || "")] || "repos";
}

/* Paramètres continus par état : r, g, b, éclat, amplitude, fréquence, vitesse, rotation, battement, respiration */
const P = { r: 0, g: 1, b: 2, glow: 3, amp: 4, freq: 5, speed: 6, spin: 7, pulse: 8, breath: 9 };
export const LOOKS = {
  repos:     { v: [0.36, 0.70, 0.88, 0.40, 0.035, 2.2, 0.35, 0.12, 0.0, 1.0], fps: 30 },
  reflexion: { v: [0.58, 0.46, 0.98, 0.70, 0.085, 3.6, 1.50, 0.55, 0.0, 0.4], fps: 60 },
  attente:   { v: [0.98, 0.68, 0.24, 0.65, 0.030, 2.2, 0.40, 0.10, 1.0, 0.0], fps: 30 },
  erreur:    { v: [0.94, 0.30, 0.28, 0.55, 0.050, 5.0, 0.60, 0.04, 0.0, 0.3], fps: 30 },
  plafond:   { v: [0.52, 0.54, 0.58, 0.12, 0.000, 2.2, 0.00, 0.00, 0.0, 0.0], fps: 15, still: true },
};

/* ── Géométrie : icosphère unité, faces CCW vues de l'extérieur ── */
export function icosphere(sub = 4) {
  const t = (1 + Math.sqrt(5)) / 2;
  const v = [];
  const add = (x, y, z) => { const l = Math.hypot(x, y, z); v.push(x / l, y / l, z / l); return v.length / 3 - 1; };
  [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].forEach((p) => add(p[0], p[1], p[2]));
  let f = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]];
  for (let s = 0; s < sub; s++) {
    const mid = new Map(), nf = [];
    const m = (a, b) => {
      const k = a < b ? a * 65536 + b : b * 65536 + a;
      let i = mid.get(k);
      if (i === undefined) { i = add((v[a * 3] + v[b * 3]) / 2, (v[a * 3 + 1] + v[b * 3 + 1]) / 2, (v[a * 3 + 2] + v[b * 3 + 2]) / 2); mid.set(k, i); }
      return i;
    };
    for (const [a, b, c] of f) { const ab = m(a, b), bc = m(b, c), ca = m(c, a); nf.push([a, ab, ca], [b, bc, ab], [c, ca, bc], [ab, bc, ca]); }
    f = nf;
  }
  return { positions: new Float32Array(v), indices: new Uint16Array(f.flat()) };
}

/* Uniformes : 4 × vec4 = 64 octets, mêmes champs pour WGSL et GLSL.
   u0 = (r, g, b, éclat) · u1 = (temps, amplitude, fréquence, phase) · u2 = (rotation, battement, secousse, aspect)
   u3 = (respiration, 0, 0, 0) */
export function packUniforms(out, cur, clock) {
  out[0] = cur[P.r]; out[1] = cur[P.g]; out[2] = cur[P.b]; out[3] = cur[P.glow];
  out[4] = clock.time; out[5] = cur[P.amp]; out[6] = cur[P.freq]; out[7] = clock.phase;
  out[8] = clock.spin; out[9] = cur[P.pulse]; out[10] = clock.shake; out[11] = 1;
  out[12] = cur[P.breath]; out[13] = 0; out[14] = 0; out[15] = 0;
  return out;
}

/* Caméra fixe : œil à 4 unités, demi-champ 19° (f = 1/tan 19° ≈ 2,904). Pas de tampon de profondeur :
   l'objet est quasi convexe, l'élimination des faces arrière suffit (z/w = 0,5 valable en GL comme en WebGPU). */
const GLSL_VS = `#version 300 es
precision highp float;
layout(location=0) in vec3 aPos;
uniform vec4 u[4];
out vec3 vN; out vec3 vV;
float disp(vec3 n){ float f = u[1].z, ph = u[1].w;
  return u[1].y * (sin(f*n.x + ph) * sin(f*n.y + ph*1.31 + 1.7) * sin(f*n.z + ph*0.73 + 0.4) + 0.25*sin(2.0*f*n.y - ph*1.9)); }
vec3 surf(vec3 n){ float t = u[1].x;
  float beat = u[2].y * pow(max(0.0, sin(t*2.4)), 6.0) * 0.07;
  float breath = u[3].x * 0.018 * sin(t*1.5708);
  return n * (1.0 + disp(n) + beat + breath); }
vec3 rot(vec3 p){ float a = u[2].x, c = cos(a), s = sin(a);
  p = vec3(c*p.x + s*p.z, p.y, -s*p.x + c*p.z);
  const float ct = 0.9394, st = 0.3429;
  return vec3(p.x, ct*p.y - st*p.z, st*p.y + ct*p.z); }
void main(){
  vec3 n = normalize(aPos);
  vec3 tA = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
  vec3 tB = cross(n, tA);
  vec3 p0 = surf(n), p1 = surf(normalize(n + tA*0.01)), p2 = surf(normalize(n + tB*0.01));
  vec3 N = normalize(cross(p1 - p0, p2 - p0));
  vec3 p = rot(p0); N = rot(N);
  p.x += u[2].z * 0.06 * sin(u[1].x * 47.0);
  vec3 v = p + vec3(0.0, 0.0, -4.0);
  vN = N; vV = -v;
  float w = -v.z;
  gl_Position = vec4(v.x * 2.904 / u[2].w, v.y * 2.904, 0.5 * w, w);
}`;

const GLSL_FS = `#version 300 es
precision highp float;
uniform vec4 u[4];
in vec3 vN; in vec3 vV;
out vec4 o;
void main(){
  vec3 N = normalize(vN), V = normalize(vV);
  vec3 L = normalize(vec3(-0.45, 0.65, 0.62));
  vec3 col = u[0].rgb; float glow = u[0].a;
  float nv = max(dot(N, V), 0.0);
  float wrapL = dot(N, L) * 0.5 + 0.5;
  float spec = pow(max(dot(N, normalize(L + V)), 0.0), 48.0);
  float fr = pow(1.0 - nv, 2.6);
  vec3 c = col * (0.20 + 0.62 * wrapL) + vec3(spec * 0.55) + col * fr * (0.6 + 1.4 * glow) + col * glow * 0.35 * pow(nv, 3.0);
  c = 1.0 - exp(-1.6 * c);
  o = vec4(c, 1.0);
}`;

const WGSL = `
struct U { c: vec4f, a: vec4f, b: vec4f, d: vec4f };
@group(0) @binding(0) var<uniform> u: U;
struct O { @builtin(position) pos: vec4f, @location(0) n: vec3f, @location(1) v: vec3f };
fn disp(n: vec3f) -> f32 { let f = u.a.z; let ph = u.a.w;
  return u.a.y * (sin(f*n.x + ph) * sin(f*n.y + ph*1.31 + 1.7) * sin(f*n.z + ph*0.73 + 0.4) + 0.25*sin(2.0*f*n.y - ph*1.9)); }
fn surf(n: vec3f) -> vec3f { let t = u.a.x;
  let beat = u.b.y * pow(max(0.0, sin(t*2.4)), 6.0) * 0.07;
  let breath = u.d.x * 0.018 * sin(t*1.5708);
  return n * (1.0 + disp(n) + beat + breath); }
fn rot(q: vec3f) -> vec3f { let a = u.b.x; let c = cos(a); let s = sin(a);
  let p = vec3f(c*q.x + s*q.z, q.y, -s*q.x + c*q.z);
  let ct = 0.9394; let st = 0.3429;
  return vec3f(p.x, ct*p.y - st*p.z, st*p.y + ct*p.z); }
@vertex fn vs(@location(0) aPos: vec3f) -> O {
  let n = normalize(aPos);
  let up = select(vec3f(1.0, 0.0, 0.0), vec3f(0.0, 1.0, 0.0), abs(n.y) < 0.99);
  let tA = normalize(cross(n, up));
  let tB = cross(n, tA);
  let p0 = surf(n); let p1 = surf(normalize(n + tA*0.01)); let p2 = surf(normalize(n + tB*0.01));
  var p = rot(p0);
  let N = rot(normalize(cross(p1 - p0, p2 - p0)));
  p.x += u.b.z * 0.06 * sin(u.a.x * 47.0);
  let v = p + vec3f(0.0, 0.0, -4.0);
  let w = -v.z;
  var o: O;
  o.pos = vec4f(v.x * 2.904 / u.b.w, v.y * 2.904, 0.5 * w, w);
  o.n = N; o.v = -v;
  return o;
}
@fragment fn fs(i: O) -> @location(0) vec4f {
  let N = normalize(i.n); let V = normalize(i.v);
  let L = normalize(vec3f(-0.45, 0.65, 0.62));
  let col = u.c.rgb; let glow = u.c.a;
  let nv = max(dot(N, V), 0.0);
  let wrapL = dot(N, L) * 0.5 + 0.5;
  let spec = pow(max(dot(N, normalize(L + V)), 0.0), 48.0);
  let fr = pow(1.0 - nv, 2.6);
  var c = col * (0.20 + 0.62 * wrapL) + vec3f(spec * 0.55) + col * fr * (0.6 + 1.4 * glow) + col * glow * 0.35 * pow(nv, 3.0);
  c = 1.0 - exp(-1.6 * c);
  return vec4f(c, 1.0);
}`;

/* ── Rendu WebGPU (MSAA 4×, horodatage de passe si « timestamp-query » est exposé) ── */
async function initWebGPU(canvas, geo, onLost) {
  const gpu = typeof navigator !== "undefined" && navigator.gpu;
  if (!gpu) return null;
  const adapter = await gpu.requestAdapter({ powerPreference: "low-power" });
  if (!adapter) return null;
  const ts = adapter.features.has("timestamp-query");
  const device = await adapter.requestDevice(ts ? { requiredFeatures: ["timestamp-query"] } : {});
  const ctx = canvas.getContext("webgpu");
  if (!ctx) { device.destroy(); return null; }
  const format = gpu.getPreferredCanvasFormat();
  ctx.configure({ device, format, alphaMode: "premultiplied" });
  const mod = device.createShaderModule({ code: WGSL });
  const pipe = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: mod, entryPoint: "vs", buffers: [{ arrayStride: 12, attributes: [{ shaderLocation: 0, offset: 0, format: "float32x3" }] }] },
    fragment: { module: mod, entryPoint: "fs", targets: [{ format }] },
    primitive: { topology: "triangle-list", cullMode: "back", frontFace: "ccw" },
    multisample: { count: 4 },
  });
  const buf = (data, usage) => {
    const n = Math.ceil(data.byteLength / 4) * 4;   // writeBuffer exige une taille multiple de 4
    const b = device.createBuffer({ size: n, usage: usage | GPUBufferUsage.COPY_DST });
    const pad = new Uint8Array(n); pad.set(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
    device.queue.writeBuffer(b, 0, pad);
    return b;
  };
  const vbuf = buf(geo.positions, GPUBufferUsage.VERTEX);
  const ibuf = buf(geo.indices, GPUBufferUsage.INDEX);
  const ubuf = device.createBuffer({ size: 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const bind = device.createBindGroup({ layout: pipe.getBindGroupLayout(0), entries: [{ binding: 0, resource: { buffer: ubuf } }] });
  let msaa = null;
  const qs = ts ? device.createQuerySet({ type: "timestamp", count: 2 }) : null;
  const resBuf = ts ? device.createBuffer({ size: 16, usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC }) : null;
  const readBuf = ts ? device.createBuffer({ size: 16, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST }) : null;
  let pending = false, gone = false;
  let errs = 0;
  device.addEventListener("uncapturederror", (e) => { if (errs++ < 3) { try { console.warn("presence3d WebGPU :", e.error && e.error.message); } catch (x) {} } });
  device.lost.then((info) => { gone = true; if (info && info.reason !== "destroyed") onLost(); });
  return {
    kind: "webgpu", timing: ts ? "webgpu-timestamp" : "indisponible",
    draw(u, measure, onMs) {
      if (gone) return;
      if (!msaa || msaa.width !== canvas.width || msaa.height !== canvas.height) {
        if (msaa) msaa.destroy();
        msaa = device.createTexture({ size: [canvas.width, canvas.height], sampleCount: 4, format, usage: GPUTextureUsage.RENDER_ATTACHMENT });
      }
      device.queue.writeBuffer(ubuf, 0, u);
      const doTs = !!(measure && ts && !pending);
      const enc = device.createCommandEncoder();
      const desc = { colorAttachments: [{ view: msaa.createView(), resolveTarget: ctx.getCurrentTexture().createView(), clearValue: { r: 0, g: 0, b: 0, a: 0 }, loadOp: "clear", storeOp: "discard" }] };
      if (doTs) desc.timestampWrites = { querySet: qs, beginningOfPassWriteIndex: 0, endOfPassWriteIndex: 1 };
      const pass = enc.beginRenderPass(desc);
      pass.setPipeline(pipe); pass.setBindGroup(0, bind); pass.setVertexBuffer(0, vbuf); pass.setIndexBuffer(ibuf, "uint16");
      pass.drawIndexed(geo.indices.length);
      pass.end();
      if (doTs) { enc.resolveQuerySet(qs, 0, 2, resBuf, 0); enc.copyBufferToBuffer(resBuf, 0, readBuf, 0, 16); }
      device.queue.submit([enc.finish()]);
      if (doTs) {
        pending = true;
        readBuf.mapAsync(GPUMapMode.READ).then(() => {
          const a = new BigUint64Array(readBuf.getMappedRange()); const ns = Number(a[1] - a[0]); readBuf.unmap(); pending = false;
          if (ns > 0 && ns < 1e9) onMs(ns / 1e6);
        }).catch(() => { pending = false; });
      }
    },
    poll() {},
    destroy() { gone = true; try { ctx.unconfigure(); } catch (e) {} try { device.destroy(); } catch (e) {} },
  };
}

/* ── Repli WebGL2 (EXT_disjoint_timer_query_webgl2 si exposé) ── */
function initWebGL2(canvas, geo, onLost) {
  const gl = canvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true, antialias: true, depth: false, stencil: false, powerPreference: "low-power" });
  if (!gl) return null;
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error("presence3d GLSL : " + gl.getShaderInfoLog(s)); return s; };
  const prog = gl.createProgram();
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, GLSL_VS)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, GLSL_FS));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error("presence3d lien : " + gl.getProgramInfoLog(prog));
  const vao = gl.createVertexArray(); gl.bindVertexArray(vao);
  const vb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, vb); gl.bufferData(gl.ARRAY_BUFFER, geo.positions, gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 0, 0);
  const ib = gl.createBuffer(); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, geo.indices, gl.STATIC_DRAW);
  gl.bindVertexArray(null);
  const loc = gl.getUniformLocation(prog, "u");
  const ext = gl.getExtension("EXT_disjoint_timer_query_webgl2");
  let q = null, gone = false, cb = null;
  canvas.addEventListener("webglcontextlost", (e) => { e.preventDefault(); gone = true; onLost(); });
  return {
    kind: "webgl2", timing: ext ? "webgl-timer" : "indisponible",
    draw(u, measure, onMs) {
      if (gone) return;
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.CULL_FACE); gl.cullFace(gl.BACK); gl.frontFace(gl.CCW);
      gl.useProgram(prog); gl.bindVertexArray(vao); gl.uniform4fv(loc, u);
      const doQ = !!(measure && ext && !q);
      if (doQ) { q = gl.createQuery(); cb = onMs; gl.beginQuery(ext.TIME_ELAPSED_EXT, q); }
      gl.drawElements(gl.TRIANGLES, geo.indices.length, gl.UNSIGNED_SHORT, 0);
      if (doQ) gl.endQuery(ext.TIME_ELAPSED_EXT);
      gl.bindVertexArray(null);
    },
    poll() {
      if (!q || gone) return;
      if (!gl.getQueryParameter(q, gl.QUERY_RESULT_AVAILABLE)) return;
      const disjoint = gl.getParameter(ext.GPU_DISJOINT_EXT);
      const ns = gl.getQueryParameter(q, gl.QUERY_RESULT);
      gl.deleteQuery(q); q = null;
      if (!disjoint && ns > 0 && cb) cb(ns / 1e6);
    },
    destroy() { gone = true; try { const l = gl.getExtension("WEBGL_lose_context"); if (l) l.loseContext(); } catch (e) {} },
  };
}

function reducedMotion() {
  try { return matchMedia("(prefers-reduced-motion: reduce)").matches || document.documentElement.dataset.reduceMotion === "1"; } catch (e) { return false; }
}

/* Monte l'objet dans host (élément positionné, taille CSS imposée par l'appelant). Renvoie le moteur, ou null
   si ni WebGPU ni WebGL2 ne sont disponibles. opts : { px, backend: "auto"|"webgpu"|"webgl", onLost } */
export async function createPresence3D(host, opts = {}) {
  const geo = icosphere(4);   // 2 562 sommets, 5 120 triangles
  let dead = false;
  const lost = () => { if (dead) return; stop(); if (typeof opts.onLost === "function") { try { opts.onLost(); } catch (e) {} } };
  const mk = () => { const c = document.createElement("canvas"); c.setAttribute("aria-hidden", "true"); c.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block"; return c; };
  let canvas = mk();
  host.append(canvas);
  const size = () => {
    const px = host.clientWidth || opts.px || 190;
    const n = Math.max(32, Math.round(px * Math.min((typeof devicePixelRatio === "number" && devicePixelRatio) || 1, 1.5)));
    if (canvas.width !== n) { canvas.width = n; canvas.height = n; return true; }
    return false;
  };
  size();
  const want = opts.backend || "auto";
  let r = null;
  if (want !== "webgl") { try { r = await initWebGPU(canvas, geo, lost); } catch (e) { r = null; } }
  if (!r && want !== "webgpu") {
    if (want !== "webgl") { canvas.remove(); canvas = mk(); host.append(canvas); size(); }   // un canevas déjà pris par « webgpu » ne rend plus de contexte WebGL
    try { r = initWebGL2(canvas, geo, lost); } catch (e) { r = null; }
  }
  if (!r) { canvas.remove(); return null; }

  /* État : cible + valeurs courantes (ressort exponentiel, jamais de coupure) */
  let nova = "repos", cap = (typeof window !== "undefined" && window.__novaBudgetCap === true);
  let target = presenceOf(nova, cap);
  const cur = LOOKS[target].v.slice();
  const clock = { time: 0, phase: 0, spin: 0, shake: 0 };
  const u = new Float32Array(16);
  const samples = []; let frames = 0, raf = 0, last = 0, visible = true;

  function settled() { const t = LOOKS[target].v; for (let i = 0; i < t.length; i++) if (Math.abs(t[i] - cur[i]) > 1e-3) return false; return clock.shake < 1e-3; }
  function render(measure) {
    size();
    packUniforms(u, cur, clock);
    r.draw(u, measure, (ms) => { samples.push(ms); if (samples.length > 240) samples.shift(); });
    frames++;
  }
  function still() {
    const t = LOOKS[target].v; for (let i = 0; i < t.length; i++) cur[i] = t[i];
    clock.shake = 0; clock.time = 0.6; clock.phase = 0.6 * t[P.speed]; clock.spin = 0.35;
    render(false);
  }
  function frame(now) {
    raf = 0;
    if (dead || !visible || document.hidden) return;
    r.poll();
    const fps = LOOKS[target].fps;
    if (last && now - last < 1000 / fps - 2) { raf = requestAnimationFrame(frame); return; }
    const dt = last ? Math.min(0.1, (now - last) / 1000) : 1 / fps; last = now;
    const k = 1 - Math.exp(-dt * 5);
    const t = LOOKS[target].v; for (let i = 0; i < t.length; i++) cur[i] += (t[i] - cur[i]) * k;
    clock.time += dt; clock.phase += dt * cur[P.speed]; clock.spin += dt * cur[P.spin]; clock.shake *= Math.exp(-dt * 5);
    render(frames % 20 === 0);
    if (LOOKS[target].still && settled()) { last = 0; return; }   // plafond : pose atteinte, la boucle s'arrête
    raf = requestAnimationFrame(frame);
  }
  function stop() { if (raf) cancelAnimationFrame(raf); raf = 0; last = 0; }
  function kick() {
    if (dead || !visible || document.hidden) return;
    if (reducedMotion()) { stop(); still(); return; }
    if (!raf) raf = requestAnimationFrame(frame);
  }
  function retarget() {
    const nt = presenceOf(nova, cap);
    if (nt === target) return;
    if (nt === "erreur") clock.shake = 1;
    target = nt; kick();
  }

  const onVis = () => { if (document.hidden) stop(); else kick(); };
  document.addEventListener("visibilitychange", onVis);
  const onCap = (e) => { cap = !!(e && e.detail && e.detail.reached); retarget(); };
  window.addEventListener("nova:budget-cap", onCap);
  let mq = null; const onMq = () => { stop(); kick(); };
  try { mq = matchMedia("(prefers-reduced-motion: reduce)"); mq.addEventListener("change", onMq); } catch (e) { mq = null; }
  let io = null, ro = null;
  try { io = new IntersectionObserver((es) => { visible = es.some((x) => x.isIntersecting); if (visible) kick(); else stop(); }); io.observe(host); } catch (e) { io = null; }
  try { ro = new ResizeObserver(() => { if (size() && !raf) { if (reducedMotion()) still(); else kick(); } }); ro.observe(host); } catch (e) { ro = null; }

  const engine = {
    kind: "presence3d", backend: r.kind,
    setState(s) { nova = String(s || "repos"); retarget(); },
    setCap(on) { cap = !!on; retarget(); },
    state() { return target; },
    setLevel() {}, setMood() {}, react() {}, setFocus() {},
    /* Mesure GPU : moyenne / médiane / p95 / max en ms sur les 240 derniers échantillons (une image sur 20). */
    stats() {
      const s = samples.slice().sort((a, b) => a - b);
      const avg = s.length ? s.reduce((a, b) => a + b, 0) / s.length : null;
      return { backend: r.kind, timing: r.timing, state: target, frames, n: s.length, avgMs: avg, medMs: s.length ? s[Math.floor(s.length / 2)] : null, p95Ms: s.length ? s[Math.min(s.length - 1, Math.floor(s.length * 0.95))] : null, maxMs: s.length ? s[s.length - 1] : null, px: canvas.width, reducedMotion: reducedMotion() };
    },
    destroy() {
      if (dead) return; dead = true; stop();
      document.removeEventListener("visibilitychange", onVis);
      window.removeEventListener("nova:budget-cap", onCap);
      try { if (mq) mq.removeEventListener("change", onMq); } catch (e) {}
      try { if (io) io.disconnect(); } catch (e) {}
      try { if (ro) ro.disconnect(); } catch (e) {}
      try { r.destroy(); } catch (e) {}
      canvas.remove();
      if (typeof window !== "undefined" && window.__novaPresence3d === engine) window.__novaPresence3d = null;
    },
  };
  if (typeof window !== "undefined") window.__novaPresence3d = engine;   // lecture des mesures (console / banc), aucune écriture
  kick();
  return engine;
}
