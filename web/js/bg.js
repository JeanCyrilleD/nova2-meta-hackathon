/* Nova 2 — LE fond animé, unique (voir architecture_nova2.md §5).
   Base : spatial-bg.js de Nova 1 (le seul des trois fonds concurrents qui méritait de survivre).
   Discipline Nova 2 : DPR plafonné à 1,5 ; AUCUN MutationObserver (le thème est relu uniquement sur
   l'événement « nova:theme » émis par core.js — Nova 1 relisait getComputedStyle + getImageData à chaque
   mutation de classe du body) ; pause hors écran ; garde-fou temps de dessin (repli statique si le GPU
   souffre) ; modes Auto / Toujours / Jamais via window.NovaBG.setMode() (réglage « Fond animé »).
   Repli : si WebGL échoue ou si le garde-fou se déclenche, le canvas disparaît et le dégradé statique
   de nova2.css (mêmes tokens) reste — l'événement « nova:bg-static » est émis. */
(function () {
  "use strict";
  if (window.__novaSpatialBg) return; window.__novaSpatialBg = true;
  const root = document.documentElement;
  const SCALE = 0.35, FRAME_MS = 1000 / 10;
  let mode = "auto"; try { mode = localStorage.getItem("nova2_bg") || "auto"; } catch (e) {}
  let calm = false;   // pause douce demandée par le shell (nova:bg-calm) : lecteur vidéo, mode concentration…
  let canvas, gl, prog, U = {}, raf = 0, last = 0, t0 = performance.now(), running = false, still = false, dead = false;
  /* 29/10 (fluidité : « zéro gel > 100 ms au repos ») — horloge d'animation qui n'avance QUE pendant qu'on
     anime (aucun saut à la reprise) et repos : 4 s sans geste (souris, clic, molette, clavier) = boucle
     arrêtée, fond figé ; le premier geste la relance. Réglage « Toujours » : jamais de repos. */
  const IDLE_MS = 4000;
  let animT = 0, animLast = 0, lastInput = performance.now(), parked = false;
  const mq = window.matchMedia ? matchMedia("(prefers-reduced-motion: reduce)") : { matches: false, addEventListener() {} };
  const probe = document.createElement("canvas").getContext("2d", { willReadFrequently: true });

  /* CSS (var, color-mix, noms…) -> [r,g,b] 0..1 */
  function rgb(css, fb) {
    try {
      if (!css) return fb;
      probe.clearRect(0, 0, 1, 1); probe.fillStyle = "#000"; probe.fillStyle = css; probe.fillRect(0, 0, 1, 1);
      const d = probe.getImageData(0, 0, 1, 1).data; return [d[0] / 255, d[1] / 255, d[2] / 255];
    } catch (e) { return fb; }
  }
  const lum = (c) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  const num = (cs, name, fb) => { const v = parseFloat(cs.getPropertyValue(name)); return isFinite(v) ? v : fb; };

  const params = { a: [0.3, 0.9, 0.8], g: [1, 0.8, 0.2], bg: [0.03, 0.04, 0.1], amp: 0.5, floor: 0.2 };
  function readTheme() {
    const cs = getComputedStyle(root);
    const a = rgb(cs.getPropertyValue("--accent").trim(), params.a);
    const gRaw = cs.getPropertyValue("--scene-glow-2").trim();
    const g = gRaw ? rgb(gRaw, a) : [a[0] * 0.6 + 0.25, a[1] * 0.6 + 0.25, a[2] * 0.6 + 0.4];
    const bg = rgb(cs.getPropertyValue("--scene-bg").trim(), params.bg);
    const L = lum(bg);
    const scene = num(cs, "--scene-intensity", 0.3);
    /* thèmes clairs / éditoriaux : très sobre, voire éteint (--scene-a:0 ou --floor-opacity:0) */
    const calm = L > 0.55 ? 0.12 : L > 0.35 ? 0.4 : 1;
    const floorV = num(cs, "--scene-floor", 0);
    params.a = a; params.g = g; params.bg = bg;
    params.amp = Math.max(0, Math.min(1, scene * 1.5)) * calm;
    params.floor = floorV * 0.4 * (L > 0.55 ? 0 : calm);
    if (gl) draw(performance.now());
  }

  const VS = "attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}";
  const FS = `precision mediump float;
uniform vec2 R;uniform float T;uniform vec3 A,G,B;uniform float AMP,FLO;uniform vec2 PAR;
float h(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float n(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);
 return mix(mix(h(i),h(i+vec2(1,0)),f.x),mix(h(i+vec2(0,1)),h(i+vec2(1,1)),f.x),f.y);}
float fbm(vec2 p){float s=0.,a=.5;for(int i=0;i<4;i++){s+=a*n(p);p=p*2.03+vec2(7.1,3.7);a*=.5;}return s;}
void main(){
 vec2 uv=gl_FragCoord.xy/R;float asp=R.x/R.y;vec2 p=vec2(uv.x*asp,uv.y);
 float t=T*.035;
 /* Parallaxe légère (correction 20/10) : la nébuleuse glisse de quelques millièmes
    contre la souris, les étoiles davantage — la profondeur vient du différentiel. */
 vec2 pp=p+PAR*.05;
 float w=fbm(pp*vec2(1.1,1.6)+vec2(t,-t*.7));
 float band=smoothstep(.15,.95,fbm(vec2(pp.x*1.3+w*1.6+t,pp.y*2.2-w*.8)));
 float curtain=smoothstep(.0,.9,uv.y)*smoothstep(1.35,.35,uv.y+.1*sin(pp.x*2.+t*6.));
 vec3 c=mix(A,G,smoothstep(.2,.9,fbm(pp*1.7-t)));
 float a=band*curtain*AMP;
 vec3 col=c*a;float al=a;
 /* Champ d'étoiles : grille hash, scintillement lent, fondues dans les zones claires
    de la nébuleuse pour rester lisibles. Même passe, aucun coût CPU. */
 vec2 sp=vec2(uv.x*asp,uv.y)*64.+PAR*2.4;
 vec2 cell=floor(sp);float rn=h(cell);
 float star=step(.9965,rn);
 vec2 f2=fract(sp)-.5;float d2=length(f2);
 float tw=.55+.45*sin(T*(.6+rn*2.2)+rn*40.);
 float st=star*smoothstep(.30,.02,d2)*tw*(0.25+0.75*AMP)*smoothstep(.55,.15,a);
 col+=vec3(.88,.92,1.)*st;al=max(al,st*.8);
 /* grille de sol en perspective */
 if(FLO>.001){
  float hz=.34;
  if(uv.y<hz){
   float d=hz-uv.y;float z=1./(d+.02);
   float gx=abs(fract((uv.x-.5)*asp*z*.35+.5)-.5)/(z*.35*.5);
   float gz=abs(fract(z*.5-T*.06)-.5);
   float lw=.02+d*.05;
   float line=max(1.-smoothstep(0.,lw*2.2,gx*asp*.5),1.-smoothstep(0.,.035,gz));
   float fade=smoothstep(0.,.1,d)*smoothstep(hz,hz*.2,d+.0)*(1.-d/hz*.3);
   float f=line*fade*FLO;
   col+=A*f;al+=f;
  }
 }
 al=clamp(al,0.,.9);
 gl_FragColor=vec4(min(col,vec3(al)),al);
}`;

  function sh(type, src) { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; }

  function setup() {
    canvas = document.createElement("canvas"); canvas.id = "spatialbg"; canvas.setAttribute("aria-hidden", "true");
    gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "low-power", preserveDrawingBuffer: false });
    if (!gl) return false;
    prog = gl.createProgram(); gl.attachShader(prog, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FS)); gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p"); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    for (const k of ["R", "T", "A", "G", "B", "AMP", "FLO", "PAR"]) U[k] = gl.getUniformLocation(prog, k);
    gl.disable(gl.BLEND); gl.clearColor(0, 0, 0, 0);
    document.body.insertBefore(canvas, document.body.firstChild);
    canvas.addEventListener("webglcontextlost", (e) => { e.preventDefault(); fail(); });
    return true;
  }

  function fit() {
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5), s = SCALE * dpr;   // NOVA2 : DPR WebGL ≤ 1,5
    const w = Math.max(2, Math.round(innerWidth * s)), hh = Math.max(2, Math.round(innerHeight * s));
    if (canvas.width !== w || canvas.height !== hh) { canvas.width = w; canvas.height = hh; gl.viewport(0, 0, w, hh); }
  }
  /* Parallaxe : cible = position de la souris (ou dérive lente sans souris),
     valeur lissée par pas de 3 % à chaque image — aucun écouteur coûteux, un lerp. */
  const par = { x: 0, y: 0 }, parT = { x: 0, y: 0 }; let parSeen = false;
  addEventListener("mousemove", (e) => {
    parSeen = true;
    parT.x = (e.clientX / Math.max(1, innerWidth)) * 2 - 1;
    parT.y = (e.clientY / Math.max(1, innerHeight)) * 2 - 1;
  }, { passive: true });
  function draw(now) {
    if (dead || !gl) return;
    fit();
    const tx = parSeen ? parT.x : Math.sin(now / 9000) * 0.35;
    const ty = parSeen ? parT.y : Math.cos(now / 11000) * 0.22;
    par.x += (tx - par.x) * 0.03; par.y += (ty - par.y) * 0.03;
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (!still && running && animLast) animT += Math.min(0.25, (now - animLast) / 1000);
    animLast = running ? now : 0;
    gl.uniform2f(U.R, canvas.width, canvas.height); gl.uniform1f(U.T, still ? 12 : animT);
    gl.uniform3fv(U.A, params.a); gl.uniform3fv(U.G, params.g); gl.uniform3fv(U.B, params.bg);
    gl.uniform1f(U.AMP, params.amp); gl.uniform1f(U.FLO, params.floor);
    gl.uniform2f(U.PAR, par.x, -par.y);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  let drawMsTotal = 0, drawCount = 0, drawWindowStart = 0;
  function tick(now) {
    raf = 0; if (!running) return;
    if (glassOwns()) { running = false; return; }   // le moteur Liquid Glass a pris le fond entre deux sync()
    if (mode !== "always" && performance.now() - lastInput > IDLE_MS && (!parSeen || (Math.abs(par.x - parT.x) < 0.01 && Math.abs(par.y - parT.y) < 0.01))) { parked = true; animLast = 0; return; }   // repos : boucle arrêtée
    raf = requestAnimationFrame(tick);
    if (now - last < FRAME_MS) return;
    last = now;
    const t1 = performance.now(); draw(now); const dt = performance.now() - t1;
    /* NOVA2 garde-fou : si dessiner une image coûte en moyenne > 20 ms sur une fenêtre de 3 s,
       le fond passe en statique (sauf mode « toujours »). Un fond qui lag est pire qu'un fond fixe. */
    if (mode !== "always") {
      if (!drawWindowStart) { drawWindowStart = now; drawMsTotal = 0; drawCount = 0; }
      drawMsTotal += dt; drawCount++;
      if (now - drawWindowStart >= 3000) {
        if (drawCount && drawMsTotal / drawCount > 20) { fail(); root.classList.add("bg-static"); try { window.dispatchEvent(new CustomEvent("nova:bg-static", { detail: { avgDrawMs: Math.round(drawMsTotal / drawCount) } })); } catch (e) {} return; }
        drawWindowStart = now; drawMsTotal = 0; drawCount = 0;
      }
    }
  }
  const glassOwns = () => root.classList.contains("gl-on");   // 24/10 : le moteur Liquid Glass dessine déjà le fond — une seule boucle WebGL à la fois
  const wake = () => { lastInput = performance.now(); if (parked && running && !raf) { parked = false; raf = requestAnimationFrame(tick); } };
  for (const ev of ["pointermove", "pointerdown", "keydown", "wheel"]) addEventListener(ev, wake, { passive: true, capture: true });
  const shouldRun = () => !dead && !still && !calm && !glassOwns() && !document.hidden && document.hasFocus();
  function sync() {
    if (dead) return;
    still = mq.matches || root.dataset.reduceMotion === "1";
    const want = shouldRun();
    if (want && !running) { running = true; parked = false; lastInput = performance.now(); if (!raf) raf = requestAnimationFrame(tick); }
    else if (!want && running) { running = false; if (raf) cancelAnimationFrame(raf), raf = 0; }
    if ((still || !want) && !glassOwns()) draw(performance.now());
    canvas.style.visibility = document.hidden ? "hidden" : "";
  }
  function fail() {
    dead = true; running = false; if (raf) cancelAnimationFrame(raf);
    root.classList.remove("gl-bg"); if (canvas) canvas.remove();
  }

  function start() {
    try {
      if (mode === "never") { root.classList.add("bg-static"); return; }   // réglage « Fond animé : Jamais »
      if (!setup()) { root.classList.add("bg-static"); return; }
      readTheme(); fit(); draw(performance.now());
      /* vérifie que le contexte est réellement utilisable avant de masquer l'ancien fond */
      if (gl.isContextLost() || gl.getError() !== gl.NO_ERROR) { fail(); root.classList.add("bg-static"); return; }
      root.classList.add("gl-bg");
      /* NOVA2 : AUCUN MutationObserver. Le thème est relu sur l'événement de core.js, la pause douce
         est demandée explicitement par le shell, le reste suit la visibilité de la fenêtre. */
      window.addEventListener("nova:theme", () => { readTheme(); setTimeout(sync, 80); if (!running && !glassOwns()) draw(performance.now()); });
      window.addEventListener("nova:appearance", () => { readTheme(); if (!running) draw(performance.now()); });   // R4 §5.8 : un changement de mode seul relit la scène
      window.addEventListener("nova:bg-calm", (e) => { calm = !!(e.detail && e.detail.on); sync(); });
      document.addEventListener("visibilitychange", sync); addEventListener("focus", sync); addEventListener("blur", sync);
      addEventListener("resize", () => { if (!running) draw(performance.now()); });
      (mq.addEventListener ? mq.addEventListener("change", sync) : mq.addListener && mq.addListener(sync));
      sync();
    } catch (e) { fail(); root.classList.add("bg-static"); }
  }
  /* API du réglage « Fond animé » : setMode("auto" | "always" | "never") — persisté, appliqué au prochain lancement
     pour never→animé ; « never » arrête immédiatement. */
  window.NovaBG = {
    mode: () => mode,
    setMode(m) {
      if (m !== "auto" && m !== "always" && m !== "never") return;
      mode = m; try { localStorage.setItem("nova2_bg", m); } catch (e) {}
      if (m === "never") { fail(); root.classList.add("bg-static"); }
    },
  };
  if (document.body) start(); else document.addEventListener("DOMContentLoaded", start, { once: true });
})();
