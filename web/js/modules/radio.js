/* Module Médias — TV en direct, radios et podcasts, Afrique d'abord.
   V5-R (25/10/2026, audit conseil_24-10/V5_R_MEDIAS_AUDIT.md) : refonte de l'écran SUR le moteur
   existant (aucune route moteur modifiée) :
   - TV : index iptv-org public (api/channels.json + streams.json + blocklist.json, logos.json en
     arrière-plan) réduit aux 54 pays africains, fusionné avec le catalogue Nova du moteur
     (/api/tv/channels?country=tout — les 65 chaînes testées le 20/10, épinglées « Vérifiées »).
     Navigation par pays (régions Ouest / Centre / Est / Nord / Australe + International), par genre,
     favoris, récents, recherche instantanée (nom, pays, genre). Index mis en cache (localStorage,
     7 jours, bouton Actualiser) : hors ligne, l'écran vit sur le cache, et sans cache sur le catalogue
     moteur.
   - Stabilité : le lecteur est celui d'avant (hls.js à la demande, relais local /api/stream, erreurs
     nommées, reconnexions par cause, reconnexion lente, lecteur flottant du shell) + BASCULE
     AUTOMATIQUE entre les flux alternatifs d'une même chaîne quand un flux n'a jamais démarré.
     Le relais moteur n'accepte que les racines servies par /api/tv/channels : avant de lire une chaîne
     de l'index, le module appelle /api/tv/channels?country=<pays> (la playlist pays iptv-org, mêmes URL)
     — si le relais refuse quand même (403), lecture directe du flux.
   - Santé : sonde moteur /api/tv/check?u= (accepte toute URL), paresseuse, 6 en vol, flux par flux ;
     résultats mémorisés avec leur heure. Statut affiché UNIQUEMENT s'il a été mesuré, sinon
     « non testée ». Les chaînes dont tous les flux ont échoué au dernier test coulent en fin de liste
     (repliées), restent lançables.
   - Radios : Radio Browser en direct (miroirs de1 → de2 → all), repli moteur /api/radio/search ;
     pays, genres, recherche, favoris, récents, bascule url_resolved → url à l'erreur, stations muettes
     coulées.
   - Podcasts : iTunes (classement par pays + recherche, sans clé), épisodes via le moteur
     /api/podcast/episodes (flux RSS, pas de CORS), reprise de position par épisode.
   - 18+ : uniquement si Réglages › Général › « Contenus adultes (18+) » est activé ET confirmé
     (nova2_media_adult + nova2_media_adult_ack) ; sinon jamais chargé, listé, cherché ni suggéré.
     Seuls les flux de l'index public iptv-org marqués is_nsfw / xxx — rien d'autre.
   Hérités et conservés : B-01 (erreur DANS le lecteur), B-05 (état de lecture issu des vrais
   événements), §52 / W-23 (reconnexions par cause), §55 (hls.js), FIXPREP D-R4 (relais), TV-RELANCE
   (une chaîne « morte » reste lançable), V5-N (hls.js chargé à la demande). */
import { TV_CHECK_BOUND_MS } from "../core.js";
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };

/* ── hls.js à la demande (V5-N) ─────────────────────────────────────────── */
let hlsP = null, hlsDone = false;
function loadHls() {
  if (window.Hls) { hlsDone = true; return Promise.resolve(true); }
  if (hlsP) return hlsP;
  const add = (src, sri) => new Promise((res) => {
    const s = document.createElement("script");
    s.src = src; s.async = true;
    if (sri) { s.integrity = sri; s.crossOrigin = "anonymous"; }
    s.onload = () => res(!!window.Hls); s.onerror = () => res(false);
    document.head.append(s);
  });
  hlsP = add(new URL("../../vendor/hls.min.js", import.meta.url).href)
    .then((ok) => ok || add("https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js", "sha384-w6Gb3fXHb5e1LUYa/hYA5Q41bEDglN5ZPCG7Jvnoo8/X90oGnlPqBlBJCe38mEMm"))
    .then((ok) => { hlsDone = true; return ok; });
  return hlsP;
}

/* ── Stockage local (jamais bloquant) ───────────────────────────────────── */
const LS = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch (e) { return false; } },
};
const adultOn = () => { try { return localStorage.getItem("nova2_media_adult") === "1" && localStorage.getItem("nova2_media_adult_ack") === "1"; } catch (e) { return false; } };

/* ── Géographie : les 54 pays africains par région (géoschéma ONU) ──────── */
const REGIONS = [
  { k: "ouest", l: "Afrique de l'Ouest", cc: ["BF", "BJ", "CI", "CV", "GH", "GM", "GN", "GW", "LR", "ML", "MR", "NE", "NG", "SL", "SN", "TG"] },
  { k: "centre", l: "Afrique centrale", cc: ["AO", "CD", "CF", "CG", "CM", "GA", "GQ", "ST", "TD"] },
  { k: "est", l: "Afrique de l'Est", cc: ["BI", "DJ", "ER", "ET", "KE", "KM", "MG", "MU", "MW", "MZ", "RW", "SC", "SO", "SS", "TZ", "UG", "ZM", "ZW"] },
  { k: "nord", l: "Afrique du Nord", cc: ["DZ", "EG", "LY", "MA", "SD", "TN"] },
  { k: "australe", l: "Afrique australe", cc: ["BW", "LS", "NA", "SZ", "ZA"] },
];
const AFRICA = new Set(REGIONS.flatMap((r) => r.cc));
const AFRICA_EXTRA = new Set(["EH", "RE", "YT"]);   // territoires présents dans l'index iptv-org : rangés avec leur région
REGIONS[3].cc.push("EH"); REGIONS[2].cc.push("RE", "YT");
let dn = null; try { dn = new Intl.DisplayNames(["fr"], { type: "region" }); } catch (e) { dn = null; }
const countryName = (cc) => { const c = String(cc || "").toUpperCase(); if (!c) return ""; if (c === "INTL") return "International"; try { return (dn && dn.of(c)) || c; } catch (e) { return c; } };
const flag = (cc) => { const c = String(cc || "").toUpperCase(); if (!/^[A-Z]{2}$/.test(c)) return "🌍"; return String.fromCodePoint(...[...c].map((x) => 0x1F1E6 + x.charCodeAt(0) - 65)); };
const isAfrican = (cc) => AFRICA.has(cc) || AFRICA_EXTRA.has(cc);

/* Genres iptv-org (categories.json), libellés français. */
const GENRES = {
  general: "Généraliste", news: "Infos", sports: "Sport", music: "Musique", kids: "Jeunesse", religious: "Religion",
  entertainment: "Divertissement", movies: "Films", series: "Séries", documentary: "Documentaires", culture: "Culture",
  education: "Éducation", business: "Économie", lifestyle: "Art de vivre", comedy: "Humour", cooking: "Cuisine",
  family: "Famille", legislative: "Parlementaire", public: "Service public", travel: "Voyage", science: "Sciences",
  weather: "Météo", outdoor: "Plein air", shop: "Télé-achat", auto: "Auto", animation: "Animation", classic: "Classiques",
  relax: "Détente", interactive: "Interactif", xxx: "Adultes (18+)", none: "Non classées",
};
const genreLabel = (g) => GENRES[g] || g;
const STATIC_CATS = { Infos: "news", Sport: "sports", Musique: "music", Jeunesse: "kids" };

/* ── Index iptv-org MONDIAL (ordre d'Ahadi 25/10 : tout l'index, Afrique en tête) ──
   Toutes les chaînes ayant au moins un flux dans streams.json, tous pays, toutes catégories ; les flux
   sans chaîne rattachée (channel: null) sont gardés en « pays inconnu ». Seul filtre : blocklist.json,
   la liste de retrait d'iptv-org elle-même (DMCA / nsfw retirés) — jamais une curation de Nova.
   Stockage : IndexedDB (≈ 2 Mo, au-delà du confort de localStorage), repli localStorage, chaque accès
   sous try/catch ; un seul téléchargement en vol, partagé entre montages. */
const IPTV = "https://iptv-org.github.io/api/";
const IDX_KEY = "tvidx_v2", LOGO_KEY = "logos_v2", REG_KEY = "nova2_media_regions_v1";
const STATIC_KEY = "nova2_media_tvstatic_v1", HEALTH_KEY = "nova2_media_health_v1";
const IDX_MAX_AGE = 7 * 24 * 3600e3;
const IDB = (() => {
  let p = null;
  const open = () => p || (p = new Promise((res, rej) => {
    try { const r = indexedDB.open("nova2_media", 1); r.onupgradeneeded = () => { try { r.result.createObjectStore("kv"); } catch (e) {} }; r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); r.onblocked = () => rej(new Error("base bloquée")); }
    catch (e) { rej(e); }
  }));
  return {
    async get(k) {
      try { const db = await open(); return await new Promise((res) => { try { const t = db.transaction("kv").objectStore("kv").get(k); t.onsuccess = () => res(t.result == null ? null : t.result); t.onerror = () => res(null); } catch (e) { res(null); } }); }
      catch (e) { return LS.get("nova2_media_" + k, null); }
    },
    async set(k, v) {
      try { const db = await open(); await new Promise((res, rej) => { const tx = db.transaction("kv", "readwrite"); tx.objectStore("kv").put(v, k); tx.oncomplete = () => res(); tx.onerror = () => rej(tx.error); tx.onabort = () => rej(tx.error); }); return true; }
      catch (e) { return LS.set("nova2_media_" + k, v); }
    },
  };
})();
async function fetchJSON(url, ms = 20000) {
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), ms);
  try { const r = await fetch(url, { signal: ctl.signal }); if (!r.ok) throw new Error("HTTP " + r.status); return await r.json(); }
  catch (e) { if (e && e.name === "AbortError") throw new Error("délai dépassé (" + Math.round(ms / 1000) + " s)"); throw e; }
  finally { clearTimeout(t); }
}
/* Continents (regions.json d'iptv-org) pour ranger les pays hors Afrique. */
const WORLD = [{ k: "EUR", l: "Europe" }, { k: "AMER", l: "Amériques" }, { k: "ASIA", l: "Asie et Moyen-Orient" }, { k: "OCE", l: "Océanie" }];
let idxBuild = null;
function buildIndex() {
  if (idxBuild) return idxBuild;
  idxBuild = (async () => {
    const [channels, streams, blocklist, regions] = await Promise.all([
      fetchJSON(IPTV + "channels.json", 150000), fetchJSON(IPTV + "streams.json", 150000),
      fetchJSON(IPTV + "blocklist.json", 30000).catch(() => []), fetchJSON(IPTV + "regions.json", 30000).catch(() => []),
    ]);
    const cont = {};
    for (const w of WORLD) { const r = arrOf(regions).find((x) => x && x.code === w.k); if (r && Array.isArray(r.countries)) for (const cc of r.countries) if (!cont[cc]) cont[cc] = w.k; }
    LS.set(REG_KEY, cont);
    const blocked = new Set(arrOf(blocklist).map((b) => b && b.channel).filter(Boolean));
    const chMap = new Map(); for (const c of arrOf(channels)) if (c && c.id) chMap.set(c.id, c);
    const all = new Map();
    for (const s of arrOf(streams)) {
      const url = String((s && s.url) || "");
      if (!/^https?:\/\//i.test(url)) continue;
      const c = s.channel ? chMap.get(s.channel) : null;
      if (c && blocked.has(c.id)) continue;
      let id, ch;
      if (c) {
        id = c.id; ch = all.get(id);
        if (!ch) {
          const cats = Array.isArray(c.categories) ? c.categories.filter(Boolean) : [];
          const adult = !!c.is_nsfw || cats.includes("xxx");
          ch = { id, n: String(c.name || id), cc: String(c.country || "").toUpperCase(), c: adult && !cats.includes("xxx") ? [...cats, "xxx"] : cats, a: adult ? 1 : 0, s: [] };
          if (c.closed) ch.x = 1;   // fermée selon iptv-org : signalée, pas retirée
          all.set(id, ch);
        }
      } else {
        id = "s:" + url; if (all.has(id)) continue;
        ch = { id, n: String((s && s.title) || "Flux sans nom"), cc: "", c: [], a: 0, s: [] }; all.set(id, ch);
      }
      if (ch.s.some((x) => x.u === url)) continue;
      const st = { u: url };
      if (s.quality) st.q = String(s.quality);
      if (Array.isArray(s.labels) && s.labels.length) st.l = s.labels;
      if (s.user_agent || s.referrer) st.h = 1;
      ch.s.push(st);
    }
    const out = { at: Date.now(), all: [...all.values()] };
    await IDB.set(IDX_KEY, out);
    /* Logos : 5,7 Mo — en arrière-plan, sans retarder la liste ; on ne garde que nos chaînes. */
    fetchJSON(IPTV + "logos.json", 150000).then(async (logos) => {
      const m = {};
      for (const l of arrOf(logos)) {
        if (!l || !all.has(l.channel) || !/^https:\/\//i.test(String(l.url || ""))) continue;
        if (!m[l.channel] || (!l.feed && l.in_use !== false)) m[l.channel] = l.url;
      }
      await IDB.set(LOGO_KEY, m);
      window.dispatchEvent(new CustomEvent("nova:media-logos"));
    }).catch(() => {});
    return out;
  })();
  idxBuild.finally(() => { idxBuild = null; });
  return idxBuild;
}

/* Pré-autorisation du relais moteur (voir en-tête) : une fois par pays et par session. */
const relayAuth = new Map();

export async function mount(root, ctx) {
  loadHls();
  const { api, bus, h, ic } = ctx;
  let dead = false;
  const cleanups = [];
  root.classList.add("mod--data", "mx");
  root.append(h("div", { class: "mod-head" },
    h("h1", {}, "Médias"),
    h("span", { class: "sub" }, "TV en direct, radios et podcasts — les 54 pays d'Afrique et le monde")));

  const stateError = (label, err, retry) => h("div", { class: "state-error", role: "alert" },
    h("span", { html: ic("alert", 16) }),
    h("span", { class: "grow" }, label + (err ? " — " + String((err && err.message) || err).slice(0, 90) : "")),
    retry ? h("button", { class: "btn sm", onclick: () => retry() }, "Réessayer") : null);
  const emptyState = (icon, text, ...extra) => h("div", { class: "empty" },
    h("span", { class: "empty-ic", html: ic(icon, 20) }),
    h("span", { class: "ss--wrap" }, text), ...extra);
  const fmtClock = (t) => { try { const d = new Date(t); const today = new Date().toDateString() === d.toDateString(); return (today ? "" : d.toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit" }) + " ") + d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); } catch (e) { return ""; } };
  const fmtDur = (s) => { s = Math.max(0, Math.round(Number(s) || 0)); const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60; return (hh ? hh + ":" + String(mm).padStart(2, "0") : mm) + ":" + String(ss).padStart(2, "0"); };
  const norm = (s) => String(s || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const sameUrl = (a, b) => { if (!a || !b) return false; try { return new URL(a, location.href).href === new URL(b, location.href).href; } catch (e) { return a === b; } };
  const scrollParent = (el) => { for (let n = el && el.parentElement; n; n = n.parentElement) { const o = getComputedStyle(n).overflowY; if ((o === "auto" || o === "scroll") && n.scrollHeight > n.clientHeight) return n; } return document.scrollingElement || document.documentElement; };
  const debounce = (fn, ms) => { let t = 0; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
  /* Segment exclusif (DS §6.16). */
  function segCtl(opts, value, onpick, label) {
    const el = h("div", { class: "seg mx-seg", role: "group", "aria-label": label });
    const btns = {};
    for (const [k, l, icon] of opts) {
      const b = h("button", { class: k === value ? "on" : "", "aria-pressed": k === value ? "true" : "false", onclick: () => { set(k); onpick(k); } },
        ...(icon ? [h("span", { html: ic(icon, 13) }), " " + l] : [l]));
      btns[k] = b; el.append(b);
    }
    function set(k) { for (const [kk, b] of Object.entries(btns)) { b.className = kk === k ? "on" : ""; b.setAttribute("aria-pressed", kk === k ? "true" : "false"); } }
    el.set = set;
    return el;
  }
  /* Grille de pays : l'Afrique d'abord (54 pays, régions ONU, tous affichés même à 0), puis le monde
     par continent (regions.json d'iptv-org), replié pour rester léger. */
  const openWorld = new Set();
  function countryGrid(counts, onpick, unit, extra, pend) {
    pend = pend || {};
    const tile = (cc, n, name, fl, p) => h("button", { class: "mx-cc" + (n ? "" : " zero"), title: name + " — " + n + " " + unit + (p ? " · " + p + " encore à vérifier" : ""), onclick: () => onpick(cc) },
      h("span", { class: "fl", "aria-hidden": "true" }, fl || flag(cc)), h("span", { class: "nm" }, name), h("span", { class: "ct" }, n ? n.toLocaleString("fr-FR") + (p ? " …" : "") : (p ? "…" : "0")));
    const wrap = h("div", { class: "mx-regions" });
    for (const r of REGIONS) {
      /* Ordre d'Ahadi : un pays vérifié sans aucune chaîne joignable disparaît de la grille ;
         ceux encore en vérification (« … ») restent, après ceux qui marchent. */
      const tiles = r.cc.filter((cc) => counts[cc] || pend[cc]).map((cc) => ({ cc, n: counts[cc] || 0, p: pend[cc] || 0, name: countryName(cc) }))
        .sort((x, y) => (y.n > 0) - (x.n > 0) || x.name.localeCompare(y.name, "fr"));
      if (!tiles.length) continue;
      wrap.append(h("section", { class: "mx-region" },
        h("h3", { class: "mx-rtitle" }, r.l, h("span", { class: "ss" }, " · " + tiles.reduce((t, x) => t + x.n, 0).toLocaleString("fr-FR") + " " + unit)),
        h("div", { class: "mx-ccgrid" }, ...tiles.map((t) => tile(t.cc, t.n, t.name, null, t.p)))));
    }
    const cont = LS.get(REG_KEY, {}) || {};
    const groups = {};
    for (const cc of new Set([...Object.keys(counts), ...Object.keys(pend)])) {
      if (!cc || cc === "??" || isAfrican(cc) || !(counts[cc] || pend[cc])) continue;
      const k = cont[cc] || "AUTRES"; (groups[k] = groups[k] || []).push({ cc, n: counts[cc] || 0, p: pend[cc] || 0, name: countryName(cc) });
    }
    const worldSecs = [...WORLD, { k: "AUTRES", l: "Autres pays" }].filter((w) => groups[w.k]).map((w) => {
      const tiles = groups[w.k].sort((x, y) => (y.n > 0) - (x.n > 0) || x.name.localeCompare(y.name, "fr"));
      const d = h("details", { class: "mx-region mx-world" }, h("summary", { class: "mx-rtitle" }, w.l, h("span", { class: "ss" }, " · " + tiles.length + " pays · " + tiles.reduce((t, x) => t + x.n, 0).toLocaleString("fr-FR") + " " + unit)));
      let filled = false;
      const fill = () => { if (!filled) { filled = true; d.append(h("div", { class: "mx-ccgrid" }, ...tiles.map((t) => tile(t.cc, t.n, t.name, null, t.p)))); } };
      d.addEventListener("toggle", () => { if (d.open) { openWorld.add(w.k); fill(); } else openWorld.delete(w.k); });
      if (openWorld.has(w.k)) { d.open = true; fill(); }
      return d;
    });
    const special = (extra || []).filter((x) => x.n || x.p);
    if (worldSecs.length || special.length) wrap.append(h("h3", { class: "mx-rtitle mx-worldhead" }, "Monde"), ...worldSecs);
    if (special.length) wrap.append(h("div", { class: "mx-ccgrid" }, ...special.map((x) => tile(x.cc, x.n, x.label, x.fl, x.pend || x.p))));
    return wrap;
  }
  const crumb = (back, backLabel, ...title) => h("div", { class: "mx-crumb" },
    back ? h("button", { class: "btn sm ghost", onclick: back, "aria-label": "Retour : " + backLabel }, h("span", { html: ic("back", 14) }), " " + backLabel) : null,
    h("div", { class: "mx-crumb-t" }, ...title));

  /* ── Onglets TV / Radios / Podcasts ─────────────────────────────────── */
  const tvPanel = h("div", { class: "mx-panel", role: "tabpanel", "aria-label": "TV en direct" });
  const radioPanel = h("div", { class: "mx-panel", role: "tabpanel", "aria-label": "Radios" });
  const podPanel = h("div", { class: "mx-panel", role: "tabpanel", "aria-label": "Podcasts" });
  const panels = { tv: tvPanel, radio: radioPanel, podcast: podPanel };
  let tab = LS.get("nova2_media_tab", "tv"); if (!panels[tab]) tab = "tv";
  const started = {};
  const tabs = segCtl([["tv", "TV en direct", "video"], ["radio", "Radios", "radio"], ["podcast", "Podcasts", "podcast"]], tab, (k) => showTab(k), "Type de média");
  tabs.classList.add("mx-tabs");
  root.append(tabs, tvPanel, radioPanel, podPanel);
  function showTab(k) {
    tab = k; LS.set("nova2_media_tab", k); tabs.set(k);
    for (const [kk, p] of Object.entries(panels)) p.hidden = kk !== k;
    if (!started[k]) { started[k] = true; (k === "tv" ? startTV : k === "radio" ? startRadio : startPodcasts)(); }
  }

  /* ── État « en cours de lecture » (B-05) ─────────────────────────────── */
  const audioEl = document.getElementById("audio");
  let audioPlayingUrl = "", tvPlayingId = "", lastAudio = null;
  function refreshMediaMarks() {
    root.querySelectorAll("[data-play-kind]").forEach((btn) => {
      const kind = btn.getAttribute("data-play-kind");
      const name = btn.getAttribute("data-play-name") || "";
      const on = kind === "tv" ? (!!tvPlayingId && btn.getAttribute("data-play-id") === tvPlayingId) : sameUrl(btn.getAttribute("data-play-url"), audioPlayingUrl);
      const row = btn.closest(".mx-row");
      if (row) row.classList.toggle("sel", on);
      btn.innerHTML = ic(on ? "pause" : (kind === "tv" ? "video" : kind === "podcast" ? "podcast" : "play"), 16);
      btn.setAttribute("aria-label", on ? "En cours de lecture : " + name + (kind === "tv" ? " — mettre en pause" : " — arrêter la lecture") : (kind === "tv" ? "Regarder " : "Écouter ") + name);
      btn.title = btn.getAttribute("aria-label");
    });
    paintNowPlaying();
  }
  function playAudio(url, title, sub, meta) {
    if (!url) return;
    if (sameUrl(audioPlayingUrl, url)) { bus.emit("nova:player-stop", {}); return; }
    lastAudio = { url, title: title || "", sub: sub || "", ...(meta || {}) };
    bus.emit("nova:play", { url, title, sub });
    paintNowPlaying();
  }
  const offPS = bus.on("nova:player-state", (d) => {
    if (!d || dead) return;
    if (d.url) audioPlayingUrl = d.playing ? d.url : (sameUrl(audioPlayingUrl, d.url) ? "" : audioPlayingUrl);
    else if (d.playing) audioPlayingUrl = (lastAudio && (!d.title || d.title === lastAudio.title)) ? lastAudio.url : audioPlayingUrl;
    else audioPlayingUrl = "";
    refreshMediaMarks();
  });
  cleanups.push(() => { try { offPS(); } catch (e) {} });

  /* ════════════════════════════ TV ════════════════════════════════════ */
  let tvMode = LS.get("nova2_media_tv_mode", "pays"); if (!["pays", "genres", "favs", "recents"].includes(tvMode)) tvMode = "pays";
  let tvCC = LS.get("nova2_media_tv_cc", "BF"), tvGenre = "";
  let channels = [], chById = new Map(), idxInfo = { at: 0, n: 0, countries: 0, af: 0, state: "init", err: "" };
  let health = {};   // url → { ok, r, at, ms } — chargé d'IndexedDB au démarrage de l'onglet TV
  const tvQ = h("input", { type: "search", placeholder: "Chaîne, pays ou genre…", "aria-label": "Rechercher une chaîne (nom, pays ou genre)" });
  const tvModes = segCtl([["pays", "Pays"], ["genres", "Genres"], ["favs", "Favoris", "star"], ["recents", "Récents"]], tvMode, (k) => { tvMode = k; LS.set("nova2_media_tv_mode", k); tvQ.value = ""; if (k === "pays" && tvCC === "") tvCC = ""; tvGenre = ""; renderTV(); }, "Parcourir la TV");
  const tvIdxLine = h("div", { class: "mx-idx" });
  const tvResume = h("div", {});
  const tvBody = h("div", { class: "mx-body" });
  const tvVideo = h("video", { class: "tv-video", controls: "controls", playsinline: "playsinline", style: "display:none" });
  const tvErrorBox = h("div", { class: "player-error", hidden: true, role: "alert" });
  const tvPlayerWrap = h("div", {}, tvVideo, tvErrorBox);
  tvPanel.append(
    h("div", { class: "mx-bar" }, h("div", { class: "searchbox mx-search" }, h("span", { html: ic("search", 16) }), tvQ), tvModes),
    tvIdxLine, tvResume, tvPlayerWrap, tvBody);
  tvQ.addEventListener("input", debounce(() => { if (!dead) renderTV(); }, 160));
  tvQ.addEventListener("keydown", (e) => { if (e.key === "Escape") { tvQ.value = ""; renderTV(); } });

  /* Favoris (compatibles avec l'ancien format nova2_tv_favs_v1 {name,url,logo,pays,group}). */
  const FAV_KEY = "nova2_tv_favs_v1", REC_KEY = "nova2_tv_recent_v1";
  const chSnap = (c) => ({ id: c.id, name: c.name, url: (c.streams[0] || {}).u || "", logo: c.logo || "", pays: c.country || "", cc: c.cc || "", cats: c.cats || [], streams: c.streams.slice(0, 4), verified: c.verified || "", adult: !!c.adult });
  const fromSnap = (f) => {
    if (!f) return null;
    const live = (f.id && chById.get(f.id)) || channels.find((c) => c.streams.some((s) => s.u === f.url));
    if (live) return live;
    if (f.adult && !adultOn()) return null;
    const streams = Array.isArray(f.streams) && f.streams.length ? f.streams : (f.url ? [{ u: f.url }] : []);
    if (!streams.length) return null;
    return { id: f.id || ("url:" + f.url), name: String(f.name || "Chaîne"), cc: String(f.cc || "").toUpperCase(), country: f.pays || f.group || "", cats: f.cats || [], logo: f.logo || "", streams, verified: f.verified || "", pin: false, adult: !!f.adult };
  };
  const loadFavs = () => { const v = LS.get(FAV_KEY, []); return Array.isArray(v) ? v : []; };
  const isFav = (c) => loadFavs().some((f) => (f.id && f.id === c.id) || c.streams.some((s) => s.u === f.url));
  function toggleFav(c) {
    let f = loadFavs();
    if (isFav(c)) f = f.filter((x) => !((x.id && x.id === c.id) || c.streams.some((s) => s.u === x.url)));
    else f.push(chSnap(c));
    LS.set(FAV_KEY, f);
    if (tvMode === "favs" && !tvQ.value.trim()) renderTV(); else refreshStars();
  }
  function refreshStars() {
    tvPanel.querySelectorAll("[data-fav-id]").forEach((b) => {
      const c = chById.get(b.getAttribute("data-fav-id")) || b._ch; if (!c) return;
      const on = isFav(c), name = c.name;
      b.classList.toggle("acc", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
      b.setAttribute("aria-label", (on ? "Retirer des favoris : " : "Ajouter aux favoris : ") + name);
      b.title = b.getAttribute("aria-label");
    });
  }
  function pushRecent(c) {
    const r = (LS.get(REC_KEY, []) || []).filter((x) => x && x.id !== c.id);
    r.unshift({ ...chSnap(c), at: Date.now() });
    LS.set(REC_KEY, r.slice(0, 12));
    paintResume();
  }
  function paintResume() {
    const r = (LS.get(REC_KEY, []) || [])[0];
    const c = r && fromSnap(r);
    if (!c || !isOk(c) || tvPlayingId || (currentTV && currentTV.ch && currentTV.ch.id === c.id)) { tvResume.replaceChildren(); return; }
    tvResume.replaceChildren(h("div", { class: "mx-resume" },
      h("span", { html: ic("time", 15) }),
      h("div", { class: "grow" }, h("div", { class: "tt" }, "Reprendre : " + c.name), h("div", { class: "ss" }, [c.country, r.at ? "regardée le " + fmtClock(r.at) : ""].filter(Boolean).join(" · "))),
      h("button", { class: "btn sm acc", onclick: () => playTV(c) }, h("span", { html: ic("play", 13) }), " Regarder")));
  }

  /* Fusion catalogue Nova (moteur) + index iptv-org mondial. Les 18+ n'entrent dans la liste
     (donc ni dans les listes, ni dans la recherche, ni dans les genres) que si l'option est active. */
  let idxData = null, logosMap = {};
  function rebuildChannels() {
    const list = [], byUrl = new Map(), withAdult = adultOn();
    for (const raw of (idxData && idxData.all) || []) {
      if (raw.a && !withAdult) continue;
      if (raw.x) continue;   // chaîne déclarée fermée par iptv-org
      /* Pré-filtre sur les champs d'iptv-org : flux à en-têtes imposés (user_agent/referrer — le relais
         ne peut pas les fournir) et flux « Geo-blocked » (sauf Burkina, où vit Ahadi) écartés avant sonde. */
      const sts = raw.s.filter((x) => !x.h && !((x.l || []).includes("Geo-blocked") && raw.cc !== "BF"));
      if (!sts.length) continue;
      const c = { id: raw.id, name: raw.n, cc: raw.cc, country: raw.cc ? countryName(raw.cc) : "Pays non renseigné", cats: raw.c && raw.c.length ? raw.c : ["none"], logo: logosMap[raw.id] || "",
        streams: sts.map((x) => ({ u: x.u, q: x.q || "", l: x.l || [], h: false })), verified: "", pin: false, adult: !!raw.a };
      list.push(c); for (const x of c.streams) byUrl.set(x.u, c);
    }
    for (const it of staticItems || []) {
      const url = String(it.url || ""); if (!/^https?:/i.test(url)) continue;
      const cats = (Array.isArray(it.cats) ? it.cats : []).map((x) => STATIC_CATS[x]).filter(Boolean);
      const cc = String(it.cc || "").toUpperCase();
      const intl = (Array.isArray(it.cats) && it.cats.includes("Monde")) || !isAfrican(cc);
      let c = byUrl.get(url);
      if (c) {
        c.streams.sort((x, y) => (x.u === url ? -1 : y.u === url ? 1 : 0));
        c.pin = true; c.verified = String(it.verified || ""); if (!c.logo && it.logo) c.logo = it.logo;
        for (const g of cats) if (!c.cats.includes(g)) c.cats = c.cats.filter((x) => x !== "none").concat(g);
        if (intl) c.intl = true;
      } else {
        c = { id: "nova:" + url, name: String(it.name || "Chaîne"), cc, country: String(it.pays || countryName(cc)), cats: cats.length ? cats : ["general"], logo: String(it.logo || ""), streams: [{ u: url, q: "", l: [], h: false }], verified: String(it.verified || ""), pin: true, adult: false, intl };
        list.push(c); byUrl.set(url, c);
      }
    }
    /* Index de recherche : une chaîne normalisée par chaîne, calculée une fois. */
    for (const c of list) c.hay = norm(c.name + " " + c.country + " " + c.cc + " " + c.cats.map(genreLabel).join(" ") + " " + c.cats.join(" "));
    channels = list;
    chById = new Map(list.map((c) => [c.id, c]));
    idxInfo.n = list.filter((c) => !c.adult).length;
    crawled = false;
  }
  let staticItems = LS.get(STATIC_KEY, null);
  async function loadStatic() {
    try {
      const j = await api.get("/api/tv/channels?country=tout");
      const items = arrOf(j, "items", "channels");
      if (items.length) { staticItems = items; LS.set(STATIC_KEY, items); }
    } catch (e) { /* hors ligne : on garde le cache du catalogue moteur */ }
    return staticItems || [];
  }
  function paintIdxLine() {
    const s2 = idxInfo;
    const parts = [];
    let okN = 0; for (const c of channels) if (!c.adult && isOk(c)) okN++;
    if (s2.state === "loading") parts.push(h("span", { class: "dotst run" }), " Téléchargement de l'index mondial iptv-org (≈ 16 Mo, une fois par semaine)…");
    else if (s2.at) parts.push(h("span", { class: "dotst ok" }), " " + okN.toLocaleString("fr-FR") + " chaînes en ligne vérifiées sur " + s2.n.toLocaleString("fr-FR") + " candidates · index iptv-org du " + fmtClock(s2.at));
    else parts.push(h("span", { class: "dotst off" }), " Index iptv-org absent — catalogue Nova seul");
    if (s2.err) parts.push(h("span", { class: "mx-warn" }, " · actualisation impossible : " + s2.err.slice(0, 80)));
    tvIdxLine.replaceChildren(h("span", { class: "grow" }, ...parts),
      s2.state === "loading" ? null : h("button", { class: "btn sm ghost", title: "Retélécharger l'index public iptv-org", onclick: () => refreshIndex(true) }, h("span", { html: ic("refresh", 13) }), " Actualiser"));
  }
  async function refreshIndex(force) {
    idxInfo.state = "loading"; idxInfo.err = ""; paintIdxLine();
    try {
      const idx = await buildIndex();
      if (dead) return;
      idxData = idx; idxInfo.at = idx.at; idxInfo.state = "ok";
      rebuildChannels();
      if (force) ctx.toast("Index TV actualisé : " + idxInfo.n.toLocaleString("fr-FR") + " chaînes.");
    } catch (e) {
      if (dead) return;
      idxInfo.state = idxData ? "ok" : "err"; idxInfo.err = String((e && e.message) || e);
    }
    paintIdxLine(); renderTV();
  }
  async function startTV() {
    tvBody.replaceChildren(h("div", { class: "skel skel-row" }), h("div", { class: "skel skel-row" }));
    const [idx, logos, hs] = await Promise.all([IDB.get(IDX_KEY), IDB.get(LOGO_KEY), IDB.get(HEALTH_IDB)]);
    if (dead) return;
    health = (hs && typeof hs === "object") ? hs : {};
    if (idx && Array.isArray(idx.all)) { idxData = idx; idxInfo.at = idx.at || 0; idxInfo.state = "ok"; } else idxInfo.state = "none";
    logosMap = logos || {};
    rebuildChannels(); paintIdxLine(); renderTV(); paintResume();
    await loadStatic();
    if (dead) return;
    rebuildChannels(); paintIdxLine(); renderTV();
    if (!idxData || Date.now() - (idxData.at || 0) > IDX_MAX_AGE) refreshIndex(false);
  }
  const onLogos = async () => { if (dead) return; logosMap = (await IDB.get(LOGO_KEY)) || {}; for (const c of channels) if (!c.logo && logosMap[c.id]) c.logo = logosMap[c.id]; if (started.tv && !dead) renderTV(); };
  const onAdult = () => { if (dead) return; if (started.tv) { tvGenre = tvGenre === "xxx" && !adultOn() ? "" : tvGenre; rebuildChannels(); paintIdxLine(); renderTV(); } };
  window.addEventListener("nova:media-logos", onLogos); window.addEventListener("nova:media-adult", onAdult);
  cleanups.push(() => { window.removeEventListener("nova:media-logos", onLogos); window.removeEventListener("nova:media-adult", onAdult); });

  /* ── Santé des flux : RIEN d'injoignable n'est jamais montré (ordre d'Ahadi, 25/10) ──────────
     Une chaîne n'apparaît (liste, recherche, favoris, récents, comptes) que si l'un de ses flux a
     réussi la sonde moteur /api/tv/check (manifeste → variante → segment, toute URL acceptée) depuis
     moins de 12 h. Échec mémorisé 24 h puis re-sondé en silence. Sondage en arrière-plan : d'abord la
     vue courante, puis (file basse) toute l'Afrique pour remplir les comptes des pays. 6 sondes en
     vol au plus. La durée mesurée de la sonde (aller-retour réel) sert au tri « rapides d'abord ». */
  const TTL_OK = 12 * 3600e3, TTL_BAD = 24 * 3600e3, HEALTH_IDB = "health_v2";
  const hGet = (u) => health[u] || null;
  const hFresh = (r) => !!r && Date.now() - r.at < (r.ok ? TTL_OK : TTL_BAD);
  let hSaveT = 0;
  function hSet(u, ok, reason, ms) {
    health[u] = { ok: !!ok, r: String(reason || "").slice(0, 120), at: Date.now(), ms: ms || 0 };
    clearTimeout(hSaveT);
    hSaveT = setTimeout(() => {
      const now = Date.now();
      for (const k of Object.keys(health)) if (now - health[k].at > 3 * TTL_BAD) delete health[k];
      IDB.set(HEALTH_IDB, health);
    }, 1500);
  }
  /* ok : un flux sondé avec succès (frais) ; dead : tous les flux en échec frais ; pending : à sonder. */
  function chState(c) {
    let best = null, allBad = c.streams.length > 0;
    for (const x of c.streams) {
      const r = hGet(x.u);
      if (hFresh(r)) { if (r.ok && (!best || (r.ms || 9e9) < (best.ms || 9e9))) best = r; if (r.ok) allBad = false; }
      else allBad = false;
    }
    return best ? { k: "ok", r: best } : allBad ? { k: "dead", r: null } : { k: "pending", r: null };
  }
  const isOk = (c) => chState(c).k === "ok";
  const hWait = new Set(), hQ = [], hLow = [];
  let hBusy = 0;
  /* Met en file le prochain flux à sonder de chaque chaîne (ordre donné = priorité). */
  function hEnqueue(list, low, cap = 200) {
    const q = low ? hLow : hQ;
    let n = 0;
    for (const c of list) {
      if (n >= cap) break;
      if (chState(c).k !== "pending") continue;
      const next = c.streams.find((x) => !hFresh(hGet(x.u)));
      if (!next || hWait.has(next.u)) continue;
      hWait.add(next.u); q.push(next.u); n++;
    }
    hPump();
    return n;
  }
  function hPump() {
    while (!dead && hBusy < 6 && (hQ.length || (hLow.length && hBusy < 3))) {
      const u = hQ.length ? hQ.shift() : hLow.shift(); hBusy++;
      const t0 = performance.now();
      api.get("/api/tv/check?u=" + encodeURIComponent(u), TV_CHECK_BOUND_MS)
        .then((j) => { hSet(u, !!(j && j.ok), (j && j.reason) || "", Math.round(performance.now() - t0)); })
        .catch((e) => { hSet(u, false, "sonde sans réponse — " + String((e && e.message) || e).slice(0, 60), 0); })
        .finally(() => { hBusy--; hWait.delete(u); if (!dead) { onHealth(); hPump(); } });
    }
    if (!dead && !hQ.length && !hLow.length && !hBusy) crawlAfrica();
  }
  /* Les chaînes dont le flux sondé a échoué gardent leurs autres flux en file : on relance la vue. */
  const onHealth = debounce(() => { if (dead) return; viewRefill(); if (started.tv) { renderTV(true); paintIdxLine(); paintResume(); } }, 700);
  let viewCands = [];
  function viewRefill() { hEnqueue(viewCands, false, 200); }
  let crawled = false;
  function crawlAfrica() {
    if (crawled || !idxData) return;
    const af = channels.filter((c) => isAfrican(c.cc) && chState(c).k === "pending");
    if (!af.length) { crawled = true; return; }
    hEnqueue(sortChannels(af), true, 400);
  }

  /* ── Lignes et listes ──────────────────────────────────────────────── */
  const PAGE = 60;
  const fmtMs = (ms) => ms ? (ms < 1000 ? ms + " ms" : (ms / 1000).toLocaleString("fr-FR", { maximumFractionDigits: 1 }) + " s") : "";
  function tvRow(c) {
    const name = c.name;
    const st = chState(c);
    const okCount = c.streams.filter((x) => { const r = hGet(x.u); return hFresh(r) && r.ok; }).length;
    const meta = [c.cc ? flag(c.cc) + " " + (c.country || countryName(c.cc)) : c.country, c.cats.filter((g) => g !== "none").slice(0, 2).map(genreLabel).join(", "), c.streams.length > 1 ? c.streams.length + " flux" : ""].filter(Boolean).join(" · ");
    const logo = c.logo ? h("img", { class: "mx-logo", src: String(c.logo), alt: "", loading: "lazy", referrerpolicy: "no-referrer", onerror: (e) => { e.target.replaceWith(h("span", { class: "mx-logo mono" }, name.slice(0, 2))); } }) : h("span", { class: "mx-logo mono", "aria-hidden": "true" }, name.replace(/[^\p{L}\p{N}]/gu, "").slice(0, 2) || "TV");
    const fav = h("button", { class: "btn icon mx-fav", "data-fav-id": c.id, "aria-label": "Ajouter aux favoris : " + name, "aria-pressed": "false", title: "Ajouter aux favoris", html: ic("star", 16), onclick: () => toggleFav(c) });
    fav._ch = c;
    const stEl = st.r ? h("span", { class: "mx-st ok", title: "Sonde moteur réussie (manifeste, variante, segment) le " + fmtClock(st.r.at) + (st.r.ms ? " en " + fmtMs(st.r.ms) : "") + (okCount > 1 ? " · " + okCount + " flux joignables (bascule automatique)" : "") },
      h("span", { html: ic("check", 12) }), " En ligne · " + fmtClock(st.r.at) + (st.r.ms ? " · " + fmtMs(st.r.ms) : "")) : h("span", { class: "mx-st" });
    const row = h("div", { class: "row-item mx-row", "data-ch": c.id },
      h("button", { class: "btn icon-lg acc mx-play", "data-play-kind": "tv", "data-play-id": c.id, "data-play-name": name, "aria-label": "Regarder " + name, title: "Regarder " + name, html: ic("video", 16),
        onclick: () => { if (currentTV && currentTV.ch && currentTV.ch.id === c.id && !tvVideo.paused) tvVideo.pause(); else playTV(c); } }),
      logo,
      h("div", { class: "mx-main" },
        h("div", { class: "tt" }, name, c.pin ? h("span", { class: "mx-badge", title: "Catalogue Nova (testé de bout en bout le 20/10/2026) — et joignable à la dernière sonde" }, "Nova") : null),
        h("div", { class: "ss" }, meta)),
      stEl, fav);
    row._ch = c;
    return row;
  }
  /* Tri : catalogue Nova, puis rapides d'abord (durée de sonde mesurée, par paliers), Afrique et
     Burkina en tête, puis le nom. */
  function sortChannels(list) {
    const speed = (c) => { const r = chState(c).r; const ms = r && r.ms; return !ms ? 1 : ms < 2000 ? 0 : ms < 6000 ? 1 : 2; };
    const geo = (c) => (c.cc === "BF" ? 0 : isAfrican(c.cc) ? 1 : 2);
    return list.map((c) => ({ c, p: c.pin ? 0 : 1, sp: speed(c), g: geo(c) }))
      .sort((x, y) => (x.p - y.p) || (x.g - y.g) || (x.sp - y.sp) || x.c.name.localeCompare(y.c.name, "fr")).map((x) => x.c);
  }
  /* Liste paginée (60 lignes, suite chargée à l'approche du bas) : seules les chaînes joignables.
     Les candidates non encore sondées partent en file ; elles apparaissent quand la sonde réussit. */
  let pager = null, shownCount = PAGE;
  function channelList(cands, emptyText) {
    if (pager) { try { pager.disconnect(); } catch (e) {} pager = null; }
    const sorted = sortChannels(cands);
    viewCands = sorted;
    const ok = sorted.filter(isOk);
    const pend = sorted.filter((c) => chState(c).k === "pending").length;
    hEnqueue(sorted, false, 200);
    const prog = pend ? h("div", { class: "mx-prog run", "aria-live": "polite" }, h("span", { class: "dotst run" }), " Vérification de " + pend.toLocaleString("fr-FR") + " chaîne" + (pend > 1 ? "s" : "") + " en arrière-plan — elles s'ajoutent dès qu'elles répondent")
      : h("div", { class: "mx-prog" });
    if (!ok.length) return [prog, pend ? h("div", { class: "skel skel-row" }) : emptyState("video", emptyText)];
    const out = [prog];
    const pins = ok.filter((c) => c.pin), rest = ok.filter((c) => !c.pin);
    if (pins.length) out.push(h("h4", { class: "mx-sub" }, "Catalogue Nova"), h("div", { class: "rows" }, ...pins.map(tvRow)));
    if (rest.length) {
      const box = h("div", { class: "rows" });
      let shown = 0;
      const more = h("button", { class: "btn sm mx-more" });
      const page = () => {
        box.append(...rest.slice(shown, shown + PAGE).map(tvRow)); shown = Math.min(rest.length, shown + PAGE); shownCount = shown;
        if (shown >= rest.length) { more.remove(); if (pager) { pager.disconnect(); pager = null; } }
        else more.textContent = "Afficher plus (" + (rest.length - shown).toLocaleString("fr-FR") + ")";
        refreshStars(); refreshMediaMarks();
      };
      more.addEventListener("click", page);
      out.push(h("h4", { class: "mx-sub" }, pins.length ? "Index iptv-org" : "En ligne", h("span", { class: "ss" }, " · " + rest.length.toLocaleString("fr-FR"))), box, more);
      const first = Math.max(PAGE, Math.min(shownCount, rest.length));
      box.append(...rest.slice(0, first).map(tvRow)); shown = Math.min(rest.length, first);
      if (shown >= rest.length) more.remove();
      else {
        more.textContent = "Afficher plus (" + (rest.length - shown).toLocaleString("fr-FR") + ")";
        try { pager = new IntersectionObserver((es) => { if (!dead && es.some((e) => e.isIntersecting) && more.isConnected) page(); }, { rootMargin: "400px" }); queueMicrotask(() => { if (pager && more.isConnected) pager.observe(more); }); } catch (e) { pager = null; }
      }
    }
    return out;
  }
  /* Comptes des pays et genres : chaînes JOIGNABLES seulement ; « … » si des candidates restent à sonder. */
  function liveCounts() {
    const ok = {}, pend = {}, gOk = {}, gPend = {};
    let intlOk = 0, intlPend = 0;
    for (const c of channels) {
      const k = chState(c).k; if (k === "dead") continue;
      const key = c.cc || "??";
      if (k === "ok") { ok[key] = (ok[key] || 0) + 1; if (c.intl) intlOk++; for (const g of c.cats) gOk[g] = (gOk[g] || 0) + 1; }
      else { pend[key] = (pend[key] || 0) + 1; if (c.intl) intlPend++; for (const g of c.cats) gPend[g] = (gPend[g] || 0) + 1; }
    }
    return { ok, pend, gOk, gPend, intlOk, intlPend };
  }
  /* Bandeau d'accès rapide : favoris et récents JOIGNABLES, en tête de l'accueil TV. */
  function quickStrip() {
    const favs = loadFavs().map(fromSnap).filter((c) => c && isOk(c));
    const seen = new Set(favs.map((c) => c.id));
    const recs = (LS.get(REC_KEY, []) || []).map(fromSnap).filter((c) => c && isOk(c) && !seen.has(c.id));
    const items = [...favs.map((c) => [c, true]), ...recs.map((c) => [c, false])].slice(0, 12);
    hEnqueue([...loadFavs().map(fromSnap), ...(LS.get(REC_KEY, []) || []).map(fromSnap)].filter(Boolean), false, 30);
    if (!items.length) return null;
    return h("section", { class: "mx-quick" }, h("h3", { class: "mx-rtitle" }, "Favoris et récents"),
      h("div", { class: "mx-quick-row" }, ...items.map(([c, f]) => h("button", { class: "mx-qitem", title: "Regarder " + c.name, onclick: () => playTV(c) },
        c.logo ? h("img", { src: c.logo, alt: "", loading: "lazy", referrerpolicy: "no-referrer", onerror: (e) => { e.target.remove(); } }) : h("span", { class: "mono" }, c.name.slice(0, 2)),
        h("span", { class: "nm" }, (f ? "★ " : "") + c.name)))));
  }
  let lastSig = "";
  function renderTV(fromHealth) {
    if (dead) return;
    const q = norm(tvQ.value.trim());
    const sig = [q, tvMode, tvCC, tvGenre, adultOn()].join("|");
    if (!fromHealth || sig !== lastSig) shownCount = PAGE;
    lastSig = sig;
    const scEl = scrollParent(tvBody), y = scEl ? scEl.scrollTop : 0;
    const nodes = [];
    if (q) {
      const terms = q.split(/\s+/).filter(Boolean);
      const hit = channels.filter((c) => terms.every((t) => c.hay.includes(t)));
      const okN = hit.filter(isOk).length;
      nodes.push(crumb(null, "", "Résultats pour « " + tvQ.value.trim() + " »", h("span", { class: "ss" }, " · " + okN.toLocaleString("fr-FR") + " en ligne")));
      nodes.push(...channelList(hit, "Aucune chaîne joignable ne correspond — essaie un nom de pays (« Sénégal ») ou un genre (« infos »)."));
    } else if (tvMode === "pays") {
      if (!tvCC) {
        const lc = liveCounts();
        const strip = quickStrip(); if (strip) nodes.push(strip);
        nodes.push(countryGrid(lc.ok, (cc) => { tvCC = cc; LS.set("nova2_media_tv_cc", cc); renderTV(); }, "en ligne",
          [{ cc: "INTL", n: lc.intlOk, pend: lc.intlPend, label: "Sélection internationale Nova", fl: "🌍" }, { cc: "??", n: lc.ok["??"] || 0, pend: lc.pend["??"] || 0, label: "Pays non renseigné", fl: "🏳️" }], lc.pend));
        viewCands = []; crawlAfrica();
      } else {
        const list = tvCC === "INTL" ? channels.filter((c) => c.intl) : tvCC === "??" ? channels.filter((c) => !c.cc) : channels.filter((c) => c.cc === tvCC);
        const okN = list.filter(isOk).length;
        const ttl = tvCC === "INTL" ? "Sélection internationale Nova" : tvCC === "??" ? "Pays non renseigné" : countryName(tvCC);
        nodes.push(crumb(() => { tvCC = ""; LS.set("nova2_media_tv_cc", ""); renderTV(); }, "Pays", h("span", { class: "fl" }, tvCC === "INTL" ? "🌍" : tvCC === "??" ? "🏳️" : flag(tvCC)), " " + ttl, h("span", { class: "ss" }, " · " + okN.toLocaleString("fr-FR") + " en ligne")));
        nodes.push(...channelList(list, "Aucune chaîne joignable de ce pays pour le moment.", ));
        if (!okN && !list.some((c) => chState(c).k === "pending")) nodes.push(h("button", { class: "btn sm", onclick: () => { radioCC = tvCC; radioMode = "pays"; rModes.set("pays"); showTab("radio"); renderRadio(); } }, "Voir ses radios"));
      }
    } else if (tvMode === "genres") {
      if (!tvGenre) {
        const lc = liveCounts();
        const keys = [...new Set([...Object.keys(lc.gOk), ...Object.keys(lc.gPend)])].filter((g) => g !== "xxx" || adultOn())
          .sort((a, b) => (a === "xxx") - (b === "xxx") || (lc.gOk[b] || 0) - (lc.gOk[a] || 0) || ((lc.gPend[b] || 0) - (lc.gPend[a] || 0)) || genreLabel(a).localeCompare(genreLabel(b), "fr"));
        nodes.push(h("div", { class: "mx-genres" }, ...keys.map((g) => h("button", { class: "mx-genre" + (g === "xxx" ? " adult" : ""), onclick: () => { tvGenre = g; renderTV(); } },
          h("span", { class: "nm" }, genreLabel(g)), h("span", { class: "ct", title: (lc.gPend[g] ? lc.gPend[g] + " encore à vérifier" : "") }, lc.gOk[g] ? lc.gOk[g].toLocaleString("fr-FR") + (lc.gPend[g] ? " …" : "") : "…")))));
        if (adultOn() && !keys.includes("xxx")) nodes.push(h("p", { class: "ss" }, "Contenus 18+ activés : l'index public iptv-org n'en contient aucun à ce jour."));
        viewCands = [];
      } else {
        const list = channels.filter((c) => c.cats.includes(tvGenre));
        nodes.push(crumb(() => { tvGenre = ""; renderTV(); }, "Genres", genreLabel(tvGenre), h("span", { class: "ss" }, " · " + list.filter(isOk).length.toLocaleString("fr-FR") + " en ligne")));
        nodes.push(...channelList(list, "Aucune chaîne joignable dans ce genre pour le moment."));
      }
    } else if (tvMode === "favs") {
      const list = loadFavs().map(fromSnap).filter(Boolean);
      nodes.push(...channelList(list, list.length ? "Aucun de tes favoris ne répond en ce moment — ils reviendront dès qu'une sonde réussit." : "Aucun favori pour le moment — touche l'étoile d'une chaîne pour l'épingler ici."));
    } else {
      const rec = (LS.get(REC_KEY, []) || []).map(fromSnap).filter(Boolean);
      nodes.push(...channelList(rec, rec.length ? "Aucune chaîne récente ne répond en ce moment." : "Aucune chaîne regardée pour le moment."));
    }
    tvBody.replaceChildren(...nodes);
    if (fromHealth && scEl) { try { scEl.scrollTop = y; } catch (e) {} }
    refreshStars(); refreshMediaMarks();
  }

  /* ── Lecteur TV ──────────────────────────────────────────────────────────
     Règle d'Ahadi (25/10) : jamais de lecteur noir. Un flux qui ne démarre pas (erreur, refus, 20 s
     sans image) → flux alternatif suivant, sans bruit. Un flux qui coupe en cours de lecture →
     3 reconnexions par cause (W-23), puis flux suivant. Plus aucun flux → la chaîne est notée
     injoignable (donc retirée de toutes les listes), le lecteur se ferme, toast « Chaîne indisponible,
     retirée ». */
  let currentTV = null, stallTimer = 0, startTimer = 0;
  const MEDIA_ERR = { 1: "lecture interrompue avant le démarrage", 2: "erreur réseau", 3: "flux non décodable", 4: "format non pris en charge" };
  function tvCause(fallback) { const e = tvVideo.error; return e ? (MEDIA_ERR[e.code] || "erreur média (code " + e.code + ")") : fallback; }
  function hideTVError() { tvErrorBox.hidden = true; if (tvErrorBox.parentNode !== tvPlayerWrap) tvPlayerWrap.append(tvErrorBox); }
  let hlsInst = null, tvHlsFallback = false, tvLastHttp = 0, tvEverPlayed = false;
  function tvDestroyHls() { if (hlsInst) { try { hlsInst.destroy(); } catch (e) {} hlsInst = null; } }
  /* FIXPREP D-R4 : forme canonique du relais local, idempotente. */
  function tvRelayUrl(raw) {
    const s = String(raw || "").trim();
    if (!s) return s;
    let direct = s;
    const m = s.match(/^\/(?:api\/stream|api\/tv\/stream)\?u=([\s\S]*)$/);
    if (m) { try { direct = decodeURIComponent(m[1]); } catch (e) { return s; } }
    if (!/^https?:\/\//i.test(direct)) return s;
    return "/api/stream?u=" + encodeURIComponent(direct);
  }
  function tvPlayNative(url) {
    if (tvVideo.src !== url) tvVideo.src = url; else tvVideo.load();
    tvVideo.play().catch((err) => {
      if (err && err.name === "AbortError") return;
      if (currentTV && currentTV.url === url) tvFailed(tvCause("Le flux n'a pas pu démarrer : " + String((err && err.message) || err)), "play");
    });
  }
  const isM3u8 = (u) => /\.m3u8($|\?|%3F|&)/i.test(u) || /^\/api\/(tv\/)?stream\?u=.*m3u8/i.test(u);
  function tvLoad(url) {
    tvDestroyHls(); tvLastHttp = 0;
    if (!hlsDone && isM3u8(url)) { loadHls().then(() => { if (currentTV && currentTV.url === url) tvLoad(url); }); return; }
    if (isM3u8(url) && !window.Hls && !tvLoad.hlsWarned) { tvLoad.hlsWarned = true; ctx.toast("Librairie hls.js indisponible — lecture native (secours) : certains flux peuvent décrocher.", true); }
    if (!tvHlsFallback && isM3u8(url) && window.Hls && window.Hls.isSupported()) {
      const hls = new window.Hls({ maxBufferLength: 30, manifestLoadingMaxRetry: 2, fragLoadingMaxRetry: 3, levelLoadingMaxRetry: 4, manifestLoadingTimeOut: 15000, levelLoadingTimeOut: 15000, startLevel: -1, capLevelToPlayerSize: true });
      hlsInst = hls;
      hls.loadSource(url);
      hls.attachMedia(tvVideo);
      hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
        if (hlsInst !== hls || !currentTV || currentTV.url !== url) return;
        tvVideo.play().catch((err) => { if (err && err.name === "AbortError") return; if (currentTV && currentTV.url === url) tvFailed(tvCause("Le flux n'a pas pu démarrer."), "play"); });
      });
      hls.on(window.Hls.Events.ERROR, (ev, data) => {
        if (hlsInst !== hls || !data || !data.fatal || !currentTV || currentTV.url !== url) return;
        if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) { try { hls.recoverMediaError(); return; } catch (e) {} }
        tvLastHttp = (data.response && data.response.code) || 0;
        if (!tvHlsFallback && data.response && data.response.code === 0) { tvHlsFallback = true; tvDestroyHls(); tvPlayNative(url); return; }
        const hlsDet = String(data.details || data.type || "erreur"), hlsTyp = data.type ? String(data.type) : "";
        const hlsCode = (data.response && data.response.code != null) ? " — HTTP " + String(data.response.code) : "";
        tvFailed(tvCause("Le flux n'a pas pu être lu (hls.js : " + hlsDet + (hlsTyp && hlsTyp !== hlsDet ? " / " + hlsTyp : "") + hlsCode + ")"), "hls");
      });
      return;
    }
    tvPlayNative(url);
  }
  let retryTimer = 0, tvRecovering = false;
  const tvRetries = { media: 0, stall: 0, play: 0, hls: 0 };
  const TV_CAUSE_LABEL = { media: "erreur média", stall: "flux gelé", play: "démarrage refusé", hls: "erreur hls/réseau" };
  function tvResetRetries() { tvRetries.media = 0; tvRetries.stall = 0; tvRetries.play = 0; tvRetries.hls = 0; tvRecovering = false; }
  function removeChannel(ch, cause) {
    for (const x of ch.streams) { const r = hGet(x.u); if (!hFresh(r) || r.ok) hSet(x.u, false, "échec de lecture — " + String(cause || "").slice(0, 80), 0); }
    const wasAttached = !!(ctx.watch && ctx.watch.active && ctx.watch.active());
    stopTV();
    if (wasAttached) { try { ctx.watch.close(); } catch (e) {} }
    ctx.toast("Chaîne indisponible, retirée : " + ch.name);
    if (started.tv) { renderTV(true); paintIdxLine(); }
  }
  /* Flux suivant de la chaîne ; relais refusé (403 « hors catalogue ») → même flux en direct d'abord. */
  function tvNextStream(cause) {
    const c = currentTV; if (!c || !c.ch) return;
    const st = c.ch.streams[c.alt];
    if (!c.direct && tvLastHttp === 403 && st && !tvEverPlayed) { loadAlt(c.alt, true); return; }
    if (st) hSet(st.u, false, "échec de lecture — " + String(cause || "").slice(0, 80), 0);
    if (c.alt + 1 < c.ch.streams.length) { loadAlt(c.alt + 1, false); return; }
    removeChannel(c.ch, cause);
  }
  function tvFailed(cause, kind) {
    if (dead || !currentTV) return;
    if (tvRecovering) return;
    clearTimeout(startTimer);
    if (!tvEverPlayed) { tvNextStream(cause); return; }
    const k = TV_CAUSE_LABEL[kind] ? kind : "media";
    if (tvRetries[k] >= 3) { clearTimeout(retryTimer); tvEverPlayed = false; tvNextStream(cause); return; }
    tvRetries[k]++;
    tvRecovering = true;
    const delay = [2000, 5000, 10000][tvRetries[k] - 1] || 10000;
    ctx.toast("Flux interrompu (" + TV_CAUSE_LABEL[k] + ") — reconnexion " + tvRetries[k] + "/3…");
    clearTimeout(retryTimer);
    retryTimer = setTimeout(() => { if (dead || !currentTV) return; tvRecovering = false; tvLoad(currentTV.url); }, delay);
  }
  tvVideo.addEventListener("error", () => { if (hlsInst) return; tvFailed(tvCause("Le flux n'a pas pu démarrer."), "media"); });
  tvVideo.addEventListener("stalled", () => {
    clearTimeout(stallTimer);
    const t0 = tvVideo.currentTime || 0;
    stallTimer = setTimeout(() => {
      if (!dead && currentTV && !tvVideo.paused && tvVideo.readyState < 3 && (tvVideo.currentTime || 0) <= t0 + 0.5)
        tvFailed("Le flux ne livre plus de données — connexion interrompue ou serveur muet.", "stall");
    }, 12000);
  });
  tvVideo.addEventListener("playing", () => {
    clearTimeout(stallTimer); clearTimeout(retryTimer); clearTimeout(startTimer);
    tvResetRetries(); hideTVError();
    tvVideo.style.display = "";
    if (currentTV && currentTV.ch) {
      const first = !tvEverPlayed;
      tvEverPlayed = true; tvPlayingId = currentTV.ch.id;
      const st = currentTV.ch.streams[currentTV.alt];
      if (first && st && !(hFresh(hGet(st.u)) && hGet(st.u).ok)) { hSet(st.u, true, "", (hGet(st.u) || {}).ms || 0); onHealth(); }
      if (first) pushRecent(currentTV.ch);
    }
    refreshMediaMarks(); paintResume();
  });
  for (const ev of ["pause", "ended"]) tvVideo.addEventListener(ev, () => { if (currentTV && currentTV.ch && tvPlayingId === currentTV.ch.id) tvPlayingId = ""; refreshMediaMarks(); });

  function stopTV() {
    currentTV = null; tvPlayingId = "";
    clearTimeout(stallTimer); clearTimeout(retryTimer); clearTimeout(startTimer); tvResetRetries();
    hideTVError(); tvDestroyHls();
    try { tvVideo.pause(); tvVideo.removeAttribute("src"); tvVideo.load(); } catch (e) {}
    tvVideo.style.display = "none";
    refreshMediaMarks(); paintResume();
  }
  function ensureRelay(c) {
    if (c.pin) return Promise.resolve();
    const key = c.adult ? "xxx" : String(c.cc || "").toLowerCase();
    if (!/^[a-z]{2,3}$/.test(key)) return Promise.resolve();
    if (!relayAuth.has(key)) relayAuth.set(key, api.get("/api/tv/channels?country=" + key, 20000).then(() => true, () => { relayAuth.delete(key); return false; }));
    return relayAuth.get(key);
  }
  /* Ordre d'essai : flux joignables (les plus rapides d'abord), puis non sondés ; jamais un flux en échec frais. */
  function streamOrder(c) {
    const r = (x) => { const v = hGet(x.u); return hFresh(v) && v.ok ? (v.ms || 5000) : 1e6; };
    return c.streams.filter((x) => { const v = hGet(x.u); return !(hFresh(v) && !v.ok); }).map((x, i) => ({ x, i })).sort((a, b) => r(a.x) - r(b.x) || a.i - b.i).map((o) => o.x);
  }
  function loadAlt(i, direct) {
    const c = currentTV; if (!c || !c.ch) return;
    const st = c.ch.streams[i]; if (!st) return;
    c.alt = i; c.direct = !!direct; c.relaySource = st.u;
    c.url = direct ? st.u : tvRelayUrl(st.u);
    tvEverPlayed = false; tvHlsFallback = false;
    clearTimeout(retryTimer); tvResetRetries(); hideTVError();
    tvVideo.style.display = "";
    const myUrl = c.url;
    clearTimeout(startTimer);
    startTimer = setTimeout(() => { if (!dead && currentTV === c && c.url === myUrl && !tvEverPlayed) tvFailed("aucune image après 20 s", "play"); }, 20000);
    (direct ? Promise.resolve() : ensureRelay(c.ch)).then(() => { if (!dead && currentTV === c && c.url === myUrl) tvLoad(myUrl); });
  }
  function playTV(ch) {
    if (!ch || !ch.streams || !ch.streams.length) return;
    const ordered = { ...ch, streams: streamOrder(ch) };
    if (!ordered.streams.length) { ctx.toast("Chaîne indisponible, retirée : " + ch.name); if (started.tv) renderTV(true); return; }
    currentTV = { ch: ordered, name: ch.name, alt: 0, direct: false, url: "", relaySource: "" };
    tvPlayingId = "";
    const attached = !!(ctx.watch && ctx.watch.attach(tvVideo, {
      title: String(ch.name || "TV en direct"), sub: [ch.country, ordered.streams.length > 1 ? ordered.streams.length + " flux, bascule auto" : ""].filter(Boolean).join(" · "), module: "radio",
      onRelease: (reason) => { if (dead || reason === "close") stopTV(); },
    }));
    loadAlt(0, false);
    if (!attached) tvVideo.scrollIntoView({ behavior: "smooth", block: "center" });
    paintResume();
  }

  /* ═══════════════════════════ RADIOS ═════════════════════════════════ */
  const RB_HOSTS = ["de1", "de2", "all"];
  let rbHost = 0;
  async function rb(path, ms = 12000) {
    let err = null;
    for (let i = 0; i < RB_HOSTS.length; i++) {
      const k = (rbHost + i) % RB_HOSTS.length;
      try { const j = await fetchJSON("https://" + RB_HOSTS[k] + ".api.radio-browser.info/json/" + path, ms); rbHost = k; return j; }
      catch (e) { err = e; }
    }
    throw err || new Error("annuaire injoignable");
  }
  const stNorm = (o) => {
    const url = String(o.url_resolved || o.url || "");
    const alt = o.url && o.url_resolved && o.url !== o.url_resolved ? String(o.url) : "";
    const fav = String(o.favicon || "");
    return { id: String(o.stationuuid || url), name: String(o.name || "Station").trim(), url, alt, cc: String(o.countrycode || o.cc || "").toUpperCase(), country: String(o.country || ""),
      tags: String(o.tags || "").split(",").map((t) => t.trim()).filter(Boolean), codec: String(o.codec || ""), bitrate: Number(o.bitrate) || 0, votes: Number(o.votes) || 0, clicks: Number(o.clickcount) || 0,
      favicon: /^https:\/\//i.test(fav) ? fav : "", ok: o.lastcheckok == null ? 1 : Number(o.lastcheckok) };
  };
  const dedupe = (arr) => { const seen = new Set(); return arr.filter((s) => { const k = norm(s.name) + "|" + s.cc; if (!s.ok || !s.url || !/^https?:/i.test(s.url) || seen.has(k)) return false; seen.add(k); return true; }); };
  /* Annuaire : direct (miroirs), sinon le moteur /api/radio/search (ses propres miroirs). */
  async function rbStations(params, limit = 200) {
    const p = new URLSearchParams({ hidebroken: "true", order: "clickcount", reverse: "true", limit: String(limit), ...params });
    try { return dedupe(arrOf(await rb("stations/search?" + p.toString())).map(stNorm)); }
    catch (e) {
      const q = new URLSearchParams({ limit: String(Math.min(120, limit)) });
      if (params.countrycode) q.set("country", params.countrycode);
      if (params.name) q.set("name", params.name);
      if (params.tag) q.set("tag", params.tag);
      const j = await api.get("/api/radio/search?" + q.toString());
      if (j && j.error && !arrOf(j, "items").length) throw new Error(String(j.error));
      return dedupe(arrOf(j, "items").map(stNorm));
    }
  }
  const RFAV_KEY = "nova2_radio_favs_v1", RREC_KEY = "nova2_radio_recent_v1", RDEAD_KEY = "nova2_radio_dead_v1", RCC_KEY = "nova2_media_rbcc_v2", RCACHE_KEY = "nova2_media_rbcache_v1";
  let radioMode = LS.get("nova2_media_radio_mode", "pays"); if (!["pays", "genres", "favs", "recents"].includes(radioMode)) radioMode = "pays";
  let radioCC = LS.get("nova2_media_radio_cc", "BF"), radioTag = "", radioGenre = "", radioWorld = false;
  const radioDead = LS.get(RDEAD_KEY, {}) || {};
  const rQ = h("input", { type: "search", placeholder: "Nom d'une radio (RFI, Savane FM, BBC…)", "aria-label": "Rechercher une radio" });
  const rModes = segCtl([["pays", "Pays"], ["genres", "Genres"], ["favs", "Favoris", "star"], ["recents", "Récents"]], radioMode, (k) => { radioMode = k; LS.set("nova2_media_radio_mode", k); rQ.value = ""; radioGenre = ""; radioTag = ""; renderRadio(); }, "Parcourir les radios");
  const rNow = h("div", {});
  const rBody = h("div", { class: "mx-body" });
  radioPanel.append(h("div", { class: "mx-bar" }, h("div", { class: "searchbox mx-search" }, h("span", { html: ic("search", 16) }), rQ), rModes), rNow, rBody);
  rQ.addEventListener("input", debounce(() => { if (!dead) renderRadio(); }, 450));
  rQ.addEventListener("keydown", (e) => { if (e.key === "Escape") { rQ.value = ""; renderRadio(); } });
  const loadRFavs = () => { const v = LS.get(RFAV_KEY, []); return Array.isArray(v) ? v : []; };
  const isRFav = (s) => loadRFavs().some((x) => x.id === s.id);
  function toggleRFav(s) {
    let f = loadRFavs();
    f = isRFav(s) ? f.filter((x) => x.id !== s.id) : f.concat(s);
    LS.set(RFAV_KEY, f);
    if (radioMode === "favs" && !rQ.value.trim()) renderRadio();
    else radioPanel.querySelectorAll("[data-rfav]").forEach((b) => { if (b.getAttribute("data-rfav") === s.id) { const on = isRFav(s); b.classList.toggle("acc", on); b.setAttribute("aria-pressed", String(on)); b.setAttribute("aria-label", (on ? "Retirer des favoris : " : "Ajouter aux favoris : ") + s.name); } });
  }
  let radioCurrent = null;   // { st, url, triedAlt }
  function playStation(s) {
    if (radioCurrent && radioCurrent.st.id === s.id && sameUrl(audioPlayingUrl, radioCurrent.url)) { bus.emit("nova:player-stop", {}); return; }
    radioCurrent = { st: s, url: s.url, triedAlt: false };
    podCurrent = null;
    playAudio(s.url, s.name, [s.cc ? countryName(s.cc) : s.country, s.codec ? s.codec + (s.bitrate ? " " + s.bitrate + " kbps" : "") : ""].filter(Boolean).join(" · "), { kind: "radio" });
  }
  function stationRow(s) {
    const meta = [s.cc ? flag(s.cc) + " " + countryName(s.cc) : s.country, s.tags.slice(0, 3).join(", "), s.codec ? s.codec + (s.bitrate ? " " + s.bitrate + " kbps" : "") : ""].filter(Boolean).join(" · ");
    const logo = s.favicon ? h("img", { class: "mx-logo", src: s.favicon, alt: "", loading: "lazy", referrerpolicy: "no-referrer", onerror: (e) => { e.target.replaceWith(h("span", { class: "mx-logo mono", html: ic("radio", 15) })); } }) : h("span", { class: "mx-logo mono", html: ic("radio", 15) });
    const on = isRFav(s);
    return h("div", { class: "row-item mx-row" },
      h("button", { class: "btn icon-lg acc mx-play", "data-play-kind": "radio", "data-play-url": s.url, "data-play-name": s.name, "aria-label": "Écouter " + s.name, title: "Écouter " + s.name, html: ic("play", 16), onclick: () => playStation(s) }),
      logo,
      h("div", { class: "mx-main" }, h("div", { class: "tt" }, s.name), h("div", { class: "ss" }, meta)),
      h("span", { class: "mx-st" }, s.votes ? s.votes.toLocaleString("fr-FR") + " votes" : ""),
      h("button", { class: "btn icon mx-fav" + (on ? " acc" : ""), "data-rfav": s.id, "aria-pressed": String(on), "aria-label": (on ? "Retirer des favoris : " : "Ajouter aux favoris : ") + s.name, title: "Favori", html: ic("star", 16), onclick: () => toggleRFav(s) }));
  }
  /* Stations : seules celles que Radio Browser a vues joignables (hidebroken + lastcheckok) et qui
     n'ont pas échoué chez nous depuis 24 h. Jamais de ligne « muette ». */
  const RDEAD_TTL = 24 * 3600e3;
  const rIsDead = (s) => { const t = radioDead[s.id]; return !!t && Date.now() - t < RDEAD_TTL; };
  function stationList(list, empty) {
    const all = list.filter((s) => !rIsDead(s));
    if (!all.length) return [empty];
    const box = h("div", { class: "rows" }, ...all.slice(0, PAGE).map(stationRow));
    let shown = Math.min(PAGE, all.length);
    const out = [box];
    if (shown < all.length) {
      const more = h("button", { class: "btn sm mx-more", onclick: () => { box.append(...all.slice(shown, shown + PAGE).map(stationRow)); shown = Math.min(all.length, shown + PAGE); if (shown >= all.length) more.remove(); else more.textContent = "Afficher plus (" + (all.length - shown) + ")"; refreshMediaMarks(); } }, "Afficher plus (" + (all.length - shown) + ")");
      out.push(more);
    }
    return out;
  }
  const rCache = new Map(Object.entries(LS.get(RCACHE_KEY, {}) || {}));
  function rCacheSet(k, list) {
    rCache.set(k, { at: Date.now(), list: list.slice(0, 150) });
    const keys = [...rCache.keys()]; while (keys.length > 12) rCache.delete(keys.shift());
    LS.set(RCACHE_KEY, Object.fromEntries(rCache));
  }
  let rSeq = 0;
  async function rLoad(key, fetcher, render) {
    const seq = ++rSeq;
    const cached = rCache.get(key);
    if (cached) render(cached.list, cached.at, true);
    else rBody.append(h("div", { class: "skel skel-row" }), h("div", { class: "skel skel-row" }));
    try {
      const list = await fetcher();
      if (dead || seq !== rSeq) return;
      rCacheSet(key, list); render(list, 0, false);
    } catch (e) {
      if (dead || seq !== rSeq) return;
      if (cached) { const w = rBody.querySelector(".mx-cachenote"); if (w) w.textContent = "Hors ligne — liste du " + fmtClock(cached.at) + " (cache)"; }
      else rBody.replaceChildren(stateError("Annuaire radio injoignable pour le moment", e, () => renderRadio()));
    }
  }
  const RADIO_GENRES = [
    ["news", "Infos"], ["talk", "Débats"], ["music", "Musique"], ["afrobeat", "Afrobeat"], ["highlife", "Highlife"], ["mbalax", "Mbalax"],
    ["coupe decale", "Coupé-décalé"], ["rumba", "Rumba"], ["bongo flava", "Bongo flava"], ["hiphop", "Hip-hop"], ["reggae", "Reggae"], ["gospel", "Gospel"],
    ["islam", "Islam"], ["quran", "Coran"], ["christian", "Chrétien"], ["sport", "Sport"], ["jazz", "Jazz"], ["french", "Francophone"], ["community", "Communautaires"],
  ];
  async function radioCounts() {
    const c = LS.get(RCC_KEY, null);
    if (c && c.at && Date.now() - c.at < 7 * 24 * 3600e3) return c.m;
    try {
      const arr = arrOf(await rb("countrycodes"));
      const m = {}; for (const o of arr) { const k = String(o.name || "").toUpperCase(); if (/^[A-Z]{2}$/.test(k)) m[k] = Number(o.stationcount) || 0; }
      LS.set(RCC_KEY, { at: Date.now(), m });
      return m;
    } catch (e) { return (c && c.m) || null; }
  }
  function renderRadio() {
    if (dead) return;
    const q = rQ.value.trim();
    rBody.replaceChildren();
    if (q) {
      rBody.append(crumb(null, "", "Radios « " + q + " »"));
      rLoad("q:" + norm(q), () => rbStations({ name: q }, 100), (list, at) => {
        rBody.replaceChildren(crumb(null, "", "Radios « " + q + " »", h("span", { class: "ss" }, " · " + list.length)), at ? h("p", { class: "ss mx-cachenote" }, "Liste du " + fmtClock(at) + " (cache) — actualisation…") : "",
          ...stationList(list, emptyState("radio", "Aucune station trouvée pour « " + q + " »."))); refreshMediaMarks();
      });
      return;
    }
    if (radioMode === "pays") {
      if (!radioCC) {
        rBody.append(h("div", { class: "skel skel-row" }));
        radioCounts().then((m) => {
          if (dead || radioMode !== "pays" || radioCC || rQ.value.trim()) return;
          /* Comptes : joignables mesurés (pays déjà ouverts, hidebroken + lastcheckok) sinon le répertoire. */
          const okm = LS.get("nova2_media_rbok_v1", {}) || {};
          if (m) for (const k of Object.keys(okm)) m[k] = okm[k];
          rBody.replaceChildren(m ? countryGrid(m, (cc) => { radioCC = cc; LS.set("nova2_media_radio_cc", cc); radioTag = ""; renderRadio(); }, "stations", null)
            : stateError("Annuaire radio injoignable — comptes par pays indisponibles", null, () => renderRadio()));
        });
        return;
      }
      const cc = radioCC;
      const head = (n) => crumb(() => { radioCC = ""; LS.set("nova2_media_radio_cc", ""); renderRadio(); }, "Pays", h("span", { class: "fl" }, flag(cc)), " " + countryName(cc), h("span", { class: "ss" }, n == null ? "" : " · " + n + " station" + (n > 1 ? "s" : "")));
      rBody.append(head(null));
      rLoad("cc:" + cc, () => rbStations({ countrycode: cc }, 300), (list, at) => {
        list = list.filter((s) => !rIsDead(s));
        { const okm = LS.get("nova2_media_rbok_v1", {}) || {}; okm[cc] = list.length; LS.set("nova2_media_rbok_v1", okm); }
        const tc = {}; for (const s of list) for (const t of s.tags) tc[t.toLowerCase()] = (tc[t.toLowerCase()] || 0) + 1;
        const tags = Object.keys(tc).filter((t) => tc[t] >= 2 && t.length < 24).sort((a, b) => tc[b] - tc[a]).slice(0, 14);
        const shown = radioTag ? list.filter((s) => s.tags.some((t) => t.toLowerCase() === radioTag)) : list;
        rBody.replaceChildren(head(list.length), at ? h("p", { class: "ss mx-cachenote" }, "Liste du " + fmtClock(at) + " (cache) — actualisation…") : "",
          tags.length ? h("div", { class: "mx-tags" }, h("button", { class: "chip" + (radioTag ? "" : " on"), onclick: () => { radioTag = ""; renderRadio(); } }, "Toutes"),
            ...tags.map((t) => h("button", { class: "chip" + (t === radioTag ? " on" : ""), onclick: () => { radioTag = t === radioTag ? "" : t; renderRadio(); } }, t + " · " + tc[t]))) : "",
          ...stationList(shown, emptyState("radio", "Aucune station de ce pays dans l'annuaire Radio Browser.")));
        refreshMediaMarks();
      });
    } else if (radioMode === "genres") {
      if (!radioGenre) {
        rBody.append(h("div", { class: "mx-genres" }, ...RADIO_GENRES.map(([t, l]) => h("button", { class: "mx-genre", onclick: () => { radioGenre = t; renderRadio(); } }, h("span", { class: "nm" }, l)))));
        return;
      }
      const label = (RADIO_GENRES.find((g) => g[0] === radioGenre) || [0, radioGenre])[1];
      const head = (n) => crumb(() => { radioGenre = ""; renderRadio(); }, "Genres", label, h("span", { class: "ss" }, n == null ? "" : " · " + n),
        h("button", { class: "chip" + (radioWorld ? " on" : ""), style: "margin-left:auto", onclick: () => { radioWorld = !radioWorld; renderRadio(); } }, radioWorld ? "Monde entier" : "Afrique seulement"));
      rBody.append(head(null));
      rLoad("tag:" + radioGenre, () => rbStations({ tag: radioGenre }, 500), (list, at) => {
        const shown = radioWorld ? list : list.filter((s) => isAfrican(s.cc));
        rBody.replaceChildren(head(shown.length), at ? h("p", { class: "ss mx-cachenote" }, "Liste du " + fmtClock(at) + " (cache) — actualisation…") : "",
          ...stationList(shown, emptyState("radio", radioWorld ? "Aucune station pour ce genre." : "Aucune station africaine étiquetée « " + label + " » — essaie « Monde entier ».")));
        refreshMediaMarks();
      });
    } else if (radioMode === "favs") {
      rBody.append(...stationList(loadRFavs(), emptyState("star", "Aucune radio favorite — touche l'étoile d'une station.")));
    } else {
      const rec = LS.get(RREC_KEY, []) || [];
      rBody.append(...stationList(rec, emptyState("time", "Aucune radio écoutée pour le moment.")));
    }
    refreshMediaMarks();
  }
  function paintNowPlaying() {
    if (!rNow) return;
    const r = radioCurrent;
    if (!r || !sameUrl(audioPlayingUrl, r.url)) { rNow.replaceChildren(); return; }
    const s = r.st;
    rNow.replaceChildren(h("div", { class: "mx-now" },
      h("span", { class: "mx-live" }, "En direct"),
      h("div", { class: "grow" }, h("div", { class: "tt" }, s.name), h("div", { class: "ss" }, [s.cc ? flag(s.cc) + " " + countryName(s.cc) : s.country, s.codec ? s.codec + (s.bitrate ? " " + s.bitrate + " kbps" : "") : "", r.triedAlt ? "flux de secours" : ""].filter(Boolean).join(" · "))),
      h("button", { class: "btn sm", onclick: () => bus.emit("nova:player-stop", {}) }, h("span", { html: ic("stop", 13) }), " Arrêter")));
  }
  /* Bascule radio / reprise podcast : on écoute l'<audio> du shell, sans jamais le piloter hors bus. */
  if (audioEl) {
    const onErr = () => {
      if (dead) return;
      const r = radioCurrent;
      if (r && sameUrl(audioEl.src, r.url)) {
        if (r.st.alt && !r.triedAlt) { r.triedAlt = true; r.url = r.st.alt; ctx.toast("Flux principal muet — bascule sur l'adresse de secours de " + r.st.name + "…"); lastAudio = { url: r.url, title: r.st.name }; bus.emit("nova:play", { url: r.url, title: r.st.name, sub: r.st.country || "" }); return; }
        radioDead[r.st.id] = Date.now(); LS.set(RDEAD_KEY, radioDead);
        radioCurrent = null;
        bus.emit("nova:player-stop", {});
        ctx.toast("Station indisponible, retirée : " + r.st.name);
        if (started.radio) renderRadio();
        return;
      }
      const p = podCurrent;
      if (p && sameUrl(audioEl.src, p.url)) {
        epDead[p.url] = Date.now(); LS.set(EPDEAD_KEY, epDead);
        podCurrent = null;
        bus.emit("nova:player-stop", {});
        ctx.toast("Épisode indisponible, retiré : " + p.title);
        pBody.querySelectorAll("[data-ep]").forEach((row) => { if (row.getAttribute("data-ep") === p.url) row.remove(); });
      }
    };
    const onPlaying = () => {
      if (dead) return;
      const r = radioCurrent;
      if (r && sameUrl(audioEl.src, r.url)) {
        if (radioDead[r.st.id]) { delete radioDead[r.st.id]; LS.set(RDEAD_KEY, radioDead); }
        const rec = (LS.get(RREC_KEY, []) || []).filter((x) => x.id !== r.st.id); rec.unshift(r.st); LS.set(RREC_KEY, rec.slice(0, 20));
      }
      const p = podCurrent;
      if (p && sameUrl(audioEl.src, p.url) && p.resumeAt && !p.resumed) { p.resumed = true; try { audioEl.currentTime = p.resumeAt; ctx.toast("Reprise à " + fmtDur(p.resumeAt)); } catch (e) {} }
      paintNowPlaying();
    };
    let lastSave = 0;
    const onTime = () => {
      const p = podCurrent;
      if (dead || !p || !sameUrl(audioEl.src, p.url) || !p.resumed && p.resumeAt) return;
      const now = Date.now(); if (now - lastSave < 5000) return; lastSave = now;
      savePos(p, audioEl.currentTime, audioEl.duration);
    };
    const onEnded = () => { const p = podCurrent; if (p && sameUrl(audioEl.src, p.url)) { savePos(p, audioEl.duration, audioEl.duration, true); if (started.podcast && podView === "eps") paintEpProgress(); } };
    const onPause = () => { const p = podCurrent; if (p && sameUrl(audioEl.src, p.url) && audioEl.currentTime > 5) { savePos(p, audioEl.currentTime, audioEl.duration); if (started.podcast && podView === "eps") paintEpProgress(); } };
    audioEl.addEventListener("error", onErr); audioEl.addEventListener("playing", onPlaying); audioEl.addEventListener("timeupdate", onTime);
    audioEl.addEventListener("ended", onEnded); audioEl.addEventListener("pause", onPause);
    cleanups.push(() => { audioEl.removeEventListener("error", onErr); audioEl.removeEventListener("playing", onPlaying); audioEl.removeEventListener("timeupdate", onTime); audioEl.removeEventListener("ended", onEnded); audioEl.removeEventListener("pause", onPause); });
  }
  function startRadio() { renderRadio(); }

  /* ══════════════════════════ PODCASTS ════════════════════════════════ */
  const POS_KEY = "nova2_pod_pos_v1", EPDEAD_KEY = "nova2_pod_epdead_v1", PODDEAD_KEY = "nova2_pod_dead_v1";
  /* Podcasts et épisodes qui n'ont pas pu être lus : retirés 24 h (puis réessayés en silence). */
  const epDead = LS.get(EPDEAD_KEY, {}) || {}, podDead = LS.get(PODDEAD_KEY, {}) || {};
  const pAlive = (m, k) => !(m[k] && Date.now() - m[k] < 24 * 3600e3);
  const podKey = (p) => p.id || p.feed;
  let podCC = LS.get("nova2_media_pod_cc", "BF"), podView = "top", podShow = null, podEps = [], podCurrent = null;
  const pQ = h("input", { type: "search", placeholder: "Rechercher un podcast…", "aria-label": "Rechercher un podcast" });
  const pCountry = h("select", { class: "sel", "aria-label": "Pays du classement Apple Podcasts" },
    ...REGIONS.flatMap((r) => r.cc.filter((cc) => AFRICA.has(cc)).map((cc) => ({ cc, n: countryName(cc) }))).sort((a, b) => a.n.localeCompare(b.n, "fr")).map(({ cc, n }) => h("option", { value: cc }, flag(cc) + " " + n)),
    h("option", { value: "FR" }, flag("FR") + " " + countryName("FR")));
  pCountry.value = podCC;
  const pModes = segCtl([["top", "Populaires"], ["resume", "Reprendre", "time"]], "top", (k) => { podView = k; pQ.value = ""; renderPod(); }, "Podcasts");
  const pBody = h("div", { class: "mx-body" });
  podPanel.append(h("div", { class: "mx-bar" }, h("div", { class: "searchbox mx-search" }, h("span", { html: ic("search", 16) }), pQ),
    h("div", { class: "searchbox mx-cc-sel" }, pCountry), pModes), pBody);
  pCountry.addEventListener("change", () => { podCC = pCountry.value; LS.set("nova2_media_pod_cc", podCC); if (podView !== "resume") { podView = pQ.value.trim() ? "search" : "top"; pModes.set("top"); } renderPod(); });
  pQ.addEventListener("input", debounce(() => { if (dead) return; podView = pQ.value.trim() ? "search" : "top"; pModes.set(podView === "search" ? "" : "top"); renderPod(); }, 500));
  const loadPos = () => LS.get(POS_KEY, {}) || {};
  function savePos(p, pos, dur, done) {
    if (!p || !isFinite(pos)) return;
    const m = loadPos();
    m[p.url] = { pos: Math.round(pos), dur: isFinite(dur) ? Math.round(dur) : 0, done: !!done || (isFinite(dur) && dur > 0 && pos > dur - 20), at: Date.now(), t: p.title, show: p.show, art: p.art || "", feed: p.feed || "" };
    const keys = Object.keys(m); if (keys.length > 200) keys.sort((a, b) => m[a].at - m[b].at).slice(0, keys.length - 200).forEach((k) => delete m[k]);
    LS.set(POS_KEY, m);
  }
  const ITUNES = "https://itunes.apple.com/";
  async function itunesTop(cc) {
    const j = await fetchJSON(ITUNES + cc.toLowerCase() + "/rss/toppodcasts/limit=50/json", 15000);
    const e = (j && j.feed && j.feed.entry) || [];
    return (Array.isArray(e) ? e : [e]).map((x) => ({
      id: String((x.id && x.id.attributes && x.id.attributes["im:id"]) || ""), name: String((x["im:name"] && x["im:name"].label) || "Podcast"),
      artist: String((x["im:artist"] && x["im:artist"].label) || ""), art: String(((x["im:image"] || []).slice(-1)[0] || {}).label || ""),
      genre: String((x.category && x.category.attributes && x.category.attributes.label) || ""), feed: "" })).filter((p) => p.id);
  }
  const itShape = (r) => ({ id: String(r.collectionId || ""), name: String(r.collectionName || r.trackName || "Podcast"), artist: String(r.artistName || ""), art: String(r.artworkUrl100 || r.artworkUrl60 || ""), genre: String(r.primaryGenreName || ""), feed: String(r.feedUrl || "") });
  async function itunesSearch(q, cc) {
    const base = ITUNES + "search?media=podcast&entity=podcast&limit=40&term=" + encodeURIComponent(q);
    try { return arrOf(await fetchJSON(base + "&country=" + cc.toLowerCase(), 15000), "results").map(itShape).filter((p) => p.feed); }
    catch (e) {
      try { return arrOf(await fetchJSON(base + "&country=fr", 15000), "results").map(itShape).filter((p) => p.feed); }   // magasin du pays refusé (400/403) : magasin France, francophone
      catch (e2) {
        const j = await api.get("/api/podcast/search?q=" + encodeURIComponent(q));   // dernier recours : annuaire fyyd du moteur
        if (j && j.error && !arrOf(j, "items").length) throw new Error(String(j.error));
        return arrOf(j, "items").map((p) => ({ id: "fyyd:" + p.feed, name: p.name, artist: p.artist, art: p.art || "", genre: "", feed: p.feed }));
      }
    }
  }
  async function feedOf(p, cc) {
    if (p.feed) return p.feed;
    for (const extra of ["&country=" + cc.toLowerCase(), ""]) {
      try { const r = arrOf(await fetchJSON(ITUNES + "lookup?id=" + encodeURIComponent(p.id) + extra, 15000), "results")[0]; if (r && r.feedUrl) { p.feed = r.feedUrl; return p.feed; } } catch (e) {}
    }
    throw new Error("Apple ne publie pas le flux RSS de ce podcast");
  }
  function podRow(p) {
    return h("div", { class: "row-item mx-row mx-pod" },
      p.art ? h("img", { class: "mx-art", src: p.art, alt: "", loading: "lazy", referrerpolicy: "no-referrer", onerror: (e) => { e.target.replaceWith(h("span", { class: "mx-art mono", html: ic("podcast", 18) })); } }) : h("span", { class: "mx-art mono", html: ic("podcast", 18) }),
      h("div", { class: "mx-main" }, h("div", { class: "tt" }, p.name), h("div", { class: "ss" }, [p.artist, p.genre].filter(Boolean).join(" · "))),
      h("button", { class: "btn sm acc", onclick: () => openShow(p) }, "Épisodes"));
  }
  let pSeq = 0;
  async function renderPod() {
    if (dead) return;
    const seq = ++pSeq;
    pBody.replaceChildren(h("div", { class: "skel skel-row" }), h("div", { class: "skel skel-row" }));
    if (podView === "resume") {
      const m = loadPos();
      const list = Object.entries(m).filter(([, v]) => !v.done && v.pos > 15).sort((a, b) => b[1].at - a[1].at).slice(0, 30);
      pBody.replaceChildren(...(list.length ? [h("div", { class: "rows" }, ...list.filter(([url]) => pAlive(epDead, url)).map(([url, v]) => epRow({ title: v.t, url, show: v.show, art: v.art, feed: v.feed }, v.show)))]
        : [emptyState("time", "Aucun épisode en cours — la position d'écoute est retenue automatiquement.")]));
      refreshMediaMarks(); return;
    }
    const q = pQ.value.trim();
    try {
      const list = q ? await itunesSearch(q, podCC) : await itunesTop(podCC);
      if (dead || seq !== pSeq) return;
      LS.set("nova2_media_podcache_" + (q ? "q" : podCC), { at: Date.now(), list: list.slice(0, 50) });
      pBody.replaceChildren(crumb(null, "", q ? "Podcasts « " + q + " »" : "Populaires · " + flag(podCC) + " " + countryName(podCC), h("span", { class: "ss" }, " · " + list.length + (q ? "" : " · classement Apple Podcasts"))),
        ...(list.some((x) => pAlive(podDead, podKey(x))) ? [h("div", { class: "rows" }, ...list.filter((x) => pAlive(podDead, podKey(x))).map(podRow))] : [emptyState("podcast", q ? "Aucun podcast trouvé pour « " + q + " »." : "Classement vide pour ce pays.")]));
    } catch (e) {
      if (dead || seq !== pSeq) return;
      const c = !q && LS.get("nova2_media_podcache_" + podCC, null);
      if (c && c.list && c.list.length) pBody.replaceChildren(h("p", { class: "ss" }, "Hors ligne — classement du " + fmtClock(c.at) + " (cache)"), h("div", { class: "rows" }, ...c.list.filter((x) => pAlive(podDead, podKey(x))).map(podRow)));
      else pBody.replaceChildren(stateError(q ? "Recherche de podcasts injoignable" : "Classement Apple Podcasts indisponible pour " + countryName(podCC), e, () => renderPod()));
    }
  }
  function epRow(ep, show) {
    const title = String(ep.title || "Épisode");
    const meta = [ep.date ? String(ep.date).replace(/\s\d\d:\d\d:\d\d.*$/, "") : "", ep.duration ? (/^\d+$/.test(String(ep.duration)) ? fmtDur(ep.duration) : String(ep.duration)) : "", ep.show && ep.show !== show ? ep.show : ""].filter(Boolean).join(" · ");
    return h("div", { class: "row-item mx-row mx-ep", "data-ep": ep.url },
      h("button", { class: "btn icon-lg acc mx-play", "data-play-kind": "podcast", "data-play-url": ep.url, "data-play-name": title, "aria-label": "Écouter l'épisode : " + title, title: "Écouter l'épisode : " + title, html: ic("podcast", 16),
        onclick: () => playEpisode({ ...ep, show: ep.show || show }) }),
      h("div", { class: "mx-main" }, h("div", { class: "tt" }, title), h("div", { class: "ss" }, meta)),
      h("span", { class: "mx-st mx-pos" }));
  }
  function paintEpProgress() {
    const m = loadPos();
    pBody.querySelectorAll("[data-ep]").forEach((row) => {
      const v = m[row.getAttribute("data-ep")]; const el = row.querySelector(".mx-pos"); if (!el) return;
      if (!v) { el.textContent = ""; el.className = "mx-st mx-pos"; return; }
      if (v.done) { el.textContent = "Écouté"; el.className = "mx-st mx-pos ok"; }
      else if (v.pos > 15) { el.textContent = "Reprise à " + fmtDur(v.pos) + (v.dur ? " / " + fmtDur(v.dur) : ""); el.className = "mx-st mx-pos run"; }
    });
  }
  function playEpisode(ep) {
    if (!ep.url) return;
    const v = loadPos()[ep.url];
    radioCurrent = null;
    podCurrent = { url: ep.url, title: ep.title || "Épisode", show: ep.show || "", art: ep.art || (podShow && podShow.art) || "", feed: ep.feed || (podShow && podShow.feed) || "", resumeAt: v && !v.done && v.pos > 15 ? v.pos : 0, resumed: false };
    playAudio(ep.url, ep.title, ep.show || "", { kind: "podcast" });
  }
  async function openShow(p) {
    podView = "eps"; podShow = p;
    const seq = ++pSeq;
    const back = () => { podView = pQ.value.trim() ? "search" : "top"; renderPod(); };
    pBody.replaceChildren(crumb(back, "Retour", p.name), h("div", { class: "skel skel-row" }), h("div", { class: "skel skel-row" }));
    try {
      let feed = await feedOf(p, podCC);
      if (/^http:\/\//i.test(feed)) feed = feed.replace(/^http:/i, "https:");   // le moteur n'accepte que https
      let j;
      try { j = await api.get("/api/podcast/episodes?feed=" + encodeURIComponent(feed), 20000); if (j && j.error) throw new Error(String(j.error)); }
      catch (e) {
        /* Repli : lecture directe du flux RSS (aboutit si l'hébergeur autorise CORS). */
        const r = await fetch(feed); if (!r.ok) throw e;
        const x = new DOMParser().parseFromString(await r.text(), "text/xml");
        const items = [...x.querySelectorAll("item")].slice(0, 25).map((it) => ({ title: (it.querySelector("title") || {}).textContent || "", url: (it.querySelector("enclosure") || { getAttribute: () => "" }).getAttribute("url") || "", date: (it.querySelector("pubDate") || {}).textContent || "", duration: (it.getElementsByTagName("itunes:duration")[0] || {}).textContent || "" })).filter((e2) => e2.url);
        j = { title: (x.querySelector("channel > title") || {}).textContent || p.name, items };
      }
      if (dead || seq !== pSeq) return;
      podEps = arrOf(j, "items", "episodes").filter((ep) => (ep.url || ep.audio) && pAlive(epDead, ep.url || ep.audio));
      if (!podEps.length) throw new Error("aucun épisode lisible dans ce flux");
      const show = String(j.title || p.name);
      pBody.replaceChildren(crumb(back, "Retour", show, h("span", { class: "ss" }, " · " + podEps.length + " épisodes récents")),
        ...(podEps.length ? [h("div", { class: "rows" }, ...podEps.slice(0, 25).map((ep) => epRow({ ...ep, url: ep.url || ep.audio || "", art: p.art, feed }, show)))] : [emptyState("podcast", "Aucun épisode lisible dans ce flux pour le moment.")]));
      paintEpProgress(); refreshMediaMarks();
    } catch (e) {
      if (dead || seq !== pSeq) return;
      podDead[podKey(p)] = Date.now(); LS.set(PODDEAD_KEY, podDead);
      ctx.toast("Podcast indisponible, retiré : " + p.name);
      back();
    }
  }
  function startPodcasts() { renderPod(); }

  showTab(tab);
  /* Cycle de vie (shell persistant) : onHide ne coupe rien — la TV vit dans le flottant du shell,
     l'audio dans le mini-lecteur. destroy : arrêt seulement si la vidéo est encore ici. */
  return {
    destroy: () => {
      dead = true;
      clearTimeout(stallTimer); clearTimeout(retryTimer); clearTimeout(startTimer); clearTimeout(hSaveT); IDB.set(HEALTH_IDB, health);
      for (const f of cleanups) { try { f(); } catch (e) {} }
      if (!(ctx.watch && ctx.watch.active())) stopTV();
    },
    onHide: () => {},
    onShow: () => { if (started.tv) paintResume(); },
  };
}
