// mascot.js — Compagnons 3D studio-grade pour Nova 2 (Panda géant & Panda roux).
// Architecture : maillages lisses déformés dans le nuanceur de sommets (V5-F) — unions lisses
// analytiques entre parties (cou, épaules, hanches, oreilles, museau, queue), respiration locale
// poitrine/ventre, joues qui suivent le sourire, oreilles à inertie secondaire, queue en tube
// continu, coquille de fourrure en bordure de silhouette — + yeux wet-cornea haute fidélité +
// accessoires 3D (casque, portable, lunettes, bulles, étincelles, « z ») + repli SVG si WebGL2 absent.
// Contrat : createAvatar(host, { species, preserve }) → { setState, setMood, setLevel, setViseme,
// setVisemeSource, lookAt, setFocus, react, setTheme, state, species, snapshot, destroy }.

import * as THREE from "../vendor/three.module.js";

const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const rnd = (a, b) => a + Math.random() * (b - a);
// 31/10 (Ahadi : « le panda bouge seul ») : au repos, plus de gestes spontanés (salut, saut, tortillement, bâillement,
// regards et inclinaisons au hasard) — clignements et réactions aux états gardés. Réactiver : localStorage nova2_mascotte_vivante = "1".
const MASCOT_LIVELY = (() => { try { return localStorage.getItem("nova2_mascotte_vivante") === "1"; } catch (e) { return false; } })();
const expo = (mean) => -Math.log(1 - Math.random()) * mean;

// Bruit 1D lisse non périodique (table fixe de 512 valeurs)
const n1 = (() => {
  const P = new Float32Array(512);
  for (let i = 0; i < 512; i++) P[i] = Math.sin(i * 127.1 + 311.7) * 43758.5453 % 1 * 2 - 1;
  return (t) => {
    const i = Math.floor(t), f = t - i, u = f * f * (3 - 2 * f);
    return lerp(P[i & 511], P[(i + 1) & 511], u);
  };
})();

/* ---------- 1. Ressorts amortis critiques ---------- */
class Spring {
  constructor(v, w, z = 1) {
    this.x = v;
    this.v = 0;
    this.t = v;
    this.w = w;
    this.z = z;
  }
  step(dt) {
    const a = this.w * this.w * (this.t - this.x) - 2 * this.z * this.w * this.v;
    this.v += a * dt;
    this.x += this.v * dt;
  }
}

const REST_L = [-0.23, 0.25, 0.17];
const REST_R = [0.23, 0.25, 0.17];

const CH = {
  bRoll: [0, 6.5, 0.85], bPitch: [0, 6.5, 0.88], bYaw: [0, 5.5, 0.9],
  hYaw: [0, 8.5, 0.85], hPitch: [0, 8.5, 0.85], hRoll: [0, 7.0, 0.68],
  grow: [1, 8.5, 0.48], sq: [0, 15.0, 0.35], fh: [0.08, 3.0, 1.0],
  gx: [0, 34, 1.0], gy: [0, 34, 1.0],
  lidT: [0, 26, 1.0], lidB: [0, 15, 1.0], lidTilt: [0, 12, 0.95], iris: [1, 10, 0.85],
  browL: [0, 12, 0.9], browR: [0, 12, 0.9],
  // V4-B : la bouche n'est plus un seul « mOpen » mais 4 canaux articulés (visèmes façon Muse)
  //   jaw    = ouverture verticale (A)        spread = étirement horizontal (I / É)
  //   round  = arrondi projeté (O / OU)       press  = fermeture bilabiale (M / B / P)
  smile: [0.45, 10, 0.9], jaw: [0, 26, 0.88], spread: [0, 18, 0.9], round: [0, 18, 0.9], press: [0, 34, 1.0],
  cheek: [0, 9, 0.9], wink: [0, 24, 1.0],
  earL: [0, 16, 0.3], earR: [0, 16, 0.3], perk: [0, 9, 0.58],
  hLx: [REST_L[0], 9.5, 0.8], hLy: [REST_L[1], 9.5, 0.8], hLz: [REST_L[2], 9.5, 0.8],
  hRx: [REST_R[0], 9.5, 0.8], hRy: [REST_R[1], 9.5, 0.8], hRz: [REST_R[2], 9.5, 0.8],
  fist: [0, 11, 0.9], wx: [0, 2.2, 1.0],
  phones: [0, 13, 0.52], laptop: [0, 12, 0.58], orbs: [0, 8, 0.9], glasses: [0, 10, 0.62],
  spark: [0, 7, 0.9], zzz: [0, 3.5, 1.0], glow: [0, 7, 1.0],
  tail: [0, 5.5, 0.35], happy: [0, 26, 1.0], legs: [0, 7.5, 0.55],
  // V5-F : retard de la tête sur le corps (le cou s'étire / se tasse au rebond, follow-through)
  nk: [0, 11, 0.42],
};
// Canaux de pose amortis selon la personnalité (zeta propre à l'espèce)
const POSE_KEYS = ["bRoll", "bPitch", "bYaw", "hYaw", "hPitch", "hRoll", "hLx", "hLy", "hLz", "hRx", "hRy", "hRz"];
// Personnalités : panda géant calme et amorti, panda roux vif, curieux, micro-vie ×1,35
const SPECIES = {
  panda: { zeta: 0.85, wMul: 1.0, life: 1.0, breath: 0.22 },
  red: { zeta: 0.65, wMul: 1.16, life: 1.35, breath: 0.27 },
};

/* 14 états & mimiques (11 états de pose + mimiques ponctuelles validate / nod / wave / arrival /
   whip / surprise). Les états rapides (respiration, saccades, frappe, balayage…) sont animés
   dans update() ; ces tables ne fixent que les poses cibles. */
const STATES = {
  idle: {},
  listening: {
    // Écoute active : casque, buste penché de ~4° vers Ahadi, oreilles dressées
    phones: 1, bPitch: 0.07, hRoll: 0.12, hPitch: -0.02, perk: 0.88, iris: 1.08, smile: 0.62,
    browL: 0.25, browR: 0.25,
    hLx: -0.22, hLy: 0.26, hLz: 0.19, hRx: 0.27, hRy: 0.58, hRz: 0.14,
  },
  thinking: {
    // Patte droite sous le menton, gauche croisée sous le coude, sourcils asymétriques
    orbs: 1, hYaw: 0.10, hPitch: -0.10, hRoll: -0.10, gy: 0.62,
    lidT: 0.08, lidTilt: -0.10, browL: -0.42, browR: 0.78, smile: 0.25, spread: -0.25,
    hRx: 0.03, hRy: 0.47, hRz: 0.30, hLx: 0.10, hLy: 0.33, hLz: 0.25,
  },
  tool: {
    laptop: 1, glow: 1, hPitch: 0.20, bPitch: 0.05, gy: -0.72, gx: 0.04,
    lidT: 0.14, browL: -0.15, browR: -0.15, smile: 0.5,
    hLx: -0.09, hLy: 0.25, hLz: 0.32, hRx: 0.09, hRy: 0.25, hRz: 0.32,
  },
  speaking: {
    smile: 0.62, iris: 1.04, browL: 0.22, browR: 0.22,
    hLx: -0.25, hLy: 0.30, hLz: 0.22, hRx: 0.25, hRy: 0.30, hRz: 0.22,
  },
  approval: {
    // Attend ton GO : se tourne vers la carte (bYaw posé dans update), patte levée paume ouverte,
    // sourcils en arc interrogatif bienveillant
    hRoll: 0.10, hPitch: -0.06, lidTilt: -0.14, iris: 1.14, smile: 0.66, perk: 0.55,
    browL: 0.62, browR: 0.62,
    hRx: 0.34, hRy: 0.61, hRz: 0.17, hLx: -0.20, hLy: 0.28, hLz: 0.21,
  },
  done: {
    // Célébration standard : rebond squash & stretch, poings levés
    grow: 1.08, hPitch: -0.11, happy: 1, smile: 1.0, jaw: 0.46, spread: 0.32,
    perk: 1.0, legs: 0.78, browL: 0.6, browR: 0.6, fist: 0.85,
    hLx: -0.45, hLy: 0.56, hLz: 0.16, hRx: 0.45, hRy: 0.56, hRz: 0.16,
  },
  celebrate: {
    // Célébration majeure : saut + pirouette + étoiles dorées, agrandissement ×1,12
    grow: 1.12, hPitch: -0.13, happy: 1, smile: 1.1, jaw: 0.6, spread: 0.36,
    perk: 1.0, spark: 1, legs: 0.9, browL: 0.7, browR: 0.7,
    hLx: -0.47, hLy: 0.60, hLz: 0.14, hRx: 0.47, hRy: 0.60, hRz: 0.14,
  },
  error: {
    // Détermination concentrée — jamais abattu : buste redressé, poings devant le torse,
    // sourcils en V, bouche ferme (pas triste)
    bPitch: -0.05, hPitch: -0.03, lidTilt: 0.62, lidT: 0.04, smile: 0.12, press: 0.55,
    iris: 1.0, perk: 0.55, browL: -0.55, browR: -0.55, fist: 1,
    hLx: -0.07, hLy: 0.40, hLz: 0.30, hRx: 0.07, hRy: 0.40, hRz: 0.30,
  },
  reading: {
    // Lecture : lunettes rondes dorées, tête légèrement penchée, regard qui suit le défilement
    glasses: 1, hPitch: 0.10, hRoll: 0.04, gy: -0.25, smile: 0.5, lidT: 0.06, browL: 0.12, browR: 0.12,
    hLx: -0.15, hLy: 0.30, hLz: 0.30, hRx: 0.15, hRy: 0.30, hRz: 0.30,
  },
  sleep: {
    hPitch: 0.22, hRoll: 0.15, lidT: 1.0, smile: 0.48, zzz: 1, fh: 0.04, perk: -0.55,
    hLx: -0.16, hLy: 0.23, hLz: 0.22, hRx: 0.16, hRy: 0.23, hRz: 0.22,
  },
};

const MOODS = {
  joie: { d: { smile: 0.3, lidB: 0.12, perk: 0.38, iris: 0.05, browL: 0.2, browR: 0.2 }, life: 1.25, key: [1.05, 0.99, 0.92] },
  attention: { d: { smile: -0.2, iris: 0.04, lidT: -0.02, perk: 0.32, browL: -0.15, browR: -0.15 }, life: 0.65, key: [1.0, 0.98, 0.96] },
  grave: { d: { smile: -0.28, lidT: 0.12, perk: -0.25, browL: -0.2, browR: -0.2 }, life: 0.5, key: [0.95, 0.97, 1.02] },
  legere: { d: { smile: 0.2, perk: 0.18, browR: 0.18 }, life: 1.35, key: [1.04, 0.99, 0.93] },
  neutre: { d: {}, life: 1.0, key: [1.03, 0.99, 0.95] },
};

/* ---------- 2. Shaders GLSL (Corps organique & Yeux studio) ---------- */
const MAXM = 12;

// V5-F : déformation organique dans le nuanceur de sommets. Chaque partie du corps (tête, corps,
// bras, pattes, jambes, oreilles, museau, queue) est aussi décrite comme une primitive analytique
// (ellipsoïde-capsule) en espace monde ; chaque sommet est gonflé par une UNION LISSE (smin
// polynomial) vers ses voisines → congés continus au cou, aux épaules, aux hanches, à la queue,
// recalculés à chaque image (la tête tourne, le bras se lève : le pli suit, sans cassure).
// Normales fusionnées selon le gradient de l'union → aucune arête d'ombrage à la jonction.
// Modes locaux : 1 = respiration (poitrine puis ventre gonflent), 2 = joues qui suivent le
// sourire, 3 = oreille souple (pointe en retard, inertie secondaire). uShell = coquille de fourrure.
const NP = 12;
const VS = `
varying vec3 vL;
varying vec3 vN;
varying vec3 vV;
varying vec3 vW;
varying vec2 vUv;
varying float vCrease;
#ifdef DEFORM
uniform mat4 uPM[${NP}];
uniform vec4 uPR[${NP}];
uniform float uPK[${NP}];
uniform float uMode;
uniform vec4 uDefA;
uniform float uShell;
float primD(int j, vec3 p, out vec3 g) {
  vec3 q = (uPM[j] * vec4(p, 1.0)).xyz;
  vec4 r = uPR[j];
  q.y -= clamp(q.y, -r.w, r.w);
  vec3 r2 = r.xyz * r.xyz;
  float k0 = length(q / r.xyz);
  float k1 = length(q / r2);
  g = normalize(transpose(mat3(uPM[j])) * (q / r2) + vec3(0.0, 1e-6, 0.0));
  return k0 * (k0 - 1.0) / max(k1, 1e-5);
}
#endif
void main() {
  vL = position;
  vUv = uv;
  vCrease = 0.0;
  vec4 wp = modelMatrix * vec4(position, 1.0);
  vec3 nV = normalize(normalMatrix * normal);
#ifdef DEFORM
  vec3 p = wp.xyz;
  vec3 n = normalize((vec4(nV, 0.0) * viewMatrix).xyz);
  vec3 d = normalize(position);
  if (uMode > 0.5 && uMode < 1.5) {
    // Respiration : la poitrine se soulève d'abord, le ventre suit (déphasage), les flancs s'élargissent
    float chestW = smoothstep(-0.25, 0.6, d.z) * exp(-pow(d.y - 0.32, 2.0) / 0.14);
    float bellyW = smoothstep(-0.45, 0.5, d.z) * exp(-pow(d.y + 0.28, 2.0) / 0.20);
    float flankW = (1.0 - abs(d.z)) * exp(-pow(d.y + 0.05, 2.0) / 0.3) * 0.5;
    p += n * (uDefA.x * chestW + uDefA.y * (bellyW + flankW));
    p.y += uDefA.x * 0.6 * smoothstep(0.35, 0.95, d.y);
  } else if (uMode > 1.5 && uMode < 2.5) {
    // Joues : se gonflent et remontent avec le sourire (pommettes de Duchenne)
    for (int s = 0; s < 2; s++) {
      vec3 c = normalize(vec3(s == 0 ? -0.64 : 0.64, -0.36, 0.68));
      float w = exp(-(1.0 - dot(d, c)) * 26.0);
      p += n * (uDefA.x * w) + vec3(0.0, uDefA.y * w, 0.0);
    }
  } else if (uMode > 2.5) {
    // Oreille : la pointe traîne derrière la base (décalage monde calculé par un ressort)
    float w = smoothstep(-0.8, 1.0, position.y);
    p += uDefA.xyz * (w * w);
  }
  vec3 disp = vec3(0.0);
  vec3 nAcc = n;
  for (int j = 0; j < ${NP}; j++) {
    float k = uPK[j];
    if (k <= 0.0) continue;
    vec3 g;
    float dj = primD(j, p, g);
    if (dj > k) continue;
    float h = clamp(0.5 + 0.5 * dj / k, 0.0, 1.0);
    float amt = k * h * (1.0 - h) - (1.0 - h) * max(dj, 0.0);
    disp += normalize(mix(g, n, h)) * max(amt, 0.0);
    nAcc += g * (1.0 - h) / max(h, 0.3);
    vCrease = max(vCrease, 4.0 * h * (1.0 - h));
  }
  p += disp;
  n = normalize(nAcc);
  p += n * uShell;
  wp = vec4(p, 1.0);
  nV = normalize(mat3(viewMatrix) * n);
#endif
  vW = wp.xyz;
  vec4 mv = viewMatrix * wp;
  vV = -mv.xyz;
  vN = nV;
  gl_Position = projectionMatrix * mv;
}`;

const SHADE = `
uniform vec3 uKey, uRim, uGlowC;
uniform float uGlow, uLW, uTime;
uniform vec2 uScan;

float hash31(vec3 p) {
  p = fract(p * 0.3183099 + 0.1);
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float vnoise(vec3 x) {
  vec3 i = floor(x), f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(hash31(i), hash31(i + vec3(1,0,0)), f.x), mix(hash31(i + vec3(0,1,0)), hash31(i + vec3(1,1,0)), f.x), f.y),
    mix(mix(hash31(i + vec3(0,0,1)), hash31(i + vec3(1,0,1)), f.x), mix(hash31(i + vec3(0,1,1)), hash31(i + vec3(1,1,1)), f.x), f.y),
    f.z
  );
}

vec3 shade(vec3 alb, vec3 N, vec3 V, vec3 posL, float sss, float spec, float shin, float furAmt) {
  // Micro-relief de fourrure doux avec atténuation LOD automatique (aucun bruit sale)
  float px = length(fwidth(posL));
  float lod = 1.0 - smoothstep(0.015, 0.055, px);
  vec3 flow = normalize(vec3(0.0, -1.0, 0.15) - N * dot(vec3(0.0, -1.0, 0.15), N) + 1e-4);
  vec3 bt = cross(N, flow);
  float strand = vnoise(vec3(dot(posL, bt) * 42.0, dot(posL, flow) * 14.0, dot(posL, N) * 14.0));
  vec3 Nf = normalize(N + bt * (strand - 0.5) * 0.11 * furAmt * lod);

  vec3 L = normalize(vec3(-0.48, 0.74, 0.65));
  float ndl = dot(Nf, L);
  float h = ndl * 0.5 + 0.5;
  float diff = mix(h * h, smoothstep(-0.15, 0.95, ndl), 0.25);

  // Studio hémisphérique chaud et lumineux (aucun gris sale sur les blancs)
  vec3 amb = mix(vec3(0.84, 0.81, 0.92), vec3(1.0, 0.99, 0.97), Nf.y * 0.5 + 0.5);
  float fill = max(dot(Nf, normalize(vec3(0.82, 0.12, 0.55))), 0.0);
  vec3 col = alb * (uKey * diff * 0.90 + amb * 0.54 + vec3(0.94, 0.96, 1.0) * fill * 0.16);

  // Diffusion sous-cutanée chaude sur le pelage clair
  float sssBand = smoothstep(-0.5, 0.15, ndl) * (1.0 - smoothstep(0.15, 0.65, ndl));
  col += alb * vec3(1.0, 0.54, 0.42) * sss * (0.11 + 0.32 * sssBand);

  // Double reflet anisotrope Kajiya-Kay le long du pelage + velours de silhouette
  vec3 H = normalize(L + V);
  float th1 = dot(normalize(flow + Nf * 0.18), H);
  float kk = pow(sqrt(max(1.0 - th1 * th1, 0.0)), 42.0) * 0.08 * furAmt;
  col += uKey * kk * (0.75 + 0.25 * strand);

  float nv = max(dot(Nf, V), 0.0);
  float fr = pow(1.0 - nv, 2.5);
  col += alb * fr * (0.28 + 0.10 * furAmt);
  col += uRim * fr * 0.30 * (0.52 + 0.48 * smoothstep(-0.35, 0.65, Nf.y + Nf.x * 0.28));

  // Spéculaire franc (truffe cuir, casque, portable)
  col += uKey * spec * pow(max(dot(Nf, H), 0.0), shin);

  // Lueur d'écran de l'ordinateur portable sur le visage et le torse
  col += alb * uGlowC * uGlow * 0.58 * max(dot(Nf, normalize(vec3(0.12, -0.52, 1.0))), 0.0);
  return col;
}

vec3 softClip(vec3 c) {
  vec3 k = 0.84 + 0.16 * (1.0 - exp(-(c - 0.84) / 0.16));
  return mix(c, k, step(0.84, c));
}
`;

const MARKS = `
uniform vec4 uMC[${MAXM}], uMR[${MAXM}], uMK[${MAXM}];
vec3 applyMarks(vec3 alb, vec3 d) {
  for (int i = 0; i < ${MAXM}; i++) {
    if (uMK[i].a <= 0.0) continue;
    vec3 c = normalize(uMC[i].xyz);
    float cd = dot(d, c);
    if (cd <= 0.0) continue;
    vec3 up = abs(c.y) > 0.95 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 t = normalize(cross(up, c)), b = cross(c, t);
    vec2 q = vec2(dot(d, t), dot(d, b));
    float s = sin(uMC[i].w), co = cos(uMC[i].w);
    q = mat2(co, s, -s, co) * q;
    float rx = uMR[i].x * max(0.25, 1.0 + uMR[i].z * q.y / uMR[i].y);
    float e = length(vec2(q.x / rx, q.y / uMR[i].y));
    float aa = fwidth(e) * 1.25;
    float m = 1.0 - smoothstep(1.0 - uMR[i].w - aa, 1.0 + aa, e);
    m *= smoothstep(0.0, 0.2, cd);
    alb = mix(alb, uMK[i].rgb, m * uMK[i].a);
  }
  return alb;
}`;

const FS_SURF = `
uniform vec3 uBase;
uniform float uSpec, uShin, uSSS, uEmit, uFur;
uniform vec2 uAO;
#ifdef MOUTH
uniform vec4 uMouth;   // x = jaw, y = smile, z = spread, w = round
uniform vec4 uMouth2;  // x = press
uniform vec3 uLineC, uMouthC, uTongueC;
#endif
#if defined(TAIL) || defined(FADE)
uniform vec3 uBase2;
#endif
#ifdef SHELL
uniform float uLayer, uFiberF;
#endif
varying vec3 vL;
varying vec3 vN;
varying vec3 vV;
varying vec3 vW;
varying vec2 vUv;
varying float vCrease;
${SHADE}
${MARKS}
void main() {
#ifdef SHELL
  // Coquille : on ne paie l'ombrage qu'en bordure de silhouette (le reste est rejeté tout de suite)
  float shEdge = smoothstep(0.35, 0.92, 1.0 - abs(dot(normalize(vN), normalize(vV))));
  if (shEdge < 0.02) discard;
#endif
  vec3 d = normalize(vL);
  vec3 alb = applyMarks(uBase, d);
  float furAmt = uFur;
#ifdef TAIL
  // Queue touffue continue : anneaux doux (pas de perles), pointe plus sombre
  float tt = vUv.x;
  float band = smoothstep(0.05, 0.75, sin(tt * 6.2831 * 3.6 - 1.4));
  alb = mix(uBase, uBase2, band * (1.0 - smoothstep(0.84, 0.96, tt)));
  alb = mix(alb, uBase * 0.70, smoothstep(0.88, 1.0, tt));
#endif
#ifdef FADE
  // Bras du panda roux : le brun des membres se fond progressivement dans le roux de l'épaule
  alb = mix(alb, uBase2, smoothstep(0.0, 0.13, vL.y));
#endif
#ifdef MOUTH
  {
    // Bouche articulée à 4 canaux : chaque visème a une silhouette propre et lisible
    vec2 q = d.xy;
    float jaw = clamp(uMouth.x, 0.0, 1.0), sm = uMouth.y, sp = clamp(uMouth.z, -0.6, 1.0), rd = clamp(uMouth.w, 0.0, 1.0);
    float pr = clamp(uMouth2.x, 0.0, 1.0), spP = max(sp, 0.0);
    float aa = fwidth(q.y) * 1.35 + 1e-4;
    float lw = 0.050 * uLW * (1.0 + 0.7 * pr);
    float y0 = 0.065, ax = abs(q.x);
    // Largeur des lobes : I/É étire, O/OU resserre (coins tirés vers le centre)
    float m = (0.20 + 0.05 * sp) * (1.0 - 0.30 * rd);
    // Profondeur du sourire en « ω » : M/B/P l'aplatit, l'arrondi l'atténue
    float dd = 0.115 * sm * (1.0 - 0.8 * pr) * (1.0 - 0.55 * rd);
    float u = (ax - m) / m, f = y0 - dd * (1.0 - u * u);
    float lineW = (1.0 - smoothstep(lw - aa, lw + aa, abs(q.y - f))) * (1.0 - smoothstep(2.0 * m - 0.02, 2.0 * m + 0.03, ax));
    float phil = (1.0 - smoothstep(lw * 0.85 - aa, lw * 0.85 + aa, abs(q.x))) * step(y0 - 0.01, q.y) * (1.0 - smoothstep(0.36, 0.40, q.y));
    // Ouverture : la mâchoire ouvre ; l'arrondi entrouvre en « O » même mâchoire basse ; M/B/P ferme tout
    float op = max(jaw, rd * 0.42) * (1.0 - pr);
    float rx = m * (1.36 + 0.42 * spP) * (1.0 - 0.18 * rd);
    float ry = (0.06 + 0.62 * op) * (1.0 - 0.30 * spP);
    float cy = y0 - dd * 0.6 - ry * rd * 0.92;
    vec2 e = vec2(q.x / rx, (q.y - cy) / ry);
    float el = length(e);
    float topClip = mix(f, cy + ry + 0.2, rd);
    float inside = (1.0 - smoothstep(1.0 - aa * 6.0, 1.0 + aa * 6.0, el)) * (1.0 - smoothstep(topClip - aa, topClip + aa, q.y)) * smoothstep(0.02, 0.07, op);
    // Langue au fond, dents supérieures visibles sur I/É
    float tg = 1.0 - smoothstep(0.0, aa * 2.0 + 0.02, length((q - vec2(0.0, cy - ry + 0.055)) / vec2(rx * 0.64, ry * 0.46 + 0.02)) - 1.0);
    vec3 mc = mix(uMouthC, uTongueC, tg * 0.95 * (1.0 - 0.6 * spP));
    float teeth = inside * (1.0 - smoothstep(0.0, aa * 2.0, (f - 0.012 - 0.03 * spP) - q.y)) * smoothstep(0.15, 0.45, spP) * (1.0 - rd);
    mc = mix(mc, vec3(0.97, 0.96, 0.95), teeth);
    alb = mix(alb, mc, inside);
    // Lèvres projetées en « O » : anneau de lèvre autour de l'ouverture
    float ring = rd * smoothstep(0.05, 0.2, op) * (1.0 - smoothstep(1.0, 1.0 + 0.22 + aa * 6.0, el)) * smoothstep(1.0 - aa * 6.0, 1.0 + aa * 6.0, el);
    alb = mix(alb, mix(uLineC, uMouthC, 0.35), ring * 0.9);
    // M/B/P : lèvres pincées — trait épaissi + fossettes aux commissures
    float dim = pr * (1.0 - smoothstep(0.018, 0.03 + aa * 2.0, length(vec2(ax - 2.0 * m - 0.01, q.y - f))));
    float groove = max(max(lineW, phil * (1.0 - inside)), dim);
    alb = mix(alb, uLineC, groove);
    furAmt *= (1.0 - max(max(inside, ring), groove));
    // Reflet d'écran (état tool) qui balaie le museau
    float sc = exp(-pow(q.x * 0.9 + q.y * 0.35 - uScan.x, 2.0) / 0.012) * uScan.y;
    alb += uGlowC * sc * 0.16;
  }
#endif
  vec3 N = normalize(vN), V = normalize(vV);
#ifdef SHELL
  {
    // Ombrage allégé pour la coquille (même lumière clé + liseré chaud, sans 2e passe de fibres)
    vec3 Ls = normalize(vec3(-0.48, 0.74, 0.65));
    float hs = dot(N, Ls) * 0.5 + 0.5;
    vec3 ambS = mix(vec3(0.84, 0.81, 0.92), vec3(1.0, 0.99, 0.97), N.y * 0.5 + 0.5);
    vec3 cs = alb * (uKey * hs * hs * 0.9 + ambS * 0.56) + alb * vec3(1.0, 0.54, 0.42) * uSSS * 0.12;
    float frs = pow(1.0 - abs(dot(N, V)), 2.5);
    cs += alb * frs * 0.32 + uRim * frs * 0.30;
    float fib = vnoise(vec3(vL.x * uFiberF, vL.y * uFiberF * 0.45, vL.z * uFiberF));
    fib = 0.6 * fib + 0.4 * vnoise(vL * uFiberF * 2.1 + 7.0);
    float a = shEdge * smoothstep(uLayer - 0.08, uLayer + 0.32, fib) * (1.0 - smoothstep(0.0, 0.35, vCrease));
    gl_FragColor = vec4(softClip(cs), a * 0.8);
    #include <colorspace_fragment>
    return;
  }
#endif
  float ao = 1.0 - uAO.x * (1.0 - smoothstep(-0.95, -0.28, d.y)) - uAO.y * smoothstep(0.42, 0.95, d.y);
  // Pli de jonction : occlusion très légère et chaude (jamais de trait sombre)
  ao *= 1.0 - 0.07 * vCrease;
  vec3 col = shade(alb, N, V, vL, uSSS, uSpec, uShin, furAmt) * ao + uBase * uEmit;
  col += alb * vec3(1.0, 0.62, 0.48) * uSSS * 0.10 * vCrease;
  gl_FragColor = vec4(softClip(col), 1.0);
  #include <colorspace_fragment>
}`;

const FS_EYE = `
uniform vec2 uGaze;
uniform float uTop, uBot, uTilt, uSide, uIris, uHappy;
uniform vec3 uLidC, uLashC, uCloseC, uIrisC, uScl;
varying vec3 vL;
varying vec3 vN;
varying vec3 vV;
${SHADE}
void main() {
  vec2 q = vL.xy;
  float x = q.x * uSide;
  float aa = fwidth(q.y) * 1.35 + 1e-4;
  float open1 = 1.0 - uTop;
  float yc = -0.22 + 0.30 * x * x;
  float tY = mix(1.15, yc, uTop) - max(uTilt, 0.0) * 0.95 * (x * 0.5 + 0.5) * open1 - max(-uTilt, 0.0) * 0.55 * (0.5 - x * 0.5) * open1;
  float bY = max(mix(-1.15, 0.18 - 0.42 * x * x, uBot), mix(-1.15, yc, smoothstep(0.55, 1.0, uTop)));
  float open = smoothstep(-aa, aa, tY - q.y) * smoothstep(-aa, aa, q.y - bY);
  float gap = tY - bY;
  float lw = 0.11 * uLW;
  float closeL = (1.0 - smoothstep(0.02, 0.22, gap)) * (1.0 - smoothstep(lw - aa, lw + aa, abs(q.y - (tY + bY) * 0.5))) * (1.0 - smoothstep(0.80, 0.92, abs(q.x)));

  vec3 N = normalize(vN), V = normalize(vV);
  vec3 lid = shade(uLidC, N, V, vL, 0.22, 0.12, 20.0, 0.4);

  // Globe oculaire : parallaxe cornéenne, fibres d'iris, anneau limbique, 2 reflets spéculaires nets
  vec2 c = uGaze * vec2(0.22, 0.18);
  vec2 pIris = q - c + V.xy * 0.045;
  float r = length(pIris), ir = 0.85 * uIris;
  vec3 scl = uScl * (1.0 - 0.13 * smoothstep(0.58, 1.0, length(q)));
  float t = clamp((c.y - q.y) / ir * 0.58 + 0.5, 0.0, 1.0);
  float ang = atan(pIris.y, pIris.x);
  float fibers = 0.92 + 0.16 * sin(ang * 18.0 + r * 12.0);
  vec3 irc = mix(vec3(0.015, 0.010, 0.018), uIrisC * fibers, t * t * 0.96);
  // Collarette dorée chaude autour de la pupille
  irc += uIrisC * vec3(1.3, 0.95, 0.65) * 0.42 * smoothstep(ir * 0.50, ir * 0.96, r) * t;
  // Pupille profonde au centre + anneau limbique doux au bord
  irc *= mix(0.22, 1.0, smoothstep(ir * 0.38, ir * 0.54, r));
  irc *= 1.0 - 0.35 * smoothstep(ir * 0.82, ir, r);

  float inI = 1.0 - smoothstep(ir - aa * 1.5, ir + aa * 1.5, r);
  vec3 ball = mix(scl, irc, inI);
  // Ombre douce portée par la paupière supérieure
  ball *= 1.0 - 0.20 * smoothstep(tY - 0.28, tY, q.y) * smoothstep(0.0, 0.5, uTop + uTilt * uTilt);

  // Deux reflets spéculaires (un grand principal en haut à gauche, un petit secondaire en bas à droite)
  vec2 o = c * 0.35;
  float h1 = 1.0 - smoothstep(1.0 - aa * 5.0, 1.0 + aa * 5.0, length((q - vec2(-0.27, 0.31) - o) / vec2(0.27, 0.24) * uIris));
  float h2 = 1.0 - smoothstep(1.0 - aa * 9.0, 1.0 + aa * 9.0, length((q - vec2(0.30, -0.35) - o) / vec2(0.118, 0.105) * uIris));
  ball += vec3(0.075) * smoothstep(0.18, 1.0, q.y);
  ball = mix(ball, vec3(1.0), h1);
  ball = mix(ball, vec3(1.0), h2 * 0.94);

  // Ligne de cils implicite au bord de la paupière supérieure
  float dl = tY - q.y;
  ball = mix(ball, uLashC, (1.0 - smoothstep(lw * 0.56, lw * 0.56 + aa * 2.0, dl)) * step(0.0, dl) * smoothstep(0.0, 0.25, gap));

  // Reflet bleuté / ambré de l'écran du portable qui balaie la cornée (état tool)
  float scb = exp(-pow(q.x * 0.8 + q.y * 0.3 - uScan.x * 1.6, 2.0) / 0.03) * uScan.y;
  ball = mix(ball, uGlowC * 0.85 + vec3(0.15), clamp(scb * 0.55, 0.0, 0.7));

  vec3 col = mix(lid, ball, open);
  col = mix(col, uCloseC, closeL);
  // Arc joyeux quand happy > 0.5 (célébration / validation)
  float ya = 0.12 - 0.62 * x * x - 0.1 * x;
  float arc = (1.0 - smoothstep(lw * 1.1 - aa, lw * 1.1 + aa, abs(q.y - ya))) * (1.0 - smoothstep(0.78, 0.9, abs(q.x)));
  col = mix(col, mix(lid, uCloseC, arc), smoothstep(0.45, 0.55, uHappy));

  gl_FragColor = vec4(softClip(col), 1.0);
  #include <colorspace_fragment>
}`;

/* ---------- 3. Palettes & marquages des 2 espèces ---------- */
const col = (h) => new THREE.Color(h);
const PAL = {
  panda: {
    fur: "#fcf9f4", dark: "#322d39", muzzle: "#fffcf8", line: "#28232e", nose: "#24202a",
    iris: "#7e4e35", scl: "#faf9fe", lid: "#322d39", lash: "#141118", close: "#f5f0f7",
    tongue: "#ff8ea0", mouthIn: "#5b2131", blush: "#ff9bb0", ear: "#322d39",
    arm: "#322d39", leg: "#322d39", body: "#fcf9f4", pad: "#5c4952", earIn: "#4a4254",
  },
  red: {
    fur: "#e26d35", dark: "#3b2521", muzzle: "#fff4e6", line: "#39211c", nose: "#2b1b19",
    iris: "#8c4b20", scl: "#fcf8f3", lid: "#e26d35", lash: "#281612", close: "#39211c",
    tongue: "#ff8ea0", mouthIn: "#5b2131", blush: "#ff8e9e", ear: "#3b2521",
    arm: "#3b2521", leg: "#3b2521", body: "#da642d", pad: "#63423c", earIn: "#fff7ef",
    cream: "#fff2e0", tear: "#a13d19", ringA: "#d45926", ringB: "#f2b57e",
  },
};

const sym = (m) => [
  { ...m, d: [-m.d[0], m.d[1], m.d[2]], tilt: m.tilt || 0 },
  { ...m, d: [m.d[0], m.d[1], m.d[2]], tilt: -(m.tilt || 0) },
];

function headMarks(red, P) {
  if (!red) {
    // Panda géant : taches oculaires en gouttes inclinées douces + petites joues roses + lueur de sourcil
    return [
      ...sym({ d: [0.43, -0.23, 0.88], tilt: 0.58, a: 0.385, b: 0.53, taper: -0.30, soft: 0.08, c: P.dark }),   // 24/10 : taches oculaires plus franches (signature du panda)
      ...sym({ d: [0.59, -0.40, 0.70], a: 0.15, b: 0.095, soft: 0.92, c: P.blush, s: 0.64 }),
      ...sym({ d: [0.32, 0.24, 0.91], tilt: -0.18, a: 0.11, b: 0.045, soft: 0.65, c: "#ffffff", s: 0.35 }),
    ];
  }
  // Panda roux : masque crème, taches sourcilières blanches, larmes rousses sous les yeux, joues roses
  return [
    { d: [0, -0.56, 0.83], a: 0.65, b: 0.39, taper: 0.25, soft: 0.28, c: P.cream },
    ...sym({ d: [0.73, -0.27, 0.61], a: 0.23, b: 0.18, soft: 0.35, c: P.cream }),
    ...sym({ d: [0.30, 0.26, 0.92], tilt: -0.15, a: 0.105, b: 0.072, soft: 0.32, c: P.cream }),
    ...sym({ d: [0.25, -0.39, 0.88], tilt: -0.32, a: 0.052, b: 0.175, soft: 0.42, c: P.tear, s: 0.78 }),
    ...sym({ d: [0.58, -0.40, 0.70], a: 0.145, b: 0.092, soft: 0.92, c: P.blush, s: 0.58 }),
  ];
}

/* ---------- 4. Textures procédurales sur Canvas (aucune image externe) ---------- */
function makeCanvasTex(sz, drawFn) {
  const c = document.createElement("canvas");
  c.width = c.height = sz;
  const g = c.getContext("2d");
  drawFn(g, sz);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

function createInstanceTextures() {
  return {
    shadow: makeCanvasTex(128, (g, s) => {
      const r = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
      r.addColorStop(0, "rgba(18, 18, 38, 0.52)");
      r.addColorStop(0.48, "rgba(18, 18, 38, 0.24)");
      r.addColorStop(1, "rgba(18, 18, 38, 0)");
      g.fillStyle = r;
      g.fillRect(0, 0, s, s);
    }),
    glow: makeCanvasTex(128, (g, s) => {
      const r = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
      r.addColorStop(0, "rgba(255, 255, 255, 0.88)");
      r.addColorStop(0.38, "rgba(255, 255, 255, 0.32)");
      r.addColorStop(1, "rgba(255, 255, 255, 0)");
      g.fillStyle = r;
      g.fillRect(0, 0, s, s);
    }),
    bubble: makeCanvasTex(128, (g, s) => {
      const c = s / 2;
      g.beginPath();
      g.arc(c, c, c * 0.86, 0, Math.PI * 2);
      const r = g.createRadialGradient(c * 0.68, c * 0.6, 2, c, c, c * 0.9);
      r.addColorStop(0, "#ffffff");
      r.addColorStop(0.7, "#f2f1ff");
      r.addColorStop(1, "#c8c7f4");
      g.fillStyle = r;
      g.fill();
      g.lineWidth = s * 0.036;
      g.strokeStyle = "rgba(136, 134, 224, 0.58)";
      g.stroke();
      g.beginPath();
      g.ellipse(c * 0.7, c * 0.6, c * 0.2, c * 0.13, -0.6, 0, Math.PI * 2);
      g.fillStyle = "rgba(255, 255, 255, 0.95)";
      g.fill();
    }),
    star: makeCanvasTex(128, (g, s) => {
      const c = s / 2;
      const r = g.createRadialGradient(c, c, 0, c, c, c);
      r.addColorStop(0, "rgba(255, 242, 195, 0.72)");
      r.addColorStop(1, "rgba(255, 220, 120, 0)");
      g.fillStyle = r;
      g.fillRect(0, 0, s, s);
      g.beginPath();
      for (let i = 0; i < 4; i++) {
        const a = i * Math.PI / 2, b = a + Math.PI / 4;
        g.lineTo(c + Math.cos(a) * c * 0.92, c + Math.sin(a) * c * 0.92);
        g.quadraticCurveTo(c + Math.cos(b) * c * 0.13, c + Math.sin(b) * c * 0.13, c + Math.cos(a + Math.PI / 2) * c * 0.92, c + Math.sin(a + Math.PI / 2) * c * 0.92);
      }
      g.closePath();
      const f = g.createRadialGradient(c, c, 0, c, c, c * 0.9);
      f.addColorStop(0, "#ffffff");
      f.addColorStop(0.35, "#fff2aa");
      f.addColorStop(1, "#ffb627");
      g.fillStyle = f;
      g.fill();
    }),
    z: makeCanvasTex(128, (g, s) => {
      g.font = `900 ${s * 0.78}px ui-rounded, "SF Pro Rounded", -apple-system, system-ui, sans-serif`;
      g.textAlign = "center";
      g.textBaseline = "middle";
      g.lineJoin = "round";
      g.lineWidth = s * 0.12;
      g.strokeStyle = "#ffffff";
      g.strokeText("z", s / 2, s / 2);
      g.fillStyle = "#6f73f0";
      g.fillText("z", s / 2, s / 2);
    }),
  };
}

/* ---------- 5. Ordonnanceur de Poisson pour la micro-vie ---------- */
class Life {
  constructor() {
    this.next = {};
    this.blink = null;
    this.sacc = { x: 0, y: 0 };
    this.tilt = 0;
    this.flick = [0, 0];
    this.ev = [];
    this.lastEv = "";
    this.out = { lid: 0, gx: 0, gy: 0, tilt: 0, flickL: 0, flickR: 0 };
    this.mul = 1;   // V4-B : fréquence de micro-vie propre à l'espèce (panda roux ×1,35)
  }
  sched(n, mean, now) {
    this.next[n] = now + expo(mean);
  }
  update(now, st, M, ptr, idleFor, reduced) {
    const L = (M.life || 1) * this.mul;
    const rate = (k) => k / L;
    const lock = st === "listening" || st === "approval" || M === MOODS.attention;
    const means = {
      blink: 4.1,
      sacc: lock ? 4.5 : 2.0,
      ear: 7.8,
      tilt: 6.8,
      look: 14.5,
      wave: 40,
      yawn: 34,
      hop: 25,
      wiggle: 19,
    };
    for (const n in means) {
      if (!(n in this.next)) this.sched(n, rate(means[n]), now);
    }
    if (now > this.next.blink) {
      if (st !== "sleep") this.blink = { t0: now, double: Math.random() < 0.18 };
      // V5-F : intervalle naturel (jamais < 1,2 s, moyenne ≈ 4 s) au lieu d'un Poisson pur
      this.next.blink = now + 1.2 + expo(rate(means.blink - 1.2));
    }
    let lid = 0;
    if (this.blink) {
      // Fermeture rapide (70 ms), courte tenue, réouverture plus lente et adoucie (150 ms)
      const u = now - this.blink.t0;
      const o = (u - 0.10) / 0.15;
      lid = u < 0 ? 0 : u < 0.07 ? Math.sin((u / 0.07) * Math.PI / 2) : u < 0.10 ? 1 : u < 0.25 ? 1 - o * o * (3 - 2 * o) : 0;
      if (u > 0.25) {
        this.blink = this.blink.double ? { t0: now + 0.07, double: false } : null;
      }
    }
    if (now > this.next.sacc) {
      // V5-F : 80 % du temps le regard revient vers toi (avec un léger écart naturel),
      // 20 % de micro-dérives (dont un quart plus franches)
      const r = Math.random();
      const atU = r < 0.80 || lock;
      const nx = atU ? ptr.x * 0.85 + rnd(-0.05, 0.05) : r < 0.95 ? ptr.x * 0.4 + rnd(-0.38, 0.38) : rnd(-0.7, 0.7);
      const ny = atU ? ptr.y * 0.80 + rnd(-0.04, 0.04) : r < 0.95 ? ptr.y * 0.4 + rnd(-0.28, 0.12) : rnd(-0.05, 0.5);
      if (Math.hypot(nx - this.sacc.x, ny - this.sacc.y) > 0.58 && !this.blink && Math.random() < 0.32) {
        this.blink = { t0: now, double: false };
      }
      this.sacc.x = nx;
      this.sacc.y = ny;
      this.sched("sacc", rate(means.sacc), now);
    }
    const fire = (n, ok, d) => {
      if (now > this.next[n]) {
        if (ok && this.lastEv !== n && !this.ev.length && !reduced) {
          this.ev.push({ k: n, t0: now, d, s: Math.random() < 0.5 ? -1 : 1, u: 0, done: 0 });
          this.lastEv = n;
        }
        this.sched(n, rate(means[n]), now);
      }
    };
    if (now > this.next.ear) {
      this.flick[Math.random() < 0.5 ? 0 : 1] = 1;
      this.sched("ear", rate(means.ear), now);
    }
    if (now > this.next.tilt) {
      this.tilt = (!MASCOT_LIVELY && st === "idle") || Math.random() < 0.28 ? 0 : rnd(0.05, 0.13) * (Math.random() < 0.5 ? -1 : 1);
      this.sched("tilt", rate(means.tilt), now);
    }
    const calm = st === "idle" && MASCOT_LIVELY;
    fire("look", calm || st === "listening", 1.9);
    fire("wave", calm, 1.7);
    fire("yawn", calm && idleFor > 38, 2.5);
    fire("hop", calm, 0.9);
    fire("wiggle", calm || st === "speaking", 1.25);

    this.flick[0] *= 0.82;
    this.flick[1] *= 0.82;
    for (let i = this.ev.length - 1; i >= 0; i--) {
      const e = this.ev[i];
      e.u = (now - e.t0) / e.d;
      if (e.u >= 1) this.ev.splice(i, 1);
    }
    this.out.lid = lid;
    // Micro-saccades de fixation (petits sauts nets toutes les 0,4–1 s) + trémor très léger
    if (!this.next.micro || now > this.next.micro) {
      this.micro = this.micro || { x: 0, y: 0 };
      this.micro.x = rnd(-0.028, 0.028);
      this.micro.y = rnd(-0.022, 0.022);
      this.next.micro = now + rnd(0.4, 1.0) / this.mul;
    }
    this.out.gx = this.sacc.x + this.micro.x + 0.010 * n1(now * 2.1);
    this.out.gy = this.sacc.y + this.micro.y + 0.010 * n1(now * 1.7 + 9);
    this.out.tilt = this.tilt;
    this.out.flickL = this.flick[0];
    this.out.flickR = this.flick[1];
    return this.out;
  }
}

/* ---------- 6. Repli statique SVG (si WebGL2 est absent) ---------- */
function createSvgFallback(host, red) {
  let state = "idle";
  const wrap = document.createElement("div");
  wrap.style.cssText = "width:100%;height:100%;display:flex;align-items:center;justify-content:center;";
  const fur = red ? "#e26d35" : "#fcf9f4";
  const dark = red ? "#3b2521" : "#322d39";
  const cream = red ? "#fff2e0" : "#fffcf8";
  wrap.innerHTML = `<svg viewBox="0 0 120 120" style="width:100%;height:100%;display:block" aria-hidden="true">
    <ellipse cx="60" cy="106" rx="30" ry="7" fill="rgba(18,18,38,0.28)"/>
    <circle cx="32" cy="28" r="14" fill="${dark}"/>
    <circle cx="88" cy="28" r="14" fill="${dark}"/>
    ${red ? `<circle cx="32" cy="29" r="8" fill="#fff7ef"/><circle cx="88" cy="29" r="8" fill="#fff7ef"/>` : ""}
    <ellipse cx="60" cy="84" rx="26" ry="22" fill="${fur}"/>
    <ellipse cx="60" cy="54" rx="38" ry="33" fill="${fur}"/>
    ${red
      ? `<ellipse cx="44" cy="54" rx="11" ry="13" fill="${cream}"/><ellipse cx="76" cy="54" rx="11" ry="13" fill="${cream}"/>`
      : `<ellipse cx="44" cy="55" rx="11" ry="14" transform="rotate(-24 44 55)" fill="${dark}"/><ellipse cx="76" cy="55" rx="11" ry="14" transform="rotate(24 76 55)" fill="${dark}"/>`}
    <circle cx="45" cy="54" r="7.5" fill="#4b2b1d"/>
    <circle cx="75" cy="54" r="7.5" fill="#4b2b1d"/>
    <circle cx="43" cy="51.5" r="2.6" fill="#fff"/>
    <circle cx="73" cy="51.5" r="2.6" fill="#fff"/>
    <ellipse cx="60" cy="65" rx="14" ry="10" fill="${cream}"/>
    <ellipse cx="60" cy="61" rx="4.5" ry="3.2" fill="#24202a"/>
    <path d="M54 67 Q60 72 66 67" stroke="#28232e" stroke-width="2.4" fill="none" stroke-linecap="round"/>
  </svg>`;
  host.appendChild(wrap);
  return {
    setState(st) { if (STATES[st]) state = st; },
    setMood() {},
    setLevel() {},
    setViseme() {},
    setVisemeSource() {},
    lookAt() {},
    setFocus() {},
    react() {},
    setTheme() {},
    get state() { return state; },
    snapshot() {
      return "data:image/svg+xml;charset=utf-8," + encodeURIComponent(wrap.innerHTML);
    },
    destroy() { wrap.remove(); },
  };
}

/* ---------- 7. Horloge partagée : UNE seule boucle rAF pour tous les compagnons ---------- */
const TICKER = {
  subs: new Set(),
  raf: 0,
  add(fn) {
    this.subs.add(fn);
    if (!this.raf) this.raf = requestAnimationFrame(tick);
  },
};
function tick() {
  TICKER.raf = 0;
  if (!TICKER.subs.size) return;
  TICKER.raf = requestAnimationFrame(tick);
  // Repos CPU (27/10, mesuré : NovaMac ~90 % au repos) : fenêtre masquée ou non focalisée,
  // personne ne regarde le compagnon — les abonnés ne sont servis qu'à ~2 images/s
  // (respiration quasi figée, invisible), le plein rythme revient dès le focus.
  const now = performance.now() / 1000;
  if (document.hidden || !document.hasFocus()) {
    if (now - (TICKER.idleAt || 0) < 0.5) return;
    TICKER.idleAt = now;
  }
  TICKER.subs.forEach((f) => {
    try {
      f(now);
    } catch (e) {}
  });
}

/* ---------- 8. Moteur principal createAvatar ---------- */
export function createAvatar(host, { species = "panda", preserve = false } = {}) {
  const red = species === "renard" || species === "panda-roux" || species === "red" || species === 1;
  const P = red ? PAL.red : PAL.panda;
  const SP = red ? SPECIES.red : SPECIES.panda;

  // Test strict de disponibilité WebGL2 sans lever d'exception
  let renderer = null;
  try {
    const testCv = document.createElement("canvas");
    const gl2 = testCv.getContext("webgl2", { alpha: true, antialias: true, premultipliedAlpha: true, preserveDrawingBuffer: !!preserve });
    if (!gl2) return createSvgFallback(host, red);
    renderer = new THREE.WebGLRenderer({
      canvas: testCv,
      context: gl2,
      alpha: true,
      antialias: true,
      premultipliedAlpha: true,
      powerPreference: "high-performance",
      preserveDrawingBuffer: !!preserve,
    });
  } catch (e) {
    return createSvgFallback(host, red);
  }

  renderer.setClearColor(0x000000, 0);
  const cv = renderer.domElement;
  cv.style.cssText = "width:100%;height:100%;display:block";
  host.appendChild(cv);

  const scene = new THREE.Scene();
  const cam = new THREE.PerspectiveCamera(25, 1, 0.1, 30);
  const T = createInstanceTextures();
  const texList = [T.shadow, T.glow, T.bubble, T.star, T.z];

  const G = {
    uKey: { value: new THREE.Vector3(1.03, 0.99, 0.95) },
    uRim: { value: new THREE.Vector3(0.58, 0.64, 0.98) },
    uGlow: { value: 0 },
    uGlowC: { value: new THREE.Vector3(0.55, 0.72, 1.2) },
    uLW: { value: 1 },
    uTime: { value: 0 },
    uScan: { value: new THREE.Vector2(0, 0) },
  };

  const mats = [];
  const geos = [];
  const sstep = (a, b, x) => {
    const t = clamp((x - a) / (b - a), 0, 1);
    return t * t * (3 - 2 * t);
  };

  // V5-F : registre des primitives analytiques (espace monde, mis à jour à chaque image)
  const PI_ = { body: 0, head: 1, armL: 2, armR: 3, pawL: 4, pawR: 5, legL: 6, legR: 7, earL: 8, earR: 9, muz: 10, tail: 11 };
  const PRIM_U = {
    uPM: { value: Array.from({ length: NP }, () => new THREE.Matrix4()) },
    uPR: { value: Array.from({ length: NP }, () => new THREE.Vector4(1, 1, 1, 0)) },
  };
  const prims = new Array(NP).fill(null);   // { obj, r: [x, y, z], h }
  const regPrim = (k, obj, r, h = 0) => { prims[PI_[k]] = { obj, r, h }; };

  function surf(base, o = {}) {
    const C = [], R = [], K = [];
    for (let i = 0; i < MAXM; i++) {
      const m = (o.marks || [])[i];
      if (m) {
        const d = new THREE.Vector3(...m.d).normalize();
        const c = col(m.c);
        C.push(new THREE.Vector4(d.x, d.y, d.z, m.tilt || 0));
        R.push(new THREE.Vector4(m.a, m.b, m.taper || 0, m.soft ?? 0.15));
        K.push(new THREE.Vector4(c.r, c.g, c.b, m.s ?? 1));
      } else {
        C.push(new THREE.Vector4(0, 0, 1, 0));
        R.push(new THREE.Vector4(1, 1, 0, 0.1));
        K.push(new THREE.Vector4(0, 0, 0, 0));
      }
    }
    const u = {
      ...G,
      uBase: { value: col(base) },
      uMC: { value: C },
      uMR: { value: R },
      uMK: { value: K },
      uSpec: { value: o.spec ?? 0.10 },
      uShin: { value: o.shin ?? 18 },
      uSSS: { value: o.sss ?? 0 },
      uFur: { value: o.fur ?? 1.0 },
      uAO: { value: new THREE.Vector2(...(o.ao || [0, 0])) },
      uEmit: { value: o.emit || 0 },
    };
    const defines = {};
    if (o.deform || o.shellOf) {
      // Union lisse : o.deform.blend = { nomPrimitive: rayon de congé (unités monde) }
      defines.DEFORM = 1;
      u.uPM = PRIM_U.uPM;
      u.uPR = PRIM_U.uPR;
      if (o.shellOf) {
        const b = o.shellOf.uniforms;
        u.uPK = b.uPK;
        u.uMode = b.uMode;
        u.uDefA = b.uDefA;
        if (b.uMouth) { u.uMouth = b.uMouth; u.uMouth2 = b.uMouth2; }
      } else {
        const pk = new Array(NP).fill(0);
        const bl = o.deform.blend || {};
        for (const k in bl) pk[PI_[k]] = bl[k];
        u.uPK = { value: pk };
        u.uMode = { value: o.deform.mode || 0 };
        u.uDefA = { value: new THREE.Vector4(0, 0, 0, 0) };
      }
      u.uShell = { value: o.shell || 0 };
    }
    if (o.shellOf) {
      defines.SHELL = 1;
      u.uLayer = { value: o.layer ?? 0.4 };
      u.uFiberF = { value: o.fiberF ?? 30 };
    }
    if (o.tail) {
      defines.TAIL = 1;
      u.uBase2 = { value: col(o.tail) };
    }
    if (o.fade) {
      defines.FADE = 1;
      u.uBase2 = { value: col(o.fade) };
    }
    if (o.mouth) {
      defines.MOUTH = 1;
      u.uMouth = { value: new THREE.Vector4(0, 0.5, 0, 0) };
      u.uMouth2 = { value: new THREE.Vector4(0, 0, 0, 0) };
      u.uLineC = { value: col(P.line) };
      u.uMouthC = { value: col(P.mouthIn) };
      u.uTongueC = { value: col(P.tongue) };
    }
    const m = new THREE.ShaderMaterial({ uniforms: u, vertexShader: VS, fragmentShader: FS_SURF, defines });
    if (o.shellOf) {
      m.transparent = true;
      m.depthWrite = false;
    }
    mats.push(m);
    return m;
  }
  // Coquilles de fourrure (2 couches, transparentes, enfants du maillage : même matrice)
  const shells = [];
  const addShells = (mesh, mat, o, layers) => {
    layers.forEach(([off, layer]) => {
      const sm = surf("#ffffff", { ...o, shellOf: mat, shell: off, layer });
      sm.uniforms.uBase = mat.uniforms.uBase;
      const x = new THREE.Mesh(mesh.geometry, sm);
      x.renderOrder = 2;
      mesh.add(x);
      shells.push(x);
    });
  };

  const SPH = new THREE.SphereGeometry(1, 56, 40);
  const SPH_S = new THREE.SphereGeometry(1, 28, 20);
  geos.push(SPH, SPH_S);

  const addMesh = (g, m, parent, pos, scl) => {
    const x = new THREE.Mesh(g, m);
    if (pos) x.position.set(pos[0], pos[1], pos[2]);
    if (scl) x.scale.set(scl[0], scl[1], scl[2]);
    parent.add(x);
    return x;
  };

  /* --- Construction anatomique studio-grade --- */
  const root = new THREE.Group();
  scene.add(root);
  const body = new THREE.Group();
  root.add(body);

  // Corps en haricot souple (déformation organique continue : poitrine fine, ventre rond)
  const beanGeo = new THREE.SphereGeometry(1, 52, 38);
  {
    const pa = beanGeo.attributes.position;
    for (let i = 0; i < pa.count; i++) {
      let x = pa.getX(i), y = pa.getY(i), z = pa.getZ(i);
      const belly = 1.0 - 0.12 * y + 0.06 * (1.0 - y * y);
      x *= belly;
      z *= belly;
      if (y < 0) z += 0.08 * (-y);
      pa.setXYZ(i, x, y, z);
    }
    beanGeo.computeVertexNormals();
  }
  geos.push(beanGeo);

  // Selle d'épaules ouverte en V sur le poitrail (panda) ou ventre brun doux (panda roux)
  const bodyMarks = red
    ? [
        { d: [0, 0.25, 1], a: 0.44, b: 0.36, soft: 0.65, c: P.ringB, s: 0.36 },
        { d: [0, -0.45, 0.85], a: 0.55, b: 0.42, soft: 0.5, c: P.dark, s: 0.55 },
      ]
    : [
        { d: [0, 0.92, -0.25], a: 0.78, b: 0.72, soft: 0.18, c: P.dark },
        ...sym({ d: [0.65, 0.58, 0.45], tilt: 0.35, a: 0.42, b: 0.28, soft: 0.22, c: P.dark }),
        ...sym({ d: [0.80, 0.40, 0.44], tilt: 0.25, a: 0.46, b: 0.40, soft: 0.16, c: P.dark }),   // 24/10 : bande d'épaules visible de face, reliée aux bras
      ];
  const bodyO = { marks: bodyMarks, sss: red ? 0.18 : 0.58, ao: [0.14, 0.28] };
  const bodyMat = surf(P.body, { ...bodyO, deform: { mode: 1, blend: { head: 0.065, armL: 0.075, armR: 0.075, legL: 0.06, legR: 0.06, tail: red ? 0.05 : 0.03 } } });
  const bodyM = addMesh(beanGeo, bodyMat, body, [0, 0.30, 0], [0.255, 0.275, 0.24]);
  regPrim("body", bodyM, [1.05, 1.0, 1.06]);
  addShells(bodyM, bodyMat, bodyO, [[0.009, 0.42]]);

  // Jambes courtes et rondes + coussinets plantaires (toe beans visibles)
  const footMarks = [
    { d: [0, -0.12, 0.98], a: 0.38, b: 0.32, soft: 0.18, c: P.pad, s: 0.92 },
    { d: [-0.26, 0.26, 0.92], a: 0.14, b: 0.16, soft: 0.18, c: P.pad, s: 0.92 },
    { d: [0, 0.32, 0.94], a: 0.14, b: 0.16, soft: 0.18, c: P.pad, s: 0.92 },
    { d: [0.26, 0.26, 0.92], a: 0.14, b: 0.16, soft: 0.18, c: P.pad, s: 0.92 },
  ];
  const legs = [-1, 1].map((s) => {
    const legMat = surf(P.leg, { marks: footMarks, sss: 0.12, spec: 0.08, deform: { blend: { body: 0.06 } } });
    const g = new THREE.Group();
    g.position.set(s * 0.11, 0.115, 0.08);
    body.add(g);
    const cg = new THREE.CapsuleGeometry(0.075, 0.048, 10, 24);
    geos.push(cg);
    const m = addMesh(cg, legMat, g, [0, -0.045, 0.01]);
    m.rotation.x = 0.25;
    regPrim(s < 0 ? "legL" : "legR", m, [0.075, 0.075, 0.075], 0.024);
    return g;
  });

  // Bras souples articulés depuis l'épaule avec coussinets palmaires

  const armGeo = new THREE.CapsuleGeometry(0.064, 0.12, 10, 24);
  geos.push(armGeo);
  const SH = [new THREE.Vector3(-0.175, 0.43, 0.06), new THREE.Vector3(0.175, 0.43, 0.06)];
  const arms = [0, 1].map((i) => {
    const g = new THREE.Group();
    g.position.copy(SH[i]);
    body.add(g);
    const ak = i ? "armR" : "armL", pk = i ? "pawR" : "pawL";
    const armMat = surf(P.arm, { sss: 0.12, spec: 0.08, fade: red ? P.body : null, deform: { blend: { body: 0.075, [pk]: 0.05 } } });
    const pawMat = surf(P.arm, {
      marks: [{ d: [0, 0, 1], a: 0.38, b: 0.34, soft: 0.25, c: P.pad, s: 0.75 }],
      sss: 0.12,
      spec: 0.10,
      deform: { blend: { [ak]: 0.05 } },
    });
    const a = addMesh(armGeo, armMat, g);
    const p = addMesh(SPH_S, pawMat, g, null, [0.076, 0.070, 0.074]);
    regPrim(ak, a, [0.064, 0.064, 0.064], 0.06);
    regPrim(pk, p, [1, 1, 1]);
    return { g, a, p };
  });

  // Queue : petit pompon crème (panda) ou longue queue annelée articulée en suivi (panda roux)
  const tail = [];
  let tailRoot = null;
  let tailTube = null;
  if (!red) {
    const pom = addMesh(SPH_S, surf(P.fur, { sss: 0.45, deform: { blend: { body: 0.03 } } }), body, [0, 0.14, -0.22], [0.062, 0.062, 0.062]);
    regPrim("tail", pom, [1, 1, 1]);
  } else {
    const tg = new THREE.Group();
    tailRoot = tg;
    tg.position.set(0.13, 0.10, -0.16);
    tg.rotation.set(-0.35, 0, -1.05);
    body.add(tg);
    let parent = tg;
    for (let i = 0; i < 7; i++) {
      const g = new THREE.Group();
      g.position.y = i ? 0.072 : 0;
      parent.add(g);
      tail.push(g);
      parent = g;
    }
    // V5-F : la queue n'est plus un chapelet de sphères mais un TUBE continu déformé à chaque
    // image le long de la chaîne articulée (spline de Catmull-Rom, repère à transport parallèle)
    const helper = new THREE.Object3D();
    helper.position.set(0, 0.03, 0);
    helper.scale.setScalar(0.07);
    tail[0].add(helper);
    regPrim("tail", helper, [1, 1, 1]);
    tailTube = makeTailTube();
  }

  // Tube de queue (panda roux) : 34 anneaux × 18 côtés, sommets réécrits sur place à chaque image
  function makeTailTube() {
    const NS = 34, NR = 18;
    const n = NS * (NR + 1);
    const g = new THREE.BufferGeometry();
    const pos = new Float32Array(n * 3), nor = new Float32Array(n * 3), uv = new Float32Array(n * 2);
    const idx = [];
    for (let i = 0; i < NS; i++) {
      for (let j = 0; j <= NR; j++) {
        uv[(i * (NR + 1) + j) * 2] = i / (NS - 1);
        uv[(i * (NR + 1) + j) * 2 + 1] = j / NR;
        if (i < NS - 1 && j < NR) {
          const a = i * (NR + 1) + j, b = a + NR + 1;
          idx.push(a, b, a + 1, b, b + 1, a + 1);
        }
      }
    }
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("normal", new THREE.BufferAttribute(nor, 3));
    g.setAttribute("uv", new THREE.BufferAttribute(uv, 2));
    g.setIndex(idx);
    geos.push(g);
    const m = new THREE.Mesh(g, surf(P.ringA, { tail: P.ringB, sss: 0.34, deform: { blend: { body: 0.05 } } }));
    m.frustumCulled = false;
    scene.add(m);
    const C = Array.from({ length: 9 }, () => new THREE.Vector3());
    return { m, g, pos, nor, NS, NR, C, P: Array.from({ length: NS }, () => new THREE.Vector3()), T: new THREE.Vector3(), N: new THREE.Vector3(), B: new THREE.Vector3() };
  }
  const _cr = (a, b, c, d, f, out) => {
    const f2 = f * f, f3 = f2 * f;
    out.set(0, 0, 0)
      .addScaledVector(a, -0.5 * f3 + f2 - 0.5 * f)
      .addScaledVector(b, 1.5 * f3 - 2.5 * f2 + 1)
      .addScaledVector(c, -1.5 * f3 + 2 * f2 + 0.5 * f)
      .addScaledVector(d, 0.5 * f3 - 0.5 * f2);
    return out;
  };
  function updateTailTube(gr) {
    const t = tailTube;
    const C = t.C;
    tailRoot.localToWorld(C[0].set(0, -0.02, 0.05));
    for (let i = 0; i < 7; i++) tail[i].localToWorld(C[i + 1].set(0, 0.03, 0));
    C[8].copy(C[7]).sub(C[6]).multiplyScalar(0.85).add(C[7]);
    const last = C.length - 1;
    for (let i = 0; i < t.NS; i++) {
      const u = (i / (t.NS - 1)) * last;
      const k = Math.min(last - 1, Math.floor(u));
      _cr(C[Math.max(k - 1, 0)], C[k], C[k + 1], C[Math.min(k + 2, last)], u - k, t.P[i]);
    }
    const NR = t.NR, pos = t.pos, nor = t.nor;
    for (let i = 0; i < t.NS; i++) {
      const tt = i / (t.NS - 1);
      t.T.copy(t.P[Math.min(i + 1, t.NS - 1)]).sub(t.P[Math.max(i - 1, 0)]).normalize();
      if (i === 0) {
        t.N.set(0, 0, 1).cross(t.T);
        if (t.N.lengthSq() < 1e-6) t.N.set(1, 0, 0);
        t.N.normalize();
      } else {
        t.N.addScaledVector(t.T, -t.N.dot(t.T)).normalize();
      }
      t.B.copy(t.T).cross(t.N);
      // Profil touffu : fin à la racine, bombé au milieu, pointe arrondie (fermée)
      let r = 0.056 + 0.040 * sstep(0.0, 0.42, tt) - 0.008 * sstep(0.55, 0.85, tt);
      if (tt > 0.80) r *= Math.sqrt(Math.max(0, 1 - Math.pow((tt - 0.80) / 0.20, 2)));
      r *= gr;
      for (let j = 0; j <= NR; j++) {
        const a = (j / NR) * Math.PI * 2, ca = Math.cos(a), sa = Math.sin(a);
        const nx = t.N.x * ca + t.B.x * sa, ny = t.N.y * ca + t.B.y * sa, nz = t.N.z * ca + t.B.z * sa;
        const o = (i * (NR + 1) + j) * 3;
        pos[o] = t.P[i].x + nx * r;
        pos[o + 1] = t.P[i].y + ny * r;
        pos[o + 2] = t.P[i].z + nz * r;
        nor[o] = nx; nor[o + 1] = ny; nor[o + 2] = nz;
      }
    }
    t.g.attributes.position.needsUpdate = true;
    t.g.attributes.normal.needsUpdate = true;
  }

  // Tête large (55 % de la hauteur totale) avec joues pleines (bajoues fondues sans arête)
  const headG = new THREE.Group();
  headG.position.set(0, 0.70, 0.02);
  headG.rotation.order = "YXZ";
  body.add(headG);

  const HS = red ? new THREE.Vector3(0.408, 0.35, 0.365) : new THREE.Vector3(0.395, 0.355, 0.365);
  const headGeo = new THREE.SphereGeometry(1, 64, 48);
  {
    const pa = headGeo.attributes.position;
    for (let i = 0; i < pa.count; i++) {
      let x = pa.getX(i), y = pa.getY(i), z = pa.getZ(i);
      // Joues potelées basses et front doux (silhouette studio Nintendo / Pixar)
      const cheek = Math.exp(-Math.pow(y + 0.24, 2) / 0.16) * (0.065 + 0.035 * Math.max(0, z));
      x *= 1.0 + cheek;
      z *= 1.0 + cheek * 0.45;
      pa.setXYZ(i, x, y, z);
    }
    headGeo.computeVertexNormals();
  }
  geos.push(headGeo);

  const hMarks = headMarks(red, P);
  const headO = { marks: hMarks, sss: red ? 0.24 : 0.62, ao: [0.26, 0], spec: 0.07 };
  const headMat = surf(P.fur, { ...headO, deform: { mode: 2, blend: { body: 0.065, earL: 0.035, earR: 0.035, muz: 0.05 } } });
  const headM = addMesh(headGeo, headMat, headG, null, HS.toArray());
  regPrim("head", headM, [1.04, 1.0, 1.02]);
  addShells(headM, headMat, headO, [[0.008, 0.44]]);
  // Duchenne : les joues roses (pommettes) remontent et s'arrondissent quand le sourire est franc
  const cheekIdx = [];
  hMarks.forEach((mk, i) => { if (mk.c === P.blush) cheekIdx.push(i); });
  const cheekBase = cheekIdx.map((i) => ({
    c: headMat.uniforms.uMC.value[i].clone(), r: headMat.uniforms.uMR.value[i].clone(), a: headMat.uniforms.uMK.value[i].w,
  }));

  const onHead = (dx, dy, dz, k = 1) => {
    const d = new THREE.Vector3(dx, dy, dz).normalize();
    const p = d.clone().multiply(HS).multiplyScalar(k);
    const n = p.clone().divide(HS).divide(HS).normalize();
    return { p, n, d };
  };

  // Arcades sourcilières expressives en fourrure douce (portent l'émotion sans trait noir dessiné)
  const browMat = surf(red ? P.cream : P.fur, { sss: 0.45, spec: 0.05 });
  const brows = [-1, 1].map((s) => {
    const bPos = onHead(s * 0.35, 0.12, 0.92, 0.985);
    const g = new THREE.Group();
    g.position.copy(bPos.p);
    g.quaternion.setFromUnitVectors(new THREE.Vector3(0, 0, 1), bPos.n);
    headG.add(g);
    addMesh(SPH_S, browMat, g, null, [0.056, 0.019, 0.022]);
    return { g, baseY: bPos.p.y, s };
  });

  // Oreilles (rondes pour le panda géant, triangulaires arrondies à intérieur blanc pour le panda roux)
  const earGeo = new THREE.SphereGeometry(1, 40, 28);
  if (red) {
    const pa = earGeo.attributes.position;
    for (let i = 0; i < pa.count; i++) {
      const y = pa.getY(i), k = Math.max(0, y);
      pa.setX(i, pa.getX(i) * (1 - 0.38 * k));
      pa.setY(i, y * (1 + 0.26 * k));
    }
    earGeo.computeVertexNormals();
  }
  geos.push(earGeo);

  const earMarks = red
    ? [{ d: [0, -0.08, 1], a: 0.66, b: 0.74, taper: -0.2, soft: 0.24, c: P.earIn }]
    : [{ d: [0, -0.1, 1], a: 0.50, b: 0.50, soft: 0.35, c: P.earIn, s: 0.45 }];
  const ears = [-1, 1].map((s) => {
    const earMat = surf(P.ear, { marks: earMarks, sss: red ? 0.25 : 0.12, spec: 0.06, deform: { mode: 3, blend: { head: 0.035 } } });
    const e = onHead(s * 0.62, 0.74, -0.1, 0.90);
    const g = new THREE.Group();
    g.position.copy(e.p);
    headG.add(g);
    g.rotation.set(-0.15, 0, -s * (red ? 0.48 : 0.55));
    const sc = red ? [0.126, 0.132, 0.056] : [0.122, 0.118, 0.066];
    const em = addMesh(earGeo, earMat, g, [0, sc[1] * 0.55, 0], sc);
    regPrim(s < 0 ? "earL" : "earR", em, red ? [0.86, 1.08, 1] : [1, 1, 1]);
    return { g, s, m: em, mat: earMat, pos: new THREE.Vector3(), vel: new THREE.Vector3(), init: false };
  });

  // Yeux grands, placés bas et écartés, toujours lumineux
  const eyes = [-1, 1].map((s) => {
    const e = onHead(s * 0.37, -0.11, 0.92, 1.032);
    const u = {
      ...G,
      uGaze: { value: new THREE.Vector2(0, 0) },
      uTop: { value: 0 },
      uBot: { value: 0 },
      uTilt: { value: 0 },
      uSide: { value: -s },
      uIris: { value: 1 },
      uHappy: { value: 0 },
      uLidC: { value: col(P.lid) },
      uLashC: { value: col(P.lash) },
      uCloseC: { value: col(P.close) },
      uIrisC: { value: col(P.iris) },
      uScl: { value: col(P.scl) },
    };
    const m = new THREE.ShaderMaterial({ uniforms: u, vertexShader: VS, fragmentShader: FS_EYE });
    mats.push(m);
    const x = addMesh(SPH, m, headG, e.p.toArray(), [0.090, 0.104, 0.060]);
    x.quaternion.setFromUnitVectors(new THREE.Vector3(0, 0, 1), e.n);
    x.rotateZ(-s * 0.06);
    return { x, u };
  });

  // Accessoire 0 : lunettes rondes dorées de lecture (état reading) — sortent du front et glissent sur le museau
  const glasses = new THREE.Group();
  headG.add(glasses);
  const goldMat = surf("#e2ae4c", { spec: 0.95, shin: 70, fur: 0, sss: 0 });
  const rimGeo = new THREE.TorusGeometry(0.108, 0.012, 10, 44);
  const lensGeo = new THREE.CircleGeometry(0.104, 36);
  const lensMat = new THREE.MeshBasicMaterial({ color: 0xfff6e0, transparent: true, opacity: 0.12, depthWrite: false });
  const bridgeGeo = new THREE.TorusGeometry(0.036, 0.010, 8, 20, Math.PI);
  const templeGeo = new THREE.CapsuleGeometry(0.008, 0.16, 4, 8);
  geos.push(rimGeo, lensGeo, bridgeGeo, templeGeo);
  mats.push(lensMat);
  const gPos = [];
  [-1, 1].forEach((s) => {
    const e = onHead(s * 0.37, -0.11, 0.92, 1.032);
    const g = new THREE.Group();
    g.position.copy(e.p).addScaledVector(e.n, 0.032);
    g.quaternion.setFromUnitVectors(new THREE.Vector3(0, 0, 1), e.n);
    glasses.add(g);
    addMesh(rimGeo, goldMat, g);
    addMesh(lensGeo, lensMat, g, [0, 0, 0.002]);
    const t = addMesh(templeGeo, goldMat, glasses, [g.position.x + s * 0.09, g.position.y + 0.02, g.position.z - 0.09]);
    t.rotation.set(Math.PI / 2, s * 0.55, 0);
    gPos.push(g.position);
  });
  const bridge = addMesh(bridgeGeo, goldMat, glasses, [(gPos[0].x + gPos[1].x) / 2, (gPos[0].y + gPos[1].y) / 2 + 0.035, (gPos[0].z + gPos[1].z) / 2 + 0.006]);
  bridge.rotation.z = 0;

  // Museau clair + bouche animée + truffe brillante
  const mz = onHead(0, -0.47, 0.88, 0.905);
  const muzG = new THREE.Group();
  muzG.position.copy(mz.p);
  headG.add(muzG);
  muzG.quaternion.setFromUnitVectors(new THREE.Vector3(0, 0, 1), mz.n.clone().add(new THREE.Vector3(0, 0.3, 0)).normalize());
  const muzMat = surf(P.muzzle, { mouth: true, sss: 0.52, spec: 0.06, fur: 0.4, deform: { blend: { head: 0.05 } } });
  const muzM = addMesh(SPH, muzMat, muzG, null, [0.156, 0.112, 0.086]);
  regPrim("muz", muzM, [1, 1, 1]);

  const noseGeo = new THREE.SphereGeometry(1, 32, 24);
  {
    const pa = noseGeo.attributes.position;
    for (let i = 0; i < pa.count; i++) {
      const y = pa.getY(i);
      pa.setX(i, pa.getX(i) * (0.62 + 0.38 * (y * 0.5 + 0.5)));
    }
    noseGeo.computeVertexNormals();
  }
  geos.push(noseGeo);
  addMesh(noseGeo, surf(P.nose, { spec: 0.92, shin: 42, fur: 0 }), muzG, [0, 0.052, 0.072], [0.046, 0.030, 0.028]);

  // Accessoire 1 : Casque audio (listening)
  const phones = new THREE.Group();
  headG.add(phones);
  phones.rotation.x = -0.42;
  const phonesMat = surf("#7d7bff", { spec: 0.55, shin: 32, fur: 0 });
  const bandMat = surf("#f4f3fb", { spec: 0.42, shin: 30, fur: 0 });
  const bandGeo = new THREE.TorusGeometry(0.418, 0.026, 14, 64, Math.PI);
  geos.push(bandGeo);
  addMesh(bandGeo, bandMat, phones, [0, 0.01, 0]);
  [-1, 1].forEach((s) => {
    addMesh(SPH_S, phonesMat, phones, [s * 0.408, -0.01, 0], [0.066, 0.106, 0.106]);
    addMesh(SPH_S, bandMat, phones, [s * 0.372, -0.01, 0], [0.040, 0.086, 0.086]);
  });

  // Accessoire 2 : Ordinateur portable avec écran lumineux (tool)
  const laptop = new THREE.Group();
  root.add(laptop);
  laptop.position.set(0.01, 0.19, 0.34);
  laptop.rotation.set(0.05, -0.42, 0);
  const rr = (w, h, rad) => {
    const s = new THREE.Shape();
    s.moveTo(-w / 2 + rad, -h / 2);
    s.lineTo(w / 2 - rad, -h / 2);
    s.quadraticCurveTo(w / 2, -h / 2, w / 2, -h / 2 + rad);
    s.lineTo(w / 2, h / 2 - rad);
    s.quadraticCurveTo(w / 2, h / 2, w / 2 - rad, h / 2);
    s.lineTo(-w / 2 + rad, h / 2);
    s.quadraticCurveTo(-w / 2, h / 2, -w / 2, h / 2 - rad);
    s.lineTo(-w / 2, -h / 2 + rad);
    s.quadraticCurveTo(-w / 2, -h / 2, -w / 2 + rad, -h / 2);
    return s;
  };
  const exO = { depth: 0.006, bevelEnabled: true, bevelThickness: 0.007, bevelSize: 0.007, bevelSegments: 4, curveSegments: 8 };
  const baseGeo = new THREE.ExtrudeGeometry(rr(0.32, 0.21, 0.03), exO);
  const lidGeo = new THREE.ExtrudeGeometry(rr(0.32, 0.20, 0.03), exO);
  geos.push(baseGeo, lidGeo);
  const alu = surf("#dcdcec", { spec: 0.58, shin: 36, fur: 0 });
  const screenMat = surf("#b9c6ff", { emit: 0.92, spec: 0.3, fur: 0 });
  const logoMat = surf("#7d7bff", { emit: 0.55, fur: 0 });
  const lb = addMesh(baseGeo, alu, laptop);
  lb.rotation.x = -Math.PI / 2;
  const hinge = new THREE.Group();
  hinge.position.set(0, 0.01, 0.10);
  laptop.add(hinge);
  hinge.rotation.x = -0.32;
  addMesh(lidGeo, alu, hinge, [0, 0.10, 0]);
  const scPlane = new THREE.PlaneGeometry(0.29, 0.17);
  geos.push(scPlane);
  const sc = addMesh(scPlane, screenMat, hinge, [0, 0.10, -0.009]);
  sc.rotation.y = Math.PI;
  addMesh(SPH_S, logoMat, hinge, [0, 0.10, 0.015], [0.018, 0.018, 0.004]);

  // Accessoires Sprites : bulles de pensée, étincelles, « z », ombre de contact, lueur au sol
  const makeSpr = (tex, sz) => {
    const m = new THREE.SpriteMaterial({ map: tex, transparent: true, depthWrite: false });
    mats.push(m);
    const s = new THREE.Sprite(m);
    s.scale.set(sz, sz, 1);
    scene.add(s);
    return s;
  };
  const bubbles = [0, 1, 2].map(() => makeSpr(T.bubble, 0.10));
  const sparks = Array.from({ length: 7 }, () => makeSpr(T.star, 0.14));
  const zs = [0, 1, 2].map(() => makeSpr(T.z, 0.12));

  const shGeo = new THREE.PlaneGeometry(1, 1);
  const shMat = new THREE.MeshBasicMaterial({ map: T.shadow, transparent: true, depthWrite: false });
  geos.push(shGeo);
  mats.push(shMat);
  const shadow = new THREE.Mesh(shGeo, shMat);
  shadow.rotation.x = -Math.PI / 2;
  scene.add(shadow);
  // V5-F : ombre de contact serrée sous les pieds (ancrage net) en plus de l'ombre large et douce
  const shMat2 = new THREE.MeshBasicMaterial({ map: T.shadow, transparent: true, depthWrite: false });
  mats.push(shMat2);
  const shadow2 = new THREE.Mesh(shGeo, shMat2);
  shadow2.rotation.x = -Math.PI / 2;
  shadow2.position.y = 0.001;
  scene.add(shadow2);

  const glGeo = new THREE.PlaneGeometry(1, 1);
  const glMat = new THREE.MeshBasicMaterial({
    map: T.glow,
    transparent: true,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
    color: 0x6c6af6,
  });
  geos.push(glGeo);
  mats.push(glMat);
  const glowSpr = new THREE.Mesh(glGeo, glMat);
  glowSpr.rotation.x = -Math.PI / 2;
  glowSpr.position.y = 0.002;
  scene.add(glowSpr);

  // Lecture du thème (--accent)
  const tmpColor = new THREE.Color();
  const whiteColor = new THREE.Color("#ffffff");
  const screenTint = new THREE.Color("#dfe6ff");
  const readAccent = () => {
    let hex = "#6C6AF6";
    try {
      hex = getComputedStyle(document.documentElement).getPropertyValue("--accent").trim() || hex;
    } catch (e) {}
    try {
      tmpColor.set(hex);
    } catch (e) {
      tmpColor.setHex(0x6c6af6);
    }
    return tmpColor;
  };
  const applyTheme = () => {
    const a = readAccent();
    // Liseré (rim light) doux teinté par l'accent du thème, sans halo violet
    // V5-F : liseré réchauffé (50 % accent du thème, 50 % lumière dorée) → silhouette douce, pas froide
    G.uRim.value.set((a.r * 0.42 + 0.50) * 0.5 + 0.50, (a.g * 0.42 + 0.52) * 0.5 + 0.42, (a.b * 0.42 + 0.58) * 0.5 + 0.33);
    phonesMat.uniforms.uBase.value.copy(a).lerp(whiteColor, 0.16);
    logoMat.uniforms.uBase.value.copy(a);
    screenMat.uniforms.uBase.value.copy(a).lerp(screenTint, 0.52);
    glowSpr.material.color.copy(a);
  };
  applyTheme();

  /* --- État d'animation et pré-allocation (0 allocation dans la boucle) --- */
  const S = {};
  const Tg = {};
  for (const [k, [v, w, z]] of Object.entries(CH)) {
    // Personnalité : les canaux de pose prennent le zeta de l'espèce (panda 0,85 calme · panda roux 0,65 vif)
    const pose = POSE_KEYS.indexOf(k) >= 0;
    S[k] = new Spring(v, pose ? w * SP.wMul : w, pose ? SP.zeta : z);
    Tg[k] = v;
  }

  let state = "idle";
  let mood = "neutre";
  let level = 0;
  let stateT = 0;
  let visible = true;
  let lastAct = performance.now() / 1000;
  let dead = false;
  let doneHopTimer = 0;
  let themeTimer = 0;
  let hopY = 0;
  let hopV = 0;
  const jumps = [];
  let phi = Math.random() * 6;
  let typing = 0;
  let prevVy = 0;
  let prevY = 0;
  let camK = 0;
  const imp = [];
  const life = new Life();
  life.mul = SP.life;
  const ptr = { x: 0, y: 0 };
  // V4-B : visèmes mesurés, cible d'intérêt, transfert de poids, gestes de rythme, pirouette, fouet de queue
  const vis = { open: 0, spread: 0, round: 0, press: 0, t: -10 };
  let visSrc = null;
  const focus = { on: false, x: 0, y: 0 };
  const weight = { side: Math.random() < 0.5 ? -1 : 1, next: 0 };
  let lvSlow = 0, beatT0 = -10, beatSide = 1, beatCool = 0;
  let spinT0 = -10, whipT0 = -10;
  const BLUE = new THREE.Vector3(0.55, 0.72, 1.2);
  const AMBER = new THREE.Vector3(1.2, 0.82, 0.45);

  // Vecteurs et quaternions réutilisés à chaque image
  const _q = new THREE.Quaternion();
  const _down = new THREE.Vector3(0, -1, 0);
  const _v = new THREE.Vector3();
  const _tgt = new THREE.Vector3();
  const _hw = new THREE.Vector3();
  const _m4 = new THREE.Matrix4();
  const _tip = new THREE.Vector3();

  const isReducedMotion = () => {
    try {
      return matchMedia("(prefers-reduced-motion: reduce)").matches || document.documentElement.dataset.reduceMotion === "1";
    } catch (e) {
      return false;
    }
  };

  const jump = (v, delay = 0.10) => {
    const now = performance.now() / 1000;
    const scale = isReducedMotion() ? 0.2 : 1.0;
    S.sq.v -= 2.2 * v * scale;
    jumps.push({ t: now + delay, v: v * scale });
  };

  // Plafonds de performance : DPR <= 2 et résolution interne <= 360 px de côté
  let cssW = 0, cssH = 0, pxRatio = 1;
  const resize = () => {
    cssW = Math.max(16, host.clientWidth || 200);
    cssH = Math.max(16, host.clientHeight || cssW);
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const cap = 360 / Math.max(cssW, cssH);
    pxRatio = Math.min(dpr, cap);
    renderer.setPixelRatio(pxRatio);
    renderer.setSize(cssW, cssH, false);
    cam.aspect = cssW / cssH;
    cam.updateProjectionMatrix();
    G.uLW.value = clamp(240 / (Math.min(cssW, cssH) * pxRatio), 1, 2.3);
  };
  const ro = new ResizeObserver(resize);
  ro.observe(host);
  const io = new IntersectionObserver((entries) => {
    if (entries && entries[0]) visible = entries[0].isIntersecting;
  });
  io.observe(host);

  let last = performance.now() / 1000;
  let acc = 0;


  function update(now, step) {
    stateT += step;
    G.uTime.value = now;
    const redMot = isReducedMotion();
    const motScale = redMot ? 0.2 : 1.0; // Amplitudes divisées par 5 en mouvement réduit
    const M = MOODS[mood] || MOODS.neutre;

    // Sommeil forcé dans Le Vide (data-vide) ou après 240 s d'inactivité
    const vide = document.documentElement.hasAttribute("data-vide");
    if (state !== "sleep" && (now - lastAct > 240 || vide)) {
      state = "sleep";
      stateT = 0;
    }

    // Source de visèmes (avatar.js) lue dans la MÊME boucle que le rendu (aucune boucle rAF de plus)
    if (visSrc) {
      try {
        const v = visSrc();
        if (v) api.setViseme(v);
      } catch (e) {}
    }

    // Réinitialisation des cibles sans allocation
    for (const k in CH) Tg[k] = CH[k][0];
    const stObj = STATES[state];
    for (const k in stObj) Tg[k] = stObj[k];
    const mdObj = M.d;
    for (const k in mdObj) Tg[k] += mdObj[k];

    // Dans l'état idle, le panda roux garde toujours les yeux grands ouverts (sans paupières lourdes)
    if (red && state === "idle") {
      Tg.lidT = 0;
    }

    const gptr = focus.on ? focus : ptr;
    const ml = life.update(now, state, M, gptr, now - lastAct, redMot);
    const ownGaze = state === "thinking" || state === "tool" || state === "sleep" || state === "reading";
    if (!ownGaze) {
      Tg.gx = ml.gx;
      Tg.gy = ml.gy;
    } else {
      Tg.gx += ml.gx * 0.12;
      Tg.gy += ml.gy * 0.12;
    }
    if (state === "approval" && focus.on) {
      // Contact visuel franc avec la carte (pas de micro-dérive)
      Tg.gx = focus.x;
      Tg.gy = focus.y;
    }
    Tg.hYaw += clamp(Tg.gx, -1, 1) * 0.25 * motScale;
    Tg.hPitch -= clamp(Tg.gy, -1, 1) * 0.12 * motScale;
    Tg.hRoll += ml.tilt * (state === "idle" ? 1 : 0.4) * motScale;
    Tg.earL += ml.flickL * 0.5 * motScale;
    Tg.earR += ml.flickR * 0.5 * motScale;
    // V5-F : micro-mouvements de tête permanents (jamais figé), plus vifs chez le panda roux,
    // et paupière supérieure qui accompagne le regard vers le bas
    if (state !== "sleep") {
      const lf = SP.life, ma = motScale * (state === "speaking" ? 0.6 : 1);
      Tg.hYaw += (0.020 * n1(now * 0.31 * lf + 11) + 0.007 * n1(now * 1.13 * lf + 3)) * ma;
      Tg.hPitch += (0.013 * n1(now * 0.27 * lf + 5) + 0.005 * n1(now * 0.97 * lf + 8)) * ma;
      Tg.hRoll += 0.011 * n1(now * 0.23 * lf + 17) * ma;
      Tg.lidT += Math.max(0, -S.gy.x) * 0.13;
    }

    // Idle : transfert de poids d'une hanche à l'autre toutes les 12 à 20 s
    if (state === "idle" || state === "listening" || state === "reading") {
      if (!weight.next) weight.next = now + rnd(12, 20);
      if (now > weight.next) {
        weight.side = -weight.side;
        weight.next = now + rnd(12, 20);
      }
      Tg.wx = weight.side * 0.016 * motScale;
      Tg.bRoll += weight.side * 0.028 * motScale;
      Tg.hRoll -= weight.side * 0.016 * motScale;
    }

    // Événements de micro-vie (Poisson)
    for (let i = 0; i < life.ev.length; i++) {
      const e = life.ev[i];
      const u = clamp(e.u || 0, 0, 1);
      const env = Math.sin(Math.PI * u);
      if (e.k === "look") {
        Tg.hYaw += 0.42 * e.s * Math.sin(u * Math.PI * 2) * env * motScale;
        Tg.gx = 0.85 * e.s * Math.sin(u * Math.PI * 2);
        Tg.gy = 0.08;
      } else if (e.k === "wave") {
        Tg.hRx = 0.36;
        Tg.hRy = 0.62 + 0.01 * Math.sin(now * 3);
        Tg.hRz = 0.15 + 0.07 * Math.sin(now * 15) * env * motScale;
        Tg.smile = Math.max(Tg.smile, 0.9);
        Tg.hRoll += 0.08 * env * motScale;
      } else if (e.k === "yawn") {
        Tg.jaw = 0.78 * env * env;
        Tg.round = 0.35 * env;
        Tg.lidT = Math.max(Tg.lidT, 0.72 * env);
        Tg.hPitch -= 0.12 * env * motScale;
        Tg.spread = -0.3;
        Tg.smile = 0.12;
        Tg.hLy += 0.06 * env;
        Tg.hRy += 0.06 * env;
      } else if (e.k === "hop") {
        if (!e.done) {
          e.done = 1;
          jump(0.88, 0.12);
        }
        Tg.smile += 0.28 * env;
      } else if (e.k === "wiggle") {
        Tg.bRoll += 0.065 * Math.sin(u * Math.PI * 4) * env * motScale;
        Tg.hRoll -= 0.048 * Math.sin(u * Math.PI * 4) * env * motScale;
      }
    }

    // Réactions ponctuelles (react)
    for (let i = imp.length - 1; i >= 0; i--) {
      const x = imp[i];
      const u = (now - x.t0) / x.d;
      if (u >= 1) {
        imp.splice(i, 1);
        continue;
      }
      if (u < 0) continue;
      const env = Math.sin(Math.PI * u);
      if (x.k === "wave") {
        Tg.hRx = 0.36;
        Tg.hRy = 0.62;
        Tg.hRz = 0.15 + 0.08 * Math.sin(now * 15) * motScale;
        Tg.smile = Math.max(Tg.smile, 0.95);
        Tg.jaw = Math.max(Tg.jaw, 0.24 * env);
      } else if (x.k === "arrival") {
        Tg.perk += 0.95 * env;
        Tg.iris += 0.10 * env;
        Tg.smile += 0.38 * env;
        Tg.jaw = Math.max(Tg.jaw, 0.22 * env);
        Tg.round = Math.max(Tg.round, 0.5 * env);
      } else if (x.k === "nod") {
        // Hochement d'acquiescement doux (écoute active : fin de phrase détectée par le VAD)
        Tg.hPitch += 0.15 * Math.sin(u * Math.PI * 2) * (1 - u) * motScale;
        Tg.smile += 0.22 * env;
        Tg.perk += 0.25 * env;
        Tg.earL += 0.25 * env * motScale;
      } else if (x.k === "validate") {
        // Petite validation : clin d'œil + hochement franc + sourire de Duchenne
        Tg.wink = u > 0.12 && u < 0.62 ? 1 : 0;
        Tg.smile += 0.55 * env;
        Tg.hPitch += 0.13 * Math.sin(u * Math.PI * 2) * (1 - u) * motScale;
        Tg.hRoll += 0.06 * env * motScale;
      } else if (x.k === "surprise") {
        // Barge-in : yeux écarquillés, silence immédiat (bouche fermée en petit « o »)
        Tg.iris = Math.max(Tg.iris, 1.12) + 0.04 * env;
        Tg.lidT = 0;
        Tg.browL += 0.75 * env;
        Tg.browR += 0.75 * env;
        Tg.perk += 0.8 * env;
        Tg.jaw = 0;
        Tg.round = 0.35 * env;
        Tg.press = 0;
        Tg.hPitch -= 0.06 * env * motScale;
      } else if (x.k === "whip") {
        Tg.perk += 0.45 * env;
        Tg.smile += 0.15 * env;
      }
    }

    // Dynamique propre à chaque état
    let lv = 0;
    if (state === "speaking") {
      const fresh = now - vis.t < 0.25;
      if (fresh) {
        // Visèmes mesurés sur le spectre de la voix (avatar.js)
        Tg.jaw = vis.open * 0.92;
        Tg.spread += vis.spread * 0.85;
        Tg.round = vis.round;
        Tg.press = vis.press;
        lv = Math.max(vis.open, vis.spread * 0.6);
      } else if (level > 0.02) {
        // Niveau seul (voix live jouée par le moteur natif : pas de spectre côté web) → mâchoire seule
        Tg.jaw = clamp(level * 1.05, 0, 0.82);
        lv = level;
      } else {
        // Parole sans flux audio mesurable (texte en cours d'écriture) : articulation douce et cyclique
        const c = now * 4.2;
        Tg.jaw = clamp(0.22 + 0.22 * Math.sin(c) * Math.sin(now * 1.7 + 1.2), 0, 0.55);
        Tg.spread += 0.18 * Math.max(0, Math.sin(c * 0.5 + 1.0));
        Tg.round = 0.3 * Math.max(0, Math.sin(c * 0.37 + 2.2));
        Tg.press = Math.max(0, Math.sin(c * 0.61)) > 0.93 ? 0.8 : 0;
        lv = Tg.jaw;
      }
      // Gestes de rythme (beat gestures) sur les pics d'intonation, en alternant les mains
      lvSlow += (lv - lvSlow) * Math.min(1, step * 2.5);
      if (lv - lvSlow > 0.14 && now > beatCool) {
        beatT0 = now;
        beatSide = -beatSide;
        beatCool = now + rnd(0.9, 1.6);
      }
      const bu = (now - beatT0) / 0.8;
      if (bu < 1) {
        const env = Math.sin(Math.PI * bu) * motScale;
        if (beatSide > 0) {
          Tg.hRx += 0.10 * env; Tg.hRy += 0.17 * env; Tg.hRz += 0.07 * env;
        } else {
          Tg.hLx -= 0.10 * env; Tg.hLy += 0.17 * env; Tg.hLz += 0.07 * env;
        }
        Tg.hPitch -= 0.05 * env;
        Tg.browL += 0.18 * env;
        Tg.browR += 0.18 * env;
      }
      // Micro-inclinaisons de tête synchronisées avec la voix
      Tg.hRoll += 0.07 * (lvSlow - 0.2) * beatSide * motScale;
      Tg.hYaw += 0.065 * n1(now * 0.9) * motScale;
      Tg.hPitch -= 0.04 * lv * motScale;
    } else {
      lvSlow *= 0.9;
    }
    if (state === "tool") {
      typing = lerp(typing, 1, 0.12);
      // Les yeux suivent les lignes de l'écran de gauche à droite (retour rapide), ligne après ligne
      const LN = 1.45, lt = stateT % LN, ln = Math.floor(stateT / LN);
      Tg.gx = lt < LN - 0.16 ? -0.5 + 1.0 * (lt / (LN - 0.16)) : 0.5 - 1.0 * ((lt - (LN - 0.16)) / 0.16);
      Tg.gy = -0.6 - 0.06 * (ln % 4);
      // Frappe en rafales rythmiques avec mouvement d'épaules
      const burst = n1(now * 0.9) > -0.2 ? 1 : 0;
      const tap0 = Math.max(0, Math.sin(now * 22)) * 0.016 * burst * motScale;
      const tap1 = Math.max(0, Math.sin(now * 29 + 2)) * 0.016 * burst * motScale;
      Tg.hLy += tap0;
      Tg.hRy += tap1;
      Tg.bRoll += 0.014 * Math.sin(now * 11) * burst * motScale;
      Tg.bYaw += 0.01 * Math.sin(now * 5.5) * burst * motScale;
      G.uScan.value.set(((now * 0.33) % 1) * 2.4 - 1.2, S.glow.x);
      G.uGlowC.value.copy(BLUE).lerp(AMBER, 0.5 + 0.5 * Math.sin(now * 0.45));
    } else {
      typing = lerp(typing, 0, 0.12);
      G.uScan.value.y = S.glow.x * 0.5;
    }
    if (state === "approval") {
      // Se tourne d'environ 15° vers la carte d'approbation et lève la patte de ce côté
      const fx = focus.on ? focus.x : ptr.x * 0.5;
      Tg.bYaw = clamp(fx, -1, 1) * 0.26 * motScale;
      if (fx < -0.12) {
        Tg.hLx = -0.34; Tg.hLy = 0.61; Tg.hLz = 0.17;
        Tg.hRx = 0.20; Tg.hRy = 0.28; Tg.hRz = 0.21;
      }
      const p = 0.5 + 0.5 * Math.sin(stateT * 3.2);
      if (fx < -0.12) Tg.hLy += 0.024 * p * motScale;
      else Tg.hRy += 0.024 * p * motScale;
      Tg.iris += 0.03 * p;
    }
    if (state === "error") {
      // Poings serrés qui battent la mesure, puis hochement affirmatif « on reprend »
      const p = Math.max(0, Math.sin(stateT * 5.0)) * (stateT < 1.6 ? 1 : 0.3);
      Tg.hLy += 0.026 * p * motScale;
      Tg.hRy += 0.026 * p * motScale;
      if (stateT > 1.7 && stateT < 2.6) {
        const u = (stateT - 1.7) / 0.9;
        Tg.hPitch += 0.17 * Math.sin(u * Math.PI * 2) * (1 - u) * motScale;
        Tg.smile += 0.25;
        Tg.press = 0.2;
      }
    }
    if (state === "thinking") {
      // Balayage des yeux d'un « dossier mental » à l'autre (saccades), tapotement d'index toutes les 2,5 s
      const SEQ = [-0.55, -0.15, 0.32, 0.6, 0.18, -0.38];
      const k = Math.floor(stateT / 1.05);
      Tg.gx = SEQ[k % SEQ.length];
      Tg.gy = 0.55 + 0.12 * Math.sin(k * 1.7);
      const tp = stateT % 2.5;
      if (tp < 0.45) {
        const w = Math.sin((tp / 0.45) * Math.PI * 3);
        Tg.hRy += 0.02 * Math.max(0, w) * motScale;
        Tg.hRz += 0.01 * w * motScale;
      }
      Tg.hRoll += 0.04 * n1(now * 0.5) * motScale;
    }
    if (state === "reading") {
      // Le regard suit le défilement réel du module lu (cible posée par companion.js)
      const LN = 2.1, lt = stateT % LN;
      const fy = focus.on ? focus.y : -0.3;
      Tg.gx = (focus.on ? focus.x * 0.35 : 0) + (lt < LN - 0.2 ? -0.42 + 0.84 * (lt / (LN - 0.2)) : 0.42 - 0.84 * ((lt - LN + 0.2) / 0.2));
      Tg.gy = clamp(fy, -0.9, 0.5);
      Tg.hPitch -= clamp(fy, -1, 1) * 0.10 * motScale;
      Tg.hYaw += (focus.on ? focus.x * 0.16 : 0) * motScale;
    }
    // Retours automatiques : done (≈ 2,4 s), célébration majeure (≈ 3,1 s)
    if (state === "done" && stateT > 2.4) api.setState("idle");
    if (state === "celebrate" && stateT > 3.1) api.setState("idle");

    // Sauts balistiques avec anticipation et squash & stretch à l'atterrissage
    for (let i = jumps.length - 1; i >= 0; i--) {
      if (now >= jumps[i].t) {
        hopV = Math.max(hopV, jumps[i].v);
        S.sq.v += 2.5 * jumps[i].v;
        jumps.splice(i, 1);
      }
    }

    // Le cou suit avec retard la vitesse verticale (tête « lourde » au rebond)
    Tg.nk = clamp(-prevVy * 0.03, -0.028, 0.028) * motScale;

    // Intégration en sous-pas des ressorts amortis
    const subSteps = Math.max(1, Math.ceil(step / (1 / 90)));
    const h = step / subSteps;
    for (let i = 0; i < subSteps; i++) {
      if (hopY > 0 || hopV > 0) {
        hopV -= 7.5 * h;
        hopY += hopV * h;
        if (hopY <= 0) {
          hopY = 0;
          S.sq.v += hopV * 3.1;
          S.earL.v += hopV * 1.9;
          S.earR.v += hopV * 1.9;
          hopV = 0;
        }
      }
      for (const k in S) {
        S[k].t = Tg[k];
        S[k].step(h);
      }
    }

    // Flottement doux par bruit multi-couches
    const amp = motScale * (state === "sleep" ? 0.5 : 1.0);
    const fy = S.fh.x + amp * (0.026 * n1(now * 0.42) + 0.011 * n1(now * 1.07 + 3.1) + 0.005 * n1(now * 2.3 + 7));
    const y = fy + hopY;
    const vy = (y - prevY) / Math.max(step, 1e-3);
    const ay = (vy - prevVy) / Math.max(step, 1e-3);
    prevY = y;
    prevVy = vy;

    S.sq.t = clamp(vy * 0.22, -0.06, 0.12) * motScale;
    S.earL.v -= (clamp(ay, -40, 40) * 0.004 + S.hRoll.v * 0.5 - S.hYaw.v * 0.35 + S.hPitch.v * 0.3) * motScale;
    S.earR.v -= (clamp(ay, -40, 40) * 0.004 - S.hRoll.v * 0.5 + S.hYaw.v * 0.35 + S.hPitch.v * 0.3) * motScale;
    S.tail.v += (S.bRoll.v * 1.5 - vy * 0.6) * step * 6 * motScale;

    // Respiration déphasée thorax / ventre (souffle court juste après une erreur)
    const brRate = SP.breath * (state === "sleep" ? 0.6 : state === "error" && stateT < 1.6 ? 2.2 : 1);
    phi += step * 2 * Math.PI * brRate * (1 + 0.15 * n1(now * 0.05));
    const chest = Math.sin(phi) * motScale;
    const belly = Math.sin(phi - 1.15) * motScale;
    const br = chest;

    // Application de la pose au rig 3D
    const sq = S.sq.x;
    const gr = 1 + (S.grow.x - 1) * motScale;
    root.position.set(0.012 * n1(now * 0.21 + 4) * amp + S.wx.x, y, 0);
    root.scale.set(gr / Math.sqrt(1 + sq), gr * (1 + sq), gr / Math.sqrt(1 + sq));
    root.rotation.z = 0.024 * n1(now * 0.31 + 2) * amp;

    // Pirouette de la célébration majeure (un tour complet en l'air, amorti)
    const su = clamp((now - spinT0) / 0.95, 0, 1);
    const spin = su > 0 && su < 1 ? (1 - Math.pow(1 - su, 3)) * Math.PI * 2 * motScale : 0;
    body.rotation.set(S.bPitch.x, S.bYaw.x + spin, S.bRoll.x);
    // V5-F : respiration par déformation locale (poitrine puis ventre), plus de mise à l'échelle globale
    bodyMat.uniforms.uDefA.value.set(0.0085 * (chest * 0.5 + 0.5) * gr, 0.0115 * (belly * 0.5 + 0.5) * gr, 0, 0);
    headG.position.y = 0.70 + 0.007 * chest + S.nk.x;
    headG.rotation.set(S.hPitch.x - 0.012 * br, S.hYaw.x, S.hRoll.x);

    // Sourcils expressifs (asymétrie possible : gauche / droite indépendants)
    for (let i = 0; i < 2; i++) {
      const b = brows[i];
      const brRaise = i === 0 ? S.browL.x : S.browR.x;
      b.g.position.y = b.baseY + 0.017 * brRaise;
      b.g.rotation.z = -b.s * (0.08 - 0.22 * S.lidTilt.x + 0.14 * brRaise);
    }

    // Oreilles avec suivi (follow-through)
    const perk = S.perk.x;
    for (let i = 0; i < 2; i++) {
      const e = ears[i];
      const fl = i ? S.earR.x : S.earL.x;
      e.g.rotation.z = -e.s * ((red ? 0.48 : 0.55) - 0.12 * perk) + fl * 0.35 * e.s;
      e.g.rotation.x = -0.15 - 0.12 * perk + fl * 0.12;
      e.g.scale.setScalar(1 + 0.05 * perk);
    }

    // Couplage de Duchenne : un vrai sourire remonte les pommettes, plisse la paupière inférieure,
    // dilate un peu la pupille
    const sm = S.smile.x;
    const duch = sstep(0.4, 0.75, sm) * (state === "sleep" ? 0 : 1);
    const lidB = clamp(S.lidB.x + sm * 0.32 * duch, 0, 1);
    const irisK = S.iris.x + 0.06 * duch;
    // Joues : volume qui se gonfle et remonte avec le sourire (déformation de la tête)
    headMat.uniforms.uDefA.value.set((0.011 * duch + 0.0035 * clamp(sm, 0, 1.2)) * gr, 0.008 * duch * gr, 0, 0);
    for (let i = 0; i < cheekIdx.length; i++) {
      const j = cheekIdx[i], b = cheekBase[i];
      const c = headMat.uniforms.uMC.value[j];
      c.copy(b.c);
      c.y += 0.075 * duch;
      const l = Math.hypot(c.x, c.y, c.z) || 1;
      c.x /= l; c.y /= l; c.z /= l;
      const r = headMat.uniforms.uMR.value[j];
      r.x = b.r.x * (1 + 0.16 * duch);
      r.y = b.r.y * (1 + 0.22 * duch);
      headMat.uniforms.uMK.value[j].w = Math.min(1, b.a * (1 + 0.5 * duch));
    }

    // Yeux et paupières (clin d'œil sur l'œil gauche du compagnon)
    const blink = ml.lid;
    for (let i = 0; i < 2; i++) {
      const e = eyes[i];
      e.u.uGaze.value.set(clamp(S.gx.x, -1, 1), clamp(S.gy.x, -1, 1));
      e.u.uTop.value = clamp(S.lidT.x + blink, 0, 1);
      e.u.uBot.value = lidB;
      e.u.uTilt.value = S.lidTilt.x;
      e.u.uIris.value = irisK;
      e.u.uHappy.value = i === 1 ? Math.max(S.happy.x, S.wink.x) : S.happy.x;
    }

    // Bouche : 4 canaux articulés
    muzMat.uniforms.uMouth.value.set(clamp(S.jaw.x, 0, 1), clamp(sm, -1, 1.4), clamp(S.spread.x, -0.6, 1), clamp(S.round.x, 0, 1));
    muzMat.uniforms.uMouth2.value.x = clamp(S.press.x, 0, 1);
    const rdk = clamp(S.round.x, 0, 1);
    muzM.scale.set(0.156 * (1 - 0.10 * rdk + 0.05 * clamp(S.spread.x, 0, 1)), 0.112 * (1 + 0.04 * clamp(S.jaw.x, 0, 1)), 0.086 * (1 + 0.16 * rdk));

    // Bras orientés vers leurs cibles avec arcs naturels
    const fist = S.fist.x;
    for (let i = 0; i < 2; i++) {
      const a = arms[i];
      if (i === 0) _tgt.set(S.hLx.x, S.hLy.x, S.hLz.x);
      else _tgt.set(S.hRx.x, S.hRy.x, S.hRz.x);
      if (state === "idle" || state === "sleep") _tgt.y += 0.011 * n1(now * 0.6 + i * 5) * amp;
      _tgt.y -= 0.012 * chest * amp;
      _v.copy(_tgt).sub(SH[i]);
      const dist = clamp(_v.length(), 0.12, 0.27);
      _v.normalize();
      _q.setFromUnitVectors(_down, _v);
      a.g.quaternion.copy(_q);
      a.a.position.y = -dist / 2;
      a.a.scale.y = (dist / 0.12) * 0.62 + 0.38;
      a.p.position.y = -dist;
      a.p.scale.set(0.076 * (1 + 0.08 * fist), 0.070 * (1 - 0.12 * fist), 0.074 * (1 + 0.10 * fist));
    }

    // Jambes (la jambe d'appui se tend pendant le transfert de poids) et queue annelée
    const ws = clamp(S.wx.x / 0.016, -1, 1);
    for (let i = 0; i < 2; i++) {
      const sd = i ? 1 : -1;
      legs[i].rotation.x = 0.22 + 0.09 * n1(now * 0.7 + i * 3) * amp - 0.25 * S.legs.x * (i ? 1 : 0.7) + 0.06 * ws * sd;
      legs[i].rotation.z = sd * (0.10 + 0.08 * S.legs.x);
    }
    // Queue du panda roux : onde sinusoïdale continue sur 7 segments, fouet à chaque arrivée,
    // tourbillon pendant la pirouette de célébration
    const wu = (now - whipT0) / 0.95;
    const whip = wu > 0 && wu < 1 ? Math.sin(Math.PI * wu) : 0;
    const lifeAmp = amp * (red ? 1 : 0.6);
    for (let i = 0; i < tail.length; i++) {
      const wave = Math.sin(now * (1.7 + 7.5 * whip) - i * 0.78);
      tail[i].rotation.z = (i ? 0.2 : 0) + S.tail.x * 0.06 * (i + 1) + lifeAmp * (0.085 + 0.26 * whip) * wave * (0.45 + i * 0.13);
      tail[i].rotation.x = (i ? -0.05 : 0) + 0.05 * Math.sin(now * 1.1 - i * 0.6) * lifeAmp;
    }
    if (tailRoot) tailRoot.rotation.y = spin * 0.5;

    // Accessoires par mise à l'échelle avec rebond
    phones.visible = S.phones.x > 0.02;
    phones.scale.setScalar(Math.max(0.001, S.phones.x));
    laptop.visible = S.laptop.x > 0.02;
    laptop.scale.setScalar(Math.max(0.001, S.laptop.x));
    const gl = S.glasses.x;
    glasses.visible = gl > 0.02;
    glasses.scale.setScalar(Math.max(0.001, 0.6 + 0.4 * clamp(gl, 0, 1.3)));
    glasses.position.y = (1 - clamp(gl, 0, 1)) * 0.16;
    G.uGlow.value = S.glow.x * (0.82 + 0.18 * n1(now * 3.0) * typing);

    headG.getWorldPosition(_hw);
    const ob = S.orbs.x;
    for (let i = 0; i < bubbles.length; i++) {
      const b = bubbles[i];
      const k = clamp(ob * 3 - i * 0.9, 0, 1);
      b.visible = k > 0.02;
      const bob = 0.012 * Math.sin(now * 2 + i * 1.7) * motScale;
      b.position.set(_hw.x + 0.36 + i * 0.10, _hw.y + 0.22 + i * 0.12 + bob, 0.10);
      const z = (i === 0 ? 0.07 : i === 1 ? 0.11 : 0.19) * k * gr;
      b.scale.set(z, z, 1);
    }

    const sp = S.spark.x;
    for (let i = 0; i < sparks.length; i++) {
      const b = sparks[i];
      const a = (i / sparks.length) * Math.PI * 2 + 0.4;
      const ph = (now * 0.8 + i * 0.37) % 1;
      const rad = 0.50 + 0.14 * ph;
      b.visible = sp > 0.02;
      const tw = Math.sin(ph * Math.PI);
      const z = 0.17 * sp * tw * (i % 2 ? 0.72 : 1);
      b.scale.set(z, z, 1);
      b.position.set(_hw.x + Math.cos(a) * rad * 1.05, _hw.y - 0.05 + Math.sin(a) * rad * 0.9, 0.25);
      b.material.rotation = now * (i % 2 ? 1 : -1);
    }

    const zz = S.zzz.x;
    for (let i = 0; i < zs.length; i++) {
      const b = zs[i];
      const ph = (now * 0.32 + i / 3) % 1;
      b.visible = zz > 0.02;
      const z = (0.06 + 0.07 * ph) * zz * Math.sin(Math.PI * Math.min(1, ph * 1.3));
      b.scale.set(z, z, 1);
      b.position.set(_hw.x + 0.30 + ph * 0.18 + 0.03 * Math.sin(ph * 9) * motScale, _hw.y + 0.20 + ph * 0.32, 0.10);
      b.material.opacity = 1 - ph * 0.6;
    }

    // Ombre de contact elliptique dont la taille et l'opacité suivent la hauteur
    const lift = clamp((y - 0.03) / 0.25, 0, 1);
    const shw = (0.62 - 0.20 * lift) * gr;
    shadow.scale.set(shw, shw * 0.55, 1);
    shadow.material.opacity = 0.82 - 0.45 * lift;
    shadow.position.set(root.position.x, 0, 0.02);
    const shw2 = (0.34 - 0.14 * lift) * gr;
    shadow2.scale.set(shw2, shw2 * 0.42, 1);
    shadow2.material.opacity = 0.62 * (1 - lift) * (1 - lift);
    shadow2.position.set(root.position.x, 0.001, 0.07);

    const gw = (0.78 - 0.15 * lift) * gr;
    glowSpr.scale.set(gw, gw * 0.45, 1);
    glowSpr.material.opacity = 0.13 + 0.05 * Math.sin(now * 1.3);
    glowSpr.position.x = root.position.x;

    // V5-F : matrices monde à jour → primitives d'union lisse, oreilles souples, tube de queue
    scene.updateMatrixWorld();
    for (let j = 0; j < NP; j++) {
      const pr = prims[j];
      if (!pr) continue;
      const M = pr.obj.matrixWorld, e = M.elements;
      const sx = Math.hypot(e[0], e[1], e[2]), sy = Math.hypot(e[4], e[5], e[6]), sz = Math.hypot(e[8], e[9], e[10]);
      const PM = PRIM_U.uPM.value[j];
      _m4.copy(M).invert();
      PM.makeScale(sx, sy, sz).multiply(_m4);
      PRIM_U.uPR.value[j].set(pr.r[0] * sx, pr.r[1] * sy, pr.r[2] * sz, pr.h * sy);
    }
    const ew = red ? 17 : 13.5, ez = red ? 0.30 : 0.42;
    const sub = Math.max(1, Math.ceil(step / (1 / 120))), eh = step / sub;
    for (let i = 0; i < 2; i++) {
      const e = ears[i];
      e.m.localToWorld(_tip.set(0, 0.95, 0));
      if (!e.init) { e.pos.copy(_tip); e.vel.set(0, 0, 0); e.init = true; }
      for (let k = 0; k < sub; k++) {
        _v.copy(_tip).sub(e.pos).multiplyScalar(ew * ew).addScaledVector(e.vel, -2 * ez * ew);
        e.vel.addScaledVector(_v, eh);
        e.pos.addScaledVector(e.vel, eh);
      }
      _v.copy(e.pos).sub(_tip);
      const L = _v.length(), lim = 0.032 * gr;
      if (L > lim) _v.multiplyScalar(lim / L);
      e.mat.uniforms.uDefA.value.set(_v.x * motScale, _v.y * motScale, _v.z * motScale, 0);
    }
    if (tailTube) updateTailTube(gr);

    // Éclairage clé modulé par l'état et l'humeur
    const key = state === "done" || state === "celebrate" ? [1.08, 1.0, 0.90] : M.key;
    G.uKey.value.set(key[0], key[1], key[2]);

    // Cadrage caméra adaptatif : léger recul quand les bras/accessoires s'élèvent (rien n'est rogné)
    const pull = state === "celebrate" ? 2.0 : state === "done" ? 1.6 : state === "thinking" || state === "approval" ? 1.0 : state === "sleep" ? 0.5 : 0;
    camK += (pull - camK) * Math.min(1, step * 4);
    const fov = 25;
    const dist = 3.62 * (1 + 0.10 * camK);   // 24/10 : recul de base — oreilles jamais rognées au repos
    cam.fov = cam.aspect < 1 ? (2 * Math.atan(Math.tan((fov * Math.PI) / 360) / cam.aspect) * 180) / Math.PI : fov;
    cam.position.set(0, 0.76 + 0.05 * camK, dist);
    cam.lookAt(0, 0.62 + 0.05 * camK, 0);
    cam.updateProjectionMatrix();
  }

  // Image par image, appelée par l'horloge PARTAGÉE (une seule boucle rAF pour tous les compagnons)
  function frame(now) {
    if (dead) return;
    // Pause totale hors écran ou onglet caché
    if (!visible || document.hidden) {
      last = now;
      acc = 0;
      return;
    }
    const active =
      state === "speaking" ||
      state === "tool" ||
      state === "done" ||
      state === "celebrate" ||
      hopY > 0 ||
      jumps.length > 0 ||
      imp.length > 0 ||
      life.ev.length > 0 ||
      Math.abs(S.sq.v) > 0.08 ||
      Math.abs(S.hRx.v) + Math.abs(S.hRy.v) > 0.05;
    /* 29/10 (fluidité) : repos partagé (html[data-idle], 10 s sans geste — shell.js) → 15 i/s au lieu de 30
       (sommeil 6) tant qu'aucune animation propre ne tourne ; pleine cadence au premier geste ou changement d'état. */
    const idleUi = !active && document.documentElement.dataset.idle === "1";
    const fps = state === "sleep" ? (idleUi ? 6 : 10) : active ? 60 : idleUi ? 15 : 30;
    acc += now - last;
    last = now;
    if (acc < 1 / fps - 0.002) return;
    const step = Math.min(acc, 0.1);
    acc = 0;
    update(now, step);
    renderer.render(scene, cam);
  }

  const api = {
    setState(st) {
      if (dead || !STATES[st]) return;
      if (!document.documentElement.hasAttribute("data-vide")) {
        lastAct = performance.now() / 1000;
      }
      if (st !== state) {
        const prev = state;
        state = st;
        stateT = 0;
        clearTimeout(doneHopTimer);
        const k = isReducedMotion() ? 0.2 : 1;
        if (st === "done") {
          // Rebond élastique : anticipation (squash) → envol (stretch) → amorti à la réception
          camK = Math.max(camK, 1.6);
          jump(1.15, 0.14);
          doneHopTimer = setTimeout(() => {
            if (!dead && state === "done") jump(0.8, 0.10);
          }, 900);
          S.grow.v += 0.8 * k;
        }
        if (st === "celebrate") {
          camK = Math.max(camK, 2.0);
          jump(1.55, 0.16);
          spinT0 = performance.now() / 1000 + 0.24;
          whipT0 = spinT0;
          doneHopTimer = setTimeout(() => {
            if (!dead && state === "celebrate") jump(0.9, 0.08);
          }, 1350);
          S.grow.v += 1.1 * k;
        }
        if (st === "error") {
          // Redressement net du buste (jamais d'affaissement)
          S.bPitch.v -= 0.6 * k;
          S.sq.v += 0.5 * k;
        }
        if (st === "approval") {
          jump(0.58, 0.08);
        }
        if (st === "reading") {
          S.glasses.v += 2.0 * k;
        }
        if (prev === "sleep") {
          S.perk.v += 5.5 * k;
          S.lidT.v -= 2.0;
        }
      }
    },
    setMood(m) {
      if (!dead && MOODS[m]) mood = m;
    },
    setLevel(v) {
      level = clamp(+v || 0, 0, 1);
    },
    // Visème mesuré : { open, spread, round, press } dans [0, 1]
    setViseme(v) {
      if (dead || !v) return;
      vis.open = clamp(+v.open || 0, 0, 1);
      vis.spread = clamp(+v.spread || 0, 0, 1);
      vis.round = clamp(+v.round || 0, 0, 1);
      vis.press = clamp(+v.press || 0, 0, 1);
      vis.t = performance.now() / 1000;
    },
    // Source de visèmes appelée à chaque image (null pour retirer) — évite toute boucle supplémentaire
    setVisemeSource(fn) {
      visSrc = typeof fn === "function" ? fn : null;
    },
    lookAt(x, y) {
      ptr.x = clamp(+x || 0, -1, 1);
      ptr.y = clamp(+y || 0, -1, 1);
    },
    // Cible d'intérêt prioritaire sur le curseur (carte d'approbation, texte lu) ; null = relâcher
    setFocus(x, y) {
      if (x == null) {
        focus.on = false;
        return;
      }
      focus.on = true;
      focus.x = clamp(+x || 0, -1, 1);
      focus.y = clamp(+y || 0, -1, 1);
    },
    react(kind) {
      if (dead) return;
      const now = performance.now() / 1000;
      if (!document.documentElement.hasAttribute("data-vide")) {
        lastAct = now;
        if (state === "sleep" && kind !== "nod") api.setState("idle");
      }
      if (kind === "validate") {
        imp.push({ k: "validate", t0: now, d: 1.25 });
        jump(0.6, 0.12);
      } else if (kind === "wave") {
        imp.push({ k: "wave", t0: now, d: 1.75 });
      } else if (kind === "nod") {
        imp.push({ k: "nod", t0: now, d: 0.85 });
      } else if (kind === "arrival") {
        imp.push({ k: "arrival", t0: now, d: 1.25 });
        jump(0.95, 0.10);
        whipT0 = now;
      } else if (kind === "whip") {
        imp.push({ k: "whip", t0: now, d: 0.95 });
        whipT0 = now;
      } else if (kind === "surprise") {
        imp.push({ k: "surprise", t0: now, d: 0.9 });
        vis.t = -10;
        level = 0;
        S.jaw.x *= 0.2;
        S.iris.v += 2.5;
      }
    },
    setTheme() {
      if (!dead) applyTheme();
    },
    get state() {
      return state;
    },
    get species() {
      return red ? "renard" : "panda";
    },
    snapshot() {
      if (dead) return "";
      renderer.render(scene, cam);
      return cv.toDataURL("image/png");
    },
    destroy() {
      if (dead) return;
      dead = true;
      TICKER.subs.delete(frame);
      clearTimeout(doneHopTimer);
      clearTimeout(themeTimer);
      io.disconnect();
      ro.disconnect();
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("nova:theme", onTheme);
      for (let i = 0; i < mats.length; i++) mats[i].dispose();
      for (let i = 0; i < geos.length; i++) geos[i].dispose();
      for (let i = 0; i < texList.length; i++) texList[i].dispose();
      renderer.dispose();
      try {
        const ext = renderer.getContext().getExtension("WEBGL_lose_context");
        if (ext) ext.loseContext();
      } catch (e) {}
      cv.remove();
    },
  };

  const onMove = (e) => {
    if (dead) return;
    const b = host.getBoundingClientRect();
    if (!b.width) return;
    api.lookAt(
      (e.clientX - (b.left + b.width / 2)) / Math.max(320, window.innerWidth * 0.5),
      -(e.clientY - (b.top + b.height * 0.35)) / Math.max(240, window.innerHeight * 0.5)
    );
    // Dans Le Vide (data-vide), le compagnon dort et ne se réveille pas au mouvement de la souris
    if (document.documentElement.hasAttribute("data-vide")) return;
    lastAct = performance.now() / 1000;
    if (state === "sleep") api.setState("idle");
  };

  const onTheme = () => {
    clearTimeout(themeTimer);
    themeTimer = setTimeout(() => {
      if (!dead) applyTheme();
    }, 50);
  };

  window.addEventListener("pointermove", onMove, { passive: true });
  window.addEventListener("nova:theme", onTheme);

  resize();
  update(performance.now() / 1000, 1 / 30);
  renderer.render(scene, cam);
  TICKER.add(frame);
  return api;
}
