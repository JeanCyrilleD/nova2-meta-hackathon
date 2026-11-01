/* autodraft.js — « BROUILLON PRÊT » sur la carte d'une arrivée du Fil direct (25/10, approuvé par Ahadi).
   Le moteur (Feat_Autonomie.swift) rédige en arrière-plan un brouillon de réponse dans la voix d'Ahadi
   pour une arrivée « à toi » ou urgente qui appelle une réponse, et le range dans la file EXISTANTE
   (brouillons.json, origine « auto »). Ce bloc ne fait que le montrer et y mener :
     Voir      le texte tel qu'il est en file
     Modifier  POST /api/drafts/update (destinataire, objet, corps — coche et empreinte recalculées)
     Envoyer   ouvre la carte d'approbation de Messages (nova:draft-focus) — l'envoi attend ENVOYER
     Ignorer   POST /api/autonomie/brouillons/ignorer — retiré de la file, jamais envoyé
   Rien ne part d'ici. Source : GET /api/autonomie/brouillons (registre joint à la file). */
import { api, bus, showToast, h as coreH } from "./core.js";
import { ic as coreIc } from "./icons.js";

const CACHE = { at: 0, map: null, busy: null };
const TTL = 20000;

async function loadMap(force) {
  if (!force && CACHE.map && Date.now() - CACHE.at < TTL) return CACHE.map;
  if (CACHE.busy) return CACHE.busy;
  CACHE.busy = (async () => {
    try {
      const j = await api.get("/api/autonomie/brouillons", 10000);
      const m = new Map();
      for (const it of (j && Array.isArray(j.items) ? j.items : [])) if (it && it.feed) m.set(String(it.feed), it);
      CACHE.map = m; CACHE.at = Date.now();
    } catch (e) { if (!CACHE.map) CACHE.map = new Map(); }
    CACHE.busy = null;
    return CACHE.map;
  })();
  return CACHE.busy;
}

function lintInfo(d) {
  const items = (d && d.lint && Array.isArray(d.lint.items)) ? d.lint.items : [];
  const bad = items.filter((x) => x && x.hard && !x.ok);
  return { known: items.length > 0, bad };
}

function paint(card, it, ctx) {
  const h = (ctx && ctx.h) || coreH, ic = (ctx && ctx.ic) || coreIc;
  const old = card.querySelector(".ad-block"); if (old) old.remove();
  const st = String(it.status || "");
  let block = null;
  if (st === "en_cours") {
    block = h("div", { class: "ad-block va-status", role: "status" }, h("span", { html: ic("draft", 12) }), " Nova prépare un brouillon de réponse dans ta voix…");
  } else if (st === "envoye") {
    block = h("div", { class: "ad-block va-status" }, h("span", { html: ic("check", 12) }), " Réponse envoyée — après ton ENVOYER dans Messages.");
  } else if (st === "pret" && it.draft) {
    block = readyBlock(card, it, ctx);
  }
  if (!block) return;
  block.addEventListener("click", (e) => e.stopPropagation());
  const meta = card.querySelector(".fc-meta");
  if (meta) card.insertBefore(block, meta); else card.append(block);
}

function readyBlock(card, it, ctx) {
  const h = (ctx && ctx.h) || coreH, ic = (ctx && ctx.ic) || coreIc;
  const d = it.draft;
  const isTeams = d.channel === "teams";
  const dest = String((isTeams ? d.target : d.to) || "").trim();
  const li = lintInfo(d);
  const panel = h("div", { class: "ad-block va-panel", role: "region", "aria-label": "Brouillon prêt" });
  const status = h("div", { class: "va-status", role: "status" });
  const view = h("div", { class: "ad-view", hidden: true, style: "white-space:pre-wrap;font:13px/19px var(--f-ui);max-height:320px;overflow:auto" }, String(d.body || ""));
  const editZone = h("div", { class: "ad-edit", hidden: true });
  const lintEl = h("div", { class: "va-lint" + (li.bad.length ? " bad" : " ok") },
    h("span", { html: ic(li.bad.length ? "alert" : "check", 13) }),
    " " + (!li.known ? "" : li.bad.length ? "Coche gabarit : à corriger avant l'envoi — " + li.bad.map((x) => x.label).join(" · ") : "Coche gabarit : tout est vert"));
  const btn = (label, cls, title, fn) => { const b = h("button", { class: "btn sm " + (cls || ""), title: title || "" }, label); b.addEventListener("click", (e) => { e.stopPropagation(); fn(b); }); return b; };
  const goMessages = () => {
    if (!ctx || !ctx.navigate) { showToast("Ouvre Messages › À approuver : le brouillon t'y attend."); return; }
    ctx.navigate("messages");
    setTimeout(() => { try { bus.emit("nova:draft-focus", { id: String(d.id) }); } catch (e) {} }, 350);
  };
  const voir = btn("Voir", "ghost", "Afficher le texte du brouillon", (b) => { view.hidden = !view.hidden; b.textContent = view.hidden ? "Voir" : "Masquer"; });
  const modifier = btn("Modifier", "ghost", "Modifier destinataire, objet et texte — la coche et l'empreinte sont recalculées", () => {
    if (!editZone.hidden) { editZone.hidden = true; return; }
    const to = h("input", { class: "fld va-dest", type: isTeams ? "text" : "email", placeholder: isTeams ? "Conversation Teams (nom exact)" : "Adresse e-mail du destinataire", "aria-label": isTeams ? "Conversation Teams" : "Destinataire" });
    to.value = dest;
    const obj = h("input", { class: "fld va-obj", type: "text", placeholder: "Objet", "aria-label": "Objet" });
    obj.value = String(d.subject || "");
    const ta = h("textarea", { class: "fld fld-area va-text", rows: String(Math.min(16, Math.max(5, String(d.body || "").split("\n").length + 1))), "aria-label": "Texte du brouillon" });
    ta.value = String(d.body || "");
    const save = btn("Enregistrer", "acc", "Met à jour le brouillon en file — rien n'est envoyé", async (b) => {
      if (!isTeams && to.value.trim() && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to.value.split(/[,;]/)[0].trim())) { status.className = "va-status bad"; status.textContent = "Adresse e-mail invalide."; to.focus(); return; }
      b.disabled = true;
      const body = { id: String(d.id), body: ta.value };
      if (isTeams) body.target = to.value.trim(); else { body.to = to.value.trim(); body.subject = obj.value.trim(); }
      try {
        const j = await api.post("/api/drafts/update", body, 15000);
        if (j && j.ok === false) throw new Error(j.error || "mise à jour refusée");
        showToast("Brouillon mis à jour — toujours en attente de ton ENVOYER.");
        const fresh = await loadMap(true);
        const n = fresh.get(String(it.feed));
        if (n) paint(card, n, ctx);
      } catch (e) { b.disabled = false; status.className = "va-status bad"; status.textContent = "Mise à jour impossible : " + ((e && e.message) || e); }
    });
    editZone.replaceChildren(
      h("div", { class: "va-fields" },
        h("label", { class: "va-to" }, h("span", {}, isTeams ? "Conversation" : "À"), to),
        isTeams ? null : h("label", { class: "va-to" }, h("span", {}, "Objet"), obj)),
      ta,
      h("div", { class: "va-actions" }, h("span", { class: "sp" }), btn("Fermer", "ghost", "", () => { editZone.hidden = true; }), save));
    editZone.hidden = false;
    view.hidden = true;
  });
  const envoyer = btn([h("span", { html: ic("arrow-up-right", 12) }), " Envoyer"], "acc", "Ouvre la carte d'approbation dans Messages — l'envoi n'aura lieu qu'après ton ENVOYER", () => {
    if (!dest) { status.className = "va-status bad"; status.textContent = (isTeams ? "Conversation Teams" : "Destinataire") + " à compléter d'abord (Modifier)."; return; }
    goMessages();
  });
  const ignorer = btn("Ignorer", "ghost", "Retire ce brouillon de la file — rien n'est envoyé", async (b) => {
    b.disabled = true;
    try {
      const j = await api.post("/api/autonomie/brouillons/ignorer", { feed: String(it.feed) }, 10000);
      if (j && j.ok === false) throw new Error(j.error || "refusé");
      if (CACHE.map) CACHE.map.delete(String(it.feed));
      panel.remove();
      showToast("Brouillon ignoré et retiré de la file.");
    } catch (e) { b.disabled = false; status.className = "va-status bad"; status.textContent = "Impossible d'ignorer : " + ((e && e.message) || e); }
  });
  const who = isTeams ? "Teams · " + (dest || "conversation à compléter") : "À " + (dest || "destinataire à compléter");
  panel.append(
    h("div", { class: "va-head" },
      h("span", { class: "va-title" }, h("span", { html: ic("draft", 13) }), "Brouillon prêt"),
      h("span", { class: "ds-meta" }, who + (it.cerveau ? " · " + String(it.cerveau) : "")),
      h("span", { class: "sp" })),
    it.intention ? h("div", { class: "va-int" }, String(it.intention)) : null,
    lintEl, view, editZone, status,
    h("div", { class: "va-actions" }, h("span", { class: "ds-meta" }, "Rien n'est parti : l'envoi attend ton ENVOYER."), h("span", { class: "sp" }), voir, modifier, ignorer, envoyer));
  return panel;
}

/** Monte le bloc sur une carte d'arrivée mail/Teams (appelé par feedcard.js). Silencieux si rien n'existe. */
export async function mountAutoDraft(m, ctx, card) {
  const feed = String((m && m.feed) || "");
  if (!feed || !card) return;
  card.dataset.feed = feed;
  card._adCtx = ctx;
  const map = await loadMap(false);
  const it = map.get(feed);
  if (it && card.isConnected !== false) paint(card, it, ctx);
}

/* Direct : le moteur annonce un brouillon prêt (« autodraft ») — la carte déjà affichée se complète. */
if (typeof window !== "undefined" && !window.__novaAutoDraftBus) {
  window.__novaAutoDraftBus = true;
  try {
    bus.on("autodraft", async (d) => {
      const feed = String((d && d.feed) || "");
      const map = await loadMap(true);
      if (!feed) return;
      const it = map.get(feed);
      let cards = [];
      try { cards = [...document.querySelectorAll('.fc[data-feed="' + (window.CSS && CSS.escape ? CSS.escape(feed) : feed) + '"]')]; } catch (e) {}
      for (const c of cards) {
        if (it) paint(c, it, c._adCtx || null);
        else { const o = c.querySelector(".ad-block"); if (o) o.remove(); }
      }
    });
    bus.on("nova:draft-new", () => { CACHE.at = 0; });
  } catch (e) {}
}
