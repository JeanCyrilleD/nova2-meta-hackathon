/* Module Relations — vague 3, n°10 LE GARDIEN DES RELATIONS.
   Le moteur entretient déjà la mécanique (Ame.swift) : chaque matin dès 9 h, un Dot
   lit le document d'âme « relations » — [{name, cadence (jours), last (ISO), deuil}] —
   et signale les contacts dont le dernier échange dépasse la cadence, hors deuil.
   Ici : la même règle de calcul que le moteur, les contacts dus d'abord, et les gestes —
     · « Relancé » : last passe à aujourd'hui (POST /api/ame/doc, document entier) ;
     · « Brouillon » : POST /api/ame/llm kind « relation » — un brouillon généré, JAMAIS envoyé ;
     · « Deuil » : la relation sort du gardien sans être effacée ;
     · ajout / retrait d'un contact ; relecture des échanges (POST /api/relations/sync).
   Les entrées non structurées du document (lignes de texte libre) sont préservées telles quelles.
   V6 (25/10) — système de design : en-tête de page, liste d'abord (recherche + filtres à compteurs),
   lignes .ds-row (statut en pastille, actions au survol, « Relancé » toujours visible pour un contact
   en retard), suggestions en puces, formulaire d'ajout replié derrière « + Ajouter un contact »,
   squelette au chargement, erreur avec « Réessayer », vide avec action. */
import { md, fmtDateFR, setFieldError } from "../core.js";
import * as ds from "../ds.js";
const DAY = 86400000;
const fmtDate = (v) => { const d = v ? new Date(v) : null; return d && !isNaN(d) ? fmtDateFR(d) : "—"; };
const initials = (n) => { const p = String(n || "?").trim().split(/\s+/).filter(Boolean); return ((p[0] || "?")[0] + (p.length > 1 ? p[p.length - 1][0] : "")).toUpperCase(); };
const plural = (n, one, many) => n + " " + (Math.abs(n) > 1 ? many : one);

async function copyText(t) {
  try { if (navigator.clipboard && navigator.clipboard.writeText) { await navigator.clipboard.writeText(t); return true; } } catch (e) {}
  try { const ta = document.createElement("textarea"); ta.value = t; ta.style.position = "fixed"; ta.style.opacity = "0"; document.body.append(ta); ta.select(); const ok = document.execCommand("copy"); ta.remove(); return !!ok; } catch (e) { return false; }
}

export async function mount(root, ctx) {
  const { api, h } = ctx;
  let dead = false;
  root.classList.add("mod--data", "flx-rel");

  let raw = null;      // le document entier, tel quel (on ne perd aucune entrée) — null = jamais lu
  let filter = "tous", query = "";
  let syncState = null;
  let suggestions = [];
  let draftFor = null;  // { c, state: "load"|"ok"|"err", text }

  const contacts = () => (raw || []).filter((x) => x && typeof x === "object" && x.name);
  const libres = () => (raw || []).filter((x) => !(x && typeof x === "object" && x.name)).length;
  const daysSince = (c) => { const t = c.last ? Date.parse(c.last) : NaN; return isNaN(t) ? null : Math.floor((Date.now() - t) / DAY); };
  const isDue = (c) => { if (c.deuil) return false; const d = daysSince(c); const cad = Number(c.cadence) || 0; return d != null && cad > 0 && d > cad; };

  /* ── En-tête ─────────────────────────────────────────────────────── */
  const syncBtnDesc = { label: "Relire les échanges", icon: "refresh", tip: "Rapprocher les dates de dernier contact avec les messages reçus (Outlook, Gmail, Teams web)", onClick: () => sync() };
  root.append(ds.pageHead({
    title: "Relations",
    sub: "Le gardien des relations — les liens à entretenir, avant qu'ils ne s'éteignent",
    actions: [syncBtnDesc, { label: "Ajouter un contact", icon: "plus", primary: true, onClick: () => openAdd() }],
  }));
  const tbHost = h("div", {});
  const dueSec = ds.section({ title: "À relancer", count: 0 });
  const listSec = ds.section({ title: "Contacts suivis", count: 0 });
  const sugSec = ds.section({ title: "Suggestions", actions: null });
  sugSec.hidden = true;
  const draftHost = h("div", { class: "flx-rel-draft" });
  const addFold = h("details", { class: "ds-fold flx-rel-add" });
  const srcSec = ds.section({ title: "Source et rapprochement", collapsible: true, open: false });
  root.append(tbHost, dueSec, listSec, draftHost, sugSec, addFold, srcSec);
  dueSec.body.append(ds.skeleton(2));
  listSec.body.append(ds.skeleton(3));

  /* ── Formulaire d'ajout (replié) ─────────────────────────────────── */
  const nameIn = h("input", { class: "fld", type: "text", placeholder: "Nom du contact", autocomplete: "off" });
  const cadIn = h("input", { class: "fld", type: "number", min: "1", value: "30" });
  const lastIn = h("input", { class: "fld", type: "date" });
  const mailIn = h("input", { class: "fld", type: "text", placeholder: "adresse@… (facultatif)" });
  const annIn = h("input", { class: "fld", type: "text", placeholder: "JJ/MM (facultatif)", maxlength: "10" });
  try { lastIn.value = new Date().toISOString().slice(0, 10); } catch (e) {}
  lastIn.addEventListener("change", () => { const v = String(lastIn.value || ""); if (!v) { setFieldError(lastIn, null); return; } if (!/^\d{4}-\d{2}-\d{2}$/.test(v) || isNaN(Date.parse(v))) setFieldError(lastIn, "Date illisible — utilise le calendrier."); else setFieldError(lastIn, null); });
  const field = (lb, input, help) => h("label", { class: "field" }, h("span", { class: "field-lb" }, lb), input, help ? h("span", { class: "field-help" }, help) : null);
  const addContact = () => {
    const n = nameIn.value.trim(); if (!n) { setFieldError(nameIn, "Le nom du contact est requis."); nameIn.focus(); return; }
    setFieldError(nameIn, null);
    if (contacts().some((c) => String(c.name).trim().toLowerCase() === n.toLowerCase())) { setFieldError(nameIn, "Ce contact est déjà suivi."); return; }
    const an = annIn.value.trim();
    if (an && !/^\d{1,2}[\/.]\d{1,2}([\/.]\d{4})?$/.test(an)) { setFieldError(annIn, "Format JJ/MM attendu."); return; }
    setFieldError(annIn, null);
    const c = { name: n, cadence: Math.max(1, Number(cadIn.value) || 30), last: lastIn.value ? new Date(lastIn.value + "T12:00:00").toISOString() : new Date().toISOString(), deuil: false };
    if (mailIn.value.trim()) c.email = mailIn.value.trim();
    if (an) c.anniv = an;
    raw = raw || [];
    raw.push(c);
    nameIn.value = ""; mailIn.value = ""; annIn.value = "";
    addFold.open = false;
    save(n + " suivi par le gardien.");
  };
  nameIn.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); addContact(); } });
  addFold.append(
    h("summary", {}, "+ Ajouter un contact"),
    h("div", { class: "ds-fold-body" },
      h("div", { class: "flx-rel-form" },
        field("Nom du contact", nameIn),
        field("Cadence (jours)", cadIn, "Délai au-delà duquel le gardien signale le contact."),
        field("Dernier contact", lastIn),
        field("Adresse ou alias", mailIn, "Pour reconnaître ses messages reçus."),
        field("Anniversaire", annIn, "JJ/MM — rappel proposé 2 jours avant.")),
      h("div", { class: "flx-rel-form-act" },
        ds.action({ label: "Annuler", ghost: true, onClick: () => { addFold.open = false; } }),
        ds.action({ label: "Ajouter", primary: true, onClick: addContact }))));
  function openAdd(name) {
    addFold.open = true;
    if (name) nameIn.value = name;
    try { addFold.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (e) {}
    setTimeout(() => { try { nameIn.focus(); } catch (e) {} }, 60);
  }

  /* ── Enregistrement / gestes ─────────────────────────────────────── */
  async function save(okMsg) {
    try { await api.post("/api/ame/doc", { name: "relations", data: raw || [] }); if (okMsg) ctx.toast(okMsg); load(); }
    catch (e) { ctx.toast("Enregistrement impossible — le document « relations » n'a pas été modifié.", true); load(); }
  }
  function remove(c) {
    raw = raw.filter((x) => x !== c);
    save(String(c.name) + " retiré du suivi.");
  }
  async function draft(c) {
    draftFor = { c, state: "load", text: "" }; paintDraft();
    try {
      const r = await api.post("/api/ame/llm", { kind: "relation", input: "Reprise de contact avec " + c.name + " — dernier échange le " + fmtDate(c.last) + ", cadence souhaitée " + (Number(c.cadence) || "—") + " jours. Brouillon chaleureux et bref, sans pression, avec une porte de sortie explicite." });
      if (dead || !draftFor || draftFor.c !== c) return;
      draftFor.text = String((r && (r.text || r.md || r.result || r.plan)) || "");
      draftFor.state = draftFor.text ? "ok" : "err";
    } catch (e) { if (dead || !draftFor || draftFor.c !== c) return; draftFor.state = "err"; }
    paintDraft();
  }
  function paintDraft() {
    if (!draftFor) { draftHost.replaceChildren(); return; }
    const { c, state, text } = draftFor;
    const close = { icon: "close", tip: "Fermer le brouillon", onClick: () => { draftFor = null; paintDraft(); } };
    let body;
    if (state === "load") body = [h("p", { class: "ds-meta" }, "Le moteur rédige un brouillon de reprise…"), ds.skeleton(1)];
    else if (state === "err") body = [ds.errorBox({ title: "Brouillon indisponible", cause: "Le moteur n'a rien renvoyé pour ce brouillon.", retry: () => draft(c) })];
    else body = [
      h("p", { class: "ds-meta" }, "Généré par le moteur. Rien n'est envoyé : tu relis, tu copies, tu envoies toi-même si tu le décides."),
      h("div", { class: "brief-text flx-rel-draft-txt", html: md(text) }),
      h("div", { class: "flx-rel-form-act" },
        ds.action({ label: "Refaire", icon: "refresh", ghost: true, onClick: () => draft(c) }),
        ds.action({ label: "Copier le texte", primary: true, onClick: async () => { const ok = await copyText(text); ctx.toast(ok ? "Brouillon copié." : "Copie impossible — sélectionne le texte à la main.", !ok); } }))];
    draftHost.replaceChildren(ds.card({ title: "Brouillon de reprise — " + String(c.name), actions: [close] }, ...body));
    try { draftHost.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (e) {}
  }

  /* ── Lignes ──────────────────────────────────────────────────────── */
  function contactRow(c) {
    const due = isDue(c);
    const d = daysSince(c);
    const cad = Number(c.cadence) || 0;
    const over = due && d != null ? d - cad : 0;
    const meta = [
      c.last ? "Dernier contact " + fmtDate(c.last) + (d != null ? " (il y a " + plural(d, "jour", "jours") + ")" : "") : "Dernier contact —",
      cad ? "cadence " + cad + " j" : "cadence —",
      c.anniv ? "anniversaire " + String(c.anniv) : "",
    ].filter(Boolean).join(" · ");
    const prov = c.last_auto && c.last_source ? "Relevé par Nova : " + String(c.last_source) : c.last ? "Date saisie à la main" : "Aucune date : le gardien ne peut pas le déclarer en retard";
    const side = c.deuil ? ds.pill("En deuil", "neutral") : due ? ds.pill("En retard de " + over + " j", "danger") : !c.last || !cad ? ds.pill("À compléter", "warn") : ds.pill("Au calme", "ok");
    const acts = c.deuil
      ? [{ label: "Réactiver", tip: "Sortir cette relation du deuil — le gardien la suivra de nouveau", onClick: () => { c.deuil = false; save("Relation sortie du deuil."); } },
        { icon: "trash", tip: "Retirer ce contact du suivi", onClick: () => remove(c) }]
      : [{ label: "Brouillon", tip: "Générer un brouillon de reprise — jamais envoyé", onClick: () => draft(c) },
        { label: "Deuil", ghost: true, tip: "Mettre en deuil : le gardien cesse de la signaler, sans l'effacer", onClick: () => { c.deuil = true; save("Relation mise en deuil — le gardien se taira."); } },
        { icon: "trash", tip: "Retirer ce contact du suivi", onClick: () => remove(c) },
        { label: "Relancé", icon: "check", primary: due, tip: "Noter le contact comme repris aujourd'hui", onClick: () => { c.last = new Date().toISOString(); c.last_auto = false; delete c.last_source; save(String(c.name) + " noté comme relancé aujourd'hui."); } }];
    const el = ds.row({ lead: h("span", { class: "flx-av" }, initials(c.name)), title: String(c.name), meta, side, actions: acts, tip: prov + (c.email ? " · reconnu aussi par " + String(c.email) : "") });
    if (c.deuil) el.classList.add("is-muted");
    return el;
  }
  const matches = (c) => !query || (String(c.name) + " " + String(c.email || "")).toLowerCase().includes(query.toLowerCase());

  /* ── Rendu ───────────────────────────────────────────────────────── */
  function paint() {
    if (dead || raw == null) return;
    const cs = contacts();
    const due = cs.filter(isDue).sort((a, b) => (daysSince(b) - Number(b.cadence)) - (daysSince(a) - Number(a.cadence)));
    const calm = cs.filter((c) => !c.deuil && !isDue(c)).sort((a, b) => String(a.name).localeCompare(String(b.name), "fr"));
    const mourning = cs.filter((c) => c.deuil);
    /* Barre d'outils : recherche instantanée + filtres à compteurs (reconstruite seulement si les compteurs changent). */
    const sig = [cs.length, due.length, calm.length, mourning.length].join("|");
    if (tbHost.dataset.sig !== sig) {
      tbHost.dataset.sig = sig;
      const chipsEl = ds.chips([
        { id: "tous", label: "Tous", n: cs.length, on: filter === "tous" },
        { id: "retard", label: "À relancer", n: due.length, on: filter === "retard" },
        { id: "calme", label: "Au calme", n: calm.length, on: filter === "calme" },
        { id: "deuil", label: "En deuil", n: mourning.length, on: filter === "deuil" },
      ], (id) => { filter = id; paint(); });
      const tb = ds.toolbar({ search: { placeholder: "Rechercher un contact…", value: query, onInput: (q) => { query = q; paint(); } }, chips: chipsEl });
      tbHost.replaceChildren(cs.length ? tb : h("span"));
    }
    const fDue = due.filter(matches), fCalm = calm.filter(matches), fMourn = mourning.filter(matches);
    /* À relancer */
    dueSec.hidden = !(filter === "tous" || filter === "retard");
    dueSec.setCount(fDue.length);
    dueSec.body.replaceChildren(fDue.length ? h("div", { class: "ds-list" }, ...fDue.map(contactRow))
      : ds.empty({ compact: true, icon: "check", text: query ? "Aucun contact en retard ne correspond à « " + query + " »." : "Aucun contact en retard — le gardien est au calme." }));
    /* Contacts suivis */
    const rest = filter === "deuil" ? fMourn : filter === "calme" ? fCalm : filter === "retard" ? [] : fCalm.concat(fMourn);
    listSec.hidden = filter === "retard";
    listSec.setCount(rest.length);
    let emptyEl = null;
    if (!cs.length) emptyEl = ds.empty({ icon: "book", text: "Aucun contact suivi pour l'instant — ajoute le premier, ou choisis une suggestion tirée de tes engagements.", action: { label: "Ajouter un contact", icon: "plus", onClick: () => openAdd() } });
    else if (!rest.length) emptyEl = ds.empty({ compact: true, icon: "search", text: query ? "Aucun contact ne correspond à « " + query + " »." : filter === "deuil" ? "Aucune relation en deuil." : "Aucun autre contact suivi." });
    listSec.body.replaceChildren(rest.length ? h("div", { class: "ds-list" }, ...rest.map(contactRow)) : emptyEl);
    paintSuggestions();
    paintSource();
  }
  function paintSuggestions() {
    const have = new Set(contacts().map((c) => String(c.name || "").trim().toLowerCase()));
    const list = suggestions.filter((x) => !have.has(x.name.toLowerCase()));
    sugSec.hidden = !list.length;
    if (!list.length) { sugSec.body.replaceChildren(); return; }
    sugSec.body.replaceChildren(
      h("p", { class: "ds-meta flx-rel-sug-note" }, "Personnes avec qui un engagement existe — un clic les confie au gardien (cadence 14 j)."),
      h("div", { class: "ds-chips flx-rel-sug" }, ...list.map((x) => h("button", { type: "button", class: "ds-chip", title: plural(x.n, "engagement", "engagements") + (x.t ? " — dernier échange le " + fmtDate(x.t) : ""),
        onclick: () => { raw = raw || []; raw.push({ name: x.name, cadence: 14, last: x.t ? new Date(x.t).toISOString() : new Date().toISOString(), deuil: false }); save(x.name + " suivi par le gardien (cadence 14 j)."); } },
        h("span", { class: "flx-plus", "aria-hidden": "true" }, "+"), x.name, h("span", { class: "ds-chip-n" }, String(x.n))))));
  }
  function paintSource() {
    const st = syncState;
    const sy = (st && st.sync) || {};
    const upd = Array.isArray(sy.updated) ? sy.updated : [];
    const bd = Array.isArray(st && st.anniversaires) ? st.anniversaires : [];
    const nl = libres();
    const kv = (k, v) => h("div", { class: "flx-kv" }, h("span", { class: "flx-kv-k" }, k), h("span", { class: "flx-kv-v" }, v));
    srcSec.body.replaceChildren(ds.card({},
      st === "err" ? ds.errorBox({ title: "Rapprochement injoignable", cause: "L'état de la relecture des échanges n'a pas pu être lu.", retry: loadSync }) : null,
      kv("Dernière relecture", sy.last_sync ? fmtDate(sy.last_sync) + " — " + plural(Number(sy.events) || 0, "message reçu examiné", "messages reçus examinés") + (upd.length ? " · mis à jour : " + upd.join(", ") : " · rien de plus récent") : st && st !== "err" ? "Pas encore de relecture (le moteur relit toutes les 30 min)." : "—"),
      kv("Sources", String((st && st !== "err" && st.sources) || "messages reçus vus par Nova") + ". Les mails que tu envoies ne sont pas lus."),
      sy.note ? kv("Note", String(sy.note)) : null,
      kv("Anniversaires", bd.length ? bd.map((b) => String(b.name) + (Number(b.jours) === 0 ? " (aujourd'hui)" : " (dans " + plural(Number(b.jours), "jour", "jours") + ")")).join(", ") : "—"),
      nl ? kv("Texte libre", plural(nl, "ligne du document conservée telle quelle", "lignes du document conservées telles quelles") + " — ignorée" + (nl > 1 ? "s" : "") + " par le gardien.") : null,
      h("p", { class: "ds-meta flx-rel-foot" }, "Le document d'âme « relations » est lu chaque matin dès 9 h par l'Éclat « Gardien des relations ». Un contact est dû quand le dernier échange dépasse sa cadence, hors relations en deuil."),
      h("div", { class: "flx-rel-form-act" }, ds.action(syncBtnDesc))));
  }

  /* ── Chargements ─────────────────────────────────────────────────── */
  async function load() {
    try {
      const j = await api.get("/api/ame/doc?name=relations");
      if (dead) return;
      raw = Array.isArray(j && j.data) ? j.data : [];
      paint();
    } catch (e) {
      if (dead) return;
      if (raw == null) {
        dueSec.body.replaceChildren(ds.errorBox({ cause: "Le document « relations » est injoignable — le moteur ne répond pas.", retry: () => { dueSec.body.replaceChildren(ds.skeleton(2)); load(); } }));
        listSec.body.replaceChildren(); listSec.setCount("—"); dueSec.setCount("—");
      } else ctx.toast("Relations : relecture impossible pour le moment.", true);
    }
  }
  async function loadSync() {
    try { syncState = await api.get("/api/relations/etat"); } catch (e) { syncState = "err"; }
    if (!dead && raw != null) paintSource();
  }
  async function sync() {
    try {
      const r = await api.post("/api/relations/sync", {});
      const u = Array.isArray(r && r.updated) ? r.updated : [];
      ctx.toast(u.length ? "Dernier contact mis à jour : " + u.join(", ") + "." : "Aucun échange plus récent trouvé.");
    } catch (e) { ctx.toast("Relecture des échanges impossible pour le moment.", true); }
    load(); loadSync();
  }
  /* Suggestions RÉELLES tirées des engagements (personnes avec qui un engagement existe) — jamais Nova ni ses
     Éclats, jamais un groupe : « Awa Diallo / équipe X » → « Awa Diallo ». */
  async function loadSuggestions() {
    try {
      const cj = await api.get("/api/commitments"); if (dead) return;
      const by = new Map();
      for (const it of (Array.isArray(cj && cj.items) ? cj.items : [])) {
        let who = String((it && it.qui) || "").trim();
        who = who.split(/\s+\/\s+|\s+—\s+|,\s*/)[0].trim();
        if (!who || /^(ahadi|nova|moi|éclat|eclat|dot)\b/i.test(who) || /\b(groupe|équipe|equipe|team|tous)\b/i.test(who) || who.length > 40) continue;
        const k = who.toLowerCase();
        const t = Date.parse(it.updated || it.seen || it.created || "") || 0;
        const cur = by.get(k) || { name: who, n: 0, t: 0 }; cur.n++; cur.t = Math.max(cur.t, t); by.set(k, cur);
      }
      suggestions = [...by.values()].sort((a, b) => b.n - a.n || b.t - a.t).slice(0, 8);
    } catch (e) { suggestions = []; }
    if (!dead && raw != null) paintSuggestions();
  }

  /* Rafraîchi au retour sur l'écran (module persistant), au plus toutes les 30 s ; une zone où Ahadi est en
     train d'écrire (champ non vide ou focus) n'est jamais reconstruite. */
  const busy = () => root.contains(document.activeElement) && /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName) || !!nameIn.value.trim();
  let lastLoad = Date.now();
  load(); loadSync(); loadSuggestions();
  return {
    destroy() { dead = true; },
    onShow() { if (Date.now() - lastLoad < 30000 || busy()) return; lastLoad = Date.now(); load(); loadSync(); loadSuggestions(); },
  };
}
