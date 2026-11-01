/* Module Finance — BRVM : portefeuille personnel (coffre), séance publique, coûts des cerveaux.
   Règles (recherche §4.2) : tableau avant cartes ; chiffres en tabular-nums ; la lecture de séance
   est GÉNÉRÉE depuis les données et cite sa source — aucun avis de synthèse non sourcé.
   Rafraîchissement : bouton + every() de 60 s (suspendu si caché, tué au démontage).
   E3 : le portefeuille est un compartiment du coffre (vaultgate.js) — aucun appel protégé avant le
   jeton (C-01), « Rafraîchir » désactivé (attribut réel) tant que le coffre est fermé, verrouillage
   automatique au démontage. Les cours BRVM sont PUBLICS (brvm.org) : visibles coffre fermé.
   V6 « Moi » (25/10/2026) — contrat conseil_24-10/V6_DESIGN.md :
   · ordre : MON portefeuille d'abord (KPIs valeur / variation du jour / +/- latente, calculés
     seulement à partir de ce que le coffre fournit), puis le marché, puis les coûts IA ;
   · coffre fermé → carte claire « Coffre verrouillé — déverrouille pour voir ton portefeuille »
     portant la porte existante (Touch ID / code) ;
   · graphique des variations : axe, ligne zéro, symboles (pivotés si serrés), info-bulle
     nom / cours / variation au survol ou au clavier ;
   · 48 cours → table .ds-table (en-tête collant) avec recherche, tri (symbole, nom, cours, var.)
     et puces Toutes / Hausse / Baisse / Mes valeurs. */
import { vaultGate, vaultLock, vaultIsUnlocked } from "../vaultgate.js";
import { fmtNumFR, fmtMoneyFR, fmtPctFR, fmtDateFR, fmtTimeFR } from "../core.js";
import * as ds from "../ds.js";
import { createBrvmAlerts } from "../brvm-alertes.js";   // LOT3 (25/10) : alertes de cours + suivi (Feat_BRVMAlertes.swift)
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const varTxt = (v) => { const n = Number(v); return isFinite(n) ? (n > 0 ? "+" : "") + fmtPctFR(n) : "—"; };
const signMoney = (v, dev = "") => { const n = Math.round(Number(v)); if (!isFinite(n)) return "—"; return (n > 0 ? "+" : n < 0 ? "−" : "") + fmtMoneyFR(Math.abs(n), dev); };
const toneOf = (v) => { const n = Number(v); return n > 0 ? "ok" : n < 0 ? "danger" : ""; };
/* Masquage d'affichage : n° de compte (≥ 8 chiffres), IBAN, jetons → ••••1234 (V6 §7). */
const maskText = (s) => String(s ?? "")
  .replace(/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,8}(?:\s?[A-Z0-9]{1,4})?\b/g, (m) => ds.maskSecret(m))
  .replace(/\b(?:sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9-_]{12,}\b/g, (m) => ds.maskSecret(m))
  .replace(/(?<![\w.,/-])\d{8,}(?!\w|[.,/-]\w)/g, (m) => ds.maskSecret(m));
/* Cerveaux : un identifiant moteur n'est jamais affiché brut. */
const BRAIN_NAMES = { "spark-1.3": "Muse Spark 1.3", "spark-1.2": "Muse Spark 1.2", "wonder-1.0": "Muse Wonder 1.0", "spark-open-baseten": "Muse Spark Open (Baseten)", "spark-open-hf": "Muse Spark Open (Hugging Face)", "muse-code": "Muse Code" };
/* Compteur de section posé après coup (ds.section ne crée la pastille que si un compte est donné). */
const setCnt = (sec, n) => { let c = sec.querySelector(":scope > .ds-section-head > .ds-count"); if (n === "" || n == null) { if (c) c.remove(); return; } if (!c) { c = document.createElement("span"); c.className = "ds-count"; sec.querySelector(":scope > .ds-section-head > .ds-h2").after(c); } c.textContent = String(n); c.setAttribute("aria-label", n + " éléments"); };
const brainLabel = (id) => { const s = String(id || "").trim(); if (!s) return "—"; if (BRAIN_NAMES[s]) return BRAIN_NAMES[s]; const t = s.replace(/-(direct|cloud|local)$/i, "").replace(/[-_]+/g, " "); return t.charAt(0).toUpperCase() + t.slice(1); };

export async function mount(root, ctx) {
  const { api, every, h } = ctx;
  let dead = false;
  root.classList.add("mod--data", "moi-fin", "is-locked");
  /* 26/10 (Ahadi : « je n'arrive pas à rafraîchir la page BRVM ») : le bouton était grisé tant que le coffre restait fermé.
     Il rafraîchit maintenant toujours les cours publics ; le portefeuille et les coûts suivent quand le coffre est ouvert. */
  const refreshBtn = ds.action({ label: "Rafraîchir", icon: "refresh", tip: "Rafraîchir les cours de la BRVM (et ton portefeuille si le coffre est ouvert)", onClick: () => refreshAll(true) });
  root.append(ds.pageHead({ title: "Finance", sub: "Ton portefeuille BRVM, la séance du jour et ce que coûtent les cerveaux de Nova", actions: [refreshBtn] }));

  /* ── 1 · Mon portefeuille (coffre) ── */
  const portSec = ds.section({ title: "Mon portefeuille" });
  const portBox = portSec.body;
  const gate = vaultGate(ctx, "Portefeuille", () => {
    root.classList.remove("is-locked");
    refreshBtn.disabled = false; refreshBtn.title = "Rafraîchir le portefeuille, les cours et les coûts";
    lockCard.remove();
    if (!dead) start();
  });
  const lockCard = ds.card({ class: "moi-fin-lock" },
    h("div", { class: "moi-fin-lock-head" },
      h("span", { class: "moi-fin-lock-ic", html: ctx.ic("lock", 18) }),
      h("div", { class: "moi-fin-lock-t" },
        h("div", { class: "ds-h3" }, "Coffre verrouillé — déverrouille pour voir ton portefeuille"),
        h("div", { class: "ds-meta" }, "Positions, valeur et plus-values restent chiffrées dans le coffre. Les cours publics de la BRVM restent visibles ci-dessous."))),
    gate);
  portBox.append(lockCard);
  const portContent = h("div", { class: "moi-fin-port" });
  portBox.append(portContent);

  /* ── 2 · Marché BRVM (public) ── */
  const mktSec = ds.section({ title: "Marché BRVM" });
  const mktSum = h("div", { class: "moi-fin-sum ds-meta" });
  const chartCard = ds.card({ class: "moi-fin-chart" });
  const mktTools = h("div", {});
  const mktTable = h("div", {});
  mktSec.body.append(mktSum, chartCard, mktTools, mktTable);
  chartCard.append(ds.skeleton(2));
  const divSec = ds.section({ title: "Dividendes connus" });
  divSec.hidden = true;
  /* ── 3 · Coûts IA (après ouverture, comme avant) ── */
  const coutSec = ds.section({ title: "Coûts IA", collapsible: true, open: true });
  coutSec.hidden = true;
  let lastQuotes = null, lastPort = null;
  const mf = { q: "", f: "all", sort: "sym", dir: 1 };
  const mySyms = () => { const s = new Set(); const acc = (lastPort && lastPort.accounts) || {}; for (const a of Object.values(acc)) for (const p of (a && a.positions) || []) if (p && p.sym) s.add(String(p.sym)); return s; };
  /* LOT3 : alertes par valeur (cloche sur chaque ligne du marché) + « Mes alertes » + « Suivi » (courbes des relevés).
     Les positions détenues n'entrent au suivi que coffre ouvert (lastPort n'existe qu'après le jeton). */
  let watchList = [];
  const alerts = createBrvmAlerts({ toast: (t, bad) => ctx.toast(t, bad), getQuotes: () => arrOf(lastQuotes, "quotes"), getHeld: () => mySyms(),
    getWatch: () => watchList, setWatch: (l) => { watchList = l.slice(); }, repaint: () => { if (!dead) { paintMarket(); alerts.paint(); } } });
  root.append(portSec, alerts.watchSec, mktSec, alerts.alertSec, divSec, coutSec);

  /* Graphique : barres des variations du jour (la source ne fournit que cours + variation — aucun
     historique inventé). Canvas 2D, axe gauche gradué, ligne zéro, symboles sous l'axe (pivotés
     quand la place manque), info-bulle au survol et au clavier (←/→). Couleurs = jetons --ds-*. */
  const tokColor = (el, v, fb) => { const p = h("span", { style: "position:absolute;visibility:hidden;color:" + v }); el.append(p); const c = getComputedStyle(p).color || fb; p.remove(); return c || fb; };
  function drawChart(wrap, canvas, tip, quotes, mine) {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = Math.max(240, canvas.clientWidth || 520);
    const n = Math.max(1, quotes.length);
    const AX = 44, PADR = 8;
    const slot = (W - AX - PADR) / n;
    const rot = slot < 34;
    const every = rot ? Math.max(1, Math.ceil(11 / slot)) : 1;
    const LB = rot ? 46 : 20, TOP = 12;
    const H = 210 + LB;
    canvas.width = W * dpr; canvas.height = H * dpr; canvas.style.height = H + "px";
    const g = canvas.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
    const up = tokColor(wrap, "var(--ds-ok)", "#1F8A3A"), down = tokColor(wrap, "var(--ds-danger)", "#C21B17");
    const line = tokColor(wrap, "var(--hairline)", "rgba(127,127,127,.3)"), ink = tokColor(wrap, "var(--ds-muted)", "#888"), ink2 = tokColor(wrap, "var(--text-2)", "#666"), acc = tokColor(wrap, "var(--accent)", "#c33");
    const font = getComputedStyle(wrap).fontFamily || "system-ui";
    const vals = quotes.map((q) => Number(q.var) || 0);
    const raw = Math.max(0.5, ...vals.map((v) => Math.abs(v)));
    const step = raw <= 1 ? 0.5 : raw <= 2 ? 1 : raw <= 5 ? 2.5 : raw <= 10 ? 5 : Math.ceil(raw / 4);
    const max = Math.ceil(raw / step) * step;
    const plotH = H - LB - TOP, mid = TOP + plotH / 2, half = plotH / 2 - 2;
    const y = (v) => mid - (v / max) * half;
    g.font = "500 10px " + font; g.textAlign = "right"; g.textBaseline = "middle";
    for (let t = -max; t <= max + 1e-9; t += step) {
      const yy = Math.round(y(t)) + 0.5;
      g.strokeStyle = line; g.globalAlpha = Math.abs(t) < 1e-9 ? 1 : 0.55; g.lineWidth = Math.abs(t) < 1e-9 ? 1.2 : 1;
      if (Math.abs(t) >= 1e-9) g.setLineDash([3, 4]); else g.setLineDash([]);
      g.beginPath(); g.moveTo(AX, yy); g.lineTo(W - PADR, yy); g.stroke();
      g.globalAlpha = 1; g.setLineDash([]);
      g.fillStyle = ink; g.fillText((t > 0 ? "+" : t < 0 ? "−" : "") + String(Math.abs(Math.round(t * 10) / 10)).replace(".", ",") + " %", AX - 6, yy);
    }
    const bw = Math.max(3, Math.min(22, slot * 0.62));
    quotes.forEach((q, i) => {
      const v = vals[i], cx = AX + slot * i + slot / 2;
      const top = y(Math.max(0, v)), bot = y(Math.min(0, v));
      const bh = Math.max(1.5, bot - top);
      g.fillStyle = v > 0 ? up : v < 0 ? down : line;
      g.fillRect(cx - bw / 2, v >= 0 ? mid - bh : mid, bw, bh);
      if (mine.has(String(q.sym))) { g.strokeStyle = acc; g.lineWidth = 1.5; g.strokeRect(cx - bw / 2 - 1.5, (v >= 0 ? mid - bh : mid) - 1.5, bw + 3, bh + 3); }
      if (i % every === 0) {
        g.fillStyle = mine.has(String(q.sym)) ? acc : ink2;
        g.font = "600 " + (rot ? 9.5 : 10) + "px " + font;
        if (rot) { g.save(); g.translate(cx + 3, H - LB + 6); g.rotate(-Math.PI / 3); g.textAlign = "right"; g.textBaseline = "middle"; g.fillText(String(q.sym || ""), 0, 0); g.restore(); }
        else { g.textAlign = "center"; g.textBaseline = "alphabetic"; g.fillText(String(q.sym || ""), cx, H - 5); }
      }
    });
    /* Survol / clavier → info-bulle (nom, symbole, cours, variation). */
    const show = (i) => {
      if (i < 0 || i >= n) { tip.hidden = true; return; }
      const q = quotes[i], cx = AX + slot * i + slot / 2;
      tip.replaceChildren(h("b", {}, String(q.name || q.sym || "")), h("span", { class: "ds-meta" }, String(q.sym || "") + (mine.has(String(q.sym)) ? " · dans ton portefeuille" : "")),
        h("span", { class: "moi-fin-tip-v" }, fmtMoneyFR(q.price, "FCFA"), " ", h("b", { class: "moi-fin-v " + toneOf(q.var) }, varTxt(q.var))));
      tip.hidden = false;
      const tw = tip.offsetWidth || 160;
      tip.style.left = Math.max(0, Math.min(W - tw, cx - tw / 2)) + "px";
      tip.style.top = Math.max(0, y(Math.max(0, vals[i])) - (tip.offsetHeight || 54) - 8) + "px";
      canvas.setAttribute("aria-valuetext", String(q.sym) + " " + varTxt(q.var));
    };
    canvas.onmousemove = (e) => { const r = canvas.getBoundingClientRect(); const i = Math.floor((e.clientX - r.left - AX) / slot); show(i); canvas.dataset.i = String(i); };
    canvas.onmouseleave = () => { tip.hidden = true; };
    canvas.onblur = () => { tip.hidden = true; };
    canvas.onkeydown = (e) => {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      e.preventDefault();
      let i = Number(canvas.dataset.i); if (!isFinite(i) || i < 0 || i >= n) i = e.key === "ArrowRight" ? -1 : n;
      i = Math.max(0, Math.min(n - 1, i + (e.key === "ArrowRight" ? 1 : -1))); canvas.dataset.i = String(i); show(i);
    };
  }

  function filteredQuotes(all) {
    const mine = mySyms();
    const q = mf.q.toLowerCase();
    let rows = all.filter((x) => {
      const v = Number(x.var) || 0;
      if (mf.f === "up" && !(v > 0)) return false;
      if (mf.f === "down" && !(v < 0)) return false;
      if (mf.f === "mine" && !mine.has(String(x.sym))) return false;
      if (q && !(String(x.sym || "").toLowerCase().includes(q) || String(x.name || "").toLowerCase().includes(q))) return false;
      return true;
    });
    const key = { sym: (x) => String(x.sym || ""), name: (x) => String(x.name || ""), price: (x) => Number(x.price) || 0, var: (x) => Number(x.var) || 0 }[mf.sort];
    rows = rows.slice().sort((a, b) => { const A = key(a), B = key(b); return (typeof A === "number" ? A - B : A.localeCompare(B, "fr")) * mf.dir; });
    return rows;
  }

  let chipsEl = null, searchBar = null, chartEls = null;
  function renderQuotes(j) {
    lastQuotes = j || {};
    const all = arrOf(j, "quotes");
    const mine = mySyms();
    const ups = all.filter((q) => Number(q.var) > 0).length, downs = all.filter((q) => Number(q.var) < 0).length;
    const seance = j && j.quotes_at ? fmtDateFR(j.quotes_at) + " · " + fmtTimeFR(j.quotes_at) : "—";
    setCnt(mktSec, all.length || "");
    if (!all.length) {
      mktSum.replaceChildren();
      chartCard.replaceChildren(ds.empty({ text: "Aucun cours publié pour le moment — la séance n'a peut-être pas encore ouvert.", icon: "chart", action: { label: "Recharger", icon: "refresh", onClick: () => loadQuotes() } }));
      mktTools.replaceChildren(); mktTable.replaceChildren();
      return;
    }
    const best = all.slice().sort((a, b) => Number(b.var) - Number(a.var))[0];
    const worst = all.slice().sort((a, b) => Number(a.var) - Number(b.var))[0];
    mktSum.replaceChildren(
      h("span", {}, "Séance du ", h("b", {}, seance)),
      h("span", {}, h("b", { class: "num" }, fmtNumFR(all.length)), " valeurs"),
      h("span", { class: "moi-fin-v ok" }, h("b", { class: "num" }, fmtNumFR(ups)), " en hausse"),
      h("span", { class: "moi-fin-v danger" }, h("b", { class: "num" }, fmtNumFR(downs)), " en baisse"),
      h("span", { title: "Source : " + String((j && j.source) || "brvm.org") + (j && j.disclaimer ? " — " + j.disclaimer : "") }, "Source : " + String((j && j.source) || "brvm.org")));
    /* Toolbar + table : construits une fois, rafraîchis ensuite (la saisie de recherche n'est jamais perdue). */
    const chipItems = [{ id: "all", label: "Toutes", n: all.length }, { id: "up", label: "Hausse", n: ups }, { id: "down", label: "Baisse", n: downs }];
    if (mine.size) chipItems.push({ id: "mine", label: "Mes valeurs", n: all.filter((q) => mine.has(String(q.sym))).length });
    if (!mine.size && mf.f === "mine") mf.f = "all";
    chipItems.forEach((c) => { c.on = c.id === mf.f; });
    chipsEl = ds.chips(chipItems, (id) => { mf.f = id; paintMarket(); });
    if (!searchBar) {
      searchBar = ds.toolbar({ search: { placeholder: "Chercher un symbole ou une société…", onInput: (v) => { mf.q = v; paintMarket(); } } });
    }
    searchBar.querySelector(".ds-chips") && searchBar.querySelector(".ds-chips").remove();
    searchBar.append(chipsEl);
    if (!mktTools.contains(searchBar)) mktTools.replaceChildren(searchBar);
    if (!chartEls) {
      const canvas = h("canvas", { class: "moi-fin-canvas", tabindex: "0", role: "img", "aria-label": "Variations du jour des valeurs affichées — survole ou utilise ← → pour lire chaque valeur" });
      const tip = h("div", { class: "moi-fin-tip", role: "status", hidden: true });
      const foot = h("div", { class: "moi-fin-chart-foot ds-meta" });
      const plot = h("div", { class: "moi-fin-plot" }, canvas, tip);
      chartEls = { canvas, tip, foot, plot };
      chartCard.replaceChildren(plot, foot);
    }
    chartEls.foot.replaceChildren(
      best && all.length > 1 ? h("span", {}, "Plus forte hausse : ", h("b", {}, String(best.sym)), " ", h("span", { class: "moi-fin-v ok" }, varTxt(best.var))) : null,
      worst && all.length > 1 ? h("span", {}, "Plus forte baisse : ", h("b", {}, String(worst.sym)), " ", h("span", { class: "moi-fin-v danger" }, varTxt(worst.var))) : null,
      mine.size ? h("span", { class: "moi-fin-legend" }, h("i"), "tes valeurs") : null,
      h("span", {}, "Lecture générée depuis les cours — ni conseil ni ordre."));
    paintMarket();
  }
  function paintMarket() {
    const all = arrOf(lastQuotes, "quotes");
    const rows = filteredQuotes(all);
    const mine = mySyms();
    const sortTh = (id, label, num) => {
      const on = mf.sort === id;
      const b = h("button", { type: "button", class: "moi-fin-sort" + (on ? " is-on" : ""), title: "Trier par " + label.toLowerCase(), onclick: () => { if (mf.sort === id) mf.dir = -mf.dir; else { mf.sort = id; mf.dir = id === "var" || id === "price" ? -1 : 1; } paintMarket(); } },
        label, h("span", { class: "moi-fin-arrow", "aria-hidden": "true" }, on ? (mf.dir > 0 ? "↑" : "↓") : "↕"));
      return h("th", { class: num ? "num" : null, "aria-sort": on ? (mf.dir > 0 ? "ascending" : "descending") : "none", scope: "col" }, b);
    };
    const body = [];
    for (const q of rows) {
      body.push(h("tr", { class: mine.has(String(q.sym)) ? "is-mine" : null },
        h("td", { class: "moi-fin-sym" }, String(q.sym || "—"), mine.has(String(q.sym)) ? h("span", { class: "moi-fin-dot", title: "Dans ton portefeuille" }) : null),
        h("td", { class: "moi-fin-name" }, String(q.name || "—")),
        h("td", { class: "num" }, fmtMoneyFR(q.price, "")),
        h("td", { class: "num moi-fin-v " + toneOf(q.var) }, varTxt(q.var)),
        alerts.cell(q)));
      const ed = alerts.editorRow(q, 5);   // LOT3 : éditeur d'alerte déplié sous la valeur
      if (ed) body.push(ed);
    }
    const wrap = h("div", { class: "ds-table-wrap moi-fin-tw" },
      h("table", { class: "ds-table" },
        h("thead", {}, h("tr", {}, sortTh("sym", "Symbole"), sortTh("name", "Société"), sortTh("price", "Cours (FCFA)", true), sortTh("var", "Variation", true), h("th", { scope: "col", class: "brvm-bell-td" }, "Alerte"))),
        h("tbody", {}, ...body)));
    mktTable.replaceChildren(rows.length ? wrap : ds.empty({ compact: true, icon: "search", text: "Aucune valeur ne correspond à ce filtre.", action: { label: "Tout afficher", ghost: true, onClick: () => { mf.q = ""; mf.f = "all"; if (searchBar && searchBar.input) { searchBar.input.value = ""; searchBar.input.dispatchEvent(new Event("input")); } renderQuotes(lastQuotes); } } }));
    const chartRows = rows.slice().sort((a, b) => String(a.sym).localeCompare(String(b.sym)));
    if (chartEls) requestAnimationFrame(() => { if (!dead) { if (chartRows.length) drawChart(chartCard, chartEls.canvas, chartEls.tip, chartRows, mine); } });
    if (chartEls) chartEls.plot.hidden = !chartRows.length;
  }
  let ro = null;
  try { ro = new ResizeObserver(() => { if (chartEls && lastQuotes && !dead) paintChartOnly(); }); ro.observe(chartCard); } catch (e) {}
  let rz = 0;
  function paintChartOnly() { cancelAnimationFrame(rz); rz = requestAnimationFrame(() => { const rows = filteredQuotes(arrOf(lastQuotes, "quotes")).sort((a, b) => String(a.sym).localeCompare(String(b.sym))); if (rows.length) drawChart(chartCard, chartEls.canvas, chartEls.tip, rows, mySyms()); }); }

  async function loadQuotes() {
    try { const j = await api.get("/api/veille/brvm"); if (!dead) { watchList = Array.isArray(j && j.watch) ? j.watch.map(String) : []; renderQuotes(j); renderDividends(j); alerts.load(); } }
    catch (e) {
      if (dead) return;
      chartEls = null;
      mktSum.replaceChildren();
      chartCard.replaceChildren(ds.errorBox({ cause: "Le bandeau public de la BRVM ne répond pas.", retry: () => loadQuotes() }));
      mktTools.replaceChildren(); mktTable.replaceChildren();
    }
  }

  /* FIX-WEB C2 : GET /api/portfolio (Portfolio.swift portfolioRoutes) renvoie
     { accounts: { <compte>: { account, kind, as_of, cash, total_releve, invested, positions:[{name,sym,qty,cmp,cours_releve,valeur_releve}], source } },
       quotes: { <SYM>: { price, var } }, quotes_at, watch:<dossier surveillé>, last_error }.
     Cours = quotes[sym].price (sinon cours du relevé, sinon PRU) ; valeur = qté × cours. */
  const numIn = (v) => { const n = Number(String(v ?? "").replace(/[\s  ]/g, "").replace(",", ".")); return isFinite(n) ? n : NaN; };
  function posRow(p, quotes) {
    const q = (p.sym && quotes[p.sym]) || null;
    const cours = q && Number(q.price) > 0 ? Number(q.price) : (Number(p.cours_releve) > 0 ? Number(p.cours_releve) : Number(p.cmp) || 0);
    const qty = Number(p.qty) || 0, cmp = Number(p.cmp) || 0;
    const live = !!(q && Number(q.price) > 0);
    const v = live ? Number(q.var) : NaN;
    /* Variation du jour en FCFA : cours − cours de la veille (= cours / (1 + var %)) — seulement sur une cotation du jour. */
    const dayDelta = live && isFinite(v) && v > -100 ? qty * (cours - cours / (1 + v / 100)) : null;
    return { p, q, qty, cmp, cours, live, valeur: qty * cours, pv: cmp > 0 ? qty * (cours - cmp) : null, dayDelta };
  }
  function renderPortfolio(j) {
    lastPort = j || {};
    const accounts = (j && j.accounts && typeof j.accounts === "object") ? Object.entries(j.accounts) : [];
    const quotes = (j && j.quotes && typeof j.quotes === "object") ? j.quotes : {};
    let grand = 0, grandCash = 0, grandCost = 0, costKnown = true, dayDelta = 0, dayKnown = false, prevVal = 0;
    const blocks = [];
    for (const [key, a] of accounts) {
      const rows = (Array.isArray(a && a.positions) ? a.positions : []).map((p) => posRow(p, quotes));
      const titres = rows.reduce((s, r) => s + r.valeur, 0), cash = Number(a.cash) || 0;
      grand += titres + cash; grandCash += cash;
      for (const r of rows) {
        if (r.cmp > 0) grandCost += r.qty * r.cmp; else costKnown = false;
        if (r.dayDelta != null) { dayDelta += r.dayDelta; dayKnown = true; prevVal += r.valeur - r.dayDelta; }
      }
      const accName = maskText(String(a.account || key));
      const tableEl = rows.length ? h("div", { class: "ds-table-wrap moi-fin-pw" }, h("table", { class: "ds-table" },
        h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "Titre"), h("th", { class: "num", scope: "col" }, "Qté"), h("th", { class: "num", scope: "col" }, "PRU"), h("th", { class: "num", scope: "col" }, "Cours"), h("th", { class: "num", scope: "col" }, "Var."), h("th", { class: "num", scope: "col" }, "Valeur (FCFA)"), h("th", { class: "num", scope: "col" }, "+/− latente"), h("th", { scope: "col", "aria-label": "Actions" }, ""))),
        h("tbody", {}, ...rows.map((r) => h("tr", {},
          r.p.sym ? h("td", { class: "moi-fin-sym" }, String(r.p.sym), r.p.name ? h("span", { class: "moi-fin-pname" }, String(r.p.name)) : null) : h("td", { class: "moi-fin-sym" }, String(r.p.name || "—")),
          h("td", { class: "num" }, fmtNumFR(r.qty)),
          h("td", { class: "num" }, r.cmp ? fmtMoneyFR(r.cmp, "") : "—"),
          h("td", { class: "num", title: r.live ? "Cours BRVM" + (j.quotes_at ? " du " + fmtDateFR(j.quotes_at) + " " + fmtTimeFR(j.quotes_at) : "") : "Cours du relevé — aucune cotation BRVM pour ce symbole" }, fmtMoneyFR(r.cours, ""), r.live ? null : h("span", { class: "moi-fin-star" }, " *")),
          h("td", { class: "num moi-fin-v " + (r.q ? toneOf(r.q.var) : "") }, r.q ? varTxt(r.q.var) : "—"),
          h("td", { class: "num" }, fmtMoneyFR(r.valeur, "")),
          h("td", { class: "num moi-fin-v " + (r.pv == null ? "" : toneOf(r.pv)) }, r.pv == null ? "—" : signMoney(r.pv)),
          h("td", { class: "moi-fin-act" }, ds.action({ icon: "trash", tip: "Retirer cette ligne du compte", onClick: () => removePosition(String(a.account || key), r.p) })))),
          cash ? h("tr", { class: "moi-fin-cash" }, h("td", {}, "Liquidités"), h("td", {}), h("td", {}), h("td", {}), h("td", {}), h("td", { class: "num" }, fmtMoneyFR(cash, "")), h("td", {}), h("td", {})) : null)))
        : ds.empty({ compact: true, icon: "file", text: "Aucune position dans ce compte." });
      blocks.push(h("div", { class: "moi-fin-acc" },
        h("div", { class: "moi-fin-acc-head" },
          h("div", { class: "moi-fin-acc-t" }, h("span", { class: "ds-h3" }, accName),
            h("span", { class: "ds-meta" }, [String(a.kind || "Compte"), a.as_of ? "relevé du " + fmtDateFR(a.as_of) : "", a.source ? "source : " + maskText(String(a.source)) : ""].filter(Boolean).join(" · "))),
          h("div", { class: "moi-fin-acc-v" },
            h("span", { class: "ds-meta" }, "Valeur au cours"), h("b", { class: "ds-num" }, fmtMoneyFR(titres + cash, "FCFA")),
            Number(a.total_releve) > 0 ? h("span", { class: "ds-meta", title: "Total indiqué sur le relevé" }, "relevé : " + fmtMoneyFR(a.total_releve, "FCFA")) : null),
          ds.action({ label: "Retirer le compte", ghost: true, tip: "Retirer ce compte du portefeuille (le relevé reste sur le disque)", onClick: () => removeAccount(String(a.account || key)) })),
        tableEl));
    }
    const kids = [];
    if (accounts.length) {
      const pv = grand - grandCash - grandCost;
      const dayPct = dayKnown && prevVal > 0 ? (dayDelta / prevVal) * 100 : null;
      kids.push(ds.kpis([
        { label: "Valeur du portefeuille", value: fmtMoneyFR(Math.round(grand), "FCFA"), delta: (grandCash ? "dont " + fmtMoneyFR(grandCash, "FCFA") + " de liquidités" : "titres au dernier cours") + (j && j.quotes_at ? " · " + fmtTimeFR(j.quotes_at) : ""), tip: "Titres au dernier cours BRVM (sinon cours du relevé) + liquidités" },
        { label: "Variation du jour", value: dayKnown ? signMoney(dayDelta, "FCFA") : null, delta: dayKnown ? (dayPct != null ? varTxt(dayPct) + " sur les titres cotés" : "") : "aucune cotation du jour sur tes titres", tone: dayKnown ? toneOf(dayDelta) : "", tip: dayKnown ? "Somme, sur tes titres cotés aujourd'hui, de qté × (cours − cours de la veille)" : "Le coffre ne fournit aucune cotation du jour pour tes titres" },
        { label: "Plus/moins-value latente", value: grandCost > 0 ? signMoney(pv, "FCFA") : null, delta: grandCost > 0 ? (varTxt((pv / grandCost) * 100) + " sur le prix de revient" + (costKnown ? "" : " (PRU manquant sur certaines lignes)")) : "PRU absent du relevé", tone: grandCost > 0 ? toneOf(pv) : "", tip: "Valeur au cours − quantité × PRU" },
      ]));
    }
    /* LOT E : clôture figée par le moteur (dernier relevé de fin de séance, clé « cloture » du coffre). */
    const clo = (j && j.cloture && typeof j.cloture === "object") ? j.cloture : null;
    if (clo && Array.isArray(clo.lignes) && clo.lignes.length) {
      const head = h("div", { class: "moi-fin-acc-head" },
        h("span", { class: "ds-h3" }, "Clôture — " + (clo.day ? fmtDateFR(clo.day) : "")),
        h("span", { class: "ds-meta" }, (clo.manuel ? "relevé manuel" : "relevé automatique") + (clo.quotes_at ? " · cours du " + fmtDateFR(clo.quotes_at) + " " + fmtTimeFR(clo.quotes_at) : "") + (clo.cout_partiel ? " · PRU manquant sur certaines lignes" : "")));
      const sum = h("div", { class: "ds-meta moi-fin-note" },
        "Valeur : " + fmtMoneyFR(clo.valeur_totale || 0, "FCFA")
        + (clo.pv != null ? " · +/− latente : " + signMoney(clo.pv, "FCFA") + " (" + varTxt(clo.pv_pct) + " vs prix de revient)" : "")
        + (clo.jour_pct != null ? " · séance : " + varTxt(clo.jour_pct) : ""));
      const tab = h("div", { class: "ds-table-wrap moi-fin-pw" }, h("table", { class: "ds-table" },
        h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "Titre"), h("th", { class: "num", scope: "col" }, "Qté"), h("th", { class: "num", scope: "col" }, "PRU"), h("th", { class: "num", scope: "col" }, "Clôture"), h("th", { class: "num", scope: "col" }, "Var. jour"), h("th", { class: "num", scope: "col" }, "Valeur (FCFA)"), h("th", { class: "num", scope: "col" }, "+/− vs PRU"))),
        h("tbody", {}, ...clo.lignes.map((L) => {
          return h("tr", {},
            h("td", { class: "moi-fin-sym" }, String(L.sym || L.name || "—"), L.name ? h("span", { class: "moi-fin-pname" }, String(L.name)) : null),
            h("td", { class: "num" }, fmtNumFR(L.qty || 0)),
            h("td", { class: "num" }, L.pru ? fmtMoneyFR(L.pru, "") : "—"),
            h("td", { class: "num" }, fmtMoneyFR(L.cours || 0, ""), L.cotation ? null : h("span", { class: "moi-fin-star" }, " *")),
            h("td", { class: "num moi-fin-v " + (L.var_jour != null ? toneOf(L.var_jour) : "") }, L.var_jour != null ? varTxt(L.var_jour) : "—"),
            h("td", { class: "num" }, fmtMoneyFR(L.valeur || 0, "")),
            h("td", { class: "num moi-fin-v " + (L.pv == null ? "" : toneOf(L.pv)) }, L.pv == null ? "—" : signMoney(L.pv) + " (" + varTxt(L.pv_pct) + ")"));
        }))));
      kids.push(ds.card({ class: "moi-fin-cloture" }, head, sum, tab));
    }
    if (j && j.last_error) kids.push(ds.errorBox({ title: "Dernier import en échec", cause: maskText(String(j.last_error)) }));
    if (!accounts.length) kids.push(ds.card({}, ds.empty({ icon: "file", text: "Aucun compte enregistré. Importe un relevé SBIF (PDF), saisis une position, ou dépose le relevé dans " + String((j && j.watch) || "~/Nova-Finances") + " (lu toutes les 60 s).", action: { label: "Importer ou saisir", primary: true, onClick: () => { const d = portContent.querySelector(".moi-fin-edit"); if (d) { d.open = true; d.scrollIntoView({ block: "nearest" }); const f = d.querySelector("input"); if (f) f.focus(); } } } })));
    if (blocks.length) kids.push(ds.card({ class: "moi-fin-accs" }, ...blocks, h("div", { class: "ds-meta moi-fin-note" }, "* cours du relevé (pas de cotation BRVM trouvée pour ce symbole). Information uniquement — ni conseil ni ordre.")));
    kids.push(editorBox());
    portContent.replaceChildren(...kids);
    if (lastQuotes) renderQuotes(lastQuotes);   // « Mes valeurs » et les liserés du graphique suivent le portefeuille
    alerts.refreshHist();   // LOT3 : les valeurs détenues entrent au suivi (coffre ouvert seulement)
    setTimeout(() => { try { alerts.autoHeld(5); } catch (e) {} }, 1500);   // 29/10 : ±5 % sur chaque valeur détenue
  }
  /* Saisie / import (POST /api/portfolio/import {path:"~/…pdf"} ; /manual {account,kind,cash,total_releve,positions:[{name,sym,qty,cmp,cours}]}
     REMPLACE le compte entier → on renvoie toujours le compte complet fusionné ; /remove {account} retire un compte). */
  const accountPayload = (a, positions) => ({ account: a.account, kind: a.kind || "Compte", cash: Number(a.cash) || 0, invested: Number(a.invested) || 0, total_releve: 0,
    positions: positions.map((p) => ({ name: p.name || p.sym, sym: p.sym || "", qty: Number(p.qty) || 0, cmp: Number(p.cmp) || 0, cours: Number(p.cours_releve) || 0 })) });
  const accOf = (name) => (lastPort && lastPort.accounts && lastPort.accounts[name]) || null;
  async function portPost(path, body, okMsg) {
    try { await api.post(path, body); ctx.toast(okMsg); }
    catch (e) { ctx.toast("Portefeuille : " + String((e && e.message) || e).replace(/^\/api\/portfolio\/\w+ → /, ""), true); return false; }
    await loadPortfolio(); return true;
  }
  function removeAccount(name) {
    if (!confirm("Retirer le compte « " + maskText(name) + " » du portefeuille ? (le relevé n'est pas supprimé du disque)")) return;
    portPost("/api/portfolio/remove", { account: name }, "Compte « " + maskText(name) + " » retiré.");
  }
  function removePosition(name, pos) {
    const a = accOf(name); if (!a) return;
    if (!confirm("Retirer " + (pos.sym || pos.name) + " du compte « " + maskText(name) + " » ?")) return;
    portPost("/api/portfolio/manual", accountPayload(a, (a.positions || []).filter((p) => p !== pos)), "Ligne retirée.");
  }
  function editorBox() {
    const pathIn = h("input", { type: "text", class: "fld", placeholder: "~/Downloads/releve-SBIF.pdf", "aria-label": "Chemin du relevé PDF" });
    const accIn = h("input", { type: "text", class: "fld", placeholder: "Compte (ex. SBIF titres)", "aria-label": "Compte", list: "fin-accounts" });
    const symIn = h("input", { type: "text", class: "fld", placeholder: "Symbole (ex. SNTS)", "aria-label": "Symbole BRVM" });
    const nameIn = h("input", { type: "text", class: "fld", placeholder: "Nom (facultatif)", "aria-label": "Nom du titre" });
    const qtyIn = h("input", { type: "text", class: "fld", inputmode: "decimal", placeholder: "Quantité", "aria-label": "Quantité" });
    const cmpIn = h("input", { type: "text", class: "fld", inputmode: "decimal", placeholder: "PRU (FCFA)", "aria-label": "Prix de revient unitaire" });
    const cashIn = h("input", { type: "text", class: "fld", inputmode: "decimal", placeholder: "Liquidités (facultatif)", "aria-label": "Liquidités du compte" });
    const names = Object.keys((lastPort && lastPort.accounts) || {});
    const dl = h("datalist", { id: "fin-accounts" }, ...names.map((n) => h("option", { value: n })));
    async function doImport() {
      const p = pathIn.value.trim();
      if (!/^~\/.+\.pdf$/i.test(p) && !/^\/Users\/.+\.pdf$/i.test(p)) { ctx.toast("Indique un PDF dans ton dossier personnel, ex. ~/Downloads/releve.pdf", true); return; }
      if (await portPost("/api/portfolio/import", { path: p }, "Relevé importé.")) pathIn.value = "";
    }
    async function doAdd() {
      const acc = accIn.value.trim(), sym = symIn.value.trim().toUpperCase(), nm = nameIn.value.trim();
      const qty = numIn(qtyIn.value), cmp = numIn(cmpIn.value), cash = cashIn.value.trim() ? numIn(cashIn.value) : null;
      if (!acc) { ctx.toast("Indique le compte.", true); return; }
      if ((sym || nm) && !(qty > 0)) { ctx.toast("Quantité invalide.", true); return; }
      if ((sym || nm) && !(cmp >= 0)) { ctx.toast("PRU invalide.", true); return; }
      if (cash != null && !isFinite(cash)) { ctx.toast("Liquidités invalides.", true); return; }
      const a = accOf(acc) || { account: acc, kind: "Compte", cash: 0, positions: [] };
      let positions = (a.positions || []).slice();
      if (sym || nm) {
        const i = positions.findIndex((p) => (sym && p.sym === sym) || (!sym && p.name === nm));
        const np = { name: nm || (i >= 0 ? positions[i].name : sym), sym, qty, cmp, cours_releve: 0 };
        if (i >= 0) positions[i] = np; else positions.push(np);
      } else if (cash == null) { ctx.toast("Rien à enregistrer : symbole + quantité, ou liquidités.", true); return; }
      const body = accountPayload({ ...a, cash: cash != null ? cash : a.cash }, positions);
      if (await portPost("/api/portfolio/manual", body, (sym || nm) ? "Position enregistrée (" + (sym || nm) + ")." : "Liquidités enregistrées.")) { symIn.value = nameIn.value = qtyIn.value = cmpIn.value = cashIn.value = ""; }
    }
    const onEnter = (fn) => (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); fn(); } };
    pathIn.addEventListener("keydown", onEnter(doImport));
    [accIn, symIn, nameIn, qtyIn, cmpIn, cashIn].forEach((el) => el.addEventListener("keydown", onEnter(doAdd)));
    const f = ds.fold("Importer un relevé ou saisir une position", [
      h("div", { class: "moi-fin-ed" },
        h("label", { class: "ds-meta" }, "Relevé SBIF (PDF dans ton dossier personnel)"),
        h("div", { class: "moi-fin-ed-line" }, pathIn, ds.action({ label: "Importer", onClick: doImport }))),
      h("div", { class: "moi-fin-ed" },
        h("label", { class: "ds-meta" }, "Saisie manuelle — une ligne existante (même symbole) est remplacée"),
        dl, h("div", { class: "moi-fin-ed-grid" }, accIn, symIn, nameIn, qtyIn, cmpIn, cashIn),
        h("div", {}, ds.action({ label: "Enregistrer la position", primary: true, onClick: doAdd })))]);
    f.classList.add("moi-fin-edit");
    return f;
  }
  async function loadPortfolio() {
    if (!portContent.childElementCount) portContent.replaceChildren(ds.skeleton(3));
    try {
      const j = await api.get("/api/portfolio");
      if (dead) return;
      renderPortfolio(j);
    } catch (e) {
      if (dead) return;
      const locked = /423|verrouillé/i.test(String((e && e.message) || e));
      if (locked) {
        portContent.replaceChildren(ds.card({ class: "moi-fin-lock" }, ds.empty({ compact: true, icon: "lock", text: "Coffre refermé — déverrouille pour voir ton portefeuille.", action: { label: "Déverrouiller", primary: true, icon: "lock", onClick: () => ctx.refresh() } })));
      } else {
        portContent.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé le portefeuille.", retry: () => loadPortfolio() }));
      }
    }
  }
  /* Dividendes saisis (le moteur les joint aux cours) : affichés avec leur source, jamais recalculés.
     Section absente si le moteur n'en connaît aucun. */
  function renderDividends(j) {
    const divs = arrOf(j, "dividends");
    divSec.hidden = !divs.length;
    setCnt(divSec, divs.length || "");
    if (!divs.length) { divSec.body.replaceChildren(); return; }
    divSec.body.replaceChildren(h("div", { class: "ds-list" }, ...divs.slice(0, 10).map((d) => ds.row({
      lead: "chart",
      title: String(d.sym || d.symbol || "—") + (d.name ? " · " + String(d.name) : ""),
      meta: d.date || d.when ? "date annoncée : " + fmtDateFR(d.date || d.when) : null,
      side: h("b", { class: "ds-num" }, d.amount != null ? fmtMoneyFR(d.amount, "FCFA") + " / action" : String(d.text || "—")),
    }))));
  }
  /* Coûts des cerveaux (GET /api/couts) — Feat_Couts.swift Couts.report → { jours, brains:[{brain,model,calls,ok,fail,in,out,ms_avg,usd}],
     total:{calls,usd}, days, today, note } : chiffres du moteur, aucun calcul local. */
  async function loadCouts() {
    if (!coutSec.body.childElementCount) coutSec.body.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.get("/api/couts?jours=7");
      if (dead) return;
      const rows = Array.isArray(j && j.brains) ? j.brains : [];
      const total = j && j.total && typeof j.total === "object" ? j.total : null;
      const usdTxt = (v) => { const n = Number(v); if (!isFinite(n)) return "—"; if (n === 0) return "0 USD"; return n > 0 && n < 0.01 ? "< 0,01 USD" : fmtMoneyFR(n, "USD"); };
      const fails = rows.reduce((s, r) => s + (Number(r.fail) || 0), 0);
      const jours = Number(j && j.jours) || 7;
      coutSec.querySelector(".ds-h2").textContent = "Coûts IA — " + fmtNumFR(jours) + " derniers jours";
      setCnt(coutSec, rows.length || "");
      coutSec.body.replaceChildren(
        ds.kpis([
          { label: "Dépense" + (j && j.estimation ? " (estimation)" : ""), value: total ? usdTxt(total.usd) : null },
          { label: "Appels", value: total ? fmtNumFR(total.calls) : null },
          { label: "Échecs", value: fmtNumFR(fails), tone: fails ? "warn" : "", delta: total && Number(total.calls) ? fmtPctFR((fails / Number(total.calls)) * 100) + " des appels" : "" },
        ]),
        rows.length ? h("div", { class: "ds-table-wrap" }, h("table", { class: "ds-table" },
          h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "Cerveau"), h("th", { class: "num", scope: "col" }, "Appels"), h("th", { class: "num", scope: "col" }, "Échecs"), h("th", { class: "num", scope: "col" }, "Coût"))),
          h("tbody", {}, ...rows.slice().sort((a, b) => (Number(b.usd) || 0) - (Number(a.usd) || 0)).slice(0, 12).map((r) => h("tr", {},
            h("td", {}, h("span", { class: "moi-fin-brain" }, brainLabel(r.brain)), r.model ? h("span", { class: "ds-meta moi-fin-model" }, String(r.model)) : null),
            h("td", { class: "num" }, fmtNumFR(r.calls)),
            h("td", { class: "num" + (Number(r.fail) ? " moi-fin-v warn" : " muted") }, fmtNumFR(r.fail || 0)),
            h("td", { class: "num" }, usdTxt(r.usd)))))))
          : ds.empty({ compact: true, icon: "chart", text: "Aucun coût enregistré sur la période (cerveaux gratuits ou locaux)." }),
        j && j.note ? h("p", { class: "ds-meta moi-fin-note" }, String(j.note)) : null);
    } catch (e) {
      if (dead) return;
      coutSec.body.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé les coûts des cerveaux.", retry: () => loadCouts() }));
    }
  }
  async function refreshAll(manual) {
    if (!vaultIsUnlocked()) {   // C-01 : aucun appel protégé avant le jeton — seuls les cours publics sont relus
      if (manual) { refreshBtn.disabled = true; try { await loadQuotes(); } catch (e) {} refreshBtn.disabled = false; }
      return;
    }
    if (manual) { refreshBtn.disabled = true; try { await api.post("/api/portfolio/refresh", {}); } catch (e) {} refreshBtn.disabled = false; }
    loadQuotes(); loadPortfolio(); loadCouts();
  }
  let stop = () => {};
  let started = false;
  function start() {   // E3 : aucun chargement protégé avant l'ouverture du coffre
    if (started) return; started = true;
    coutSec.hidden = false;
    loadPortfolio(); loadCouts();
  }
  /* Cours publics : chargés tout de suite et toutes les 60 s, coffre ouvert ou non. */
  loadQuotes();
  stop = every(60000, () => loadQuotes());   // sobre : suspendu si caché (core.every), tué au démontage
  return () => { dead = true; stop(); try { if (ro) ro.disconnect(); } catch (e) {} vaultLock(); };   // E3 : verrouillage auto au changement d'écran
}
