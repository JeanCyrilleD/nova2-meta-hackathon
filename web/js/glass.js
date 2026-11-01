/* glass.js — MOTEUR LIQUID GLASS (24/10/2026).

   WebKit ne sait pas déformer l'arrière-plan d'un élément (backdrop-filter n'accepte pas
   les filtres SVG de déplacement). Or le fond de Nova nous appartient : c'est ce moteur
   qui le dessine. On peut donc obtenir la VRAIE réfraction du verre d'Apple :

     passe A  le fond d'écran « Aurore » (champs de couleur déformés, rubans nets, grain),
              rendu dans une texture mip-mappée — redessiné lentement (dérive de 90 s) ;
     passe B  pour chaque élément marqué [data-glass] (barre latérale, barres d'outils,
              capsules, fenêtres flottantes…), un rectangle arrondi en distance signée :
              lentille convexe au bord (le fond est comprimé/courbé), centre net mais
              flouté, saturation, teinte, liseré spéculaire orienté vers la lumière, bord
              sombre côté ombre, reflet qui suit le pointeur, ombre portée douce, et fusion
              « liquide » des formes voisines (union lisse).

   Le DOM du verre reste transparent (classe html.gl-on) et porte seulement le contenu.
   Repli : sans WebGL2, la recette CSS (backdrop-filter + liserés) de nova2.css s'applique.
   Discipline : pause quand la fenêtre est cachée, fond redessiné à 8 i/s max et SEULEMENT pendant
   l'activité (figé au repos, voir « régime repos / activité »), verre redessiné seulement si quelque
   chose bouge (rects, pointeur près du verre, thème, dérive). */

const VS = `#version 300 es
void main(){vec2 v=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(v*2.-1.,0,1);}`;

const WALL = `#version 300 es
precision highp float;
uniform vec2 uRes; uniform float uTime; uniform float uDark;
uniform vec3 uC0, uC1, uC2, uC3, uBg;
out vec4 o;
float h21(vec2 p){p=fract(p*vec2(123.34,456.21));p+=dot(p,p+45.32);return fract(p.x*p.y);}
float vn(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);
  return mix(mix(h21(i),h21(i+vec2(1,0)),f.x),mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x),f.y);}
float fbm(vec2 p){float s=0.,a=.5;for(int i=0;i<4;i++){s+=a*vn(p);p=p*2.03+vec2(1.7,9.2);a*=.5;}return s;}
void main(){
  vec2 uv=gl_FragCoord.xy/uRes; vec2 p=(gl_FragCoord.xy-.5*uRes)/uRes.y;
  float t=uTime*.011;
  vec2 q=p*1.15; q+=.55*vec2(fbm(q*1.1+t),fbm(q*1.1-t+5.2)); q+=.3*vec2(fbm(q*1.9-t*1.3+2.),fbm(q*1.9+t+8.));
  float f=fbm(q*1.05);
  // fond : dégradé profond + trois foyers colorés
  vec3 col=uBg;
  col=mix(col,uC0,smoothstep(.25,.85,fbm(q*.8+vec2(3.,1.))) *.95);
  col=mix(col,uC1,smoothstep(.45,.95,f)*.85);
  col=mix(col,uC2,smoothstep(.55,.9,fbm(q*1.3-vec2(7.,2.)))*.7);
  // rubans nets qui traversent les bords du verre (rendent la réfraction lisible)
  float r=fract(f*3.2+t*.6); float rib=smoothstep(.47,.5,r)-smoothstep(.53,.58,r);
  col=mix(col,uC3,rib*.55);
  float r2=abs(sin((q.x*1.7+q.y*.9+f*2.2)*3.1)); col+=uC3*pow(1.-r2,28.)*.35;
  // vignette + grain
  col*=mix(1.,.82,smoothstep(.55,1.15,length(p*vec2(.85,1.))));
  col+=(h21(gl_FragCoord.xy+fract(uTime))-.5)*(uDark>.5?.018:.012);
  o=vec4(col,1.);
}`;

const GLASS = `#version 300 es
precision highp float;
#define MAXR 24
uniform sampler2D uScene; uniform vec2 uRes; uniform float uDpr; uniform int uCount;
uniform vec4 uRect[MAXR]; uniform float uRad[MAXR]; uniform float uKind[MAXR];
uniform float uSmooth, uBand, uStrength, uChroma, uBlur, uSat, uBri, uTintAmt, uSpec, uDark;
uniform vec3 uTint; uniform vec2 uLight; uniform vec2 uPointer;
out vec4 o;
float sdRR(vec2 p, vec2 c, vec2 h, float r){vec2 q=abs(p-c)-h+r;return min(max(q.x,q.y),0.)+length(max(q,0.))-r;}
float smin(float a,float b,float k){if(k<=0.)return min(a,b);float h=max(k-abs(a-b),0.)/k;return min(a,b)-h*h*k*.25;}
float kindAt=0.;
float field(vec2 p){float d=1e5;float best=1e5;
  for(int i=0;i<MAXR;i++){if(i>=uCount)break;vec4 r=uRect[i];float di=sdRR(p,r.xy+r.zw*.5,r.zw*.5,uRad[i]);
    if(di<best){best=di;kindAt=uKind[i];} d=smin(d,di,uSmooth);} return d;}
vec2 toUV(vec2 p){return vec2(p.x/uRes.x,1.-p.y/uRes.y);}
vec3 blurAt(vec2 p,float rad){
  if(rad<.75)return textureLod(uScene,toUV(p),0.).rgb;
  float lod=max(log2(rad*.5),0.);vec3 s=vec3(0.);
  for(int i=0;i<12;i++){float a=float(i)*2.39996,r=rad*sqrt((float(i)+.5)/12.);s+=textureLod(uScene,toUV(p+r*vec2(cos(a),sin(a))),lod).rgb;}
  return s/12.;}
void main(){
  vec2 p=vec2(gl_FragCoord.x,uRes.y-gl_FragCoord.y);
  vec3 scene=textureLod(uScene,toUV(p),0.).rgb;
  float sd=field(p);
  float kind=kindAt;   // 0 = verre normal, 1 = capsule claire (moins de flou)
  float so=field(p-vec2(0.,12.*uDpr));
  float sh=exp(-max(so,0.)/(22.*uDpr))*.26+exp(-max(so+2.*uDpr,0.)/(6.*uDpr))*.12;
  vec3 base=scene*(1.-sh*mix(.6,1.,uDark));
  if(sd>3.*uDpr){o=vec4(base,1.);return;}
  float e=1.5;
  vec2 n=normalize(vec2(field(p+vec2(e,0.))-field(p-vec2(e,0.)),field(p+vec2(0.,e))-field(p-vec2(0.,e)))+1e-5);
  float d=max(-sd,0.);
  float band=uBand*mix(1.,.7,kind);
  float u=1.-clamp(d/band,0.,1.);
  float prof=1.-sqrt(max(1.-u*u,0.));
  float disp=uStrength*band*prof;
  float bl=uBlur*mix(1.,.35,kind);
  vec2 pg=p+n*disp;
  vec3 col;
  if(uChroma>.001){col=vec3(blurAt(p+n*disp*(1.+uChroma),bl).r,blurAt(pg,bl).g,blurAt(p+n*disp*(1.-uChroma),bl).b);}
  else col=blurAt(pg,bl);
  float l=dot(col,vec3(.299,.587,.114));
  col=mix(vec3(l),col,uSat)*uBri;
  col=mix(col,uTint,uTintAmt*mix(1.,.55,kind));
  float facing=max(dot(n,uLight),0.),back=max(dot(-n,uLight),0.);
  float dirTerm=pow(facing,1.6)+.45*pow(back,1.6);
  float rim=pow(u,5.);
  float lip=smoothstep(1.6*uDpr,0.,d);
  col+=vec3(1.)*uSpec*(rim*dirTerm*.85+lip*(.16+.66*dirTerm));
  col+=vec3(1.)*.05*pow(u,2.);
  col*=1.-.16*pow(u,3.)*(1.-dirTerm)*(1.-uDark*.3);
  float pg2=exp(-dot(p-uPointer,p-uPointer)/(2.*pow(80.*uDpr,2.)));
  col+=vec3(1.)*.2*pg2*smoothstep(band*2.5,0.,d);
  float cover=clamp(.5-sd,0.,1.);
  o=vec4(mix(base,col,cover),1.);
}`;

/* Palettes du fond, par thème (jour / nuit). Couleurs en 0..1. */
const hex = (s) => { const n = parseInt(s.slice(1), 16); return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255]; };
const PALETTES = {
  /* Obsidienne & Or Solaire : fond minéral, foyers d'ambre et d'or sahélien, une veine indigo (les agents). */
  "obsidienne-nuit": { bg: "#08090E", c0: "#5A3208", c1: "#1E1F55", c2: "#3A2410", c3: "#F7B05B", dark: 1, tint: [.08, .07, .06] },
  /* Ivoire & Encre : papier chaud, lumière dorée, rose de terre de Sienne très pâle. */
  "obsidienne-jour": { bg: "#EFEBE3", c0: "#F2D3A2", c1: "#EBCBC4", c2: "#E6DCC8", c3: "#FFFFFF", dark: 0, tint: [1, .99, .96] },
  "verre-nuit": { bg: "#070A18", c0: "#1B3FA8", c1: "#5B2BB5", c2: "#0E7C8C", c3: "#9CC8FF", dark: 1 },
  "verre-jour": { bg: "#DCE7F7", c0: "#7FB2FF", c1: "#C9A7FF", c2: "#8FE3D2", c3: "#FFFFFF", dark: 0 },
};
const P_DAY = { band: 24, strength: .72, chroma: .035, blur: 13, sat: 1.55, bri: 1.06, tint: [1, 1, 1], tintAmt: .2, spec: .95 };
const P_NIGHT = { band: 24, strength: .72, chroma: .04, blur: 16, sat: 1.45, bri: .86, tint: [.07, .085, .14], tintAmt: .34, spec: .72 };

export function startGlass() {
  if (window.__novaGlass) return window.__novaGlass;
  const root = document.documentElement;
  const cv = document.createElement("canvas");
  cv.id = "lgcanvas"; cv.setAttribute("aria-hidden", "true");
  let gl = null;
  try { gl = cv.getContext("webgl2", { antialias: false, alpha: false, powerPreference: "high-performance", preserveDrawingBuffer: false }); } catch (e) {}
  if (!gl) { root.classList.remove("gl-on"); return null; }
  document.body.prepend(cv);
  const prog = (fs) => {
    const p = gl.createProgram();
    for (const [t, s] of [[gl.VERTEX_SHADER, VS], [gl.FRAGMENT_SHADER, fs]]) {
      const sh = gl.createShader(t); gl.shaderSource(sh, s); gl.compileShader(sh);
      if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(sh) || "shader");
      gl.attachShader(p, sh);
    }
    gl.linkProgram(p); if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p) || "link");
    return p;
  };
  let A, B;
  try { A = prog(WALL); B = prog(GLASS); } catch (e) { console.warn("glass", e); cv.remove(); return null; }
  const UA = {}, UB = {};
  const ua = (n) => UA[n] || (UA[n] = gl.getUniformLocation(A, n));
  const ub = (n) => UB[n] || (UB[n] = gl.getUniformLocation(B, n));
  gl.bindVertexArray(gl.createVertexArray());
  let tex = null, fbo = null, W = 0, H = 0, dpr = 1, sceneW = 0, sceneH = 0;
  const SCENE_SCALE = 0.5;   // le fond est flou par nature : demi-résolution suffit
  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 1.5);   // discipline Nova 2 : DPR ≤ 1,5
    W = cv.width = Math.round(innerWidth * dpr); H = cv.height = Math.round(innerHeight * dpr);
    sceneW = Math.max(2, Math.round(W * SCENE_SCALE)); sceneH = Math.max(2, Math.round(H * SCENE_SCALE));
    if (tex) gl.deleteTexture(tex); if (fbo) gl.deleteFramebuffer(fbo);
    tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texStorage2D(gl.TEXTURE_2D, Math.floor(Math.log2(Math.max(sceneW, sceneH))) + 1, gl.RGBA8, sceneW, sceneH);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    fbo = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    dirtyScene = true; dirty = true;
  }
  let dirty = true, dirtyScene = true, lastScene = 0, lastSig = "", raf = 0;
  let ptr = [-1e5, -1e5], ptrT = [-1e5, -1e5];
  let pal = PALETTES["verre-nuit"], params = P_NIGHT, active = false;

  function readTheme() {
    const th = root.dataset.theme || "";
    active = (root.dataset.material === "verre" || root.dataset.material === "obsidienne") && root.dataset.transparency !== "reduced";
    pal = PALETTES[th] || PALETTES[root.dataset.mode === "jour" ? "verre-jour" : "verre-nuit"];
    params = pal.dark ? P_NIGHT : P_DAY;
    if (pal.tint) params = { ...params, tint: pal.tint };
    root.classList.toggle("gl-on", active);
    cv.style.display = active ? "block" : "none";
    dirtyScene = true; dirty = true; kick();
  }
  /* 29/10 (fluidité, « zéro gel > 100 ms au repos ») — rayon des coins mis en cache par élément :
     avant, getComputedStyle était appelé DEUX fois par élément et par image (60 i/s), même au repos. */
  let radCache = new WeakMap();
  function collect() {
    const rects = [], rads = [], kinds = [], nowMs = performance.now();
    const els = document.querySelectorAll("[data-glass]");
    for (const el of els) {
      if (rects.length >= 24 * 4) break;
      const b = el.getBoundingClientRect();
      if (b.width < 4 || b.height < 4 || b.bottom < 0 || b.top > innerHeight || b.right < 0 || b.left > innerWidth) continue;
      if (el.closest("[hidden], [aria-hidden='true'].mod")) continue;
      let c = radCache.get(el);
      if (!c || nowMs - c.t > 2000) { const cs = getComputedStyle(el); c = { r: parseFloat(cs.borderTopLeftRadius) || 0, vis: cs.visibility !== "hidden", t: nowMs }; radCache.set(el, c); }
      if (!c.vis) continue;
      const r = Math.min(c.r, b.width / 2, b.height / 2);
      rects.push(b.left * dpr, b.top * dpr, b.width * dpr, b.height * dpr); rads.push(r * dpr); kinds.push(el.dataset.glass === "clear" ? 1 : 0);
    }
    return { rects, rads, kinds };
  }

  /* 29/10 — RÉGIME REPOS / ACTIVITÉ. Mesure (jank.js, Conversations, aucun geste) : 42 gels de 250–490 ms en
     10 min. Cause principale côté page : ce moteur redessinait le fond Aurore 24 fois par seconde EN
     PERMANENCE ; chaque nouvelle image du canvas plein écran oblige le compositeur à recalculer TOUS les
     backdrop-filter posés au-dessus (rail, panneau 30 px, cartes de l'Accueil…). Désormais :
       · ACTIVITÉ (geste < 4 s : souris, clic, molette, clavier, défilement, transition CSS) : boucle rAF,
         rects suivis à chaque image, dérive du fond à 8 i/s (la dérive fait ~1 % d'un ruban par seconde :
         8 i/s est indiscernable de 24) ;
       · REPOS : AUCUNE boucle rAF, fond figé (l'horloge de dérive s'arrête — pas de saut à la reprise),
         une sonde à 1 Hz vérifie seulement que les rects n'ont pas bougé ; le premier geste relance tout.
     Réglage « Fond animé : Toujours » : la dérive continue au repos, à 4 i/s. « Jamais » : fond figé. */
  const ACTIVE_MS = 4000, SCENE_FPS_ACTIVE = 8, SCENE_FPS_ALWAYS_IDLE = 4;
  let lastInput = performance.now(), lastGeom = 0, animT = 12.0, animLast = 0, idleProbeT = 0;
  let bgModeCache = "auto", bgModeAt = -1e9, reduceCache = null;
  const bgMode = (now) => {
    if (now - bgModeAt > 2000) { bgModeAt = now; try { bgModeCache = localStorage.getItem("nova2_bg") || "auto"; } catch (e) { bgModeCache = "auto"; } }
    return bgModeCache;
  };
  try { const mqR = matchMedia("(prefers-reduced-motion: reduce)"); const f = () => { reduceCache = null; }; mqR.addEventListener ? mqR.addEventListener("change", f) : mqR.addListener && mqR.addListener(f); } catch (e) {}
  const reducedNow = () => { if (reduceCache === null) { try { reduceCache = matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) { reduceCache = false; } } return reduceCache || root.dataset.reduceMotion === "1"; };
  const nearGlass = (x, y, g) => {   // le reflet du pointeur n'existe qu'à proximité du bord du verre
    const m = 140 * dpr;
    for (let i = 0; i < g.rects.length; i += 4) { const L = g.rects[i], T = g.rects[i + 1], W2 = g.rects[i + 2], H2 = g.rects[i + 3]; if (x > L - m && x < L + W2 + m && y > T - m && y < T + H2 + m) return true; }
    return false;
  };
  let ptrNear = false;
  function frame(now) {
    raf = 0;
    if (!active || document.hidden) return;
    // Repos CPU (27/10, mesuré : NovaMac ~90 % au repos) : fenêtre non focalisée, la boucle
    // de mesure des rects tombe à ~2 i/s — le verre reste juste, personne ne le regarde défiler.
    if (!document.hasFocus()) {
      if (now - (frame.idleAt || 0) < 500) { kick(); return; }
      frame.idleAt = now;
    }
    const mode = bgMode(now);
    const animate = !reducedNow() && mode !== "never";   // réglage « Fond animé » (Jamais = fond figé)
    const busyInput = now - lastInput < ACTIVE_MS;
    const busy = busyInput || now - lastGeom < 1500;   // géométrie en mouvement : on suit les rects, sans faire dériver le fond
    const sceneFps = busyInput ? SCENE_FPS_ACTIVE : (mode === "always" ? SCENE_FPS_ALWAYS_IDLE : 0);
    if (animate && sceneFps && now - lastScene > 1000 / sceneFps) {
      animT += Math.min(0.25, animLast ? (now - animLast) / 1000 : 0);   // horloge de dérive : avance seulement quand on anime
      animLast = now; dirtyScene = true;
    } else if (!sceneFps) animLast = 0;
    // lissage du pointeur (reflet calme, jamais nerveux)
    ptr[0] += (ptrT[0] - ptr[0]) * .25; ptr[1] += (ptrT[1] - ptr[1]) * .25;
    const g = collect();
    /* le pointeur n'entre dans la signature que près du verre : survoler le contenu ne redessine plus
       le canvas plein écran (et donc plus tous les flous CSS) à 60 i/s */
    const near = nearGlass(ptr[0], ptr[1], g) || nearGlass(ptrT[0], ptrT[1], g);
    const pSig = near || ptrNear ? (ptr[0] | 0) + "," + (ptr[1] | 0) : "far";
    ptrNear = near;
    const sig = g.rects.map((v) => v | 0).join(",") + "|" + pSig;
    if (sig !== lastSig) { dirty = true; lastSig = sig; lastGeom = now; }   // un rect qui bouge = transition en cours : on suit encore un instant
    if (dirtyScene) {
      lastScene = now; dirtyScene = false; dirty = true;
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo); gl.viewport(0, 0, sceneW, sceneH); gl.useProgram(A);
      gl.uniform2f(ua("uRes"), sceneW, sceneH); gl.uniform1f(ua("uTime"), animate ? animT : 12.0); gl.uniform1f(ua("uDark"), pal.dark);
      gl.uniform3fv(ua("uBg"), hex(pal.bg)); gl.uniform3fv(ua("uC0"), hex(pal.c0)); gl.uniform3fv(ua("uC1"), hex(pal.c1)); gl.uniform3fv(ua("uC2"), hex(pal.c2)); gl.uniform3fv(ua("uC3"), hex(pal.c3));
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      gl.bindTexture(gl.TEXTURE_2D, tex); gl.generateMipmap(gl.TEXTURE_2D);
    }
    if (dirty) {
      dirty = false;
      gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0, 0, W, H); gl.useProgram(B);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.uniform1i(ub("uScene"), 0); gl.uniform2f(ub("uRes"), W, H); gl.uniform1f(ub("uDpr"), dpr);
      const n = g.rects.length / 4;
      gl.uniform1i(ub("uCount"), n);
      const R = new Float32Array(24 * 4); R.set(g.rects); gl.uniform4fv(ub("uRect"), R);
      const RA = new Float32Array(24); RA.set(g.rads); gl.uniform1fv(ub("uRad"), RA);
      const K = new Float32Array(24); K.set(g.kinds); gl.uniform1fv(ub("uKind"), K);
      const P = params;
      gl.uniform1f(ub("uSmooth"), 18 * dpr); gl.uniform1f(ub("uBand"), P.band * dpr); gl.uniform1f(ub("uStrength"), P.strength);
      gl.uniform1f(ub("uChroma"), P.chroma); gl.uniform1f(ub("uBlur"), P.blur * dpr); gl.uniform1f(ub("uSat"), P.sat); gl.uniform1f(ub("uBri"), P.bri);
      gl.uniform1f(ub("uTintAmt"), P.tintAmt); gl.uniform1f(ub("uSpec"), P.spec); gl.uniform1f(ub("uDark"), pal.dark);
      gl.uniform3fv(ub("uTint"), P.tint);
      const la = -2.2 + Math.sin(animT * .05) * .25;   // lumière : haut-gauche, dérive lente (horloge de dérive)
      gl.uniform2f(ub("uLight"), Math.cos(la), Math.sin(la));
      gl.uniform2f(ub("uPointer"), ptr[0], ptr[1]);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    /* repos : plus de boucle rAF — sauf réglage « Toujours » (dérive lente) ou pointeur encore en
       train de converger près du verre */
    const settling = near && (Math.abs(ptrT[0] - ptr[0]) > 0.5 || Math.abs(ptrT[1] - ptr[1]) > 0.5);
    if (busy || settling || dirty || dirtyScene) kick();
    else if (animate && mode === "always") { clearTimeout(idleProbeT); idleProbeT = setTimeout(kick, 1000 / SCENE_FPS_ALWAYS_IDLE); }
    else idleProbe();
  }
  /* Sonde de repos (1 Hz, sans rAF) : relance la boucle seulement si un rect de verre a changé. */
  function idleProbe() {
    clearTimeout(idleProbeT);
    idleProbeT = setTimeout(() => {
      idleProbeT = 0;
      if (raf || !active || document.hidden) return;
      const g = collect();
      const near = nearGlass(ptr[0], ptr[1], g);
      const sig = g.rects.map((v) => v | 0).join(",") + "|" + (near ? (ptr[0] | 0) + "," + (ptr[1] | 0) : "far");
      if (sig !== lastSig) { dirty = true; lastGeom = performance.now(); kick(); } else idleProbe();
    }, 1000);
  }
  /* 29/10 (Ahadi : « Nova lague ») — Nova derrière une autre app : le verre se redessine 2 fois par seconde au lieu de 60. */
  let slowT = 0;
  function kick() {
    if (raf || !active || document.hidden) return;
    if (idleProbeT) { clearTimeout(idleProbeT); idleProbeT = 0; }
    let focused = true; try { focused = document.hasFocus(); } catch (e) {}
    if (!focused) { if (!slowT) slowT = setTimeout(() => { slowT = 0; if (!raf && active && !document.hidden) raf = requestAnimationFrame(frame); }, 500); return; }
    raf = requestAnimationFrame(frame);
  }
  const wake = () => { lastInput = performance.now(); if (!raf) kick(); };
  const follow = () => { lastGeom = performance.now(); if (!raf) kick(); };   // géométrie seulement (pas de dérive du fond)
  const touchesGlass = (t) => { try { return !!(t && t.nodeType === 1 && (t.matches("[data-glass]") || t.querySelector("[data-glass]"))); } catch (e) { return false; } };
  addEventListener("resize", () => { radCache = new WeakMap(); resize(); follow(); });
  addEventListener("pointermove", (e) => { ptrT = [e.clientX * dpr, e.clientY * dpr]; wake(); }, { passive: true });
  for (const ev of ["pointerdown", "keydown", "wheel"]) addEventListener(ev, wake, { passive: true, capture: true });
  document.addEventListener("scroll", follow, { passive: true, capture: true });
  /* une transition / animation CSS peut déplacer un élément de verre (repli du rail, fenêtre flottante) :
     seulement si elle porte sur le verre lui-même ou un de ses ancêtres (le clignement de l'avatar, DANS
     le rail, ne réveille rien) */
  document.addEventListener("transitionrun", (e) => { if (touchesGlass(e.target)) follow(); }, { passive: true });
  document.addEventListener("animationstart", (e) => { if (touchesGlass(e.target)) follow(); }, { passive: true });
  document.addEventListener("visibilitychange", follow);
  addEventListener("focus", follow);
  addEventListener("nova:theme", () => { radCache = new WeakMap(); readTheme(); });
  addEventListener("nova:appearance", () => { radCache = new WeakMap(); readTheme(); });
  resize(); readTheme();
  const api = { refresh: () => { dirty = true; bgModeAt = -1e9; radCache = new WeakMap(); wake(); }, active: () => active };
  window.__novaGlass = api;
  return api;
}
