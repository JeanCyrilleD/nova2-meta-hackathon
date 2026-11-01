// V21 — Dots en peluche : personnages originaux (corps duveteux, grands yeux, accessoire qui dit le métier).
// Dessinés en SVG (texture de fourrure par filtre), animés en CSS : respiration, clignement, saut quand il travaille, salut quand il est prêt.
// NOVA2 (vague 2, item 5) : porté tel quel depuis Nova 1 (web/plush.js) ; les animations CSS vivent
// dans css/nova2.css (section « Peluches »), conformément à la règle du fichier CSS unique.
let UID = 0;
const clamp = (x) => Math.max(0, Math.min(255, Math.round(x)));
function rgb(hex) { const m = /^#?([0-9a-f]{6})$/i.exec(hex || ""); const n = m ? parseInt(m[1], 16) : 0xd93226; return [n >> 16, (n >> 8) & 255, n & 255]; }
const mix = (c, t, k) => "#" + c.map((v, i) => clamp(v + (t[i] - v) * k).toString(16).padStart(2, "0")).join("");
const light = (hex, k) => mix(rgb(hex), [255, 255, 255], k), dark = (hex, k) => mix(rgb(hex), [20, 10, 30], k);

export const PERSONAS = ["#D93226", "#FF7A29", "#FF8A1F", "#5EA8FF", "#8FC2FF", "#9FB2D6"];
export function snapPersona(hex) { const [r, g, b] = rgb(hex); let best = PERSONAS[0], bd = Infinity; for (const p of PERSONAS) { const [pr, pg, pb] = rgb(p); const d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2; if (d < bd) { bd = d; best = p; } } return best; }
const SPEC = {
  chercheur: ["blob", "headphones"], analytics: ["pear", "sprout"], contenu: ["bean", "pocket"], social: ["blob", "scarf"], code: ["blob", "glasses"],
  projet: ["bean", "cap"], ops: ["pear", "antenna"], courrier: ["blob", "scarf"], redacteur: ["bean", "glasses"], agenda: ["pear", "sprout"],
  veille: ["blob", "antenna"], brvm: ["pear", "headphones"], mac: ["bean", "antenna"], bilan: ["blob", "cap"],
};
const ACC = ["headphones", "sprout", "pocket", "scarf", "glasses", "cap", "antenna"], SHP = ["blob", "pear", "bean"];
function specFor(id) { if (SPEC[id]) return SPEC[id]; let n = 0; for (const c of String(id)) n = (n * 31 + c.charCodeAt(0)) >>> 0; return [SHP[n % SHP.length], ACC[(n >> 3) % ACC.length]]; }

function body(shape, fill) {
  if (shape === "pear") return `<path d="M60 22C46 22 40 34 42 46C28 54 20 66 24 82C28 98 44 104 60 104C76 104 92 98 96 82C100 66 92 54 78 46C80 34 74 22 60 22Z" fill="${fill}"/>`;
  if (shape === "bean") return `<path d="M60 18C40 18 30 38 32 62C34 90 44 106 62 106C80 106 90 90 90 64C90 38 78 18 60 18Z" fill="${fill}"/>`;
  if (shape === "star") return `<ellipse cx="60" cy="66" rx="40" ry="38" fill="${fill}"/><ellipse cx="60" cy="66" rx="49" ry="15" fill="none" stroke="${fill}" stroke-width="3" opacity=".55" transform="rotate(-18 60 66)"/>`;
  return `<ellipse cx="60" cy="66" rx="40" ry="38" fill="${fill}"/>`;
}
function acc(a, c) {
  const cream = "#f3e3c8", cd = "#d9c3a0";
  switch (a) {
    case "headphones": return `<path d="M26 62C24 30 44 18 60 18C76 18 96 30 94 62" fill="none" stroke="${cream}" stroke-width="7" stroke-linecap="round"/><rect x="16" y="54" width="16" height="26" rx="8" fill="${cream}" stroke="${cd}" stroke-width="2"/><rect x="88" y="54" width="16" height="26" rx="8" fill="${cream}" stroke="${cd}" stroke-width="2"/>`;
    case "sprout": return `<g opacity=".8"><path d="M60 26C58 14 50 8 40 8C42 20 50 26 60 26Z" fill="#35E0A1"/><path d="M60 26C62 12 72 6 84 8C80 22 70 28 60 26Z" fill="#35E0A1"/><path d="M60 28V22" stroke="#35E0A1" stroke-width="3" stroke-linecap="round"/></g>`;
    case "pocket": return `<path d="M42 82H78V96Q78 102 72 102H48Q42 102 42 96Z" fill="${light(c, .25)}" stroke="${dark(c, .35)}" stroke-width="1.5"/><path d="M45 86H75" stroke="${dark(c, .45)}" stroke-width="1.6" stroke-dasharray="3 3"/>`;
    case "scarf": return `<path d="M30 78Q60 94 90 78L92 88Q60 104 28 88Z" fill="#D93226"/><path d="M76 90L84 112L72 108Z" fill="${dark("#D93226", .25)}"/><path d="M34 84Q60 96 86 84" stroke="rgba(255,255,255,.5)" stroke-width="1.5" stroke-dasharray="3 3" fill="none"/>`;
    case "glasses": return `<circle cx="44" cy="58" r="12" fill="rgba(255,255,255,.18)" stroke="#1f2937" stroke-width="3"/><circle cx="76" cy="58" r="12" fill="rgba(255,255,255,.18)" stroke="#1f2937" stroke-width="3"/><path d="M56 58H64" stroke="#1f2937" stroke-width="3"/>`;
    case "cap": return `<path d="M30 40C34 18 86 18 90 40Z" fill="#FFC38F"/><rect x="26" y="38" width="68" height="7" rx="3.5" fill="#FF7A29"/><circle cx="60" cy="19" r="4" fill="#FFF6EC"/>`;
    case "antenna": return `<path d="M60 28V10" stroke="#475569" stroke-width="3" stroke-linecap="round"/><circle cx="60" cy="8" r="6" fill="#FFC38F" stroke="#C24E12" stroke-width="1.5"/>`;
    default: return "";
  }
}

export function plushSVG({ id = "dot", color = "#D93226", emoji = "" } = {}) {
  const u = "pl" + ++UID, [shape, a] = specFor(id);
  color = snapPersona(color);
  const fill = `url(#${u}g)`;
  return `<svg class="plush" viewBox="0 0 120 124" aria-hidden="true">
  <defs>
    <radialGradient id="${u}g" cx="38%" cy="28%" r="85%"><stop offset="0" stop-color="${light(color, .5)}"/><stop offset=".55" stop-color="${color}"/><stop offset="1" stop-color="${dark(color, .38)}"/></radialGradient>
    <filter id="${u}f" x="-10%" y="-10%" width="120%" height="120%" color-interpolation-filters="sRGB">
      <feTurbulence type="fractalNoise" baseFrequency=".85" numOctaves="2" seed="${(UID * 7) % 90}" result="n"/>
      <feDisplacementMap in="SourceGraphic" in2="n" scale="3.2" xChannelSelector="R" yChannelSelector="G" result="d"/>
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 1.2 -.42" result="fl"/>
      <feComposite in="fl" in2="d" operator="in" result="fur"/>
      <feBlend in="d" in2="fur" mode="soft-light"/>
    </filter>
  </defs>
  <ellipse class="pl-sh" cx="60" cy="114" rx="30" ry="5" fill="rgba(0,0,0,.35)"/>
  <g class="pl-body">
    <g filter="url(#${u}f)">${body(shape, fill)}</g>
    <ellipse cx="46" cy="40" rx="13" ry="7" fill="rgba(255,255,255,.28)" transform="rotate(-24 46 40)"/>
    ${acc(a, color)}
    <g class="pl-face">
      <g class="pl-eyes"><ellipse cx="46" cy="62" rx="6.2" ry="7.6" fill="#1b1222"/><ellipse cx="74" cy="62" rx="6.2" ry="7.6" fill="#1b1222"/><circle cx="48.2" cy="59" r="2.3" fill="#fff"/><circle cx="76.2" cy="59" r="2.3" fill="#fff"/><circle cx="44.4" cy="65" r="1" fill="#fff" opacity=".7"/><circle cx="72.4" cy="65" r="1" fill="#fff" opacity=".7"/></g>
      <path class="pl-mouth" d="M53 74Q60 81 67 74" fill="none" stroke="#1b1222" stroke-width="2.6" stroke-linecap="round"/>
      <ellipse cx="36" cy="73" rx="5" ry="3" fill="#FF8A1F" opacity=".3"/><ellipse cx="84" cy="73" rx="5" ry="3" fill="#FF8A1F" opacity=".3"/>
    </g>
  </g></svg>`;
}

/** Monte le Dot en peluche dans `host` ; même contrat que l'ancien orbe 3D (setPhase / setMood / dispose).
 *  FUSION DOTS (22/10, audit §5) — la double rupture est réparée ici :
 *  1) `data-phase` vit sur le SVG `.plush` LUI-MÊME — c'est là que les sélecteurs
 *     CSS le lisent (.plush[data-phase="…"] .pl-body) ; avant, il était posé sur
 *     le conteneur .plushwrap, qu'aucune règle ne regardait.
 *  2) UN SEUL vocabulaire d'état, celui du CSS : repos / actif / attente /
 *     erreur / pause. Le JS ne produit que ces cinq valeurs ; les phases du
 *     bus moteur (working / ready / idle) sont TRADUITES par les écrans avant
 *     d'appeler setPhase — jamais posées telles quelles. */
export function mountPlush(host, color, size = 96, id = "dot", emoji = "") {
  const w = document.createElement("div"); w.className = "plushwrap"; w.style.width = w.style.height = size + "px"; w.innerHTML = plushSVG({ id, color, emoji });
  host.append(w);
  const svg = w.querySelector("svg.plush") || w;
  svg.dataset.phase = "repos";
  return { el: w, setPhase: (p) => { svg.dataset.phase = p; }, setMood: (m) => { w.dataset.mood = m; }, dispose: () => w.remove() };
}
