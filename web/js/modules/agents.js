/* Module Dots — LA surface unique des Dots (FUSION du 22/10, audit
   Dots/Automatisations, décision ratifiée par Muse au nom d'Ahadi).
   Avant : deux écrans (« Dots » ici, « Automatisations ») montraient le MÊME
   objet (le Dot de dots.json), le MÊME moteur (Dots.run), le MÊME
   planificateur (DotScheduler) et le MÊME gardien (DotCare, piloté des deux
   côtés). La fusion est une fusion d'INTERFACES : aucun objet du magasin
   n'est touché, aucune route ne change. Quatre sections, dans l'ordre de
   l'audit :
     1. En attente de ta décision — la file (GET /api/dots/waiting, Vu
        /api/dots/ack, Plus tard /api/dots/snooze), avec l'ÂGE de chaque
        entrée ;
     2. Parc & horaires — le parc complet (GET /api/dots) : peluche à l'état
        réel (même composant que l'Accueil), horaire en texte + prochain
        créneau calculé, badge « créneau mort » quand l'horaire tombe
        intégralement dans les heures calmes, création/édition/suppression
        des Dots (POST /api/dots/save, /api/dots/remove avec carte
        d'approbation), rituels de l'âme RÉCONCILIÉS avec le parc ;
     3. Exécutions — les runs (30 servis), rapport COMPLET déplié au clic,
        brouillons produits liés vers Messages ;
     4. Santé & packs — interrupteur global dots_auto, DotCare UNE seule
        fois (pause DotCare distincte de la pause du Dot), packs
        installables (GET /api/packs, POST /api/packs/install).
   V5-X (25/10, flotte resserrée) : la décision d'abord (une entrée par Éclat,
   lignes resserrées), puis le PARC groupé — Actifs (triés par prochain
   passage) · En pause · Retirés (repliés) — une ligne par Éclat : mission,
   prochain passage, pastille du dernier résultat ; « Nouvel Éclat » replié
   derrière un bouton ; rituels et santé DotCare repliés.
   FIX-WEB C1 : la section « Missions continues » appelait /api/missions*
   (GET, add, remove, patch) — AUCUNE de ces routes n'existe dans le moteur
   (404 permanent). Retirée : un objectif continu = un Dot planifié. */
import { approvalCard } from "../orb.js";
import { mountPlush } from "../plush.js";
import { cleanResume, truncWords, fmtDateFR, fmtTimeFR, sse, md, setFieldError, etatLabel, phaseLabel } from "../core.js";
import { pageHead, section, card, row, pill, tabs, empty, action as dsAction } from "../ds.js";   // V6 : page de détail d'un Éclat
import { feedbackBar } from "../eclat-feedback.js";
import { houseHTML, isHouse } from "../richtext.js";

const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const fmtDate = (v) => {
  if (!v) return "";
  const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v);
  return isNaN(d) ? String(v).slice(0, 16) : fmtDateFR(d) + " " + fmtTimeFR(d);
};
const fmtDT = (v) => { const s = fmtDateFR(v); return s ? s + " · " + fmtTimeFR(v) : String(v || "").slice(0, 16); };
/* Âge d'une entrée en attente — la file ne doit plus vieillir en silence. */
const fmtAge = (v) => {
  const t = v ? new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v).getTime() : NaN;
  if (!isFinite(t)) return "";
  const s = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (s < 90) return "à l'instant";
  const m = Math.floor(s / 60); if (m < 60) return "depuis " + m + " min";
  const hh = Math.floor(m / 60); if (hh < 48) return "depuis " + hh + " h";
  return "depuis " + Math.floor(hh / 24) + " j";
};

/* ── Grammaire des horaires (recopiée de DotScheduler.slots, comme avant) ── */
const DAYS = { lun: 1, mar: 2, mer: 3, jeu: 4, ven: 5, sam: 6, dim: 0 };
function nextRun(schedule, from = new Date()) {
  const s = String(schedule || "").trim().toLowerCase(); if (!s) return null;
  let days = null, times = s;
  const m = s.match(/^([a-z]{3}(?:-[a-z]{3})?(?:,[a-z]{3}(?:-[a-z]{3})?)*)\s+(.+)$/);
  if (m && !/^\d/.test(m[1])) {
    days = new Set();
    for (const part of m[1].split(",")) {
      const [a, b] = part.split("-");
      if (b && DAYS[a] != null && DAYS[b] != null) { let d = DAYS[a]; for (let i = 0; i < 7; i++) { days.add(d); if (d === DAYS[b]) break; d = (d + 1) % 7; } }
      else if (DAYS[part] != null) days.add(DAYS[part]);
    }
    times = m[2];
  }
  const slots = times.split(",").map((t) => t.trim()).filter((t) => /^\d{1,2}:\d{2}$/.test(t));
  if (!slots.length) return null;
  for (let add = 0; add < 8; add++) {
    const day = new Date(from); day.setDate(day.getDate() + add);
    if (days && !days.has(day.getDay())) continue;
    for (const t of slots) {
      const [hh, mm] = t.split(":").map(Number);
      const cand = new Date(day); cand.setHours(hh, mm, 0, 0);
      if (cand > from) return cand;
    }
  }
  return null;
}
const fmtNext = (d) => d ? fmtDateFR(d) + " · " + fmtTimeFR(d) : "—";
/* Heures des créneaux d'un horaire (les jours ne comptent pas : les heures
   calmes sont quotidiennes). Sert au badge « créneau mort ». */
function scheduleTimes(schedule) {
  const s = String(schedule || "").trim().toLowerCase(); if (!s) return [];
  let times = s;
  const m = s.match(/^([a-z]{3}(?:-[a-z]{3})?(?:,[a-z]{3}(?:-[a-z]{3})?)*)\s+(.+)$/);
  if (m && !/^\d/.test(m[1])) times = m[2];
  return times.split(",").map((t) => t.trim()).filter((t) => /^\d{1,2}:\d{2}$/.test(t))
    .map((t) => { const p = t.split(":").map(Number); return p[0] * 60 + p[1]; });
}
/* Heures calmes : réglages quiet_from / quiet_to du moteur (défauts 22:00 et
   07:00, mêmes valeurs que Briefs.inQuietHours). Calculées ICI, côté écran —
   aucune touche moteur (audit §8, étape 4). */
const quietWin = (settings) => {
  const parse = (v, dflt) => { const mm = /^(\d{1,2}):(\d{2})$/.exec(String(v || dflt)); return mm ? Number(mm[1]) * 60 + Number(mm[2]) : null; };
  const a = parse(settings && settings.quiet_from, "22:00"), b = parse(settings && settings.quiet_to, "07:00");
  if (a == null || b == null) return null;
  return { a, b, label: String((settings && settings.quiet_from) || "22:00") + "–" + String((settings && settings.quiet_to) || "07:00") };
};
const deadInfo = (d, settings) => {
  if (!d || d.paused) return null;
  const times = scheduleTimes(d.schedule); if (!times.length) return null;
  const q = quietWin(settings); if (!q) return null;
  const inside = (mins) => q.a > q.b ? (mins >= q.a || mins < q.b) : (mins >= q.a && mins < q.b);
  return times.every(inside) ? q : null;
};

/* ── Rituels de l'âme RÉCONCILIÉS (audit §6.3.2) ─────────────────────────
   Le parc contient DÉJÀ la première génération, sous ids « imp-rituel-* ».
   L'ancien écran proposait un second import sous ids « imp-ame-* » :
   l'import étant idempotent PAR ID, il aurait créé des DOUBLONS
   fonctionnels de 9 rituels. Désormais : chaque rituel porte son id de
   parc (parkId, la convention existante) ; la présence est testée par CLÉ
   de rituel — id de parc, ancien id « imp-ame-* », ou nom normalisé — quel
   que soit le préfixe. Seuls les rituels absents sous TOUTES leurs formes
   sont importables, sous l'id de parc. Les deux manquants relevés par
   l'audit (« Un contact », « Lecture du dimanche ») sont dans la liste. */
const AME_RITUALS = [
  { parkId: "imp-rituel-sparring", ameId: "imp-ame-sparring", name: "Sparring anglais", emoji: "🗣️", color: "#4cc9ff", schedule: "lun-ven 07:10", freq: "Lun–ven · 07:10", role: "Rituel du matin — pack d'âme §5", prompt: "Lance la séance de sparring d'anglais du matin : 10 minutes en anglais avec Ahadi, corrections bienveillantes au fil de l'eau, et le point WEPHI du jour. Prépare la séance prête à commencer." },
  { parkId: "imp-rituel-brvm", ameId: "imp-ame-brvm", name: "Veille BRVM", emoji: "📡", color: "#E8A856", schedule: "16:30", freq: "Lun–ven · 16:30", mergedInto: "portefeuille", role: "Rituel — pack d'âme §5", prompt: "Fais la veille BRVM de clôture : cours du jour des valeurs suivies (source brvm.org), variations marquantes, dividendes annoncés. Rapport court et sourcé, aucun conseil d'investissement." },
  { parkId: "imp-rituel-dictee", ameId: "imp-ame-dictee", name: "Dictée du soir", emoji: "🌙", color: "#b48cff", schedule: "21:15", freq: "Chaque jour · 21:15", role: "Rituel du soir — pack d'âme §5", prompt: "Ouvre la dictée du soir : invite Ahadi à vider sa tête, puis trie ce qu'il dicte en tâches, idées et notes datées. Ne rien envoyer, tout reste en brouillon." },
  { parkId: "imp-rituel-contact", ameId: "imp-ame-contact", name: "Un contact", emoji: "🤝", color: "#3ddc97", schedule: "lun 09:20", freq: "Lundi · 09:20", role: "Rituel hebdo — pack d'âme §5", prompt: "Propose UN contact à relancer cette semaine, avec l'angle d'approche. Angle seulement : Ahadi écrit et envoie lui-même (RÈGLE D'OR n°2)." },
  { parkId: "imp-rituel-post-afrique", ameId: "imp-ame-post", name: "Post Afrique", emoji: "✍️", color: "#FF7A29", schedule: "mer 09:30", freq: "Mercredi · 09:30", role: "Rituel hebdo — pack d'âme §5", prompt: "Rédige le brouillon du post Afrique de la semaine (français, un fait établi + une analyse), prêt pour la relecture d'Ahadi. Brouillon uniquement — aucun envoi." },
  { parkId: "imp-rituel-revue-cash", ameId: "imp-ame-cash", name: "Revue cash", emoji: "💰", color: "#E8A856", schedule: "ven 17:05", freq: "Vendredi · 17:05", role: "Rituel hebdo — pack d'âme §5", prompt: "Prépare la revue cash de la semaine depuis les données Finance de Nova : entrées, sorties, soldes. Faits sourcés uniquement, aucun chiffre inventé." },
  { parkId: "imp-rituel-chose-apprise", ameId: "imp-ame-appris", name: "Chose apprise", emoji: "🧠", color: "#4cc9ff", schedule: "ven 17:30", freq: "Vendredi · 17:30", mergedInto: "imp-rituel-fermeture", role: "Rituel hebdo — pack d'âme §5", prompt: "Note la chose apprise de la semaine (mutuel) : une leçon d'Ahadi, une leçon de Nova, chacune en une phrase, versées au journal de boucle fermée." },
  { parkId: "imp-rituel-fermeture", ameId: "imp-ame-fermeture", name: "Fermeture de semaine", emoji: "🌙", color: "#b48cff", schedule: "ven 18:40", freq: "Vendredi · 18:40", role: "Rituel hebdo — pack d'âme §5", prompt: "Ferme la semaine avec les 3 questions du rituel : ce qui est terminé, ce qui glisse, ce qui compte lundi. Ajoute une 4e question : la chose apprise de la semaine (une leçon d'Ahadi, une leçon de Nova, une phrase chacune). Réponses courtes, prêtes à dicter." },
  { parkId: "imp-rituel-lecture", ameId: "imp-ame-lecture", name: "Lecture du dimanche", emoji: "📚", color: "#3ddc97", schedule: "dim 10:00", freq: "Dimanche · 10:00", role: "Rituel hebdo — pack d'âme §5", prompt: "Prépare la lecture du dimanche : un texte au long cours adapté à ses chantiers du moment, et les 3 idées clés à en tirer." },
  { parkId: "imp-rituel-chantier", ameId: "imp-ame-chantier", name: "Point chantier", emoji: "🏠", color: "#FF7A29", schedule: "dim 18:00", freq: "Dimanche · 18:00", role: "Rituel hebdo — pack d'âme §5", prompt: "Ouvre le point chantier (projet personnel, exemple) de la semaine : avancement, dépenses, prochaines étapes — prêt à compléter dans le journal chantier." },
  { parkId: "imp-rituel-podcast", ameId: "imp-ame-podcast", name: "Podcast de la semaine", emoji: "🎙️", color: "#E8A856", schedule: "dim 19:00", freq: "Dimanche · 19:00", role: "Rituel hebdo — pack d'âme §5", prompt: "Produit l'épisode audio « ma semaine en 5 minutes » : Nova rassemble les faits réels des 7 derniers jours (conversations, briefs, engagements, Éclats, BRVM), écrit un dialogue Léa / Mehdi, le fait dire par deux voix système du Mac et dépose le fichier audio et son script dans les Livrables. Aucune question, rien n'est envoyé ni publié." },   /* 25/10 : pipeline réel (Feat_Podcast.swift) */
];
const normName = (s) => String(s || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, " ").trim();

export async function mount(root, ctx) {
  const { api, bus, h, ic } = ctx;
  let dead = false;
  const offs = [];
  const cleanups = [];
  const on = (t, f) => offs.push(bus.on(t, f));
  root.classList.add("mod--data");
  let dots = [], settings = {};
  let plushes = [];
  let plushById = new Map();
  const clearPlushes = () => { plushes.forEach((p) => { try { p.dispose(); } catch (e) {} }); plushes = []; plushById = new Map(); };

  const secHead = (titre, ...actions) => h("div", { class: "sec-head" }, h("h2", { class: "sec-title" }, titre), ...(actions.length ? [h("span", { class: "grow" }), ...actions] : []));
  const errBox = (msg, retry) => h("div", { class: "state-error" }, h("span", { html: ic("alert", 16) }), h("span", { class: "grow" }, msg), h("button", { class: "btn sm", onclick: () => retry() }, "Réessayer"));

  root.append(h("div", { class: "mod-head" },
    h("h1", {}, "Éclats"),
    h("span", { class: "sub" }, "Tes agents permanents : ils lisent tout, ne t'écrivent que pour une vraie décision, et se taisent quand il n'y a rien (« RAS »)")));

  /* Menu ⋯ d'une ligne (.row-more / .row-menu, patron repris de l'ancien
     écran Automatisations, DS §6.7). */
  function rowMenu(items, ariaLabel) {
    const panel = h("div", { class: "row-menu", role: "menu", hidden: true, style: "position:absolute;right:0;top:calc(100% + var(--sp-1));z-index:var(--z-menu);min-width:220px;flex-direction:column;gap:var(--sp-1);padding:var(--sp-2);background:var(--glass-strong);border:1px solid var(--stroke);border-radius:var(--r-md);box-shadow:var(--shadow-float)" });
    const btn = h("button", { class: "btn icon ghost", "aria-label": ariaLabel, "aria-haspopup": "true", "aria-expanded": "false" }, "⋯");
    const wrap = h("span", { class: "row-more" }, btn, panel);
    const close = () => { panel.hidden = true; panel.style.display = "none"; btn.setAttribute("aria-expanded", "false"); document.removeEventListener("click", onDoc, true); };
    const onDoc = (e) => { if (!wrap.contains(e.target)) close(); };
    const open = () => { panel.hidden = false; panel.style.display = "flex"; btn.setAttribute("aria-expanded", "true"); document.addEventListener("click", onDoc, true); };
    btn.addEventListener("click", (e) => { e.stopPropagation(); panel.hidden ? open() : close(); });
    panel.addEventListener("keydown", (e) => { if (e.key === "Escape") { close(); btn.focus(); } });
    for (const it of items) {
      if (it.sep) { panel.append(h("div", { class: "row-sep" })); continue; }
      const b = h("button", { class: "btn ghost", role: "menuitem", style: "justify-content:flex-start;text-align:left" + (it.danger ? ";color:var(--danger)" : ""), onclick: () => { close(); it.onclick(); } }, it.label);
      panel.append(b);
    }
    cleanups.push(close);
    return wrap;
  }

  /* ── Squelette des sections (ordre de l'audit §6.1) ─────────────────── */
  const waitBox = h("div", {});
  /* V5-X (25/10) : « Nouvel Éclat » replié derrière un bouton — le parc vient d'abord. */
  const createBox = h("div", { hidden: true, style: "margin-bottom:var(--sp-4)" });
  const newBtn = h("button", { class: "btn sm", "aria-expanded": "false", onclick: () => { createBox.hidden = !createBox.hidden; newBtn.setAttribute("aria-expanded", String(!createBox.hidden)); newBtn.textContent = createBox.hidden ? "+ Nouvel Éclat" : "Fermer le formulaire"; if (!createBox.hidden) { try { fName.focus(); } catch (e) {} } } }, "+ Nouvel Éclat");
  const parcSummary = h("span", { class: "ss" });
  const parcBox = h("div", {}, h("div", { class: "skel skel-card" }));
  const ameCount = h("span", { class: "ss" });
  const ameBox = h("div", { class: "rows" });
  const runsBox = h("div", {});
  const globalBox = h("div", {});
  const careBox = h("div", { class: "rows" });
  const careSum = h("span", { class: "ss" });
  const careJournal = h("div", {});
  const packBox = h("div", {});
  root.append(
    secHead("En attente de ta décision"), waitBox,
    h("div", { class: "sec-head" }, h("h2", { class: "sec-title" }, "Parc"), parcSummary, h("span", { class: "grow" }), newBtn),
    createBox, parcBox,
    h("details", { class: "x-group", style: "margin-top:var(--sp-5)" },
      h("summary", { style: "cursor:pointer;display:flex;gap:var(--sp-2);align-items:baseline;flex-wrap:wrap" }, h("span", { class: "sec-title", style: "font-size:17px" }, "Rituels de l'âme — le rythme du pack"), ameCount),
    h("div", { style: "display:flex;justify-content:flex-end;margin:var(--sp-2) 0" }, h("button", { class: "btn sm", onclick: () => importAme() }, "Importer les manquants (en pause)")),
    ameBox,
    h("div", { class: "card flat", style: "margin-top:var(--sp-3)" },
      h("div", { class: "row-item", style: "border:0" },
        h("span", { html: ic("chart", 20) }),
        h("div", { class: "row-main" }, h("div", { class: "tt" }, "Revue mensuelle — le 1er à 08:00"),
          h("div", { class: "ss ss--wrap" }, "Rituel du pack (§5) NON planifiable par le moteur : DotScheduler connaît les horaires quotidiens et hebdomadaires, pas mensuels (grammaire de slots() : « HH:MM » ou « jours HH:MM »). En attendant, le « Brief du matin » du 1er et cette ligne te le rappellent.")),
        h("span", { class: "chip" }, "non planifiable")))),
    secHead("Exécutions"), runsBox,
    secHead("Santé & packs"), globalBox,
    h("details", { class: "x-group", style: "margin-top:var(--sp-3)" }, h("summary", { style: "cursor:pointer;padding:6px 0" }, h("span", { class: "tt" }, "Santé détaillée (DotCare)"), " ", careSum), careBox, careJournal),
    h("div", { class: "sec-head" }, h("h2", { class: "sec-title" }, "Packs de Éclats")), packBox);

  /* ── Création d'un Dot (le formulaire de l'ancien écran, renommé) ───── */
  const fName = h("input", { type: "text", id: "dot-name", placeholder: "Nom (ex. Rapport du soir)", class: "fld" });
  const fSched = h("input", { type: "text", id: "dot-sched", placeholder: "07:30 ou lun-ven 08:00,12:30", class: "fld" });
  const SCHED_EX = "07:30 ou lun-ven 08:00,12:30";
  let schedFreq = "tous";
  const SCHED_DAY_DEFS = [["lun","Lun"],["mar","Mar"],["mer","Mer"],["jeu","Jeu"],["ven","Ven"],["sam","Sam"],["dim","Dim"]];
  const schedChecks = SCHED_DAY_DEFS.map(([k, lb]) => ({ k, lb, box: h("input", { type: "checkbox", value: k, "aria-label": lb }) }));
  const schedDayWrap = h("div", { style: "display:flex;gap:8px;flex-wrap:wrap" }, ...schedChecks.map((c) => h("label", { class: "ss", style: "display:inline-flex;gap:4px;align-items:center" }, c.box, c.lb)));
  schedDayWrap.hidden = true;
  const schedTimesWrap = h("div", { style: "display:grid;gap:6px" });
  let schedTimeInputs = [];
  function schedAddTime(v, removable) { if (schedTimeInputs.length >= 4) return; const inp = h("input", { type: "time", value: v || "07:30", class: "fld", "aria-label": "Heure" }); schedTimeInputs.push(inp); const row = h("div", { style: "display:flex;gap:6px;align-items:center" }, inp); if (removable !== false) { const x = h("button", { type: "button", class: "btn sm ghost", "aria-label": "Retirer cette heure" }, "×"); x.addEventListener("click", () => { row.remove(); schedTimeInputs = schedTimeInputs.filter((t) => t !== inp); schedUpdate(); }); row.append(x); } schedTimesWrap.append(row); inp.addEventListener("input", schedUpdate); inp.addEventListener("change", schedUpdate); }
  schedAddTime("07:30", false);
  const schedAddBtn = h("button", { type: "button", class: "btn sm" }, "+ Ajouter une heure");
  schedAddBtn.addEventListener("click", () => { schedAddTime(schedTimeInputs.map((t) => t.value).find((vv) => vv) || "07:30"); schedUpdate(); });
  const schedPreview = h("div", { class: "ss", "aria-live": "polite" }, "→ —");
  const schedAdvNote = h("div", { class: "ss", hidden: true }, "Horaire avancé actif — le structuré est ignoré.");
  const schedSegTous = h("button", { type: "button", class: "on" }, "Tous les jours");
  const schedSegSemaine = h("button", { type: "button" }, "Lun–Ven");
  const schedSegPerso = h("button", { type: "button" }, "Personnalisé");
  const schedSeg = h("div", { class: "seg", role: "group", "aria-label": "Fréquence" }, schedSegTous, schedSegSemaine, schedSegPerso);
  const schedStructBox = h("div", { style: "display:grid;gap:8px" }, schedSeg, schedDayWrap, schedTimesWrap, schedAddBtn);
  function schedDaysForPreview() { if (schedFreq === "tous") return ["Lun","Mar","Mer","Jeu","Ven","Sam","Dim"]; if (schedFreq === "semaine") return ["Lun","Mar","Mer","Jeu","Ven"]; return schedChecks.filter((c) => c.box.checked).map((c) => c.lb); }
  function schedCompose() { const ts = schedTimeInputs.map((t) => String(t.value || "").trim()).filter((t) => /^\d{1,2}:\d{2}$/.test(t)); if (!ts.length) return ""; const str = ts.join(","); if (schedFreq === "tous") return str; if (schedFreq === "semaine") return "lun-ven " + str; const ds = schedChecks.filter((c) => c.box.checked).map((c) => c.k); if (!ds.length) return str; return ds.join(",") + " " + str; }
  function schedUpdate() { const ds = schedDaysForPreview(); const ts = schedTimeInputs.map((t) => String(t.value || "").trim()).filter(Boolean); let ttxt = "—"; if (ts.length === 1) ttxt = ts[0]; else if (ts.length > 1) ttxt = ts.slice(0, -1).join(", ") + " et " + ts.slice(-1)[0]; schedPreview.textContent = "→ " + (ds.length ? ds.join(", ") : "—") + " à " + ttxt; const adv = fSched.value.trim(); if (adv) { schedStructBox.style.opacity = ".5"; schedStructBox.style.pointerEvents = "none"; schedAdvNote.hidden = false; } else { schedStructBox.style.opacity = ""; schedStructBox.style.pointerEvents = ""; schedAdvNote.hidden = true; } }
  function schedSetFreq(f) { schedFreq = f; schedSegTous.className = f === "tous" ? "on" : ""; schedSegSemaine.className = f === "semaine" ? "on" : ""; schedSegPerso.className = f === "perso" ? "on" : ""; schedDayWrap.hidden = f !== "perso"; schedUpdate(); }
  schedSegTous.addEventListener("click", () => schedSetFreq("tous"));
  schedSegSemaine.addEventListener("click", () => schedSetFreq("semaine"));
  schedSegPerso.addEventListener("click", () => schedSetFreq("perso"));
  schedChecks.forEach((c) => c.box.addEventListener("change", schedUpdate));
  fSched.addEventListener("input", schedUpdate);
  const schedAdvDet = h("details", {}, h("summary", {}, "Horaire avancé (grammaire DotScheduler)"), h("div", { class: "field", style: "margin-top:8px" }, fSched, h("span", { class: "field-help" }, "Grammaire DotScheduler : « 07:30 » (chaque jour) ou « lun-ven 08:00,12:30 » (jours + heures, virgules).")));
  function schedParse(schedule) { const s = String(schedule || "").trim().toLowerCase(); if (!s) return null; if (!nextRun(s)) return null; let times = s; let dayPart = ""; const m = s.match(/^([a-z]{3}(?:-[a-z]{3})?(?:,[a-z]{3}(?:-[a-z]{3})?)*)\s+(.+)$/); if (m && !/^\d/.test(m[1])) { dayPart = m[1]; times = m[2]; } const ts = String(times).split(",").map((t) => t.trim()).filter((t) => /^\d{1,2}:\d{2}$/.test(t)); if (!ts.length) return null; const norm = (t) => t.length === 4 ? "0" + t : t; const timesN = ts.map(norm); if (!dayPart) return { freq: "tous", days: [], times: timesN }; const set = new Set(); for (const part of dayPart.split(",")) { const ab = part.split("-"); if (ab[1] && DAYS[ab[0]] != null && DAYS[ab[1]] != null) { let d = DAYS[ab[0]]; for (let i = 0; i < 7; i++) { set.add(d); if (d === DAYS[ab[1]]) break; d = (d + 1) % 7; } } else if (DAYS[part] != null) set.add(DAYS[part]); else return null; } const all = [1,2,3,4,5,0,6].every((d) => set.has(d)); const mf = [1,2,3,4,5].every((d) => set.has(d)) && set.size === 5; const rev = Object.fromEntries(Object.entries(DAYS).map(([k,v]) => [v,k])); if (all) return { freq: "tous", days: [], times: timesN }; if (mf) return { freq: "semaine", days: [], times: timesN }; return { freq: "perso", days: [...set].map((d) => rev[d]).filter(Boolean), times: timesN }; }
  function prefillSchedForm(schedule) { const p = schedParse(schedule); if (!p && String(schedule || "").trim()) { fSched.value = String(schedule); schedAdvDet.open = true; schedUpdate(); return; } fSched.value = ""; schedAdvDet.open = false; if (!p) { schedSetFreq("tous"); schedTimesWrap.replaceChildren(); schedTimeInputs = []; schedAddTime("07:30", false); schedChecks.forEach((c) => { c.box.checked = false; }); schedUpdate(); return; } schedSetFreq(p.freq); schedChecks.forEach((c) => { c.box.checked = p.days.includes(c.k); }); schedTimesWrap.replaceChildren(); schedTimeInputs = []; p.times.slice(0, 4).forEach((t, i) => schedAddTime(t, i !== 0 || p.times.length > 1)); if (!schedTimeInputs.length) schedAddTime("07:30", false); schedUpdate(); }
  schedUpdate();
  const fPrompt = h("textarea", { id: "dot-prompt", rows: "3", placeholder: "Ce que l'Éclat doit faire, pour qui, avec quelles limites", class: "fld fld-area" });
  const fColor = h("select", { id: "dot-color", class: "fld" }, h("option", { value: "#D93226" }, "Rouge impérial"), h("option", { value: "#FF7A29", selected: "" }, "Feu"), h("option", { value: "#FF8A1F" }, "Humeur chaude"), h("option", { value: "#5EA8FF" }, "Saphir"), h("option", { value: "#8FC2FF" }, "Saphir clair"), h("option", { value: "#9FB2D6" }, "Verre indigo"));
  createBox.replaceChildren(h("div", { class: "card flat", style: "display:grid;gap:var(--sp-4)" },
    h("h3", { class: "subhead" }, "Nouvel Éclat"),
    h("div", { style: "display:flex;gap:var(--sp-4);flex-wrap:wrap" },
      h("div", { class: "field" }, h("label", { class: "field-lb", for: "dot-color" }, "Couleur de la sphère"), fColor),
      h("div", { class: "field", style: "flex:1;min-width:200px" }, h("label", { class: "field-lb", for: "dot-name" }, "Nom"), fName)),
    h("div", { class: "field" }, h("span", { class: "field-lb" }, "Fréquence"),
      schedStructBox,
      schedPreview,
      schedAdvNote,
      schedAdvDet),
    h("div", { class: "field" }, h("label", { class: "field-lb", for: "dot-prompt" }, "Mission de l'Éclat"), fPrompt),
    h("div", { style: "display:flex;gap:var(--sp-2);align-items:center;flex-wrap:wrap" },
      h("button", { class: "btn acc", onclick: () => createDot() }, "Créer l'Éclat"),
      h("span", { class: "ss ss--wrap" }, "Créé actif si les automatismes sont allumés ; la charte du nouvel Éclat est libre (pas un Éclat verrouillé)."))));

  /* ── Actions ─────────────────────────────────────────────────────────── */
  async function saveDot(dot, patch) {
    try { await api.post("/api/dots/save", { ...dot, ...patch }); await loadAll(); }
    catch (e) { ctx.toast("Enregistrement impossible.", true); }
  }
  async function removeDot(dot, anchor) {
    const card = approvalCard({ title: "Retirer l'Éclat « " + (dot.name || dot.id) + " » ?", what: "L'Éclat et son horaire seront retirés du parc. Ses rapports passés restent dans l'historique.", approveLabel: "Retirer", refuseLabel: "Garder" });
    if (anchor && anchor.after) anchor.after(card); else root.append(card);
    const v = await card.promise; card.remove();
    if (v !== "approve") return;
    try { await api.post("/api/dots/remove", { id: dot.id }); ctx.toast("Éclat retiré du parc."); loadAll(); }
    catch (e) { ctx.toast("Retrait impossible.", true); }
  }
  async function createDot() {
    const name = fName.value.trim(), prompt = fPrompt.value.trim();
    const adv = fSched.value.trim();
    const composed = schedCompose();
    const schedule = adv || composed;
    const fromAdv = !!adv;
    if (!name || !schedule || !prompt) { ctx.toast("Nom, horaire et mission sont requis.", true); return; }
    if (schedule && !nextRun(schedule)) { setFieldError(fromAdv ? fSched : (schedTimeInputs[0] || fSched), "Horaire illisible — exemple : " + SCHED_EX); ctx.toast("Horaire illisible — formats : « 07:30 » ou « lun-ven 08:00,12:30 ».", true); return; }
    setFieldError(fSched, null);
    if (schedTimeInputs[0]) setFieldError(schedTimeInputs[0], null);
    const id = "perso-" + name.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 32);
    try {
      await api.post("/api/dots/save", { id, name, color: fColor.value, role: "Éclat personnel", tools: [], brain: "", schedule, prompt, paused: false, quiet_ok: true });
      ctx.toast("Éclat « " + name + " » créé — prochain passage : " + fmtNext(nextRun(schedule)) + ".");
      fName.value = fSched.value = fPrompt.value = ""; loadAll();
    } catch (e) { ctx.toast("Création impossible.", true); }
  }
  /* Le rituel est-il déjà au parc — sous N'IMPORTE laquelle de ses formes ? */
  function ritualDot(r) {
    return dots.find((x) => x.id === r.parkId) || dots.find((x) => x.id === r.ameId)
      || dots.find((x) => normName(x.name) === normName(r.name)) || null;
  }
  async function importAme(only) {
    const missing = AME_RITUALS.filter((r) => !r.mergedInto && !ritualDot(r) && (!only || only === r));
    if (!missing.length) { ctx.toast(only ? "« " + only.name + " » est déjà au parc — aucun doublon créé." : "Tous les rituels sont déjà au parc — aucun doublon créé."); return; }
    const items = missing.map((r) => ({ id: r.parkId, name: r.name, color: r.color, role: r.role, tools: [], brain: "", schedule: r.schedule, prompt: r.prompt, paused: true, quiet_ok: true }));
    try {
      const j = await api.post("/api/dots/import", { items });
      ctx.toast((j && j.imported != null ? j.imported + " rituel(s) importé(s)" : "Import effectué") + " — en pause, active-les un par un.");
      loadAll();
    } catch (e) { ctx.toast("Import impossible.", true); }
  }
  /* ── Phases : UN vocabulaire (celui du CSS, plush.js) ──────────────────
     Priorité : signal du moment (actif, attente) > pause > échec passé >
     repos. carePaused = pause du GARDIEN (DotCare), distincte de la pause
     du Dot — les deux libellés ne se confondent plus. */
  /* PHASE_LBL : table unique dans core.js (phaseLabel) — U6 23/10. */
  const PHASE_ST = { actif: "run", attente: "warn", pause: "warn", carepause: "warn", erreur: "err", repos: "idle" };
  function phaseOf(d, env) {
    const id = String(d.id);
    if (env.activeIds.has(id)) return "actif";
    if (env.waitingIds.has(id)) return "attente";
    if (d.paused) return "pause";
    if (env.careMap[id] && env.careMap[id].paused) return "carepause";
    const lr = env.lastRun[id];
    if (lr && (lr.ok === false || String(lr.status || "").toUpperCase() === "ECHEC")) return "erreur";
    return "repos";
  }
  const cssPhase = (ph) => ph === "carepause" ? "pause" : ph;

  /* ── Statut d'un Éclat au parc (V5-X, flotte du 25/10) ────────────────
     Retiré = gardé au parc, en pause, sans horaire, avec un motif (le moteur
     ne le planifie plus ; « Réactiver » rend l'horaire d'avant). Ancien
     format accepté : merged_into + pause. À la demande = actif sans horaire. */
  const isRetired = (d) => !!d.paused && (d.retired === true || (!!d.merged_into && d.retired !== false));
  const groupOf = (d, env) => {
    if (isRetired(d)) return "retire";
    const carePaused = !!(env.careMap[d.id] && env.careMap[d.id].paused);
    if (d.paused || carePaused) return "pause";
    return "actif";
  };
  const retiredWhy = (d, env) => {
    if (d.retired_motif) return String(d.retired_motif);
    if (d.merged_into === "(à la demande)") return "retiré — à la demande";
    if (d.merged_into) return "fusionné dans « " + env.nameOf(d.merged_into) + " »";
    return "retiré";
  };
  /* Pastille du dernier passage : statut de charte + âge. */
  const relAge = (v) => {
    const t = v ? new Date(v).getTime() : NaN; if (!isFinite(t)) return "";
    const m = Math.max(0, Math.round((Date.now() - t) / 60000));
    if (m < 2) return "à l'instant"; if (m < 60) return "il y a " + m + " min";
    const hh = Math.round(m / 60); if (hh < 48) return "il y a " + hh + " h";
    return "il y a " + Math.round(hh / 24) + " j";
  };
  function lastChip(lr) {
    if (!lr) return h("span", { class: "chip", title: "Aucun passage dans les 30 dernières exécutions servies" }, "jamais passé");
    const st = String(lr.status || "").toUpperCase();
    const en = String(lr.statut || "") === "en_cours";
    let cls = "", lb = "";
    if (en) { cls = ""; lb = "en cours"; }
    else if (st === "OK") { cls = "ok"; lb = "OK"; }
    else if (st === "RAS") { cls = "ok"; lb = "RAS"; }
    else if (st === "PARTIEL") { cls = "warn"; lb = "Partiel"; }
    else if (st === "ECHEC" || lr.ok === false) { cls = "bad"; lb = "Échec"; }
    else if (st === "ARRETE") { cls = ""; lb = "Arrêté"; }
    else { cls = lr.ok ? "ok" : ""; lb = lr.ok ? "Fait" : "?"; }
    const age = relAge(lr.ts);
    return h("span", { class: "chip " + cls, style: "white-space:nowrap", title: "Dernier passage : " + fmtDate(lr.ts) }, age ? lb + " · " + age : lb);
  }
  const ONE = "white-space:nowrap;overflow:hidden;text-overflow:ellipsis";
  /* Prochain passage court : « aujourd'hui 18:00 », « demain 08:15 », « lun. 08:35 ». */
  const JOURS = ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."];
  function fmtShort(dt) {
    if (!dt) return "—";
    const hm = String(dt.getHours()).padStart(2, "0") + ":" + String(dt.getMinutes()).padStart(2, "0");
    const d0 = new Date(); d0.setHours(0, 0, 0, 0);
    const d1 = new Date(dt); d1.setHours(0, 0, 0, 0);
    const days = Math.round((d1 - d0) / 864e5);
    if (days === 0) return "aujourd'hui " + hm;
    if (days === 1) return "demain " + hm;
    return JOURS[dt.getDay()] + " " + hm;
  }

  /* ── Ligne du parc : UNE ligne de mission + prochain passage + dernier résultat ── */
  function dotRow(d, env) {
    const persona = (d && d.persona) || {};
    const grp = groupOf(d, env);
    const phase = phaseOf(d, env);
    const name = String(d.name || d.id || "Éclat");
    const deadQ = grp === "actif" ? deadInfo(d, settings) : null;
    const next = grp === "actif" ? nextRun(d.schedule) : null;
    const stDot = h("span", { class: "dotst " + PHASE_ST[phase] });
    /* V5-X : le libellé d'état ne s'affiche que s'il dit quelque chose de plus que la pastille du dernier passage. */
    const LOUD = { actif: 1, carepause: 1 };
    const stTxt = h("span", { class: "dotst-lb", style: LOUD[phase] ? "" : "display:none" }, phaseLabel(phase, "État inconnu"));
    /* Panneau d'édition de l'horaire, déplié SOUS la ligne (DS §6.7) */
    const schedIn = h("input", { type: "text", value: String(d.schedule || ""), class: "fld", "aria-label": "Horaire de « " + name + " »" });
    const editErr = h("div", {});
    const panel = h("div", { hidden: true, style: "padding:var(--sp-3) var(--sp-2);border-bottom:1px solid var(--stroke)" },
      h("div", { class: "field" }, h("span", { class: "field-lb" }, "Horaire de « " + name + " »"),
        schedIn,
        h("span", { class: "field-help" }, "Grammaire DotScheduler : « 07:30 » ou « lun-ven 08:00,12:30 ». Vide = aucun horaire (lancement manuel uniquement).")),
      editErr,
      h("div", { style: "display:flex;gap:var(--sp-2);margin-top:var(--sp-2)" },
        h("button", { class: "btn sm acc", onclick: () => {
          const v = schedIn.value.trim();
          editErr.replaceChildren(); schedIn.removeAttribute("aria-invalid");
          if (v && !nextRun(v)) { schedIn.setAttribute("aria-invalid", "true"); editErr.replaceChildren(h("div", { class: "field-err", role: "alert" }, "Horaire illisible — formats : « 07:30 » ou « lun-ven 08:00,12:30 ».")); return; }
          panel.hidden = true; saveDot(d, { schedule: v });
        } }, "Enregistrer"),
        h("button", { class: "btn sm ghost", onclick: () => { panel.hidden = true; schedIn.value = String(d.schedule || ""); editErr.replaceChildren(); schedIn.removeAttribute("aria-invalid"); } }, "Annuler")));
    /* VAGUE 2 FIABILITÉ : Stop RÉEL (POST /api/dots/stop) — visible seulement quand le moteur dit l'Éclat en cours
       (GET /api/dots/active) ou pendant un lancement depuis cette ligne ; la réponse du moteur est lue, jamais supposée. */
    const stopBtn = h("button", { class: "btn sm fi-stop", hidden: phase !== "actif", title: "Arrêter l'exécution en cours de « " + name + " »",
      onclick: async (e) => {
        e.stopPropagation();
        const b = e.currentTarget; if (b.disabled) return;
        b.disabled = true;
        try {
          const j = await api.post("/api/dots/stop", { id: d.id });
          if (j && j.ok === false) ctx.toast(String(j.error || "Rien à arrêter : l'exécution est déjà terminée."));
          else ctx.toast("Arrêt demandé — « " + name + " » s'interrompt à la prochaine étape.");
        } catch (err) { ctx.toast("Arrêt impossible : " + String((err && err.message) || err), true); }
        finally { b.disabled = false; setTimeout(() => { if (!dead) loadAll(); }, 1200); }
      } }, h("span", { html: ic("stop", 12) }), "Stop");
    const launchBtn = h("button", { class: "btn sm " + (grp === "retire" ? "ghost" : "acc"), onclick: async (e) => {
      e.stopPropagation();
      const btn = e.currentTarget, nom = name;
      if (btn.disabled) return;
      btn.disabled = true; const oldLbl = btn.textContent; btn.textContent = "En cours…";
      stopBtn.hidden = false;
      let stopped = false;
      const rec0 = plushById.get(String(d.id)); if (rec0) rec0.apply("actif");
      /* §53 : /api/dots/run est un flux SSE — consommé en direct : cerveau annoncé, fin annoncée, liste rechargée. */
      try {
        await sse("/api/dots/run", { id: d.id }, (ev, data) => {
          if (ev === "brain" && data && data.label) ctx.toast("Éclat « " + nom + " » lancé — cerveau : " + data.label);
          else if (ev === "stopped") stopped = true;
          else if (ev === "error" && !stopped && !/annul/i.test(String((data && data.message) || ""))) throw new Error((data && data.message) || "erreur du moteur pendant l'exécution");
        });
        ctx.toast(stopped ? "Éclat « " + nom + " » arrêté à ta demande." : "Éclat « " + nom + " » terminé.");
      } catch (err) {
        ctx.toast("Éclat « " + nom + " » : " + String((err && err.message) || err), true);
      } finally {
        btn.disabled = false; btn.textContent = oldLbl;
        stopBtn.hidden = true;
        loadAll();
      }
    } }, "Lancer");
    /* Menu ⋯ selon le groupe. « Retirer » garde l'Éclat en réserve (rien n'est supprimé) ;
       « Supprimer du parc » reste derrière la carte d'approbation. */
    const menuItems = [];
    if (grp === "retire") {
      const back = String(d.prev_schedule || "");
      menuItems.push({ label: "Réactiver" + (back ? " (horaire d'avant : " + back + ")" : " (sans horaire)"), onclick: () => saveDot(d, { paused: false, retired: false, retired_motif: "", schedule: back }) });
    } else {
      menuItems.push({ label: "Modifier l'horaire", onclick: () => { panel.hidden = !panel.hidden; if (!panel.hidden) schedIn.focus(); } });
      menuItems.push({ label: d.paused ? "Reprendre l'Éclat" : "Mettre l'Éclat en pause", onclick: () => saveDot(d, { paused: !d.paused }) });
      menuItems.push({ label: "Retirer (garder en réserve)", onclick: () => saveDot(d, { paused: true, retired: true, retired_motif: "retiré à la main", prev_schedule: String(d.schedule || ""), schedule: "" }) });
    }
    menuItems.push({ sep: true });
    menuItems.push({ label: "Supprimer du parc", danger: true, onclick: () => removeDot(d, wrap) });
    /* Méta de droite : prochain passage (ou à la demande / motif), dernier résultat. */
    let when = "";
    if (grp === "retire") when = "";
    else if (grp === "pause") when = d.pause_motif ? String(d.pause_motif) : (d.schedule ? "en pause · " + String(d.schedule) : "en pause");
    else if (!String(d.schedule || "").trim()) when = "à la demande";
    else when = next ? fmtShort(next) : "horaire illisible";
    const ritual = /^imp-(rituel|ame)-/.test(String(d.id || ""));
    const RIT_DESC = { "point chantier": "Point de la semaine sur un chantier personnel (exemple) : avancement, dépenses, prochaine étape.", "podcast": "Ton épisode de la semaine, choisi pour tes dossiers.", "dictée": "Dictée du soir : ce que tu retiens de la journée, en 2 minutes.", "sparring": "Entraînement d'anglais professionnel : une question de bailleur, ta réponse, un retour.", "post": "Idée de post de la semaine, prête à relire.", "contact": "Un contact à relancer cette semaine, avec la raison.", "cash": "Point trésorerie du vendredi.", "fermeture": "Fermeture de la semaine : ce qui est clos, ce qui reste." };
    const ritualDesc = () => {
      const low = name.toLowerCase();
      for (const k of Object.keys(RIT_DESC)) if (low.includes(k)) return RIT_DESC[k];
      /* 25/10 : la consigne de repli (« Si Ahadi n'est pas disponible… ») n'est pas une mission — on prend la première vraie phrase. */
      const parts = String(d.prompt || "").split(/(?<=[.!?])\s+/).filter((x) => x && !/^si ahadi|aucune r[ée]ponse|sans brouillon|version autonome/i.test(x));
      return parts[0] || String(d.role || d.goal || "Rituel");
    };
    const missionTxt = grp === "retire" ? retiredWhy(d, env) : (ritual ? ritualDesc() : String(d.role || d.goal || d.prompt || ""));
    const row = h("div", { class: "row-item x-dot", "data-dot": String(d.id || ""), style: "gap:var(--sp-3);padding:8px 6px" + (grp === "retire" ? ";opacity:.78" : "") },
      h("div", { class: "parc-plush", style: "width:32px;height:32px;flex:none" }),
      h("div", { class: "grow x-open", style: "min-width:0;cursor:pointer", role: "button", tabindex: "0", title: "Ouvrir le détail de « " + name + " »", onclick: () => openDetail(d), onkeydown: (e) => { if (e.key === "Enter") openDetail(d); } },
        h("div", { class: "tt", style: ONE, title: name }, name + (persona.who ? " — " + String(persona.who) : "")),
        h("div", { class: "ss", style: ONE, title: missionTxt }, missionTxt)),
      deadQ ? h("span", { class: "chip warn", title: "Horaire intégralement dans les heures calmes (" + deadQ.label + ") — le planificateur ne part jamais à cette heure." }, "créneau mort") : null,
      when ? h("span", { class: "ss", style: "flex:none;width:150px;text-align:right;" + ONE, title: (d.schedule ? "Horaire : " + String(d.schedule) : "") + (next ? " · prochain : " + fmtNext(next) : "") }, when) : null,
      grp === "retire" ? null : h("span", { style: "flex:none;width:128px;display:inline-flex;justify-content:flex-end" }, lastChip(env.lastRun[d.id])),
      grp === "retire" ? null : h("span", { style: "display:inline-flex;align-items:center;gap:var(--sp-1);flex:none", title: phaseLabel(phase, "") }, stDot, stTxt),
      h("span", { class: "row-actions", style: "flex:none" },
        stopBtn,
        grp === "retire" ? null : launchBtn,
        rowMenu(menuItems, "Plus d'actions pour « " + name + " »")));
    const wrap = h("div", {}, row, panel);
    const p = mountPlush(row.querySelector(".parc-plush"), String(d.color || "#FF7A29"), 32, String(d.id || ""), "");
    p.setPhase(cssPhase(phase));
    plushes.push(p);
    plushById.set(String(d.id), {
      p, base: () => cssPhase(phaseOf(d, env)),
      apply: (ph) => { try { p.setPhase(ph); stTxt.textContent = phaseLabel(ph, "État inconnu"); stTxt.style.display = LOUD[ph] || ph === "erreur" ? "" : "none"; stDot.className = "dotst " + (PHASE_ST[ph] || "idle"); } catch (e) {} },
    });
    return wrap;
  }

  /* ── Parc groupé : Actifs · En pause · Retirés (repliés) ───────────── */
  function renderParc(env) {
    const groups = { actif: [], pause: [], retire: [] };
    for (const d of dots) groups[groupOf(d, env)].push(d);
    /* Actifs : planifiés d'abord, par prochain passage ; à la demande ensuite. */
    const nx = (d) => { const n = nextRun(d.schedule); return n ? n.getTime() : Infinity; };
    groups.actif.sort((a, b) => nx(a) - nx(b));
    parcSummary.textContent = dots.length + " au parc · " + groups.actif.length + " actifs · " + groups.pause.length + " en pause · " + groups.retire.length + " retirés";
    const block = (key, title, desc, open) => {
      const list = groups[key];
      const body = h("div", { class: "rows" }, ...list.map((d) => dotRow(d, env)));
      const sum = h("summary", { style: "cursor:pointer;display:flex;gap:var(--sp-2);align-items:baseline;padding:6px 0;flex-wrap:wrap" },
        h("span", { class: "tt" }, title + " (" + list.length + ")"), h("span", { class: "ss" }, desc));
      const det = h("details", { class: "x-group", "data-group": key }, sum, list.length ? body : h("div", { class: "empty" }, "Aucun."));
      if (open) det.open = true;
      return det;
    };
    parcBox.replaceChildren(...(dots.length ? [
      block("actif", "Actifs", "triés par prochain passage — un « RAS » reste silencieux", true),
      block("pause", "En pause", "par toi, l'anti-boucle ou DotCare — « Reprendre » dans le menu ⋯", groups.pause.length > 0),
      block("retire", "Retirés", "gardés en réserve, sans horaire — « Réactiver » dans le menu ⋯", false),
    ] : [h("div", { class: "empty" }, "Parc vide — crée un Éclat (bouton « + Nouvel Éclat ») ou installe un pack plus bas.")]));
  }

  /* ── Ligne rituel de l'âme (présence testée par clé, jamais par un
        seul préfixe d'id) ─────────────────────────────────────────────── */
  function ameRow(r) {
    const d = ritualDot(r);
    if (r.mergedInto) {
      /* V5-X : rituel fusionné (flotte du 25/10) — jamais réimporté en doublon. */
      const tgt = dots.find((x) => x.id === r.mergedInto);
      return h("div", { class: "row-item", style: "opacity:.75" },
        h("span", { style: "width:28px;height:28px;flex:none;display:inline-block" }),
        h("div", { class: "row-main" }, h("div", { class: "tt" }, r.name + " — " + r.freq), h("div", { class: "ss ss--wrap" }, "Fait désormais par « " + String((tgt && tgt.name) || r.mergedInto) + " »")),
        h("span", { class: "chip" }, "fusionné"));
    }
    const state = !d ? "à importer" : isRetired(d) ? "au parc — retiré" : d.paused ? "au parc — en pause" : "au parc — actif";
    const amePlush = h("span", { style: "width:28px;height:28px;flex:none;display:inline-block" });
    try { mountPlush(amePlush, r.color || "#D93226", 28, String(r.parkId || r.name || "dot"), ""); } catch (e) {}
    return h("div", { class: "row-item" },
      amePlush,
      h("div", { class: "row-main" },
        h("div", { class: "tt", title: r.name }, r.name + " — " + r.freq),
        h("div", { class: "ss ss--wrap" }, truncWords(r.prompt, 110))),
      h("span", { class: "chip" }, state),
      !d ? h("button", { class: "btn sm", onclick: () => importAme(r) }, "Importer")
        : d.paused ? h("button", { class: "btn sm acc", onclick: () => saveDot(d, { paused: false }) }, "Activer")
        : h("button", { class: "btn sm", onclick: () => saveDot(d, { paused: true }) }, "Mettre en pause"));
  }

  /* ── Ligne d'exécution : rapport complet au clic + brouillons liés ──── */
  function runRow(r, draftsByRun) {
    const full = String(r.result || r.summary || "");
    const linked = (r.id && draftsByRun.get(String(r.id))) || [];
    const detail = h("div", { class: "run-detail", hidden: true },
      h("div", { class: "ss", style: "margin-bottom:var(--sp-2)" },
        [r.brain ? "cerveau : " + String(r.brain) : "", r.ms ? "durée : " + Math.round(Number(r.ms) / 100) / 10 + " s" : "",
         (r.usage_in || r.usage_out) ? "jetons : " + String(r.usage_in || 0) + " entrants · " + String(r.usage_out || 0) + " sortants" : ""].filter(Boolean).join(" · ")),
      full ? h("div", { class: "ss ss--wrap run-full", html: md(full) }) : h("div", { class: "ss" }, "Rapport vide."),
      linked.length ? h("div", { style: "display:flex;gap:var(--sp-2);flex-wrap:wrap;margin-top:var(--sp-2)" },
        ...linked.map((df) => h("button", { class: "btn sm", onclick: () => ctx.navigate("messages") },
          h("span", { html: ic("draft", 13) }), " Brouillon créé : " + String(df.to || df.target || df.subject || "sans destinataire") + " — voir dans Messages"))) : null);
    const row = h("div", { class: "row-item", style: "cursor:pointer", title: "Cliquer pour le rapport complet",
      onclick: () => { detail.hidden = !detail.hidden; } },
      h("span", { class: "dotst " + (r.ok === true ? "ok" : r.ok === false ? "err" : "idle") }),
      h("div", { class: "grow" }, h("div", { class: "tt" }, String(r.dot_name || r.name || r.dot || r.id || "Exécution")),
        h("div", { class: "ss" }, (() => { const et = etatLabel(r.status || r.state), rs = cleanResume(r.summary || r.result || ""); return [fmtDate(r.ts || r.at || r.date), et && rs.toLowerCase().startsWith(String(et).toLowerCase()) ? "" : et, rs].filter(Boolean).join(" · "); })(), /* V5-W : « Partiel · Partiel — … » → une seule fois */ ...(linked.length ? [" · ", h("span", { html: ic("draft", 11) }), " " + linked.length + " brouillon(s)"] : []))));
    return h("div", { "data-run": String(r.id || "") }, row, detail);
  }
  /* V5-T (25/10) : « Voir le résultat complet » d'une carte d'Éclat (feedcard.js, clé
     nova2_pending_run + nova:eclat-run-focus) ouvre CE run : rapport déplié, ligne mise en
     évidence. Une exécution hors des 10 lignes affichées est ajoutée en tête de liste. */
  let focusWant = null;   // { run_id, dot, until } — survit aux rechargements rapprochés (montage + signal du bus)
  function focusPendingRun(runs, draftsByRun) {
    let pend = null;
    try { pend = JSON.parse(localStorage.getItem("nova2_pending_run") || "null"); } catch (e) { pend = null; }
    if (pend && pend.at && Date.now() - Number(pend.at) <= 120000) { focusWant = { run_id: pend.run_id, dot: pend.dot, until: Date.now() + 10000 }; }
    try { if (pend) localStorage.removeItem("nova2_pending_run"); } catch (e) {}
    if (!focusWant || Date.now() > focusWant.until) { focusWant = null; return; }
    pend = focusWant;
    const rid = String(pend.run_id || ""), did = String(pend.dot || "");
    let el = null;
    try { el = rid ? [...runsBox.querySelectorAll("[data-run]")].find((x) => x.dataset.run === rid) || null : null; } catch (e) { el = null; }
    if (!el) {
      const r = (rid && runs.find((x) => String((x && x.id) || "") === rid)) || (did ? runs.find((x) => String((x && (x.dot || x.dot_id)) || "") === did) : null);
      if (r) { el = runRow(r, draftsByRun); runsBox.insertBefore(el, runsBox.children[1] || null); }
    }
    if (!el) { ctx.toast("Exécution introuvable dans l'historique servi par le moteur (30 dernières)."); return; }
    const det = el.querySelector(".run-detail"); if (det) det.hidden = false;
    el.classList.add("run-focus");
    setTimeout(() => { try { el.scrollIntoView({ block: "center", behavior: "smooth" }); } catch (e) {} }, 80);
  }

  /* ── Interrupteur global (en tête de Santé & packs, audit §6.1.4) ────── */
  function renderGlobal() {
    const onAuto = settings.dots_auto !== false;
    globalBox.replaceChildren(
      h("div", { class: "card flat", style: "display:flex;gap:var(--sp-3);align-items:center" },
        h("span", { html: ic("zap", 18) }),
        h("div", { class: "row-main" }, h("div", { class: "tt" }, "Automatismes planifiés"), h("div", { class: "ss ss--wrap" }, "Interrupteur général du DotScheduler (réglage dots_auto). Les heures calmes continuent de s'appliquer.")),
        h("span", { class: "chip " + (onAuto ? "ok" : "warn") }, onAuto ? "Actifs" : "En pause globale"),
        h("button", { class: "btn", onclick: async () => {
          const v = !onAuto;
          try { await api.post("/api/settings", { dots_auto: v }); settings.dots_auto = v; renderGlobal(); ctx.toast(v ? "Automatismes activés." : "Automatismes en pause globale."); }
          catch (e) { ctx.toast("Réglage impossible.", true); }
        } }, onAuto ? "Tout mettre en pause" : "Tout réactiver")),
      h("p", { class: "sec-desc", style: "margin-top:var(--sp-3)" },
        "Limite assumée : les routines tournent dans l'app Nova ouverte (ou en arrière-plan sur le Mac). App fermée, elles attendent — le moteur rattrape les créneaux manqués dans les 3 heures à la réouverture. Il n'y a pas de daemon séparé : Nova ne promet pas ce qu'elle n'a pas."));
  }

  /* ── V6 ÉCLATS (25/10) : page de détail d'un Éclat (modèle : tâche Muse — frise à gauche
        « Démarré → étapes → Terminé », « Résumé » à droite). Entrée : clic sur une ligne du parc.
        Onglets Activité / Leçons ; actions Lancer maintenant, Pause/Reprendre, Réorienter, Retirer. ── */
  let allRuns = [], lastEnv = null, detailId = "", detailTab = "activite", detailRun = "";
  const detailBox = h("div", { class: "x-eclat", hidden: true });
  root.querySelector(".mod-head").after(detailBox);
  if (!document.getElementById("x-eclat-css")) {
    const css = h("style", { id: "x-eclat-css" });
    css.textContent = ".x-eclat{display:grid;gap:var(--ds-4)}"
      + ".x-eclat .xe-grid{display:grid;grid-template-columns:minmax(220px,320px) minmax(0,1fr);gap:var(--ds-4);align-items:start}"
      + "@media (max-width:760px){.x-eclat .xe-grid{grid-template-columns:minmax(0,1fr)}}"
      + ".x-eclat .xe-runs{display:grid;gap:var(--ds-1);max-height:520px;overflow:auto}"
      + ".x-eclat .xe-tl{list-style:none;margin:var(--ds-2) 0 0;padding:0 0 0 var(--ds-3);border-left:2px solid var(--hairline);display:grid;gap:var(--ds-2)}"
      + ".x-eclat .xe-tl li{position:relative;font:400 13px/18px var(--f-ui);color:var(--text-2);min-width:0;overflow-wrap:anywhere}"
      + ".x-eclat .xe-tl li::before{content:'';position:absolute;left:calc(-1 * var(--ds-3) - 6px);top:5px;width:8px;height:8px;border-radius:50%;background:var(--ds-neutral)}"
      + ".x-eclat .xe-tl li.ok::before{background:var(--ds-ok)}.x-eclat .xe-tl li.bad::before{background:var(--ds-danger)}.x-eclat .xe-tl li.warn::before{background:var(--ds-warn)}"
      + ".x-eclat .xe-tl b{color:var(--text-1);font-weight:600}"
      + ".x-eclat .xe-reo{display:flex;gap:var(--ds-2);flex-wrap:wrap}.x-eclat .xe-reo input{flex:1;min-width:180px}"
      + ".efb{display:grid;gap:var(--ds-2);margin-top:var(--ds-3)}.efb-row{display:flex;gap:var(--ds-2);align-items:center;flex-wrap:wrap}.efb-row[hidden]{display:none}"
      + ".efb-note{flex:1;min-width:160px}.efb[data-v=utile] .efb-b[data-v=utile],.efb[data-v=pas_utile] .efb-b[data-v=pas_utile],.efb[data-v=corriger] .efb-b[data-v=corriger]{box-shadow:inset 0 0 0 1.5px var(--ds-ring);font-weight:600}";
    document.head.append(css);
  }
  const fleetNodes = () => [...root.children].filter((x) => x !== detailBox && !x.classList.contains("mod-head"));
  function closeDetail() {
    detailId = ""; detailRun = ""; detailBox.hidden = true; detailBox.replaceChildren();
    fleetNodes().forEach((x) => { if (x.dataset.xeHid === "1") { x.hidden = false; delete x.dataset.xeHid; } });
  }
  function openDetail(d) {
    detailId = String(d.id); detailTab = "activite"; detailRun = "";
    fleetNodes().forEach((x) => { if (!x.hidden) { x.hidden = true; x.dataset.xeHid = "1"; } });
    detailBox.hidden = false;
    renderDetail(d);
    try { root.scrollIntoView({ block: "start" }); } catch (e) {}
  }
  const tone = (r) => {
    const st = String((r && r.status) || "").toUpperCase();
    if (r && r.statut === "en_cours") return "neutral";
    if (st === "OK" || st === "RAS") return "ok";
    if (st === "PARTIEL") return "warn";
    if (st === "ECHEC" || (r && r.ok === false)) return "danger";
    return "neutral";
  };
  const stLabel = (r) => {
    if (r && r.statut === "en_cours") return "En cours";
    const st = String((r && r.status) || "").toUpperCase();
    return { OK: "Réussi", RAS: "RAS", PARTIEL: "Partiel", ECHEC: "Échec", ARRETE: "Arrêté" }[st] || (r && r.ok ? "Fait" : "—");
  };
  const TOOL_FR = { web_search: "recherche web", web_fetch: "lecture d'une page", recall: "mémoire", know: "savoir", mail_unread: "courrier non lu", mail_week: "courrier de la semaine", calendar: "agenda", reminders: "rappels", teams_read: "Teams", brvm_cours: "cours BRVM", ask_assistant: "question à Nova", supervision_nova: "relecture par Nova", read_file: "lecture d'un fichier", draft_reply: "brouillon", today: "aujourd'hui", system: "état du Mac", processes: "processus", flux_titres: "titres de flux", notes: "notes" };
  function timeline(r) {
    const end = r.ts ? new Date(r.ts) : null;
    const start = end && r.ms ? new Date(end.getTime() - Number(r.ms)) : end;
    const hm = (t) => t && !isNaN(t) ? fmtTimeFR(t) : "";
    const steps = Array.isArray(r.steps) ? r.steps : [];
    const tl = h("ol", { class: "xe-tl", "aria-label": "Déroulé du passage" },
      h("li", {}, h("b", {}, "Démarré"), start ? " · " + hm(start) : "", r.trigger_label ? " · " + String(r.trigger_label) : ""));
    for (const s0 of steps) {
      const out = String(s0.output || "");
      const bad = /^(Refusé|ÉCHEC|Erreur)/i.test(out);
      tl.append(h("li", { class: bad ? "bad" : "ok", title: out.slice(0, 400) }, TOOL_FR[s0.tool] || String(s0.tool || "étape"), s0.input ? " — " + truncWords(String(s0.input), 12) : ""));
    }
    if (!steps.length && r.statut !== "en_cours") tl.append(h("li", {}, "Aucun outil enregistré pour ce passage"));
    const t = tone(r);
    tl.append(h("li", { class: t === "danger" ? "bad" : t }, h("b", {}, r.statut === "en_cours" ? "En cours…" : "Terminé"), r.statut === "en_cours" ? "" : " · " + stLabel(r) + (end ? " · " + hm(end) : "") + (r.ms ? " · " + Math.round(Number(r.ms) / 1000) + " s" : "")));
    return tl;
  }
  async function renderDetail(d) {
    const id = String(d.id), name = String(d.name || id);
    const runs = allRuns.filter((r) => String(r.dot || r.dot_id || "") === id);
    const env = lastEnv || { activeIds: new Set(), careMap: {} };
    const running = env.activeIds && env.activeIds.has(id);
    let fb = { items: [], stats: {} };
    try { fb = (await api.get("/api/dots/feedback?dot=" + encodeURIComponent(id), 10000)) || fb; } catch (e) {}
    if (detailId !== id) return;
    const verdictOf = new Map((fb.items || []).map((x) => [String(x.run_id || ""), String(x.verdict || "")]));
    const mission = String(d.role || d.goal || d.prompt || "");
    const head = pageHead({ title: name, sub: mission, actions: [
      { label: "← Retour au parc", ghost: true, onClick: closeDetail },
      { label: running ? "En cours…" : "Lancer maintenant", primary: true, disabled: !!running, onClick: async () => { try { await api.post("/api/dots/launch", { id }); ctx.toast("« " + name + " » lancé."); setTimeout(() => { if (!dead) loadAll(); }, 1500); } catch (e) { ctx.toast("Lancement impossible.", true); } } },
      { label: d.paused ? "Reprendre" : "Pause", onClick: () => saveDot(d, { paused: !d.paused }) },
      { label: "Retirer", danger: true, onClick: () => { saveDot(d, { paused: true, retired: true, retired_motif: "retiré à la main", prev_schedule: String(d.schedule || ""), schedule: "" }); closeDetail(); } },
    ] });
    const stateLine = h("div", { class: "ds-meta" }, [
      d.paused ? "En pause" + (d.pause_motif ? " — " + String(d.pause_motif) : "") : "Actif",
      d.schedule ? "horaire : " + String(d.schedule) : "à la demande",
      runs.length + " passage(s) servis",
    ].join(" · "));
    /* Réorienter : une ligne, servie au prochain passage (bloc « PRIORITÉ D'AHADI ») puis effacée par le moteur. */
    const reoIn = h("input", { type: "text", class: "fld", maxlength: "300", placeholder: "Ex. : concentre-toi sur les mails de la DG cette fois", "aria-label": "Réorienter le prochain passage" });
    const reoBtn = dsAction({ label: "Réorienter", onClick: async () => { const t = reoIn.value.trim(); if (!t) { reoIn.focus(); return; } try { await api.post("/api/dots/reorient", { id, text: t }); ctx.toast("Consigne notée pour le prochain passage."); d.reorient = { text: t }; renderDetail(d); } catch (e) { ctx.toast("Réorientation impossible.", true); } } });
    reoIn.addEventListener("keydown", (e) => { if (e.key === "Enter") reoBtn.click(); });
    const reoCur = d.reorient && d.reorient.text ? h("div", { class: "ds-meta" }, "Consigne en attente du prochain passage : « " + String(d.reorient.text) + " » ",
      dsAction({ label: "Effacer", ghost: true, onClick: async () => { try { await api.post("/api/dots/reorient", { id, text: "" }); delete d.reorient; renderDetail(d); } catch (e) {} } })) : null;
    const reoCard = card({ title: "Réorienter le prochain passage" }, h("div", { class: "xe-reo" }, reoIn, reoBtn), reoCur);
    const body = h("div", {});
    const tb = tabs([{ id: "activite", label: "Activité", n: runs.length, on: detailTab === "activite" }, { id: "lecons", label: "Leçons", n: (fb.items || []).length, on: detailTab === "lecons" }], (t) => { detailTab = t; paint(); });
    function paint() {
      if (detailTab === "lecons") {
        const st = fb.stats || {};
        const items = (fb.items || []);
        body.replaceChildren(section({ title: "Leçons d'Ahadi", count: items.length, body: [
          h("p", { class: "ds-meta" }, "Utile " + (st.utile || 0) + " · Pas utile " + (st.pas_utile || 0) + " · Corrections " + (st.corriger || 0) + " — les 5 dernières notes et ce ratio sont injectés avant chaque passage."),
          ...(items.length ? items.map((x) => row({ title: x.note ? String(x.note) : (x.verdict === "utile" ? "Utile" : "Pas utile"), meta: fmtDT(x.ts), side: pill(x.verdict === "utile" ? "Utile" : x.verdict === "pas_utile" ? "Pas utile" : "Correction", x.verdict === "utile" ? "ok" : x.verdict === "pas_utile" ? "warn" : "neutral"),
            actions: [{ icon: "trash", tip: "Supprimer cette leçon", onClick: async () => { try { await api.post("/api/dots/feedback/delete", { dot: id, id: x.id }); renderDetail(d); } catch (e) { ctx.toast("Suppression impossible.", true); } } }] }))
            : [empty({ text: "Aucun retour encore — utilise « Utile », « Pas utile » ou « Corriger… » sous un résumé.", compact: true })]),
        ] }));
        return;
      }
      if (!runs.length) { body.replaceChildren(empty({ text: "Aucun passage parmi les 30 derniers servis par le moteur — « Lancer maintenant » pour le premier." })); return; }
      const cur = runs.find((r) => String(r.id) === detailRun) || runs[0];
      const list = h("div", { class: "xe-runs" }, ...runs.map((r) => row({ title: fmtDT(r.ts) || "Passage", meta: r.trigger_label ? String(r.trigger_label) : cleanResume(String(r.result || "")).slice(0, 90), side: pill(stLabel(r), tone(r)), selected: r === cur, onOpen: () => { detailRun = String(r.id); paint(); } })));
      const full = String(cur.result || "").trim();
      const res = h("div", { class: "fc-run-res" + (isHouse(full) ? " is-house" : "") });
      res.innerHTML = full ? (isHouse(full) ? houseHTML(full) : md(full)) : "<p>Rapport vide.</p>";
      const resume = card({ title: "Résumé" }, h("div", { class: "ds-meta" }, [cur.brain ? "cerveau : " + String(cur.brain) : "", (cur.usage_in || cur.usage_out) ? (Number(cur.usage_in || 0) + Number(cur.usage_out || 0)) + " jetons" : ""].filter(Boolean).join(" · ")), res,
        cur.id && cur.statut !== "en_cours" ? feedbackBar({ runId: String(cur.id), dotId: id, current: verdictOf.get(String(cur.id)) || "", onDone: () => setTimeout(() => { if (detailId === id) renderDetail(d); }, 600) }) : null);
      body.replaceChildren(h("div", { class: "xe-grid" }, card({ title: "Passages" }, list, h("div", { class: "ds-meta", style: "margin-top:var(--ds-3)" }, "Déroulé"), timeline(cur)), resume));
    }
    paint();
    detailBox.replaceChildren(head, stateLine, reoCard, tb, body);
  }

  /* ── Chargement complet ──────────────────────────────────────────────── */
  async function loadAll() {
    try { const sj = await api.get("/api/settings"); if (sj) settings = sj.settings || {}; } catch (e) {}
    if (dead) return;
    renderGlobal();
    /* DotCare d'abord : la carte de santé sert aux lignes du parc. */
    let careMap = {};
    try {
      const c = await api.get("/api/dotcare");
      if (dead) return;
      const items = arrOf(c, "items", "dots");
      for (const it of items) if (it && it.id) careMap[it.id] = it;
      { const nf = items.filter((it) => Number(it.fails) > 0).length, np = items.filter((it) => it.paused).length;
        careSum.textContent = "— " + items.length + " suivis · " + nf + " en échec · " + np + " en pause"; }
      careBox.replaceChildren(
        h("div", { class: "ss ss--wrap", style: "margin-bottom:var(--sp-2)" }, items.length
          ? items.length + " Éclat(s) suivis par DotCare" + (c && c.paused != null ? " · " + String(c.paused) + " en pause (DotCare)" : "") + ". La pause DotCare est celle du gardien ; la pause de l'Éclat vit dans le menu ⋯ de chaque ligne du parc."
          : "DotCare : aucun Éclat suivi lu pour le moment — la santé n'est pas déclarée bonne, elle est non lue."),
        ...items.map((it) => {
          const fails = Number(it.fails) || 0;
          const stateCls = it.paused ? "warn" : fails > 0 ? "err" : "ok";
          const stateLb = it.paused ? "en pause" : fails > 0 ? "en échec" : "en marche";
          return h("div", { class: "row-item" },
            h("span", { class: "dotst " + stateCls }),
            h("div", { class: "row-main" },
              h("div", { class: "tt", title: String(it.name || it.id) }, String(it.name || it.id)),
              h("div", { class: "ss" }, "Échecs consécutifs : " + String(it.fails ?? 0) + (it.last_ts ? " · dernier : " + fmtDT(it.last_ts) + " (" + (it.last_ok ? "réussi" : String(it.last_status || "échec")) + ")" : " · jamais passé"))),
            h("span", { class: "dotst-lb" }, stateLb),
            it.paused ? h("button", { class: "btn sm", onclick: async () => { try { await api.post("/api/dotcare/resume", { id: it.id }); } catch (e) { ctx.toast("Reprise impossible : " + ((e && e.message) || e), true); } loadAll(); } }, "Reprendre (DotCare)")
              : h("button", { class: "btn sm", onclick: async () => { try { await api.post("/api/dotcare/pause", { id: it.id }); } catch (e) { ctx.toast("Pause impossible : " + ((e && e.message) || e), true); } loadAll(); } }, "Pause (DotCare)"));
        }));
      const journal = arrOf(c, "journal");
      careJournal.replaceChildren(...(journal.length ? [h("div", { class: "card flat", style: "margin-top:var(--sp-3)" },
        h("h3", { class: "subhead", style: "margin-bottom:var(--sp-2)" }, "Journal du gardien"),
        ...journal.slice(0, 8).map((e) => h("div", { class: "ss ss--wrap" }, fmtDT(e.ts || e.at) + " — " + String(e.line || e.text || ""))))] : []));
    } catch (e) { if (!dead) { careBox.replaceChildren(errBox("Santé des Éclats (DotCare) injoignable.", loadAll)); careJournal.replaceChildren(); } }
    /* Parc + exécutions + environnement des phases. */
    let waiting = [], waitingIds = new Set();
    try { const w = await api.get("/api/dots/waiting"); waiting = arrOf(w, "items", "waiting"); waiting.forEach((x) => { if (x && x.dot) waitingIds.add(String(x.dot)); }); } catch (e) {}
    try {
      const j = await api.get("/api/dots");
      if (dead) return;
      dots = arrOf(j, "items", "dots");
      const runs = arrOf(j, "runs");
      allRuns = runs;
      let activeIds = new Set();
      try { const a = await api.get("/api/dots/active"); arrOf(a, "items", "runs", "active").forEach((r) => { const id = typeof r === "string" ? r : (r && (r.dot_id || (r.dot && r.dot.id) || (typeof r.dot === "string" ? r.dot : "") || r.id)); if (id) activeIds.add(String(id)); }); } catch (e) {}
      const lastRun = {};
      for (const r of runs) { const rid = String((r && (r.dot || r.dot_id)) || ""); if (rid && !lastRun[rid]) lastRun[rid] = r; }
      const nameOf = (id) => { const d = dots.find((x) => String(x.id) === String(id)); return d ? String(d.name || id) : String(id || "Éclat"); };
      const env = { careMap, activeIds, waitingIds, lastRun, nameOf };
      lastEnv = env;
      if (detailId) { const dd = dots.find((x) => String(x.id) === detailId); if (dd) renderDetail(dd); }
      /* Brouillons produits par les runs : le moteur étiquette chaque
         brouillon du Dot qui l'a créé (tagDrafts) ; on relie par Dot +
         fenêtre du run [début − marge, fin + marge]. Lien seulement —
         jamais bloquant si /api/drafts est injoignable. */
      const draftsByRun = new Map();
      try {
        const dj = await api.get("/api/drafts");
        const drafts = arrOf(dj, "drafts", "items");
        const tOf = (v) => { const t = v ? new Date(v).getTime() : NaN; return isFinite(t) ? t : null; };
        for (const r of runs) {
          const end = tOf(r.ts); if (end == null || !r.id) continue;
          const start = end - (Number(r.ms) || 0) - 15000;
          const linked = drafts.filter((df) => df && String(df.dot || "") === String(r.dot || r.dot_id || "") && tOf(df.ts) != null && tOf(df.ts) >= start && tOf(df.ts) <= end + 15000);
          if (linked.length) draftsByRun.set(String(r.id), linked);
        }
      } catch (e) {}
      clearPlushes();
      /* V5-X : les groupes ouverts/fermés survivent au rechargement doux (signal du bus). */
      const openState = {};
      try { parcBox.querySelectorAll("details[data-group]").forEach((x) => { openState[x.dataset.group] = x.open; }); } catch (e) {}
      renderParc(env);
      try { parcBox.querySelectorAll("details[data-group]").forEach((x) => { if (openState[x.dataset.group] != null) x.open = openState[x.dataset.group]; }); } catch (e) {}
      ameBox.replaceChildren(...AME_RITUALS.map(ameRow));
      { const inPark = AME_RITUALS.filter((r) => ritualDot(r) && !r.mergedInto).length, toImport = AME_RITUALS.filter((r) => !ritualDot(r) && !r.mergedInto).length;
        ameCount.textContent = inPark + " au parc" + (toImport ? " · " + toImport + " à importer" : "") + " · ils figurent aussi dans le Parc"; }
      const shownRuns = runs.slice(0, 10);
      runsBox.replaceChildren(
        ...(runs.length ? [h("div", { class: "list-count" }, shownRuns.length + " affichée(s) sur " + runs.length + " — clique une ligne pour le rapport complet"), ...shownRuns.map((r) => runRow(r, draftsByRun))]
          : [h("div", { class: "empty" }, "Aucune exécution récente.")]));
      try { focusPendingRun(runs, draftsByRun); } catch (e) {}   // V5-T
    } catch (e) { if (!dead) { parcBox.replaceChildren(errBox("Parc injoignable pour le moment.", loadAll)); runsBox.replaceChildren(); } }
    /* File d'attente — avec l'âge de chaque entrée (audit §6.3.5). */
    try {
      if (dead) return;
      waitBox.replaceChildren(...(waiting.length ? [
        h("div", { class: "card appr" },
          h("div", { class: "appr-head" }, h("span", { html: ic("alert", 18) }), h("span", {}, waiting.length + " décision(s) en attente — une par Éclat, la plus récente")),
          ...(waiting.length > 5 ? [h("div", { class: "list-count" }, "5 affichées sur " + waiting.length + " — les autres suivront après décision sur celles-ci.")] : []),
          /* 24/10 : solder d'un geste les comptes rendus de plus de 24 h qui ne posent AUCUNE question (les vraies questions restent). */
          ...(() => {
            const old = waiting.filter((r) => { const t = new Date(r.ts || r.at || r.time || 0).getTime(); return isFinite(t) && t > 0 && Date.now() - t > 864e5 && !(r.decision && r.question); });
            if (old.length < 2) return [];
            const b = h("button", { class: "btn sm", title: "Marque « vu » les comptes rendus de plus de 24 h sans question — les décisions réelles restent dans la file" }, "Classer les " + old.length + " anciennes (plus de 24 h)");
            b.addEventListener("click", async () => {
              b.disabled = true; let n = 0;
              for (const r of old) { try { await api.post("/api/dots/ack", { run_id: r.run_id || r.id || "" }); n++; } catch (e) {} }
              ctx.toast(n + " exécution(s) classée(s) comme vues."); loadAll();
            });
            return [h("div", { style: "display:flex;justify-content:flex-end;margin:4px 0 6px" }, b)];
          })(),
          /* V5-X : lignes resserrées — l'Éclat, la question (une ligne, entière au survol), l'âge ; mêmes gestes (Plus tard / Vu). */
          ...waiting.slice(0, 5).map((r) => {
            const q = r.decision && r.question ? "À TOI : " + String(r.question) : cleanResume(r.summary || r.text || "");
            return h("div", { class: "row-item", style: "padding:6px 4px;gap:var(--sp-2)" },
              h("div", { class: "grow", style: "min-width:0" },
                h("div", { style: ONE, title: q }, h("span", { class: "tt" }, String(r.name || r.dot_name || r.title || r.dot || "Éclat")), h("span", { class: "ss" }, " — " + q))),
              h("span", { class: "ss", style: "flex:none;white-space:nowrap" }, fmtAge(r.ts)),
              h("button", { class: "btn sm", onclick: async () => { try { await api.post("/api/dots/snooze", { run_id: r.run_id || r.id || "", minutes: 15 }); ctx.toast("Reporté de 15 minutes."); loadAll(); } catch (e) { ctx.toast("Report impossible.", true); } } }, "Plus tard"),
              h("button", { class: "btn sm acc", onclick: async () => { try { await api.post("/api/dots/ack", { run_id: r.run_id || r.id || "" }); ctx.toast("Vu et acquitté."); loadAll(); } catch (e) { ctx.toast("Accusé impossible.", true); } } }, "Vu"));
          })),
      ] : [h("div", { class: "ss", style: "color:var(--ink-2)" }, "Aucune décision en attente — les comptes rendus sont dans Exécutions, les « RAS » restent silencieux.")]));
    } catch (e) { if (!dead) waitBox.replaceChildren(errBox("File d'attente des exécutions illisible pour le moment.", loadAll)); }
    /* Packs installables. */
    try {
      const p = await api.get("/api/packs");
      if (dead) return;
      const packs = arrOf(p, "items", "packs");
      packBox.replaceChildren(
        ...(packs.length ? packs.map((pk) => {
          const ds = arrOf(pk, "dots");
          const installed = ds.filter((d) => d.installed).length;
          return h("div", { class: "card flat", style: "margin-bottom:12px" },
            h("div", { style: "display:flex;align-items:baseline;gap:10px" },
              h("div", { class: "tt" }, String(pk.name || pk.id || "Pack")),
              h("span", { class: "ss" }, installed + "/" + ds.length + " installé(s)"),
              h("span", { class: "sp", style: "flex:1" }),
              h("button", { class: "btn", disabled: installed === ds.length ? "disabled" : null,
                onclick: async (e) => { try { const r = await api.post("/api/packs/install", { id: pk.id }); ctx.toast("Pack installé" + (r && r.added && r.added.length ? " : " + r.added.length + " Éclat(s) ajoutés." : ".")); loadAll(); } catch (err) { ctx.toast("Installation impossible.", true); } } },
                installed === ds.length ? "Installé" : "Installer")),
            h("div", { class: "ss ss--wrap", style: "margin:4px 0 8px" }, String(pk.desc || "")),
            h("div", { style: "display:flex;gap:6px;flex-wrap:wrap" },
              ...ds.map((d) => h("span", { class: "chip", title: String(d.role || "") }, h("span", { class: "dotst " + (d.installed ? "ok" : "idle") }), h("span", { class: "dotst-lb" }, (d.installed ? "installé · " : "à installer · ") + String(d.name || d.id))))));
        }) : [h("div", { class: "empty" }, "Aucun pack proposé par le moteur.")]));
    } catch (e) { if (!dead) packBox.replaceChildren(errBox("Packs injoignables pour le moment.", loadAll)); }
  }

  /* Le bus fait passer les peluches du parc à l'instant du signal (même
     traduction que l'Accueil) ; le rechargement doux ne sert qu'aux données. */
  let reloadT = 0;
  on("nova:dot-run", (d) => {
    try {
      if (d && d.dot != null) {
        const rec = plushById.get(String(d.dot));
        if (rec) {
          if (d.phase === "working") rec.apply("actif");
          else if (d.phase === "ready") rec.apply(d.ok === false ? "erreur" : "attente");
          else if (d.phase === "idle") rec.apply(rec.base());
        }
      }
    } catch (e) {}
    clearTimeout(reloadT);
    reloadT = setTimeout(() => { if (!dead) loadAll(); }, 1500);
  });
  on("nova:eclat-run-focus", () => { if (!dead) loadAll(); });   // V5-T : module déjà monté — la clé nova2_pending_run est relue par loadAll
  loadAll();
  return () => { dead = true; clearTimeout(reloadT); clearPlushes(); offs.forEach((o) => { try { o(); } catch (e) {} }); cleanups.forEach((f) => { try { f(); } catch (e) {} }); };
}
