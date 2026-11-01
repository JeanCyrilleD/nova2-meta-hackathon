/* Module FEEDS (ex-Veille) — V4-C, 24/10/2026, Bloc 3 du cahier d'Ahadi.
   « Centre d'intelligence & d'activités en direct » en 3 zones :
     1. bandeau « Activité des agents & signaux live » (GET /api/feeds/overview → ticker : runs
        d'Éclats, passes du radar, cours BRVM en cache, événements Fundings — horodatages du
        moteur, jamais simulés) + pills de flux thématiques avec compteurs de non-lus ;
     2. grille éditoriale : cartes rédigées par Nova (GET /api/feeds/overview → units, issues de
        /api/feed/units) — badge de pôle, source, heure, épingle, titre éditorial, encadré
        « Pourquoi ça compte pour toi » calculé par le MOTEUR à partir de faits réels (absent
        sinon), 2–3 puces, actions : Lire dans Nova (panneau lecteur latéral), Demander une note
        CAFU (prompt pré-rempli à côté, jamais envoyé), Déléguer à un Éclat (/api/dots/launch,
        sur ton clic), 👍/👎 (poids source/thème côté moteur) ;
     3. colonne droite : 3 prochaines échéances Fundings & Engagements, carte thermique des
        signaux par pays (dernier relevé réel du radar, cliquable = filtre), téléscripteur BRVM
        (uniquement ce que le moteur sert ; coffre verrouillé = dit).
   Vue Feeds › Fundings : bandeau des 3 échéances + compteurs « Crédits acquis & actifs » et
   « Dossiers en instruction » strictement séparés + listes §1/§2/§3 (GET /api/fundings).
   Aucun article inventé, aucune URL fabriquée, aucun envoi : tout vient du moteur. */
import { md, showToast, fmtRelFR } from "../core.js";
import { renderFundingsEvent } from "../feedcard.js";
import * as ds from "../ds.js";

const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const mdInline = (v) => { const html = md(String(v)); const one = /^<p>([\s\S]*)<\/p>$/.exec(html); return one && !one[1].includes("</p>") ? one[1] : html; };
const escHtml = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const escRe = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const toDate = (v) => { if (!v) return null; const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v); return isNaN(d) ? null : d; };
const rel = (v) => { const d = toDate(v); return d ? fmtRelFR(d) : ""; };
const fmtDate = (v) => { const d = toDate(v); return d ? d.toLocaleString("fr-FR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : String(v || "").slice(0, 16); };
const usd = (n) => { const v = Number(n); return isFinite(v) ? new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 0 }).format(v) + " $" : "—"; };
const ddmm = (d) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || "")); return m ? m[3] + "/" + m[2] : String(d || ""); };
const countdown = (n) => { n = Number(n); return !isFinite(n) ? "" : n === 0 ? "aujourd'hui" : n === 1 ? "demain" : "J-" + n; };
/* V5-H — mouvement : toujours désactivable (prefers-reduced-motion), jamais porteur d'information seule. */
const reducedMotion = () => { try { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) { return false; } };
const isoFR = (v) => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(v || "").trim()); return m ? m[3] + "/" + m[2] + "/" + m[1] : String(v || "—"); };
const plural = (n, one, many) => n + " " + (n > 1 ? many : one);
const fmtInt = (v) => new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 0 }).format(Math.round(Number(v) || 0));
/* Éclat « de veille » : reconnu à son nom / id (radar, Sahel, BRVM, Fundings…) — l'état vient de /api/activity. */
const VEILLE_DOT_RX = /veille|radar|sahel|feed|signal|afrique|wca|esa|brvm|bourse|fundings?|financement|surveill|actu/i;

/* V6 (25/10) : libellés sobres, sans émoji ni capitales (contrat V6_DESIGN.md §4).
   29/10 (conformité Bloc 3 du cahier d'instructions du 24/10) : nommage exact rétabli —
   « Fundings & crédits », « Sahel & WCA (CAFU) », « Afrique Est & Australe (ESA) »,
   « Marchés BRVM & finance », « Décisions & à traiter » — style sobre conservé (V6 gagne sur les émojis). */
const FILTERS = [
  { id: "tout", label: "Tout" },
  { id: "fundings", label: "Fundings & crédits" },
  { id: "wca", label: "Sahel & WCA (CAFU)" },
  { id: "esa", label: "Afrique Est & Australe (ESA)" },
  { id: "brvm", label: "Marchés BRVM & finance" },
  { id: "decisions", label: "Décisions & à traiter" },
  { id: "pulses", label: "Pulses" },
];
const POLE_LABEL = { fundings: "Fundings", wca: "Sahel · WCA", esa: "Afrique Est & Australe", brvm: "BRVM", decisions: "À traiter", pulses: "Brief", autre: "Nova" };
/* Surtitres du moteur en capitales (« AFRIQUE DE L'OUEST ») → casse de phrase ; sigles conservés. */
const KEEP_UP = new Set(["BRVM", "WCA", "ESA", "CAFU", "SCI", "ONU", "OCHA", "HCR", "PAM", "UE", "FMI", "RDC", "UEMOA", "CEDEAO"]);
const PROPER = new Set(["afrique", "sahel", "ouest", "est", "australe", "nova", "fundings", "pulses"]);
const sentenceCase = (t) => {
  const s = String(t || "").trim();
  if (!s || s !== s.toUpperCase() || !/[A-ZÀ-Ý]{3}/.test(s)) return s;
  return s.split(/(\s+|·)/).map((w, i) => {
    const bare = w.replace(/[^A-Za-zÀ-ÿ']/g, "");
    if (KEEP_UP.has(bare)) return w;
    const low = w.toLowerCase();
    const core = low.replace(/^l'|^d'/, "");
    const cap = PROPER.has(core.replace(/[^a-zà-ÿ]/g, "")) || i === 0;
    if (!cap) return low;
    const k = low.length - core.length;
    return low.slice(0, k) + core.charAt(0).toUpperCase() + core.slice(1);
  }).join("").replace(/^./, (c) => c.toUpperCase());
};
const FILTER_KEY = "nova2_feeds_filter";
const REGION_KICKERS = new Set(["SAHEL", "AFRIQUE DE L'OUEST", "AFRIQUE DE L'EST", "BRIEF DU MATIN", "POINT DE MI-JOURNÉE", "FERMETURE DU SOIR"]);
/* Pastille de catégorie d'un événement Fundings (rendu partagé feedcard.js) : sans émoji ni capitales ici. */
const tidyFev = (el) => { try { const bd = el.querySelector(".fb-badge"); if (bd) bd.textContent = sentenceCase(bd.textContent.replace(/[\p{Extended_Pictographic}\uFE0F]/gu, "").trim()); } catch (e) {} return el; };
const POLE_KEYS = { fundings: "FUNDINGS", wca: "SAHEL · WCA", esa: "AFRIQUE EST & AUSTRALE", brvm: "BRVM", decisions: "À TRAITER", pulses: "BRIEF", autre: "NOVA" };

export async function mount(root, ctx) {
  const { api, bus, h, ic } = ctx;
  let dead = false;
  root.classList.add("mod--data", "fx");

  let filter = (() => { try { const v = localStorage.getItem(FILTER_KEY); return FILTERS.some((f) => f.id === v) ? v : "tout"; } catch (e) { return "tout"; } })();
  let country = "";
  let ov = null;            // dernière vue d'ensemble servie par le moteur (null = jamais reçue)
  let ovErr = null;
  let pulses = [];          // historique des Pulses (GET /api/pulse → history)
  let fund = null;          // état complet de la campagne (GET /api/fundings) — vue Fundings
  const offs = [];

  /* V5-H — chiffres qui « roulent » vers leur nouvelle valeur. La valeur précédente est celle qu'Ahadi a VUE
     (dernier rendu de la même clé) ; premier rendu = valeur posée telle quelle. Texte final garanti même si
     requestAnimationFrame est suspendu (fenêtre en arrière-plan). */
  const rollPrev = new Map();
  function rollNum(key, value, fmt, cls = "") {
    const v = Number(value);
    const el = h("span", { class: "fx-roll" + (cls ? " " + cls : "") }, fmt(v));
    const prev = rollPrev.get(key);
    rollPrev.set(key, v);
    if (prev == null || !isFinite(prev) || !isFinite(v) || prev === v || reducedMotion()) return el;
    el.classList.add(v > prev ? "is-up" : "is-down");
    el.textContent = fmt(prev);
    const t0 = performance.now(), dur = 900;
    let done = false;
    const end = () => { if (done) return; done = true; el.textContent = fmt(v); setTimeout(() => { el.classList.remove("is-up", "is-down"); }, 900); };
    const step = (t) => { if (done) return; const k = Math.min(1, (t - t0) / dur); const e = 1 - Math.pow(1 - k, 3); el.textContent = fmt(prev + (v - prev) * e); if (k < 1) requestAnimationFrame(step); else end(); };
    requestAnimationFrame(step);
    setTimeout(end, dur + 250);
    return el;
  }
  /* V5-H — arrivées : ids déjà montrés (cartes, événements Fundings, ticker). Rien n'est « nouveau » au premier rendu. */
  const seenUnits = new Set(), seenFund = new Set(), seenTk = new Set();
  let seenReady = false, tkReady = false;

  const emptyState = (icon, text) => ds.empty({ icon, text, compact: true });
  const stateError = (label, err, retry) => ds.errorBox({ title: label, cause: err ? String((err && err.message) || err).slice(0, 120) : "Le moteur n'a pas répondu.", retry: () => retry() });

  /* « Ouvrir dans Nova » : la page part dans le volet Navigateur de Messages (aucun target=_blank). */
  function openInNova(url) {
    try { localStorage.setItem("nova2_pending_url", JSON.stringify({ url, at: Date.now() })); } catch (e) {}
    ctx.navigate("messages");
    setTimeout(() => { try { bus.emit("nova:open-url", { url }); } catch (e) {} }, 60);
  }
  /* Conversation à côté, prompt PRÉ-REMPLI — jamais envoyé : Ahadi relit et appuie sur Entrée. */
  function prefillChat(text) {
    try { if (window.NovaWorkspace) window.NovaWorkspace.openBeside("conversations"); else ctx.navigate("conversations"); } catch (e) { ctx.navigate("conversations"); }
    let tries = 0;
    const fill = () => {
      if (dead) return;
      const tas = [...document.querySelectorAll('.mod[data-mod="conversations"] .composer textarea')];
      const t = tas.find((x) => x.offsetParent) || tas[0];
      if (!t) { if (tries++ < 40) setTimeout(fill, 150); else ctx.toast("Conversation introuvable — le texte n'a pas été placé.", true); return; }
      t.value = text;
      try { t.dispatchEvent(new Event("input", { bubbles: true })); } catch (e) {}
      try { t.focus(); t.setSelectionRange(t.value.length, t.value.length); } catch (e) {}
      ctx.toast("Demande de note CAFU pré-remplie à côté — rien n'est envoyé tant que tu n'appuies pas sur Entrée.");
    };
    setTimeout(fill, 180);
  }
  const markRead = (u) => { if (!u || u.read === true) return; u.read = true; api.post("/api/feed/read", { id: String(u.id || "") }).catch(() => {}); };
  const fundMarkRead = (id) => { api.post("/api/fundings/read", { id: String(id) }).catch(() => {}); };

  /* ── En-tête ─────────────────────────────────────────────────────────── */
  const refreshBtn = ds.action({ label: "Rafraîchir", icon: "refresh", tip: "Relire le fil, les échéances et l'activité", onClick: () => { loadAll(true); loadSources(); } });
  root.append(ds.pageHead({ title: "Feeds", sub: "Ce que Nova a lu et rédigé pour toi, et l'activité de tes agents en direct", actions: [refreshBtn] }));

  /* ── Zone 1 : activité live + filtres ───────────────────────────────── */
  const tickerRow = h("div", { class: "fx-ticker-row" });
  const ticker = h("div", { class: "fx-ticker", role: "status", "aria-live": "polite" },
    h("span", { class: "fx-live" }, h("i", {}), "En direct"), tickerRow);
  const pills = h("div", { class: "vf-filters", "aria-label": "Flux thématiques" });
  const countryChip = h("div", { class: "fx-country", hidden: true });
  const liveHost = h("div", { class: "fx-livecards", "aria-live": "polite", hidden: true });
  root.append(ticker, pills, countryChip, liveHost);

  /* ── Zone 2 + 3 : grille ────────────────────────────────────────────── */
  const main = h("div", { class: "fx-main" });
  const aside = h("aside", { class: "fx-aside", "aria-label": "Radar & échéances critiques" });
  root.append(h("div", { class: "fx-grid" }, main, aside));

  const wDues = h("section", { class: "fx-w" }, h("h3", { class: "ds-h3 fx-w-t" }, "Prochaines échéances"), h("div", { class: "fx-w-b" }));
  const wHeat = h("section", { class: "fx-w" }, h("h3", { class: "ds-h3 fx-w-t" }, "Signaux par pays"), h("div", { class: "fx-w-b" }));
  const wBrvm = h("section", { class: "fx-w" }, h("h3", { class: "ds-h3 fx-w-t" }, "Cours BRVM"), h("div", { class: "fx-w-b" }));
  const wCarte = h("section", { class: "fx-w" }, h("h3", { class: "ds-h3 fx-w-t" }, "Carte des signaux — Sahel"), h("div", { class: "fx-w-b" }));   /* LOT J 28/10 */
  aside.append(wDues, wHeat, wCarte, wBrvm);

  const srcBox = h("div", {});
  const sourcesSec = h("div", { class: "fx-sources" }, h("div", { class: "ds-section-head" }, h("h2", { class: "ds-h2" }, "Sources du radar")), srcBox);

  /* ── Lecteur latéral (Lire dans Nova) ───────────────────────────────── */
  const reader = h("div", { class: "fx-reader", role: "dialog", "aria-modal": "false", "aria-label": "Lecteur", hidden: true });
  document.body.append(reader);
  let readerFor = null;
  const placeReader = () => {
    if (reader.hidden) return;
    const r = root.getBoundingClientRect();
    const w = Math.min(560, Math.max(320, r.width * 0.46));
    reader.style.top = Math.max(0, r.top) + "px";
    reader.style.height = Math.max(240, Math.min(window.innerHeight, r.bottom) - Math.max(0, r.top)) + "px";
    reader.style.left = Math.max(r.left, r.right - w) + "px";
    reader.style.width = Math.min(w, r.width) + "px";
  };
  const closeReader = () => { reader.hidden = true; readerFor = null; reader.replaceChildren(); root.classList.remove("fx-reading"); };
  const onKey = (e) => { if (e.key === "Escape" && !reader.hidden) closeReader(); };
  window.addEventListener("keydown", onKey);
  window.addEventListener("resize", placeReader);
  root.addEventListener("scroll", placeReader, { passive: true });

  function entityTerms(u) {
    const t = new Set();
    for (const c of arrOf(u, "countries")) if (c && !/^Région/.test(c)) t.add(String(c));
    for (const i of arrOf(u, "impact")) if (i && i.dossier && String(i.dossier).length >= 3 && i.src !== "fundings") t.add(String(i.dossier));
    return [...t].sort((a, b) => b.length - a.length).slice(0, 12);
  }
  function highlighted(text, terms) {
    let html = escHtml(text);
    if (terms.length) {
      const re = new RegExp("(" + terms.map((x) => escRe(escHtml(x))).join("|") + ")", "gi");
      html = html.replace(re, '<mark class="fx-ent">$1</mark>');
    }
    return html;
  }
  function impactBox(u, cls = "fx-why") {
    const imp = arrOf(u, "impact");
    if (!imp.length) return null;
    return h("div", { class: cls },
      h("div", { class: "fx-why-t" }, "Pourquoi ça compte pour toi"),
      h("ul", {}, ...imp.map((i) => h("li", {},
        h("b", {}, String(i.dossier || "")), " — ", String(i.fait || ""),
        i.date ? h("span", { class: "fx-why-d" }, " (noté le " + String(i.date) + ")") : null))));
  }
  async function openReader(u) {
    readerFor = u; markRead(u); reader.hidden = false; root.classList.add("fx-reading");
    const src = arrOf(u, "sources")[0] || {};
    const body = h("div", { class: "fx-r-body" });
    const terms = entityTerms(u);
    reader.replaceChildren(
      h("div", { class: "fx-r-head" },
        h("span", { class: "fx-pole", "data-pole": u.pole || "autre" }, POLE_LABEL[u.pole] || "Nova"),
        h("span", { class: "fx-src" }, String(src.name || "Nova")),
        h("span", { class: "sp" }),
        h("button", { class: "btn sm ghost icon", title: "Fermer le lecteur (Échap)", "aria-label": "Fermer le lecteur", html: ic("close", 15), onclick: closeReader })),
      h("div", { class: "fx-r-scroll" },
        h("h2", { class: "fx-r-title" }, String(u.title || "Sans titre")),
        u.standfirst ? h("p", { class: "fx-r-stand", html: mdInline(u.standfirst) }) : null,
        impactBox(u, "fx-why fx-why--r"),
        body,
        arrOf(u, "sources").length ? h("div", { class: "fx-r-srcs" }, "Sources : ", ...arrOf(u, "sources").map((s) => h("span", { class: "unit-src" }, String(s.name || "") + (s.time ? " · " + fmtDate(s.time) : "")))) : null),
      h("div", { class: "fx-r-foot" },
        u.link ? h("button", { class: "btn sm", onclick: () => openInNova(String(u.link)) }, h("span", { html: ic("globe", 13) }), "Page entière dans Nova") : null,
        h("span", { class: "sp" }),
        h("button", { class: "btn sm acc", onclick: () => askCafu(u) }, "Demander une note CAFU")));
    placeReader();
    if (u.raw) { body.innerHTML = md(String(u.raw)); return; }
    if (!u.link) { body.innerHTML = u.body ? md(String(u.body)) : '<p class="ss">Pas de développement pour cette unité.</p>'; return; }
    if (u.body) body.append(h("div", { class: "fx-r-nova", html: md(String(u.body)) }));
    const art = h("div", { class: "fx-r-art" }, h("div", { class: "ss" }, "Lecture de l'article…"));
    body.append(art);
    try {
      const j = await api.get("/api/veille/article?url=" + encodeURIComponent(String(u.link)), 25000);
      if (dead || readerFor !== u) return;
      if (!j || j.ok !== true) throw new Error((j && j.error) || "extraction refusée");
      const t = String(j.text || "");
      if (t.length < 200) { art.replaceChildren(h("div", { class: "ss" }, "Texte complet non extractible de cette page (paywall, script ou mise en page) — « Page entière dans Nova » l'affiche.")); return; }
      const paras = t.split(/\n{2,}|\n(?=[A-ZÀ-Ý«"])/).map((x) => x.trim()).filter((x) => x.length > 1).slice(0, 120);
      art.replaceChildren(h("div", { class: "fx-r-label" }, "Texte de l'article (nettoyé par le moteur)" + (terms.length ? " · entités surlignées" : "")),
        ...paras.map((p) => h("p", { html: highlighted(p, terms) })));
    } catch (e) {
      if (dead || readerFor !== u) return;
      art.replaceChildren(h("div", { class: "ss" }, "Lecture de l'article impossible — " + String((e && e.message) || e).slice(0, 110)));
    }
  }

  function askCafu(u) {
    markRead(u);
    const src = arrOf(u, "sources")[0] || {};
    const lines = [
      "Rédige une note CAFU (normes CAFU Save the Children : BLUF en tête, faits sourcés et datés, implications humanitaires et opérationnelles pour la région, points de vigilance, sources citées) sur ce signal de mon fil Feeds :",
      "« " + String(u.title || "") + " »",
      "Source : " + String(src.name || "non précisée") + (src.time ? " (" + fmtDate(src.time) + ")" : "") + (u.link ? " — " + String(u.link) : ""),
    ];
    if (u.standfirst) lines.push("Accroche : " + String(u.standfirst).replace(/\*\*/g, ""));
    if (u.body) lines.push("Résumé de Nova : " + String(u.body).replace(/\*\*/g, "").slice(0, 900));
    if (arrOf(u, "countries").length) lines.push("Pays : " + arrOf(u, "countries").join(", "));
    lines.push("N'utilise que des faits vérifiables et dis ce qui reste à confirmer. Ne l'envoie à personne : je relis d'abord.");
    prefillChat(lines.join("\n"));
  }

  /* Déléguer à un Éclat : choisir le Dot, relire la mission, puis missionner (POST /api/dots/launch, route existante). */
  let delegatePop = null;
  async function delegate(u, anchor) {
    if (delegatePop) { delegatePop.remove(); delegatePop = null; }
    const task = "Suis ce sujet pour Ahadi et rapporte uniquement les faits nouveaux, sources citées et datées : « " + String(u.title || "") + " »"
      + (u.link ? " (" + String(u.link) + ")" : "") + ". Lecture et rapport seulement — rien n'est envoyé, publié ni rédigé en brouillon.";
    const sel = h("select", { class: "fld", "aria-label": "Éclat à missionner" }, h("option", { value: "" }, "Chargement des Éclats…"));
    const ta = h("textarea", { class: "fld fld-area", rows: "4", "aria-label": "Mission" }); ta.value = task;
    const go = h("button", { class: "btn sm acc", disabled: true }, "Missionner");
    const status = h("div", { class: "ss" });
    const pop = h("div", { class: "fx-pop", role: "dialog", "aria-label": "Déléguer à un Éclat" },
      h("div", { class: "fx-pop-t" }, "Déléguer à un Éclat"), sel, ta, status,
      h("div", { class: "fx-pop-a" }, h("button", { class: "btn sm ghost", onclick: () => { pop.remove(); delegatePop = null; } }, "Annuler"), h("span", { class: "sp" }), go));
    delegatePop = pop;
    anchor.closest(".fx-card").append(pop);
    ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); if (!go.disabled) go.click(); } });
    try {
      const j = await api.get("/api/dots", 15000);
      if (dead || !pop.isConnected) return;
      const dots = arrOf(j, "items").filter((d) => d && d.id && d.id !== "bilan");
      if (!dots.length) { sel.replaceChildren(h("option", { value: "" }, "Aucun Éclat disponible")); status.textContent = "Crée d'abord un Éclat dans l'écran Éclats."; return; }
      sel.replaceChildren(...dots.map((d) => h("option", { value: String(d.id) }, (d.emoji ? d.emoji + " " : "") + String(d.name || d.id))));
      const pref = dots.find((d) => /veille|radar|sahel|suivi/i.test(String(d.name || "") + " " + String(d.id)));
      if (pref) sel.value = String(pref.id);
      go.disabled = false;
    } catch (e) { if (!dead) { sel.replaceChildren(h("option", { value: "" }, "Éclats injoignables")); status.textContent = String((e && e.message) || e).slice(0, 90); } }
    go.addEventListener("click", async () => {
      const id = sel.value, t = ta.value.trim();
      if (!id || !t) return;
      go.disabled = true; status.textContent = "Mission en cours d'envoi au moteur…";
      try {
        await api.post("/api/dots/launch", { id, task: t }, 20000);
        if (dead) return;
        markRead(u);
        pop.replaceChildren(h("div", { class: "fx-pop-t" }, "Mission confiée"), h("div", { class: "ss" }, "L'Éclat travaille — son rapport arrivera dans le Fil direct."),
          h("div", { class: "fx-pop-a" }, h("span", { class: "sp" }), h("button", { class: "btn sm", onclick: () => { pop.remove(); delegatePop = null; } }, "OK")));
      } catch (e) { if (!dead) { go.disabled = false; status.textContent = "Lancement refusé : " + String((e && e.message) || e).slice(0, 110); } }
    });
  }

  async function vote(u, signal, btnUp, btnDown) {
    const src = arrOf(u, "sources")[0] || {};
    try {
      const j = await api.post("/api/feeds/feedback", { id: String(u.id || ""), source: String(src.name || ""), theme: String(u.pole || ""), signal }, 10000);
      if (dead) return;
      u.vote = j && typeof j.signal === "string" ? j.signal : signal;
      btnUp.classList.toggle("on", u.vote === "up"); btnDown.classList.toggle("on", u.vote === "down");
      btnUp.setAttribute("aria-pressed", u.vote === "up" ? "true" : "false"); btnDown.setAttribute("aria-pressed", u.vote === "down" ? "true" : "false");
      ctx.toast(u.vote ? "Noté — Nova ajustera le poids de cette source et de ce thème." : "Avis retiré.");
    } catch (e) { if (!dead) ctx.toast("Avis non enregistré — " + String((e && e.message) || e).slice(0, 80), true); }
  }

  /* ── Carte éditoriale ───────────────────────────────────────────────── */
  function bulletsOf(u) {
    const out = [];
    if (u.keys) for (const k of String(u.keys).split(/\s+·\s+/)) if (k.trim()) out.push(k.trim());
    if (out.length < 3 && u.body && !u.raw) {
      for (const s of String(u.body).replace(/^- /gm, "").split(/(?<=[.!?])\s+|\n+/)) { const t = s.trim(); if (t.length > 24) out.push(t); if (out.length >= 3) break; }
    }
    return out.slice(0, 3);
  }
  function unitCard(u) {
    const src = arrOf(u, "sources")[0] || {};
    const pinned = u.user_pin === true;
    const dot = u.read === true ? null : h("span", { class: "unit-unread", title: "Non lue" });
    const pinBtn = h("button", { class: "fx-pin" + (pinned ? " on" : ""), title: pinned ? "Désépingler" : "Épingler en tête du jour", "aria-pressed": pinned ? "true" : "false", html: ic("star", 14) });
    pinBtn.addEventListener("click", async () => {
      const want = !(u.user_pin === true);
      try { await api.post("/api/feeds/pin", { id: String(u.id || ""), pinned: want }, 10000); u.user_pin = want; pinBtn.classList.toggle("on", want); pinBtn.setAttribute("aria-pressed", want ? "true" : "false"); pinBtn.title = want ? "Désépingler" : "Épingler en tête du jour"; card.classList.toggle("is-pinned", want); }
      catch (e) { ctx.toast("Épingle non enregistrée.", true); }
    });
    const up = h("button", { type: "button", class: "fx-vote" + (u.vote === "up" ? " on" : ""), title: "Plus de ça : Nova donne plus de poids à cette source et à ce thème", "aria-pressed": u.vote === "up" ? "true" : "false" }, "Plus de ça");
    const down = h("button", { type: "button", class: "fx-vote" + (u.vote === "down" ? " on" : ""), title: "Moins de ça : Nova donne moins de poids à cette source et à ce thème", "aria-pressed": u.vote === "down" ? "true" : "false" }, "Moins de ça");
    up.addEventListener("click", () => vote(u, "up", up, down));
    down.addEventListener("click", () => vote(u, "down", up, down));
    const bullets = bulletsOf(u);
    const kicker = String(u.kicker || "");
    const poleL = POLE_LABEL[u.pole] || "Nova";
    const poleK = POLE_KEYS[u.pole] || "NOVA";
    const card = h("article", { class: "fx-card" + (pinned ? " is-pinned" : "") + (u.masked === true ? " is-masked" : ""), "data-pole": u.pole || "autre", "data-brief-id": u.origin === "brief" && u.id ? String(u.id) : null },
      h("div", { class: "fx-card-head" },
        h("span", { class: "fx-pole", "data-pole": u.pole || "autre" }, REGION_KICKERS.has(kicker.toUpperCase()) ? sentenceCase(kicker) : poleL + (kicker && kicker.toUpperCase() !== poleK ? " · " + sentenceCase(kicker) : "")),
        h("span", { class: "fx-src", title: "Source" }, h("span", { html: ic(u.origin === "brief" ? "brief" : "globe", 12) }), String(src.name || (u.origin === "brief" ? "Brief de Nova" : "Nova"))),
        dot,
        h("span", { class: "sp" }),
        h("span", { class: "fx-time", title: fmtDate(u.ts) }, rel(u.ts)),
        pinBtn),
      u.img ? h("img", { class: "fx-cover", src: String(u.img), alt: "", loading: "lazy", onerror: (e) => { e.currentTarget.remove(); } }) : null,
      h("h3", { class: "fx-title" }, String(u.title || "Sans titre")),
      impactBox(u),
      u.standfirst && !bullets.length ? h("p", { class: "fx-stand", html: mdInline(u.standfirst) }) : null,
      bullets.length ? h("ul", { class: "fx-bullets" }, ...bullets.map((b) => h("li", { html: mdInline(b) }))) : null,
      h("div", { class: "fx-actions" },
        h("button", { class: "btn sm ds-btn-primary is-primary", onclick: () => openReader(u) }, h("span", { class: "ds-ic", html: ic("brief", 14) }), "Lire dans Nova"),
        h("button", { class: "btn sm ds-btn-secondary", title: "Prépare la demande à côté — rien n'est envoyé", onclick: () => askCafu(u) }, "Note CAFU"),
        h("button", { class: "btn sm ds-btn-secondary", title: "Confier le suivi de ce sujet à un Éclat (lecture et rapport seulement)", onclick: (e) => delegate(u, e.currentTarget) }, h("span", { class: "ds-ic", html: ic("agent", 14) }), "Déléguer"),
        h("span", { class: "sp" }), h("span", { class: "fx-votes", role: "group", "aria-label": "Ton avis sur ce sujet" }, up, down),
        u.origin === "brief" && u.kind ? h("button", { class: "btn sm ds-btn-ghost", title: "Régénérer ce brief", onclick: async (e) => {
          const btn = e.currentTarget; btn.disabled = true; btn.textContent = "Régénération…";
          try { await api.post("/api/briefs/run", { kind: String(u.kind) }); if (!dead) { ctx.toast("Brief régénéré — la nouvelle édition est en tête du jour."); loadAll(true); } }
          catch (err) { ctx.toast("Régénération impossible.", true); btn.disabled = false; btn.textContent = "Régénérer"; }
        } }, "Régénérer") : null,
        h("button", { class: "btn sm ds-btn-ghost", title: "Écarter cette carte (annulable 8 s)", onclick: () => {
          const parent = card.parentNode, next = card.nextSibling; card.remove();
          let undone = false;
          const restore = () => { undone = true; try { if (parent && parent.isConnected) parent.insertBefore(card, next); } catch (e) {} };
          try { showToast("Carte écartée.", { ms: 8000, action: { label: "Annuler", onClick: restore } }); } catch (e) { ctx.toast("Carte écartée."); }
          setTimeout(async () => { if (undone || dead) return; try { await api.post("/api/feed/dismiss", { id: String(u.id || "") }); } catch (e) {} }, 8000);
        } }, "Écarter")));
    return card;
  }

  /* ── Rendu : pills, ticker, flux, colonne droite ────────────────────── */
  /* V6 : puces du système (.ds-chip + .ds-chip-n), une seule ligne qui défile si l'écran est étroit ;
     compteur = non lus servis par le moteur (neutre, pas de bulle rouge). */
  let pillsSig = "";
  function paintPills() {
    const un = (ov && ov.unread) || {};
    const items = FILTERS.map((f) => { const n = Number(un[f.id] || 0); return { id: f.id, label: f.label, n: n > 0 ? (n > 99 ? "99+" : String(n)) : null, on: filter === f.id }; });
    const sigP = JSON.stringify(items);
    if (sigP !== pillsSig) {
      pillsSig = sigP;
      const box = ds.chips(items, (id) => { filter = id; try { localStorage.setItem(FILTER_KEY, id); } catch (e) {} pillsSig = ""; paintPills(); paintMain(); paintDues(); });
      box.querySelectorAll(".ds-chip").forEach((b, i) => { const it = items[i]; if (it && it.n) b.title = it.n + " non lu" + (it.n === "1" ? "" : "s"); });
      pills.replaceChildren(box);
      const on = box.querySelector(".ds-chip.is-on");
      if (on) requestAnimationFrame(() => { try { const r = on.getBoundingClientRect(), b = box.getBoundingClientRect(); if (r.right > b.right || r.left < b.left) box.scrollLeft += r.left - b.left - 16; } catch (e) {} });
    }
    countryChip.hidden = !country;
    countryChip.replaceChildren(...(country ? [h("span", { class: "ds-chip is-on vf-country" }, "Pays : " + country,
      h("button", { type: "button", class: "vf-x", title: "Retirer le filtre pays", "aria-label": "Retirer le filtre pays", html: ic("close", 12), onclick: () => { country = ""; paintPills(); paintMain(); paintHeat(); } }))] : []));
  }
  /* V5-H — téléscripteur : défilement continu et doux (CSS, piste doublée) dès qu'il déborde ; mis à jour en
     direct sans saut (la phase du défilement est conservée) ; pause au survol / au clavier ; immobile et
     défilable à la main si prefers-reduced-motion. Seulement les entrées servies par le moteur. */
  let tkSig = "", tkT0 = 0, tkDur = 0;
  const tkKey = (x) => String(x.label || "") + "|" + String(x.ts || "") + "|" + (x.live ? 1 : 0);
  function tkItem(x, clone, fresh) {
    const when = x.live ? "en cours" : rel(x.ts);
    const el = h(x.ecran ? "button" : "span", { class: "fx-tk" + (x.live ? " live" : "") + (fresh ? " fx-tk-new" : ""), title: x.ts ? fmtDate(x.ts) : "" },
      h("span", { class: "fx-tk-i" }, String(x.icon || "•")), h("span", { class: "fx-tk-l" }, String(x.label || "")), when ? h("span", { class: "fx-tk-t" }, when) : null);
    if (clone) { el.setAttribute("aria-hidden", "true"); el.tabIndex = -1; }
    if (x.ecran) el.addEventListener("click", () => ctx.navigate(x.ecran === "dots" ? "dots" : String(x.ecran)));
    return el;
  }
  function layoutTicker() {
    const track = tickerRow.querySelector(".fx-tk-track");
    if (!track) return;
    track.querySelectorAll("[data-clone]").forEach((n) => n.remove());
    tickerRow.classList.remove("marquee");
    track.style.removeProperty("animation-delay");
    if (reducedMotion() || track.scrollWidth <= tickerRow.clientWidth + 2) return;
    const w = track.scrollWidth;
    const items = arrOf(ov, "ticker");
    const gap = h("span", { class: "fx-tk-gap", "data-clone": "1", "aria-hidden": "true" }, "·");
    track.append(gap, ...items.map((x) => { const c = tkItem(x, true, false); c.setAttribute("data-clone", "1"); return c; }));
    const dur = Math.max(24, Math.min(140, w / 38));
    const now = performance.now();
    const frac = tkDur > 0 ? ((now - tkT0) / 1000 / tkDur) % 1 : 0;
    tkDur = dur; tkT0 = now - frac * dur * 1000;
    track.style.setProperty("--fx-tk-dur", dur.toFixed(1) + "s");
    track.style.animationDelay = (-frac * dur).toFixed(2) + "s";
    tickerRow.classList.add("marquee");
  }
  function paintTicker() {
    const t = arrOf(ov, "ticker");
    if (!ov) { tkSig = ""; tickerRow.classList.remove("marquee"); tickerRow.replaceChildren(h("span", { class: "fx-tk-empty" }, ovErr ? "Activité injoignable pour le moment." : "Lecture de l'activité…")); return; }
    if (!t.length) { tkSig = ""; tickerRow.classList.remove("marquee"); tickerRow.replaceChildren(h("span", { class: "fx-tk-empty" }, "Aucune activité récente relevée par le moteur (Éclats, radar, BRVM, Fundings).")); return; }
    const sigNow = t.map(tkKey).join("\n") + "|" + t.map((x) => (x.live ? "en cours" : rel(x.ts))).join(",");
    if (sigNow === tkSig) return;   // rien de neuf : le défilement continue sans être touché
    tkSig = sigNow;
    const track = h("div", { class: "fx-tk-track" }, ...t.map((x) => { const k = tkKey(x); const fresh = tkReady && !seenTk.has(k); seenTk.add(k); return tkItem(x, false, fresh); }));
    tkReady = true;
    tickerRow.replaceChildren(track);
    requestAnimationFrame(layoutTicker);
  }
  function filteredUnits() {
    let us = arrOf(ov, "units");
    if (filter !== "tout") us = us.filter((u) => u.pole === filter);
    if (country) us = us.filter((u) => arrOf(u, "countries").includes(country));
    return us;
  }
  function dayLabel(v) {
    const d = toDate(v); if (!d) return "";
    const today = new Date();
    if (d.toDateString() === today.toDateString()) return "Aujourd'hui";
    const y = new Date(); y.setDate(today.getDate() - 1);
    if (d.toDateString() === y.toDateString()) return "Hier";
    return d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });
  }
  let fundView = null;
  let focusFund = "";   // V5-H : événement Fundings à mettre en évidence (clic sur une notification)
  function paintMain() {
    if (fundView) { try { fundView.destroy(); } catch (e) {} fundView = null; }
    if (delegatePop) { delegatePop.remove(); delegatePop = null; }
    main.removeAttribute("aria-busy");
    if (filter === "fundings") { main.replaceChildren(); fundView = mountFundingsView(main); return; }
    if (!ov) {
      main.replaceChildren(ovErr ? stateError("Feeds injoignable pour le moment", ovErr, () => loadAll(true))
        : h("div", { class: "fx-skel" }, h("div", { class: "skel skel-row" }), h("div", { class: "skel skel-row" }), h("div", { class: "skel skel-row" })));
      return;
    }
    const nodes = [];
    /* Une passe « en cours » est déjà signalée par l'indicateur en direct : pas de seconde mention ici. */
    if (ov.note && String(ov.note).indexOf("en cours") < 0) nodes.push(h("p", { class: "ds-meta feed-note" }, String(ov.note)));
    // Événements Fundings : à traiter (ACTION REQUISE) dans « Décisions », les non lus en tête de « Tout ».
    const fev = arrOf(ov.fundings, "events");
    const fsel = filter === "decisions" ? fev.filter((e) => e.categorie === "ACTION REQUISE") : filter === "tout" && !country ? fev.filter((e) => e.lu !== true).slice(0, 4) : [];
    if (fsel.length) {
      nodes.push(h("h3", { class: "ds-h3 fx-day" }, "Fundings à regarder"));
      for (const e of fsel) nodes.push(arrive(tidyFev(renderFundingsEvent(e, { h, markRead: fundMarkRead })), seenFund, "f:" + String(e.id || "")));
    }
    const us = filteredUnits();
    let lastDay = "";
    const list = h("div", { class: "fx-list" });
    for (const u of us) {
      const d = dayLabel(u.ts);
      if (d && d !== lastDay) { list.append(h("h3", { class: "ds-h3 fx-day" }, d.charAt(0).toUpperCase() + d.slice(1))); lastDay = d; }
      list.append(arrive(unitCard(u), seenUnits, "u:" + String(u.id || u.title || "")));
    }
    seenReady = true;
    if (us.length) nodes.push(list);
    if (filter === "pulses") nodes.push(pulseHistory());
    if (!us.length && !fsel.length && filter !== "pulses") {
      const msg = country ? "Aucune carte rédigée ne cite " + country + " pour le moment."
        : filter === "tout" ? "Le fil est encore vide — les briefs planifiés et la sélection du radar l'alimenteront à leur prochain cycle."
        : "Rien dans ce flux pour le moment.";
      nodes.push(emptyState("feed", msg));
    }
    if (filter === "tout" && !country) nodes.push(sourcesSec);
    main.replaceChildren(...nodes);
  }
  /* V5-H — une carte jamais montrée arrive en glissant, avec un halo bref (classe retirée après l'animation). */
  function arrive(el, seen, key) {
    const fresh = seenReady && key.length > 2 && !seen.has(key);
    seen.add(key);
    if (fresh && el && !reducedMotion()) { el.classList.add("fx-new"); setTimeout(() => { try { el.classList.remove("fx-new"); } catch (e) {} }, 2200); }
    return el;
  }
  function pulseHistory() {
    const PCAT = { mail: "Mail", agenda: "Agenda", reunion: "Réunion", engagement: "Engagement", dot: "Éclat", brvm: "BRVM", veille: "Veille", budget: "Budget" };
    const PSIG = { up: "utile", down: "moins utile", more: "plus de ça", less: "moins de ça" };
    if (!pulses.length) return emptyState("feed", "Aucun Pulse dans l'historique des 7 derniers jours.");
    return h("div", { class: "plh" }, h("h3", { class: "ds-h3 fx-day" }, "Pulses précédents"), ...pulses.map((d, i) => {
      const cards = Array.isArray(d.cards) ? d.cards : [];
      const det = h("details", { class: "plh-day" },
        h("summary", {}, h("span", {}, dayLabel(String(d.day || "") + "T12:00:00")), h("span", { class: "ss" }, cards.length + " carte" + (cards.length > 1 ? "s" : "") + (d.brain && !/^aucun/.test(String(d.brain)) ? " · " + d.brain : "")), h("span", { class: "sp" }), h("span", { html: ic("chev-d", 14) })),
        h("div", { class: "plh-list" }, ...(cards.length ? cards.map((c) => h("div", { class: "plh-row" },
          h("span", { class: "pl-cat" }, PCAT[c.cat] || "Nova"), h("span", { class: "plh-t" }, String(c.titre || "")),
          c.signal && PSIG[c.signal] ? h("span", { class: "plh-sig" }, PSIG[c.signal]) : null,
          c.pinned ? h("span", { class: "plh-sig" }, "épinglée") : null,
          h("span", { class: "plh-s" }, String((c.source || {}).nom || "")))) : [h("div", { class: "ss" }, "Aucune carte ce jour-là.")])));
      if (i === 0) det.open = true;
      return det;
    }));
  }
  /* V6 : une échéance = une ligne (intitulé sur 2 lignes au plus, type et date en méta, compte à rebours en
     pastille à droite) — plus de gros « aujourd'hui » qui chevauchait le libellé. Masquée dans la vue Fundings,
     qui porte déjà ses propres échéances (aucun doublon). */
  const dueTone = (n) => (n <= 0 ? "danger" : n <= 2 ? "warn" : "neutral");
  function dueItem(e, onOpen) {
    const n = Number(e.days_left);
    const when = (e.approx ? "≈ " : "") + countdown(n);
    const el = h("button", { type: "button", class: "vf-due", title: String(e.label || ""), onclick: onOpen },
      h("span", { class: "vf-due-m" },
        h("span", { class: "vf-due-t" }, String(e.label || "—")),
        h("span", { class: "ds-meta vf-due-s" }, [e.kind === "engagement" ? "Engagement" : "Fundings", ddmm(e.date) + (e.heure ? " · " + e.heure : "")].filter(Boolean).join(" · "))),
      when ? ds.pill(when.charAt(0).toUpperCase() + when.slice(1), dueTone(n)) : null);
    return el;
  }
  function paintDues() {
    wDues.hidden = filter === "fundings";
    const b = wDues.querySelector(".fx-w-b");
    const list = arrOf(ov, "echeances");
    if (!ov) { b.replaceChildren(h("p", { class: "ds-meta" }, ovErr ? "Échéances injoignables pour le moment." : "Lecture…")); return; }
    if (!list.length) { b.replaceChildren(h("p", { class: "ds-meta" }, "Aucune échéance Fundings ni engagement daté servi par le moteur.")); return; }
    b.replaceChildren(...list.map((e) => dueItem(e, () => { if (e.kind === "fundings") { filter = "fundings"; try { localStorage.setItem(FILTER_KEY, filter); } catch (x) {} paintPills(); paintMain(); paintDues(); } else ctx.navigate("engagements"); })));
  }
  function paintHeat() {
    const b = wHeat.querySelector(".fx-w-b");
    const list = arrOf(ov, "heat");
    if (!ov) { b.replaceChildren(h("div", { class: "ss" }, ovErr ? "Carte injoignable." : "Lecture…")); return; }
    const gen = ov.radar && ov.radar.generated ? String(ov.radar.generated) : "";
    if (!list.length) { b.replaceChildren(h("div", { class: "ss" }, "Aucun relevé du radar pour le moment.")); return; }
    const max = Math.max(1, ...list.map((c) => Number(c.n) || 0));
    b.replaceChildren(
      h("div", { class: "fx-heat" }, ...list.slice(0, 18).map((c) => {
        const n = Number(c.n) || 0;
        const el = h("button", { class: "fx-hc" + (country === c.name ? " on" : "") + (n ? "" : " zero"), "data-region": c.region || "wca", title: n + " signal(aux) cité(s) — clic : filtrer le fil sur ce pays",
          onclick: () => { country = country === c.name ? "" : String(c.name); paintPills(); paintMain(); paintHeat(); } },
          h("span", { class: "fx-hc-n" }, String(c.name)), h("span", { class: "fx-hc-v" }, rollNum("heat:" + String(c.name), n, fmtInt)));
        el.style.setProperty("--heat", String(n / max));
        return el;
      })),
      h("div", { class: "fx-w-foot" }, gen ? "Dernier relevé du radar : " + fmtDate(gen) + (ov.radar.window_days ? " · fenêtre " + ov.radar.window_days + " j" : "") : "Pays SCI suivis — aucun relevé du radar encore conservé."));
  }
  /* LOT J (28/10) — carte schématique des signaux scorés (GET /api/veille/carte).
     Grille lat/long sans frontières ; taille et teinte = score mécanique du moteur. */
  async function loadCarte() {
    const b = wCarte.querySelector(".fx-w-b");
    let j = null;
    try { j = await api.get("/api/veille/carte?jours=14", 60000); } catch (e) {}
    if (dead) return;
    const pts = (j && Array.isArray(j.points)) ? j.points : [];
    if (!j || !pts.length) { b.replaceChildren(h("div", { class: "ss" }, j ? "Aucun signal géolocalisable sur la fenêtre." : "Carte injoignable.")); return; }
    const bb = j.bbox || { lon_min: -20, lon_max: 40, lat_min: 2, lat_max: 28 };
    const W = 560, H = Math.round(560 * (bb.lat_max - bb.lat_min) / (bb.lon_max - bb.lon_min) * 1.15);
    const X = (lon) => ((lon - bb.lon_min) / (bb.lon_max - bb.lon_min) * W).toFixed(1);
    const Y = (lat) => ((bb.lat_max - lat) / (bb.lat_max - bb.lat_min) * H).toFixed(1);
    let svg = `<svg viewBox="0 0 ${W} ${H}" class="fx-carte-svg" role="img" aria-label="Carte schématique des signaux du Sahel">`;
    for (let lon = Math.ceil(bb.lon_min / 10) * 10; lon <= bb.lon_max; lon += 10) {
      svg += `<line x1="${X(lon)}" y1="0" x2="${X(lon)}" y2="${H}" class="fx-carte-grid"/><text x="${X(lon)}" y="${H - 3}" class="fx-carte-ax">${lon}°</text>`;
    }
    for (let lat = Math.ceil(bb.lat_min / 5) * 5; lat <= bb.lat_max; lat += 5) {
      svg += `<line x1="0" y1="${Y(lat)}" x2="${W}" y2="${Y(lat)}" class="fx-carte-grid"/><text x="3" y="${Y(lat)}" class="fx-carte-ax">${lat}°N</text>`;
    }
    for (const p of [...pts].sort((a, b2) => (a.score || 0) - (b2.score || 0))) {
      const s = Number(p.score) || 0;
      const r = (3 + s / 100 * 9).toFixed(1);
      const cls = s >= 66 ? "fx-pt-hi" : (s >= 33 ? "fx-pt-mid" : "fx-pt-lo");
      const lab = s >= 30 ? `<text x="${X(p.lon)}" y="${(Number(Y(p.lat)) - Number(r) - 2).toFixed(1)}" class="fx-carte-lb">${String(p.lieu || "").replace(/[<>&"]/g, "")}</text>` : "";
      svg += `<circle cx="${X(p.lon)}" cy="${Y(p.lat)}" r="${r}" class="fx-pt ${cls}"><title>${String(p.lieu || "")} (${String(p.pays || "")}) — score ${s}/100 · ${p.signaux || 0} signal(aux)${p.pays_seul ? " · pays seul cité (capitale)" : ""}</title></circle>${lab}`;
    }
    svg += "</svg>";
    const top = pts.slice(0, 8).map((p) => h("div", { class: "fx-carte-row" },
      h("span", { class: "fx-carte-sc" }, String(p.score || 0)),
      h("span", { class: "fx-carte-nm" }, String(p.lieu || ""), h("span", { class: "ds-meta" }, " · " + String(p.pays || "") + " · " + (p.signaux || 0) + " signal(aux)")),
      h("span", { class: "ds-meta fx-carte-t" }, String((p.titres && p.titres[0]) || ""))));
    b.replaceChildren(
      h("div", { html: svg }),
      ...top,
      h("div", { class: "fx-w-foot" }, "Score mécanique (gravité × fraîcheur × volume), grille lat/long sans frontières · " + (j.signaux_lus || 0) + " signaux lus / " + (j.window_days || 14) + " j · " + ((j.generated && fmtDate(j.generated)) || "")));
  }
  async function loadBrvm() {
    const b = wBrvm.querySelector(".fx-w-b");
    let syms = [], quotes = {}, locked = false, portErr = "";
    try {
      const p = await api.get("/api/portfolio", 12000);
      const accts = p && p.accounts && typeof p.accounts === "object" ? Object.values(p.accounts) : [];
      for (const a of accts) for (const pos of arrOf(a, "positions")) if (pos && pos.sym && !syms.includes(pos.sym)) syms.push(String(pos.sym));
      if (p && p.quotes && typeof p.quotes === "object") quotes = p.quotes;
    } catch (e) { if (/423/.test(String((e && e.message) || ""))) locked = true; else portErr = String((e && e.message) || e); }
    let watch = [], qrows = [], bErr = "", qAt = "";
    if (!syms.length || !Object.keys(quotes).length) {
      try {
        const j = await api.get("/api/veille/brvm", 25000);
        watch = arrOf(j, "watch").map(String); qrows = arrOf(j, "quotes"); bErr = j && j.error ? String(j.error) : ""; qAt = j && j.quotes_at ? String(j.quotes_at) : "";
        for (const r of qrows) if (r && r.sym && !quotes[r.sym]) quotes[r.sym] = { price: r.price, var: r.var };
      } catch (e) { bErr = String((e && e.message) || e).slice(0, 80); }
    }
    if (dead) return;
    const lines = syms.length ? syms : watch;
    const nodes = [];
    if (locked) nodes.push(h("div", { class: "fx-lock" }, h("span", { html: ic("lock", 13) }), "Coffre verrouillé — tes lignes SBIF restent masquées" + (watch.length ? " ; seules les valeurs suivies (réglage) s'affichent." : ".")));
    const rows = lines.map((s) => ({ sym: s, q: quotes[s] })).filter((r) => r.q && Number(r.q.price) > 0);
    if (rows.length) {
      nodes.push(h("div", { class: "fx-brvm" }, ...rows.slice(0, 12).map((r) => {
        const v = Number(r.q.var) || 0;
        const price = Number(r.q.price);
        const prevP = rollPrev.get("bq:" + r.sym);
        const moved = prevP != null && prevP !== price ? (price > prevP ? " tick-up" : " tick-down") : "";
        return h("div", { class: "fx-bq" + (v > 0 ? " up" : v < 0 ? " down" : "") + (reducedMotion() ? "" : moved) },
          h("b", {}, r.sym), h("span", { class: "fx-bq-p" }, rollNum("bq:" + r.sym, price, (x) => new Intl.NumberFormat("fr-FR", { maximumFractionDigits: Number.isInteger(price) ? 0 : 2 }).format(x) + " FCFA")),
          h("span", { class: "fx-bq-v" }, rollNum("bqv:" + r.sym, v, (x) => (v > 0 ? "▲ +" : v < 0 ? "▼ " : "■ ") + Number(x).toFixed(2).replace(".", ",") + " %")));
      })));
      nodes.push(h("div", { class: "fx-w-foot" }, (syms.length ? "Lignes du portefeuille" : "Valeurs suivies") + " · brvm.org (bandeau public, peut être différé)" + (qAt ? " · " + fmtDate(qAt) : "") + ". Information, pas un conseil."));
    } else if (lines.length) {
      nodes.push(h("div", { class: "ss" }, "Lignes suivies : " + lines.join(", ") + " — " + (bErr || "aucun cours servi par le moteur pour le moment.")));
    } else if (!locked) {
      nodes.push(h("div", { class: "ss" }, "Aucune ligne suivie servie par le moteur" + (bErr ? " (" + bErr + ")" : portErr ? " (" + portErr.slice(0, 60) + ")" : "") + "."));
    }
    b.replaceChildren(...nodes);
  }

  /* ── Vue Feeds › Fundings (GET /api/fundings) ───────────────────────────
     V6 (25/10) : l'ordre suit la hiérarchie du contrat — l'état en deux chiffres strictement séparés
     (acquis ≠ visés), les échéances, ce qui arrive (événements), le suivi des crédits, puis les
     programmes en tables (défilement interne à 550 px). Les règles d'Ahadi restent mot pour mot :
     un montant visé n'est jamais additionné aux acquis ; §3 verrouillé, aucune relance sans son GO. */
  function mountFundingsView(host) {
    let alive = true;
    const wrap = h("div", { class: "fx-fund vf-fund" });
    const kpiHost = h("div", {}, ds.skeleton(1));
    const secDue = ds.section({ title: "Prochaines échéances" });
    const dueHost = h("div", { class: "ds-list vf-duelist" }, h("p", { class: "ds-meta" }, "Lecture…"));
    secDue.body.append(dueHost);
    const secEv = ds.section({ title: "Événements de surveillance" });
    const evHost = h("div", {});
    secEv.body.append(evHost);
    const creditsHost = h("div", {});
    const progHost = h("div", {});
    wrap.append(kpiHost, secDue, secEv, creditsHost, progHost); host.append(wrap);
    const credits = mountCreditsSection(creditsHost, focusFund.indexOf("credit-") === 0 ? focusFund.slice(7) : "");
    const setCount = (sec, n) => { const hd = sec.querySelector(".ds-section-head"); let c = hd.querySelector(".ds-count"); if (!n) { if (c) c.remove(); return; } if (!c) { c = h("span", { class: "ds-count" }); hd.querySelector(".ds-h2").after(c); } c.textContent = String(n); };
    const table = (title, sub, items, locked) => {
      const sec = ds.section({ title, count: items.length || null });
      if (sub) sec.body.append(h("p", { class: "ds-meta vf-sub" }, sub));
      if (!items.length) { sec.body.append(h("p", { class: "ds-meta" }, "Aucun programme dans cette catégorie.")); return sec; }
      const th = (t, num) => h("th", { class: num ? "num" : null, scope: "col" }, t);
      sec.body.append(h("div", { class: "ds-table-wrap vf-tw" }, h("table", { class: "ds-table vf-table" },
        h("thead", {}, h("tr", {}, th("Programme"), th("Décision ou statut"), th("Montant en jeu", true), th("Action requise"), th("Échéance", true))),
        h("tbody", {}, items.map((p) => h("tr", { class: locked ? "is-locked" : null },
          h("td", { class: "vf-prog" },
            h("span", { class: "vf-prog-n" }, locked ? h("span", { class: "vf-lockic", title: "Verrouillé : aucune relance sans ton GO", html: ic("lock", 12) }) : null, String(p.programme || "—")),
            p.note || p.refs ? h("span", { class: "ds-meta vf-prog-s" }, [p.refs, p.note].filter(Boolean).join(" · ")) : null),
          h("td", {}, String(p.statut || "—")),
          h("td", { class: "num" }, String(p.montant || "—")),
          h("td", { class: locked ? "muted" : null }, String(p.action || (locked ? "Aucune relance sans ton GO" : "—"))),
          h("td", { class: "num" }, isoFR(p.echeance))))))));
      return sec;
    };
    const paint = (j) => {
      if (!alive) return;
      if (!j || !j.totals) {
        kpiHost.replaceChildren(emptyState("feed", "Campagne Fundings indisponible : le moteur n'a rien servi pour le moment."));
        dueHost.replaceChildren(); evHost.replaceChildren(); progHost.replaceChildren(); secDue.hidden = true; secEv.hidden = true;
        return;
      }
      secDue.hidden = false; secEv.hidden = false;
      fund = j;
      const t = j.totals || {};
      const ev = arrOf(j, "events");
      const cut = j.cut_off ? (toDate(j.cut_off) ? toDate(j.cut_off).toLocaleString("fr-FR", { timeZone: "UTC", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) + " GMT" : String(j.cut_off)) : "";
      kpiHost.replaceChildren(
        ds.kpis([
          { label: "Crédits acquis et actifs", value: rollNum("kpi:acquis", Number(t.acquis_usd) || 0, usd),
            delta: plural(Number(t.n_acquis) || 0, "programme", "programmes") + (Number(t.acquis_en_validation_usd) > 0 ? " · " + usd(t.acquis_en_validation_usd) + " en validation, non comptés" : ""), tone: "ok",
            tip: "Seuls les crédits confirmés sont comptés" },
          { label: "Dossiers en instruction", value: rollNum("kpi:attente", Number(t.n_en_attente) || 0, fmtInt),
            delta: "Montants visés : " + usd(t.vise_usd) + " — jamais additionnés aux acquis", tip: "Un montant visé n'est jamais présenté comme acquis" },
        ]),
        j.doctrine || cut ? h("p", { class: "vf-doctrine" }, h("b", {}, "Doctrine · "), String(j.doctrine || ""), cut ? h("span", { class: "ds-meta" }, " Coupure des statuts : " + cut + ".") : null) : null);
      /* Échéances : celles du dossier Fundings (j.prochaines), sinon les 3 premières datées à venir. */
      const pro = Array.isArray(j.prochaines) ? j.prochaines : arrOf(j, "echeances").filter((e) => Number(e.days_left) >= 0).slice(0, 3);
      setCount(secDue, pro.length);
      dueHost.replaceChildren(...(pro.length ? pro.slice(0, 5).map((e) => dueItem(Object.assign({ kind: "fundings" }, e), () => {
        const el = e.target ? evHost.querySelector('[data-fev="' + String(e.target) + '"]') : null;
        if (el) { try { el.scrollIntoView({ block: "center", behavior: reducedMotion() ? "auto" : "smooth" }); } catch (x) {} el.classList.add("flash"); setTimeout(() => el.classList.remove("flash"), 1600); }
      })) : [h("p", { class: "ds-meta" }, "Aucune échéance à venir dans le dossier.")]));
      setCount(secEv, ev.length);
      evHost.replaceChildren(ev.length ? h("div", { class: "fx-fev" }, ...ev.slice(0, 30).map((e) => {
        const el = tidyFev(renderFundingsEvent(e, { h, markRead: fundMarkRead }));
        if (e.id != null) el.setAttribute("data-fev", String(e.id));
        if (focusFund && String(e.id) === focusFund) { el.classList.add("flash"); setTimeout(() => { try { el.scrollIntoView({ block: "center" }); } catch (x) {} }, 60); setTimeout(() => el.classList.remove("flash"), 1800); }
        return arrive(el, seenFund, "f:" + String(e.id || ""));
      })) : h("p", { class: "ds-meta" }, "Aucun événement reçu depuis la coupure — les passes de surveillance (09:23, 17:23) les pousseront ici et dans le Fil direct."));
      progHost.replaceChildren(
        h("h2", { class: "ds-h2 vf-progh" }, "Programmes"),
        table("Crédits et approbations acquis", "Utilisables. « En validation » ou « en traitement » : pas encore comptés.", arrOf(j, "acquis"), false),
        table("Candidatures en attente", "Réponse attendue — les montants sont visés, jamais acquis.", arrOf(j, "en_attente"), false),
        table("Refusés, garés ou clos", "Verrouillés : aucune relance sans ta décision.", arrOf(j, "clos"), true));
      seenReady = true; focusFund = "";
    };
    const load = async () => { try { const j = await api.get("/api/fundings", 15000); paint(j); } catch (e) { if (alive) kpiHost.replaceChildren(stateError("Campagne Fundings injoignable", e, load)); } };
    load();
    return { reload() { load(); credits.reload(); }, destroy() { alive = false; credits.destroy(); try { wrap.remove(); } catch (e) {} } };
  }

  /* ── V5-I · Crédits acquis — suivi (GET /api/credits) ─────────────────
     Une carte par crédit : montant, échéance + compte à rebours, usage MESURÉ par Nova (jamais présenté comme
     le solde du fournisseur), état de branchement vérifié dans le code, repli prêt / à faire, action restante.
     Bandeau des urgences. Seuls boutons : actions réelles (réarmement d'un disjoncteur).
     V6 : carte en lignes clé → valeur (lecture en colonne), statuts en pastilles sémantiques, sans capitales. */
  function mountCreditsSection(host, focusId) {
    let alive = true, busy = false, exportMsg = null;   // dernier résultat d'export : survit au rechargement de la section
    const sec = ds.section({ title: "Crédits acquis — suivi" });
    sec.classList.add("fx-cr");
    sec.setAttribute("aria-label", "Crédits acquis — suivi");
    const body = h("div", { class: "fx-cr-body" }, ds.skeleton(2));
    sec.body.append(body);
    host.append(sec);
    const fmtUnits = (v, unit) => { const n = Number(v) || 0; if (/s d'audio/.test(unit || "")) return (n >= 3600 ? (n / 3600).toLocaleString("fr-FR", { maximumFractionDigits: 1 }) + " h" : Math.round(n / 60) + " min") + " d'audio"; return fmtInt(n) + " " + (unit || ""); };
    const branchTone = (b) => b === "branché" ? "ok" : b === "partiel" ? "warn" : "neutral";
    const repliTone = (e) => e === "prêt" ? "ok" : e === "en cours" ? "warn" : e === "à faire" ? "danger" : "neutral";
    const cap = (x) => { const s2 = String(x || ""); return s2 ? s2.charAt(0).toUpperCase() + s2.slice(1) : s2; };
    const kv = (k, ...v) => h("div", { class: "flx-kv" }, h("span", { class: "flx-kv-k" }, k), h("span", { class: "flx-kv-v" }, ...v));
    const dueNode = (c) => {
      const n = c.days_left;
      if (n == null || !c.echeance) return [h("span", {}, String(c.echeance_label || "non communiquée"))];
      const tone = n < 0 ? "danger" : (n <= 7 || (c.alerte_forte && n <= 30)) ? "danger" : n <= 30 ? "warn" : "neutral";
      return [h("span", {}, String(c.echeance_label || ddmm(c.echeance))), " ", ds.pill(n < 0 ? "Passée" : (c.approx ? "≈ " : "") + cap(countdown(n)), tone)];
    };
    const usageNode = (c) => {
      const u = c.usage || {};
      const calls = Number(u.calls) || 0;
      const parts = [];
      if (u.mesure && calls > 0) {
        parts.push(fmtInt(calls) + " appel" + (calls > 1 ? "s" : ""));
        if (Number(u.units) > 0 && u.unit && u.unit !== "requête" && u.unit !== "événements") parts.push(fmtUnits(u.units, u.unit));
        if (Number(u.cost_usd) > 0) parts.push(Number(u.cost_usd).toLocaleString("fr-FR", { maximumFractionDigits: 2 }) + " $ estimés" + (u.pct_credit != null ? " (" + u.pct_credit + " %)" : ""));
        if (Number(u.errors) > 0) parts.push(fmtInt(u.errors) + " échec(s) crédit/quota");
      }
      return [h("span", {}, parts.length ? parts.join(" · ") + (u.first ? " — depuis le " + fmtDate(u.first) : "") : (u.mesure ? "Aucun appel compté pour l'instant" : "Non mesuré")),
        u.note ? h("span", { class: "ds-meta vf-kv-s" }, String(u.note)) : null];
    };
    const rearm = async (c, btn) => {
      btn.disabled = true;
      try { await api.post("/api/credits/rearm", { provider: String(c.compteur || c.id) }, 15000); ctx.toast("Disjoncteur de " + c.programme + " réarmé : Nova réessaiera au prochain appel."); load(); }
      catch (e) { btn.disabled = false; ctx.toast("Réarmement impossible : " + String(e && e.message || e), true); }
    };
    const card = (c, pe) => {
      const r = c.repli || {};
      const br = c.disjoncteur && c.disjoncteur.open ? c.disjoncteur : null;
      const confirme = c.confirme === true;
      const el = h("article", { class: "vf-crc" + (c.alerte_forte ? " is-strong" : "") + (c.verrou ? " is-locked" : ""), id: "credit-" + c.id },
        h("header", { class: "vf-crc-h" },
          h("h3", { class: "ds-h3 vf-crc-n" }, c.verrou ? h("span", { class: "vf-lockic", title: "Verrou posé par toi", html: ic("lock", 13) }) : null, String(c.programme || "—")),
          ds.pill(cap(c.branchement || "—"), branchTone(c.branchement))),
        h("div", { class: "vf-crc-amt" }, h("b", { class: "vf-crc-v" }, String(c.montant || "—")),
          h("span", { class: "ds-meta" }, c.montant_usd != null ? (confirme ? "compté dans les acquis" : "non compté (en validation)") : "non monétaire")),
        c.verrou ? h("p", { class: "vf-crc-lock", role: "note" }, h("span", { class: "ds-ic", html: ic("lock", 14) }), h("span", {}, String(c.verrou))) : null,
        br ? h("div", { class: "vf-crc-br", role: "alert" }, h("span", {}, "Disjoncteur ouvert (" + String(br.reason || "") + ") depuis le " + fmtDate(br.since) + (br.until ? " — nouvel essai après " + fmtDate(br.until) : "") + ". Nova utilise le repli."),
          ds.action({ label: "Réarmer", onClick: (e) => rearm(c, e.currentTarget) })) : null,
        h("div", { class: "vf-crc-kv" },
          kv("Échéance", ...dueNode(c)),
          kv("Usage mesuré par Nova", ...usageNode(c)),
          kv("Solde réel", h("span", {}, cap(String(c.solde_reel || "à vérifier sur le portail")))),
          kv("Si le crédit s'épuise", h("span", { class: "vf-repli" }, ds.pill(cap(r.etat || "—"), repliTone(r.etat)), r.cible ? h("span", {}, String(r.cible)) : null),
            r.detail ? h("span", { class: "ds-meta vf-kv-s" }, String(r.detail)) : null),
          c.action ? kv("Reste à faire", h("b", { class: "vf-todo" }, String(c.action))) : null),
        ds.fold("À quoi ça sert, comment Nova l'utilise", [
          h("p", {}, h("b", {}, "Sert à · "), String(c.sert_a || "—")),
          h("p", {}, h("b", {}, "Dans Nova · "), String(c.usage_nova || "—")),
          h("p", {}, h("b", {}, "Objectif · "), String(c.objectif || "—")),
          h("p", { class: "ds-meta" }, "Branchement vérifié dans le code : " + String(c.branchement_preuve || "—")),
          c.cle && c.cle.ou ? h("p", { class: "ds-meta" }, "Clé : " + (c.cle.presente ? "présente" : "absente") + (/[\/\\]/.test(String(c.cle.ou)) ? "" : " (" + String(c.cle.ou) + ")") + (c.cle.interrupteur === false ? " · interrupteur fermé" : "")) : null,
          c.date_alerte ? h("p", { class: "ds-meta" }, "Alerte posée au " + ddmm(c.date_alerte) + (arrOf(c, "alertes_envoyees").length ? " · déjà envoyées : " + arrOf(c, "alertes_envoyees").map((x) => String(x).split(":")[1]).join(", ") : "")) : null], false));
      return el;
    };
    const paint = (j) => {
      if (!alive) return;
      const list = arrOf(j, "credits");
      if (!list.length) { body.replaceChildren(emptyState("feed", "Suivi des crédits indisponible : le moteur n'a rien servi pour le moment.")); return; }
      const t = (j && j.totals) || {};
      const urg = arrOf(j, "urgences");
      const hors = arrOf(j, "hors_acquis");
      const parts = arrOf(j, "partenaires_nebius");
      const ev = j.local_events || {};
      const nEv = Object.values(ev).reduce((a, b) => a + (Number(b) || 0), 0);
      body.replaceChildren(...[
        h("div", { class: "vf-crsum" },
          h("span", { class: "vf-crsum-v" }, "Acquis confirmés : " + usd(t.acquis_usd)),
          h("span", { class: "ds-meta" }, [t.point_usd ? "ton point : ≈ " + usd(t.point_usd) : "", String(t.note || ""), String(j.solde_note || "")].filter(Boolean).join(" · "))),
        urg.length ? h("div", { class: "vf-urg", role: "list", "aria-label": "Urgences" }, ...urg.map((u) => {
          const lock = u.niveau === "verrou";
          const b = h("button", { class: "vf-urg-i" + (lock ? " is-lock" : " is-strong"), type: "button", role: "listitem", title: "Aller à la carte" },
            h("span", { class: "vf-urg-t" }, lock ? h("span", { class: "ds-ic", html: ic("lock", 13) }) : null, String(u.titre || "")),
            ds.pill(u.days_left != null ? cap(countdown(u.days_left)) : "Verrou", lock ? "warn" : "danger"),
            h("span", { class: "vf-urg-d" }, String(u.detail || "")));
          b.addEventListener("click", () => { const el = sec.querySelector("#credit-" + String(u.id)); if (el) { try { el.scrollIntoView({ block: "center", behavior: reducedMotion() ? "auto" : "smooth" }); } catch (e) {} el.classList.add("flash"); setTimeout(() => el.classList.remove("flash"), 1600); } });
          return b;
        })) : null,
        h("div", { class: "vf-crgrid" }, ...list.map((c) => card(c, j.pinecone_export))),
        h("div", { class: "vf-crfoot" },
          hors.length ? h("p", {}, h("b", {}, "Hors acquis (jamais additionnés) · "), hors.map((x) => String(x.programme) + " — " + String(x.montant)).join(" ; ") + ".") : null,
          parts.length ? h("p", {}, h("b", {}, "Partenaires Nebius à réclamer · "), parts.join(", ") + " (conditions propres à chacun).") : null,
          h("p", { class: "ds-meta" }, "Replis locaux : " + fmtInt(nEv) + " événement(s) comptés en local" + (j.local_events_since ? " depuis le " + fmtDate(j.local_events_since) : "") + " · " + fmtInt(j.crash_local) + " plantage(s) au journal local."))].filter(Boolean));
      if (focusId) { const el = sec.querySelector("#credit-" + focusId); focusId = ""; if (el) { el.classList.add("flash"); setTimeout(() => { try { el.scrollIntoView({ block: "center" }); } catch (x) {} }, 60); setTimeout(() => el.classList.remove("flash"), 1800); } }
    };
    const load = async () => { try { const j = await api.get("/api/credits", 15000); paint(j); } catch (e) { if (alive) body.replaceChildren(stateError("Suivi des crédits injoignable", e, load)); } };
    load();
    const off = bus.on("credits", () => { if (alive && !busy) load(); });
    return { reload: load, destroy() { alive = false; try { off && off(); } catch (e) {} try { sec.remove(); } catch (e) {} } };
  }

  /* ── Sources du radar (matière première, repliée) ───────────────────── */
  let srcOpen = false;
  async function loadSources() {
    if (dead) return;
    const body = h("div", { hidden: !srcOpen });
    const toggle = h("button", { type: "button", class: "btn sm ds-btn-secondary", "aria-expanded": srcOpen ? "true" : "false", onclick: () => { srcOpen = !srcOpen; body.hidden = !srcOpen; toggle.textContent = srcOpen ? "Replier" : "Afficher"; toggle.setAttribute("aria-expanded", srcOpen ? "true" : "false"); } }, srcOpen ? "Replier" : "Afficher");
    srcBox.replaceChildren(h("div", { class: "ds-card vf-src" },
      h("div", { class: "src-head" }, h("span", { class: "ds-meta" }, "Les articles bruts que le radar a gardés — la matière première du fil, pas le fil."), h("span", { class: "sp" }), toggle), body));
    try {
      const j = await api.get("/api/veille/radar", 40000);
      if (dead) return;
      const items = arrOf(j, "items");
      const failed = arrOf(j, "sources").filter((s) => s && s.ok !== true);
      body.replaceChildren(
        ...(failed.length ? [h("p", { class: "feed-srcerr" }, h("span", { html: ic("alert", 13) }), " Sources en échec : " + failed.map((s) => String(s.name || "?") + " (" + String(s.detail || "injoignable") + ")").join(" · "))] : []),
        ...(items.length ? items.slice(0, 60).map((it) => h("div", { class: "src-row" }, h("span", { class: "src-name" }, String(it.source || "?")), h("span", { class: "src-title" }, String(it.title || "")), h("span", { class: "feed-time" }, fmtDate(it.date || it.ts))))
          : [emptyState("feed", "Aucun article gardé dans la fenêtre.")]),
        ...(j && j.limits ? [h("p", { class: "feed-srcerr" }, String(j.limits))] : []));
    } catch (e) { if (!dead) body.replaceChildren(h("p", { class: "feed-srcerr" }, "Sources du radar injoignables pour le moment.")); }
    // La route radar vient de proposer une passe détachée et de garder son relevé : relecture différée.
    setTimeout(() => { if (!dead) loadAll(false); }, 3000);
  }

  /* ── Chargement ─────────────────────────────────────────────────────── */
  let notePolls = 0, noteTimer = null, sig = "";
  const stopNotePoll = () => { if (noteTimer) { clearTimeout(noteTimer); noteTimer = null; } };
  async function loadAll(force) {
    if (dead) return;
    refreshBtn.disabled = true;
    try {
      const j = await api.get("/api/feeds/overview", 20000);
      if (dead) return;
      ov = j && typeof j === "object" ? j : {};
      ovErr = null;
    } catch (e) { if (dead) return; ovErr = e; }
    finally { if (!dead) refreshBtn.disabled = false; }
    const note = ov && ov.note ? String(ov.note) : "";
    if (note.indexOf("en cours") >= 0 && notePolls < 15) { notePolls += 1; stopNotePoll(); noteTimer = setTimeout(() => { noteTimer = null; loadAll(false); }, 20000); }
    else { notePolls = 0; stopNotePoll(); }
    const nsig = JSON.stringify([arrOf(ov, "units").map((u) => [u.id, u.read === true, u.user_pin === true, u.vote || ""]), arrOf(ov && ov.fundings, "events").map((e) => [e.id, e.lu]), note, !!ovErr]);
    paintPills(); paintTicker(); paintDues(); paintHeat(); paintLive();
    if (force || nsig !== sig) {
      sig = nsig;
      const y = root.scrollTop;
      if (filter !== "fundings" || force) paintMain();
      requestAnimationFrame(() => { try { root.scrollTop = y; } catch (e) {} });
    }
  }
  async function loadPulses() {
    let j = null;
    try { j = await api.get("/api/pulse"); } catch (e) { j = null; }
    if (dead) return;
    pulses = j && Array.isArray(j.history) ? j.history : [];
    if (filter === "pulses") paintMain();
  }

  offs.push(bus.on("fundings", () => { if (dead) return; loadAll(false); if (fundView) fundView.reload(); }));
  offs.push(bus.on("nova:brief-focus", (d) => {
    try {
      const id = d && d.id != null ? String(d.id) : ""; if (!id || dead) return;
      if (filter !== "tout" && filter !== "pulses") { filter = "tout"; paintPills(); paintMain(); }
      const el = root.querySelector('[data-brief-id="' + id + '"]'); if (!el) return;
      try { el.scrollIntoView({ block: "center" }); } catch (e) {}
      el.classList.add("flash"); setTimeout(() => { if (!dead) el.classList.remove("flash"); }, 1600);
    } catch (e) {}
  }));
  /* V5-H — carte « en direct » : un Éclat de veille tourne À L'INSTANT (GET /api/activity → running, état du
     moteur) ou la passe du radar est en cours (note du moteur). Rien ne tourne → la carte n'existe pas.
     Sondage léger : 6 s seulement tant que quelque chose tourne ; sinon réveil par SSE (dot) et minute. */
  let act = null, actTimer = null, actBusy = false, liveClock = null;
  const elapsed = (since) => { const d = toDate(since); if (!d) return ""; const s2 = Math.max(0, Math.round((Date.now() - d.getTime()) / 1000)); const m = Math.floor(s2 / 60); return m >= 60 ? Math.floor(m / 60) + " h " + String(m % 60).padStart(2, "0") : m > 0 ? m + " min " + String(s2 % 60).padStart(2, "0") + " s" : s2 + " s"; };
  function liveItems() {
    const out = [];
    for (const r of arrOf(act, "running")) {
      if (!r || r.kind !== "dot") continue;
      if (!VEILLE_DOT_RX.test(String(r.name || "") + " " + String(r.id || ""))) continue;
      out.push({ key: "dot:" + String(r.id || ""), icon: String(r.emoji || "●"), name: String(r.name || r.id || "Éclat"), label: String(r.label || "au travail…"), detail: String(r.detail || ""), since: r.since || "", ecran: "dots" });
    }
    /* V6 : la passe du radar « en cours » n'a sa carte que si le bandeau ne la montre pas déjà (un seul indicateur). */
    const note = ov && ov.note ? String(ov.note) : "";
    const tickerLive = arrOf(ov, "ticker").some((x) => x && x.live);
    if (note.indexOf("en cours") >= 0 && !tickerLive) out.push({ key: "radar", icon: "", name: "Radar Afrique", label: note, detail: "", since: "", ecran: "" });
    return out;
  }
  let liveSig = "";
  function paintLive() {
    const items = liveItems();
    const sigL = items.map((x) => x.key + "|" + x.label + "|" + x.detail).join("\n");
    if (!items.length) { liveHost.hidden = true; liveHost.replaceChildren(); liveSig = ""; if (liveClock) { clearInterval(liveClock); liveClock = null; } return; }
    if (sigL !== liveSig) {
      const firstShow = liveSig === "";
      liveSig = sigL;
      liveHost.replaceChildren(...items.map((x) => h("div", { class: "fx-livecard" + (firstShow && !reducedMotion() ? " fx-new" : ""), role: "status" },
        h("span", { class: "vf-lc-dot", title: "En cours", "aria-label": "En cours" }, h("i", {})),
        x.icon ? h("span", { class: "fx-lc-ic", "aria-hidden": "true" }, x.icon) : null,
        h("span", { class: "fx-lc-txt" }, h("b", {}, x.name), h("span", { class: "fx-lc-l" }, x.label), x.detail ? h("span", { class: "fx-lc-d" }, x.detail) : null),
        h("span", { class: "fx-lc-t", "data-since": x.since ? String(x.since) : "" }, x.since ? "depuis " + elapsed(x.since) : ""),
        x.ecran ? h("button", { type: "button", class: "btn sm ds-btn-secondary", onclick: () => ctx.navigate(x.ecran) }, "Voir l'Éclat") : null)));
    }
    liveHost.hidden = false;
    if (!liveClock) liveClock = setInterval(() => { if (dead) return; liveHost.querySelectorAll(".fx-lc-t[data-since]").forEach((n) => { const v = n.getAttribute("data-since"); if (v) n.textContent = "depuis " + elapsed(v); }); }, 1000);
  }
  async function loadActivity() {
    if (dead || actBusy) return;
    actBusy = true;
    if (actTimer) { clearTimeout(actTimer); actTimer = null; }
    try { const j = await api.get("/api/activity", 10000); if (dead) return; act = j && typeof j === "object" ? j : null; }
    catch (e) { act = null; }   // moteur injoignable : aucune carte « en direct » (jamais d'état supposé)
    finally { actBusy = false; }
    if (dead) return;
    paintLive();
    if (liveItems().length) actTimer = setTimeout(loadActivity, 6000);
  }
  /* Rafales SSE regroupées : un seul rechargement léger 2,5 s après le dernier événement. */
  let kickTimer = null;
  const kick = () => { if (dead) return; if (kickTimer) clearTimeout(kickTimer); kickTimer = setTimeout(() => { kickTimer = null; loadAll(false); loadActivity(); }, 2500); };
  for (const ev of ["dot", "brief", "engagements", "feed"]) { try { offs.push(bus.on(ev, kick)); } catch (e) {} }
  /* Clic sur une notification native (NovaNotify → nova:notif-open {module, id}) */
  offs.push(bus.on("nova:notif-open", (d) => {
    if (dead || !d || d.module !== "veille") return;
    const id = String(d.id || "");
    if (id.indexOf("fundings:") === 0) { focusFund = id.slice(9); filter = "fundings"; try { localStorage.setItem(FILTER_KEY, filter); } catch (e) {} paintPills(); paintMain(); }
  }));
  const onResizeTk = () => layoutTicker();
  window.addEventListener("resize", onResizeTk);
  let ticks = 0;
  const stopTick = ctx.every ? ctx.every(60000, () => { loadAll(false); loadActivity(); ticks += 1; if (ticks % 5 === 0) { loadBrvm(); loadCarte(); } }, { now: false }) : null;

  paintPills(); paintTicker(); paintMain(); paintDues(); paintHeat();
  let lastLoad = Date.now();
  loadAll(true); loadSources(); loadPulses(); loadBrvm(); loadActivity(); loadCarte();   /* LOT J */
  return {
    destroy() {
      dead = true; stopNotePoll(); if (stopTick) stopTick();
      if (actTimer) clearTimeout(actTimer); if (liveClock) clearInterval(liveClock); if (kickTimer) clearTimeout(kickTimer);
      window.removeEventListener("resize", onResizeTk);
      for (const o of offs) { try { o(); } catch (e) {} }
      if (fundView) { try { fundView.destroy(); } catch (e) {} }
      window.removeEventListener("keydown", onKey); window.removeEventListener("resize", placeReader);
      try { reader.remove(); } catch (e) {}
    },
    onShow() { requestAnimationFrame(layoutTicker); if (Date.now() - lastLoad < 30000) return; lastLoad = Date.now(); loadAll(false); loadSources(); loadPulses(); loadBrvm(); loadActivity(); },
    onHide() { closeReader(); },
  };
}
