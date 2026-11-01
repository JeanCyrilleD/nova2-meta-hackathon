/* V6 — Helpers du système de design Nova (contrat : conseil_24-10/V6_DESIGN.md).
   Chaque helper renvoie un nœud DOM construit avec h() (core.js) et les classes
   .ds-* de css/v6-ds.css. Aucun style en ligne, aucune couleur : tout vient du thème.
   Les « actions » acceptent soit des nœuds DOM, soit des descripteurs :
     { label, icon, onClick, primary, danger, ghost, tip, disabled }
   (icône seule → bouton-icône avec infobulle ; sinon .btn.sm + variante ds-btn-*). */
import { h } from "./core.js";
import { ic } from "./icons.js";

const isNode = (x) => !!(x && typeof x === "object" && x.nodeType);
const list = (x) => (x == null || x === false ? [] : Array.isArray(x) ? x.flat() : [x]);
const svg = (name, size) => { const s = h("span", { class: "ds-ic", "aria-hidden": "true" }); s.style.display = "inline-flex"; s.innerHTML = ic(name, size); return s; };

/** Bouton d'action à partir d'un descripteur { label, icon, onClick, primary, danger, ghost, tip, disabled } (ou nœud renvoyé tel quel). */
export function action(a) {
  if (isNode(a)) return a;
  if (!a || typeof a !== "object") return null;
  const onclick = (e) => { e.stopPropagation(); if (!a.disabled && typeof a.onClick === "function") a.onClick(e); };
  if (a.icon && !a.label) {
    const b = h("button", { type: "button", class: "ds-icon-btn" + (a.primary ? " is-primary" : ""), title: a.tip || "", "aria-label": a.tip || a.icon, disabled: !!a.disabled, onclick });
    b.innerHTML = ic(a.icon, 16);
    return b;
  }
  const v = a.primary ? "ds-btn-primary" : a.danger ? "ds-btn-danger" : a.ghost ? "ds-btn-ghost" : "ds-btn-secondary";
  const b = h("button", { type: "button", class: "btn sm " + v + (a.primary ? " is-primary" : ""), title: a.tip || null, disabled: !!a.disabled, onclick });
  if (a.icon) b.append(svg(a.icon, 14));
  b.append(String(a.label));
  return b;
}
const actionsBox = (acts, cls = "ds-actions") => { const nodes = list(acts).map(action).filter(Boolean); return nodes.length ? h("div", { class: cls }, nodes) : null; };

/** En-tête de page : pageHead({ title, sub, actions }) — titre = libellé du menu, sous-titre ≤ 1 ligne, actions à droite (1 primaire max). */
export function pageHead({ title = "", sub = "", actions = null } = {}) {
  const txt = h("div", { class: "ds-ph-txt" }, h("h1", { class: "ds-title" }, String(title)), sub ? h("p", { class: "ds-sub", title: String(sub) }, String(sub)) : null);
  return h("header", { class: "ds-page-head" }, txt, actionsBox(actions));
}

/** Section : section({ title, count, actions, collapsible, open, body }) — renvoie l'élément ; .body reçoit le contenu (repliable = <details>). */
export function section({ title = "", count = null, actions = null, collapsible = false, open = true, body = null, id = null } = {}) {
  const headKids = [h("h2", { class: "ds-h2" }, String(title)), count != null && count !== "" ? h("span", { class: "ds-count", "aria-label": count + " éléments" }, String(count)) : null, actionsBox(actions)];
  const inner = h("div", { class: "ds-section-body" }, list(body));
  let el;
  if (collapsible) {
    el = h("details", { class: "ds-section ds-collapsible", open: open ? true : null, id }, h("summary", { class: "ds-section-head" }, headKids), inner);
    el.querySelectorAll(".ds-actions button").forEach((b) => b.addEventListener("click", (e) => e.preventDefault()));
  } else {
    el = h("section", { class: "ds-section", id }, h("div", { class: "ds-section-head" }, headKids), inner);
  }
  el.body = inner;
  el.setCount = (n) => { const c = el.querySelector(".ds-count"); if (c) c.textContent = String(n); };
  return el;
}

/** Carte : card(opts?, ...enfants) — opts { alert, muted, flush, class, title, actions } ; une seule ombre, rayon lg. */
export function card(opts = {}, ...kids) {
  if (isNode(opts) || typeof opts === "string" || Array.isArray(opts)) { kids.unshift(opts); opts = {}; }
  const o = opts || {};
  const cls = "ds-card" + (o.alert ? " is-alert" : "") + (o.muted ? " is-muted" : "") + (o.flush ? " is-flush" : "") + (o.class ? " " + o.class : "");
  const head = o.title ? h("div", { class: "ds-section-head" }, h("h3", { class: "ds-h3" }, String(o.title)), actionsBox(o.actions)) : null;
  return h("div", { class: cls }, head, kids);
}

/** Ligne de liste : row({ title, meta, side, actions, onOpen, lead, selected, tip }) — 56 px mini, clic/Entrée = ouvrir, actions atteignables au Tab. */
export function row({ title = "", meta = null, side = null, actions = null, onOpen = null, lead = null, selected = false, tip = null } = {}) {
  const main = h("div", { class: "ds-row-main" },
    h("div", { class: "ds-row-title", title: tip || (typeof title === "string" ? title : null) }, title),
    meta != null && meta !== "" ? h("div", { class: "ds-row-meta", title: typeof meta === "string" ? meta : null }, meta) : null);
  const leadEl = lead == null ? null : (typeof lead === "string" && /^[a-z0-9-]+$/.test(lead) ? h("span", { class: "ds-row-lead" }, svg(lead, 16)) : h("span", { class: "ds-row-lead" }, lead));
  const sideEl = side != null && side !== "" ? h("div", { class: "ds-row-side" }, side) : null;
  const acts = actionsBox(actions, "ds-row-actions");
  const el = h("div", { class: "ds-row" + (selected ? " is-selected" : "") }, leadEl, main, sideEl, acts);
  if (typeof onOpen === "function") {
    el.tabIndex = 0;
    el.dataset.open = "1";
    el.setAttribute("role", "button");
    if (typeof title === "string") el.setAttribute("aria-label", title);
    const interactive = (t) => { const c = t && t.closest ? t.closest("button, a, input, select, textarea, summary, .ds-row-actions") : null; return !!(c && c !== el && el.contains(c)); };
    el.addEventListener("click", (e) => { if (interactive(e.target)) return; onOpen(e); });
    el.addEventListener("keydown", (e) => { if (e.target !== el) return; if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onOpen(e); } });
  }
  el.setSelected = (on) => el.classList.toggle("is-selected", !!on);
  return el;
}

/** Statut : pill(texte, ton) — ton ∈ ok | warn | danger | neutral ; 1 ou 2 mots. */
export function pill(text, tone = "neutral") {
  const t = ["ok", "warn", "danger", "neutral"].includes(tone) ? tone : "neutral";
  return h("span", { class: "ds-pill " + t, title: String(text) }, String(text));
}

/** Puces de filtre à sélection unique : chips([{ id, label, n, on }], onPick(id)) — renvoie le conteneur (.set(id) pour piloter). */
export function chips(items = [], onPick = null) {
  const box = h("div", { class: "ds-chips", role: "radiogroup" });
  const btns = new Map();
  const set = (id, fire) => {
    for (const [k, b] of btns) { const on = k === id; b.classList.toggle("is-on", on); b.setAttribute("aria-checked", on ? "true" : "false"); }
    box.value = id;
    if (fire && typeof onPick === "function") onPick(id);
  };
  for (const it of items) {
    const b = h("button", { type: "button", class: "ds-chip", role: "radio", "aria-checked": "false", onclick: () => set(it.id, true) },
      String(it.label), it.n != null && it.n !== "" ? h("span", { class: "ds-chip-n" }, String(it.n)) : null);
    btns.set(it.id, b); box.append(b);
  }
  const first = items.find((x) => x.on) || items[0];
  if (first) set(first.id, false);
  box.set = (id) => set(id, false);
  return box;
}

/** Onglets internes : tabs([{ id, label, n, on }], onPick(id)) — ≤ 6, flèches ←/→, défilement horizontal si étroit. */
export function tabs(items = [], onPick = null) {
  const box = h("div", { class: "ds-tabs", role: "tablist" });
  const btns = new Map();
  const set = (id, fire) => {
    for (const [k, b] of btns) { const on = k === id; b.classList.toggle("is-on", on); b.setAttribute("aria-selected", on ? "true" : "false"); b.tabIndex = on ? 0 : -1; if (on) try { b.scrollIntoView({ block: "nearest", inline: "nearest" }); } catch (e) {} }
    box.value = id;
    if (fire && typeof onPick === "function") onPick(id);
  };
  for (const it of items) {
    const b = h("button", { type: "button", class: "ds-tab", role: "tab", "aria-selected": "false", onclick: () => set(it.id, true) },
      String(it.label), it.n != null && it.n !== "" ? h("span", { class: "ds-chip-n" }, String(it.n)) : null);
    btns.set(it.id, b); box.append(b);
  }
  box.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    const ids = [...btns.keys()]; const i = ids.indexOf(box.value); if (i < 0) return;
    const n = ids[(i + (e.key === "ArrowRight" ? 1 : ids.length - 1)) % ids.length];
    e.preventDefault(); set(n, true); btns.get(n).focus();
  });
  const first = items.find((x) => x.on) || items[0];
  if (first) set(first.id, false);
  box.set = (id) => set(id, false);
  return box;
}

/** État vide : empty({ text, action, icon, compact }) — dit quoi faire ; action = descripteur ou nœud. */
export function empty({ text = "Rien à afficher pour l'instant.", action: act = null, icon = "sparkle", compact = false } = {}) {
  return h("div", { class: "ds-empty" + (compact ? " is-compact" : "") },
    icon ? h("span", { class: "ds-empty-ic" }, svg(icon, compact ? 16 : 20)) : null,
    h("div", { class: "ds-empty-t" }, String(text)),
    act ? action(act) : null);
}

/** Chargement : skeleton(n) — n lignes fantômes (animation coupée si mouvement réduit) ; jamais d'écran blanc. */
export function skeleton(n = 3) {
  const box = h("div", { class: "ds-skeleton", "aria-busy": "true", "aria-label": "Chargement…", role: "status" });
  for (let i = 0; i < Math.max(1, n | 0); i++) box.append(h("div", { class: "ds-skel-row" }, h("i")));
  return box;
}

/** Erreur : errorBox({ cause, retry, title }) — cause claire en français + « Réessayer » ; jamais de pile technique. */
export function errorBox({ cause = "Le moteur n'a pas répondu.", retry = null, title = "Impossible de charger" } = {}) {
  const ico = h("span", { class: "ds-error-ic" }, svg("alert", 18));
  const t = h("div", { class: "ds-error-t" }, h("b", {}, String(title)), String(cause));
  const b = typeof retry === "function" ? action({ label: "Réessayer", icon: "refresh", onClick: retry }) : null;
  return h("div", { class: "ds-error", role: "alert" }, ico, t, b);
}

/** Métriques : kpis([{ label, value, delta, tone, alert, tip }]) — ≤ 4 par rangée ; valeur absente → « — ». */
export function kpis(items = []) {
  return h("div", { class: "ds-kpis" }, items.map((k) => {
    const v = k.value == null || k.value === "" || (typeof k.value === "number" && !isFinite(k.value)) ? "—" : k.value;
    return h("div", { class: "ds-kpi" + (k.alert ? " is-alert" : ""), title: k.tip || null },
      h("div", { class: "ds-kpi-l" }, String(k.label || "")),
      h("div", { class: "ds-kpi-v", title: isNode(v) ? null : String(v) }, isNode(v) ? v : String(v)),
      k.delta != null && k.delta !== "" ? h("div", { class: "ds-kpi-d" + (k.tone ? " " + k.tone : "") }, String(k.delta)) : null);
  }));
}

/** Barre d'outils : toolbar({ search: { placeholder, value, onInput }, chips, end }) — recherche instantanée ; .input = le champ. */
export function toolbar({ search = null, chips: chipsEl = null, end = null } = {}) {
  const bar = h("div", { class: "ds-toolbar" });
  if (search) {
    const input = h("input", { type: "search", placeholder: search.placeholder || "Rechercher…", "aria-label": search.placeholder || "Rechercher", value: search.value || null, autocomplete: "off", spellcheck: "false" });
    const wrap = h("label", { class: "ds-search" + (search.value ? " has-q" : "") });
    wrap.innerHTML = ic("search", 15);
    const x = h("button", { type: "button", class: "ds-search-x", title: "Effacer", "aria-label": "Effacer la recherche" });
    x.innerHTML = ic("close", 13);
    const fire = () => { wrap.classList.toggle("has-q", !!input.value); if (typeof search.onInput === "function") search.onInput(input.value.trim()); };
    input.addEventListener("input", fire);
    input.addEventListener("keydown", (e) => { if (e.key === "Escape" && input.value) { e.stopPropagation(); input.value = ""; fire(); } });
    x.addEventListener("click", (e) => { e.preventDefault(); input.value = ""; fire(); input.focus(); });
    wrap.append(input, x);
    bar.append(wrap);
    bar.input = input;
  }
  if (chipsEl) bar.append(chipsEl);
  const endNodes = list(end).map(action).filter(Boolean);
  if (endNodes.length) bar.append(h("div", { class: "ds-tb-end" }, endNodes));
  return bar;
}

/** Repli : fold(titre, contenu, ouvert) — <details> pour la configuration et le technique. */
export function fold(title, content, open = false) {
  return h("details", { class: "ds-fold", open: open ? true : null }, h("summary", {}, String(title)), h("div", { class: "ds-fold-body" }, list(content)));
}

/** Masquage : maskSecret(str, garder = 4) — n° de compte, IBAN, jeton → « ••••1234 » ; vide → « — ». */
export function maskSecret(str, keep = 4) {
  const s = String(str ?? "").replace(/\s+/g, "");
  if (!s || /^(null|undefined)$/i.test(s)) return "—";
  const k = Math.max(0, Math.min(keep | 0, Math.floor(s.length / 2)));
  return "••••" + (k ? s.slice(-k) : "");
}
