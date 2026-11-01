/* Nova 2 — palette ⌘K. Huit états explicites (recherche design §2.2) :
   1) défaut : récents (frecency) + modules ; 2) saisie : résultats LOCAUX rendus dans la même
   frame que la frappe, recherche serveur en appoint ; 3) aucun résultat : sorties proposées, jamais
   une impasse ; 4) chargement : squelette à géométrie finale pendant la recherche serveur ;
   5) erreur/hors-ligne : les commandes locales marchent, la bande d'erreur le dit ;
   6) sous-page avec fil d'Ariane (thèmes, fond animé, brouillons) ; 7) multi-sélection (Tab) pour
   les approbations en lot ; 8) commande désactivée AVEC sa raison affichée. */
import { api, bus, esc, h, applyTheme, THEMES, reportError, showToast } from "./core.js";
import { ic } from "./icons.js";
import { DEPTHS, getDepth, depthInfo, costIncreaseText } from "./depth.js";   /* Phase 4 : profondeur de réflexion + alerte de coût */

const FREC_KEY = "nova2_frec";
let frec = {};
try { frec = JSON.parse(localStorage.getItem(FREC_KEY) || "{}"); } catch (e) {}
function bump(id) {
  const f = frec[id] || { n: 0, t: 0 }; f.n++; f.t = Date.now(); frec[id] = f;
  try { localStorage.setItem(FREC_KEY, JSON.stringify(frec)); } catch (e) {}
}
const frecScore = (id) => { const f = frec[id]; if (!f) return 0; const age = (Date.now() - f.t) / 86400000; return Math.min(f.n, 12) * (age < 1 ? 4 : age < 7 ? 2 : 1); };

/* Matching sous-séquence : renvoie un score (plus = mieux) ou -1. Bonus début de mot. */
function fuzzy(q, text) {
  q = q.toLowerCase(); text = String(text).toLowerCase();
  let qi = 0, score = 0, prevBoundary = true;
  for (let i = 0; i < text.length && qi < q.length; i++) {
    if (text[i] === q[qi]) { score += prevBoundary ? 3 : 1; qi++; }
    prevBoundary = /[\s\-_/]/.test(text[i]);
  }
  return qi === q.length ? score : -1;
}

export function initPalette(ctx) {
  const host = document.getElementById("pal");
  let open = false, page = null;         // page = { title, items() } pour les sous-pages
  let items = [], sel = 0, picked = new Set();
  let serverItems = [], serverPending = false, serverError = false, debounce = 0, lastQuery = "";
  let vaultLocked = null;                // null = inconnu ; true/false après /api/vault/status
  let refreshBusy = false;

  /* ── Registre de commandes ─────────────────────────────────────────── */
  function commands() {
    const list = [];
    for (const m of ctx.modules) list.push({
      id: "mod:" + m.id, icon: m.icon, title: "Ouvrir " + m.label, sub: m.desc, sec: "Modules",
      kbd: "@" + m.id,   // NOVA2-FIX (reco n°19) : le clavier se voit — « @module » = aller direct
      run: () => ctx.navigate(m.id),
    });
    list.push({ id: "act:refresh-module", icon: "refresh", title: "Recharger le module courant", sub: "Démonte et remonte l'écran affiché", sec: "Actions", run: () => ctx.refresh() });
    list.push({
      id: "act:refresh-portfolio", icon: "chart", title: "Rafraîchir le portefeuille BRVM", sub: "Recalcule cours et positions", sec: "Actions",
      disabled: () => (refreshBusy ? "Rafraîchissement déjà en cours" : null),
      run: async () => { refreshBusy = true; try { await api.post("/api/portfolio/refresh", {}); ctx.toast("Portefeuille rafraîchi."); } finally { refreshBusy = false; } },
    });
    list.push({
      id: "act:lock-vault", icon: "lock", title: "Verrouiller le coffre", sub: "Referme le coffre chiffré", sec: "Actions",
      disabled: () => (vaultLocked === true ? "Le coffre est déjà verrouillé" : null),
      run: async () => { await api.post("/api/vault/lock", {}); vaultLocked = true; ctx.toast("Coffre verrouillé."); },
    });
    list.push({ id: "page:themes", icon: "palette", title: "Thème…", sub: "Les " + THEMES.length + " thèmes Nova 2, appliqués en direct", sec: "Apparence", page: themesPage });
    list.push({ id: "page:bg", icon: "sun", title: "Fond animé…", sub: "Auto / Toujours / Jamais", sec: "Apparence", page: bgPage });
    list.push({ id: "page:modes", icon: "sparkle", title: "Profondeur de réflexion…", sub: DEPTHS.map((d) => d.label).join(" / ") + " — actuelle : " + depthInfo(getDepth()).label + " ; alerte si le coût monte", sec: "Actions", page: modesPage });   /* Phase 4 */
    list.push({ id: "act:vault-touchid", icon: "lock", title: "Coffre : Touch ID…", sub: "État de l'ouverture du coffre par Touch ID (Trousseau) ; l'activer si le coffre est ouvert", sec: "Actions", run: vaultTouchId });   /* Phase 4 */
    list.push({ id: "page:drafts", icon: "draft", title: "Brouillons à approuver…", sub: "Sélection multiple : Tab pour cocher, Entrée pour envoyer", sec: "Actions", kbd: "⇥", page: draftsPage });
    return list;
  }
  function themesPage() {
    return { title: "Thème", items: THEMES.map((t) => ({
      id: "theme:" + t.id, icon: "palette", title: t.name, sub: t.desc,
      run: async () => { if (applyTheme(t.id)) { try { await api.post("/api/settings", { theme: t.id }); } catch (e) { reportError(e, "settings theme", true); } } },
    })) };
  }
  /* Phase 4 : profondeur. Une hausse de coût s'annonce dans le toast existant, avec « Passer en … » comme action. */
  function modesPage() {
    return { title: "Profondeur de réflexion", items: DEPTHS.map((d) => ({
      id: "mode:" + d.id, icon: "sparkle", title: d.label + (d.id === getDepth() ? " (actuelle)" : ""), sub: d.hint,
      run: async () => {
        const apply = () => { try { localStorage.setItem("nova2_depth", String(d.id)); } catch (e) {} ctx.toast("Profondeur : " + d.label + " — vaut pour les prochaines questions."); };
        const msg = await costIncreaseText(getDepth(), d.id);
        if (!msg) { apply(); return; }
        showToast(msg, { action: { label: "Passer en " + d.label, onClick: apply }, ms: 15000 });
      },
    })) };
  }
  /* Phase 4 : coffre derrière Touch ID (routes NovaCore/VaultBiometric.swift). N'active rien sans un second geste. */
  async function vaultTouchId() {
    let st = null;
    try { st = await api.get("/api/vault/biometric/status", 8000); } catch (e) { ctx.toast("État Touch ID du coffre indisponible : " + ((e && e.message) || e), true); return; }
    if (!st || !st.registered) { ctx.toast("Touch ID du coffre : non branché dans ce build.", true); return; }
    if (st.enabled) { ctx.toast("Le coffre s'ouvre déjà par Touch ID."); return; }
    if (!st.available) { ctx.toast("Touch ID indisponible sur ce Mac" + (st.message ? " : " + st.message : "."), true); return; }
    showToast("Ouvrir le coffre par Touch ID ? La clé est copiée dans un élément du Trousseau protégé par Touch ID ; l'élément actuel est gardé.", { ms: 15000, action: { label: "Activer", onClick: async () => {
      try { const j = await api.post("/api/vault/biometric/enable", {}, 60000); ctx.toast(j && j.ok ? "Coffre : Touch ID activé." : "Activation refusée : " + ((j && j.error) || "?"), !(j && j.ok)); }
      catch (e) { ctx.toast("Activation refusée : " + ((e && e.message) || e), true); }
    } } });
  }
  function bgPage() {
    const modes = [["auto", "Auto", "Animé, avec repli statique si le GPU souffre"], ["always", "Toujours", "Animé en permanence"], ["never", "Jamais", "Dégradé statique uniquement"]];
    return { title: "Fond animé", items: modes.map(([id, name, desc]) => ({
      id: "bg:" + id, icon: "sun", title: name, sub: desc,
      run: async () => { if (window.NovaBG) window.NovaBG.setMode(id); try { await api.post("/api/settings", { bg_mode: id }); } catch (e) {} },
    })) };
  }
  async function draftsPage() {
    let drafts = [];
    try { const j = await api.get("/api/drafts"); drafts = (j && (j.drafts || j.items)) || []; } catch (e) { reportError(e, "palette drafts", true); }
    return { title: "Brouillons à approuver", items: drafts.map((d) => ({
      id: "draft:" + (d.id || ""), icon: "mail", multi: true,
      title: String(d.to || d.dest || "—"), sub: String(d.subject || d.objet || d.body || "").slice(0, 90),
      /* P-DRAFT-6 — LA PALETTE N'ENVOIE PLUS (remplace le geste LOT1/LOT4) : « montré pour
         avis » exige le corps ENTIER, or la palette n'affiche que le destinataire et 90
         caractères. Le geste palette navigue vers Messages et y fait ouvrir la carte du
         brouillon (coche + saisie ENVOYER + empreinte + preuve) : un seul chemin d'envoi,
         aucune surface d'exception. bus est déjà importé de core.js (palette.js:8). */
      run: async () => { ctx.navigate("messages"); setTimeout(() => bus.emit("nova:draft-focus", { id: d.id }), 350); },
    })) };
  }

  /* ── Rendu ─────────────────────────────────────────────────────────── */
  const input = h("input", { type: "text", placeholder: "Rechercher, commander…", "aria-label": "Palette de commandes" });
  const listEl = h("div", { class: "pal-list" });
  const crumb = h("div", { class: "pal-crumb" });
  const foot = h("div", { class: "pal-foot" });
  const box = h("div", { class: "pal-box", role: "dialog", "aria-modal": "true" },
    crumb,
    h("div", { class: "pal-input" }, h("span", { html: ic("search", 18) }), input,
      h("span", { class: "kbd" }, "esc")),
    listEl, foot);
  host.replaceChildren(box);

  function visibleItems() {
    if (page) return page.items;
    const q = input.value.trim();
    /* NOVA2-FIX (reco n°19) : préfixe « @module » — la frappe « @fin » ne propose que
       les modules, matchés sur id et libellé ; Entrée y va directement. Aucune
       recherche serveur dans ce mode (le matcher local suffit, réponse immédiate). */
    if (q.startsWith("@")) {
      const needle = q.slice(1).trim();
      return ctx.modules
        .map((m) => ({ m, s: needle ? Math.max(fuzzy(needle, m.id), fuzzy(needle, m.label)) : 1 }))
        .filter((x) => x.s >= 0)
        .sort((a, b) => b.s - a.s)
        .map((x) => ({ id: "mod:" + x.m.id, icon: x.m.icon, title: "Aller à " + x.m.label, sub: x.m.desc, sec: "Modules", kbd: "@" + x.m.id, run: () => ctx.navigate(x.m.id) }));
    }
    const all = commands();
    if (!q) {
      const recent = all.filter((c) => frec[c.id]).sort((a, b) => frecScore(b.id) - frecScore(a.id)).slice(0, 5);
      const rest = all.filter((c) => !recent.includes(c));
      return [...recent.map((c) => ({ ...c, sec: recent.length ? "Récent" : c.sec })), ...rest];
    }
    return all
      .map((c) => ({ c, s: Math.max(fuzzy(q, c.title), fuzzy(q, c.title + " " + (c.sub || "")) - 1) }))
      .filter((x) => x.s >= 0)
      .sort((a, b) => (b.s + frecScore(b.c.id)) - (a.s + frecScore(a.c.id)))
      .map((x) => x.c);
  }

  function render() {
    const q = input.value.trim();
    items = visibleItems();
    if (page) items = items.concat([]);   // sous-page : pas de recherche serveur
    if (!page && q && algItems.length) items = items.concat(algItems);   // 31/10 (biblio 3) : la BIBLIOTHÈQUE passe avant l'appoint serveur
    if (!page && q && serverItems.length) items = items.concat(serverItems);
    if (!page && q && semItems.length) items = items.concat(semItems);   // mémoire sémantique (relais Algolia puis copie locale), après l'index Algolia
    if (sel >= items.length) sel = Math.max(0, items.length - 1);
    crumb.className = "pal-crumb" + (page ? " show" : "");
    crumb.replaceChildren(h("span", { html: ic("back", 13) }), h("span", {}, page ? page.title : ""));
    listEl.replaceChildren();
    let lastSec = null;
    items.forEach((it, i) => {
      const dis = typeof it.disabled === "function" ? it.disabled() : null;
      if (it.sec && it.sec !== lastSec && !page) { lastSec = it.sec; listEl.append(h("div", { class: "pal-sec" }, it.sec)); }
      const row = h("button", {
        class: "pal-item" + (i === sel ? " sel" : "") + (dis ? " disabled" : ""),
        onclick: () => { sel = i; activate(); },
        onmousemove: () => { if (sel !== i) { sel = i; render(); } },
      },
        h("span", { html: ic(it.icon || "cmd", 18) }),
        h("span", { class: "grow" }, h("div", {}, it.title), h("div", { class: "ss" }, dis ? dis : (it.sub || ""))),
        it.kbd ? h("span", { class: "kbd" }, it.kbd) : null,   // NOVA2-FIX (reco n°19) : raccourci visible par ligne
        it.when ? h("span", { class: "when" }, it.when) : null,   // ALGOLIA (23/10) : date du résultat d'index
        it.multi ? h("span", { class: "chip" }, ...(picked.has(it.id) ? [h("span", { html: ic("check", 13) }), " coché"] : ["Tab"])) : null,
        it.page ? h("span", { class: "ss" }, "›") : null);
      listEl.append(row);
    });
    if (!page && q && serverPending) listEl.append(h("div", { class: "pal-sec" }, "Recherche"), h("div", { class: "skel", style: "height:38px;margin:2px 4px 6px" }), h("div", { class: "skel", style: "height:38px;margin:2px 4px" }));
    if (!page && serverError) listEl.append(h("div", { class: "pal-sec" }, "Moteur injoignable — les commandes locales ci-dessus fonctionnent."));
    if (!page && q && !q.startsWith("@")) {
      if (algPending) listEl.append(h("div", { class: "pal-sec" }, "Bibliothèque Nova"), h("div", { class: "skel", style: "height:38px;margin:2px 4px 6px" }));
      else if (algState === "off") listEl.append(h("div", { class: "pal-sec" }, "Bibliothèque Nova"), h("div", { class: "pal-sec" }, "Recherche d'index non configurée — la clé de recherche n'est pas encore en place."));
      else if (algState === "error") listEl.append(h("div", { class: "pal-sec" }, "Bibliothèque Nova"), h("div", { class: "pal-sec" }, "Index injoignable — vérifie la connexion, puis réessaie."));
      else if (algState === "empty") listEl.append(h("div", { class: "pal-sec" }, "Bibliothèque Nova"), h("div", { class: "pal-sec" }, "L'index est vide pour l'instant — rien n'y a encore été versé."));
      else if (algState === "none") listEl.append(h("div", { class: "pal-sec" }, "Bibliothèque Nova"), h("div", { class: "pal-sec" }, "Rien dans l'index pour « " + q + " »."));
      if (algItems.length && semState !== "ok") { /* 31/10 (biblio 3) : pas de bruit quand la bibliothèque a répondu */ }
      else if (semPending) listEl.append(h("div", { class: "pal-sec" }, "Mémoire sémantique"), h("div", { class: "skel", style: "height:38px;margin:2px 4px 6px" }));
      else if (semState === "off") listEl.append(h("div", { class: "pal-sec" }, "Mémoire sémantique"), h("div", { class: "pal-sec" }, "Mémoire sémantique non configurée — la recherche locale ci-dessus reste active."));
      else if (semState === "degraded") listEl.append(h("div", { class: "pal-sec" }, "Mémoire sémantique"), h("div", { class: "pal-sec" }, "Mémoire sémantique indisponible — la recherche locale continue de répondre."));
      else if (semState === "none") listEl.append(h("div", { class: "pal-sec" }, "Mémoire sémantique"), h("div", { class: "pal-sec" }, "Rien dans la mémoire sémantique pour « " + q + " »."));
    }
    if (!items.length && !serverPending && !algPending && !semPending) {
      listEl.append(h("div", { class: "empty" },
        h("div", {}, page ? "Rien ici pour l'instant." : "Aucun résultat pour « " + q + " »."),
        !page && q ? h("button", { class: "btn", onclick: () => { closePal(); ctx.navigate("accueil"); bus.emit("nova:ask", { text: q }); } }, "Poser la question à Nova") : null));
    }
    /* §9.9/D-34 : pied en DEUX zones — raccourcis essentiels à gauche, contexte à droite. */
    foot.replaceChildren(
      h("span", {}, picked.size ? picked.size + " sélectionné(s) — Entrée pour exécuter" : "↑↓ naviguer · Entrée valider · Échap retour"),
      h("span", { style: "flex:1" }),
      h("span", { title: "@module = aller direct · ⌃Tab / ⌥Tab = changer de module" }, page ? page.title : "@module · ⌃Tab/⌥Tab modules · Nova 2"));
  }

  /* ── Recherche serveur (appoint ; jamais bloquante) ────────────────── */
  function scheduleServerSearch() {
    clearTimeout(debounce); serverItems = []; serverError = false;
    const q = input.value.trim(); lastQuery = q;
    if (!q || page || q.startsWith("@")) { serverPending = false; return; }   // mode @module : local seulement
    serverPending = true;
    debounce = setTimeout(async () => {
      try {
        const j = await api.get("/api/search/all?q=" + encodeURIComponent(q));
        if (input.value.trim() !== lastQuery || !open) return;
        const arr = (j && (j.results || j.items)) || [];
        serverItems = arr.slice(0, 6).map((r, i) => ({
          id: "srv:" + i, icon: "search", sec: "Résultats", title: String(r.title || r.name || "Résultat"),
          sub: String(r.snippet || r.type || "").slice(0, 90),
          run: () => { if (r.module && ctx.modules.some((m) => m.id === r.module)) ctx.navigate(r.module); else ctx.navigate("accueil"); },
        }));
      } catch (e) { serverError = true; }
      serverPending = false; if (open) render();
    }, 160);
  }

  /* ── Index Nova — Algolia (23/10) ─────────────────────────────────────
     Recherche dans l'index Algolia « nova » (notes, mails, documents et
     news, amorcé hors app par le pilote). Config lue une fois par session
     via le canal magasin : GET /api/search/algolia-config (coquille Swift,
     Trousseau d'abord, repli fichier algolia_config.json du magasin). Seule
     la clé de RECHERCHE transite ; la clé Admin n'existe pas côté app.
     États honnêtes, jamais de résultat fabriqué : non configurée, index
     vide, aucun résultat pour la recherche, index injoignable. */
  const ALG_ICONS = { note: "note", mail: "mail", document: "file", news: "feed" };
  let algCfg = null, algCfgPromise = null;   // config résolue (null = absente ou non configurée)
  let algItems = [], algPending = false, algState = "", algDebounce = 0, lastAlgQuery = "";
  function loadAlgConfig() {
    if (!algCfgPromise) {
      algCfgPromise = api.get("/api/search/algolia-config", 6000)
        .then((j) => { algCfg = (j && j.app_id && j.search_key) ? { appId: String(j.app_id), key: String(j.search_key), index: String(j.index || "nova") } : null; })
        .catch(() => { algCfg = null; });
    }
    return algCfgPromise;
  }
  function algWhen(ts) {
    const n = Number(ts); if (!n) return "";
    const d = new Date(n * 1000); if (isNaN(d.getTime())) return "";
    return d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) + " " + d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  }
  function openAlgHit(hit) {
    const ref = String(hit.ref || "");
    if ((hit.type === "note" || hit.type === "mail") && ref) {
      /* Même voie que le panneau Conversations du rail (shell.js) : clé
         d'attente consommée au montage du module + événement s'il est monté. */
      try { localStorage.setItem("nova2_pending_conv", ref); } catch (e) {}
      ctx.navigate("conversations");
      bus.emit("nova:open-conv", { id: ref });
    } else if (hit.type === "document") ctx.navigate("livrables");
    else if (hit.type === "news") ctx.navigate("accueil");
    /* Type inconnu ou ref absente : aucune navigation sûre — on n'invente rien. */
  }
  async function algQuery(cfg, q) {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 6000);
    try {
      const r = await fetch("https://" + cfg.appId + "-dsn.algolia.net/1/indexes/" + encodeURIComponent(cfg.index) + "/query", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Algolia-Application-Id": cfg.appId, "X-Algolia-API-Key": cfg.key },
        body: JSON.stringify({ query: q, hitsPerPage: 20 }),
        signal: ctl.signal,
      });
      /* 24/10 : chaque requête Algolia est comptée par le suivi des crédits (usage mesuré par Nova) ; un refus 401/402/403/429 ouvre le disjoncteur. */
      try { fetch("/api/credits/count", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ provider: "algolia", status: r.status }) }).catch(() => {}); } catch (e) {}
      if (!r.ok) throw new Error("Algolia → " + r.status);
      return await r.json();
    } finally { clearTimeout(t); }
  }
  /* 31/10 (biblio 2) : la palette cherche dans la BIBLIOTHÈQUE Nova (Mac + bibliothèques, index
     nova-bibliotheque) par le moteur : GET /api/search/bibliotheque — la clé ne quitte jamais Swift.
     Entrée : ouvre le fichier. */
  const BIB_ICONS = { mac: "file", cafu: "note", memoire: "note", fundings: "file", savoir: "file", competences: "note", projets: "file", briefs: "note", dossiers: "file" };
  const BIB_LABELS = { mac: "Mac", cafu: "CAFU", memoire: "Mémoire", fundings: "Fundings", savoir: "Savoir", competences: "Compétences", projets: "Projets", briefs: "Briefs", dossiers: "Dossiers" };
  async function openBibHit(hit, reveal) {
    const chemin = String(hit.chemin || "");
    if (!chemin || chemin.startsWith("nova://")) { ctx.toast("Élément interne de Nova : demande-le dans le chat."); return; }
    try { const r = await api.post("/api/bibliotheque/ouvrir", { chemin, reveal: !!reveal }); if (r && r.ok === false) ctx.toast("Ouverture impossible : " + (r.message || "")); }
    catch (e) { ctx.toast("Ouverture impossible."); }
  }
  function scheduleAlgoliaSearch() {
    clearTimeout(algDebounce); algItems = []; algState = "";
    const q = input.value.trim(); lastAlgQuery = q;
    if (!q || page || q.startsWith("@")) { algPending = false; return; }   // mode @module et sous-pages : local seulement
    algPending = true;
    algDebounce = setTimeout(async () => {
      if (input.value.trim() !== lastAlgQuery || !open) { algPending = false; return; }
      try {
        const j = await api.get("/api/search/bibliotheque?k=20&q=" + encodeURIComponent(q), 8000);
        if (input.value.trim() !== lastAlgQuery || !open) return;
        if (!j || j.ok === false) { algState = "error"; }
        else {
          const hits = j.hits || [];
          if (!hits.length) algState = "none";
          else {
            algState = "ok";
            /* 31/10 (biblio 4) : UNE section (avant : un en-tête par source, répété quand les sources alternaient) ; le moteur
               renvoie un résultat par fichier (copies et jumeaux .md/.docx regroupés) : source · dossier · formats · extrait. */
            algItems = hits.map((hit) => {
              const chemin = String(hit.chemin || "");
              const interne = chemin.startsWith("nova://");
              const dossier = interne ? "" : String(hit.dossier || chemin.replace(/\/[^\/]*$/, ""));
              const fm = Array.isArray(hit.formats) && hit.formats.length > 1 ? " · " + hit.formats.join(" / ") : "";
              const cp = (hit.copies || 1) > 1 && !fm ? " · " + hit.copies + " copies" : "";
              const gen = hit.genere ? " · généré" : "";
              return {
              id: "bib:" + String(hit.id || chemin),
              icon: BIB_ICONS[hit.source] || "search",
              sec: "Bibliothèque Nova",
              title: String(hit.title || "(sans titre)"),
              sub: (BIB_LABELS[hit.source] || String(hit.source || "")) + (dossier ? " · " + dossier : "") + fm + cp + gen + " — " + String(hit.extrait || "").slice(0, 90),
              when: String(hit.date || ""),
              run: (ev) => openBibHit(hit, !!(ev && ev.altKey)),
              };
            });
          }
        }
      } catch (e) { if (input.value.trim() !== lastAlgQuery || !open) return; algState = "error"; }
      algPending = false; if (open) render();
    }, 250);
  }

  /* ── Mémoire sémantique — [tiers] (23/10, programme crédits) ──────────
     Appoint sémantique de la palette : la requête part à la coquille Swift
     (POST /api/search/semantic) qui seule détient la clé (Trousseau d'abord,
     repli du magasin) et appelle le service avec un
     délai de 4 s et un disjoncteur (3 échecs → désactivation + journal
     pinecone_journal.jsonl, réactivation manuelle). Le web ne voit jamais
     la clé. États honnêtes : non configurée, dégradée (le service est mort
     ou le disjoncteur est ouvert — la recherche locale et l'index Algolia
     continuent de répondre normalement), aucun résultat. Jamais bloquant :
     simple appoint après les résultats locaux, serveur et Algolia. */
  const SEM_ICONS = { note: "note", mail: "mail", document: "file", news: "feed" };
  let semItems = [], semPending = false, semState = "", semDebounce = 0, lastSemQuery = "";
  function scheduleSemanticSearch() {
    clearTimeout(semDebounce); semItems = []; semState = "";
    const q = input.value.trim(); lastSemQuery = q;
    if (!q || page || q.startsWith("@")) { semPending = false; return; }   // mode @module et sous-pages : local seulement
    semPending = true;
    semDebounce = setTimeout(async () => {
      try {
        const j = await api.post("/api/search/semantic", { q });
        if (input.value.trim() !== lastSemQuery || !open) return;
        if (!j || j.configured === false) semState = "off";
        else if (j.degraded) semState = "degraded";
        else {
          const hits = (j && j.hits) || [];
          if (!hits.length) semState = "none";
          else {
            semState = "ok";
            semItems = hits.map((hit) => ({
              id: "sem:" + String(hit.id || ""),
              icon: SEM_ICONS[hit.type] || "search",
              sec: "Mémoire sémantique",
              title: String(hit.title || "(sans titre)"),
              sub: String(hit.snippet || "").slice(0, 110) + (hit.score != null ? "  ·  score " + Number(hit.score).toFixed(3) : ""),
              when: algWhen(hit.ts),
              run: () => openAlgHit(hit),
            }));
          }
        }
      } catch (e) { if (input.value.trim() !== lastSemQuery || !open) return; semState = "degraded"; }
      semPending = false; if (open) render();
    }, 300);
  }

  /* ── Activation ────────────────────────────────────────────────────── */
  async function activate() {
    const it = items[sel]; if (!it) return;
    const dis = typeof it.disabled === "function" ? it.disabled() : null;
    if (dis) { ctx.toast(dis, true); return; }
    if (it.page) {
      const p = await it.page();
      page = p; picked.clear(); sel = 0; render(); return;
    }
    const batch = it.multi && picked.size ? items.filter((x) => picked.has(x.id)) : [it];
    closePal();
    for (const b of batch) { bump(b.id); try { await b.run(); } catch (e) { reportError(e, "palette " + b.id); ctx.toast("Échec : " + ((e && e.message) || e), true); } }
    picked.clear();
  }

  function openPal() {
    if (open) return; open = true; page = null; picked.clear(); sel = 0; serverItems = []; serverError = false; algItems = []; algState = ""; algPending = false; semItems = []; semState = ""; semPending = false;
    host.classList.add("open"); input.value = ""; render();
    requestAnimationFrame(() => input.focus());
    if (vaultLocked === null) api.get("/api/vault/status").then((j) => { vaultLocked = !!(j && (j.locked || j.state === "locked")); }).catch(() => {});
  }
  function closePal() { open = false; host.classList.remove("open"); }
  bus.on("nova:palette", openPal);
  host.addEventListener("mousedown", (e) => { if (e.target === host) closePal(); });
  input.addEventListener("input", () => { sel = 0; render(); scheduleServerSearch(); scheduleAlgoliaSearch(); scheduleSemanticSearch(); });
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); sel = Math.min(items.length - 1, sel + 1); render(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); sel = Math.max(0, sel - 1); render(); }
    else if (e.key === "Enter") { if (e.isComposing || e.keyCode === 229) return; e.preventDefault(); activate(); }
    else if (e.key === "Tab") {
      const it = items[sel];
      if (it && it.multi) { e.preventDefault(); picked.has(it.id) ? picked.delete(it.id) : picked.add(it.id); render(); }
    } else if (e.key === "Escape") {
      e.preventDefault();
      if (page) { page = null; picked.clear(); sel = 0; render(); } else closePal();
    }
  });
  return { open: openPal, close: closePal };
}
