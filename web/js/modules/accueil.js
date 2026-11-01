/* accueil.js — V5-Q (25/10/2026) : L'ACCUEIL v3 (maquette validée par Ahadi), pour TOUS les thèmes.

     1  HÉROS (verre)  « Bonjour Ahadi. » + phrase du moment (N = éléments prioritaires réels),
        date · heure · ville · météo (GET /api/state → réglages lat/lon/city, Open-Meteo),
        « Demander à Nova » (même comportement que l'ancien champ : la question part dans
        Conversations, ouverte à côté) + suggestions, 3 chiffres à barre partagée ;
        à droite L'ANNEAU DU JOUR (24 h, 0 h en haut, sens horaire) : heures calmes
        (GET /api/silence → quiet, sinon réglages quiet_from/quiet_to), rendez-vous du jour
        (GET /api/today), créneau de travail profond proposé (GET /api/chrono → 1er créneau du
        jour), rituels actifs (GET /api/rituels), aiguille « maintenant » ; au centre le
        compagnon (ancre « hero » de companion.js — l'unique présence, rien n'est recréé).
     2  Trois cartes : À toi de décider (engagements, Éclats en attente, échéances Fundings),
        Courrier (GET /api/mail/counts + fil proactif), Marchés BRVM (portefeuille si le
        Coffre est ouvert, sinon valeurs suivies ; courbe = historique local réel seulement).
     3  Bandeau : Feeds, Éclats, Conseil, Brief. Puis « Pendant ton absence », le Pulse et
        le pied « budget » (inchangés).
   Règle : une source illisible affiche « — » ou un état vide honnête ; aucun chiffre, aucune
   courbe, aucune durée n'est inventé (seule hypothèse dite : un rendez-vous sans heure de fin
   occupe 1 h sur l'anneau — le calendrier lu par le moteur ne donne que l'heure de début).
   Cycle de vie (règles V5-N) : une minuterie alignée sur la minute (horloge + aiguille + données
   rapides toutes les 60 s, lentes toutes les 5 min), arrêtée quand l'Accueil est caché. */
import { presenceAnchor } from "../companion.js";

/* 26/10 : brouillon de la question partagé entre instances de l'Accueil (un re-montage pendant la frappe effaçait le texte). */
let ASK_DRAFT = "";
const arr = (j, ...k) => { if (Array.isArray(j)) return j; for (const x of k) if (j && Array.isArray(j[x])) return j[x]; return []; };
const has = (j, ...k) => Array.isArray(j) || k.some((x) => j && Array.isArray(j[x]));
const nfr = (n, d = 0) => new Intl.NumberFormat("fr-FR", { maximumFractionDigits: d }).format(n);
const pct = (n) => (n > 0 ? "+" : n < 0 ? "−" : "") + new Intl.NumberFormat("fr-FR", { minimumFractionDigits: Math.abs(n) < 10 ? 2 : 1, maximumFractionDigits: 2 }).format(Math.abs(n)) + " %";
const pct1 = (n) => (n > 0 ? "+" : n < 0 ? "−" : "") + new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(Math.abs(n)) + " %";
const hhmm = (d) => d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
const toDate = (v) => { if (v == null || v === "") return null; const d = typeof v === "number" ? new Date(v > 1e12 ? v : v * 1000) : new Date(v); return isNaN(d) ? null : d; };
const relTime = (d) => { if (!d) return ""; const m = Math.round((Date.now() - d.getTime()) / 60000); if (m < 1) return "à l'instant"; if (m < 60) return "il y a " + m + " min"; const hh = Math.round(m / 60); if (hh < 24) return "il y a " + hh + " h"; return "le " + d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }); };
const dayStart = (d = new Date()) => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; };
const isoDay = (d) => d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
const sameDay = (a, b) => a && b && a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
const ymd = (s) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s || "")); return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null; };
const daysFrom = (d) => Math.round((dayStart(d) - dayStart()) / 86400000);
const shortDate = (d) => d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" });
/* « 22:00 », « 7h30 », « daily 18:00 », cron « 30 7 * * * » → heures décimales ; null si illisible. */
const parseHour = (v) => {
  const s = String(v == null ? "" : v).trim(); if (!s) return null;
  let m = /(?:^|\D)(\d{1,2})\s*[:h]\s*(\d{2})(?!\d)/.exec(s);
  if (m && +m[1] < 24 && +m[2] < 60) return +m[1] + +m[2] / 60;
  m = /^(\d{1,2})\s+(\d{1,2})\s+\*\s+\*\s+[\d*,\-]+$/.exec(s);
  if (m && +m[2] < 24 && +m[1] < 60) return +m[2] + +m[1] / 60;
  return null;
};
const fmtH = (h) => { const t = Math.round(h * 60) % 1440; return String(Math.floor(t / 60)).padStart(2, "0") + ":" + String(t % 60).padStart(2, "0"); };
const NUM = ["Zéro", "Une", "Deux", "Trois", "Quatre", "Cinq", "Six", "Sept", "Huit", "Neuf", "Dix", "Onze", "Douze"];
const AV_COLORS = ["#7A5C8E", "#3F6E8C", "#8C6A3F", "#4F7352", "#8E4F55", "#4D6680", "#77683A", "#6A5A84"];
const avColor = (name) => { let x = 0; for (const c of String(name || "")) x = (x * 31 + c.codePointAt(0)) >>> 0; return AV_COLORS[x % AV_COLORS.length]; };
const initials = (name) => { const w = String(name || "").replace(/[<>"(),+]/g, " ").replace(/\S+@\S+/g, "").trim().split(/\s+/).filter((x) => /\p{L}/u.test(x)); return ((w[0] || "?")[0] + (w.length > 1 ? w[w.length - 1][0] : (w[0] || "")[1] || "")).toUpperCase(); };
const WMO = (c) => c === 0 ? "ciel dégagé" : c <= 2 ? "peu nuageux" : c === 3 ? "couvert" : c <= 48 ? "brouillard" : c <= 57 ? "bruine" : c <= 67 ? "pluie" : c <= 77 ? "neige" : c <= 82 ? "averses" : c <= 86 ? "averses de neige" : "orage";

export async function mount(root, ctx) {
  const { api, bus, h, ic } = ctx;
  let dead = false, shown = true, tickT = 0, lastSlow = 0, lastWeather = 0;
  root.classList.add("home", "hq");
  root.dataset.resetScroll = "0";
  const isSable = () => document.documentElement.dataset.material === "sable";
  /* Icône céramique sous Sable (la décision V5-L tient : sur les autres matières les tuiles crème
     font « autocollant ») — ailleurs, le pictogramme au trait dans une pastille teintée. */
  /* 30/10 : icônes en VERRE (série [tiers] validée par Ahadi, img/glass/) — toutes matières sauf Sable (céramique) ; repli : le trait. */
  const icon = (name, glyph, px, glass) => h("span", { class: "hq-ico" + (glass ? " has-glass" : ""), style: "--px:" + px + "px", "aria-hidden": "true" },
    h("img", { src: "img/icons3d/" + name + "-256.webp", srcset: "img/icons3d/" + name + "-256.webp 1x, img/icons3d/" + name + "-512.webp 2x", alt: "", decoding: "async", width: String(px), height: String(px) }),
    glass ? h("img", { class: "g", src: "img/glass/" + glass + "-128.webp", srcset: "img/glass/" + glass + "-128.webp 1x, img/glass/" + glass + "-256.webp 2x", alt: "", decoding: "async", width: String(px), height: String(px) }) : null,
    h("i", { html: ic(glyph, Math.round(px * 0.46)) }));
  const S = { state: null, commit: null, waiting: null, fund: null, counts: null, feed: null, today: null, silence: null, chrono: null, rituels: null, dots: null, council: null, briefs: null, feeds: null, apiOk: null };

  /* ── 1 · HÉROS ───────────────────────────────────────────────────── */
  const greet = h("span", {}, "Bonjour.");
  const lead = h("span", { class: "hq-lead" }, "");
  const title = h("h1", { class: "hq-title" }, greet, h("br"), lead);
  const live = h("i", { class: "hq-live", "aria-hidden": "true" });
  const whenTx = h("span", {}, "");
  const vide = h("button", { class: "hq-vide", title: "Le Vide : tout disparaît sauf le compagnon — Échap pour revenir", "aria-label": "Le Vide : masquer tout sauf le compagnon", onclick: () => bus.emit("nova:vide-toggle", {}) });
  vide.innerHTML = ic("moon", 13) + "<span>Le Vide</span>";
  const sub = h("p", { class: "hq-sub" }, live, whenTx, vide);
  const askIn = h("input", { class: "hq-ask-in", type: "text", placeholder: "Demander à Nova…", "aria-label": "Demander à Nova", autocomplete: "off" });
  const askGo = h("button", { class: "hq-send", title: "Envoyer (Entrée)", "aria-label": "Envoyer la question à Nova" }); askGo.innerHTML = ic("arrow-up-right", 15);
  const askBox = h("label", { class: "hq-ask" }, h("span", { class: "hq-ask-ic", html: ic("sparkle", 18) }), askIn, askGo);
  const chips = h("div", { class: "hq-chips" });
  const ask = (text) => {
    text = String(text || "").trim(); if (!text) return;
    askIn.value = ""; ASK_DRAFT = ""; chips.hidden = false;
    try { window.NovaWorkspace ? window.NovaWorkspace.openBeside("conversations") : ctx.navigate("conversations"); } catch (e) { ctx.navigate("conversations"); }
    let tries = 0;
    const fire = () => { if (document.querySelector('.mod[data-mod="conversations"] .composer') || tries > 30) { bus.emit("nova:ask", { text, fresh: true }); return; } tries++; setTimeout(fire, 150); };
    setTimeout(fire, 120);
  };
  askIn.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); ask(askIn.value); } });
  askIn.addEventListener("input", () => { chips.hidden = !!askIn.value; ASK_DRAFT = askIn.value; });
  if (ASK_DRAFT) { askIn.value = ASK_DRAFT; chips.hidden = true; }
  askGo.addEventListener("click", (e) => { e.preventDefault(); ask(askIn.value); });
  for (const [label, q] of [["Brief du matin", "Fais-moi le brief du matin : ce qui compte aujourd'hui, en BLUF."], ["Point BRVM", "Fais le point sur mon portefeuille BRVM (SBIF) : variations du jour et ce qui mérite mon attention."], ["Qui relancer ?", "Qui dois-je relancer aujourd'hui, et pourquoi ?"], ["Mes mails importants", "Quels mails reçus depuis hier demandent une action de ma part ?"]]) {
    chips.append(h("button", { class: "hq-chip", onclick: () => ask(q) }, label));
  }
  const kpi = (label, go) => {
    const v = h("b", {}, "—"), bar = h("span", { class: "hq-bar", "aria-hidden": "true" }), note = h("small", {}, "");
    const el = h("button", { class: "hq-kpi", onclick: () => ctx.navigate(go) }, h("span", { class: "hq-kpi-l" }, label), v, bar, note);
    return { el, v, bar, note, label };
  };
  const K = { dus: kpi("Engagements dus", "engagements"), mails: kpi("Messages non lus", "messages"), dec: kpi("Décisions en attente", "dots") };
  const setKpi = (k, val, segs, note, hot) => {
    k.v.textContent = val == null ? "—" : String(val);
    k.el.classList.toggle("hot", !!hot);
    k.el.dataset.empty = val == null ? "1" : "0";
    k.bar.replaceChildren(...(segs || []).filter((s) => s.n > 0).map((s) => h("i", { class: "hq-seg-" + s.c, style: "flex:" + s.n })));
    k.note.textContent = note || "";
    k.el.setAttribute("aria-label", k.label + " : " + (val == null ? "indisponible" : val) + (note ? " — " + note : ""));
  };
  /* L'anneau : SVG 340 × 340, compagnon au centre (cadre rond 150 px), légende et légende du prochain rendez-vous. */
  const anchor = presenceAnchor(ctx, { slot: "hero", px: 150 });
  const dial = h("div", { class: "hq-dial" });
  const capS = h("span", {}, ""), capB = h("b", {}, "");
  const ring = h("div", { class: "hq-ring" }, dial, h("div", { class: "hq-pd" }, anchor), h("div", { class: "hq-cap", "aria-live": "polite" }, capS, capB));
  const legend = h("div", { class: "hq-legend", "aria-hidden": "true" },
    ...[["quiet", "Heures calmes"], ["rdv", "Rendez-vous"], ["deep", "Travail profond"], ["now", "Maintenant"]].map(([c, t]) => h("span", {}, h("i", { class: "hq-lg-" + c }), t)));
  const hero = h("section", { class: "hq-hero hq-glass", "aria-label": "Aujourd'hui" },
    h("div", { class: "hq-hero-l" }, title, sub, askBox, chips, h("div", { class: "hq-kpis", role: "group", "aria-label": "En chiffres" }, K.dus.el, K.mails.el, K.dec.el)),
    ring, legend);

  /* ── 2 · CARTES ──────────────────────────────────────────────────── */
  const card = (cls, name, glyph, t, s, linkLabel, go, glass) => {
    const subEl = h("p", {}, s);
    const body = h("div", { class: "hq-card-b" });
    const el = h("section", { class: "hq-card hq-glass " + cls, "aria-label": t },
      h("header", {}, icon(name, glyph, 44, glass), h("div", { class: "hq-card-t" }, h("h2", {}, t), subEl), h("button", { class: "hq-link", onclick: () => ctx.navigate(go), "aria-label": linkLabel + " — ouvrir " + t }, linkLabel)),
      body);
    return { el, sub: subEl, body };
  };
  const C = {
    dec: card("hq-dec", "cadran-solaire", "check", "À toi de décider", "", "Tout voir", "engagements", "attente"),
    mail: card("hq-mail", "courrier", "mail", "Courrier", "Ce qui attend une réponse de toi", "Messages", "messages", "messages"),
    mk: card("hq-mk", "portefeuille", "chart", "Marchés BRVM", "", "Finance", "finance", "finance"),
  };
  /* ── 3 · BANDEAU ─────────────────────────────────────────────────── */
  const tile = (name, glyph, go, label, glass) => {
    const b = h("b", {}, "—"), p = h("p", {}, "");
    const el = h("button", { class: "hq-tile hq-glass", onclick: () => ctx.navigate(go), "aria-label": label }, icon(name, glyph, 52, glass), h("div", { class: "hq-tile-t" }, b, p));
    return { el, b, p, label };
  };
  const T = { feeds: tile("globe", "globe", "veille", "Feeds", "feeds"), eclats: tile("eclats", "agent", "dots", "Éclats", "dots"), conseil: tile("conseil", "council", "conseil", "Conseil", "conseil"), brief: tile("cadran-solaire", "brief", "veille", "Brief") };
  const setTile = (t, b, p) => {
    t.el.hidden = b == null;
    t.b.textContent = b || ""; t.p.textContent = p || "";
    t.el.setAttribute("aria-label", t.label + " : " + (b || "") + (p ? " — " + p : ""));
  };

  /* « Pendant ton absence » (R-196), Pulse et budget : conservés, sous le bandeau. */
  const absence = h("section", { class: "home-card hq-absence", hidden: "" });
  let lastSeen = 0; try { lastSeen = Number(localStorage.getItem("nova2_last_seen") || 0); } catch (e) {}
  const markSeen = () => { try { localStorage.setItem("nova2_last_seen", String(Date.now())); } catch (e) {} };
  const pulse = pulseSection(ctx, { ask, isDead: () => dead });
  const sugg = suggestTile(ctx, { isDead: () => dead, directId: () => String((S.feed && S.feed.direct_thread_id) || "") });   // V5-U : « Nova te propose »
  const budget = budgetFooter(ctx, { isDead: () => dead });
  const gridEl = h("div", { class: "hq-grid" }, C.dec.el, C.mail.el, C.mk.el);
  const stripEl = h("div", { class: "hq-strip" }, T.feeds.el, T.eclats.el, T.conseil.el, T.brief.el);
  const custom = homeCustomizer(ctx, { ring, legend, hero, gridEl, stripEl, cards: [["dec", "À toi de décider", C.dec.el], ["mail", "Courrier", C.mail.el], ["mk", "Marchés BRVM", C.mk.el]],
    tiles: [["feeds", "Feeds", T.feeds.el], ["eclats", "Éclats", T.eclats.el], ["conseil", "Conseil", T.conseil.el], ["brief", "Brief", T.brief.el]],
    extras: [["sugg", "Nova te propose", sugg.el], ["absence", "Pendant ton absence", absence], ["pulse", "Pulse", pulse.el], ["budget", "Budget et consommation", budget.el]] });
  root.append(h("div", { class: "hq-wrap" }, hero,
    gridEl,
    stripEl,
    sugg.el,
    absence, pulse.el, budget.el, custom.el));

  /* ══ Données ══════════════════════════════════════════════════════ */
  const get = async (p, key, t) => { try { const j = await api.get(p, t); S[key] = j == null ? {} : j; } catch (e) { S[key] = undefined; } };   // undefined = source illisible
  const settings = () => (S.state && S.state.settings) || {};

  /* Horloge, phrase du moment */
  let userName = "Ahadi", weatherTx = "";
  const paintClock = () => {
    const d = new Date(), hr = d.getHours();
    greet.textContent = (hr >= 18 ? "Bonsoir " : "Bonjour ") + userName + ".";
    const city = String(settings().city || "").trim();
    whenTx.textContent = d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" }).replace(/^./, (c) => c.toUpperCase()) + " · " + hhmm(d) + (city ? " à " + city : "") + (weatherTx ? " · " + weatherTx : "");
    live.classList.toggle("off", S.apiOk === false);
    live.title = S.apiOk === false ? "Moteur injoignable" : "Moteur en ligne";
  };
  const moment = () => { const hr = new Date().getHours(); return hr < 12 ? "ce matin" : hr < 18 ? "cet après-midi" : "ce soir"; };

  /* ── Pool « À toi de décider » ── */
  function decisionPool() {
    const now = new Date(), t0 = dayStart(now), wk = new Date(t0.getTime() + 7 * 86400000);
    const items = [];
    const cOk = S.commit !== undefined && has(S.commit, "items");
    let late = 0, week = 0;
    if (cOk) for (const c of arr(S.commit, "items")) {
      if ((c.status || "ouvert") !== "ouvert") continue;
      const d = ymd(c.echeance); if (!d || d > wk) continue;
      if (d < t0) late++; else week++;
      items.push({ kind: "c", due: d.getTime(), d, c });
    }
    const wOk = S.waiting !== undefined && has(S.waiting, "items");
    let go = 0, nWait = 0;
    if (wOk) for (const w of arr(S.waiting, "items")) {
      nWait++; const isGo = w.decision === true; if (isGo) go++;
      const ts = toDate(w.ts);
      items.push({ kind: isGo ? "go" : "w", due: isGo ? now.getTime() : (ts ? ts.getTime() : now.getTime()), w, ts });
    }
    const fOk = S.fund !== undefined && S.fund && Array.isArray(S.fund.echeances);
    let nFund = 0;
    if (fOk) for (const e of S.fund.echeances) {
      const n = Number(e.days_left); const d = ymd(e.date);
      if (!d || !Number.isFinite(n) || n < 0 || n >= 30) continue;
      nFund++; items.push({ kind: "f", due: d.getTime() + (parseHour(e.heure) || 0) * 3600000, d, e });
    }
    items.sort((a, b) => a.due - b.due);
    return { items, late, week, cOk, go, nWait, wOk, nFund, fOk };
  }
  const pickFive = (items) => {
    const cap = { c: 2, go: 1, f: 1, w: 0 }, used = {}, out = [], rest = [];   // 1er passage : une ligne de chaque source, puis l'échéance décide
    for (const it of items) { if ((used[it.kind] || 0) < cap[it.kind] && out.length < 5) { out.push(it); used[it.kind] = (used[it.kind] || 0) + 1; } else rest.push(it); }
    for (const it of rest) { if (out.length >= 5) break; out.push(it); }
    return out.sort((a, b) => a.due - b.due);
  };
  const dueTag = (d) => { const n = daysFrom(d); return n < 0 ? ["late", "En retard"] : n === 0 ? ["late", "Aujourd'hui"] : n === 1 ? ["due", "Demain"] : ["due", "J-" + n]; };
  function decRow(it) {
    let t = "", meta = "", tag = ["due", ""], btn = "Ouvrir", pri = false, go = "engagements";
    if (it.kind === "c") {
      const c = it.c; t = String(c.quoi || "Engagement"); tag = dueTag(it.d);
      const n = daysFrom(it.d);
      const qui = String(c.qui || "").trim();   /* 29/10 : son propre nom (« Dahani, Ahadi Jean Cyrille ») n'apprend rien et coupait la date */
      meta = [/ahadi|dahani/i.test(qui) ? "" : qui, n < 0 ? "depuis le " + shortDate(it.d) : n > 1 ? "pour le " + shortDate(it.d) : ""].filter(Boolean).join(", ");
      pri = n <= 0; btn = n <= 0 ? "Traiter" : "Ouvrir";
    } else if (it.kind === "go") {
      const w = it.w; t = String(w.question || "").trim() || String(w.name || "Un Éclat") + " attend ta décision";
      meta = String(w.name || "Éclat") + (it.ts ? " · " + relTime(it.ts) : ""); tag = ["go", "GO"]; btn = "Examiner"; pri = true; go = "dots";
    } else if (it.kind === "w") {
      const w = it.w; t = String(w.name || "Un Éclat") + " a terminé";
      meta = String(w.summary || "").replace(/\s+/g, " ").slice(0, 90); tag = ["due", "À relire"]; btn = "Voir"; go = "dots";
    } else {
      const e = it.e; t = String(e.label || "Échéance Fundings"); tag = dueTag(it.d);
      meta = [String(e.programme || "").trim(), shortDate(it.d) + (e.heure ? " " + e.heure : "")].filter(Boolean).join(" · "); go = "veille";
    }
    t = t.trim(); if (t) t = t.charAt(0).toLocaleUpperCase("fr") + t.slice(1);   // 29/10 : titres en phrase (« livrer la section… » → « Livrer… »)
    /* 30/10 : l'état (En retard, GO, J-2…) a sa propre colonne à gauche — le bord gauche se lit d'un coup d'œil. */
    return h("div", { class: "hq-dec-row", "data-kind": tag[0] },
      h("span", { class: "hq-tag " + tag[0] }, tag[1]),
      h("div", { class: "hq-dec-t" }, h("h3", { title: t }, t), meta ? h("p", {}, meta) : null),
      h("button", { class: "hq-btn" + (pri ? " pri" : ""), onclick: () => ctx.navigate(go), "aria-label": btn + " : " + t }, btn));
  }

  function paintDecisions() {
    const P = decisionPool();
    /* KPI 1 · engagements dus (en retard | cette semaine) */
    if (P.cOk) setKpi(K.dus, P.late + P.week, [{ c: "late", n: P.late }, { c: "week", n: P.week }], P.late + " en retard · " + P.week + " cette semaine", P.late > 0);
    else setKpi(K.dus, null, [], "Engagements illisibles");
    /* KPI 3 · décisions en attente (Éclats en attente + échéances Fundings < 30 j) | GO */
    const decOk = P.wOk || P.fOk;
    const nDec = (P.wOk ? P.nWait : 0) + (P.fOk ? P.nFund : 0);
    if (decOk) setKpi(K.dec, nDec, [{ c: "go", n: P.go }, { c: "rest", n: nDec - P.go }], P.go ? P.go + (P.go > 1 ? " attendent" : " attend") + " ton GO" : nDec ? "Aucune n'attend ton GO" : "Rien en attente", false);
    else setKpi(K.dec, null, [], "Éclats et Fundings illisibles");
    /* Phrase : N = en retard + dû aujourd'hui + GO */
    const today = P.items.filter((it) => (it.kind === "c" || it.kind === "f") && daysFrom(it.d) === 0).length;
    const N = (P.cOk || P.wOk || P.fOk) ? P.late + today + P.go : null;
    /* 29/10 : la phrase NOMME ce qui compte (avant : « 27 choses comptent », un total qui ne correspondait à aucun compteur) */
    const nb = (n) => String(n);
    const cap1 = (x) => x.charAt(0).toUpperCase() + x.slice(1);
    const parts = [];
    if (P.late) parts.push(nb(P.late) + " en retard");
    if (today) parts.push(nb(today) + " pour aujourd'hui");
    if (P.go) parts.push(nb(P.go) + (P.go > 1 ? " attendent" : " attend") + " ton GO");
    lead.textContent = N == null ? "Tes sources ne répondent pas encore." : !parts.length ? "Rien d'urgent " + moment() + "." : cap1(parts.slice(0, 2).join(", ")) + ".";
    lead.title = parts.join(" · ");
    /* Carte */
    const shownItems = pickFive(P.items);
    const total = P.items.length;
    C.dec.sub.textContent = !(P.cOk || P.wOk || P.fOk) ? "Sources indisponibles" : total ? shownItems.length + " sur " + total + ", triées par échéance" : "Rien n'attend ta décision";
    C.dec.body.replaceChildren(...(shownItems.length ? shownItems.map(decRow)
      : [h("div", { class: "hq-empty" + (!(P.cOk || P.wOk || P.fOk) ? " off" : "") }, h("span", { html: ic(!(P.cOk || P.wOk || P.fOk) ? "alert" : "check", 16) }), !(P.cOk || P.wOk || P.fOk) ? "Engagements, Éclats et Fundings sont injoignables pour le moment." : "Aucun engagement dû, aucun Éclat en attente, aucune échéance Fundings sous 30 jours.")]));
  }

  /* ── Courrier ── */
  const BOX = { Outlook: "ol", Teams: "tm", Gmail: "gm", Zoho: "zm" };   // V5-S : 4e boîte, Zoho campagne (lecture directe IMAP)
  const AUTO_SENDER = /no-?reply|ne-?pas-?repondre|donotreply|do-not-reply|notification|alert|mailer-daemon|newsletter|info@|news@|bounce/i;
  const ORG_WORDS = /\b(news|analysis|group|groupe|inc|ltd|llc|sarl|gmbh|bank|banque|university|universit[ée]|council|network|journal|magazine|times|daily|report|press|media|association|club|programs?|programme|fund|capital|partners|consulting|services?|support|store|shop|academy|school|institute|initiative|foundation|team|hq|official|platform|app)\b/i;
  const looksPerson = (w) => { const x = String(w || "").trim(); if (!x || /[@&|:/]/.test(x) || ORG_WORDS.test(x)) return false; const t = x.replace(/[,;]/g, " ").split(/\s+/).filter(Boolean); return t.length >= 2 && t.length <= 8 && t.some((k) => /^[A-ZÀ-Ý][a-zà-ÿ'’-]+$/.test(k)); };
  const bulkAddr = (txt) => { const m = String(txt || "").match(/<([^<>\s@]+)@([^<>\s]+)>/) || String(txt || "").match(/\bDe\s*:\s*([^<>\s@]+)@(\S+)/); if (!m) return false; const loc = m[1].toLowerCase(), dom = m[2].toLowerCase();
    return /(^|[._+-])(no-?reply|noreply|notifications?|notif|alerts?|news|info|hello|hi|team|support|verify|verification|marketing|promo|offers?|updates?|communications?|contact|mail(er|ing)?|e-?mail|digest|events?|community|billing|account|service|feedback|survey|accounts?|security|invitations?|bonjour|bounce)([._+-]|\d|$)/.test(loc)
      || /^(e|em|email|mail|mailer|mg|news|newsletter|mkt|marketing|info|notify|notifications?|bounce|send|go|click)\d*\./.test(dom); };
  const BULK_SENDER = /\b(team|équipe|promotions?|marketing|podcast|digest|updates?|initiative|institute|foundation|webinars?|events?)\b|^(hello|contact|news|events?|info|team)@|^moi\b|\bvia (todoist|linkedin|calendly|zoom|notion|asana|slack|google)\b/i;
  const BULK_TEXT = /unsubscribe|se d[ée]sabonner|d[ée]sinscri|view (this )?(email )?in (your )?browser|afficher dans (le|votre) navigateur|\bpodcast\b|\bwebinar|\bnewsletter|\bepisode\b|\bpromo(tion)?s?\b|% (off|de r[ée]duction)|\bdigest\b|\bsurvey\b|\bsondage\b|share your view|weekly|hebdomadaire|monthly update/i;
  const AUTO_SUBJECT = /^(new )?notification|alerte? de (crédit|débit)|transaction notification|^cfa [\d.,]+ (reçu|débité)/i;
  function paintMail() {
    const c = S.counts;
    const boxes = c && Array.isArray(c.boxes) ? c.boxes : null;
    const val = (name) => { const b = boxes && boxes.find((x) => x.name === name); return b && b.unread != null && Number.isFinite(Number(b.unread)) ? Number(b.unread) : null; };
    const o = val("Outlook"), t = val("Teams"), g = val("Gmail"), z = val("Zoho");
    const tot = c && c.total != null && Number.isFinite(Number(c.total)) ? Number(c.total) : null;
    const dash = (n) => (n == null ? "—" : nfr(n));
    setKpi(K.mails, tot == null ? null : nfr(tot), [{ c: "ol", n: o || 0 }, { c: "tm", n: t || 0 }, { c: "gm", n: g || 0 }, { c: "zm", n: z || 0 }], boxes ? "Outlook " + dash(o) + " · Teams " + dash(t) + " · Gmail " + dash(g) + " · Zoho " + dash(z) : "Compteurs non relevés");
    const sum = (o || 0) + (t || 0) + (g || 0) + (z || 0);
    const split = h("div", { class: "hq-split", role: "img", "aria-label": "Non lus — Outlook " + dash(o) + ", Teams " + dash(t) + ", Gmail " + dash(g) + ", Zoho " + dash(z) },
      ...(sum ? [["ol", o], ["tm", t], ["gm", g], ["zm", z]].filter(([, n]) => n).map(([k, n]) => h("i", { class: "hq-seg-" + k, style: "flex:" + n })) : [h("i", { class: "hq-seg-none", style: "flex:1" })]));
    /* V5-S : un clic sur une entrée de la légende ouvre Messages sur cette boîte (Zoho : le volet mail.zoho.com). */
    const legendL = h("div", { class: "hq-splitl" }, ...[["Outlook", o], ["Teams", t], ["Gmail", g], ["Zoho", z]].map(([n, v]) => h("span", { title: (boxes && (boxes.find((x) => x.name === n) || {}).source) || "", role: "button", tabindex: "0", style: "cursor:pointer", onclick: () => openBox(BOX[n]), onkeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openBox(BOX[n]); } } }, h("em", { class: "hq-seg-" + BOX[n] }), n + " ", h("b", {}, dash(v)))));
    /* 3 messages les plus récents du fil proactif (mail.new / teams.new, expéditeur connu) ; repli : le Fil direct */
    let msgs = [];
    const feed = S.feed !== undefined ? arr(S.feed, "items") : [];
    for (const it of feed) {
      if (!/^(mail|teams)\.new$/.test(String(it.kind || ""))) continue;
      const who = String(it.who || "").trim(); if (!who || /lot résumé/i.test(String(it.title || ""))) continue;
      if (AUTO_SENDER.test(who) || /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(who) || AUTO_SUBJECT.test(String(it.title || ""))) continue;
      if (!it.urgent && !looksPerson(who)) continue;
      if (bulkAddr(String(it.text || ""))) continue;   /* 29/10 : adresse d'envoi de masse (verify@, team@, …-noreply@, sous-domaine mail./news./em.) */   /* 29/10 : signal POSITIF — une personne (ou un urgent) attend une réponse, pas une marque ni une liste */
      if (BULK_SENDER.test(who) || BULK_TEXT.test(String(it.title || "") + " " + String(it.text || "").slice(0, 1500))) continue;   /* 29/10 : lettres d'info, podcasts, promos — « attend une réponse de toi » doit dire vrai */   /* 26/10 : alertes bancaires, no-reply… n'attendent pas de réponse */
      if (msgs.some((m) => m.who.toLowerCase() === who.toLowerCase())) continue;   /* 29/10 : une ligne par personne (« Awa · message » ×2) */
      let sub = String(it.title || "").trim();
      if (!sub || /^(message|nouveau message|new message)$/i.test(sub) || sub.toLowerCase() === who.toLowerCase()) {
        /* titre générique (Teams) : la 1re ligne utile du texte, sinon le canal nommé */
        const line = String(it.text || "").split("\n").map((l) => l.replace(/^(De|Objet|Heure|Aperçu)\s*:\s*/i, "").trim()).find((l) => l && l.toLowerCase() !== who.toLowerCase() && !/^\d{1,2}[:h]\d{2}$/.test(l) && !/^(message|nouveau message)$/i.test(l));
        sub = line ? line.slice(0, 120) : (String(it.box || "") === "tm" ? "Message Teams" : "Nouveau message");
      }
      msgs.push({ who, sub, at: toDate(it.ts), box: String(it.box || "") });
      if (msgs.length >= 3) break;
    }
    if (!msgs.length) {
      try {
        for (const it of (ctx.direct ? ctx.direct.list() : []).filter((x) => x.kind === "mail").slice(0, 12)) {
          if (msgs.length >= 3) break;
          const parts = String(it.key || "").split("|"); const who = parts.length > 3 ? parts[1] : String(it.corps || "").split(" · ")[0];
          if (!looksPerson(who)) continue;
          if (AUTO_SENDER.test(who || "") || BULK_SENDER.test(who || "") || BULK_TEXT.test(String(it.titre || "") + " " + String(it.corps || ""))) continue;
          msgs.push({ who: who || "Messagerie", sub: String(it.titre || ""), at: toDate(it.at), box: String((it.action && it.action.box) || it.box || "") });
        }
      } catch (e) {}
    }
    const when = (d) => !d ? "" : sameDay(d, new Date()) ? hhmm(d) : daysFrom(d) === -1 ? "hier" : shortDate(d);
    /* Ouvre Messages SUR la bonne boîte (ol/gm/tm) : Messages restaure le dernier service mémorisé
       (nova2_msg_svc) — sans cela il rouvrait le dernier volet utilisé, par ex. le Navigateur sur Google. */
    function openBox(box) {   // déclaration hissée : la légende (plus haut) l'appelle aussi
      if (/^(ol|gm|tm|wa|zm)$/.test(box)) { try { localStorage.setItem("nova2_msg_svc", box); } catch (e) {} }
      ctx.navigate("messages");
      if (/^(ol|gm|tm|wa|zm)$/.test(box)) setTimeout(() => bus.emit("nova:open-box", { box }), 120);
    }
    const rows = msgs.map((m) => h("button", { class: "hq-msg", onclick: () => openBox(m.box), "aria-label": "Message de " + m.who + " : " + m.sub },
      h("span", { class: "hq-av", style: "background:" + avColor(m.who), "aria-hidden": "true" }, initials(m.who)),
      h("span", { class: "hq-msg-t" }, h("h3", {}, m.who), h("p", {}, m.sub)),
      h("time", { datetime: m.at ? m.at.toISOString() : "" }, when(m.at))));
    C.mail.body.replaceChildren(split, legendL, ...(rows.length ? rows : [h("div", { class: "hq-empty" + (S.feed === undefined ? " off" : "") }, h("span", { html: ic(S.feed === undefined ? "alert" : "check", 16) }), S.feed === undefined ? "Fil des messages injoignable pour le moment." : "Personne n'attend de réponse dans les derniers arrivés — le reste, ce sont des lettres d'info et des notifications.")]));
  }

  /* ── Marchés BRVM ── */
  let pf = null, pfLocked = false, pfErr = false;
  const spark = (vals, up) => {
    const W = 300, H = 92, mn = Math.min(...vals), mx = Math.max(...vals), sp = mx - mn || 1;
    const pts = vals.map((v, i) => [i * W / (vals.length - 1), H - 6 - (v - mn) / sp * (H - 14)]);
    const d = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
    const id = "hqg" + Math.random().toString(36).slice(2, 7);
    const el = h("div", { class: "hq-spark " + (up ? "up" : "dn") });
    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Valeur du portefeuille, ${vals.length} relevés quotidiens"><defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" class="hq-stop" stop-opacity=".28"/><stop offset="1" class="hq-stop" stop-opacity="0"/></linearGradient></defs><path d="${d} L${W} ${H} L0 ${H} Z" fill="url(#${id})"/><path d="${d}" fill="none" class="hq-spark-l" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>`;
    return el;
  };
  const varBars = (rows) => {
    const mx = Math.max(0.5, ...rows.map((r) => Math.abs(r.v)));
    return h("div", { class: "hq-vbars", role: "img", "aria-label": "Variations du jour : " + rows.map((r) => r.n + " " + pct1(r.v)).join(", ") },
      ...rows.map((r) => h("span", { class: "hq-vb" + (r.v >= 0 ? " up" : " dn"), title: r.n + " " + pct1(r.v) },
        h("i", { style: "height:" + Math.max(3, Math.abs(r.v) / mx * 50).toFixed(1) + "%" }), h("em", {}, r.s))));
  };
  const mkRow = (r, mx) => h("div", { class: "hq-mk-row" }, h("span", { class: "hq-mk-n", title: r.n }, r.n),
    h("span", { class: "hq-mk-bar" + (r.v >= 0 ? " up" : " dn"), "aria-hidden": "true" }, h("i", { style: "width:" + Math.max(4, Math.abs(r.v) / mx * 50).toFixed(1) + "%" })),
    h("b", { class: r.v >= 0 ? "up" : "dn" }, pct1(r.v)));
  function paintMarkets(brvm) {
    const big = (v, label) => h("div", { class: "hq-big" }, h("b", { class: v >= 0 ? "up" : "dn" }, pct(v)), h("span", {}, label));
    const dated = (at) => { const d = toDate(at); if (!d) return "Cours non datés"; return sameDay(d, new Date()) ? "Cours de " + hhmm(d) : "Clôture du " + shortDate(d); };
    /* (a) Coffre ouvert : portefeuille réel */
    if (pf) {
      const quotes = pf.quotes || {}; let total = 0, prev = 0, n = 0; const rows = [];
      for (const acc of Object.values(pf.accounts || {})) {
        total += Number(acc.cash) || 0; prev += Number(acc.cash) || 0;
        for (const p of acc.positions || []) {
          const q = quotes[p.sym] || null; const price = q ? Number(q.price) : Number(p.cours_releve) || Number(p.cmp) || 0;
          const v = (Number(p.qty) || 0) * price; const vr = q ? Number(q.var) || 0 : 0;
          total += v; prev += v / (1 + vr / 100); n++;
          if (q) rows.push({ s: String(p.sym || ""), n: String(p.name || q.name || p.sym || ""), v: vr });
        }
      }
      if (n) {
        const dayVar = prev ? (total / prev - 1) * 100 : 0;
        let hist = []; try { hist = JSON.parse(localStorage.getItem("nova2_pf_hist") || "[]"); } catch (e) {}
        if (!Array.isArray(hist)) hist = [];
        const today = isoDay(new Date());
        hist = hist.filter((x) => x && x.d !== today && Number.isFinite(Number(x.v))).concat([{ d: today, v: Math.round(total) }]).slice(-30);
        try { localStorage.setItem("nova2_pf_hist", JSON.stringify(hist)); } catch (e) {}
        rows.sort((a, b) => Math.abs(b.v) - Math.abs(a.v));
        const mx = Math.max(0.5, ...rows.map((r) => Math.abs(r.v)));
        C.mk.sub.textContent = dated(pf.quotes_at);
        C.mk.body.replaceChildren(big(dayVar, "mon portefeuille, " + nfr(total) + " FCFA"),
          hist.length >= 2 ? spark(hist.map((x) => Number(x.v)), hist[hist.length - 1].v >= hist[0].v) : rows.length ? varBars(rows.slice(0, 8)) : h("div", { class: "hq-empty" }, "Aucun cours relevé pour tes lignes."),
          h("p", { class: "hq-mk-note" }, hist.length >= 2 ? "Valeur relevée chaque jour par Nova (" + hist.length + " jours) · brvm.org" : "Variations du jour de tes lignes · la courbe viendra après deux jours de relevés"),
          ...rows.slice(0, 2).map((r) => mkRow(r, mx)));
        return;
      }
    }
    /* (b) Coffre fermé ou vide : moyenne des valeurs suivies (même règle que l'ancienne jauge) */
    const all = brvm && Array.isArray(brvm.quotes) ? brvm.quotes.filter((q) => Number.isFinite(Number(q.var))) : [];
    const watch = (brvm && Array.isArray(brvm.watch) && brvm.watch) || [];
    const mine = watch.length ? all.filter((q) => watch.includes(q.sym)) : [];
    const use = mine.length ? mine : all;
    if (!use.length) {
      C.mk.sub.textContent = brvm === undefined ? "Cours injoignables" : "Aucun cours relevé";
      C.mk.body.replaceChildren(h("div", { class: "hq-empty off" }, h("span", { html: ic(pfLocked ? "lock-closed" : "alert", 16) }), pfLocked ? "Coffre verrouillé et cours BRVM indisponibles pour le moment." : "Cours BRVM indisponibles pour le moment."));
      return;
    }
    const avg = use.reduce((t, q) => t + Number(q.var), 0) / use.length;
    const rows = use.map((q) => ({ s: String(q.sym || ""), n: String(q.name || q.sym || ""), v: Number(q.var) })).sort((a, b) => Math.abs(b.v) - Math.abs(a.v));
    const mx = Math.max(0.5, ...rows.map((r) => Math.abs(r.v)));
    C.mk.sub.textContent = dated(brvm.quotes_at);
    C.mk.body.replaceChildren(big(avg, (mine.length ? "mes " + use.length + " valeurs suivies" : "moyenne de la cote") + ", sur la séance"),
      varBars(rows.slice(0, 8)),
      h("p", { class: "hq-mk-note" }, (pfLocked ? "Coffre verrouillé : " : pfErr ? "Portefeuille indisponible : " : "") + "variations du jour · brvm.org"),
      ...rows.slice(0, 2).map((r) => mkRow(r, mx)));
  }
  async function loadMarkets() {
    let d = null; pfLocked = false; pfErr = false;
    try { d = await api.get("/api/portfolio"); } catch (e) { const m = String((e && e.message) || ""); pfLocked = /423/.test(m); pfErr = !pfLocked; }
    pf = d && typeof d === "object" && d.accounts ? d : null;
    let b; try { b = await api.get("/api/veille/brvm"); } catch (e) { b = undefined; }
    if (!dead) paintMarkets(b);
  }

  /* ── L'anneau du jour ── */
  const NS = 'xmlns="http://www.w3.org/2000/svg"';
  const SZ = 340, CX = 170, R = 126;
  const pt = (hh, r) => { const a = (hh / 24) * 2 * Math.PI - Math.PI / 2; return [CX + r * Math.cos(a), CX + r * Math.sin(a)]; };
  const arcD = (h1, h2, r) => { const [x1, y1] = pt(h1, r), [x2, y2] = pt(h2, r); const span = ((h2 - h1) % 24 + 24) % 24; return `M${x1.toFixed(2)} ${y1.toFixed(2)} A${r} ${r} 0 ${span > 12 ? 1 : 0} 1 ${x2.toFixed(2)} ${y2.toFixed(2)}`; };
  const escX = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  function dayModel() {
    const now = new Date(), nowH = now.getHours() + now.getMinutes() / 60;
    const st = settings();
    const q = S.silence && S.silence.quiet ? S.silence.quiet : null;
    const qf = parseHour(q ? q.from : st.quiet_from), qt = parseHour(q ? q.to : st.quiet_to);
    const quiet = qf != null && qt != null && qf !== qt ? { a: qf, b: qt } : null;
    const evs = [];
    const seen = new Set();
    for (const e of arr(S.today, "items")) {
      const d = toDate(Number(e.ts) || e.start); if (!d || !sameDay(d, now)) continue;
      const allDay = d.getHours() === 0 && d.getMinutes() === 0; if (allDay) continue;
      const k = d.getTime() + "|" + (e.title || ""); if (seen.has(k)) continue; seen.add(k);
      const end = toDate(e.end_ts || e.end); const a = d.getHours() + d.getMinutes() / 60;
      let b = end && end > d && sameDay(end, now) ? end.getHours() + end.getMinutes() / 60 : Math.min(24, a + 1);
      if (b - a < 0.25) b = a + 0.25;
      evs.push({ a, b, d, t: String(e.title || e.label || "Rendez-vous"), guess: !end });
    }
    evs.sort((x, y) => x.a - y.a);
    let deep = null;
    for (const s of arr(S.chrono, "slots")) { const a = toDate(s.start), b = toDate(s.end); if (a && b && sameDay(a, now) && b > a) { deep = { a: a.getHours() + a.getMinutes() / 60, b: sameDay(b, now) ? b.getHours() + b.getMinutes() / 60 : 24 }; break; } }
    const rits = [];
    for (const r of arr(S.rituels, "items", "rituels")) {
      if (r.actif !== true) continue;
      const hr = parseHour(r.heure); if (hr == null) continue;
      const nom = String(r.nom || r.id || "Rituel");
      const shortN = nom.replace(/\(.*$/, "").trim().split(/\s+/)[0] || nom;
      rits.push({ h: hr, nom, s: shortN });
    }
    rits.sort((x, y) => x.h - y.h);
    return { now, nowH, quiet, evs, deep, rits };
  }
  function paintRing() {
    const M = dayModel();
    const o = [];
    o.push(`<circle cx="${CX}" cy="${CX}" r="${R}" class="hq-r-track" stroke-width="14" fill="none"/>`);
    if (M.quiet) o.push(`<path d="${arcD(M.quiet.a, M.quiet.b, R)}" class="hq-r-quiet" stroke-width="14" fill="none"/>`);
    if (M.deep) o.push(`<path d="${arcD(M.deep.a, M.deep.b, R)}" class="hq-r-deep" stroke-width="14" fill="none" stroke-linecap="round"><title>Travail profond proposé ${fmtH(M.deep.a)}–${fmtH(M.deep.b)}</title></path>`);
    for (const e of M.evs) o.push(`<path d="${arcD(e.a, e.b, R)}" class="hq-r-rdv" stroke-width="14" fill="none" stroke-linecap="round"><title>${escX(fmtH(e.a) + " · " + e.t + (e.guess ? " (durée non fournie : 1 h affichée)" : ""))}</title></path>`);
    for (let hh = 0; hh < 24; hh++) {
      const [x1, y1] = pt(hh, R - 14), [x2, y2] = pt(hh, R - (hh % 6 ? 18 : 24));
      o.push(`<line x1="${x1.toFixed(1)}" y1="${y1.toFixed(1)}" x2="${x2.toFixed(1)}" y2="${y2.toFixed(1)}" class="hq-r-tick${hh % 6 ? "" : " maj"}"/>`);
      if (hh % 6 === 0) { const [tx, ty] = pt(hh, R - 34); o.push(`<text x="${tx.toFixed(1)}" y="${(ty + 4).toFixed(1)}" text-anchor="middle" class="hq-r-hr">${String(hh).padStart(2, "0")}</text>`); }
    }
    let lastLab = -9;
    for (const r of M.rits) {
      const [x, y] = pt(r.h, R);
      o.push(`<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="4.2" class="hq-r-rit"><title>${escX(fmtH(r.h) + " · " + r.nom)}</title></circle>`);
      if (r.h - lastLab < 1.2) continue;   // deux rituels proches : un seul libellé, l'infobulle garde les deux
      lastLab = r.h;
      const [lx, ly] = pt(r.h, R + 14); const sx = Math.sin((r.h / 24) * 2 * Math.PI);
      o.push(`<text x="${(lx + (sx > 0.3 ? 4 : sx < -0.3 ? -4 : 0)).toFixed(1)}" y="${(ly + (Math.abs(sx) <= 0.3 ? (Math.cos((r.h / 24) * 2 * Math.PI) > 0 ? -6 : 12) : 4)).toFixed(1)}" text-anchor="${sx > 0.3 ? "start" : sx < -0.3 ? "end" : "middle"}" class="hq-r-lab">${escX(r.s)}</text>`);
    }
    const [nx, ny] = pt(M.nowH, R + 8), [ix, iy] = pt(M.nowH, R - 26), [kx, ky] = pt(M.nowH, R);
    o.push(`<line x1="${ix.toFixed(1)}" y1="${iy.toFixed(1)}" x2="${nx.toFixed(1)}" y2="${ny.toFixed(1)}" class="hq-r-needle" stroke-width="3" stroke-linecap="round"/>`);
    o.push(`<circle cx="${kx.toFixed(1)}" cy="${ky.toFixed(1)}" r="6" class="hq-r-knob" stroke-width="2.5"/>`);
    const desc = ["Ta journée sur 24 heures, il est " + hhmm(M.now)];
    desc.push(M.quiet ? "heures calmes de " + fmtH(M.quiet.a) + " à " + fmtH(M.quiet.b) : "heures calmes non lues");
    desc.push(M.evs.length ? M.evs.length + " rendez-vous : " + M.evs.map((e) => fmtH(e.a) + " " + e.t).join(", ") : S.today === undefined ? "agenda illisible" : "aucun rendez-vous");
    if (M.deep) desc.push("travail profond proposé de " + fmtH(M.deep.a) + " à " + fmtH(M.deep.b));
    if (M.rits.length) desc.push("rituels : " + M.rits.map((r) => fmtH(r.h) + " " + r.nom).join(", "));
    dial.innerHTML = `<svg ${NS} viewBox="0 0 ${SZ} ${SZ}" role="img" aria-label="${escX(desc.join(" ; ") + ".")}">${o.join("")}</svg>`;
    /* légende sous l'anneau : prochain rendez-vous du jour */
    const nowMs = Date.now();
    const cur = M.evs.find((e) => e.d.getTime() <= nowMs && nowMs < e.d.getTime() + (e.b - e.a) * 3600000);
    const nx2 = M.evs.find((e) => e.d.getTime() > nowMs);
    if (S.today === undefined) { capS.textContent = "Agenda"; capB.textContent = "Agenda injoignable pour le moment"; }
    else if (cur) { capS.textContent = "En cours · depuis " + Math.max(1, Math.round((nowMs - cur.d.getTime()) / 60000)) + " min"; capB.textContent = cur.t + ", " + hhmm(cur.d); }
    else if (nx2) {
      const m = Math.round((nx2.d.getTime() - nowMs) / 60000);
      capS.textContent = "Prochain · dans " + (m >= 60 ? Math.floor(m / 60) + " h " + String(m % 60).padStart(2, "0") : m + " min");
      capB.textContent = nx2.t + ", " + hhmm(nx2.d);
    } else { capS.textContent = M.evs.length ? "Journée d'agenda terminée" : "Agenda"; capB.textContent = M.evs.length ? "Aucun autre rendez-vous aujourd'hui" : "Aucun rendez-vous aujourd'hui"; }
  }

  /* ── Bandeau ── */
  function paintStrip() {
    /* Feeds */
    if (S.feeds === undefined) setTile(T.feeds, "Feeds", "Veille injoignable pour le moment");
    else {
      const units = arr(S.feeds, "units"); const unread = Number(S.feeds && S.feeds.unread && S.feeds.unread.tout) || 0;
      const fresh = units.filter((u) => u.read !== true);
      const titles = (fresh.length ? fresh : units).slice(0, 3).map((u) => String(u.title || "").replace(/\s+/g, " ").trim()).filter(Boolean);
      setTile(T.feeds, unread ? (unread > 1 ? unread + " signaux à lire" : "1 signal à lire") : units.length ? "Veille à jour" : "Feeds",
        titles.length ? titles.map((t) => t.length > 38 ? t.slice(0, 37) + "…" : t).join(" · ") : "Aucun signal pour l'instant");
    }
    /* Éclats */
    if (S.dots === undefined) setTile(T.eclats, "Éclats", "Parc injoignable pour le moment");
    else {
      const all = arr(S.dots, "items"), runs = arr(S.dots, "runs");
      const act = all.filter((x) => x.paused !== true && x.enabled !== false).length;
      const since = Date.now() - 24 * 3600000;
      /* 26/10 : un échec rattrapé par un passage réussi du même Éclat n'est plus compté (échecs OUVERTS seulement). */
      const lastOk = {};
      for (const r of runs) { const d = toDate(r.ts); if (!d || r.ok !== true) continue; const k = String(r.dot || ""); if (!lastOk[k] || lastOk[k] < d.getTime()) lastOk[k] = d.getTime(); }
      const fails = runs.filter((r) => { const d = toDate(r.ts); return d && d.getTime() > since && r.ok === false && r.statut !== "en_cours" && !r.arrete && !(lastOk[String(r.dot || "")] > d.getTime()); });
      setTile(T.eclats, act + (act > 1 ? " Éclats actifs" : " Éclat actif") + (all.length !== act ? " sur " + all.length : ""),
        fails.length ? fails.length + (fails.length > 1 ? " échecs ouverts" : " échec ouvert") + " sur 24 h" : "Aucun échec ouvert sur 24 h");
      T.eclats.el.classList.toggle("warn", fails.length > 0);
    }
    /* Conseil */
    if (S.council === undefined) setTile(T.conseil, "Conseil", "Historique injoignable pour le moment");
    else {
      const it = arr(S.council, "items").slice().sort((a, b) => String(b.updated || b.created || "").localeCompare(String(a.updated || a.created || "")))[0];
      setTile(T.conseil, "Conseil", it ? "Dernière séance : " + String(it.title || "délibération") + (toDate(it.updated || it.created) ? " · " + relTime(toDate(it.updated || it.created)) : "") : "Aucune séance archivée");
    }
    /* Brief : le prochain brief actif du jour, sinon le dernier publié */
    const now = new Date(), nowH = now.getHours() + now.getMinutes() / 60;
    const nextB = arr(S.rituels, "items", "rituels").filter((r) => r.type === "brief" && r.actif === true).map((r) => ({ r, hh: parseHour(r.heure) })).filter((x) => x.hh != null && x.hh > nowH).sort((a, b) => a.hh - b.hh)[0];
    const lastB = arr(S.briefs, "items", "briefs")[0];
    const lastD = lastB ? toDate(lastB.ts) : null;
    if (nextB) setTile(T.brief, String(nextB.r.nom || "Brief") + " à " + fmtH(nextB.hh), lastB ? "Dernier : " + String(lastB.title || "brief") + (lastD ? " · " + relTime(lastD) : "") : "Préparé à l'heure, il t'attendra ici");
    else if (lastB) setTile(T.brief, String(lastB.title || "Brief") + (lastD && sameDay(lastD, now) ? " prêt" : ""), lastD ? "Publié " + relTime(lastD) : "");
    else if (S.rituels === undefined && S.briefs === undefined) setTile(T.brief, null);
    else setTile(T.brief, "Brief", "Aucun brief programmé ni publié");
  }

  async function loadWeather() {
    const st = settings(); const lat = Number(st.lat), lon = Number(st.lon);
    if (!(isFinite(lat) && isFinite(lon) && lat && lon)) return;
    lastWeather = Date.now();
    try {
      const r = await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,weather_code`);
      const w = await r.json(); const t = w && w.current && w.current.temperature_2m; const c = w && w.current && Number(w.current.weather_code);
      if (t != null && !dead) { weatherTx = Math.round(t) + " °C" + (Number.isFinite(c) ? ", " + WMO(c) : ""); paintClock(); }
    } catch (e) {}
  }
  async function loadAbsence() {
    if (!lastSeen || Date.now() - lastSeen < 30 * 60000) { absence.hidden = true; return; }
    const since = lastSeen; const lines = [];
    const runs = arr(S.dots, "runs").filter((r) => { const d = toDate(r.ts); return d && d.getTime() > since; });
    const ok = runs.filter((r) => r.ok !== false && !/err|fail|éch/i.test(String(r.status || ""))).length;
    if (runs.length) lines.push({ go: "dots", t: runs.length + " exécution" + (runs.length > 1 ? "s" : "") + " d'Éclats", s: ok + " réussie" + (ok > 1 ? "s" : "") + (runs.length - ok ? " · " + (runs.length - ok) + " à revoir" : "") });
    try {
      const it = (ctx.direct ? ctx.direct.list() : []).filter((x) => (x.at || 0) > since);
      if (it.length) lines.push({ go: "conversations", t: it.length + " arrivée" + (it.length > 1 ? "s" : "") + " dans le fil", s: it.slice(0, 2).map((x) => x.titre).join(" · ") });
    } catch (e) {}
    if (dead) return;
    if (!lines.length) { absence.hidden = true; return; }
    const ago = Math.round((Date.now() - since) / 3600000);
    absence.hidden = false;
    absence.replaceChildren(h("header", {}, h("span", { html: ic("time", 16) }), h("h2", {}, "Pendant ton absence" + (ago >= 1 ? " · " + ago + " h" : "")),
      h("button", { class: "btn ghost sm", onclick: () => { absence.hidden = true; markSeen(); } }, "Vu")),
      ...lines.map((l) => h("button", { class: "hq-abs-row", onclick: () => ctx.navigate(l.go) }, h("b", {}, l.t), h("span", {}, l.s))));
  }

  /* Rapide (60 s) : engagements, Éclats en attente, compteurs, fil, agenda, portefeuille.
     Lent (5 min) : réglages, silence, chrono, rituels, Fundings, Feeds, Conseil, briefs, parc d'Éclats. */
  async function refresh(full) {
    const slow = full || Date.now() - lastSlow > 5 * 60000;
    const jobs = [get("/api/commitments", "commit"), get("/api/dots/waiting", "waiting"), get("/api/mail/counts", "counts"), get("/api/proactive/feed?limit=40", "feed"), get("/api/today", "today"), loadMarkets()];
    if (slow) {
      lastSlow = Date.now();
      jobs.push(get("/api/state", "state").then(() => { S.apiOk = S.state !== undefined; const nm = String(settings().user_name || settings().user_first || "").trim(); if (nm) userName = nm.split(" ")[0]; if (!weatherTx && Date.now() - lastWeather > 30 * 60000) loadWeather(); }),
        get("/api/silence", "silence"), get("/api/chrono", "chrono"), get("/api/rituels", "rituels"), get("/api/fundings", "fund"),
        get("/api/feeds/overview", "feeds", 20000), get("/api/council/history", "council"), get("/api/briefs", "briefs"), get("/api/dots", "dots"));
    }
    await Promise.all(jobs);
    if (dead) return;
    paintClock(); paintDecisions(); paintMail(); paintRing(); paintStrip();
    if (slow) { pulse.load(); budget.load(); sugg.load(); }
  }
  /* Minuterie unique, alignée sur la minute ; rien ne tourne quand l'Accueil ou la fenêtre est caché. */
  const tick = () => {
    tickT = 0; if (dead || !shown) return;
    if (!document.hidden) { paintClock(); refresh(false); }
    tickT = setTimeout(tick, 60000 - (Date.now() % 60000) + 50);
  };
  const startTick = () => { if (!tickT && shown && !dead) tickT = setTimeout(tick, 60000 - (Date.now() % 60000) + 50); };
  const stopTick = () => { if (tickT) { clearTimeout(tickT); tickT = 0; } };
  const onVis = () => { if (!document.hidden && shown && !dead) { paintClock(); paintRing(); } };
  document.addEventListener("visibilitychange", onVis);

  paintClock(); paintRing();
  setKpi(K.dus, null, [], "…"); setKpi(K.mails, null, [], "…"); setKpi(K.dec, null, [], "…");
  refresh(true).then(() => loadAbsence());
  startTick();
  setTimeout(markSeen, 4000);
  const offs = [bus.on("nova:direct-state", () => { if (shown) paintMail(); }), bus.on("nova:dot-run", () => { if (shown) refresh(false); }), bus.on("nova:brief-new", () => { if (shown) { lastSlow = 0; refresh(false); } }), bus.on("suggestion.new", () => { if (shown) sugg.load(); })];
  return {
    onHide: () => { shown = false; stopTick(); },
    onShow: () => { shown = true; refresh(false).then(() => loadAbsence()); startTick(); setTimeout(markSeen, 4000); },
    destroy: () => { dead = true; shown = false; stopTick(); document.removeEventListener("visibilitychange", onVis); pulse.stop(); offs.forEach((o) => { try { o(); } catch (e) {} }); try { anchor.destroyAvatar(); } catch (e) {} },
  };
}

/* ══ V5-U · « NOVA TE PROPOSE » ═══════════════════════════════════════════════
   Une ligne compacte sous le bandeau : la DERNIÈRE suggestion (GET /api/suggestions → items[0] :
   kind, title, why, source) — un clic ouvre le Fil direct sur sa carte dépliée (clé
   nova2_pending_sugg lue par feedcard.js) ; « Propose-moi quelque chose » → POST
   /api/suggestions/now (asynchrone), puis relecture toutes les 6 s (3 min au plus) jusqu'au
   nouveau passage (last_run.ts). Rien n'est inventé : sans réponse du moteur, « — ». */
const SUGG_K = { lecture: "Lecture", a_voir: "À voir", opportunite: "Opportunité", a_faire: "À faire" };
function suggestTile(ctx, { isDead, directId }) {
  const { api, bus, h, ic } = ctx;
  const kEl = h("span", { class: "hq-sugg-k" }, "Nova te propose");
  const tEl = h("b", {}, "—");
  const wEl = h("p", {}, "");
  const main = h("button", { class: "hq-sugg-main", "aria-label": "Nova te propose" }, kEl, tEl, wEl);
  const go = h("button", { class: "hq-sugg-go", title: "Nova cherche maintenant une suggestion qui touche tes dossiers (lue et vérifiée avant d'être publiée)" });
  const goTx = h("span", {}, "Propose-moi quelque chose");
  go.append(h("span", { html: ic("sparkle", 14) }), goTx);
  const el = h("section", { class: "hq-sugg hq-glass", "aria-label": "Nova te propose" },
    h("span", { class: "hq-sugg-ic", "aria-hidden": "true", html: ic("sparkle", 20) }), main, go);
  let last = null, busy = false;
  const paint = (j) => {
    const items = j && Array.isArray(j.items) ? j.items : null;
    last = items && items.length ? items[0] : null;
    el.classList.toggle("off", !j);
    if (!j) { kEl.textContent = "Nova te propose"; tEl.textContent = "—"; wEl.textContent = "Suggestions injoignables pour le moment."; main.disabled = true; return; }
    if (!last) {
      kEl.textContent = "Nova te propose";
      tEl.textContent = j.on === false ? "Suggestions coupées" : "Rien pour l'instant";
      wEl.textContent = j.on === false ? "À rallumer dans Réglages › Assistant." : "Au plus " + (j.par_jour || 3) + " par jour (lecture 08:15, à voir 13:00, à préparer 18:30) — seulement ce qui touche tes dossiers.";
      main.disabled = true; return;
    }
    main.disabled = false;
    kEl.textContent = "Nova te propose · " + (SUGG_K[last.kind] || "Suggestion") + (last.source ? " · " + String(last.source) : "");
    tEl.textContent = String(last.title || "");
    wEl.textContent = last.why ? "Ça compte pour toi parce que " + String(last.why).replace(/^\s*(ç|c)a compte pour toi parce que\s*/i, "") : "";
    main.setAttribute("aria-label", "Nova te propose : " + String(last.title || "") + " — ouvrir au Fil direct");
  };
  async function load() {
    let j = null;
    try { j = await api.get("/api/suggestions"); } catch (e) { j = null; }
    if (isDead()) return null;
    if (!busy) paint(j);
    return j;
  }
  main.addEventListener("click", () => {
    if (!last) return;
    try { localStorage.setItem("nova2_pending_sugg", String(last.id || "")); } catch (e) {}
    const cid = directId();
    if (cid) { try { localStorage.setItem("nova2_pending_conv", cid); } catch (e) {} }
    ctx.navigate("conversations");
    if (cid) setTimeout(() => { try { bus.emit("nova:open-conv", { cid, id: cid }); } catch (e) {} }, 140);
  });
  go.addEventListener("click", async () => {
    if (busy) return;
    busy = true; go.disabled = true; goTx.textContent = "Nova cherche…";
    const t0 = Date.now();
    let started = null;
    try { started = await api.post("/api/suggestions/now", {}, 15000); } catch (e) { started = null; }
    if (!started || (started.status !== "en_cours")) {
      busy = false; go.disabled = false; goTx.textContent = "Propose-moi quelque chose";
      ctx.toast("Nova n'a pas pu lancer la recherche" + (started && started.error ? " : " + started.error : " — moteur injoignable."), true); return;
    }
    let tries = 0;
    const poll = async () => {
      if (isDead()) return;
      let j = null; try { j = await api.get("/api/suggestions"); } catch (e) { j = null; }
      const lr = j && j.last_run;
      const ts = lr && lr.ts ? new Date(lr.ts).getTime() : 0;
      if (j && !j.running && ts >= t0 - 2000) {
        busy = false; go.disabled = false; goTx.textContent = "Propose-moi quelque chose"; paint(j);
        if (lr.status === "publiée") ctx.toast("Nouvelle suggestion au Fil direct : " + String(lr.title || ""));
        else ctx.toast("Rien de pertinent ni de vérifiable pour l'instant" + (lr.note ? " — " + String(lr.note).slice(0, 140) : "") + ".");
        return;
      }
      if (++tries > 30) { busy = false; go.disabled = false; goTx.textContent = "Propose-moi quelque chose"; ctx.toast("La recherche continue en arrière-plan : la suggestion arrivera au Fil direct."); return; }
      setTimeout(poll, 6000);
    };
    setTimeout(poll, 4000);
  });
  return { el, load };
}

/* ══ VAGUE 1 · PULSE DU MATIN ═══════════════════════════════════════════════
   Données : GET /api/pulse → { day, composed, brain, note, running, cards:[{ id, cat, titre,
   lignes[], source:{nom,date}, action:{type:"ouvrir"|"demander", module|texte, label}, signal,
   pinned, arrival, verif }], pinned:[…cartes épinglées des jours passés], vault_masked, wish,
   heure }. Rien n'est inventé ici : une carte absente = un état vide honnête. */
const PULSE_CAT = { mail: "Mail", agenda: "Agenda", reunion: "Réunion", engagement: "Engagement", dot: "Éclat", brvm: "BRVM", veille: "Veille", budget: "Budget", charge: "Équilibre" };
const PULSE_IC = { mail: "mail", agenda: "calendar", reunion: "calendar", engagement: "check", dot: "agent", brvm: "chart", veille: "brief", budget: "cpu", charge: "moon" };
const pDate = (v) => { if (!v) return ""; const d = new Date(v); if (isNaN(d)) return String(v).slice(0, 16);
  const today = new Date(); const same = d.toDateString() === today.toDateString();
  const y = new Date(); y.setDate(today.getDate() - 1);
  const hm = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  if (same) return hm === "00:00" ? "aujourd'hui" : "aujourd'hui " + hm;
  if (d.toDateString() === y.toDateString()) return "hier " + hm;
  return d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }); };

function pulseSection(ctx, { ask, isDead }) {
  const { api, h, ic } = ctx;
  let pollT = 0, pollT0 = 0, lastSig = "";
  const meta = h("span", { class: "pl-meta" });
  const track = h("div", { class: "pl-track", role: "list" });
  const note = h("div", { class: "pl-note", hidden: "" });
  const prev = h("button", { class: "pl-nav", "aria-label": "Cartes précédentes", html: ic("chev-r", 16), onclick: () => track.scrollBy({ left: -track.clientWidth * 0.8, behavior: "smooth" }) });
  const next = h("button", { class: "pl-nav", "aria-label": "Cartes suivantes", html: ic("chev-r", 16), onclick: () => track.scrollBy({ left: track.clientWidth * 0.8, behavior: "smooth" }) });
  prev.classList.add("pl-prev");
  const recompose = h("button", { class: "btn ghost sm", title: "Recomposer le Pulse avec les sources du moment", onclick: () => compose() });
  recompose.innerHTML = ic("refresh", 14) + "<span>Recomposer</span>";
  const el = h("section", { class: "pl", "aria-label": "Pulse du matin" },
    h("header", { class: "pl-head" }, h("span", { class: "pl-ic", html: ic("pulse", 16) }), h("h2", {}, "Pulse"), meta, h("span", { class: "sp" }), recompose, prev, next),
    track, note);
  const navState = () => { const max = track.scrollWidth - track.clientWidth - 2; prev.disabled = track.scrollLeft <= 2; next.disabled = track.scrollLeft >= max; };
  track.addEventListener("scroll", navState, { passive: true });

  async function compose() {
    recompose.disabled = true;
    try { await api.post("/api/pulse/compose", {}); ctx.toast("Nova recompose ton Pulse…"); } catch (e) { ctx.toast("Composition impossible pour le moment.", true); recompose.disabled = false; return; }
    pollT0 = Date.now(); poll();
  }
  function poll() {
    clearTimeout(pollT);
    pollT = setTimeout(async () => { pollT = 0; if (isDead()) return; lastSig = ""; const j = await load(); if (j && j.running && Date.now() - pollT0 < 120000) poll(); else recompose.disabled = false; }, 4000);
  }

  function actionBtn(c) {
    const a = c.action || {};
    if (a.type === "demander" && a.texte) return h("button", { class: "btn sm pl-go", onclick: () => ask(String(a.texte)) }, h("span", { html: ic("sparkle", 13) }), h("span", { class: "pl-go-l" }, String(a.label || "Demander à Nova")));
    const mod = a.module || "";
    if (!mod) return null;
    const lb = String(a.label || "Ouvrir");
    return h("button", { class: "btn sm pl-go", title: lb, onclick: () => ctx.navigate(mod) }, h("span", { class: "pl-go-l" }, lb.replace(/^Voir l['’]engagement$/i, "Voir").replace(/^Voir les coûts$/i, "Coûts")));
  }
  function sigBtn(c, sig, glyph, label, row) {
    const b = h("button", { class: "pl-sig" + (c.signal === sig ? " on" : ""), "aria-pressed": c.signal === sig ? "true" : "false", title: label, "aria-label": label }, glyph);
    b.addEventListener("click", async () => {
      const nextSig = c.signal === sig ? "" : sig, before = c.signal || "";
      c.signal = nextSig;
      row.querySelectorAll(".pl-sig").forEach((x) => { const on = x === b && nextSig; x.classList.toggle("on", !!on); x.setAttribute("aria-pressed", on ? "true" : "false"); });
      try { await api.post("/api/pulse/feedback", { card: c.id, signal: nextSig }); if (nextSig) ctx.toast(nextSig === "more" ? "Noté : plus de ça demain." : nextSig === "less" ? "Noté : moins de ça demain." : "Merci, c'est noté pour demain."); }
      catch (e) { c.signal = before; ctx.toast("Retour non enregistré.", true); load(); }
    });
    return b;
  }
  function card(c, older) {
    const cat = String(c.cat || "");
    const src = c.source || {};
    const pin = h("button", { class: "pl-pin" + (c.pinned ? " on" : ""), title: c.pinned ? "Désépingler" : "Épingler (garder après aujourd'hui)", "aria-label": c.pinned ? "Désépingler" : "Épingler", html: ic("star", 14) });
    pin.addEventListener("click", async () => {
      pin.disabled = true;
      try { const r = await api.post("/api/pulse/pin", { card: c.id, pinned: !c.pinned }); if (r && r.ok === false) ctx.toast(String(r.error || "Épingle refusée."), true); else { c.pinned = !c.pinned; pin.classList.toggle("on", c.pinned); if (older && !c.pinned) el.querySelector('[data-pl="' + c.id + '"]')?.remove(); } }
      catch (e) { ctx.toast("Épingle impossible.", true); }
      pin.disabled = false;
    });
    if (c.vault) pin.hidden = true;
    const sigRow = h("div", { class: "pl-sigs" });
    sigRow.append(sigBtn(c, "up", "👍", "Utile", sigRow), sigBtn(c, "down", "👎", "Pas utile", sigRow), sigBtn(c, "more", "Plus", "Plus de ça", sigRow), sigBtn(c, "less", "Moins", "Moins de ça", sigRow));
    const lines = (Array.isArray(c.lignes) ? c.lignes : []).filter(Boolean).slice(0, 3);
    return h("article", { class: "pl-card" + (c.arrival ? " arrival" : "") + (older ? " older" : "") + (c.vault ? " vault" : ""), role: "listitem", "data-pl": String(c.id || ""), "data-cat": cat },
      h("div", { class: "pl-kick" },
        h("span", { class: "pl-cat" }, h("span", { html: ic(PULSE_IC[cat] || "dot", 12) }), PULSE_CAT[cat] || "Nova"),
        h("span", { class: "pl-src", title: String(src.nom || "") }, [String(src.nom || ""), pDate(src.date)].filter(Boolean).join(" · ")),
        pin),
      h("h3", { class: "pl-t" }, String(c.titre || "")),
      lines.length ? h("ul", { class: "pl-lines" }, ...lines.map((l) => h("li", {}, String(l)))) : null,
      h("div", { class: "pl-foot" }, actionBtn(c), h("span", { class: "sp" }), sigRow),
      older ? h("div", { class: "pl-older" }, "Épinglée · " + pDate(c.day || c.ts)) : null,
      c.arrival ? h("div", { class: "pl-flag" }, "Nouveau") : null);
  }
  function wishCard(j) {
    const w = j && j.wish && j.wish.texte ? String(j.wish.texte) : "";
    const ta = h("textarea", { class: "pl-wish-in", rows: "3", maxlength: "400", placeholder: "Ex. : plus de veille Sahel, moins de Éclats ; le point sur le dossier DAR.", "aria-label": "Dis-moi ce que tu veux demain" });
    ta.value = w;
    const save = async () => {
      const t = ta.value.trim();
      try { await api.post("/api/pulse/wish", { texte: t }); ctx.toast(t ? "Souhait noté pour ton prochain Pulse." : "Souhait effacé."); } catch (e) { ctx.toast("Souhait non enregistré.", true); }
    };
    ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); save(); } });
    return h("article", { class: "pl-card pl-wish", role: "listitem" },
      h("div", { class: "pl-kick" }, h("span", { class: "pl-cat" }, h("span", { html: ic("sparkle", 12) }), "Demain")),
      h("h3", { class: "pl-t" }, "Dis-moi ce que tu veux demain"),
      ta,
      h("div", { class: "pl-foot" }, h("span", { class: "pl-hint" }, "Entrée enregistre · Maj+Entrée : nouvelle ligne"), h("span", { class: "sp" }), h("button", { class: "btn sm", onclick: save }, "Noter")));
  }
  function emptyCard(text, withCompose) {
    return h("article", { class: "pl-card pl-empty", role: "listitem" },
      h("span", { class: "pl-empty-ic", html: ic("pulse", 20) }),
      h("p", {}, text),
      withCompose ? h("button", { class: "btn sm", onclick: () => compose() }, "Composer maintenant") : null);
  }
  async function load() {
    let j = null;
    try { j = await api.get("/api/pulse"); } catch (e) { j = null; }
    if (isDead()) return j;
    const cards = j && Array.isArray(j.cards) ? j.cards : [];
    const older = j && Array.isArray(j.pinned) ? j.pinned : [];
    const sig = JSON.stringify([cards.map((c) => [c.id, c.signal, c.pinned]), older.map((c) => c.id), j && j.running, j && j.composed, j && j.wish && j.wish.texte, j && j.vault_masked]);
    if (sig === lastSig) return j;
    lastSig = sig;
    const parts = [];
    if (j && j.composed) parts.push("composé " + pDate(j.composed));
    if (j && j.brain && !/^aucun/.test(String(j.brain))) parts.push(String(j.brain));
    if (j && j.running) parts.push("composition en cours…");
    meta.textContent = parts.join(" · ");
    recompose.hidden = !j;
    const nodes = [];
    for (const c of older) nodes.push(card(c, true));
    for (const c of cards) nodes.push(card(c, false));
    if (!cards.length) {
      if (j && j.running) nodes.push(h("article", { class: "pl-card pl-empty", role: "listitem", "aria-busy": "true" }, h("div", { class: "skel skel-block" }), h("p", {}, "Nova compose ton Pulse à partir de tes sources…")));
      else if (!j) nodes.push(emptyCard("Le Pulse est injoignable pour le moment.", false));
      else if (j.composed) nodes.push(emptyCard(String(j.note || "Rien de neuf dans tes sources ce matin : aucune carte n'a été inventée."), false));
      else nodes.push(emptyCard("Ton Pulse du matin arrive à " + String(j.heure || "07:30") + " : mails triés, agenda, engagements, Éclats, veille.", true));
    }
    if (j) nodes.push(wishCard(j));
    track.replaceChildren(...nodes);
    const notes = [];
    if (j && j.composed && j.note && cards.length) notes.push(String(j.note));
    if (j && j.vault_masked) notes.push(j.vault_masked + " carte" + (j.vault_masked > 1 ? "s" : "") + " du portefeuille masquée" + (j.vault_masked > 1 ? "s" : "") + " : déverrouille le coffre pour la voir.");
    note.hidden = !notes.length; note.textContent = notes.join(" ");
    requestAnimationFrame(navState);
    if (j && j.running && !pollT) { pollT0 = Date.now(); poll(); }
    return j;
  }
  return { el, load, stop: () => clearTimeout(pollT) };
}

/* ══ VAGUE 1 · BUDGET DES CERVEAUX (pied de l'Accueil) ═════════════════════
   GET /api/budget → { today:{usd,calls}, month:{label,usd,calls,brains[]}, cap_usd, pct, niveau, message }.
   Estimation (jetons du journal × grille de prix) : dite comme telle. Jamais de coupure. */
function budgetFooter(ctx, { isDead }) {
  const { api, h, ic } = ctx;
  const usd = (n) => new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(n) || 0) + " $";
  const txt = h("button", { class: "hb-txt", title: "Détail des coûts dans Finance", onclick: () => ctx.navigate("finance") });
  const bar = h("span", { class: "hb-bar", hidden: "" }, h("i", {}));
  const msg = h("span", { class: "hb-msg", hidden: "" });
  const capIn = h("input", { class: "hb-cap-in", type: "number", min: "0", step: "1", inputmode: "decimal", "aria-label": "Plafond mensuel en dollars", placeholder: "0 = aucun" });
  const capBox = h("span", { class: "hb-cap", hidden: "" }, capIn, h("span", { class: "hb-u" }, "$ / mois"));
  const capBtn = h("button", { class: "btn ghost sm hb-edit" }, "Plafond");
  const el = h("footer", { class: "home-budget", hidden: "" }, h("span", { class: "hb-ic", html: ic("cpu", 14) }), txt, bar, msg, h("span", { class: "sp" }), capBox, capBtn);
  let editing = false, cap = 0;
  const saveCap = async () => {
    const v = Number(String(capIn.value).replace(",", "."));
    if (!isFinite(v) || v < 0) { ctx.toast("Montant invalide.", true); return; }
    try { await api.post("/api/budget/cap", { usd: v }); ctx.toast(v ? "Plafond mensuel : " + usd(v) + " (estimation, sans coupure)." : "Plafond retiré."); editing = false; capBox.hidden = true; capBtn.textContent = "Plafond"; load(); }
    catch (e) { ctx.toast("Plafond non enregistré.", true); }
  };
  capIn.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); saveCap(); } if (e.key === "Escape") { editing = false; capBox.hidden = true; capBtn.textContent = "Plafond"; } });
  capBtn.addEventListener("click", () => { if (editing) { saveCap(); return; } editing = true; capBox.hidden = false; capBtn.textContent = "Enregistrer"; capIn.value = cap ? String(cap) : ""; capIn.focus(); });
  async function load() {
    let b = null;
    try { b = await api.get("/api/budget"); } catch (e) { b = null; }
    if (isDead()) return;
    if (!b || !b.month || !b.today) { el.hidden = true; return; }
    el.hidden = false;
    cap = Number(b.cap_usd) || 0;
    const parts = ["Cerveaux · aujourd'hui " + usd(b.today.usd), String(b.month.label || "ce mois") + " " + usd(b.month.usd) + (cap ? " / " + usd(cap) : "")];
    txt.textContent = parts.join(" · ") + " (estimation)";
    const pct = b.pct == null ? null : Number(b.pct);
    el.classList.toggle("warn", b.niveau === "alerte80");
    el.classList.toggle("over", b.niveau === "depasse");
    if (cap && pct != null) { bar.hidden = false; bar.firstChild.style.width = Math.min(100, Math.max(2, pct)) + "%"; bar.title = pct + " % du plafond mensuel"; }
    else bar.hidden = true;
    msg.hidden = !b.message; msg.textContent = b.message ? String(b.message) : "";
  }
  return { el, load };
}


/* 29/10 (Ahadi : « continue les améliorations et customisations ») — PERSONNALISER L'ACCUEIL.
   Chaque bloc se masque ou revient d'un clic ; le choix reste sur ce Mac (préférence d'affichage, rien d'autre).
   Les grilles se recomposent : une carte masquée ne laisse pas de colonne vide. */
function homeCustomizer(ctx, o) {
  const { h, ic } = ctx;
  const KEY = "nova2_home_hide";
  let off = {};
  try { off = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (e) { off = {}; }
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(off)); } catch (e) {} };
  const all = [["ring", "Anneau de la journée et compagnon", o.ring]].concat(o.cards, o.tiles, o.extras);
  const OKEY = "nova2_home_order";
  let order = [];
  try { order = JSON.parse(localStorage.getItem(OKEY) || "[]") || []; } catch (e) { order = []; }
  const cardKeys = o.cards.map(([k]) => k);
  order = order.filter((k) => cardKeys.includes(k)).concat(cardKeys.filter((k) => !order.includes(k)));
  const saveOrder = () => { try { localStorage.setItem(OKEY, JSON.stringify(order)); } catch (e) {} };
  const apply = () => {
    for (const k of order) { const c = o.cards.find(([x]) => x === k); if (c) o.gridEl.append(c[2]); }   /* 29/10 : ordre choisi */
    for (const [k, , el] of all) { try { el.classList.toggle("hq-off", !!off[k]); } catch (e) {} }
    try { o.legend.classList.toggle("hq-off", !!off.ring); o.hero.classList.toggle("hq-noring", !!off.ring); } catch (e) {}
    const nc = o.cards.filter(([k]) => !off[k]).length;
    o.gridEl.classList.toggle("hq-off", nc === 0);
    o.gridEl.style.setProperty("--hq-cols", nc === 3 ? "1.25fr 1fr 1fr" : nc === 2 ? "1.25fr 1fr" : "minmax(0,1fr)");
    const nt = o.tiles.filter(([k]) => !off[k]).length;
    o.stripEl.classList.toggle("hq-off", nt === 0);
    o.stripEl.style.setProperty("--hq-tiles", String(Math.max(1, nt)));
  };
  const panel = h("div", { class: "hq-custom-p", hidden: true, role: "group", "aria-label": "Blocs affichés sur l'Accueil" });
  const group = (label, items) => h("fieldset", { class: "hq-custom-g" }, h("legend", {}, label), ...items.map(([k, name]) => {
    const cb = h("input", { type: "checkbox" }); cb.checked = !off[k];
    cb.addEventListener("change", () => { if (cb.checked) delete off[k]; else off[k] = 1; save(); apply(); });
    return h("label", { class: "hq-custom-i" }, cb, h("span", {}, name));
  }));
  const reset = h("button", { type: "button", class: "hq-custom-reset" }, "Tout réafficher");
  reset.addEventListener("click", () => { off = {}; save(); order = cardKeys.slice(); saveOrder(); paintOrder(); apply(); for (const cb of panel.querySelectorAll("input[type=checkbox]")) cb.checked = true; });
  /* Ordre des cartes : flèches ↑ ↓ (clavier compris), enregistré sur ce Mac. */
  const orderBox = h("fieldset", { class: "hq-custom-g" }, h("legend", {}, "Ordre des cartes"));
  const paintOrder = () => {
    orderBox.querySelectorAll(".hq-order-r").forEach((x) => x.remove());
    order.forEach((k, i) => {
      const name = (o.cards.find(([x]) => x === k) || [k, k])[1];
      const mv = (d) => { const j = i + d; if (j < 0 || j >= order.length) return; const t = order[i]; order[i] = order[j]; order[j] = t; saveOrder(); apply(); paintOrder(); };
      const up = h("button", { type: "button", class: "hq-order-b", "aria-label": "Monter " + name, disabled: i === 0 }, "↑"); up.addEventListener("click", () => mv(-1));
      const dn = h("button", { type: "button", class: "hq-order-b", "aria-label": "Descendre " + name, disabled: i === order.length - 1 }, "↓"); dn.addEventListener("click", () => mv(1));
      orderBox.append(h("div", { class: "hq-order-r" }, h("span", {}, name), up, dn));
    });
  };
  paintOrder();
  /* Nuit douce : en mode nuit, teinte plus chaude et contraste adouci pour le soir. */
  const soft = h("input", { type: "checkbox" });
  try { soft.checked = localStorage.getItem("nova2_soft_night") === "1"; } catch (e) {}
  soft.addEventListener("change", () => { try { localStorage.setItem("nova2_soft_night", soft.checked ? "1" : "0"); } catch (e) {} if (soft.checked) document.documentElement.dataset.softNight = "1"; else delete document.documentElement.dataset.softNight; });
  const softBox = h("fieldset", { class: "hq-custom-g" }, h("legend", {}, "Confort"), h("label", { class: "hq-custom-i" }, soft, h("span", {}, "Nuit douce (thèmes de nuit)")));
  panel.append(group("En haut", [all[0]]), group("Cartes", o.cards), orderBox, group("Raccourcis", o.tiles), group("Plus bas", o.extras), softBox, reset);
  const btn = h("button", { type: "button", class: "hq-custom-btn", "aria-expanded": "false" }, h("span", { html: ic("gear", 14) }), h("span", {}, "Personnaliser l'accueil"));
  btn.addEventListener("click", () => { panel.hidden = !panel.hidden; btn.setAttribute("aria-expanded", panel.hidden ? "false" : "true"); if (!panel.hidden) try { panel.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (e) {} });
  apply();
  return { el: h("div", { class: "hq-custom" }, btn, panel), apply };
}
