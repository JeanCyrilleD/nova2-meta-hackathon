/* Icônes 3D « Promesse » (studio d'icônes, 30/10/2026).
   Rendus three.js hors ligne (émail, verre liquide, métal brossé ; clé haut-gauche,
   contre-jour indigo, ombre de contact) → web/assets/identite/icons3d/<id>.png (128 px)
   et <id>@56.png (2× d'une tuile de 28 px).
   Utilisation : ico3dImg(id) renvoie la balise <img class="ico3d"> à poser dans la
   tuile .ri du rail ; elle n'est visible que si html[data-identite] est posé (Promesse
   active). Sinon l'icône Phosphor d'origine reste affichée (repli). */

const BASE = new URL("../assets/identite/icons3d/", import.meta.url).href;

/* id de page (MODULES de shell.js) ou d'action → fichier */
export const ICONS3D_IDS = [
  "accueil", "conversations", "attente",
  "messages", "veille", "temps", "reunions", "engagements", "dossiers", "relations",
  "dots", "conseil", "livrables", "studio",
  "finance", "fundings", "vie", "savoir", "journal", "ame",
  "controle", "confiance", "outils", "systeme", "radio",
  "settings", "vault",
  /* actions */
  "send", "mic", "attach", "search", "new", "marque",
];
const ALIAS = { automatisations: "dots", agent: "conversations", chat: "conversations", eclats: "dots", coffre: "vault", reglages: "settings", medias: "radio", projets: "vie", agenda: "temps", feeds: "veille", nouvelle: "new", emblem: "marque" };

export const ICONS3D = Object.fromEntries(ICONS3D_IDS.map((id) => [id, { src: BASE + id + "@56.png", hd: BASE + id + ".png" }]));

export function ico3d(id, hd = false) {
  const e = ICONS3D[id] || ICONS3D[ALIAS[id]];
  return e ? (hd ? e.hd : e.src) : null;
}

/* 30/10 (Ahadi : « icônes et onglets font vieux, pas premium ») — dans l'app, le rail utilise les VRAIS SF Symbols
   d'Apple, dessinés par macOS et servis par le moteur (GET /api/sf) puis appliqués en masque CSS (couleur = texte).
   Hors app (tests navigateur), repli sur les icônes 3D. */
const SF = {
  accueil: "house", conversations: "bubble.left.and.bubble.right", attente: "hourglass", messages: "envelope",
  veille: "antenna.radiowaves.left.and.right", temps: "calendar", reunions: "list.clipboard", engagements: "checkmark.seal",
  dossiers: "folder", relations: "person.2", dots: "sparkles", conseil: "person.3", livrables: "doc.richtext",
  studio: "paintpalette", finance: "chart.line.uptrend.xyaxis", fundings: "leaf", vie: "square.grid.2x2",
  savoir: "books.vertical", journal: "book.closed", ame: "heart", controle: "gamecontroller", confiance: "checkmark.shield",
  outils: "wrench.and.screwdriver", systeme: "cpu", radio: "headphones", settings: "gearshape", vault: "lock.shield",
  send: "arrow.up", mic: "mic", attach: "paperclip", search: "magnifyingglass", new: "square.and.pencil", marque: "sparkle",
};
export function sfName(id) { return SF[id] || SF[ALIAS[id]] || null; }
export function icoSF(id, size = 18) {
  const n = sfName(id); if (!n) return "";
  return '<i class="sfi" aria-hidden="true" style="--sf:url(/api/sf?n=' + n + '&s=' + (size * 2) + '&w=regular);width:' + size + 'px;height:' + size + 'px"></i>';
}

export function ico3dImg(id, size = 22) {
  if (window.__NOVA_NATIVE_WEB && sfName(id)) return icoSF(id, 18);
  const src = ico3d(id); if (!src) return "";
  const hd = ico3d(id, true);
  return '<img class="ico3d" src="' + src + '" srcset="' + src + " 1x, " + hd + ' 2x" alt="" width="' + size + '" height="' + size + '" decoding="async" draggable="false">';
}

/* Styles minimaux (visibilité + tuile de verre) ; la tuile .ri reste celle de identite.css. */
(function injectStyle() {
  try {
    if (document.getElementById("nova-ico3d-css")) return;
    const st = document.createElement("style"); st.id = "nova-ico3d-css";
    st.textContent = [
      ".rail-btn .ri > .ico3d { display: none; }",
      "html[data-identite] .rail-btn .ri.ri3d > svg { display: none; }",
      "html[data-identite] .rail-btn .ri.ri3d > .ico3d { display: block; pointer-events: none; user-select: none; -webkit-user-drag: none; }",
      "html[data-identite] .rail-btn .ri.ri3d > .sfi { display: block; background: currentColor; -webkit-mask: var(--sf) center / contain no-repeat; mask: var(--sf) center / contain no-repeat; }",
      "html[data-identite] .rail-btn .ri.ri3d { background: linear-gradient(180deg, rgb(var(--edge-rgb) / calc(var(--edge-a) * .9)), rgb(var(--edge-rgb) / calc(var(--edge-a) * .15)) 70%), var(--fill-1) !important; }",
      'html[data-material="sentinelle"] .rail-btn .ri.ri3d { background: transparent !important; box-shadow: none; }',
    ].join("\n");
    document.head.append(st);
  } catch (e) {}
})();
