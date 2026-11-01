/* PILOTAGE (01/11) — résolution DÉTERMINISTE des cibles de navigation interne de Nova.
   Module pur (aucun DOM) : importé par uibridge.js et testé par tools/test_pilotage.mjs.
   Avant : « go » prenait le PREMIER module dont l'id était contenu dans la demande
   (q.includes(id)) et répondait ok:true avant même d'avoir navigué ; « go cerveaux »,
   « go réglages cerveaux » ou « go chat » échouaient (« écran introuvable ») et
   l'agent contournait au hasard. Ici : alias explicites, score, ambiguïté signalée,
   section déduite (« cerveaux » → Réglages › Assistant). */

export const normTxt = (s) => String(s == null ? "" : s).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
  .replace(/[«»"'’`]/g, " ").replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();

/* Alias → écran (id de MODULES) et, s'il y a lieu, section ou ligne à atteindre dans cet écran. */
export const SCREEN_ALIASES = {
  "reglages": ["settings"], "reglage": ["settings"], "parametres": ["settings"], "preferences": ["settings"], "settings": ["settings"],
  "cerveau": ["settings", "assistant"], "cerveaux": ["settings", "assistant"], "cerveau par defaut": ["settings", "assistant"], "modele": ["settings", "assistant"], "modeles": ["settings", "assistant"],
  "assistant": ["settings", "assistant"], "autorisation totale": ["settings", "assistant"],
  "apparence": ["settings", "look"], "theme": ["settings", "look"], "themes": ["settings", "look"], "accessibilite": ["settings", "look"],
  "general": ["settings", "general"], "notifications": ["settings", "general"],
  "donnees": ["settings", "data"], "comptes": ["settings", "data"], "cles": ["settings", "data"], "sauvegarde": ["settings", "data"], "connexions": ["settings", "data"],
  "voix": ["settings", "appareils"], "telephone": ["settings", "appareils"], "micro": ["settings", "appareils"], "mot de reveil": ["settings", "appareils"],
  "chat": ["conversations"], "chats": ["conversations"], "conversation": ["conversations"], "discussions": ["conversations"], "discussion": ["conversations"], "agent": ["conversations"], "fil direct": ["conversations"],
  "eclats": ["dots"], "eclat": ["dots"], "automatisations": ["dots"], "agents": ["dots"],
  "agenda": ["temps"], "calendrier": ["temps"], "reunions a venir": ["temps"],
  "projets": ["vie"], "notes": ["vie"],
  "medias": ["radio"], "media": ["radio"], "tv": ["radio"], "television": ["radio"], "podcasts": ["radio"], "radios": ["radio"],
  "approbations": ["taches"], "taches": ["taches"],
  "en attente": ["attente"], "attente": ["attente"],
  "feeds": ["veille"], "veille": ["veille"], "fil": ["veille"],
  "comptes rendus": ["reunions"], "compte rendu": ["reunions"], "transcriptions": ["reunions"],
  "coffre": ["vault"], "coffre fort": ["vault"],
  "mails": ["messages"], "boites": ["messages"], "brouillons": ["messages"],
  "couts": ["couts"], "depenses": ["couts"], "budget": ["couts"],
  "systeme": ["systeme"], "boite noire": ["systeme"],
  "accueil": ["accueil"], "maison": ["accueil"],
};

/* Score d'une correspondance texte (0 = aucune). */
function score(q, label) {
  const a = normTxt(q), b = normTxt(label);
  if (!a || !b) return 0;
  if (a === b) return 100;
  if (b.startsWith(a) && a.length >= 3) return 75;
  if (a.length >= 4 && b.includes(a)) return 60;
  const words = a.split(" ");
  if (b.length >= 4 && words.includes(b)) return 55;   // « ouvre la page finance » → finance
  return 0;
}

/* Résout un écran. modules : [{id,label}]. Retour :
   { ok:true, id, label, section, via }  |  { ok:false, erreur, candidats:[{id,label}] } */
export function resolveScreen(q, modules, section = "") {
  const r = resolveScreenRaw(q, modules, section);
  if (r.ok && r.section) {   // « Réglages | Cerveaux » : la section dite par son alias devient la vraie section (Assistant)
    const sa = SCREEN_ALIASES[normTxt(r.section)];
    if (sa && sa[0] === r.id && sa[1] && normTxt(r.section) !== sa[1]) { r.sectionDemandee = r.section; r.section = sa[1]; }
  }
  return r;
}
function resolveScreenRaw(q, modules, section = "") {
  const mods = Array.isArray(modules) ? modules : [];
  const nq = normTxt(q);
  const list = () => mods.map((m) => ({ id: m.id, label: m.label }));
  if (!nq) return { ok: false, erreur: "écran non précisé", candidats: list() };
  const byId = (id) => mods.find((m) => m.id === id);
  // 1) id exact, libellé exact
  for (const m of mods) if (normTxt(m.id) === nq || normTxt(m.label) === nq) return { ok: true, id: m.id, label: m.label, section: section || "", via: "exact" };
  // 2) alias complet
  const al = SCREEN_ALIASES[nq];
  if (al && byId(al[0])) { const m = byId(al[0]); return { ok: true, id: m.id, label: m.label, section: section || al[1] || "", via: "alias" }; }
  // 3) « <écran> <section> » : le plus long préfixe qui désigne un écran, le reste devient la section
  const w = nq.split(" ");
  for (let k = w.length - 1; k >= 1; k--) {
    const head = w.slice(0, k).join(" "), tail = w.slice(k).join(" ");
    const sub = resolveScreenRaw(head, mods, "");
    if (sub.ok && sub.via !== "partiel") return { ok: true, id: sub.id, label: sub.label, section: section || tail, via: "écran+section" };
  }
  // 4) score sur libellés, ids et alias ; ambiguïté signalée, jamais tranchée au hasard
  const cand = new Map();
  const put = (id, s) => { if (s > 0 && byId(id)) cand.set(id, Math.max(cand.get(id) || 0, s)); };
  for (const m of mods) { put(m.id, score(nq, m.label)); put(m.id, score(nq, m.id)); }
  for (const [k, v] of Object.entries(SCREEN_ALIASES)) put(v[0], Math.min(70, score(nq, k)));
  const ranked = [...cand.entries()].sort((x, y) => y[1] - x[1]);
  if (!ranked.length) return { ok: false, erreur: "écran introuvable : « " + q + " »", candidats: list() };
  if (ranked.length > 1 && ranked[0][1] === ranked[1][1]) {
    return { ok: false, erreur: "écran ambigu : « " + q + " »", candidats: ranked.filter((r) => r[1] === ranked[0][1]).map(([id]) => ({ id, label: byId(id).label })) };
  }
  const m = byId(ranked[0][0]);
  const al2 = Object.entries(SCREEN_ALIASES).find(([k, v]) => v[0] === m.id && v[1] && score(nq, k) >= 60);
  return { ok: true, id: m.id, label: m.label, section: section || (al2 ? al2[1][1] : ""), via: "partiel" };
}

/* Choisit, parmi des entrées [{key,label}], celle qui correspond à q (section, onglet, ligne de réglage).
   Retour : { ok:true, key, label, score } | { ok:false, ambigu?:[labels] } */
export function matchLabel(q, entries) {
  const nq = normTxt(q);
  if (!nq) return { ok: false };
  const ranked = (entries || []).map((e) => ({ e, s: Math.max(score(nq, e.label), score(nq, e.key || "")) })).filter((x) => x.s > 0).sort((a, b) => b.s - a.s);
  if (!ranked.length) return { ok: false };
  if (ranked.length > 1 && ranked[0].s === ranked[1].s && ranked[0].s < 100 && normTxt(ranked[0].e.label) !== normTxt(ranked[1].e.label)) {
    return { ok: false, ambigu: ranked.filter((r) => r.s === ranked[0].s).map((r) => r.e.label) };
  }
  return { ok: true, key: ranked[0].e.key, label: ranked[0].e.label, score: ranked[0].s };
}

/* « ligne > option » (ex. « Taille du texte des réponses > Grand ») : clic ciblé dans une ligne de réglage. */
export function splitRowOption(q) {
  const s = String(q || "");
  const i = s.indexOf(">");
  if (i <= 0) return null;
  const row = s.slice(0, i).trim(), opt = s.slice(i + 1).trim();
  return row && opt ? { row, opt } : null;
}

/* Réglages appliqués côté fenêtre (cache localStorage + attribut du document), en plus du moteur. */
export const CLIENT_SETTINGS = {
  text_size: { ls: "nova2_text_size", ds: "textSize", neutral: "m", values: ["s", "m", "l", "xl"] },
  read_width: { ls: "nova2_read_width", ds: "readWidth", neutral: "normal", values: ["narrow", "normal", "wide"] },
  answer_style: { ls: "nova2_answer_style", ds: "answerStyle", neutral: "cafu", values: ["cafu", "sobre"] },
  soft_night: { ls: "nova2_soft_night", ds: "softNight", bool: true },
};
