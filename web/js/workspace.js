/* workspace.js — ESPACE DE TRAVAIL MULTI-PAGES (24/10/2026).

   Une page n'est plus « l'écran » : c'est un PANNEAU. L'espace de travail en contient
   1, 2 ou 3 côte à côte (proportions réglables à la souris), plus des FENÊTRES
   FLOTTANTES déplaçables, redimensionnables, aimantées aux bords. Chaque page (racine
   .mod d'un module) vit dans UN seul emplacement à la fois ; la déplacer d'un panneau à
   l'autre la RÉ-ACCROCHE (même instance, même état, même scroll, médias qui continuent).

   Gestes :
     · clic dans la barre latérale        → ouvre la page dans le panneau actif
     · ⌥-clic / clic droit → « À côté »   → ouvre dans un nouveau panneau (jusqu'à 3)
     · glisser une page de la barre       → la dépose sur le panneau visé (ou dans le vide → flottante)
     · barre du panneau : ⧉ diviser · ⬈ détacher (flottante) · ⤢ agrandir · ✕ fermer
     · fenêtre flottante : glisser par la barre, poignée en bas à droite, double-clic → ancrer
     · ⌥⌘1 / ⌥⌘2 / ⌥⌘3 : une, deux, trois colonnes · ⌥⌘F : détacher la page active
   L'agencement est mémorisé (nova2_ws_v1) et restauré au démarrage. */

const KEY = "nova2_ws_v1";
const MIN_W = 340;

import { peekData, peekBody, hasPeek } from "./peek.js";

export function createWorkspace({ view, h, ic, bus, labelOf, iconOf, open, release, descOf }) {
  // open(id, slotBody) : le shell monte/affiche le module dans ce conteneur (Promise)
  // release(id)        : le shell cache le module (il retourne au dépôt)
  const ws = h("div", { class: "ws", "data-layout": "1" });
  const stash = h("div", { class: "ws-stash", hidden: "" });
  const floatLayer = h("div", { class: "ws-floats" });
  view.append(ws, floatLayer, stash);

  let panes = [];          // [{ el, body, bar, mod }]
  let floats = [];         // [{ el, body, mod, x, y, w, h, z }]
  let focused = 0;         // index du panneau actif, ou "f:<i>" pour une flottante
  let fr = [1, 1, 1];
  let zTop = 10;

  /* ── Persistance ─────────────────────────────────────────────────── */
  const save = () => {
    try {
      localStorage.setItem(KEY, JSON.stringify({
        panes: panes.map((p) => p.mod || ""), fr, focused: typeof focused === "number" ? focused : 0,
        floats: floats.map((f) => ({ mod: f.mod, x: f.x, y: f.y, w: f.w, h: f.h })),
      }));
    } catch (e) {}
  };
  const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) { return null; } };

  /* 30/10 : pages qui ont leur icône en verre (id de module → fichier img/glass/<nom>-128.webp). */
  const GLASS = { accueil: "accueil", conversations: "conversations", messages: "messages", attente: "attente", temps: "agenda",
    veille: "feeds", finance: "finance", fundings: "fundings", livrables: "livrables", vie: "projets", reunions: "reunions",
    dossiers: "dossiers", engagements: "engagements", relations: "relations", dots: "dots", conseil: "conseil", savoir: "savoir",
    ame: "ame", confiance: "confiance", journal: "journal", controle: "controle", outils: "outils", systeme: "systeme",
    radio: "medias", studio: "studio", settings: "reglages", vault: "coffre" };
  /* ── Construction d'un panneau ───────────────────────────────────── */
  function paneBar(kind) {
    const icon = h("span", { class: "pb-ic" }), title = h("span", { class: "pb-title" });
    const acts = h("span", { class: "pb-acts" });
    const btn = (name, tip, fn) => { const b = h("button", { class: "pb-btn", title: tip, "aria-label": tip }); b.innerHTML = ic(name, 15); b.addEventListener("click", (e) => { e.stopPropagation(); fn(); }); acts.append(b); return b; };
    const bar = h("div", { class: "pane-bar" + (kind === "float" ? " is-float" : "") }, icon, title, h("span", { class: "sp" }), acts);
    /* 30/10 : icône en VERRE (série [tiers] d'Ahadi, img/glass/) dans l'en-tête de chaque page quand elle existe ; sinon le trait. */
    bar._set = (mod) => {
      const g = mod ? GLASS[mod] : null;
      icon.classList.toggle("has-glass", !!g);
      icon.innerHTML = !mod ? "" : g ? '<img class="pb-glass" src="img/glass/' + g + '-128.webp" alt="" width="26" height="26" decoding="async" draggable="false">' : ic(iconOf(mod), 15);
      title.textContent = mod ? labelOf(mod) : "Vide";
    };
    bar._btn = btn;
    return bar;
  }
  function makePane() {
    const body = h("div", { class: "pane-body" });
    const bar = paneBar("pane");
    const el = h("section", { class: "pane" }, bar, body);
    const p = { el, body, bar, mod: "" };
    bar._btn("layers", "Diviser — ouvrir une page à côté", () => { const i = panes.indexOf(p); splitFrom(i); });
    bar._btn("external", "Détacher en fenêtre flottante", () => detach(panes.indexOf(p)));
    bar._btn("maximize", "Agrandir — cette page seule", () => maximize(panes.indexOf(p)));
    bar._btn("close", "Fermer ce panneau", () => closePane(panes.indexOf(p)));
    el.addEventListener("pointerdown", () => focus(panes.indexOf(p)), true);
    // dépôt d'une page glissée depuis la barre latérale
    el.addEventListener("dragover", (e) => { if (e.dataTransfer && [...e.dataTransfer.types].includes("text/nova-module")) { e.preventDefault(); el.classList.add("drop"); } });
    el.addEventListener("dragleave", () => el.classList.remove("drop"));
    el.addEventListener("drop", (e) => { el.classList.remove("drop"); const id = e.dataTransfer.getData("text/nova-module"); if (id) { e.preventDefault(); e.stopPropagation(); focus(panes.indexOf(p)); show(id, panes.indexOf(p)); } });
    return p;
  }
  function renderLayout() {
    ws.replaceChildren();
    panes.forEach((p, i) => {
      if (i > 0) ws.append(splitter(i));
      p.el.classList.toggle("on", focused === i);
      ws.append(p.el);
    });
    ws.dataset.layout = String(panes.length);
    applyFr();
    window.dispatchEvent(new Event("resize"));
  }
  function applyFr() {
    const cols = [];
    panes.forEach((p, i) => { if (i > 0) cols.push("6px"); cols.push("minmax(" + MIN_W + "px, " + (fr[i] || 1) + "fr)"); });
    ws.style.gridTemplateColumns = cols.join(" ");
  }
  function splitter(i) {
    const s = h("div", { class: "ws-split", role: "separator", "aria-orientation": "vertical", title: "Glisser pour redimensionner · double-clic : parts égales" });
    s.addEventListener("dblclick", () => { fr = [1, 1, 1]; applyFr(); save(); window.dispatchEvent(new Event("resize")); });
    s.addEventListener("pointerdown", (e) => {
      e.preventDefault(); s.setPointerCapture(e.pointerId); ws.classList.add("resizing");
      const a = panes[i - 1].el.getBoundingClientRect(), b = panes[i].el.getBoundingClientRect();
      const tot = a.width + b.width, sum = (fr[i - 1] || 1) + (fr[i] || 1);
      const move = (ev) => {
        const wa = Math.max(MIN_W, Math.min(tot - MIN_W, ev.clientX - a.left));
        fr[i - 1] = sum * wa / tot; fr[i] = sum - fr[i - 1]; applyFr();
      };
      const up = () => { s.removeEventListener("pointermove", move); ws.classList.remove("resizing"); save(); window.dispatchEvent(new Event("resize")); };
      s.addEventListener("pointermove", move); s.addEventListener("pointerup", up, { once: true });
    });
    return s;
  }

  /* ── Placement d'une page ────────────────────────────────────────── */
  const whereIs = (id) => {
    const pi = panes.findIndex((p) => p.mod === id); if (pi >= 0) return { kind: "pane", i: pi };
    const fi = floats.findIndex((f) => f.mod === id); if (fi >= 0) return { kind: "float", i: fi };
    return null;
  };
  async function show(id, paneIndex = (typeof focused === "number" ? focused : 0)) {
    const at = whereIs(id);
    // 27/10 (reproduit à l'écran) : le rail sélectionnait « Conversations » mais la
    // vue restait sur l'écran précédent — le module était déjà placé dans un
    // panneau/flottant INVISIBLE, et show() se contentait de le « focaliser ».
    // Un emplacement invisible ne compte plus comme ouvert : on libère sa
    // réservation et on ouvre réellement dans le panneau visible.
    if (at && at.kind === "pane") {
      const el = panes[at.i] && panes[at.i].el;
      // Visible = largeur réelle ET intersection réelle avec l'espace de travail
      // (un panneau en 0fr gardait 240 px hors champ : clientWidth ne suffisait pas).
      let visible = false;
      try {
        const r = el.getBoundingClientRect(), wr = ws.getBoundingClientRect();
        visible = !!el && r.width >= 60 && r.height >= 60 && r.right > wr.left + 40 && r.left < wr.right - 40
          && getComputedStyle(el).display !== "none" && getComputedStyle(el).visibility !== "hidden";
      } catch (e) {}
      if (visible) {
        // 27/10 (revérifié à l'écran après 2 correctifs insuffisants) : le module
        // était bien visible, mais dans le panneau NON focalisé — focus() ne
        // changeait qu'une couleur d'icône, la vue principale restait sur l'ancien
        // écran et l'utilisateur voyait « rien ne se passe ». Un clic rail veut la
        // page demandée dans le panneau focalisé : on échange les deux panneaux
        // (déplacement DOM, instances et flux en cours préservés).
        if (at.i !== 0 && panes[0]) {
          const a = panes[at.i], b = panes[0];
          const aKids = Array.from(a.body.childNodes), bKids = Array.from(b.body.childNodes);
          aKids.forEach((n) => b.body.appendChild(n));
          bKids.forEach((n) => a.body.appendChild(n));
          const m = a.mod; a.mod = b.mod; b.mod = m;
          a.bar._set(a.mod); b.bar._set(b.mod);
          focus(0); save(); return;
        }
        focus(at.i); return;
      }
      panes[at.i].mod = "";
    }
    if (at && at.kind === "float") {
      const f = floats[at.i];
      let fVisible = false;
      try {
        const r = f.el.getBoundingClientRect();
        fVisible = !!f && !!f.el && !f.el.hidden && r.width >= 60 && r.height >= 60 && getComputedStyle(f.el).display !== "none";
      } catch (e) {}
      if (fVisible) { raise(f); focusFloat(at.i); return; }
      if (f) f.mod = "";
    }
    const p = panes[paneIndex] || panes[0];
    const prev = p.mod;
    p.mod = id; p.bar._set(id); focus(panes.indexOf(p));
    if (prev && prev !== id) release(prev);
    await open(id, p.body);
    save();
  }
  function focus(i) {
    if (i < 0 || !panes[i]) return;
    focused = i;
    panes.forEach((p, k) => p.el.classList.toggle("on", k === i));
    floats.forEach((f) => f.el.classList.remove("on"));
    if (panes[i].mod) bus.emit("nova:pane-focus", { id: panes[i].mod });
    save();
  }
  function focusFloat(i) { focused = "f:" + i; panes.forEach((p) => p.el.classList.remove("on")); floats.forEach((f, k) => f.el.classList.toggle("on", k === i)); if (floats[i]) bus.emit("nova:pane-focus", { id: floats[i].mod }); }

  /* ── Disposition ─────────────────────────────────────────────────── */
  function setLayout(n, fill = []) {
    n = Math.max(1, Math.min(3, n | 0));
    while (panes.length < n) panes.push(makePane());
    while (panes.length > n) { const p = panes.pop(); if (p.mod) release(p.mod); }
    if (typeof focused === "number" && focused >= n) focused = n - 1;
    renderLayout();
    fill.forEach((id, i) => { if (id && panes[i] && !panes[i].mod) show(id, i); });
    // panneaux restés vides : proposer une page utile plutôt qu'un trou
    panes.forEach((p, i) => { if (!p.mod) emptyState(p, i); });
    save();
    bus.emit("nova:layout", { n });
  }
  /* V4-A : l'état vide « Panneau libre » montre de VRAIES cartes d'aperçu — un mini-tableau de
     bord en direct par page (même source que la Live Peek Card, peek.js : routes réelles, cache
     30 s, coffre verrouillé dit tel quel, aucun chiffre inventé). Un clic ouvre la page ici. */
  function emptyState(p, i) {
    p.bar._set("");
    const pick = (id) => () => show(id, i);
    const sugg = ["veille", "finance", "dots", "messages", "temps", "engagements", "conversations", "conseil"].filter((id) => !whereIs(id)).slice(0, 6);
    const cards = sugg.map((id) => {
      const body = hasPeek(id) ? h("div", { class: "pk-body" }, h("div", { class: "skel skel-line", style: "height:20px;width:55%" }), h("div", { class: "skel skel-line", style: "height:11px;width:80%;margin-top:10px" })) : peekBody(id, null, descOf ? descOf(id) : "");
      const card = h("button", { class: "pe-card pe-live", onclick: pick(id), title: "Ouvrir " + labelOf(id) + " dans ce panneau" },
        h("div", { class: "pk-head" }, h("span", { class: "pk-ic", html: ic(iconOf(id), 15) }), h("b", {}, labelOf(id)), h("span", { class: "sp" }), h("span", { class: "pk-live" }, hasPeek(id) ? "en direct" : "")),
        body);
      if (hasPeek(id)) peekData(id).then((d) => { if (body.parentNode) body.replaceWith(peekBody(id, d, descOf ? descOf(id) : "")); }).catch(() => {});
      return card;
    });
    p.body.replaceChildren(h("div", { class: "pane-empty" },
      h("div", { class: "pe-title" }, "Panneau libre"),
      h("div", { class: "pe-sub" }, "Glisse une page depuis la barre latérale, ou ouvre l'une de celles-ci — leur état est en direct."),
      h("div", { class: "pe-grid" }, ...cards)));
  }
  function splitFrom(i) {
    if (panes.length >= 3) { bus.emit("nova:toast", { text: "Trois panneaux au maximum — détache une page en fenêtre flottante." }); return; }
    panes.splice(i + 1, 0, makePane());
    fr.splice(i + 1, 0, 1); fr = fr.slice(0, 3);
    renderLayout(); emptyState(panes[i + 1], i + 1); focus(i + 1); save();
  }
  function closePane(i) {
    if (panes.length <= 1) { return; }
    const [p] = panes.splice(i, 1); fr.splice(i, 1); fr.push(1);
    if (p.mod) release(p.mod);
    if (typeof focused === "number" && focused >= panes.length) focused = panes.length - 1;
    renderLayout(); focus(typeof focused === "number" ? focused : 0); save();
  }
  function maximize(i) {
    const keep = panes[i]; if (!keep) return;
    panes.forEach((p, k) => { if (k !== i && p.mod) release(p.mod); });
    panes = [keep]; fr = [1, 1, 1]; focused = 0; renderLayout(); focus(0); save();
  }
  /* V4-A — flux : ouvrir « à côté » anime l'arrivée du panneau (260 ms, ressort doux
     cubic-bezier(0.22, 1, 0.36, 1)) puis SURLIGNE l'élément cible quand l'appelant le nomme :
     openBeside(id, { target: "<sélecteur CSS dans la page>" | (root) => Element }). */
  function arrive(el) {
    if (!el) return;
    el.classList.remove("ws-arriving"); void el.offsetWidth; el.classList.add("ws-arriving");
    el.addEventListener("animationend", () => el.classList.remove("ws-arriving"), { once: true });
  }
  function highlight(id, target) {
    if (!target) return;
    let tries = 0;
    const find = () => {
      const root = view.querySelector('.mod[data-mod="' + id + '"]');
      let el = null;
      try { el = root ? (typeof target === "function" ? target(root) : root.querySelector(String(target))) : null; } catch (e) { el = null; }
      if (el) { try { el.scrollIntoView({ block: "center", behavior: "smooth" }); } catch (e) {} el.classList.remove("ws-target"); void el.offsetWidth; el.classList.add("ws-target"); setTimeout(() => el.classList.remove("ws-target"), 1600); return; }
      if (++tries < 12) setTimeout(find, 150);   // la page peut finir de charger ses données : on réessaie ~1,8 s, puis on renonce sans bruit
    };
    setTimeout(find, 280);
  }
  async function openBeside(id, opts = {}) {
    const at = whereIs(id);
    if (at) { if (at.kind === "pane") { focus(at.i); arrive(panes[at.i].el); } else { raise(floats[at.i]); arrive(floats[at.i].el); } highlight(id, opts.target); return; }
    if (panes.length < 3) { splitFrom(panes.length - 1); const p = panes[panes.length - 1]; arrive(p.el); await show(id, panes.length - 1); }
    else { await openFloating(id); const f = floats[floats.length - 1]; if (f) arrive(f.el); }
    highlight(id, opts.target);
  }

  /* ── Fenêtres flottantes ─────────────────────────────────────────── */
  function raise(f) { f.z = ++zTop; f.el.style.zIndex = String(f.z); }
  function placeFloat(f) {
    const r = view.getBoundingClientRect();
    f.w = Math.max(MIN_W, Math.min(f.w, r.width - 24)); f.h = Math.max(260, Math.min(f.h, r.height - 24));
    f.x = Math.max(8, Math.min(f.x, r.width - f.w - 8)); f.y = Math.max(8, Math.min(f.y, r.height - f.h - 8));
    Object.assign(f.el.style, { left: f.x + "px", top: f.y + "px", width: f.w + "px", height: f.h + "px" });
  }
  async function openFloating(id, geo) {
    const at = whereIs(id);
    if (at && at.kind === "float") { raise(floats[at.i]); return; }
    if (at && at.kind === "pane") { panes[at.i].mod = ""; emptyState(panes[at.i], at.i); }
    const r = view.getBoundingClientRect();
    const body = h("div", { class: "pane-body" });
    const bar = paneBar("float");
    const el = h("section", { class: "fwin" }, bar, body, h("div", { class: "fwin-grip", title: "Redimensionner" }));
    const f = { el, body, bar, mod: id, x: 0, y: 0, w: 520, h: 600, z: 0, ...(geo || {}) };
    if (!geo) { f.x = r.width - f.w - 40 - floats.length * 28; f.y = 56 + floats.length * 28; }
    bar._set(id);
    bar._btn("layers", "Ancrer dans un panneau", () => dock(floats.indexOf(f)));
    bar._btn("close", "Fermer la fenêtre", () => closeFloat(floats.indexOf(f)));
    floats.push(f); floatLayer.append(el); placeFloat(f); raise(f);
    el.addEventListener("pointerdown", () => { raise(f); focusFloat(floats.indexOf(f)); }, true);
    bar.addEventListener("dblclick", () => dock(floats.indexOf(f)));
    // déplacement + aimantation (bords et moitiés)
    bar.addEventListener("pointerdown", (e) => {
      if (e.target.closest(".pb-btn")) return;
      e.preventDefault(); bar.setPointerCapture(e.pointerId); el.classList.add("dragging");
      const sx = e.clientX - f.x, sy = e.clientY - f.y;
      const move = (ev) => { f.x = ev.clientX - sx; f.y = ev.clientY - sy; placeFloat(f); };
      const up = (ev) => {
        bar.removeEventListener("pointermove", move); el.classList.remove("dragging");
        const vr = view.getBoundingClientRect();
        if (ev.clientX - vr.left < 24 || vr.right - ev.clientX < 24) { dock(floats.indexOf(f), ev.clientX - vr.left < 24 ? 0 : 99); return; }   // lâchée au bord → panneau
        save();
      };
      bar.addEventListener("pointermove", move); bar.addEventListener("pointerup", up, { once: true });
    });
    const grip = el.querySelector(".fwin-grip");
    grip.addEventListener("pointerdown", (e) => {
      e.preventDefault(); grip.setPointerCapture(e.pointerId);
      const sw = f.w, sh = f.h, sx = e.clientX, sy = e.clientY;
      const move = (ev) => { f.w = sw + ev.clientX - sx; f.h = sh + ev.clientY - sy; placeFloat(f); };
      const up = () => { grip.removeEventListener("pointermove", move); save(); window.dispatchEvent(new Event("resize")); };
      grip.addEventListener("pointermove", move); grip.addEventListener("pointerup", up, { once: true });
    });
    focusFloat(floats.length - 1);
    await open(id, body);
    save();
  }
  function closeFloat(i) { const [f] = floats.splice(i, 1); if (!f) return; release(f.mod); f.el.remove(); focus(0); save(); }
  async function dock(i, side) {
    const f = floats[i]; if (!f) return;
    const id = f.mod; floats.splice(i, 1); f.el.remove();
    release(id);
    if (panes.length < 3) { if (side === 0) { panes.unshift(makePane()); fr.unshift(1); fr = fr.slice(0, 3); renderLayout(); await show(id, 0); } else { splitFrom(panes.length - 1); await show(id, panes.length - 1); } }
    else await show(id, typeof focused === "number" ? focused : 0);
    save();
  }
  function detach(i) { const p = panes[i]; if (!p || !p.mod) return; const id = p.mod; p.mod = ""; release(id); if (panes.length > 1) closePane(i); else emptyState(p, i); openFloating(id); }

  /* ── Raccourcis ──────────────────────────────────────────────────── */
  window.addEventListener("keydown", (e) => {
    if (!(e.altKey && e.metaKey)) return;
    const k = e.code;
    if (k === "Digit1") { e.preventDefault(); maximize(typeof focused === "number" ? focused : 0); }
    else if (k === "Digit2") { e.preventDefault(); setLayout(2); }
    else if (k === "Digit3") { e.preventDefault(); setLayout(3); }
    else if (k === "KeyF") { e.preventDefault(); if (typeof focused === "number") detach(focused); }
  });
  window.addEventListener("resize", () => floats.forEach(placeFloat));

  /* ── Démarrage : un panneau, puis restauration de l'agencement ──── */
  panes = [makePane()]; renderLayout();
  const api = {
    show, openBeside, openFloating, setLayout, focus, whereIs,
    layout: () => panes.length,
    focusedId: () => (typeof focused === "number" ? (panes[focused] && panes[focused].mod) : (floats[+String(focused).slice(2)] || {}).mod) || "",
    stash,
    async restore(fallbackId) {
      const s = load();
      if (!s || !Array.isArray(s.panes) || !s.panes.length) { await show(fallbackId, 0); return; }
      fr = Array.isArray(s.fr) && s.fr.length ? s.fr.map((x) => Number(x) || 1) : [1, 1, 1];
      while (panes.length < Math.min(3, s.panes.length)) panes.push(makePane());
      renderLayout();
      const first = s.panes[0] || fallbackId;
      await show(first, 0);
      for (let i = 1; i < panes.length; i++) { if (s.panes[i]) await show(s.panes[i], i); else emptyState(panes[i], i); }
      for (const g of (s.floats || []).slice(0, 4)) { if (g && g.mod) await openFloating(g.mod, { x: g.x, y: g.y, w: g.w, h: g.h }); }
      focus(Math.min(Number(s.focused) || 0, panes.length - 1));
    },
  };
  return api;
}
