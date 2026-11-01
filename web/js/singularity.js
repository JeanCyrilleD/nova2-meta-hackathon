// Singularity Core — avatar cristallin (chargé paresseusement par avatar.js à la première activation).
// Sphère icosaédrique subdivisée + déplacement harmonique (vertex shader), réfraction à dispersion chromatique + Fresnel,
// anneaux gyroscopiques horlogers or #D4AF37 (cardan à 3 axes, graduations, rubis), filaments lumineux vers les Dots actifs.
// Un seul WebGLRenderer, créé ici et détruit (forceContextLoss) par destroy().
// NOVA2 (vague 2, item 1) : porté depuis Nova 1 (web/avatar-singularity-core.js) — adaptations :
// import three.js (../vendor/) et DPR plafonné à 1,5 dans fit() (discipline perf Nova 2).
import * as THREE from "../vendor/three.module.js";

const GOLD = 0xd4af37;
const STATE_COL = { idle: null, listening: "#4cc9ff", thinking: "#ffb020", tool: "#b48cff", speaking: "#3ddc97", error: "#ff4d5e" };
const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const FRAME = 2.62;   // demi-hauteur visible (unités monde) : l'anneau extérieur occupe ~70 % de l'hôte (= la coque #orb .shell)

function ensureStyle() {
  if (document.getElementById("nsg-style")) return;
  const s = document.createElement("style"); s.id = "nsg-style";
  s.textContent = ".nsg-on>:not(.nsg-layer){visibility:hidden!important}.nsg-layer{position:absolute;inset:0;pointer-events:none;opacity:0;transition:opacity .45s ease}.nsg-layer.in{opacity:1}.nsg-layer canvas{width:100%!important;height:100%!important;display:block}@media (prefers-reduced-motion:reduce){.nsg-layer{transition:none}}";
  document.head.appendChild(s);
}

const CORE_VS = /* glsl */`
uniform float uT, uAmp, uFreq, uTurb;
varying vec3 vN, vP, vO;
float disp(vec3 n){
  float d = sin(dot(n, vec3(2.3,1.3,-1.7))*uFreq + uT*1.10)*0.50
          + sin(dot(n, vec3(-1.5,2.1,0.9))*uFreq*1.31 - uT*1.45)*0.32
          + (n.x*n.x*n.x - 3.0*n.x*n.z*n.z)*sin(uT*0.83)*0.55            // harmonique Y(3,3)
          + (3.0*n.y*n.y - 1.0)*sin(uT*0.61 + 1.3)*0.18                   // harmonique Y(2,0)
          + sin(dot(n, vec3(1.1,-1.9,2.6))*uFreq*2.2 + uT*2.6)*0.22*uTurb;
  return d*uAmp;
}
void main(){
  vec3 n = normalize(position);
  vec3 p = n*(1.0 + disp(n));
  vec3 t = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0,1.0,0.0) : vec3(1.0,0.0,0.0)));
  vec3 b = cross(n, t);
  vec3 n1 = normalize(n + t*0.012), n2 = normalize(n + b*0.012);
  vec3 nn = normalize(cross(n1*(1.0+disp(n1)) - p, n2*(1.0+disp(n2)) - p));
  if (dot(nn, n) < 0.0) nn = -nn;
  vN = normalize(normalMatrix*nn); vO = p;
  vec4 mv = modelViewMatrix*vec4(p, 1.0); vP = mv.xyz;
  gl_Position = projectionMatrix*mv;
}`;
const CORE_FS = /* glsl */`
uniform vec3 uCol, uAcc, uDeep; uniform float uT, uGlow, uLevel;
varying vec3 vN, vP, vO;
const vec3 L1 = vec3(-0.48, 0.62, 0.62);
vec3 env(vec3 d){
  vec3 c = mix(uDeep, mix(uDeep, uAcc, 0.30), smoothstep(-0.8, 0.95, d.y));
  c += vec3(1.0, 0.97, 0.93)*pow(max(dot(d, normalize(L1)), 0.0), 40.0)*2.6;                         // boîte à lumière
  c += uAcc*pow(max(dot(d, normalize(vec3(0.8, -0.1, -0.55))), 0.0), 4.0)*0.55;                    // contre-jour
  c += vec3(0.83, 0.69, 0.22)*smoothstep(-0.3, -0.95, d.y)*0.30;                                   // rebond or
  return c;
}
void main(){
  vec3 N = normalize(vN), V = normalize(-vP), R = reflect(-V, N);
  float NdV = clamp(dot(N, V), 0.0, 1.0), F = 0.04 + 0.96*pow(1.0 - NdV, 5.0);
  vec3 refr = vec3(env(refract(-V, N, 0.690)).r, env(refract(-V, N, 0.672)).g, env(refract(-V, N, 0.654)).b);
  refr *= mix(vec3(1.0), uCol, 0.35);
  float inner = pow(NdV, 3.0);
  float veins = pow(abs(sin(vO.x*7.0 + uT*0.7)*sin(vO.y*6.0 - uT*0.5)*sin(vO.z*8.0 + uT*0.4)), 7.0);   // filaments internes
  vec3 col = refr*0.26 + uCol*pow(NdV, 5.0)*(0.05 + 0.3*uGlow) + uCol*veins*0.5*(0.4 + uGlow);
  col += mix(uCol, vec3(1.0), 0.6)*pow(NdV, 48.0)*0.8*(0.5 + uLevel + 0.4*uGlow);                                   // noyau
  col = mix(col, env(R), F*0.9);
  col += vec3(1.0)*(pow(max(dot(R, normalize(L1)), 0.0), 90.0)*1.8 + pow(max(dot(R, normalize(vec3(0.6, 0.3, 0.7))), 0.0), 40.0)*0.25);
  vec3 irid = 0.5 + 0.5*cos(6.2832*(vec3(0.0, 0.33, 0.67) + (1.0 - NdV)*1.3 + uT*0.04));
  col += irid*pow(1.0 - NdV, 3.5)*0.22;
  col += uCol*pow(1.0 - NdV, 2.6)*1.1*(0.5 + uGlow);
  col = 1.0 - exp(-col*1.2);
  float a = clamp(0.84 + F*0.16 + pow(1.0 - NdV, 2.0)*0.2, 0.0, 1.0);   // verre : le noyau transparaît
  gl_FragColor = vec4(pow(col, vec3(0.4545)), a);
}`;

function radialTex(stops) {
  const c = document.createElement("canvas"); c.width = c.height = 128; const g = c.getContext("2d"), r = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  for (const [o, a] of stops) r.addColorStop(o, `rgba(255,255,255,${a})`); g.fillStyle = r; g.fillRect(0, 0, 128, 128);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; return t;
}

function sgFail(host, e, where) {
  const msg = (where ? where + " : " : "") + String((e && (e.message || e)) || e).slice(0, 220);
  try { window.__sgErr = msg; localStorage.setItem("nova_sg_err", msg); } catch {}
  try { host.classList.remove("nsg-on"); host.querySelectorAll(":scope>.nsg-layer").forEach((n) => n.remove()); } catch {}
  try { window.dispatchEvent(new CustomEvent("nova:sgfail", { detail: msg })); } catch {}
}
// Montage blindé : toute erreur WebGL (shader, PMREM, contexte perdu) nettoie tout et laisse le panda visible.
export function mountSingularity(host, ctx) {
  try { const inst = mountInner(host, ctx); if (!inst) sgFail(host, "WebGL2 indisponible", "montage"); return inst || null; }
  catch (e) { sgFail(host, e, "montage"); return null; }
}
function mountInner(host, ctx) {
  ensureStyle();
  const layer = document.createElement("div"); layer.className = "nsg-layer";
  let renderer;
  // sonde silencieuse : sans WebGL2 on ne crée rien (le panda reste), sinon three réutilise ce même contexte (un seul)
  const cv = document.createElement("canvas"); cv.style.setProperty("display", "block", "important"); cv.style.setProperty("opacity", "1", "important"); cv.style.setProperty("visibility", "visible", "important");   // le thème Liquid Glass masque tous les <canvas> (app.css : body.liquid canvas) ; celui-ci doit rester visible
  const gl = cv.getContext("webgl2", { antialias: true, alpha: true, premultipliedAlpha: true, depth: true, stencil: false, powerPreference: "high-performance" });
  if (!gl) return null;
  try { renderer = new THREE.WebGLRenderer({ canvas: cv, context: gl, antialias: true, alpha: true }); }
  catch (e) { try { gl.getExtension("WEBGL_lose_context")?.loseContext(); } catch {} return null; }
  if (!renderer.getContext()) { try { renderer.dispose(); } catch {} return null; }
  renderer.outputColorSpace = THREE.SRGBColorSpace; renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.toneMappingExposure = 1.1;
  renderer.setClearColor(0x000000, 0);
  let failed = false; const fail = (e, w) => { if (failed) return; failed = true; try { inst && inst.destroy(); } catch {} sgFail(host, e, w); };
  let inst = null;
  renderer.debug.onShaderError = (g, prog, vs, fs) => { let log = ""; try { log = g.getProgramInfoLog(prog) || ""; } catch {} fail(log || "shader", "shader"); };
  cv.addEventListener("webglcontextlost", (ev) => { ev.preventDefault(); fail("contexte WebGL perdu", "gpu"); });
  layer.appendChild(renderer.domElement); host.appendChild(layer);

  const scene = new THREE.Scene(), cam = new THREE.PerspectiveCamera(28, 1, 0.1, 60);
  // environnement studio (pour l'or) : PMREM d'une petite scène procédurale, détruite aussitôt
  const pmrem = new THREE.PMREMGenerator(renderer);
  const envScene = new THREE.Scene();
  envScene.add(new THREE.Mesh(new THREE.SphereGeometry(10, 32, 16), new THREE.ShaderMaterial({ side: THREE.BackSide,
    vertexShader: "varying vec3 d; void main(){ d = normalize(position); gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.0); }",
    fragmentShader: "varying vec3 d; void main(){ vec3 c = mix(vec3(0.05,0.045,0.04), vec3(0.55,0.5,0.45), smoothstep(-0.5,0.9,d.y)); gl_FragColor = vec4(c,1.0); }" })));
  for (const [x, y, z, w, h, k] of [[-5, 5, 5, 6, 3, 6], [6, 1, -2, 2, 7, 2.2], [0, -6, 3, 8, 2, 0.9], [-6, 0, -4, 2, 5, 1.4]]) {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(k, k * 0.97, k * 0.92), side: THREE.DoubleSide }));
    m.position.set(x, y, z); m.lookAt(0, 0, 0); envScene.add(m);
  }
  const envRT = pmrem.fromScene(envScene, 0.035); pmrem.dispose();
  envScene.traverse((o) => { if (o.isMesh) { o.geometry.dispose(); o.material.dispose(); } });
  scene.environment = envRT.texture;
  scene.add(new THREE.HemisphereLight(0xffffff, 0x302820, 0.6));
  const keyL = new THREE.DirectionalLight(0xffffff, 1.6); keyL.position.set(-3, 4, 5); scene.add(keyL);

  const root = new THREE.Group(); scene.add(root);
  // halo arrière (glow maîtrisé)
  const haloTex = radialTex([[0, 0.85], [0.28, 0.32], [0.6, 0.08], [1, 0]]);
  const halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: haloTex, color: 0x4cc9ff, transparent: true, opacity: 0.4, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false }));
  halo.scale.set(4.6, 4.6, 1); halo.position.z = -1.6; root.add(halo);

  // noyau
  const U = { uT: { value: 0 }, uAmp: { value: 0.04 }, uFreq: { value: 2.2 }, uTurb: { value: 0 }, uGlow: { value: 0.3 }, uLevel: { value: 0 },
    uCol: { value: new THREE.Color("#4cc9ff") }, uAcc: { value: new THREE.Color("#4cc9ff") }, uDeep: { value: new THREE.Color(0x020306) } };
  const core = new THREE.Mesh(new THREE.IcosahedronGeometry(1, 36), new THREE.ShaderMaterial({ uniforms: U, vertexShader: CORE_VS, fragmentShader: CORE_FS }));
  core.material.transparent = true; core.renderOrder = 3; core.scale.setScalar(0.9);
  // singularité : nucleus lumineux visible à travers le verre
  const nucMat = new THREE.MeshBasicMaterial({ color: 0xffffff, toneMapped: false });
  const nucleus = new THREE.Mesh(new THREE.IcosahedronGeometry(0.2, 1), nucMat); root.add(nucleus);
  const nucGlow = new THREE.Sprite(new THREE.SpriteMaterial({ map: haloTex, color: 0x4cc9ff, transparent: true, opacity: 0.9, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false }));
  nucGlow.scale.setScalar(1.3); nucGlow.renderOrder = 2; root.add(nucGlow); root.add(core);

  // anneaux gyroscopiques (cardan) — or poli + graduations + rubis
  const gold = new THREE.MeshPhysicalMaterial({ color: GOLD, metalness: 1, roughness: 0.2, clearcoat: 1, clearcoatRoughness: 0.08, envMapIntensity: 1.6 });
  const goldDim = new THREE.MeshPhysicalMaterial({ color: 0xb8922a, metalness: 1, roughness: 0.32, envMapIntensity: 1.0 });
  const jewelMat = new THREE.MeshPhysicalMaterial({ color: 0xc00000, emissive: 0xc00000, emissiveIntensity: 0.35, roughness: 0.05, metalness: 0, clearcoat: 1, transmission: 0, envMapIntensity: 1.6 });
  const RADII = [1.36, 1.56, 1.76];
  const gimbal = []; let parent = root; const ringMeshes = [], tickMeshes = [];
  RADII.slice().reverse().forEach((r, k) => {           // extérieur → intérieur (chaque anneau porte le suivant)
    const g = new THREE.Group(); parent.add(g); gimbal.unshift(g); parent = g;
    const ring = new THREE.Mesh(new THREE.TorusGeometry(r, 0.024, 18, 240), k === 0 ? gold : (k === 1 ? gold : goldDim)); g.add(ring); ringMeshes.unshift(ring);
    // pivots (axes du cardan) : deux petites goupilles diamétralement opposées
    // k=0 extérieur : lunette qui tourne dans son plan ; k=1 pivote sur Y ; k=2 (intérieur) pivote sur X → goupilles sur l'axe de pivot
    if (k > 0) { const pinG = new THREE.CylinderGeometry(0.024, 0.024, 0.15, 12), onY = k === 1;
      for (const s of [-1, 1]) { const p = new THREE.Mesh(pinG, gold); if (!onY) p.rotation.z = Math.PI / 2; p.position.set(onY ? 0 : s * (r + 0.06), onY ? s * (r + 0.06) : 0, 0); g.add(p); } }
    const j = new THREE.Mesh(new THREE.SphereGeometry(0.052, 20, 14), jewelMat); const ja = k === 1 ? 0 : k === 2 ? Math.PI / 2 : Math.PI / 4; j.position.set(Math.cos(ja) * r, Math.sin(ja) * r, 0); g.add(j);
  });
  { // graduations d'horlogerie sur l'anneau extérieur (60 index, 12 longs)
    const r = RADII[2], n = 60, tg = new THREE.BoxGeometry(1, 1, 1);
    const ticks = new THREE.InstancedMesh(tg, gold, n); const m = new THREE.Matrix4(), q = new THREE.Quaternion(), s = new THREE.Vector3(), p = new THREE.Vector3(), z = new THREE.Vector3(0, 0, 1);
    for (let i = 0; i < n; i++) { const a = i / n * Math.PI * 2, long = i % 5 === 0, L = long ? 0.13 : 0.06;
      p.set(Math.cos(a) * (r - 0.04 - L / 2), Math.sin(a) * (r - 0.04 - L / 2), 0); q.setFromAxisAngle(z, a - Math.PI / 2); s.set(long ? 0.024 : 0.012, L, 0.012); m.compose(p, q, s); ticks.setMatrixAt(i, m); }
    gimbal[2].add(ticks); tickMeshes.push(ticks);
  }
  gimbal[2].rotation.set(1.18, 0, 0.32); gimbal[1].rotation.set(0, 0.9, 0); gimbal[0].rotation.set(0.6, 0, 0);

  // Dots satellites + filaments lumineux
  const dotTex = radialTex([[0, 1], [0.22, 0.85], [0.5, 0.18], [1, 0]]);
  const NF = 6, FS = 48; const sats = [], fils = [];
  for (let i = 0; i < NF; i++) {
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: dotTex, color: 0x4cc9ff, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false }));
    sp.scale.setScalar(0.32); root.add(sp);
    const geo = new THREE.BufferGeometry(); const pos = new Float32Array(FS * 3), al = new Float32Array(FS);
    for (let k = 0; k < FS; k++) al[k] = k / (FS - 1);
    geo.setAttribute("position", new THREE.BufferAttribute(pos, 3)); geo.setAttribute("u", new THREE.BufferAttribute(al, 1));
    const mat = new THREE.ShaderMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
      uniforms: { c: { value: new THREE.Color(0x4cc9ff) }, t: { value: 0 }, a: { value: 1 }, ph: { value: i * 0.37 } },
      vertexShader: "attribute float u; varying float vu; void main(){ vu = u; gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.0); }",
      fragmentShader: "uniform vec3 c; uniform float t, a, ph; varying float vu; void main(){ float f = fract(vu*1.6 - t*0.55 - ph); float pulse = smoothstep(0.0,0.12,f)*smoothstep(0.32,0.12,f); float env = smoothstep(0.0,0.15,vu)*smoothstep(1.0,0.75,vu); float k = (0.28 + pulse*1.3)*env*a; gl_FragColor = vec4(c*k, k); }" });
    const line = new THREE.Line(geo, mat); line.frustumCulled = false; root.add(line);
    sats.push({ sp, a: i / NF * Math.PI * 2 + 0.3, tilt: (i % 3 - 1) * 0.55 + 0.15, r: 2.0 + (i % 2) * 0.16, sp0: 0.22 + (i % 3) * 0.07, vis: 0 });
    fils.push({ line, geo, mat });
  }
  // poussière d'or
  const ND = 70, dpos = new Float32Array(ND * 3), dseed = [];
  for (let i = 0; i < ND; i++) dseed.push({ a: Math.random() * 6.283, r: 1.2 + Math.random() * 1.3, y: (Math.random() - 0.5) * 3.6, s: 0.1 + Math.random() * 0.35 });
  const dg = new THREE.BufferGeometry(); dg.setAttribute("position", new THREE.BufferAttribute(dpos, 3));
  const dm = new THREE.PointsMaterial({ map: dotTex, color: GOLD, size: 0.055, transparent: true, opacity: 0.7, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false });
  root.add(new THREE.Points(dg, dm));
  // Singularity vivant : un satellite doré par Dot en cours de travail (max 8), qui orbite et pulse ; plus de Dots actifs = anneaux plus vifs.
  const satG = new THREE.SphereGeometry(0.07, 16, 12), satM = new THREE.MeshBasicMaterial({ color: GOLD, toneMapped: false, transparent: true, opacity: 0 });
  const goldSats = Array.from({ length: 8 }, (_, i) => { const m = new THREE.Mesh(satG, satM.clone()); m.userData.i = i; root.add(m); return m; });
  let actN = 0, actS = 0;

  // ── taille / cadrage
  let pxSize = 0;
  const fit = () => {
    const w = Math.max(1, host.clientWidth), h = Math.max(1, host.clientHeight); const s = Math.min(w, h);
    const dpr = window.devicePixelRatio || 1; renderer.setPixelRatio(Math.min(1.5, Math.max(dpr, s < 300 ? 1.5 : 1)));   // NOVA2 : DPR ≤ 1,5 (avant : 2)
    renderer.setSize(w, h, false); cam.aspect = w / h;
    const half = FRAME / Math.min(1, cam.aspect); cam.position.set(0, 0, half / Math.tan(cam.fov * Math.PI / 360)); cam.lookAt(0, 0, 0); cam.updateProjectionMatrix();
    pxSize = s;
    const small = s < 200; tickMeshes.forEach((t) => (t.visible = s >= 160)); dm.size = small ? 0.075 : 0.055;
    const tube = small ? 0.036 : s < 300 ? 0.028 : 0.024;                        // anneaux plus épais en petit : lisibles à 136 px
    ringMeshes.forEach((rm, i) => { if (rm.userData.tube === tube) return; rm.geometry.dispose(); rm.geometry = new THREE.TorusGeometry(RADII[i], tube, 18, 240); rm.userData.tube = tube; });
  };
  const ro = new ResizeObserver(fit); ro.observe(host); fit();

  // ── état (réutilise les signaux de l'assistant : ctx.avatar.state + niveau audio)
  let level = 0, lvlS = 0, st = "idle";
  const av = ctx && ctx.avatar; const origSetLevel = av && av.setLevel;
  if (av && origSetLevel) av.setLevel = function (v) { level = clamp(+v || 0, 0, 1); return origSetLevel.call(this, v); };
  const onLevel = (e) => { level = clamp(+(e.detail && e.detail.level) || 0, 0, 1); };
  ctx && ctx.A && ctx.A.addEventListener && ctx.A.addEventListener("level", onLevel);
  const accent = new THREE.Color("#4cc9ff"), tmp = new THREE.Color();
  const deep = new THREE.Color(0x020306);
  const readAccent = () => { const cs = getComputedStyle(document.documentElement), v = cs.getPropertyValue("--accent").trim(), bg = cs.getPropertyValue("--bg").trim();
    try { if (v) accent.set(v); } catch {}
    try { if (bg) { tmp.set(bg); const lum = 0.2126 * tmp.r + 0.7152 * tmp.g + 0.0722 * tmp.b; deep.copy(tmp).multiplyScalar(lum > 0.45 ? 0.42 : 0.18); } } catch {}   // thème clair : verre plus lumineux
    U.uDeep.value.copy(deep); };
  readAccent(); const mo = new MutationObserver(readAccent); mo.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "style", "class"] });
  U.uAcc.value.copy(accent); U.uCol.value.copy(accent);
  const tgt = { x: 0, y: 0 }, look = { x: 0, y: 0 };
  const onMove = (e) => { const r = host.getBoundingClientRect(); const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    tgt.x = clamp((e.clientX - cx) / (innerWidth * 0.5), -1, 1); tgt.y = clamp(-(e.clientY - cy) / (innerHeight * 0.5), -1, 1); };
  addEventListener("pointermove", onMove, { passive: true });
  /* REQUALIFICATION (22/10, audit §5.3) : ces satellites comptaient les Dots
     du PARC — un signal réel mais mal étiqueté (« combien de Dots existent »
     n'est pas « qui travaille »). Ils lisent désormais le nombre de Dots
     RÉELLEMENT en cours, la même source que les satellites dorés :
     /api/dots/active, publié dans __novaActiveDots par avatar.js.
     Au repos (0 en cours), ils s'effacent — le mouvement signifie un état. */
  const activeDots = () => { try { const n = Number(window.__novaActiveDots); return Number.isFinite(n) ? clamp(n, 0, NF) : 0; } catch { return 0; } };

  const col = new THREE.Color(), V3 = new THREE.Vector3(), C1 = new THREE.Vector3(), C2 = new THREE.Vector3(), P0 = new THREE.Vector3(), P = new THREE.Vector3();
  let spin = [0, 0, 0], jitter = 0, nDots = activeDots(), dotsT = 0;
  function tick(dt, t) {
    st = (av && av.state) || "idle";
    try { actN = Math.min(8, Math.max(0, +window.__novaActiveDots || 0)); } catch { actN = 0; }
    actS = lerp(actS, actN, 1 - Math.exp(-dt * 3));
    goldSats.forEach((m, i) => { const on = i < actN, ph = t * (0.7 + i * 0.09) + i * 0.8; m.visible = on || m.material.opacity > 0.02;
      m.material.opacity = lerp(m.material.opacity, on ? 0.75 + 0.25 * Math.sin(t * 3 + i) : 0, 1 - Math.exp(-dt * 4));
      const R = 1.55 + (i % 3) * 0.16, inc = 0.5 + i * 0.35; m.position.set(Math.cos(ph) * R, Math.sin(ph) * R * Math.sin(inc), Math.sin(ph) * R * Math.cos(inc) * 0.6); });
    lvlS = lerp(lvlS, level, 1 - Math.exp(-dt * 16));
    const sc = STATE_COL[st]; col.copy(accent); if (sc) col.lerp(tmp.set(sc), 0.88);
    U.uCol.value.lerp(col, 1 - Math.exp(-dt * 5)); U.uAcc.value.lerp(accent, 1 - Math.exp(-dt * 5));
    const thinking = st === "thinking" || st === "tool";
    const amp = st === "speaking" ? 0.04 + lvlS * 0.045 : st === "listening" ? 0.04 + lvlS * 0.04 : thinking ? 0.075 : st === "error" ? 0.09 : 0.04;
    U.uAmp.value = lerp(U.uAmp.value, amp, 1 - Math.exp(-dt * 8)); U.uTurb.value = lerp(U.uTurb.value, thinking || st === "error" ? 1 : 0.25, 1 - Math.exp(-dt * 3));
    U.uFreq.value = lerp(U.uFreq.value, thinking ? 2.8 : 2.2, 1 - Math.exp(-dt * 2));
    const glow = 0.28 + lvlS * 0.9 + (thinking ? 0.25 : 0) + (st === "listening" ? 0.15 : 0);
    U.uGlow.value = lerp(U.uGlow.value, glow, 1 - Math.exp(-dt * 6)); U.uLevel.value = lvlS; U.uT.value = t * (thinking ? 1.6 : 1);
    nucMat.color.copy(U.uCol.value).lerp(tmp.set(0xffffff), 0.55); nucGlow.material.color.copy(U.uCol.value);
    nucleus.rotation.y += dt * (thinking ? 4 : 0.8); nucleus.rotation.x += dt * (thinking ? 2.6 : 0.5);
    nucleus.scale.setScalar(1 + 0.12 * Math.sin(t * 2.2) + lvlS * 0.45); nucGlow.scale.setScalar(1.6 + lvlS * 0.6 + (thinking ? 0.25 * Math.sin(t * 6) : 0));
    nucGlow.material.opacity = clamp(0.8 + lvlS * 0.2 + (thinking ? 0.2 : 0), 0, 1);
    core.rotation.y += dt * (thinking ? 0.6 : 0.18); core.rotation.x = Math.sin(t * 0.3) * 0.15;
    core.scale.setScalar(0.9 * (1 + Math.sin(t * 1.4) * 0.012 + lvlS * 0.05));
    halo.material.color.lerp(col, 1 - Math.exp(-dt * 4)); halo.material.opacity = clamp(0.3 + 0.06 * Math.sin(t * 1.3) + lvlS * 0.35 + (thinking ? 0.08 : 0), 0, 0.75);
    halo.scale.setScalar(4.4 + lvlS * 0.8);
    // cardan : vitesses horlogères distinctes
    const mult = thinking ? 3.2 : st === "speaking" ? 1 + lvlS * 1.6 : st === "listening" ? 0.6 : 1;
    spin[0] += dt * 0.55 * mult; spin[1] += dt * 0.32 * mult; spin[2] += dt * 0.12 * mult;
    gimbal[0].rotation.x = 0.6 + spin[0]; gimbal[1].rotation.y = 0.9 + spin[1]; gimbal[2].rotation.z = 0.32 + spin[2];
    jewelMat.emissiveIntensity = 0.35 + lvlS * 1.2 + (thinking ? 0.3 * (0.5 + 0.5 * Math.sin(t * 6)) : 0);
    // regard : toute la scène s'incline légèrement vers le curseur ; erreur → tremblement
    look.x = lerp(look.x, tgt.x, 1 - Math.exp(-dt * 5)); look.y = lerp(look.y, tgt.y, 1 - Math.exp(-dt * 5));
    jitter = st === "error" ? Math.sin(t * 40) * 0.035 : 0;
    root.rotation.y = look.x * 0.32 + jitter; root.rotation.x = -look.y * 0.22 + (st === "listening" ? -0.06 : 0);
    // Dots + filaments
    dotsT -= dt; if (dotsT <= 0) { nDots = activeDots(); dotsT = 2; }
    core.updateMatrixWorld();
    sats.forEach((s, i) => {
      const on = i < nDots; s.vis = lerp(s.vis, on ? 1 : 0, 1 - Math.exp(-dt * 3));
      s.a += dt * s.sp0 * (thinking ? 2.4 : 1);
      V3.set(Math.cos(s.a) * s.r, Math.sin(s.a * 1.3 + i) * 0.35, Math.sin(s.a) * s.r).applyAxisAngle(P.set(1, 0, 0), s.tilt);
      s.sp.position.copy(V3); s.sp.material.color.copy(U.uCol.value); s.sp.material.opacity = s.vis * (0.8 + 0.2 * Math.sin(t * 3 + i));
      s.sp.scale.setScalar((pxSize < 200 ? 0.34 : 0.24) * (0.9 + 0.2 * Math.sin(t * 2.4 + i * 1.7)));
      const f = fils[i]; f.line.visible = s.vis > 0.02; if (!f.line.visible) return;
      P0.copy(V3).normalize().multiplyScalar(0.92);
      C1.copy(P0).multiplyScalar(1.45).add(P.set(0, 0.25 * Math.sin(i + t * 0.5), 0)); C2.copy(V3).multiplyScalar(0.82).add(P.set(0, -0.2, 0));
      const arr = f.geo.attributes.position.array;
      for (let k = 0; k < FS; k++) { const u = k / (FS - 1), a = 1 - u;
        arr[k * 3] = a * a * a * P0.x + 3 * a * a * u * C1.x + 3 * a * u * u * C2.x + u * u * u * V3.x;
        arr[k * 3 + 1] = a * a * a * P0.y + 3 * a * a * u * C1.y + 3 * a * u * u * C2.y + u * u * u * V3.y;
        arr[k * 3 + 2] = a * a * a * P0.z + 3 * a * a * u * C1.z + 3 * a * u * u * C2.z + u * u * u * V3.z; }
      f.geo.attributes.position.needsUpdate = true;
      f.mat.uniforms.c.value.copy(U.uCol.value); f.mat.uniforms.t.value = t * (thinking ? 2.4 : st === "speaking" ? 1 + lvlS * 2 : 1); f.mat.uniforms.a.value = s.vis;
    });
    const pa = dg.attributes.position;
    for (let i = 0; i < ND; i++) { const d = dseed[i]; d.a += dt * d.s * (thinking ? 2 : 0.6); pa.setXYZ(i, Math.cos(d.a) * d.r * 1.15, d.y + Math.sin(t * d.s * 2 + i) * 0.15, Math.sin(d.a) * d.r - 0.3); }
    pa.needsUpdate = true;
  }

  // ── boucle : 60 i/s, 15 i/s pendant une vidéo (body.vplay), pause si l'onglet est caché ou l'hôte invisible
  const stillMo = () => { try { return matchMedia("(prefers-reduced-motion: reduce)").matches || document.body.classList.contains("reduce-motion"); } catch { return false; } };
  let raf = 0, last = performance.now(), lr = 0, dead = false, frames = 0; const t0 = last;
  function loop(now) {
    if (dead) return; raf = requestAnimationFrame(loop);
    if (document.hidden || !host.isConnected || !host.clientWidth) { last = now; return; }
    if (now - lr < 50) return;   // plafond 20 i/s : présence vivante sans saturer le main thread (la fluidité n'est pas perceptible au-delà)
    if (document.body.classList.contains("vplay") && now - lr < 66) return;
    if (stillMo() && now - lr < 500) return;   // prefers-reduced-motion / mode calme : image quasi fixe (rafraîchie 2×/s pour les changements d'état)
    const B = document.body.classList; if (B.contains("perf3") && now - lr < 1000) return; if (B.contains("perf2") && now - lr < 33) return;   // gouverneur : 30 i/s au niveau 2, 1 i/s au niveau 3
    lr = now; const dt = clamp((now - last) / 1000, 0, 0.05); last = Math.max(last, now);   // horodatage rAF parfois antérieur : dt jamais négatif
    try { tick(stillMo() ? 0 : dt, stillMo() ? 0 : (now - t0) / 1000); renderer.render(scene, cam); if (!host.classList.contains("nsg-on")) { const er = renderer.getContext().getError(); if (er) throw new Error("GL " + er); host.classList.add("nsg-on"); layer.classList.add("in"); }
      if (++frames === 8) {   // contrôle de rendu réel : des pixels dessinés au centre ? sinon retour au panda avec le détail GPU (jamais d'avatar vide)
        const gl = renderer.getContext(), cw = gl.drawingBufferWidth, ch = gl.drawingBufferHeight, px = new Uint8Array(4 * 81); let seen = 0;
        for (const [fx, fy] of [[0.5, 0.5], [0.42, 0.5], [0.58, 0.5], [0.5, 0.42], [0.5, 0.58]]) { gl.readPixels(Math.floor(cw * fx) - 4, Math.floor(ch * fy) - 4, 9, 9, gl.RGBA, gl.UNSIGNED_BYTE, px); for (let i = 3; i < px.length; i += 4) if (px[i] > 8) seen++; }
        if (!seen) { let info = ""; try { const dbg = gl.getExtension("WEBGL_debug_renderer_info"); info = " · " + gl.getParameter(gl.VERSION) + " · " + (dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : "?") + " · " + cw + "×" + ch; } catch {} throw new Error("rendu vide (aucun pixel dessiné)" + info); }
      } } catch (e) { fail(e, "rendu"); }
  }
  tick(0.016, 0); renderer.render(scene, cam); raf = requestAnimationFrame(loop);

  inst = {
    renderer,
    destroy() {
      if (dead) return; dead = true; cancelAnimationFrame(raf);
      ro.disconnect(); mo.disconnect(); removeEventListener("pointermove", onMove);
      ctx && ctx.A && ctx.A.removeEventListener && ctx.A.removeEventListener("level", onLevel);
      if (av && origSetLevel) av.setLevel = origSetLevel;
      const seen = new Set();
      scene.traverse((o) => { if (o.geometry && !seen.has(o.geometry)) { seen.add(o.geometry); o.geometry.dispose(); }
        const ms = o.material ? (Array.isArray(o.material) ? o.material : [o.material]) : [];
        for (const m of ms) { if (seen.has(m)) continue; seen.add(m); if (m.map) m.map.dispose(); m.dispose(); } });
      haloTex.dispose(); dotTex.dispose(); envRT.dispose(); scene.environment = null;
      renderer.dispose(); try { renderer.forceContextLoss(); } catch {}
      host.classList.remove("nsg-on"); layer.remove();
    },
  };
  return inst;
}
