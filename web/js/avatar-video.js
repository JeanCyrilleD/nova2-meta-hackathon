/* avatar-video.js — 30/10 soir (Ahadi : « des avatars animés, vidéos, flottants, avec de vrais mouvements naturels »).
   Les compagnons Panda et Panda roux viennent des VIDÉOS Veo d'Ahadi (fond vert). Chaque état de Nova est un passage
   de ces vidéos, pré-découpé hors ligne en planche d'images (web/avatars/video/<perso>_<état>.jpg, 20 i/s, cadré et
   à la même taille pour tous les états) ; ici, un petit shader WebGL rend le fond vert transparent et retire la teinte
   verte de la fourrure, image par image.
   Boucles en ALLER-RETOUR (le mouvement repart en arrière au lieu de sauter au début) : aucune coupure, même sur un
   passage d'une seconde. Changement d'état = fondu enchaîné de 0,3 s ; sortie du sommeil = réveil d'abord (panda roux).
   Même contrat que les autres moteurs (avatar.js) : setState, setLevel, setMood, react, setFocus, destroy.
   Discipline : une planche chargée à la demande, 20 i/s, arrêt hors écran / fenêtre cachée. null si WebGL ou manifeste manque. */

const BASE = new URL("../avatars/video/", import.meta.url).href;
let manifestP = null;
function manifest() {
  if (!manifestP) manifestP = fetch(BASE + "manifest.json", { cache: "no-cache" }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  return manifestP;
}
const ALIAS = { reading: "thinking", tool: "thinking", error: "idle" };

const VS = "attribute vec2 p;varying vec2 v;void main(){v=vec2(p.x*.5+.5,.5-p.y*.5);gl_Position=vec4(p,0.,1.);}";
const FS = `
precision mediump float;
varying vec2 v;
uniform sampler2D uA; uniform sampler2D uB;
uniform vec4 uCellA; uniform vec4 uCellB;   // colonne, rangée, nb colonnes, nb rangées
uniform float uMix; uniform float uHasB;
vec4 keyed(sampler2D t, vec4 c){
  vec2 q = clamp(v, 0.003, 0.997);
  vec3 s = texture2D(t, vec2((c.x + q.x) / c.z, (c.y + q.y) / c.w)).rgb;
  float dom = s.g - max(s.r, s.b);
  float a = 1.0 - smoothstep(0.035, 0.15, dom);
  s.g = min(s.g, max(s.r, s.b));
  return vec4(s * a, a);
}
void main(){
  vec4 a = keyed(uA, uCellA);
  if (uHasB > 0.5 && uMix < 1.0) { vec4 b = keyed(uB, uCellB); gl_FragColor = mix(b, a, uMix); }
  else gl_FragColor = a;
}`;

export async function createVideoAvatar(host, { species = "panda" } = {}) {
  const m = await manifest();
  const key = species === "renard" ? "panda_roux" : "panda";
  const def = m && m.characters && m.characters[key];
  if (!def) return null;
  const fps = m.fps || 20;
  const cv = document.createElement("canvas");
  cv.className = "avatar-video";
  cv.setAttribute("aria-hidden", "true");
  cv.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;pointer-events:none";
  let gl = null;
  try { gl = cv.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "low-power" }); } catch (e) {}
  if (!gl) return null;
  const sh = (t, s) => { const o = gl.createShader(t); gl.shaderSource(o, s); gl.compileShader(o); return gl.getShaderParameter(o, gl.COMPILE_STATUS) ? o : null; };
  const vs = sh(gl.VERTEX_SHADER, VS), fs = sh(gl.FRAGMENT_SHADER, FS);
  if (!vs || !fs) return null;
  const pr = gl.createProgram(); gl.attachShader(pr, vs); gl.attachShader(pr, fs); gl.linkProgram(pr);
  if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) return null;
  gl.useProgram(pr);
  const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(pr, "p"); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const U = {}; ["uA", "uB", "uCellA", "uCellB", "uMix", "uHasB"].forEach((k) => { U[k] = gl.getUniformLocation(pr, k); });
  host.appendChild(cv);

  /* Planches : chargées à la demande, gardées en mémoire (une texture par état). */
  const atlases = new Map();   // nom → { tex, ready, info }
  function atlas(name) {
    const st = def.states[name];
    if (!st) return null;
    if (atlases.has(name)) return atlases.get(name);
    const rec = { tex: gl.createTexture(), ready: false, info: st };
    atlases.set(name, rec);
    const img = new Image();
    img.decoding = "async";
    img.onload = () => {
      if (dead) return;
      gl.bindTexture(gl.TEXTURE_2D, rec.tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, img);
      rec.ready = true; kick();
    };
    img.src = BASE + st.atlas;
    return rec;
  }

  let dead = false, raf = 0, lastT = 0, visible = true, lost = false;
  let cur = null, prev = null, mixT0 = 0, after = null, wanted = "idle";
  // cur / prev : { name, rec, t0 (horodatage de départ du passage) }
  function stateName(n) { return def.states[n] ? n : (ALIAS[n] && def.states[ALIAS[n]] ? ALIAS[n] : "idle"); }
  function play(name, opts = {}) {
    const rec = atlas(name); if (!rec) return;
    if (cur && cur.rec.ready) { prev = { ...cur, frozen: frameIndex(cur, performance.now()) }; mixT0 = 0; }
    cur = { name, rec, t0: 0 };
    after = opts.after || null;
    kick();
  }
  function frameIndex(p, now) {
    const n = p.rec.info.n; if (n <= 1) return 0;
    const k = Math.floor(((now - p.t0) / 1000) * fps);
    if (p.rec.info.pingpong) { const per = 2 * (n - 1); const r = k % per; return r < n ? r : per - r; }
    return Math.min(k, n - 1);
  }
  function go(name) {
    const n = stateName(name);
    if (cur && cur.name === n) return;
    if (cur && cur.name === "sleep" && n !== "sleep" && def.states.wake) { play("wake", { after: n }); return; }
    play(n);
  }

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.round(cv.clientWidth * dpr)), h = Math.max(1, Math.round(cv.clientHeight * dpr));
    if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; gl.viewport(0, 0, w, h); }
  }
  const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(resize) : null; if (ro) ro.observe(cv);
  const io = typeof IntersectionObserver !== "undefined" ? new IntersectionObserver((es) => { visible = es.some((e) => e.isIntersecting); if (visible) kick(); }) : null; if (io) io.observe(cv);
  const onVis = () => { if (!document.hidden) kick(); };
  document.addEventListener("visibilitychange", onVis);
  cv.addEventListener("webglcontextlost", (e) => { e.preventDefault(); lost = true; });
  cv.addEventListener("webglcontextrestored", () => { lost = false; atlases.clear(); if (cur) play(cur.name); });

  const cellOf = (rec, i) => [i % rec.info.cols, Math.floor(i / rec.info.cols), rec.info.cols, rec.info.rows];
  function frame(now) {
    raf = 0;
    if (dead || lost || document.hidden || !visible || !cur) return;
    if (now - lastT < 1000 / fps - 4) { raf = requestAnimationFrame(frame); return; }
    lastT = now;
    if (cur.rec.ready) {
      if (!cur.t0) { cur.t0 = now; if (prev) mixT0 = now; }
      const info = cur.rec.info;
      const i = frameIndex(cur, now);
      // passage joué une seule fois (salut, réveil) : à la fin, l'état suivant
      if (!info.pingpong && i >= info.n - 1 && now - cur.t0 > (info.n / fps) * 1000) {
        const next = after || (wanted !== cur.name ? stateName(wanted) : "idle"); after = null;
        play(next === cur.name ? "idle" : next);
      }
      resize();
      const mix = prev ? Math.min(1, (now - mixT0) / 300) : 1;
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, cur.rec.tex);
      gl.uniform1i(U.uA, 0); gl.uniform4fv(U.uCellA, cellOf(cur.rec, i));
      if (prev && mix < 1) {
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, prev.rec.tex);
        gl.uniform1i(U.uB, 1); gl.uniform4fv(U.uCellB, cellOf(prev.rec, prev.frozen));
        gl.uniform1f(U.uHasB, 1);
      } else { prev = null; gl.uniform1f(U.uHasB, 0); }
      gl.uniform1f(U.uMix, mix);
      gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    raf = requestAnimationFrame(frame);
  }
  function kick() { if (!raf && !dead) raf = requestAnimationFrame(frame); }

  play("idle");
  ["thinking", "speaking", "listening"].forEach((n) => { if (def.states[n]) atlas(n); });   // préchargement des états fréquents
  return {
    species: key,
    setState(s) { if (dead) return; wanted = String(s || "idle"); go(wanted); },
    setLevel() {},
    setMood() {},
    react() { if (!dead && cur && cur.name === "idle" && def.states.done) play("done"); },
    setFocus() {},
    destroy() {
      dead = true; if (raf) cancelAnimationFrame(raf);
      document.removeEventListener("visibilitychange", onVis);
      try { ro && ro.disconnect(); io && io.disconnect(); } catch (e) {}
      atlases.forEach((r) => { try { gl.deleteTexture(r.tex); } catch (e) {} });
      try { const ext = gl.getExtension("WEBGL_lose_context"); if (ext) ext.loseContext(); } catch (e) {}
      cv.remove();
    },
  };
}
