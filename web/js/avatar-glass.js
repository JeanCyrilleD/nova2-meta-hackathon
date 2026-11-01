/* avatar-glass.js — 30/10 (Ahadi : « les avatars sont mauvais… reconstruis »). La présence de Nova en VERRE LIQUIDE,
   rendue en temps réel (WebGL, un seul fragment shader, aucune image, aucune dépendance).
   Une sphère de verre clair, visqueuse, habitée d'une petite lumière calme (l'âme de Nova) ; le verre réfracte un
   studio neutre (jour clair, nuit graphite), dispersion chromatique au bord, reflet spéculaire, liseré irisé discret.
   Même contrat que les autres moteurs (avatar.js) : setState(idle|listening|thinking|reading|speaking|tool|approval|
   done|celebrate|sleep|error), setLevel(0..1) MESURÉ, setMood, react, setFocus, destroy.
   États → paramètres continus (ressort exponentiel) : jamais de coupure entre deux états.
   Discipline : DPR ≤ 2 sur un petit canevas, 30 i/s au repos et en sommeil, 60 i/s sinon, arrêt hors écran / onglet caché,
   prefers-reduced-motion = mouvement ralenti de moitié. createGlassAvatar() renvoie null si WebGL manque (l'appelant
   garde l'orbe CSS). */

const VS = "attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}";

const FS = `
precision highp float;
uniform vec2 uRes; uniform float uT; uniform float uPh; uniform float uDark; uniform float uShiver; uniform float uPulse;
uniform vec4 uA;   // x bruit de surface, y ondes de parole, z rayon d'orbite des gouttes, w taille des gouttes
uniform vec4 uB;   // x intensité de l'âme, y respiration, z tassement (sommeil), w opacité du verre
uniform vec3 uCore; uniform vec2 uLook;

float h31(vec3 p){ p = fract(p*0.3183099 + 0.1); p *= 17.0; return fract(p.x*p.y*p.z*(p.x+p.y+p.z)); }
float vn(vec3 x){ vec3 i = floor(x), f = fract(x); f = f*f*(3.0-2.0*f);
  return mix(mix(mix(h31(i),h31(i+vec3(1,0,0)),f.x), mix(h31(i+vec3(0,1,0)),h31(i+vec3(1,1,0)),f.x), f.y),
             mix(mix(h31(i+vec3(0,0,1)),h31(i+vec3(1,0,1)),f.x), mix(h31(i+vec3(0,1,1)),h31(i+vec3(1,1,1)),f.x), f.y), f.z); }
float fbm(vec3 p){ return 0.65*vn(p) + 0.35*vn(p*2.03 + 7.1); }
float smin(float a, float b, float k){ float h = clamp(0.5 + 0.5*(b-a)/k, 0.0, 1.0); return mix(b, a, h) - k*h*(1.0-h); }
mat2 rot(float a){ float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

float map(vec3 p){
  float br = 1.0 + uB.y*0.022*sin(uT*1.5708) + uPulse*0.05;
  vec3 q = p; q.y *= 1.0 + uB.z; q.xz *= 1.0 - uB.z*0.4; q.y += uB.z*0.25;
  float d = length(q) - 0.60*br;
  d += uA.x*0.085*(fbm(p*2.2 + vec3(0.0, uT*0.28, uT*0.17)) - 0.5);
  float ang = acos(clamp(normalize(p + 1e-5).z, -1.0, 1.0));
  d += uA.y*0.018*sin(ang*9.0 - uT*8.5);
  d += uShiver*0.012*sin(p.x*38.0 + uT*55.0)*sin(p.y*31.0 - uT*47.0);
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    float a = uPh*(1.0 + 0.23*fi) + fi*2.094;
    vec3 c = vec3(cos(a), 0.34*sin(a*1.3 + fi), sin(a)) * uA.z * (1.0 + 0.06*fi);
    d = smin(d, length(p - c) - uA.w*(0.095 + 0.03*fi), 0.17);
  }
  return d;
}
vec3 nor(vec3 p){ const vec2 k = vec2(1.0, -1.0); const float e = 0.0015;
  return normalize(k.xyy*map(p + k.xyy*e) + k.yyx*map(p + k.yyx*e) + k.yxy*map(p + k.yxy*e) + k.xxx*map(p + k.xxx*e)); }

vec3 env(vec3 d){
  d.xz *= rot(uLook.x*0.35); d.yz *= rot(-uLook.y*0.25);
  vec3 top = mix(vec3(0.975, 0.978, 0.985), vec3(0.46, 0.47, 0.51), uDark);
  vec3 bot = mix(vec3(0.36, 0.37, 0.40), vec3(0.07, 0.072, 0.08), uDark);
  vec3 c = mix(bot, top, smoothstep(-0.18, 0.38, d.y));
  float key = smoothstep(0.84, 0.975, dot(d, normalize(vec3(-0.55, 0.72, 0.42))));
  float strip = smoothstep(0.07, 0.0, abs(d.x - 0.80)) * smoothstep(-0.35, 0.25, d.y) * smoothstep(0.95, 0.35, d.y);
  float floorL = smoothstep(0.2, 0.0, abs(d.y + 0.55)) * 0.18;
  c += vec3(1.0)*key*1.7 + vec3(0.94, 0.97, 1.0)*strip*0.85 + floorL*(1.0 - uDark*0.6);
  return c;
}

void main(){
  vec2 uv = (gl_FragCoord.xy*2.0 - uRes) / uRes.y;
  vec3 ro = vec3(0.0, 0.0, 2.5), rd = normalize(vec3(uv, -2.1));
  float b = dot(ro, rd), c0 = dot(ro, ro) - 1.32*1.32, disc = b*b - c0;
  if (disc < 0.0) { gl_FragColor = vec4(0.0); return; }
  float t = max(0.0, -b - sqrt(disc)), tmax = -b + sqrt(disc), md = 1e9;
  bool hit = false;
  for (int i = 0; i < 72; i++) {
    float d = map(ro + rd*t); md = min(md, d);
    if (d < 0.0012) { hit = true; break; }
    t += d*0.85; if (t > tmax) break;
  }
  vec3 cp = vec3(0.07 + uLook.x*0.10, 0.05 + uLook.y*0.08, 0.05) + 0.025*vec3(sin(uT*0.7), cos(uT*0.53), 0.0);
  if (!hit) {
    float g = exp(-md*11.0) * uB.x * 0.30;
    gl_FragColor = vec4(uCore*g, g);
    return;
  }
  vec3 p = ro + rd*t, n = nor(p);
  float cosi = max(dot(n, -rd), 0.0);
  float fres = 0.04 + 0.96*pow(1.0 - cosi, 5.0);
  vec3 rfl = env(reflect(rd, n));
  vec3 tR = normalize(refract(rd, n, 1.0/1.13) - n*0.30);
  vec3 tG = normalize(refract(rd, n, 1.0/1.16) - n*0.33);
  vec3 tB = normalize(refract(rd, n, 1.0/1.19) - n*0.36);
  vec3 trn = vec3(env(tR).r, env(tG).g, env(tB).b);
  float th = clamp(2.0*0.6*cosi, 0.0, 1.2);
  trn *= mix(vec3(1.0), vec3(0.955, 0.965, 0.985), th);
  float tc = max(dot(cp - p, tG), 0.0);
  float dc = length(p + tG*tc - cp);
  float core = uB.x*(exp(-dc*dc*38.0)*1.0 + exp(-dc*7.0)*0.20);
  vec3 L = normalize(vec3(-0.55, 0.72, 0.42));
  float spec = pow(max(dot(reflect(rd, n), L), 0.0), 110.0)*1.3 + pow(max(dot(reflect(rd, n), normalize(vec3(0.8, 0.1, 0.6))), 0.0), 60.0)*0.35;
  vec3 iri = (0.5 + 0.5*cos(6.2832*(fres*1.4 + vec3(0.0, 0.33, 0.67) + uT*0.02))) * 0.10 * smoothstep(0.15, 0.9, fres);
  float rim = smoothstep(0.42, 0.04, cosi);                 // bande sombre du bord (réfraction rasante, comme un vrai verre)
  vec3 col = mix(trn, rfl, fres*0.85) * mix(1.0, 0.50 + 0.25*uDark, rim) + uCore*core + vec3(spec) + iri;
  float a = clamp(uB.w*(0.30 + 0.55*rim + 0.35*fres) + core*0.80 + spec, 0.0, 1.0);
  float edge = smoothstep(0.0, 0.10, cosi);   // bord adouci (anticrénelage du contour)
  a *= mix(0.65, 1.0, edge);
  gl_FragColor = vec4(col*a, a);
}`;

/* Paramètres cibles par état : a = [bruit, ondes, orbite, gouttes], b = [âme, respiration, tassement, opacité],
   core = couleur de l'âme (quasi neutre, jamais saturée), speed = vitesse d'orbite, fps = cadence. */
const P = {
  idle:      { a: [0.55, 0, 0, 0],       b: [0.55, 1.0, 0, 0.62],  core: [1.0, 0.975, 0.93], speed: 0.35, fps: 30 },
  listening: { a: [0.40, 0.12, 0, 0],    b: [0.82, 0.5, 0, 0.66],  core: [0.94, 0.97, 1.0],  speed: 0.5,  fps: 60 },
  thinking:  { a: [0.60, 0, 0.86, 1.0],  b: [0.66, 0.4, 0, 0.64],  core: [1.0, 0.98, 0.95], speed: 1.35, fps: 60 },
  reading:   { a: [0.45, 0, 0.78, 0.7],  b: [0.60, 0.4, 0, 0.63],  core: [1.0, 0.98, 0.95], speed: 0.7,  fps: 60 },
  speaking:  { a: [0.45, 0.50, 0, 0],    b: [0.74, 0.3, 0, 0.66],  core: [1.0, 0.97, 0.92], speed: 0.6,  fps: 60 },
  tool:      { a: [0.50, 0, 0.92, 0.85], b: [0.66, 0.3, 0, 0.64],  core: [0.95, 0.97, 1.0],  speed: 2.1,  fps: 60 },
  approval:  { a: [0.35, 0, 0, 0],       b: [0.72, 1.6, 0, 0.64],  core: [1.0, 0.87, 0.62], speed: 0.4,  fps: 60 },
  done:      { a: [0.50, 0, 0, 0],       b: [1.05, 1.0, 0, 0.66],  core: [1.0, 0.97, 0.90], speed: 0.6,  fps: 60 },
  celebrate: { a: [0.70, 0, 1.22, 1.1],  b: [1.20, 1.0, 0, 0.68],  core: [1.0, 0.95, 0.86], speed: 2.5,  fps: 60 },
  sleep:     { a: [0.15, 0, 0, 0],       b: [0.20, 0.6, 0.09, 0.5], core: [1.0, 0.90, 0.80], speed: 0.15, fps: 30 },
  error:     { a: [0.70, 0, 0, 0],       b: [0.60, 0.3, 0, 0.64],  core: [1.0, 0.84, 0.82], speed: 0.5,  fps: 60, shiver: 1 },
};
const MOOD = { joie: 1.12, legere: 1.05, attention: 1.0, grave: 0.85 };

function isDark() {
  const d = document.documentElement.dataset.mode;
  if (d === "nuit") return true;
  if (d === "jour") return false;
  try { return matchMedia("(prefers-color-scheme: dark)").matches; } catch (e) { return false; }
}
function reduced() { try { return matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) { return false; } }

export function createGlassAvatar(host) {
  const cv = document.createElement("canvas");
  cv.className = "avatar-glass";
  cv.setAttribute("aria-hidden", "true");
  cv.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;pointer-events:none";
  let gl = null;
  try { gl = cv.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "low-power" }); } catch (e) { gl = null; }
  if (!gl) return null;
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { console.warn("[avatar-glass]", gl.getShaderInfoLog(s)); return null; } return s; };
  const vs = sh(gl.VERTEX_SHADER, VS), fs = sh(gl.FRAGMENT_SHADER, FS);
  if (!vs || !fs) return null;
  const pr = gl.createProgram(); gl.attachShader(pr, vs); gl.attachShader(pr, fs); gl.linkProgram(pr);
  if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) { console.warn("[avatar-glass]", gl.getProgramInfoLog(pr)); return null; }
  gl.useProgram(pr);
  const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(pr, "p"); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const U = {}; ["uRes", "uT", "uPh", "uDark", "uShiver", "uPulse", "uA", "uB", "uCore", "uLook"].forEach((k) => { U[k] = gl.getUniformLocation(pr, k); });
  host.appendChild(cv);

  let state = "idle", level = 0, mood = 1, dead = false, raf = 0, last = 0, lastDraw = 0, T = 0, PH = 0;
  let pulse = 0, shiverT = 0, focus = null, ptr = [0, 0], visible = true, lost = false, dark = isDark() ? 1 : 0;
  const cur = { a: P.idle.a.slice(), b: P.idle.b.slice(), core: P.idle.core.slice(), speed: P.idle.speed, look: [0, 0] };

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.round(cv.clientWidth * dpr)), h = Math.max(1, Math.round(cv.clientHeight * dpr));
    if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; gl.viewport(0, 0, w, h); }
  }
  const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(resize) : null; if (ro) ro.observe(cv);
  const io = typeof IntersectionObserver !== "undefined" ? new IntersectionObserver((es) => { visible = es.some((e) => e.isIntersecting); if (visible) kick(); }) : null; if (io) io.observe(cv);
  const onPtr = (e) => {
    const r = cv.getBoundingClientRect(); if (!r.width) return;
    const x = ((e.clientX - (r.left + r.width / 2)) / (window.innerWidth * 0.5));
    const y = -((e.clientY - (r.top + r.height / 2)) / (window.innerHeight * 0.5));
    ptr = [Math.max(-1, Math.min(1, x)), Math.max(-1, Math.min(1, y))];
  };
  addEventListener("pointermove", onPtr, { passive: true });
  const onVis = () => { if (!document.hidden) kick(); };
  document.addEventListener("visibilitychange", onVis);
  const mo = new MutationObserver(() => { dark = isDark() ? 1 : 0; kick(); });
  mo.observe(document.documentElement, { attributes: true, attributeFilter: ["data-mode", "data-theme"] });
  cv.addEventListener("webglcontextlost", (e) => { e.preventDefault(); lost = true; });
  cv.addEventListener("webglcontextrestored", () => { lost = false; kick(); });

  function frame(now) {
    raf = 0;
    if (dead || lost) return;
    if (document.hidden || !visible) return;   // relancé par visibilitychange / IntersectionObserver
    const tgt = P[state] || P.idle;
    const minDt = 1000 / (tgt.fps || 60) - 2;
    if (now - lastDraw < minDt) { raf = requestAnimationFrame(frame); return; }
    const dt = Math.min(0.1, last ? (now - last) / 1000 : 0.016); last = now; lastDraw = now;
    const slow = reduced() ? 0.5 : 1;
    T += dt * slow; PH += dt * cur.speed * slow;
    const k = 1 - Math.exp(-dt * 5.5);
    const lv = level;
    const ta = tgt.a.slice(), tb = tgt.b.slice();
    if (state === "speaking") { ta[1] += lv * 1.1; tb[0] += lv * 0.3; }
    if (state === "listening") { ta[0] += lv * 0.7; ta[1] += lv * 0.5; tb[0] += lv * 0.25; }
    tb[0] *= mood;
    for (let i = 0; i < 4; i++) { cur.a[i] += (ta[i] - cur.a[i]) * k; cur.b[i] += (tb[i] - cur.b[i]) * k; }
    for (let i = 0; i < 3; i++) cur.core[i] += (tgt.core[i] - cur.core[i]) * k;
    cur.speed += (tgt.speed - cur.speed) * k;
    const lk = focus || ptr;
    cur.look[0] += (lk[0] - cur.look[0]) * (1 - Math.exp(-dt * 3)); cur.look[1] += (lk[1] - cur.look[1]) * (1 - Math.exp(-dt * 3));
    pulse *= Math.exp(-dt * 4);
    const shiver = tgt.shiver ? Math.max(0, 1 - (now - shiverT) / 700) : 0;
    resize();
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform2f(U.uRes, cv.width, cv.height);
    gl.uniform1f(U.uT, T); gl.uniform1f(U.uPh, PH); gl.uniform1f(U.uDark, dark);
    gl.uniform1f(U.uShiver, shiver); gl.uniform1f(U.uPulse, pulse);
    gl.uniform4f(U.uA, cur.a[0], cur.a[1], cur.a[2], cur.a[3]);
    gl.uniform4f(U.uB, cur.b[0], cur.b[1], cur.b[2], cur.b[3]);
    gl.uniform3f(U.uCore, cur.core[0], cur.core[1], cur.core[2]);
    gl.uniform2f(U.uLook, cur.look[0], cur.look[1]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    raf = requestAnimationFrame(frame);
  }
  function kick() { if (!raf && !dead) { last = 0; raf = requestAnimationFrame(frame); } }
  kick();

  return {
    species: "verre",
    setState(s) { const n = P[s] ? s : "idle"; if (n !== state) { state = n; if (n === "error") shiverT = performance.now(); if (n === "done" || n === "celebrate") pulse = 1; } kick(); },
    setLevel(v) { level = Math.max(0, Math.min(1, +v || 0)); },
    setMood(m) { mood = MOOD[m] || 1; },
    react() { pulse = Math.max(pulse, 0.7); kick(); },
    setFocus(x, y) { focus = (x == null || y == null) ? null : [Math.max(-1, Math.min(1, x)), Math.max(-1, Math.min(1, y))]; },
    destroy() {
      dead = true; if (raf) cancelAnimationFrame(raf);
      removeEventListener("pointermove", onPtr); document.removeEventListener("visibilitychange", onVis);
      try { ro && ro.disconnect(); io && io.disconnect(); mo.disconnect(); } catch (e) {}
      try { const ext = gl.getExtension("WEBGL_lose_context"); if (ext) ext.loseContext(); } catch (e) {}
      cv.remove();
    },
  };
}
