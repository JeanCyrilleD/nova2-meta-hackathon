/* Module Paramètres — 4 écrans plats, cherchables, source de vérité UNIQUE : /api/settings.
   Nova 1 éparpillait les réglages entre /api/settings, 5 clés localStorage et deux fichiers JS :
   d'où les thèmes qui ne s'appliquaient pas. Ici chaque contrôle écrit immédiatement au serveur ;
   localStorage ne garde que le cache d'amorçage du thème et du fond (shell/bg). */
import { THEMES, DEFAULT_THEME, applyTheme, resolveTheme, identiteUserChoice, applyAppearance, readAppearanceCache, applyReducedTransparency, reducedTransparencyState, fmtDateFR, fmtTimeFR } from "../core.js";
import { approvalCard } from "../orb.js";
import { mountSourcesPanel } from "./sources-panel.js";   // V5-V/V5-W : « Sources de Nova » dans Données & comptes
import { gmailControl } from "./settings-gmail.js";   // 25/10 : Gmail en lecture directe IMAP (carte à côté de Zoho)

/* V5-W (25/10) — AUDIT DES RÉGLAGES : chaque ligne = titre, UNE ligne de description, contrôle aligné à
   droite ; le texte complet passe dans « ⓘ » (infobulle + dépliable au clic, lu par VoiceOver). Les
   contrôles riches (listes, curseurs, cartes) prennent toute la largeur sous leur titre. Les lignes sont
   regroupées en sous-blocs titrés. Aucune valeur ni aucun branchement moteur ne change. */
const SHORT = {
  "Notifications": "Mails urgents, Fundings, engagements, GO, Éclats — même hors de l'app.",
  "Notification d'essai": "Passe sur une autre app : l'essai arrive 8 s après le clic.",
  "Silence": "Plafond des interruptions proactives ; l'urgent passe toujours.",
  "Chronobiologie": "Créneaux de travail profond dans l'Agenda, d'après tes heures actives.",
  "Rituels": "Les rituels qui tournent, leur heure et leur dernier passage.",
  "Contenus adultes (18+)": "Chaînes 18+ dans Médias › TV. Désactivé par défaut.",
  "Cerveau par défaut": "Toujours essayé en premier ; la chaîne de secours prend le relais s'il échoue.",
  "Cerveau des Éclats": "Exécute les Éclats et tâches de fond, sans relais : choisis-en un qui a du crédit.",
  "Cerveaux actifs": "Coupé, un cerveau sort des chaînes de réponse ; seul le moteur confirme.",
  "Délai avant repli": "Attente maximale du premier mot avant de passer au cerveau suivant.",
  "Suggestions proactives": "« Nova te propose » : lectures et idées vérifiées, aux heures choisies.",
  "Autorisation totale": "Lève les confirmations locales ; envois et paiements restent confirmés.",
  "Conversation vocale live": "Parler à Nova comme au téléphone, interruptible.",
  "Luciole": "Les vols de la luciole vers le courrier, les Éclats et les approbations.",
  "Oublier les habitudes d'Éclat": "Ses vols repartent de zéro.",
  "Zoho Mail (campagne)": "Boîte de campagne lue en IMAP, lecture seule ; mot de passe au Trousseau.",
  "Gmail (lecture directe)": "Gmail lu en IMAP par Nova, lecture seule ; mot de passe d'application au Trousseau.",
  "Données web des volets": "Cookies et caches d'Outlook, Gmail… ; il faudra se reconnecter.",
  "Mot de réveil « Nova »": "Écoute locale fr-FR sur le Mac ; rien n'est stocké.",
  "Téléphone": "Pont Android par Tailscale ; les actions risquées restent validées sur le Mac.",
  "Thème": "Identité Promesse : Harmattan par défaut — chaque thème en Auto, Jour ou Nuit.",
  "Liquid Glass — matière": "Teinte, densité et flou du verre, aperçu en direct.",
  "Avatar de Nova": "Panda, Renard, Cœur Singularity ou orbe sobre.",
  "Style d'avatar": "Illustré, organique ou 3D (aperçu) ; repli automatique.",
};
const GROUPS = {
  general: [["Affichage", ["Fond animé", "Réduire les animations"]], ["Notifications", ["Notifications", "Notification d'essai", "Silence"]], ["Rythme", ["Chronobiologie", "Rituels"]], ["Médias", ["Contenus adultes (18+)"]]],
  look: [["Thème", ["Thème", "Liquid Glass — matière"]], ["Avatar", ["Avatar de Nova", "Style d'avatar"]], ["Accès", ["Rail étendu", "Réduire la transparence"]]],
  assistant: [["Cerveaux", ["Cerveau par défaut", "Cerveau des Éclats", "Mode démo encore actif", "Cerveaux actifs", "Délai avant repli", "Mode économie (lots)"]], ["Comportement", ["Suggestions proactives", "Autorisation totale", "Conversation vocale live"]], ["Compagnons", ["Saluts du panda", "Luciole", "Oublier les habitudes d'Éclat"]]],
  data: [["Comptes & sources", ["Clés de services", "Zoho Mail (campagne)", "Gmail (lecture directe)", "Sources de Nova"]], ["Sauvegarde & nettoyage", ["Sauvegarde", "Cache de l'interface", "Données web des volets"]]],
  appareils: [["Voix", ["Moteur de voix", "Mot de réveil « Nova »"]], ["Téléphone", ["Téléphone"]]],
};
function shortOf(label, desc) {
  if (SHORT[label]) return SHORT[label];
  const d = String(desc || "").trim();
  if (d.length <= 115) return d;
  const m = /^(.{30,115}?[.;:!?])\s/.exec(d);
  if (m) return m[1].replace(/[;:]$/, ".");
  return d.slice(0, 110).replace(/\s+\S*$/, "") + "…";
}

const SECTIONS = [
  { id: "general", icon: "gear", label: "Général", desc: "Démarrage, fond animé, mouvement, notifications." },
  { id: "look", icon: "palette", label: "Apparence & accès", desc: "Thème, rail, transparence." },
  { id: "assistant", icon: "brain", label: "Assistant", desc: "Cerveau par défaut, délais, modes du routeur." },
  { id: "data", icon: "shield", label: "Données & comptes", desc: "Clés au Trousseau, sauvegarde, cache." },
  { id: "appareils", icon: "mic", label: "Voix & téléphone", desc: "Moteur de voix, mot de réveil « Nova » et téléphone appairé — états lus en direct sur le moteur." },
];
let activeSec = SECTIONS[0].id;
let searching = false;

export async function mount(root, ctx) {
  const { api, bus, h, ic } = ctx;
  let dead = false;
  root.classList.add("mod--wide");   // plafond Réglages (§2.3)
  let settings = {}, brains = [], keys = [];
  let settingsLocked = false;   // D-30 : vrai si AUCUNE source de réglages n'a pu être lue
  root.append(h("div", { class: "mod-head" },
    h("h1", {}, "Réglages"),
    h("span", { class: "sub" }, "Chaque changement s'applique tout de suite — et se voit.")));

  const searchIn = h("input", { type: "text", placeholder: "Rechercher un réglage…" });
  root.append(h("div", { class: "searchbox" }, h("span", { html: ic("search", 16) }), searchIn));

  const nav = h("div", { class: "set-nav" });
  const body = h("div", {});
  root.append(h("div", { class: "set-grid" }, nav, body));

  async function save(patch) {
    if (settingsLocked) { ctx.toast("Réglages non lus : modifications désactivées.", true); throw new Error("settingsLocked"); }
    try { const j = await api.post("/api/settings", patch); if (j && j.settings) settings = j.settings; }
    catch (e) { ctx.toast("Réglage non enregistré : " + ((e && e.message) || e), true); throw e; }
  }
  const get = (k, d) => (settings[k] !== undefined ? settings[k] : d);

  function seg(options, value, onchange) {
    const el = h("div", { class: "seg" });
    for (const [v, label] of options) {
      const b = h("button", { class: v === value ? "on" : "", onclick: async () => { el.querySelectorAll("button").forEach((x) => x.classList.remove("on")); b.classList.add("on"); await onchange(v); } }, label);
      el.append(b);
    }
    return el;
  }
  function sw(value, onchange) {
    const b = h("button", { class: "switch", role: "switch", "aria-checked": value ? "true" : "false",
      onclick: async () => { const v = b.getAttribute("aria-checked") !== "true"; b.setAttribute("aria-checked", String(v)); await onchange(v); } });
    return b;
  }
  function row(sec, label, desc, control, extra = "") {
    /* V5-N : une bascule sans nom était muette pour VoiceOver (et introuvable par libellé) — elle prend le libellé de sa ligne. */
    try { if (control && control.getAttribute && control.getAttribute("role") === "switch" && !control.getAttribute("aria-label")) control.setAttribute("aria-label", String(label)); } catch (e) {}
    const short = shortOf(label, desc);
    const full = String(desc || "") !== short ? String(desc || "") : "";
    const fullEl = full ? h("div", { class: "ds-full", hidden: true }, full) : null;
    const info = full ? h("button", { class: "set-info", type: "button", title: full, "aria-label": "En savoir plus : " + full, "aria-expanded": "false",
      onclick: (e) => { e.stopPropagation(); fullEl.hidden = !fullEl.hidden; info.setAttribute("aria-expanded", String(!fullEl.hidden)); info.classList.toggle("on", !fullEl.hidden); } }, "i") : null;
    /* Contrôle compact (bascule, segments, bouton, sélecteur, pastilles) → à droite ; contrôle riche → pleine largeur. */
    let wide = false;
    try { wide = !!control && !(control.matches && control.matches("button, .switch, .seg, select, .fld, .keys-chips, .og-ctl")); } catch (e) {}
    let compact = false;
    try { compact = !!control && !!(control.matches && control.matches(".switch, button")); } catch (e) {}
    return { sec, label, el: h("div", { class: "set-row" + (wide ? " set-row--wide" : "") + (compact ? " set-row--compact" : ""), "data-q": (label + " " + desc + " " + extra).toLowerCase() },
      h("div", { class: "grow set-main" }, h("div", { class: "lb" }, h("span", {}, label), info), h("div", { class: "ds" }, short), fullEl),
      h("div", { class: "set-ctl" }, control)) };
  }

  /* NOVA2-FIX (reco n°15) : curseur Liquid Glass clair ↔ teinté. La position mappe
     --glass-tint et --glass-blur ; aperçu en direct dès le glissement
     (applyGlass), enregistrement serveur au relâchement seulement.
     §32 (21/10 ~09:02, constat d'Ahadi « poussé à fond, il ne fait rien ») :
     plage ÉLARGIE pour un effet impossible à manquer — tint 0,3 → 2,4
     (×8 sur les alphas) et flou 11 → 48 px (l'ancienne plage 0,55→1,5 /
     17→32 px était quasi invisible sur le fond sombre uni des Réglages). */
  /* LOT WEB v3 / R4 §5.6-5.7 : la matière se règle sur TROIS axes
     indépendants (Teinte / Densité / Flou), chacun 0-100, défaut 50,
     aperçu en direct et enregistrement au relâchement. Deux préréglages
     explicites : Clair (25/35/45) et Teinté (80/80/65). Si la transparence
     réduite est active, les curseurs sont SUSPENDUS (disabled + badge
     nommant la source) — jamais écrasés : les valeurs repartent intactes
     à la réactivation. */
  function glassControl() {
    const initial = (get("appearance_tint") != null || get("appearance_density") != null || get("appearance_blur") != null)
      ? { tint: Number(get("appearance_tint", 50)), density: Number(get("appearance_density", 50)), blur: Number(get("appearance_blur", 50)) }
      : readAppearanceCache();
    const effects = {
      tint: "la couleur de la matière dans le verre",
      density: "l'opacité des surfaces de verre",
      blur: "la profondeur du flou derrière le verre",
    };
    const names = { tint: "Teinte", density: "Densité", blur: "Flou" };
    const wrap = h("div", { class: "appearance-controls" });
    const inputs = {}, valueEls = {};
    const rt = reducedTransparencyState();
    const rtSetting = get("reduce_transparency", false) === true || get("reduce_transparency", false) === "true" || get("reduce_transparency", false) === 1;
    const suspended = rt.reduced || rtSetting;
    const source = rt.system ? "système" : "application";
    const badge = h("div", { class: "appearance-badge", role: "status", hidden: !suspended },
      "Matière suspendue — Transparence réduite (source : " + source + "). Tes réglages sont conservés.");
    const reactivate = h("button", { class: "btn sm", hidden: !(suspended && !rt.system) }, "Réactiver la matière");
    reactivate.addEventListener("click", async () => {
      applyReducedTransparency(false, "application");
      await save({ reduce_transparency: false });
      wrap.querySelectorAll("input[type=range], .appearance-presets .btn").forEach((el) => { el.disabled = false; });
      badge.hidden = true; reactivate.hidden = true;
      ctx.toast("Matière restaurée : Teinte " + inputs.tint.value + " · Densité " + inputs.density.value + " · Flou " + inputs.blur.value);
    });
    const saveAppearance = (vals) => {
      const legacyTint = Math.round((0.3 + (vals.tint / 100) * 2.1) * 100) / 100;
      const legacyBlur = Math.round(11 + (vals.blur / 100) * 37);
      return save({ appearance_tint: vals.tint, appearance_density: vals.density, appearance_blur: vals.blur, glass_tint: legacyTint, glass_blur: legacyBlur });
    };
    const readVals = () => ({ tint: Number(inputs.tint.value), density: Number(inputs.density.value), blur: Number(inputs.blur.value) });
    const paint = () => { const v = readVals(); for (const k of Object.keys(inputs)) valueEls[k].textContent = names[k] + " " + v[k] + " — " + effects[k]; return v; };
    for (const key of ["tint", "density", "blur"]) {
      const rng = h("input", { type: "range", class: "glass-range", min: "0", max: "100", value: String(initial[key]), "aria-label": names[key] + " — " + effects[key] });
      rng.disabled = suspended;
      const val = h("span", { class: "ss appearance-value" }, "");
      valueEls[key] = val; inputs[key] = rng;
      rng.addEventListener("input", () => { applyAppearance(paint(), { persist: true }); });
      rng.addEventListener("change", () => { saveAppearance(paint()).catch(() => {}); });
      wrap.append(h("div", { class: "appearance-row" }, h("span", { class: "appearance-name" }, names[key]), rng, val));
    }
    const preset = (label, vals) => {
      const b = h("button", { class: "btn sm", disabled: suspended ? "" : null, onclick: () => {
        for (const k of Object.keys(inputs)) inputs[k].value = String(vals[k]);
        applyAppearance(paint(), { persist: true });
        saveAppearance(paint()).catch(() => {});
      } }, label);
      if (suspended) b.disabled = true;
      return b;
    };
    wrap.append(h("div", { class: "appearance-presets" },
      h("span", { class: "ss" }, "Préréglages :"),
      preset("Clair", { tint: 25, density: 35, blur: 45 }),
      preset("Teinté", { tint: 80, density: 80, blur: 65 })));
    wrap.append(badge, reactivate);
    if (suspended && rt.system) badge.textContent += " Le commutateur Nova affiche « piloté par le système ».";
    paint();
    return wrap;
  }

  /* LIQUID GLASS PREMIUM (21/10) : sélecteur de thème VISUEL — une carte par
     thème : le mesh d'ambiance du thème (champ swatch du registre), un
     échantillon de son verre posé dessus (chip : vrai mini-verre, flou et
     liseré), la pastille d'accent, le nom et l'intention. Application
     immédiate (applyTheme) + enregistrement serveur, comme l'ancien seg. */
  function themeControl() {
    /* 30/10 : identité « Promesse » — ses trois thèmes sont montrés ; les thèmes précédents restent
       disponibles derrière « Afficher les thèmes précédents » (le thème actif est toujours visible). */
    const PRIMARY = THEMES.filter((t) => t.identite).map((t) => t.id);
    let showAllThemes = false;
    const resolved = resolveTheme(String(document.documentElement.dataset.themeChoice || get("theme", DEFAULT_THEME)));
    const cur = resolved ? resolved.id : DEFAULT_THEME;
    const grid = h("div", { class: "theme-families", role: "radiogroup", "aria-label": "Thème : identité et mode jour/nuit" });
    /* 24/10 (soir) : trois thèmes signature, chacun en Auto / Jour / Nuit — une famille par ligne. */
    const FAMILIES = [
      /* 30/10 : identité « Promesse » en tête — Harmattan par défaut (docs/identite/IDENTITE.md). */
      { material: "harmattan", name: "Harmattan", tag: "Signature — l'identité Promesse, par défaut : brume d'harmattan, latérite, indigo, or d'étoile" },
      { material: "fleuve", name: "Fleuve", tag: "Travail calme — porcelaine, ardoise, eau du Niger" },
      { material: "sentinelle", name: "Sentinelle", tag: "Contraste élevé — opaque, zéro flou, lisible partout" },
      /* V5-L2 : Sable CAFU en tête, RECOMMANDÉ (planche Design System v8.0) — le défaut reste Obsidienne (décision d'Ahadi). */
      { material: "sable", name: "Sable CAFU", tag: "Thème précédent — la planche v8.0 : céramique, cramoisi, bronze" },
      { material: "obsidienne", name: "Obsidienne & Or Solaire", tag: "Thème précédent — l'ancienne identité de Nova" },
      { material: "verre", name: "Verre Céleste", tag: "Liquid Glass neutre, Nova Iris" },
      { material: "graphite", name: "Graphite Studio", tag: "Mat, zéro flou, contraste maximal" },
    ];
    const wrap = h("div", {}, grid);
    const cards = [];
    const paintSel = () => cards.forEach(({ card, badge, t }) => {
      const on = card.classList.contains("on");
      card.setAttribute("aria-checked", on ? "true" : "false");
      card.tabIndex = on ? 0 : -1;   // tabindex tournant : un seul arrêt de tabulation pour le groupe
      if (badge) { if (on) badge.removeAttribute("hidden"); else badge.setAttribute("hidden", ""); }
      void t;
    });
    const selectCard = async (card, t, focusIt) => {
      identiteUserChoice();   // 30/10 : un choix explicite n'est jamais re-migré
      if (!applyTheme(t.id)) return;
      cards.forEach(({ card: c }) => c.classList.remove("on"));
      card.classList.add("on");
      paintSel();
      if (focusIt) card.focus();
      await save({ theme: t.id });   // id canonique matière-mode : la migration des anciens ids est explicite (core.resolveTheme)
    };
    const renderGrid = () => {
      cards.length = 0;
      grid.replaceChildren();
      const list = showAllThemes ? THEMES : THEMES.filter((t) => PRIMARY.includes(t.id) || t.id === cur);
      const rows = {};
      for (const f of FAMILIES) {
        if (!list.some((t) => t.material === f.material)) continue;   // 30/10 : pas d'en-tête de famille vide
        const row = h("div", { class: "theme-grid" });
        grid.append(h("div", { class: "theme-fam" }, h("div", { class: "theme-fam-h" }, h("b", {}, f.name), h("span", {}, f.tag)), row));
        rows[f.material] = row;
      }
      for (const t of list) {
        const badge = h("span", { class: "micro", ...(t.id === cur ? {} : { hidden: "" }) }, h("span", { class: "dotst ok" }), " Actif");
        const card = h("button", { class: "theme-card" + (t.id === cur ? " on" : ""), role: "radio", "aria-checked": t.id === cur ? "true" : "false", tabindex: t.id === cur ? "0" : "-1",
          onclick: () => selectCard(card, t, false) },
          h("div", { class: "theme-swatch", style: "background:" + t.swatch },
            h("div", { class: "theme-chip", style: "background:" + t.chip }),
            h("span", { class: "theme-dot", style: "background:" + t.accent })),
          h("div", { class: "theme-meta" }, h("b", {}, t.name), h("span", {}, t.desc), badge));
        cards.push({ card, badge, t });
        (rows[t.material] || grid).append(card);
      }
    };
    renderGrid();
    const toggle = h("button", { class: "btn ghost sm", "aria-expanded": "false" }, "Afficher les thèmes précédents");
    toggle.addEventListener("click", () => {
      showAllThemes = !showAllThemes;
      toggle.setAttribute("aria-expanded", showAllThemes ? "true" : "false");
      toggle.textContent = showAllThemes ? "Masquer les thèmes précédents" : "Afficher les thèmes précédents";
      renderGrid();
      paintSel();
    });
    wrap.append(h("div", { style: "margin-top:10px" }, toggle));   // 30/10 : thèmes précédents à la demande
    grid.addEventListener("keydown", (e) => {   // navigation par flèches du radiogroup (D-31)
      const idx = cards.findIndex(({ card }) => card === document.activeElement);
      if (idx < 0) return;
      let n = null;
      if (e.key === "ArrowRight" || e.key === "ArrowDown") n = (idx + 1) % cards.length;
      else if (e.key === "ArrowLeft" || e.key === "ArrowUp") n = (idx - 1 + cards.length) % cards.length;
      else if (e.key === "Home") n = 0;
      else if (e.key === "End") n = cards.length - 1;
      if (n != null) { e.preventDefault(); selectCard(cards[n].card, cards[n].t, true); }
    });
    return wrap;
  }

  /* V5-G (24/10) : deux capacités du moteur sans écran jusqu'ici.
     Mot de réveil — Feat_Wake.swift : GET /api/wake/status {running, available, error, hits},
     POST /api/wake/start (200 {ok, running} | 500 {error}), POST /api/wake/stop. L'interrupteur
     ne bouge QU'APRÈS la réponse du moteur. 25/10 : start/stop posent le réglage « wake_word » ;
     activé, le moteur relance l'écoute au démarrage, et « Nova » entendu lance le Live (carillon).
     Téléphone — Bridge.swift : GET /api/bridge/state {enabled, running, port, addresses, devices[]},
     POST /api/bridge/enable {enabled}, /api/bridge/newcode (200 {code, valid_seconds…} | 409 {error}),
     /api/bridge/revoke {id}. Le pont n'écoute que sur l'adresse Tailscale (100.64/10). */
  const cleanups = [];
  const errOf = (e) => (e && e.body && (e.body.error || e.body.message)) || (e && e.message) || String(e);
  /* Version Meta : voix système macOS (AVSpeechSynthesizer, meilleure voix française installée) — seul moteur.
     GET /api/voix/locale {moteur, disponible, voix{nom, qualite}}. */
  function voiceEngineControl() {
    const status = h("span", { class: "og-status" }, "Lecture de la voix locale…");
    const sel = seg([["local", "Voix du Mac"]], "local",
      async (v) => {
        await save({ voix_moteur: v });
        ctx.toast("Voix système du Mac : rien ne part sur Internet.");
      });
    (async () => {
      try {
        const j = await api.get("/api/voix/locale");
        if (dead) return;
        const qn = { premium: "Premium", amelioree: "Améliorée", standard: "standard" };
        if (j && j.disponible && j.voix) status.textContent = "Voix locale : " + j.voix.nom + " (" + (qn[j.voix.qualite] || j.voix.qualite || "") + ", " + j.voix.langue + ").";
        else status.textContent = "Aucune voix française installée — Réglages Système › Accessibilité › Contenu énoncé.";
      } catch (e) { if (!dead) status.textContent = "Voix locale : état illisible — le moteur ne répond pas."; }
    })();
    return h("div", { class: "og-ctl" }, status, sel);
  }
  function wakeControl() {
    const status = h("span", { class: "og-status" }, "Lecture de l'état…");
    const btn = h("button", { class: "switch", role: "switch", "aria-checked": "false", "aria-label": "Mot de réveil « Nova »" });
    btn.disabled = true;
    let running = false, busy = false;
    const paint = (j) => {
      running = !!(j && j.running);
      btn.setAttribute("aria-checked", String(running));
      const avail = !!(j && j.available);
      btn.disabled = !avail && !running;
      if (running) status.textContent = "À l'écoute — dis « Nova »" + (Number(j.hits) > 0 ? " · entendu " + j.hits + " fois" : "") + ".";
      else if (!avail) status.textContent = "Indisponible : la reconnaissance vocale locale en français n'est pas prise en charge sur ce Mac.";
      else status.textContent = "Coupé — rien n'est écouté." + (j && j.error ? " Dernière erreur : " + j.error : "");
    };
    async function load() {
      try { const j = await api.get("/api/wake/status"); if (!dead) paint(j); }
      catch (e) { if (!dead) { btn.disabled = true; status.textContent = "État du mot de réveil illisible — le moteur ne répond pas."; } }
    }
    btn.addEventListener("click", async () => {
      if (busy || btn.disabled) return;
      busy = true; btn.disabled = true;
      const target = !running;
      btn.setAttribute("aria-checked", String(running));
      status.textContent = target ? "Démarrage de l'écoute locale… macOS peut demander l'accès au micro." : "Arrêt de l'écoute…";
      try {
        const j = await api.post(target ? "/api/wake/start" : "/api/wake/stop", {}, 30000);
        if (dead) return;
        ctx.toast(j && j.running ? "Mot de réveil actif : dis « Nova »." : "Mot de réveil coupé.");
      } catch (e) { if (!dead) ctx.toast("Mot de réveil : " + errOf(e), true); }
      busy = false;
      if (!dead) await load();
    });
    try { const off = bus.on("wake_state", () => { if (!busy && !dead) load(); }); if (typeof off === "function") cleanups.push(off); } catch (e) {}
    load();
    return h("div", { class: "og-ctl" }, status, btn);
  }
  /* V5-O (25/10) — Silence, Chronobiologie, Rituels : trois réglages RÉELLEMENT branchés au moteur.
     Silence — GET /api/silence {on, cap, mail, today:{shown, held}, quiet:{from, to, now}, held_items[]} ;
       réglages silence_mode / silence_cap / silence_mail par /api/settings ; le compteur vient du moteur.
     Rituels — GET /api/rituels [{id, nom, heure, actif, dernier_passage, disponible, interrupteur, note, lead, choix}] ;
       POST /api/rituels/global {on}, /api/rituels/toggle {id, on}, /api/rituels/lead {min}.
     Rien n'est affiché sans la réponse du moteur : route muette → ligne « illisible », jamais un faux état. */
  const lastFR = (v) => { if (!v) return "jamais encore"; const d = fmtDateFR(v); return d ? d + " · " + fmtTimeFR(v) : "jamais encore"; };
  function silenceControl() {
    const wrap = h("div", { class: "v5o-box" });
    const capSel = h("select", { class: "fld v5o-sel", "aria-label": "Plafond de notifications par jour" },
      ...[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((n) => h("option", { value: String(n) }, n + " / jour")));
    capSel.value = String(Number(get("silence_cap", 3)) || 3);
    capSel.addEventListener("change", async () => { try { await save({ silence_cap: Number(capSel.value) }); load(); } catch (e) {} });
    const swOn = sw(get("silence_mode", true) !== false, async (v) => { try { await save({ silence_mode: v }); } catch (e) {} capSel.disabled = !v; load(); });
    swOn.setAttribute("aria-label", "Silence : plafond des interruptions");
    capSel.disabled = get("silence_mode", true) === false;
    const swMail = sw(get("silence_mail", false) === true, async (v) => { try { await save({ silence_mail: v }); } catch (e) {} load(); });
    swMail.setAttribute("aria-label", "Compter aussi les nouveaux mails dans le plafond");
    const todayEl = h("div", { class: "v5o-line ss ss--wrap", role: "status" }, "Lecture du compteur…");
    const heldEl = h("div", { class: "v5o-held" });
    async function load() {
      let j = null;
      try { j = await api.get("/api/silence"); } catch (e) { j = null; }
      if (dead) return;
      const t = j && j.today;
      if (!t || typeof t.shown !== "number") { todayEl.textContent = "Compteur illisible — le moteur ne répond pas."; heldEl.replaceChildren(); return; }
      const q = j.quiet || {};
      const qTxt = q.from && q.to ? " · heures calmes " + q.from + "–" + q.to + (q.now ? " (en cours : rien ne sonne, sauf l'urgent)" : "") : "";
      todayEl.textContent = (j.on ? "Aujourd'hui : " + t.shown + " affichée" + (t.shown > 1 ? "s" : "") + ", " + t.held + " retenue" + (t.held > 1 ? "s" : "") + " (plafond " + j.cap + ")"
        : "Plafond coupé — toutes les notifications non urgentes s'affichent (aujourd'hui : " + t.shown + " comptée" + (t.shown > 1 ? "s" : "") + ")") + qTxt + ".";
      const items = Array.isArray(j.held_items) ? j.held_items.slice(0, 3) : [];
      heldEl.replaceChildren(...items.map((x) => h("div", { class: "v5o-held-it ss" }, "Retenue · " + (x.ts ? fmtTimeFR(x.ts) + " · " : "") + String(x.title || x.source || "notification") + (x.body ? " — " + String(x.body).slice(0, 90) : ""))));
    }
    wrap.append(
      h("div", { class: "v5o-head" }, h("span", { class: "ss" }, "Plafond actif"), swOn),
      h("div", { class: "v5o-head" }, h("span", { class: "ss" }, "Notifications non urgentes affichées au plus"), capSel),
      h("div", { class: "v5o-head" }, h("span", { class: "ss ss--wrap" }, "Compter aussi les nouveaux mails — par défaut ils passent tous, comme tu l'as demandé le 24/10"), swMail),
      todayEl, heldEl);
    load();
    return wrap;
  }
  /* V5-U (25/10) — « Nova te propose » : suggestions_on (true) + suggestions_par_jour (1–3, 3), par /api/settings ;
     l'état du jour (créneaux passés, dernier passage) vient de GET /api/suggestions — muet = « illisible », jamais un faux état. */
  function suggestionsControl() {
    const wrap = h("div", { class: "v5o-box" });
    const n0 = Math.min(3, Math.max(1, Number(get("suggestions_par_jour", 3)) || 3));
    const per = seg([["1", "1"], ["2", "2"], ["3", "3"]], String(n0), async (v) => { try { await save({ suggestions_par_jour: Number(v) }); } catch (e) {} load(); });
    per.setAttribute("aria-label", "Suggestions par jour");
    const swOn = sw(get("suggestions_on", true) !== false, async (v) => {
      try { await save({ suggestions_on: v }); ctx.toast(v ? "Suggestions proactives rallumées." : "Suggestions proactives coupées — le bouton « Propose-moi quelque chose » reste disponible."); } catch (e) {}
      per.classList.toggle("is-off", !v); load();
    });
    swOn.setAttribute("aria-label", "Suggestions proactives");
    per.classList.toggle("is-off", get("suggestions_on", true) === false);
    const stEl = h("div", { class: "v5o-line ss ss--wrap", role: "status" }, "Lecture des créneaux…");
    const KL = { lecture: "lecture", a_voir: "à voir", opportunite: "opportunité", a_faire: "à préparer" };
    async function load() {
      let j = null;
      try { j = await api.get("/api/suggestions"); } catch (e) { j = null; }
      if (dead) return;
      if (!j || !Array.isArray(j.slots)) { stEl.textContent = "État des suggestions illisible — le moteur ne répond pas."; return; }
      const sl = j.slots.map((x) => String(x.heure || "") + " " + (Array.isArray(x.kinds) ? x.kinds.map((k) => KL[k] || k).join("/") : "") + (x.etat && x.etat !== "à venir" ? " (" + x.etat + ")" : "")).join(" · ");
      const lr = j.last_run && j.last_run.ts ? " · dernier passage " + fmtTimeFR(j.last_run.ts) + " : " + String(j.last_run.status || "") : "";
      stEl.textContent = (j.on === false ? "Coupées — aucun créneau automatique." : "Aujourd'hui : " + sl + (j.quiet ? " · heures calmes en cours (rien ne part)" : "")) + lr + ".";
    }
    wrap.append(
      h("div", { class: "v5o-head" }, h("span", { class: "ss" }, "Suggestions actives"), swOn),
      h("div", { class: "v5o-head" }, h("span", { class: "ss" }, "Au plus, par jour"), per),
      stEl);
    load();
    return wrap;
  }
  function rituelsControl() {
    const wrap = h("div", { class: "v5o-box" });
    const listEl = h("div", { class: "v5o-list" }, h("div", { class: "ss" }, "Lecture des rituels…"));
    let busy = false;
    const swAll = sw(get("rituels_on", true) !== false, async (v) => {
      if (busy) return; busy = true; swAll.disabled = true;
      try { const j = await api.post("/api/rituels/global", { on: v }); if (!j || j.ok !== true) throw new Error("réponse sans ok"); settings.rituels_on = v; paint(j.items); ctx.toast(v ? "Rituels réactivés." : "Rituels coupés — briefs, brief pré-réunion et rituels-Éclats en pause."); }
      catch (e) { swAll.setAttribute("aria-checked", String(!v)); ctx.toast("Bascule refusée : " + ((e && e.message) || e), true); }
      busy = false; swAll.disabled = false;
    });
    swAll.setAttribute("aria-label", "Tous les rituels");
    function line(r) {
      const meta = [String(r.heure || ""), r.disponible === false ? "" : "dernier passage : " + lastFR(r.dernier_passage), r.note ? String(r.note) : ""].filter(Boolean).join(" · ");
      let ctl;
      if (r.disponible === false) ctl = h("span", { class: "chip" }, "non disponible");
      else if (r.interrupteur === false) ctl = h("span", { class: "chip" }, r.actif ? "actif" : "coupé");
      else {
        ctl = h("button", { class: "switch", role: "switch", "aria-checked": r.actif ? "true" : "false", "aria-label": "Rituel " + String(r.nom || r.id) });
        ctl.addEventListener("click", async () => {
          const target = ctl.getAttribute("aria-checked") !== "true";
          ctl.disabled = true;
          try { const j = await api.post("/api/rituels/toggle", { id: r.id, on: target }); if (!j || j.ok !== true) throw new Error((j && j.error) || "réponse sans ok"); paint(j.items); }
          catch (e) { ctx.toast("Rituel non modifié : " + ((e && e.message) || e), true); ctl.disabled = false; }
        });
      }
      const extra = [];
      if (r.id === "reunion" && Array.isArray(r.choix)) {
        extra.push(seg(r.choix.map((n) => [String(n), n + " min"]), String(r.lead || 30), async (v) => {
          try { const j = await api.post("/api/rituels/lead", { min: Number(v) }); if (!j || j.ok !== true) throw new Error("réponse sans ok"); paint(j.items); ctx.toast("Brief pré-réunion préparé " + v + " min avant."); }
          catch (e) { ctx.toast("Avance non enregistrée : " + ((e && e.message) || e), true); }
        }));
      }
      return h("div", { class: "v5o-rit" + (r.disponible === false ? " is-off" : "") },
        h("div", { class: "grow" }, h("div", { class: "v5o-rit-nm" }, String(r.nom || r.id)), h("div", { class: "ss ss--wrap" }, meta), ...extra), ctl);
    }
    function paint(items) {
      if (!Array.isArray(items)) { listEl.replaceChildren(h("div", { class: "ss" }, "Rituels illisibles — le moteur ne répond pas.")); return; }
      listEl.replaceChildren(...(items.length ? items.map(line) : [h("div", { class: "ss" }, "Aucun rituel déclaré.")]));
    }
    (async () => { let j = null; try { j = await api.get("/api/rituels"); } catch (e) { j = null; } if (!dead) paint(j); })();
    wrap.append(h("div", { class: "v5o-head" }, h("span", { class: "ss" }, "Tous les rituels"), swAll), listEl);
    return wrap;
  }
  /* V5-S (25/10) — ZOHO MAIL (CAMPAGNE). La connexion est faite par Ahadi lui-même, ici : adresse, mot de passe
     d'APPLICATION Zoho (jamais réaffiché, jamais gardé dans la page : le champ est vidé dès l'envoi), serveur.
     Le moteur essaie la connexion IMAP (lecture seule), puis range le mot de passe au Trousseau macOS
     (service « nova-zoho-imap ») ; la réponse ne renvoie que {ok, account, server}. Nova ne marque, ne déplace
     et n'envoie rien : EXAMINE + BODY.PEEK, liste blanche de commandes (GET /api/zoho/selftest). */
  function zohoControl() {
    const DEFAULT_ACCOUNT = "campagne@nova-campagne.example";
    const wrap = h("div", { class: "og-phone og-zoho" });
    let busy = false;
    const when = (iso) => { try { const d = new Date(iso); return isNaN(d) ? "" : d.toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }); } catch (e) { return ""; } };
    const emailIn = h("input", { type: "email", class: "fld", value: DEFAULT_ACCOUNT, autocomplete: "off", spellcheck: "false", "aria-label": "Adresse de la boîte Zoho", style: "flex:1 1 220px;min-width:0" });
    const pwIn = h("input", { type: "password", value: "", autocomplete: "new-password", placeholder: "mot de passe d'application Zoho", "aria-label": "Mot de passe d'application Zoho", style: "flex:1 1 270px;min-width:0" });
    const SERVERS = [["auto", "Automatique"], ["imappro.zoho.com", "imappro.zoho.com"], ["imap.zoho.com", "imap.zoho.com"], ["imappro.zoho.eu", "imappro.zoho.eu"]];
    const srvSel = h("select", { class: "sel", "aria-label": "Serveur IMAP Zoho" }, ...SERVERS.map(([v, l]) => h("option", { value: v }, l)));
    const statusEl = h("span", { class: "og-status" }, "Lecture de l'état…");
    const dotEl = h("span", { class: "dotst off" });
    const connectBtn = h("button", { class: "btn sm acc" }, "Connecter");
    const syncBtn = h("button", { class: "btn sm" }, "Synchroniser");
    const offBtn = h("button", { class: "btn sm danger" }, "Déconnecter");
    const listEl = h("div", { class: "og-zoho-list", style: "display:flex;flex-direction:column;gap:2px" });
    const modeEl = h("div", { class: "ss" }, "");
    async function loadList(st) {
      if (!st.connected || !st.count) { listEl.replaceChildren(); return; }
      try {
        const j = await api.get("/api/zoho/messages?limit=5");
        if (dead) return;
        const ms = (j && Array.isArray(j.messages)) ? j.messages : [];
        listEl.replaceChildren(h("div", { class: "ss", style: "font-weight:600;margin-top:4px" }, "Derniers messages lus (lecture seule)"),
          ...ms.map((m) => h("div", { class: "ss", style: "white-space:nowrap;overflow:hidden;text-overflow:ellipsis", title: String(m.fundings || "") },
            (m.lu === false ? "● " : "") + when(m.date) + " · " + String(m.from_name || m.from || "—") + " — " + String(m.subject || "(sans objet)"))));
      } catch (e) { if (!dead) listEl.replaceChildren(); }
    }
    function paint(st) {
      const connected = !!st.connected;
      if (st.account) emailIn.value = String(st.account);
      if (st.server_choice) srvSel.value = String(st.server_choice);
      let txt;
      if (connected && st.error) txt = "Connecté — erreur à la dernière synchro : " + String(st.error);
      else if (connected) txt = "Connecté — " + String(st.account || "") + " · " + String(st.server || "") + (st.last_ok ? " · dernière synchro " + when(st.last_ok) : " · première synchro en cours") + (st.count ? " · " + st.count + " messages lus" : "") + (st.unread != null ? " · " + st.unread + " non lus" : "");
      else if (st.error) txt = "Non connecté — " + String(st.error);
      else txt = "Non connecté — le canal Fundings reste alimenté par les passes du pilote.";
      statusEl.textContent = st.syncing ? txt + " · synchro en cours…" : txt;
      dotEl.className = "dotst " + (connected && !st.error ? "ok" : (st.error ? "err" : "off"));
      syncBtn.disabled = busy || !connected || !!st.syncing;
      offBtn.disabled = busy || !connected;
      connectBtn.disabled = busy;
      connectBtn.textContent = connected ? "Reconnecter" : "Connecter";
      modeEl.textContent = st.direct_active
        ? "Lecture directe ACTIVE : le canal Fundings se remplit depuis la boîte ; un push du pilote déjà vu en direct est ignoré (aucun doublon)."
        : "Lecture directe inactive : le canal Fundings accepte les pushes du pilote, comme aujourd'hui.";
      loadList(st);
    }
    async function load() {
      let st;
      try { st = await api.get("/api/zoho/status"); }
      catch (e) { if (!dead) { statusEl.textContent = "État de la boîte Zoho illisible — le moteur ne répond pas."; dotEl.className = "dotst err"; } return; }
      if (!dead) paint(st || {});
    }
    connectBtn.addEventListener("click", async () => {
      const email = String(emailIn.value || "").trim();
      const password = String(pwIn.value || "");
      pwIn.value = "";   // jamais gardé dans la page, jamais réaffiché
      if (!email || !password) { ctx.toast("Saisis l'adresse et le mot de passe d'application Zoho.", true); return; }
      busy = true; connectBtn.disabled = true; statusEl.textContent = "Connexion à Zoho… (essai IMAP en lecture seule)";
      try {
        const j = await api.post("/api/zoho/connect", { email, password, server: srvSel.value || "auto" }, 90000);
        if (!dead) ctx.toast("Boîte Zoho connectée (" + String((j && j.server) || "") + ") — première synchronisation en cours.");
      } catch (e) { if (!dead) ctx.toast("Zoho : " + errOf(e), true); }
      busy = false;
      if (!dead) load();
    });
    syncBtn.addEventListener("click", async () => {
      busy = true; syncBtn.disabled = true; statusEl.textContent = "Synchronisation… (lecture seule)";
      try {
        const j = await api.post("/api/zoho/sync", {}, 150000);
        if (!dead) ctx.toast(j && j.ok ? "Zoho : " + (j.nouveaux || 0) + " nouveau(x) message(s), " + (j.fundings || 0) + " événement(s) Fundings." : "Zoho : " + String((j && j.error) || "synchro non faite"), !(j && j.ok));
      } catch (e) { if (!dead) ctx.toast("Zoho : " + errOf(e), true); }
      busy = false;
      if (!dead) load();
    });
    offBtn.addEventListener("click", async () => {
      if (!offBtn.dataset.armed) { offBtn.dataset.armed = "1"; offBtn.textContent = "Confirmer ?"; setTimeout(() => { try { if (offBtn.isConnected) { delete offBtn.dataset.armed; offBtn.textContent = "Déconnecter"; } } catch (e2) {} }, 4000); return; }
      delete offBtn.dataset.armed; offBtn.textContent = "Déconnecter";
      busy = true;
      try { await api.post("/api/zoho/disconnect", {}); if (!dead) ctx.toast("Boîte Zoho déconnectée — mot de passe effacé du Trousseau."); }
      catch (e) { if (!dead) ctx.toast("Zoho : " + errOf(e), true); }
      busy = false;
      if (!dead) load();
    });
    try { const off = bus.on("zoho", () => { if (!busy && !dead) load(); }); if (typeof off === "function") cleanups.push(off); } catch (e) {}
    wrap.append(
      h("div", { class: "og-ctl" }, h("span", { class: "og-status" }, dotEl, " ", statusEl)),
      h("div", { style: "display:flex;gap:8px;flex-wrap:wrap;align-items:center" }, emailIn, pwIn, srvSel),
      h("div", { style: "display:flex;gap:8px;flex-wrap:wrap" }, connectBtn, syncBtn, offBtn),
      h("div", { class: "ss", style: "font-weight:600" }, "Lecture seule — Nova ne marque, ne déplace et n'envoie rien."),
      h("div", { class: "ss" }, "Zoho › Paramètres › Sécurité › Mots de passe d'application ; IMAP doit être activé dans Zoho › Paramètres › Comptes de messagerie › IMAP."),
      modeEl, listEl);
    load();
    return wrap;
  }
  function phoneControl() {
    const wrap = h("div", { class: "og-phone" });
    let codeTimer = null;
    const stopTimer = () => { if (codeTimer) { clearInterval(codeTimer); codeTimer = null; } };
    cleanups.push(stopTimer);
    const isTs = (a) => { const p = String(a).split(".").map(Number); return p.length === 4 && p[0] === 100 && p[1] >= 64 && p[1] <= 127; };
    async function load() {
      let st;
      try { st = await api.get("/api/bridge/state"); }
      catch (e) { if (!dead) wrap.replaceChildren(h("div", { class: "ss" }, "État du pont téléphone illisible — le moteur ne répond pas."), h("button", { class: "btn sm", onclick: load }, "Réessayer")); return; }
      if (dead) return;
      render(st || {});
    }
    function render(st) {
      stopTimer();
      const enabled = !!st.enabled, running = !!st.running;
      const ts = (Array.isArray(st.addresses) ? st.addresses : []).map(String).filter(isTs);
      const devices = Array.isArray(st.devices) ? st.devices.filter((d) => d && d.id) : [];
      const port = Number(st.port) || 0;
      const sw0 = h("button", { class: "switch", role: "switch", "aria-checked": String(enabled), "aria-label": "Pont téléphone" });
      sw0.addEventListener("click", async () => {
        sw0.disabled = true;
        try { const j = await api.post("/api/bridge/enable", { enabled: !enabled }); if (!dead) ctx.toast(String((j && j.note) || (enabled ? "Pont désactivé." : "Pont activé."))); }
        catch (e) { if (!dead) ctx.toast("Pont téléphone : " + errOf(e), true); }
        if (!dead) load();
      });
      const stateTxt = !enabled ? "Désactivé — aucun port ouvert pour le téléphone."
        : running ? "Actif sur Tailscale" + (ts[0] ? " · " + ts[0] + (port ? ":" + port : "") : "") + "."
        : "Activé, mais le pont ne tourne pas : Tailscale n'est pas détecté sur ce Mac.";
      const tsTxt = ts.length ? "Tailscale détecté (" + ts.join(", ") + ")." : "Tailscale non détecté : installe-le et connecte-toi pour appairer un téléphone.";
      const head = h("div", { class: "og-ctl" }, h("span", { class: "og-status" }, h("span", { class: "dotst " + (enabled && running ? "ok" : enabled ? "err" : "off") }), " ", stateTxt), sw0);
      const codeBox = h("div", { class: "og-code-box" });
      const codeBtn = h("button", { class: "btn sm" }, "Afficher un code d'appairage");
      codeBtn.addEventListener("click", async () => {
        codeBtn.disabled = true;
        try {
          const j = await api.post("/api/bridge/newcode", {});
          if (dead) return;
          const code = String((j && j.code) || "");
          if (!/^\d{6}$/.test(code)) throw new Error("code absent de la réponse du moteur");
          let left = Number(j.valid_seconds) || 300;
          const addr = (Array.isArray(j.addresses) ? j.addresses.map(String).filter(isTs) : [])[0] || ts[0] || "";
          const cd = h("span", { class: "ss" }, "");
          const tick = () => { cd.textContent = "Valable " + Math.floor(left / 60) + " min " + String(left % 60).padStart(2, "0") + " s · usage unique"; };
          tick();
          const hide = h("button", { class: "btn sm ghost" }, "Masquer");
          const close = () => { stopTimer(); codeBox.replaceChildren(); codeBtn.hidden = false; codeBtn.disabled = false; };
          hide.addEventListener("click", close);
          stopTimer();
          codeTimer = setInterval(() => { left -= 1; if (left <= 0 || dead) { close(); if (!dead) ctx.toast("Code d'appairage expiré."); return; } tick(); }, 1000);
          codeBtn.hidden = true;
          codeBox.replaceChildren(h("div", { class: "og-code" },
            h("div", { class: "og-digits", "aria-label": "Code d'appairage " + code.split("").join(" ") }, code.slice(0, 3), h("span", { class: "og-gap" }), code.slice(3)),
            h("div", { class: "grow" },
              h("div", {}, addr ? "Sur le téléphone : adresse " + addr + (j.port ? ":" + j.port : "") + ", puis ce code." : "Saisis ce code dans l'application du téléphone."),
              cd),
            hide));
          load2();
        } catch (e) {
          if (dead) return;
          codeBtn.disabled = false;
          ctx.toast(errOf(e), true);
        }
      });
      async function load2() { try { const s2 = await api.get("/api/bridge/state"); if (!dead && s2) { const ok = !!s2.running; head.querySelector(".dotst").className = "dotst " + (ok ? "ok" : "err"); sw0.setAttribute("aria-checked", String(!!s2.enabled)); } } catch (e) {} }
      const devList = h("div", { class: "og-devs" });
      if (!devices.length) devList.append(h("div", { class: "ss" }, "Aucun téléphone appairé."));
      for (const d of devices) {
        const name = String(d.name || "Téléphone");
        const rv = h("button", { class: "btn sm ghost" }, "Révoquer");
        let armT = null;
        rv.addEventListener("click", async () => {
          if (!rv.dataset.armed) {
            rv.dataset.armed = "1"; rv.classList.add("danger-solid"); rv.textContent = "Confirmer la révocation";
            armT = setTimeout(() => { if (rv.isConnected) { delete rv.dataset.armed; rv.classList.remove("danger-solid"); rv.textContent = "Révoquer"; } }, 4000);
            return;
          }
          clearTimeout(armT); rv.disabled = true;
          try { const j = await api.post("/api/bridge/revoke", { id: String(d.id) }); if (dead) return; if (!(j && j.ok)) throw new Error("révocation non confirmée par le moteur"); ctx.toast("« " + name + " » révoqué : son jeton ne vaut plus rien."); }
          catch (e) { if (!dead) ctx.toast("Révocation impossible : " + errOf(e), true); }
          if (!dead) load();
        });
        devList.append(h("div", { class: "og-dev" },
          h("span", { class: "og-dev-ic", html: ic("talk", 15) }),
          h("div", { class: "grow" }, h("div", { class: "og-tt" }, name),
            h("div", { class: "ss" }, ["appairé le " + (d.since ? fmtDay(d.since) : "date inconnue"), d.seen ? "vu " + fmtDay(d.seen) : "pas vu depuis le lancement de Nova"].join(" · "))),
          rv));
      }
      wrap.replaceChildren(head, h("div", { class: "ss og-ts" }, tsTxt), h("div", { class: "og-code-row" }, codeBtn, codeBox), devList);
    }
    const fmtDay = (v) => { const d = new Date(v); return isNaN(d) ? "date inconnue" : new Intl.DateTimeFormat("fr-FR", { dateStyle: "medium", timeStyle: "short" }).format(d); };
    wrap.append(h("div", { class: "ss" }, "Lecture de l'état…"));
    load();
    return wrap;
  }

  /* V5-W : « Sources de Nova » (sources-panel.js, V5-V) monté dans une ligne pleine largeur ; son propre
     en-tête est masqué ici (le titre et la ligne de la rangée le remplacent). Un seul panneau vivant :
     le précédent est détruit à chaque reconstruction des lignes et au démontage. */
  let sourcesPanel = null;
  cleanups.push(() => { try { if (sourcesPanel) sourcesPanel.destroy(); } catch (e) {} sourcesPanel = null; });
  function sourcesControl() {
    try { if (sourcesPanel) sourcesPanel.destroy(); } catch (e) {}
    const wrap = h("div", { class: "set-sources" });
    try { sourcesPanel = mountSourcesPanel(wrap, ctx); } catch (e) { sourcesPanel = null; wrap.append(h("div", { class: "ss" }, "Panneau des sources indisponible : " + ((e && e.message) || e))); }
    return wrap;
  }
  function buildRows() {
    /* §30 (21/10) : l'état brut du moteur (« non_teste ») ne s'affiche jamais
       tel quel — libellés humains ; U6 (23/10) : repli « état inconnu »,
       jamais le jeton brut (avant : underscores remplacés, jeton affiché). */
    const etatFr = (e) => ({ non_teste: "non testé", teste: "testé", ok: "testé", erreur: "en erreur", ko: "en erreur" })[e] || "état inconnu";
    // DIAG2-CERVEAUX : l'option « auto » a disparu — le moteur la réécrit en « spark-1.3 »
    // à la lecture (Settings.all) et au démarrage (P-BRAIN) : la proposer était un choix illusoire.
    // Le défaut est un cerveau nommé, épinglé à chaque run ; la chaîne ne sert que de secours en cas d'échec.
    // 01/11 (voix-rapide) : meta_only → seuls les cerveaux Meta (le moteur filtre déjà ; filet si une ligne meta === false subsiste).
    const brainOpts = brains.filter((b) => !(get("meta_only", false) === true && b && b.meta === false)).map((b) => [String(b.id || ""), String(b.label || b.id || "") + (b.etat ? " — " + etatFr(b.etat) : "")]).filter((x) => x[0]);
    const brainSel = h("select", { class: "fld", onchange: async () => { await save({ brain: brainSel.value }); ctx.toast("Cerveau par défaut enregistré."); } },
      ...brainOpts.map(([v, l]) => h("option", { value: v, ...(v === String(get("brain", "spark-1.3")) ? { selected: "" } : {}) }, l)));
    /* 25/10 : cerveau des Éclats (dots_brain) — épinglé SANS relais pour les tâches de fond (solo) : quand ses
       crédits manquent, tous les Éclats échouent. Aucun écran ne le réglait ; le voici, à côté du défaut. */
    const dotsSel = h("select", { class: "fld", onchange: async () => { await save({ dots_brain: dotsSel.value }); ctx.toast("Cerveau des Éclats enregistré."); } },
      ...brainOpts.filter(([v]) => v && v !== "auto").map(([v, l]) => h("option", { value: v, ...(v === String(get("dots_brain", "spark-1.3")) ? { selected: "" } : {}) }, l)));
    /* CHANTIER-BASCULES (22/10) : gouvernance des cerveaux DANS Réglages.
       Le moteur expose POST /api/brains/toggle (App.swift:891 — corps {id, enabled} :
       enabled=false → le cerveau entre dans brains_off persisté, sinon il en sort ;
       réponse {ok:true}) mais AUCUN contrôle ne l'appelait (recette S3 : la
       « Gouvernance des cerveaux » de Système est un affichage lecture seule et
       Réglages ne présentait que les deux sélecteurs ci-dessus). Ici : une bascule
       par cerveau servi, au même endroit. État initial lu dans brains_off RÉEL
       (get) — jamais dans l'état santé servi, qui peut différer (le héros de démo
       en brains_off n'est pas servi « désactivé »). Le visuel ne bouge QU'APRÈS
       confirmation du moteur : en cas d'échec, retour à l'état antérieur et
       erreur nommée — jamais de bascule fantôme. La pseudo-ligne « Local (aucun
       moteur détecté) » (etat « absent », Router.swift:110) n'est pas un cerveau :
       elle est exclue. L'id envoyé vient toujours du catalogue servi. */
    const offSet = new Set((get("brains_off", []) || []).map((x) => String(x)));
    function brainToggleLine(b) {
      const id = String(b.id || "");
      const name = String(b.label || id);
      const det = String(b.detail || "");
      const errLike = /erreur|ko|échec|echec|panne/i.test(String(b.etat || "")) || /HTTP \d{3}|error|échec|refus/i.test(det);
      const healthK = errLike ? "bad" : (b.etat === "ok" || b.etat === "teste") ? "ok" : "n";
      /* V5-W : la dernière erreur se replie (cause en clair d'abord, texte brut au clic) — fini les JSON sur 8 lignes. */
      const errHuman = /credit balance|insufficient[_ ]quota|billing/i.test(det) ? "Crédits épuisés chez le fournisseur" : /\b401\b|invalid[_ ]api[_ ]key|unauthori/i.test(det) ? "Clé refusée" : /\b429\b|rate limit/i.test(det) ? "Limite de débit atteinte" : "";
      const nFail = (/(\d+)\s+échecs?/i.exec(det) || [])[1];
      const detShown = det === "désactivé par vous" ? "" : det;
      const stateEl = h("span", { class: "br-chip " + (offSet.has(id) ? "off" : "on") }, offSet.has(id) ? "Coupé" : "Actif");
      const healthEl = h("span", { class: "br-chip h-" + healthK }, b.etat ? etatFr(b.etat) : "état inconnu");
      const errEl = errLike && detShown ? h("details", { class: "br-err" },
        h("summary", {}, (errHuman || "Dernière erreur") + (nFail ? " · " + nFail + " échecs" : "")),
        h("code", {}, detShown)) : (detShown ? h("div", { class: "br-note" }, detShown) : null);
      const btn = h("button", { class: "switch", role: "switch", "aria-checked": offSet.has(id) ? "false" : "true", "aria-label": "Activer ou couper " + name,
        onclick: async () => {
          if (btn.disabled) return;
          const target = offSet.has(id);   // enabled visé = inverse de l'état courant (coupé → true, actif → false) ; « enabled » est TOUJOURS envoyé (absent, la route réactive)
          btn.disabled = true;
          try {
            const j = await api.post("/api/brains/toggle", { id, enabled: target });
            if (!j || j.ok !== true) throw new Error("réponse du moteur sans ok");
            if (target) offSet.delete(id); else offSet.add(id);
            settings["brains_off"] = [...offSet].sort();
            btn.setAttribute("aria-checked", String(target));
            stateEl.textContent = target ? "Actif" : "Coupé"; stateEl.className = "br-chip " + (target ? "on" : "off");
          } catch (e) {
            btn.setAttribute("aria-checked", String(!target));   // état antérieur = état moteur, inchangé
            ctx.toast("Bascule refusée pour " + name + " : " + ((e && e.message) || e), true);
          }
          btn.disabled = false;
        } });
      return h("div", { class: "br-line" },
        h("div", { class: "grow br-main" }, h("div", { class: "br-name", title: name }, name), h("div", { class: "br-chips" }, stateEl, healthEl), errEl), btn);
    }
    function brainsToggleControl() {
      /* COSMETIQUE-WEB (22/10, recette S4) : la classe brains-toggles borne la
         largeur du conteneur côté CSS (nova2.css, règle « .set-row > .brains-toggles »,
         famille D-R8 / V8-RÉSIDUEL) — sans elle, ce div nu hérite du flex:none des
         contrôles de .set-row et sa largeur max-content écrase la description. */
      const wrap = h("div", { class: "brains-toggles" });
      let n = 0;
      for (const b of brains) { if (!String(b.id || "") || b.etat === "absent") continue; wrap.append(brainToggleLine(b)); n++; }
      if (!n) wrap.append(h("div", { class: "ss" }, "Catalogue non lu — état des cerveaux inconnu."));
      return wrap;
    }
    return [
      /* ── Général ── */
      row("general", "Fond animé", "Le fond WebGL unique de Nova 2. Auto = animé, avec repli statique si le GPU souffre.",
        seg([["auto", "Auto"], ["always", "Toujours"], ["never", "Jamais"]], String(get("bg_mode", "auto")),
          async (v) => { if (window.NovaBG) window.NovaBG.setMode(v); await save({ bg_mode: v }); }), "fond arriere-plan animation webgl"),
      row("general", "Réduire les animations", "Coupe les respirations de l'orbe et les transitions de l'interface.",
        sw(!!get("reduce_motion", false), async (v) => { document.documentElement.dataset.reduceMotion = v ? "1" : ""; await save({ reduce_motion: v }); }), "mouvement accessibilite"),
      /* 25/10 : le compagnon flottant se gouverne aussi ici (avant : seulement le menu de la barre). */
      row("general", "Compagnon flottant", "Nova sur ton bureau, au-dessus des autres apps : un clic pour lui parler, clic droit pour son menu (apparence, Live, masquer). Tu peux le déplacer en le glissant.",
        sw(get("companion_float", true) !== false, async (v) => { await save({ companion_float: v }); try { window.webkit.messageHandlers.nova.postMessage({ cmd: "companionApply" }); } catch (e) {} }), "compagnon avatar flottant bureau panda mascotte"),
      row("general", "Notifications", "Nova te prévient quand tu n'es pas dans l'app : mails urgents, Fundings, engagements en retard, GO en attente, Éclats terminés. Heures calmes respectées ; un clic ouvre l'élément.",
        sw(!!get("notify", true), async (v) => { await save({ notify: v }); }), "alertes briefs notifications"),
      /* 01/11 : conversations qui attendent Ahadi (autorisation, envoi à approuver, GO) et travaux longs finis. */
      row("general", "Notifications des conversations", "Une notification quand une conversation attend ton action (autorisation, envoi à approuver, GO) ou quand un travail long se termine hors de ta vue (réponse, Éclat, note CAFU). Rien si le fil est déjà affiché. Heures calmes respectées, sauf une autorisation qui bloque Nova. Pastille du Dock : demandes en attente.",
        sw(get("notif_conversations", true) !== false, async (v) => { await save({ notif_conversations: v }); }), "notifications conversations autorisation approbation go attente pastille dock badge travail termine"),
      /* 24/10 : essai réel du circuit de notification natif (macOS demande l'autorisation la première fois). */
      row("general", "Notification d'essai", "Passe sur une autre app après le clic : la notification arrive 8 s plus tard (rien ne s'affiche si Nova est au premier plan).",
        (() => { const b = h("button", { class: "btn sm", type: "button" }, "Envoyer un essai"); b.addEventListener("click", async () => { b.disabled = true; try { const j = await api.post("/api/notify/test", {}); ctx.toast(j && j.ok ? "Essai programmé dans 8 s — passe sur une autre app." : "Essai refusé par le moteur.", !(j && j.ok)); } catch (e) { ctx.toast("Moteur injoignable pour l'essai.", true); } setTimeout(() => { b.disabled = false; }, 9000); }); return b; })(), "notification test essai"),
      /* V5-O : Silence (#15), Chronobiologie (#18), Rituels (#20/#26) — branchés au moteur. */
      row("general", "Silence", "Plafond réel des interruptions proactives (Éclats, briefs, Fundings, engagements, GO, pastilles) : au-delà, plus de notification — l'élément reste dans le Fil direct. L'urgent passe toujours ; les heures calmes restent la règle horaire.",
        silenceControl(), "silence plafond interruptions notifications retenues heures calmes mails"),
      row("general", "Chronobiologie", "Créneaux de travail profond dans l'Agenda : tes heures les plus actives (14 j, messages et actions réels) croisées avec ton agenda libre. Rien n'est bloqué sans ton GO.",
        sw(get("chronobio_on", true) !== false, async (v) => { await save({ chronobio_on: v }); ctx.toast(v ? "Créneaux de travail profond affichés dans l'Agenda." : "Chronobiologie coupée."); }), "chronobiologie travail profond creneaux pic agenda"),
      row("general", "Rituels", "Les rituels qui tournent vraiment, leur heure et leur dernier passage. Un rituel absent du parc est dit « non disponible ».",
        rituelsControl(), "rituels brief matin fermeture soir reunion sparring dictee reve ce qu'on laisse"),
      /* V5-R : contenus 18+ de l'écran Médias — désactivés par défaut, confirmation d'âge demandée une
         fois. Réglage local à ce Mac (lu par web/js/modules/radio.js) ; éteint, les flux marqués xxx /
         is_nsfw de l'index iptv-org ne sont ni chargés dans les listes, ni cherchables, ni suggérés. */
      row("general", "Contenus adultes (18+)", "Affiche dans Médias › TV les chaînes 18+ de l'index public iptv-org (catégorie « xxx »). Désactivé par défaut ; une confirmation d'âge est demandée une fois.",
        (() => {
          const rd = (k) => { try { return localStorage.getItem(k) === "1"; } catch (e) { return false; } };
          const wr = (k, v) => { try { localStorage.setItem(k, v ? "1" : "0"); } catch (e) {} };
          const b = h("button", { class: "switch", role: "switch", "aria-checked": String(rd("nova2_media_adult") && rd("nova2_media_adult_ack")), "aria-label": "Contenus adultes (18+)" });
          b.addEventListener("click", async () => {
            const want = b.getAttribute("aria-checked") !== "true";
            if (want && !rd("nova2_media_adult_ack")) {
              const card = approvalCard({ title: "Contenus adultes (18+)", what: "Ces chaînes sont réservées aux adultes. En continuant, tu confirmes avoir 18 ans ou plus. L'option reste désactivable à tout moment ici.", approveLabel: "J'ai 18 ans ou plus", editLabel: null, refuseLabel: "Annuler" });
              b.closest(".set-row").after(card);
              const v = await card.promise; card.remove();
              if (v !== "approve") return;
              wr("nova2_media_adult_ack", true);
            }
            wr("nova2_media_adult", want);
            b.setAttribute("aria-checked", String(want));
            try { window.dispatchEvent(new CustomEvent("nova:media-adult", { detail: { on: want } })); } catch (e) {}
            ctx.toast(want ? "Contenus 18+ affichés dans Médias." : "Contenus 18+ masqués.");
          });
          return b;
        })(), "adulte 18 xxx contenus medias tv iptv"),
      /* ── Assistant ── */
      row("assistant", "Cerveau par défaut", "Le cerveau imposé à chaque réponse : épinglé, il est toujours essayé en premier — ni une désactivation ni une quarantaine crédit ne l'écartent. S'il échoue, la chaîne réduite prend le relais (local en filet, délai global 25 s) et la bascule s'affiche sous la réponse.",
        brainSel, "modele ia brain routeur"),
      row("assistant", "Cerveau des Éclats", "Le cerveau qui exécute les Éclats, briefs et tris de fond. Il est épinglé sans relais : s'il n'a plus de crédit, ces tâches échouent — choisis-en un qui répond.",
        dotsSel, "eclats dots brain fond taches"),
      /* FIX-WEB (audit P2 settings.js:274-280) : « Mode démo (concours) » et « Cerveau de démo » (Muse Spark)
         retirés de l'interface de production. Seul reste, si le réglage est encore allumé côté moteur,
         un bouton pour l'éteindre — sinon le mode resterait actif sans moyen visible de le couper. */
      ...(get("demo_mode", false) ? [row("assistant", "Mode démo encore actif", "Un ancien mode démo envoie encore chaque réponse sur le cerveau de démo au lieu du cerveau par défaut. Éteins-le.",
        h("button", { class: "btn sm", onclick: async (e) => { const b = e.currentTarget; b.disabled = true; try { await save({ demo_mode: false }); } catch (err) { b.disabled = false; return; } ctx.toast("Mode démo éteint : retour au cerveau par défaut."); const r = b.closest(".set-row"); if (r) r.hidden = true; } }, "Éteindre le mode démo"), "demo")] : []),
      /* CHANTIER-BASCULES (22/10) : la gouvernance elle-même — voir le bloc
         brainToggleLine ci-dessus. L'index de recherche porte les noms et ids
         des cerveaux : chercher un cerveau trouve enfin cette ligne (en S3,
         la recherche retombait sur un panneau vide). */
      row("assistant", "Cerveaux actifs", "Chaque cerveau du catalogue, gouverné ici : coupé, il sort des chaînes de réponse et le reste après relance ; réactivé, il y rentre. L'état affiché vient de ta liste réelle (brains_off) et chaque bascule n'affiche que ce que le moteur a confirmé.",
        brainsToggleControl(), "cerveaux actifs gouverner desactiver activer catalogue routeur brains_off " + brains.map((b) => String(b.label || "") + " " + String(b.id || "")).join(" ")),
      row("assistant", "Délai avant repli", "Temps maximal d'attente du premier mot d'un cerveau cloud avant de passer au suivant.",
        seg([["4", "4 s"], ["6", "6 s"], ["9", "9 s"], ["15", "15 s"]], String(get("firstTokenTimeout", 6)),
          async (v) => { await save({ firstTokenTimeout: Number(v) }); }), "timeout latence failover"),
      row("assistant", "Suggestions proactives", "« Nova te propose », comme Muse : une lecture le matin (dimanche 10:00 : la Lecture du dimanche), à voir ou une opportunité à 13:00, de quoi préparer demain à 18:30 — seulement ce qui touche tes dossiers. Une page n'est proposée que si Nova l'a lue et y a retrouvé chaque idée ; heures calmes et plafond Silence respectés.",
        suggestionsControl(), "suggestions proactives nova te propose muse lecture dimanche opportunite a voir a faire par jour"),
      /* 25/10 AUTONOMIE (Feat_Autonomie.swift) — trois propositions, jamais un envoi. */
      row("assistant", "Brouillons de réponse prêts", "Pour un message important qui attend ta réponse (tri « À toi » ou urgent), Nova prépare un brouillon court dans ta voix et le range dans Messages › À approuver — 8 par jour au plus, newsletters et expéditeurs automatiques exclus. Rien ne part sans ton ENVOYER.",
        sw(get("brouillons_auto", false) === true, async (v) => { await save({ brouillons_auto: v }); ctx.toast(v ? "Brouillons automatiques activés — rien ne part sans ton ENVOYER." : "Brouillons automatiques coupés."); }), "brouillons auto reponse draft voix fil direct"),
      row("assistant", "Fiches de réunion la veille", "À 20:30, Nova prépare la fiche de chaque réunion de demain (4 au plus) : participants, échanges récents, engagements ouverts, documents, 3 points à soulever — dans l'Agenda (« Brief prêt »), au Fil direct et en .md.",
        sw(get("prep_veille", true) !== false, async (v) => { await save({ prep_veille: v }); }), "fiche reunion veille brief preparation demain 20h30"),
      row("assistant", "Relance après (jours)", "Un mail que tu as envoyé avec une question, resté sans réponse après ce délai, apparaît dans Engagements › « On me doit une réponse », avec « Proposer une relance » (un brouillon, jamais un envoi).",
        seg([["3", "3 j"], ["4", "4 j"], ["7", "7 j"]], String(get("relance_jours", 4)), async (v) => { await save({ relance_jours: Number(v) }); }), "relance attente reponse jours on me doit"),
      row("assistant", "Mode économie (lots)", "Pour les gros volumes, privilégie les cerveaux gratuits ou bon marché.",
        sw(!!get("economy_mode", false), async (v) => { await save({ economy_mode: v }); }), "bulk cout"),
      /* AUTONOMIE A2 (22/10) : le drapeau moteur n'avait AUCUN interrupteur dans cet écran —
         il n'était réglable que par l'API. La phrase ci-dessous est le contrat affiché :
         ce qui est levé, et ce qui ne l'est jamais. */
      row("assistant", "Autorisation totale", "Activée, elle lève les confirmations intermédiaires des actions locales et réversibles (fichiers, brouillons, livrables, navigation, mémoire) ; les envois externes (mail, Teams, publications) et les paiements gardent toujours leur carte d'approbation.",
        sw(!!get("autorisation_totale", false), async (v) => { await save({ autorisation_totale: v }); ctx.toast(v ? "Autorisation totale ACTIVÉE — confirmations locales levées ; envois et paiements toujours confirmés." : "Autorisation totale éteinte."); }), "autonomie confirmations envois approbation"),
      /* Version hackathon Meta : « Modèles Meta seulement » est fixe (MetaOnly.swift) — affiché, non modifiable. */
      row("assistant", "Modèles Meta seulement", "Toujours actif dans cette version : Nova n'appelle que des modèles Meta (Spark, Wonder, Spark Open, Muse Image, Voice Transcribe, SAM 3.1). Preuve : releves/diag/meta_only_journal.jsonl.",
        h("span", { class: "og-status" }, "Toujours actif"), "meta muse spark hackathon seulement only"),
      row("assistant", "Conversation vocale live", "Parler à Nova à la voix, comme un appel : elle écoute, répond avec sa voix et tu peux l'interrompre. Fermé = la conversation live est refusée par le moteur.",
        sw(!!get("voix_live_enabled", false), async (v) => { await save({ voix_live_enabled: v }); ctx.toast(v ? "Conversation vocale live autorisée." : "Conversation vocale live désactivée."); }), "voix vocale live conversation parler micro appel"),
      row("assistant", "Saluts du panda", "Le salut bref du panda quand un travail se termine.",
        sw((() => { try { return localStorage.getItem("nova2_panda_saluts") !== "0"; } catch (e) { return true; } })(), async (v) => { try { localStorage.setItem("nova2_panda_saluts", v ? "1" : "0"); } catch (e) {} }), "panda salut saluts travail termine"),
      row("assistant", "Luciole", "La luciole de verre : ses vols vers le courrier, les Éclats et les approbations. Silencieux = perchée, elle pulse seulement. Désactivée = cachée.",
        seg([["actif", "Actif"], ["silencieux", "Silencieux"], ["off", "Désactivé"]], (() => { try { return localStorage.getItem("nova2_eclat_mode") || "off"; } catch (e) { return "off"; } })(),
          async (v) => { try { localStorage.setItem("nova2_eclat_mode", v); } catch (e) {} try { window.dispatchEvent(new CustomEvent("nova:eclat-mode", { detail: { mode: v } })); } catch (e) {} }), "eclat luciole compagnon vols silencieux desactive"),
      row("assistant", "Oublier les habitudes d'Éclat", "Efface sa mémoire d'habitudes (heures où tu la suis vers chaque type d'événement). Ses vols repartent de zéro.",
        h("button", { class: "btn sm", onclick: () => { try { localStorage.removeItem("nova2_eclat_habits"); } catch (e) {} ctx.toast("Habitudes d'Éclat oubliées."); } }, "Oublier"), "eclat habitudes memoire oublier"),
      /* ── Données & comptes ── */
      row("data", "Clés de services", "État des clés au Trousseau — les valeurs ne s'affichent jamais.",
        h("div", { class: "keys-chips", style: "display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end" },
          ...(keys.length ? keys.slice(0, 10).map((k) => h("span", { class: "chip" },
            h("span", { class: "dotst " + (k.present || k.ok ? "ok" : "off") }), String(k.label || k.id || k.service || "clé")))
            : [h("span", { class: "chip" }, "État inconnu")])), "trousseau keychain api"),
      row("data", "Zoho Mail (campagne)", "La boîte campagne@nova-campagne.example lue directement par Nova (IMAP, toutes les 5 min) : Fil direct, compteur Courrier et canal Fundings. Le mot de passe d'application va au Trousseau macOS ; il n'est jamais réaffiché.",
        zohoControl(), "zoho mail campagne imap boite ahadi connexion mot de passe application fundings lecture seule trousseau"),
      row("data", "Gmail (lecture directe)", "Gmail lu directement par Nova (IMAP, toutes les 5 min, sans passer par Mail.app) : Fil direct, compteur Courrier, outils mail des Éclats. Le mot de passe d'application Google va au Trousseau macOS ; il n'est jamais réaffiché.",
        gmailControl({ h, api, ctx, bus, cleanups, isDead: () => dead, errOf }), "gmail google imap lecture directe connexion mot de passe application trousseau lecture seule mail.app"),
      row("data", "Sources de Nova", "Dossiers que Nova lit et indexe (lecture seule) : SCI/OneDrive, Documents, autres IA du Mac…",
        sourcesControl(), "sources dossiers savoir index lecture seule sci onedrive documents autres ia muse know"),
      row("data", "Sauvegarde", "Archive l'état de Nova (réglages, Éclats, mémoire) via le moteur.",
        h("button", { class: "btn", onclick: async () => { try { await api.post("/api/backup/run", {}); ctx.toast("Sauvegarde lancée."); } catch (e) { ctx.toast("Sauvegarde impossible.", true); } } }, "Sauvegarder maintenant"), "backup archive"),
      row("data", "Cache de l'interface", "Vide les caches locaux du navigateur intégré (thème d'amorçage, journal d'erreurs).",
        h("button", { class: "btn danger-solid", onclick: (e) => { const b = e.currentTarget; if (!b.dataset.armed) { b.dataset.armed = "1"; b.textContent = "Confirmer ?"; setTimeout(() => { try { if (b.isConnected) { delete b.dataset.armed; b.textContent = "Vider"; } } catch (e2) {} }, 4000); return; } try { localStorage.removeItem("nova2_theme"); localStorage.removeItem("nova2_bg"); localStorage.removeItem("nova_errors"); } catch (err) {} ctx.toast("Cache vidé. Le thème repassera par le serveur."); } }, "Vider"), "localstorage"),
      (() => { const _r = row("data", "Données web des volets", "Cookies, cache et stockages des volets web (Outlook, Gmail, réseaux…) : il faudra se reconnecter aux services. Les réglages et données de Nova ne sont pas touchés.",
        h("button", { class: "btn danger-solid", onclick: async (e) => {
          const b = e.currentTarget; if (!b.dataset.armed) { b.dataset.armed = "1"; b.textContent = "Confirmer ?"; setTimeout(() => { try { if (b.isConnected) { delete b.dataset.armed; b.textContent = "Effacer les données web"; } } catch (e2) {} }, 4000); return; }
          const card = approvalCard({ title: "Effacer les données du navigateur intégré ?", what: "Cookies, cache et stockages des volets web (Outlook, Gmail, réseaux…) seront supprimés : il faudra se reconnecter aux services. Les réglages et données de Nova ne sont pas touchés.", approveLabel: "Tout effacer", refuseLabel: "Garder" });
          root.append(card); const v = await card.promise; card.remove();
          if (v !== "approve") return;
          const n = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nova;
          if (n) { n.postMessage({ cmd: "web.clearData" }); ctx.toast("Données du navigateur intégré effacées."); } else ctx.toast("Coquille native absente.", true);
        } }, "Effacer les données web"), "cookies cache webview outlook gmail effacer donnees navigateur"); return _r; })(),
      /* ── Voix & téléphone (V5-G) ── */
      row("appareils", "Moteur de voix", "Qui prête sa voix à Nova (conversation, Live, lecture) : la voix système du Mac (meilleure voix française installée, Premium ou Améliorée si présente), 100 % sur l'appareil. Meta ne publie aucun modèle de synthèse vocale.",
        voiceEngineControl(), "voix moteur locale mac avspeech premium amelie thomas tts"),
      row("appareils", "Mot de réveil « Nova »", "Dire « Nova » lance la conversation Live (petit carillon). Confidentialité : reconnaissance fr-FR SUR L'APPAREIL uniquement — rien n'est envoyé, le texte entendu n'est ni journalisé ni stocké. Activé, l'écoute reprend au lancement de Nova ; elle se met en pause pendant le Live et la dictée.",
        wakeControl(), "mot de reveil wake word nova micro ecoute voix live carillon confidentialite appareil"),
      row("appareils", "Téléphone", "Le pont vers l'application Android, uniquement par Tailscale (réseau privé chiffré). Le téléphone lit tes dossiers autorisés et discute avec Nova ; il ne peut jamais valider une action risquée — elle s'affiche ici, sur le Mac.",
        phoneControl(), "telephone android pont bridge appairage code tailscale revoquer"),
      /* ── Apparence & accès ── */
      row("look", "Thème", "Identité « Promesse » : Harmattan (signature, par défaut), Fleuve (travail calme) et Sentinelle (contraste élevé) — chacun en Auto, Jour ou Nuit. Les thèmes précédents (Sable CAFU, Obsidienne, Verre Céleste, Graphite) restent disponibles. Appliqué en direct.",
        themeControl(), "theme identite promesse harmattan fleuve sentinelle contraste liquid glass verre graphite sable cafu céramique bronze ambre jour nuit apparence couleurs"),
      /* NOVA2-FIX (reco n°15) : la matière verre se règle — en démo, bouger ce
         curseur prouve le verre en 5 secondes. Il pilote --glass-tint et
         --glass-blur, que le moteur Liquid Glass Premium (§23) consomme pour
         les cinq thèmes verre. */
      row("look", "Liquid Glass — matière", "Trois axes indépendants : Teinte, Densité, Flou. Aperçu en direct, enregistrement au relâchement ; suspendus (jamais écrasés) si la transparence réduite est active.",
        glassControl(), "liquid glass verre teinte densite flou curseurs specular matiere clair teinte"),
      /* NOVA2 (vague 2, item 1) : le visage de Nova — le panda aimé par défaut, le Cœur
         Singularity en alternative, l'orbe CSS en repli léger. Réglage serveur
         (avatar_mode) + cache local (montage sans flash) ; l'accueil et l'écran Agent
         remontent le moteur en direct via le bus. */
      row("look", "Avatar de Nova", "Ton compagnon vivant : le Panda ou le Renard (même présence, mêmes mimiques), le Cœur Singularity, ou l'orbe sobre.",
        seg([["panda", "Panda"], ["renard", "Renard"], ["singularity", "Singularity"], ["orbe", "Orbe"]], String(get("avatar_mode", "panda")),
          async (v) => { await save({ avatar_mode: v }); try { localStorage.setItem("nova2_avatar", v); } catch (e) {} bus.emit("nova:avatar-mode", { mode: v }); }), "avatar panda renard compagnon singularity orbe visage"),
      row("look", "Style d'avatar", "Illustré (défaut) : les illustrations studio, bouche synchronisée à la voix, casque/portable/lunettes selon l'état. Organique : le panda animé dessiné. 3D (aperçu) : modèle .glb expérimental. Repli automatique sur l'organique.",
        seg([["video", "Vidéo"], ["verre", "Verre liquide"], ["illustre", "Illustré"], ["3d", "3D"]], String(get("avatar_style", get("avatar_3d", false) ? "3d" : "video")),
          async (v) => { await save({ avatar_style: v, avatar_3d: v === "3d" }); try { localStorage.setItem("nova2_avatar_style", v); localStorage.setItem("nova2_avatar_3d", v === "3d" ? "1" : "0"); } catch (e) {} bus.emit("nova:avatar-style", { style: v }); }), "avatar style video panda verre liquide illustre organique 3d glb realiste gemini"),
      /* PHASE 5 (brief Nova 2) : présence 3D optionnelle — UN objet procédural qui montre l'état de Nova.
         Défaut coupé ; coupée, web/js/presence3d.js n'est jamais chargé. Bus « nova:presence-3d » → avatar.js. */
      row("look", "Présence 3D (expérimental)", "Un seul objet 3D montre l'état de Nova : repos (bleu), réflexion (violet), attente d'une approbation (ambre), erreur (rouge), plafond de budget atteint (gris, immobile). Il remplace l'avatar et l'orbe tant qu'il est actif. WebGPU, repli WebGL ; en pause fenêtre cachée ; image fixe si « Réduire les animations » est actif ; aucun appel de modèle. Coupé par défaut : rien n'est chargé.",
        sw(get("presence_3d", false) === true, async (v) => { await save({ presence_3d: v }); try { localStorage.setItem("nova2_presence_3d", v ? "1" : "0"); } catch (e) {} bus.emit("nova:presence-3d", { on: v }); }),
        "presence 3d objet etat webgpu webgl experimental orbe avatar plafond budget approbation"),
      row("look", "Rail étendu", "Affiche le nom des modules à côté des icônes du rail.",
        sw(!!get("rail_extended", document.querySelector(".shell").classList.contains("rail-ext")), async (v) => {
          document.querySelector(".shell").classList.toggle("rail-ext", v);
          try { localStorage.setItem("nova2_rail", v ? "ext" : ""); } catch (e) {}   // cache d'amorçage seulement
          await save({ rail_extended: v });   // source de vérité : /api/settings (D-32)
        }), "barre laterale navigation"),
      /* 29/10 (Ahadi : « rendu, customisation ») — confort de lecture des réponses de Nova, appliqué à l'instant. */
      row("look", "Style des réponses", "CAFU : la charte CAFU (titres rouges, puces carrées, encadré de synthèse, pastilles « à vérifier »). Sobre : la mise en forme neutre de Nova.",
        seg([["cafu", "CAFU"], ["sobre", "Sobre"]], (() => { try { return localStorage.getItem("nova2_answer_style") || "cafu"; } catch (e) { return "cafu"; } })(),
          async (v) => { try { localStorage.setItem("nova2_answer_style", v); } catch (e) {} if (v === "sobre") document.documentElement.dataset.answerStyle = "sobre"; else delete document.documentElement.dataset.answerStyle; await save({ answer_style: v }); }), "style reponses cafu charte save the children mise en forme sobre"),
      row("look", "Taille du texte des réponses", "La taille des messages dans les conversations (le reste de l'interface ne bouge pas).",
        seg([["s", "Petit"], ["m", "Normal"], ["l", "Grand"], ["xl", "Très grand"]], (() => { try { return localStorage.getItem("nova2_text_size") || "m"; } catch (e) { return "m"; } })(),
          async (v) => { try { localStorage.setItem("nova2_text_size", v); } catch (e) {} if (v === "m") delete document.documentElement.dataset.textSize; else document.documentElement.dataset.textSize = v; await save({ text_size: v }); }), "taille texte police lecture grand petit messages conversations"),
      row("look", "Largeur de lecture", "Jusqu'où s'étendent les messages dans une conversation : étroit pour lire, large pour les tableaux.",
        seg([["narrow", "Étroite"], ["normal", "Normale"], ["wide", "Large"]], (() => { try { return localStorage.getItem("nova2_read_width") || "normal"; } catch (e) { return "normal"; } })(),
          async (v) => { try { localStorage.setItem("nova2_read_width", v); } catch (e) {} if (v === "normal") delete document.documentElement.dataset.readWidth; else document.documentElement.dataset.readWidth = v; await save({ read_width: v }); }), "largeur lecture colonne messages tableaux large etroite"),
      row("look", "Nuit douce", "En thème de nuit : teinte plus chaude et textes moins éclatants, pour le soir.",
        sw((() => { try { return localStorage.getItem("nova2_soft_night") === "1"; } catch (e) { return false; } })(), async (v) => { try { localStorage.setItem("nova2_soft_night", v ? "1" : "0"); } catch (e) {} if (v) document.documentElement.dataset.softNight = "1"; else delete document.documentElement.dataset.softNight; await save({ soft_night: v }); }), "nuit douce chaude soir yeux contraste"),
      row("look", "Réduire la transparence", "Remplace le verre dépoli par des surfaces pleines (accessibilité).",
        sw(!!get("reduce_transparency", false), async (v) => { const st = reducedTransparencyState(); if (!v && st.system) { ctx.toast("Transparence réduite pilotée par le système : le commutateur Nova ne peut pas la lever."); return; } applyReducedTransparency(v, "application"); await save({ reduce_transparency: v }); }), "verre flou accessibilite"),
    ];
  }

  let spy = null;
  function applySecVisibility() {
    body.querySelectorAll(".set-sec").forEach((sec) => {
      const id = sec.getAttribute("data-sec");
      sec.style.display = (searching || id === activeSec) ? "" : "none";
    });
    nav.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.getAttribute("data-nav") === activeSec));
  }
  function render() {
    /* D-29 : la nav pose .on AU CLIC — commutation (plus de scrollspy) : un seul
       écran visible, piloté par les clics et la recherche. */
    nav.replaceChildren(...SECTIONS.map((s) => h("button", { "data-nav": s.id, onclick: (e) => {
      activeSec = s.id; searching = false; searchIn.value = "";
      applySecVisibility();
      try { if (root.scrollTo) root.scrollTo(0, 0); else window.scrollTo(0, 0); } catch (err) { const target = body.querySelector('[data-sec="' + s.id + '"]'); if (target) target.scrollIntoView({ behavior: "smooth", block: "start" }); }
    } }, h("span", { html: ic(s.icon, 17) }), s.label)));
    const rows = buildRows();
    /* V5-W : sous-blocs titrés (GROUPS) ; une ligne hors table rejoint le dernier sous-bloc de sa section. */
    const groupsOf = (sec) => {
      const mine = rows.filter((r) => r.sec === sec);
      const defs = GROUPS[sec] || [];
      const out = defs.map(([t, labels]) => ({ t, items: mine.filter((r) => labels.includes(r.label)) }));
      const placed = new Set(out.flatMap((g) => g.items));
      const rest = mine.filter((r) => !placed.has(r));
      if (rest.length) { if (out.length) out[out.length - 1].items.push(...rest); else out.push({ t: "", items: rest }); }
      return out.filter((g) => g.items.length);
    };
    body.replaceChildren(...SECTIONS.map((s) => h("section", { class: "set-sec", "data-sec": s.id },
      h("h2", {}, s.label), h("div", { class: "desc" }, s.desc),
      ...groupsOf(s.id).map((g) => h("div", { class: "set-grp" }, g.t ? h("h3", { class: "set-grp-t" }, g.t) : null,
        h("div", { class: "card flat" }, ...g.items.map((r) => r.el)))))));
    if (settingsLocked) {   // D-30 : valeurs par défaut affichées mais contrôles désactivés, dit explicitement
      body.prepend(h("div", { class: "banner banner--err" }, h("span", { class: "dotst err" }), h("span", { class: "grow" }, "Réglages non lus — les valeurs par défaut sont affichées et les modifications sont désactivées.")));
      body.querySelectorAll("button, select, input").forEach((el) => { el.disabled = true; });
    }
    if (spy) spy.disconnect();
    spy = null;
    applySecVisibility();
  }
  searchIn.addEventListener("input", () => {
    const q = searchIn.value.trim().toLowerCase();
    if (!q) { searching = false; body.querySelectorAll(".set-row, .set-grp").forEach((r) => { r.style.display = ""; }); applySecVisibility(); return; }
    searching = true;
    const visibleSecs = [];
    body.querySelectorAll(".set-sec").forEach((sec) => {
      let any = false;
      sec.querySelectorAll(".set-row").forEach((r) => { const show = (r.getAttribute("data-q") || "").includes(q); r.style.display = show ? "" : "none"; if (show) any = true; });
      sec.querySelectorAll(".set-grp").forEach((g) => { g.style.display = [...g.querySelectorAll(".set-row")].some((r) => r.style.display !== "none") ? "" : "none"; });
      sec.style.display = any ? "" : "none";
      if (any) visibleSecs.push(sec.getAttribute("data-sec"));
    });
    if (visibleSecs.length === 1) { activeSec = visibleSecs[0]; nav.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.getAttribute("data-nav") === activeSec)); }
  });

  /* D-30 : pendant la lecture, squelettes de sections (jamais un écran « par défaut »
     qui se fait passer pour les réglages réels). */
  body.replaceChildren(h("div", { class: "skel skel-card" }), h("div", { class: "skel skel-card", style: "margin-top:12px" }), h("div", { class: "skel skel-card", style: "margin-top:12px" }));
  let stateOk = false, settingsOk = false;
  try {
    const st = await api.get("/api/state");
    if (st) { settings = st.settings || {}; brains = st.brains || []; keys = st.keys || []; stateOk = true; }
  } catch (e) { /* signalé ci-dessous si les deux sources échouent */ }
  if (dead) return;
  try { settings = (await api.get("/api/settings")).settings || settings; settingsOk = true; } catch (e) {}
  settingsLocked = !stateOk && !settingsOk;
  if (!dead) render();
  return () => { dead = true; if (spy) spy.disconnect(); for (const f of cleanups) { try { f(); } catch (e) {} } };
}
