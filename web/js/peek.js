/* peek.js — APERÇUS VIVANTS DES PAGES (V4-A, 24/10/2026).

   Une seule source pour deux surfaces :
     · la « Live Peek Card » : survol 350 ms d'une entrée de la barre latérale → carte de verre
       260×160 à droite de la barre, état RÉEL de la page, sans quitter l'écran actif ;
     · les cartes d'aperçu de l'état vide « Panneau libre » (workspace.js).

   Discipline :
     · uniquement les routes existantes du moteur ; une route absente ou en erreur = état honnête
       (« indisponible »), JAMAIS un chiffre inventé ;
     · Finance : coffre verrouillé (423) → on le DIT, aucun montant n'est affiché ;
     · cache court (30 s) + requêtes en vol partagées : survoler dix fois = un seul appel ;
     · aucune requête en rafale : le survol attend 350 ms, la sortie annule. */
import { api, h } from "./core.js";
import { ic } from "./icons.js";

const TTL = 30000;
const cache = new Map();      // id -> { at, data }
const inflight = new Map();   // id -> Promise

const arr = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const toDate = (v) => {
  if (v == null || v === "") return null;
  const n = Number(v);
  const d = isFinite(n) && n > 0 ? new Date(n < 1e12 ? n * 1000 : n) : new Date(String(v));
  return isNaN(d.getTime()) ? null : d;
};
function relTime(d) {
  if (!d) return "";
  const s = Math.round((Date.now() - d.getTime()) / 1000);
  if (s < 0) { const m = Math.round(-s / 60); return m < 60 ? "dans " + m + " min" : m < 1440 ? "dans " + Math.round(m / 60) + " h" : "dans " + Math.round(m / 1440) + " j"; }
  if (s < 60) return "à l'instant";
  if (s < 3600) return "il y a " + Math.round(s / 60) + " min";
  if (s < 86400) return "il y a " + Math.round(s / 3600) + " h";
  return "il y a " + Math.round(s / 86400) + " j";
}
const fmtF = (n) => Math.round(Number(n) || 0).toLocaleString("fr-FR").replace(/ | /g, " ");
const pct = (v) => (v >= 0 ? "+" : "") + (Number(v) || 0).toFixed(2).replace(".", ",") + " %";
const hhmm = (d) => d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
const isLocked = (e) => /423|verrouill/i.test(String((e && (e.status || e.message)) || ""));
const clip = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };

/* Chaque source renvoie { big?, unit?, sub?, tone?, lines?:[{t, s?}], note?, state } — state ∈ ok | empty | locked | off. */
const SOURCES = {
  async finance() {
    let d = null;
    try { d = await api.get("/api/portfolio", 8000); }
    catch (e) { return isLocked(e) ? { state: "locked", sub: "Coffre verrouillé", note: "Aucun montant n'est affiché tant que le coffre est fermé." } : { state: "off", sub: "Portefeuille injoignable" }; }
    const quotes = (d && d.quotes) || {};
    let total = 0, prev = 0, n = 0, top = null;
    for (const acc of Object.values((d && d.accounts) || {})) {
      total += Number(acc.cash) || 0; prev += Number(acc.cash) || 0;
      for (const p of acc.positions || []) {
        const q = quotes[p.sym] || null; const price = q ? Number(q.price) : Number(p.cours_releve) || Number(p.cmp) || 0;
        const v = (Number(p.qty) || 0) * price; const vp = q ? Number(q.var) || 0 : 0;
        total += v; prev += v / (1 + vp / 100); n++;
        if (q && (!top || Math.abs(vp) > Math.abs(top.v))) top = { s: p.sym || p.name, v: vp };
      }
    }
    if (!n) return { state: "empty", sub: "Aucun relevé SBIF importé", note: "Importe un relevé pour suivre ton portefeuille." };
    const dv = prev ? (total / prev - 1) * 100 : 0;
    return { state: "ok", big: fmtF(total), unit: "FCFA", sub: (dv >= 0 ? "▲ " : "▼ ") + pct(dv) + " aujourd'hui", tone: dv >= 0 ? "up" : "down",
      lines: top ? [{ t: top.s, s: pct(top.v) }] : [], note: d.quotes_at ? "Cours BRVM " + relTime(toDate(d.quotes_at)) : n + " ligne(s) suivie(s)" };
  },
  async veille() {
    let ov = null, fund = null;
    try { ov = await api.get("/api/feeds/overview", 8000); } catch (e) {}
    try { fund = await api.get("/api/fundings", 8000); } catch (e) {}   // livré par le lot C — absent = on n'affiche pas d'échéance
    const units = arr(ov, "units").filter((u) => u && u.title).slice().sort((a, b) => String(b.ts || "").localeCompare(String(a.ts || ""))).slice(0, 2);
    const next = arr(fund, "prochaines")[0] || arr(ov && ov.fundings, "prochaines")[0] || null;
    const lines = units.map((u) => ({ t: clip(u.title, 64), s: relTime(toDate(u.ts)) }));
    if (!lines.length && !next) return { state: ov || fund ? "empty" : "off", sub: ov || fund ? "Aucun signal récent" : "Feeds injoignable" };
    const unread = ov && ov.unread && Number(ov.unread.tout);
    return { state: "ok", sub: unread ? unread + " non lu" + (unread > 1 ? "s" : "") : "Derniers signaux", lines,
      note: next ? "Échéance " + String(next.date || "").slice(8, 10) + "/" + String(next.date || "").slice(5, 7) + (next.heure ? " " + next.heure : "") + " · " + clip(next.label || next.programme, 48) : "" };
  },
  async dots() {
    let all = null, act = [], wait = [];
    try { all = await api.get("/api/dots", 8000); } catch (e) { return { state: "off", sub: "Éclats injoignables" }; }
    try { act = arr(await api.get("/api/dots/active", 8000), "items", "runs", "active"); } catch (e) {}
    try { wait = arr(await api.get("/api/dots/waiting", 8000), "items"); } catch (e) {}
    const parc = arr(all, "items").filter((x) => x && x.paused !== true && x.enabled !== false).length;
    const lines = wait.slice(0, 2).map((x) => ({ t: clip((x.name || "Un Éclat") + (x.decision ? " attend ton GO" : " a terminé"), 60), s: relTime(toDate(x.ts)) }));
    const last = arr(all, "runs")[0];
    return { state: "ok", ...(act.length ? { big: String(act.length), unit: act.length > 1 ? "tournent en ce moment" : "tourne en ce moment" } : {}), tone: wait.length ? "warn" : "",
      sub: wait.length ? wait.length + " attend" + (wait.length > 1 ? "ent" : "") + " ton GO" : act.length ? "Aucun GO en attente" : "Aucun ne tourne · aucun GO en attente", lines,
      note: (parc ? parc + " actif" + (parc > 1 ? "s" : "") + " au parc" : "Parc vide") + (last ? " · dernier " + relTime(toDate(last.ts)) : "") };
  },
  async messages() {
    let d = null; try { d = await api.get("/api/drafts", 8000); } catch (e) { return { state: "off", sub: "Messagerie injoignable" }; }
    const pend = arr(d, "items").filter((x) => !x.sent && String(x.status || "") !== "sent");
    return { state: pend.length ? "ok" : "empty", ...(pend.length ? { big: String(pend.length), unit: "brouillon" + (pend.length > 1 ? "s" : "") + " à relire" } : {}),
      lines: pend.slice(0, 2).map((x) => ({ t: clip(x.subject || x.title || x.to || "Message", 56), s: clip(x.channel || "", 14) })), sub: pend.length ? "" : "Rien à approuver" };
  },
  async temps() {
    let evs = []; try { evs = arr(await api.get("/api/today", 8000), "items"); } catch (e) { return { state: "off", sub: "Agenda injoignable" }; }
    const now = Date.now() / 1000;
    const up = evs.map((e) => ({ t: Number(e.ts) || 0, l: String(e.title || e.label || "Événement") })).filter((e) => e.t > now - 1800).sort((a, b) => a.t - b.t);
    if (!up.length) return { state: "empty", sub: "Aucun rendez-vous à venir" };
    return { state: "ok", sub: "Prochains rendez-vous", lines: up.slice(0, 3).map((e) => { const d = new Date(e.t * 1000); return { t: clip(e.l, 52), s: (d.toDateString() === new Date().toDateString() ? "" : d.toLocaleDateString("fr-FR", { weekday: "short" }).replace(".", "") + " ") + hhmm(d) }; }) };
  },
  async engagements() {
    let it = []; try { it = arr(await api.get("/api/commitments", 8000), "items"); } catch (e) { return { state: "off", sub: "Engagements injoignables" }; }
    const open = it.filter((c) => (c.status || "ouvert") === "ouvert");
    const iso = new Date().toISOString().slice(0, 10);
    const due = open.filter((c) => c.echeance && String(c.echeance) <= iso);
    return { state: open.length ? "ok" : "empty", ...(open.length ? { big: String(open.length), unit: "ouvert" + (open.length > 1 ? "s" : "") } : {}), tone: due.length ? "warn" : "",
      sub: due.length ? due.length + " échu" + (due.length > 1 ? "s" : "") + " ou dû aujourd'hui" : open.length ? "Rien d'échu" : "Aucun engagement ouvert",
      lines: open.slice().sort((a, b) => String(a.echeance || "9").localeCompare(String(b.echeance || "9"))).slice(0, 2).map((c) => ({ t: clip((c.quoi || "Engagement") + (c.qui ? " · " + c.qui : ""), 54), s: String(c.echeance || "").slice(5).split("-").reverse().join("/") })) };
  },
  async conseil() {
    let it = []; try { it = arr(await api.get("/api/council/history", 8000), "items"); } catch (e) { return { state: "off", sub: "Conseil injoignable" }; }
    if (!it.length) return { state: "empty", sub: "Aucune délibération archivée" };
    const pend = it.filter((x) => x.pending).length;
    return { state: "ok", sub: pend ? pend + " séance(s) attendent ton GO" : it.length + " délibération" + (it.length > 1 ? "s" : ""), tone: pend ? "warn" : "",
      lines: it.slice(0, 2).map((x) => ({ t: clip(x.title || "Délibération", 56), s: relTime(toDate(x.updated || x.created)) })) };
  },
  async livrables() {
    let it = []; try { it = arr(await api.get("/api/livrables", 8000), "items"); } catch (e) { return { state: "off", sub: "Livrables injoignables" }; }
    if (!it.length) return { state: "empty", sub: "Aucun livrable produit" };
    return { state: "ok", big: String(it.length), unit: "document" + (it.length > 1 ? "s" : ""), lines: it.slice(0, 2).map((x) => ({ t: clip(x.title || x.name, 52), s: String(x.format || "").toUpperCase() })) };
  },
  async vie() {
    let p = [], n = [];
    try { p = arr(await api.get("/api/projects", 8000), "items", "projects"); } catch (e) {}
    try { n = arr(await api.get("/api/notes", 8000), "items", "notes"); } catch (e) {}
    if (!p.length && !n.length) return { state: "empty", sub: "Aucun projet ni note" };
    return { state: "ok", sub: p.length + " projet" + (p.length > 1 ? "s" : "") + " · " + n.length + " note" + (n.length > 1 ? "s" : ""), lines: p.slice(0, 2).map((x) => ({ t: clip(x.name || x.title, 54) })) };
  },
};

/** État réel d'une page — cache 30 s, requêtes en vol partagées. null = pas de source (page sans aperçu chiffré). */
export function hasPeek(id) { return Object.prototype.hasOwnProperty.call(SOURCES, id); }
export async function peekData(id) {
  if (!hasPeek(id)) return null;
  const c = cache.get(id);
  if (c && Date.now() - c.at < TTL) return c.data;
  if (inflight.has(id)) return inflight.get(id);
  const p = (async () => {
    let data;
    try { data = await SOURCES[id](); } catch (e) { data = { state: "off", sub: "Aperçu indisponible" }; }
    cache.set(id, { at: Date.now(), data }); inflight.delete(id);
    return data;
  })();
  inflight.set(id, p);
  return p;
}

/** Corps d'aperçu (mini-tableau de bord) — mêmes classes pour la carte de survol et le panneau libre. */
export function peekBody(id, data, desc) {
  const box = h("div", { class: "pk-body" });
  if (!data) { box.append(h("div", { class: "pk-desc" }, desc || "")); return box; }
  if (data.state === "locked") box.append(h("div", { class: "pk-lock" }, h("span", { html: ic("lock-closed", 16) }), h("span", {}, data.sub)));
  else if (data.big != null) box.append(h("div", { class: "pk-big" }, h("span", { class: "pk-v num" }, data.big), data.unit ? h("span", { class: "pk-u" }, " " + data.unit) : ""));
  if (data.sub && data.state !== "locked") box.append(h("div", { class: "pk-sub" + (data.tone ? " " + data.tone : "") + (data.state === "off" ? " off" : "") }, data.sub));
  if (data.lines && data.lines.length) box.append(h("div", { class: "pk-lines" }, ...data.lines.map((l) => h("div", { class: "pk-line" }, h("span", { class: "pk-lt" }, l.t), l.s ? h("span", { class: "pk-ls num" }, l.s) : ""))));
  if (data.note) box.append(h("div", { class: "pk-note" }, data.note));
  return box;
}

/* ── Live Peek Card de la barre latérale ──────────────────────────────── */
export function initRailPeek({ rail, modules }) {
  if (!rail || rail.__peek) return;
  rail.__peek = true;
  let timer = 0, card = null, curBtn = null, token = 0;
  const meta = (id) => (modules || []).find((m) => m.id === id) || { id, label: id, icon: "dot", desc: "" };
  const idOf = (b) => b.dataset.page || "";
  /* 24/10 : la bulle native (title) recouvrait la carte — retirée pendant l'aperçu, rendue à la fermeture. */
  let tipBtn = null;
  const hideTip = (b) => { restoreTip(); if (b && b.title) { b.dataset.pkTitle = b.title; b.removeAttribute("title"); tipBtn = b; } };
  const restoreTip = () => { if (tipBtn && tipBtn.dataset.pkTitle != null) { tipBtn.title = tipBtn.dataset.pkTitle; delete tipBtn.dataset.pkTitle; } tipBtn = null; };
  const close = () => { clearTimeout(timer); timer = 0; token++; curBtn = null; restoreTip(); if (card) { const c = card; card = null; c.classList.remove("in"); setTimeout(() => c.remove(), 160); } };
  const fits = () => { const sh = document.querySelector(".shell"); if (!sh || sh.classList.contains("sb-mini") || document.documentElement.dataset.rail === "mini") return false; const r = rail.getBoundingClientRect(); return innerWidth - r.right >= 260 + 24; };
  async function open(b) {
    const id = idOf(b); if (!id || !fits()) return;
    const m = meta(id); const my = ++token;
    hideTip(b);
    if (card) card.remove();
    card = h("div", { class: "peek-card", role: "tooltip", "aria-live": "polite" },
      h("div", { class: "pk-head" }, h("span", { class: "pk-ic", html: ic(m.icon, 15) }), h("b", {}, m.label), h("span", { class: "sp" }), h("span", { class: "pk-live" }, hasPeek(id) ? "en direct" : "")),
      hasPeek(id) ? h("div", { class: "pk-body" }, h("div", { class: "skel skel-line", style: "height:22px;width:60%" }), h("div", { class: "skel skel-line", style: "height:12px;width:85%;margin-top:10px" })) : peekBody(id, null, m.desc));
    const r = b.getBoundingClientRect(), rr = rail.getBoundingClientRect();
    const top = Math.max(8, Math.min(innerHeight - 168, r.top + r.height / 2 - 80));
    Object.assign(card.style, { left: Math.round(rr.right + 10) + "px", top: Math.round(top) + "px" });
    document.body.append(card);
    requestAnimationFrame(() => card && card.classList.add("in"));
    if (!hasPeek(id)) return;
    const data = await peekData(id);
    if (my !== token || !card) return;
    card.replaceChild(peekBody(id, data, m.desc), card.querySelector(".pk-body"));
  }
  rail.addEventListener("pointerover", (e) => {
    const b = e.target.closest && e.target.closest(".rail-btn");
    if (!b || !rail.contains(b) || b.classList.contains("sb-toggle")) return;
    if (b === curBtn) return;
    clearTimeout(timer); curBtn = b; if (fits()) hideTip(b);
    if (card) { open(b); return; }   // déjà ouverte : on glisse d'une entrée à l'autre sans réattendre
    timer = setTimeout(() => open(b), 350);
  });
  rail.addEventListener("pointerleave", close);
  rail.addEventListener("pointerdown", close, true);
  window.addEventListener("keydown", (e) => { if (e.key === "Escape" && card) close(); });
  window.addEventListener("blur", close);
  window.addEventListener("resize", close);
}
