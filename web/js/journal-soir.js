/* journal-soir.js — LOT3 (25/10/2026) : « Journal du soir » (rituel Dictée du soir — Luna, 21:15).
   Moteur : Sources/NovaCore/Feat_JournalSoir.swift.
     GET  /api/journal-soir               → { entries:[…], aujourdhui:{day, carte, entrees} }
     POST /api/journal-soir/ouvrir        → ouvre la carte au Fil direct (une par jour pour le rituel)
     POST /api/journal-soir/entree        {texte, via, feed} → { entry } (tri Actions / Idées / Humeur, cerveau actif)
     POST /api/journal-soir/retrier       {id}
     POST /api/journal-soir/action        {id, action, decision: confirmer|ignorer} → l'engagement n'est créé QU'à « Confirmer »
   Dictée : la dictée NATIVE du Mac (POST /api/voix/dictee/start|stop|annuler, partiels sur le bus « voix_dictee »,
   comme voice.js). Le texte reste éditable avant l'envoi au tri. Aucun envoi à quiconque : tout reste dans Nova.
   Exporte : renderJournalSoirCard(m, ctx, live) pour le Fil direct (feedcard.js) et mountJournalSoirSection(el, ctx)
   pour l'écran Journal. */
import { api, bus, h as coreH, fmtTimeFR } from "./core.js";
import { ic as coreIc } from "./icons.js";
import * as ds from "./ds.js";

const MAX_MS = 180000;   // garde-fou : 3 min de dictée
const TON = { positif: ["ok", "positif"], neutre: ["neutral", "neutre"], negatif: ["warn", "difficile"], inconnu: ["neutral", "non dite"] };
const dayLabel = (d) => {
  const t = new Date(String(d || "") + "T12:00:00");
  if (isNaN(t)) return String(d || "");
  const s = t.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });
  return s.charAt(0).toUpperCase() + s.slice(1);
};
const post = (p, b, ms) => api.post(p, b, ms);

/* ── Dictée native → zone éditable → « Trier » ─────────────────────────── */
function dictBox({ h, ic, feed, onEntry }) {
  const ta = h("textarea", { class: "fld js-text", rows: "4", placeholder: "Ta journée en quelques phrases — ce qui reste à faire, une idée, comment tu te sens.", "aria-label": "Texte du journal du soir" });
  const st = h("div", { class: "ds-meta js-st", role: "status" });
  let listening = false, unsub = null, timer = 0, base = "";
  const btnDict = ds.action({ label: "Dicter", icon: "mic", primary: true, tip: "Dictée native du Mac — parle, puis « Terminer »", onClick: () => start() });
  const btnStop = ds.action({ label: "Terminer", icon: "stop", tip: "Arrêter la dictée", onClick: () => stop() });
  const btnSend = ds.action({ label: "Trier ma journée", icon: "sparkle", tip: "Un appel au cerveau actif : Actions / Idées / Humeur — les actions restent proposées", onClick: () => send() });
  btnStop.hidden = true;
  const acts = h("div", { class: "ds-actions js-acts" }, btnDict, btnStop, btnSend);
  const box = h("div", { class: "js-dict" }, ta, acts, st);
  async function start() {
    if (listening) return;
    btnDict.disabled = true; st.textContent = "Ouverture du micro…";
    let j = null;
    try { j = await post("/api/voix/dictee/start", {}, 10000); } catch (e) { j = null; }
    if (!j || j.ok !== true) {
      btnDict.disabled = false;
      st.textContent = "Dictée native indisponible" + (j && (j.erreur || j.error) ? " : " + String(j.erreur || j.error) : "") + " — tu peux écrire ta journée ci-dessus.";
      try { ta.focus(); } catch (e) {}
      return;
    }
    listening = true; base = ta.value.trim();
    btnDict.hidden = true; btnStop.hidden = false; btnSend.disabled = true;
    box.classList.add("is-live");
    st.textContent = "J'écoute… parle librement, puis « Terminer » (3 min au plus).";
    unsub = bus.on("voix_dictee", (d) => {
      if (!d || typeof d !== "object" || !listening) return;
      if (typeof d.partiel === "string") ta.value = (base ? base + " " : "") + d.partiel;
      if (d.etat === "erreur" && d.erreur) st.textContent = "Dictée : " + String(d.erreur);
    });
    timer = setTimeout(() => { if (listening) stop(); }, MAX_MS);
  }
  async function stop() {
    if (!listening) return;
    listening = false; clearTimeout(timer);
    btnStop.disabled = true; st.textContent = "Transcription…";
    const heard = ta.value.trim();
    let j = null;
    try { j = await post("/api/voix/dictee/stop", {}, 12000); } catch (e) { j = null; }
    if (unsub) { try { unsub(); } catch (e) {} unsub = null; }
    if (!j || j.ok !== true) { try { post("/api/voix/dictee/annuler", {}, 4000).catch(() => {}); } catch (e) {} }
    const t = j && j.ok === true ? String(j.text || "").trim() : "";
    ta.value = t ? (base ? base + " " : "") + t : heard;
    box.classList.remove("is-live");
    btnStop.hidden = true; btnStop.disabled = false; btnDict.hidden = false; btnDict.disabled = false; btnSend.disabled = false;
    st.textContent = ta.value.trim() ? "Relis ou corrige, puis « Trier ma journée »." : "Aucune parole reconnue — réessaie près du micro, ou écris.";
  }
  async function send() {
    const texte = ta.value.trim();
    if (texte.length < 3) { st.textContent = "Rien à trier pour l'instant."; return; }
    btnSend.disabled = true; btnDict.disabled = true;
    st.textContent = "Tri par le cerveau actif… (jusqu'à une minute)";
    try {
      const j = await post("/api/journal-soir/entree", { texte, via: "dictee", feed: feed || "" }, 90000);
      if (!j || !j.entry) throw new Error("réponse sans entrée");
      ta.value = "";
      st.textContent = j.entry.erreur ? "Journée gardée telle quelle — tri impossible : " + String(j.entry.erreur) : "Journée rangée dans le Journal.";
      if (onEntry) onEntry(j.entry);
    } catch (e) {
      st.textContent = "Envoi impossible : " + String((e && e.message) || e) + " — ton texte est toujours là.";
    }
    btnSend.disabled = false; btnDict.disabled = false;
  }
  box.cancel = () => { if (listening) { listening = false; clearTimeout(timer); try { post("/api/voix/dictee/annuler", {}, 4000).catch(() => {}); } catch (e) {} if (unsub) { try { unsub(); } catch (e) {} unsub = null; } } };
  return box;
}

/* ── Une entrée triée : humeur + rythme mesuré, actions proposées, idées, texte ── */
export function entryView(e, ctx = {}, onChange = null) {
  const h = ctx.h || coreH;
  const hm = (e && e.humeur) || {};
  const ton = TON[String(hm.ton || "inconnu")] || TON.inconnu;
  const when = e && e.ts ? fmtTimeFR(e.ts) : "";
  const head = h("div", { class: "js-e-head" },
    h("span", { class: "ds-h3" }, dayLabel(e.day) + (when ? " · " + when : "")),
    ds.pill(hm.mot ? String(hm.mot) : "humeur " + ton[1], ton[0]));
  const kids = [head];
  if (e.lien) kids.push(h("div", { class: "ds-meta js-e-lien", title: (e.soir && e.soir.source) || "" }, String(e.lien)));
  if (e.erreur) {
    kids.push(h("div", { class: "js-e-err" }, ds.pill("Tri impossible", "warn"), " ", h("span", { class: "ds-meta" }, String(e.erreur)),
      " ", ds.action({ label: "Relancer le tri", ghost: true, onClick: async () => {
        try { const j = await post("/api/journal-soir/retrier", { id: e.id }, 90000); if (j && j.entry && onChange) onChange(j.entry); }
        catch (err) { if (ctx.toast) ctx.toast("Tri : " + String((err && err.message) || err), true); }
      } })));
  }
  const actions = Array.isArray(e.actions) ? e.actions : [];
  if (actions.length) {
    kids.push(h("div", { class: "ds-meta js-e-lbl" }, "Actions"));
    kids.push(h("div", { class: "ds-list" }, ...actions.map((a) => {
      const prop = (a.statut || "propose") === "propose";
      const meta = [a.qui ? "avec " + a.qui : "", a.echeance ? "échéance " + a.echeance : "", a.citation ? "« " + a.citation + " »" : ""].filter(Boolean).join(" · ");
      const side = prop ? ds.pill("Proposé", "neutral") : a.statut === "confirme" ? ds.pill("Engagement", "ok") : ds.pill("Ignoré", "neutral");
      const acts = prop ? [
        { label: "Confirmer", icon: "check", primary: true, tip: "Crée l'engagement (écran Engagements)", onClick: () => decide(a, "confirmer") },
        { label: "Ignorer", ghost: true, onClick: () => decide(a, "ignorer") },
      ] : null;
      return ds.row({ lead: "check", title: String(a.quoi || ""), meta, side, actions: acts });
    })));
  }
  async function decide(a, decision) {
    try {
      const j = await post("/api/journal-soir/action", { id: e.id, action: a.id, decision }, 15000);
      if (ctx.toast) ctx.toast(decision === "confirmer" ? "Engagement créé : " + String(a.quoi || "") : "Action ignorée.");
      if (j && j.entry && onChange) onChange(j.entry);
    } catch (err) { if (ctx.toast) ctx.toast("Action : " + String((err && err.message) || err), true); }
  }
  const idees = Array.isArray(e.idees) ? e.idees : [];
  if (idees.length) {
    kids.push(h("div", { class: "ds-meta js-e-lbl" }, "Idées"));
    kids.push(h("ul", { class: "js-e-idees" }, ...idees.map((t) => h("li", {}, String(t)))));
  }
  if (!e.erreur && !actions.length && !idees.length) kids.push(h("div", { class: "ds-meta" }, "Ni action ni idée relevée dans cette dictée."));
  if (e.texte) kids.push(ds.fold("Ce que tu as dicté", [h("p", { class: "js-e-txt" }, String(e.texte))]));
  return ds.card({ class: "js-entry" }, ...kids);
}

/* ── Carte du Fil direct « 2 minutes pour ta journée ? » ───────────────── */
export function renderJournalSoirCard(m, ctx = {}, live = false) {
  const h = ctx.h || coreH, ic = ctx.ic || coreIc;
  const time = (() => { const d = new Date(m.ts || 0); return isNaN(d) || !m.ts ? "" : d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); })();
  const card = h("div", { class: "msg nova direct-msg fc fc-js" + (live ? " fd-in" : ""), "data-pri": "info" });
  card.append(h("div", { class: "fc-head" },
    h("span", { class: "fc-src" }, h("span", { html: ic("moon", 14) }), "Journal du soir"),
    h("span", { class: "fc-pri p-info" }, "Rituel"),
    h("span", { class: "sp" }),
    h("span", { class: "fc-time" }, time)));
  card.append(h("div", { class: "fc-bluf" }, h("b", {}, "2 minutes pour ta journée ?")));
  card.append(h("div", { class: "fc-note" }, "Dicte ce qui reste de ta journée : Nova trie en Actions, Idées et Humeur. Les actions restent proposées tant que tu ne les confirmes pas ; rien n'est envoyé."));
  const out = h("div", { class: "js-out" });
  const box = dictBox({ h, ic, feed: String(m.feed || ""), onEntry: (e) => {
    out.replaceChildren(entryView(e, ctx, (ne) => out.replaceChildren(entryView(ne, ctx, null))));
    if (ctx.navigate) out.append(h("div", { class: "fc-meta" }, h("span", { class: "sp" }), h("button", { class: "btn sm ghost", onclick: () => ctx.navigate("journal") }, "Ouvrir le Journal", h("span", { html: ic("arrow-up-right", 12) }))));
  } });
  card.append(box, out);
  if (live) { try { window.dispatchEvent(new CustomEvent("nova:feed-arrival", { detail: { gravite: "", urgent: false, kind: "journal.soir" } })); } catch (e) {} }
  return card;
}

/* ── Section « Journal du soir » de l'écran Journal ───────────────────── */
export function mountJournalSoirSection(ctx) {
  const h = ctx.h || coreH, ic = ctx.ic || coreIc;
  const sec = ds.section({ title: "Journal du soir", actions: [{ label: "Dicter maintenant", icon: "mic", onClick: () => { composer.hidden = !composer.hidden; } }] });
  const composer = h("div", { class: "js-compose" });
  composer.hidden = true;
  const list = h("div", { class: "js-list" });
  sec.body.append(composer, list);
  composer.append(dictBox({ h, ic, feed: "", onEntry: () => { composer.hidden = true; load(); } }));
  let dead = false;
  async function load() {
    if (!list.childElementCount) list.replaceChildren(ds.skeleton(2));
    let j = null;
    try { j = await api.get("/api/journal-soir?limit=30", 15000); } catch (e) { j = null; }
    if (dead) return;
    if (!j || !Array.isArray(j.entries)) { list.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé le journal du soir.", retry: () => load() })); return; }
    const n = j.entries.length;
    let c = sec.querySelector(":scope > .ds-section-head > .ds-count");
    if (n && !c) { c = h("span", { class: "ds-count" }); sec.querySelector(".ds-h2").after(c); }
    if (c) c.textContent = n ? String(n) : "";
    if (!n) {
      list.replaceChildren(ds.empty({ icon: "moon", text: "Aucune entrée pour l'instant. Le rituel de 21:15 t'invite au Fil direct ; tu peux aussi dicter maintenant.", action: { label: "Dicter maintenant", icon: "mic", onClick: () => { composer.hidden = false; } } }));
      return;
    }
    const nodes = [];
    for (const e of j.entries) {
      const holder = h("div", {});
      holder.append(entryView(e, ctx, (ne) => holder.replaceChildren(entryView(ne, ctx, null))));
      nodes.push(holder);
    }
    list.replaceChildren(...nodes);
  }
  load();
  const off = bus.on("journal_soir", () => { if (!dead) load(); });
  sec.destroy = () => { dead = true; try { off && off(); } catch (e) {} };
  return sec;
}
