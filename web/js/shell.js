/* Nova 2 — coquille : rail unique, chargeur paresseux de modules, mini-lecteur persistant.
   Règles (architecture §4, RÉVISÉES le 20/10/2026 — ordres d'Ahadi : « la TV se coupe dès
   qu'on change d'écran », « conversations côte à côte », « le Direct et les Dots doivent
   venir à moi ») :
   - un module est importé à sa première ouverture, MONTÉ une fois dans la zone centrale,
     puis CACHE (display:none) à la navigation — jamais détruit : son état, son scroll et
     ses éléments média en cours de lecture SURVIVENT à l'aller-retour entre modules ;
   - EXCEPTIONS SÉCURITÉ/NATIF (ensemble NON_PERSIST ci-dessous) : les modules dont le
     démontage verrouille le coffre (vault, finance, systeme) ou ferme un volet WKWebView
     NATIF positionné par Swift (messages — un volet natif non fermé flotterait AU-DESSUS
     des autres modules : c'est une fuite inter-modules réelle) gardent l'ancien régime :
     démontés à la sortie, remontés à l'entrée ;
   - un module peut rendre un objet cycle de vie { destroy, onHide, onShow } au lieu de la
     fonction de démontage historique : onHide/onShow sont appelés à chaque bascule ;
   - le shell possède aussi : le mini-lecteur audio (inchangé), le LECTEUR FLOTTANT vidéo
     (#watchbox, section dédiée) et le service DIRECT GLOBAL (direct-global.js), exposés
     aux modules via ctx.watch et ctx.direct (+ window.NovaDirect.push pour les Dots). */
import { api, bus, esc, every, h, applyTheme, applyGlass, applyAppearance, applyReducedTransparency, bootTheme, reportError, softToast, showToast, sse, md, bindChatMessage, stampMsgTime, daySepEl, sameDay, prevStampedTs, traceMirror } from "./core.js";
import { ic } from "./icons.js";
import { ico3dImg } from "./icons3d.js";   /* 30/10 : icônes 3D Promesse (visibles seulement si html[data-identite]) */
import { createAttachments, describeForBrain } from "./attach.js";
import { createVoice } from "./voice.js";
import "./bg.js";
import { initPalette } from "./palette.js";
import { initUIBridge } from "./uibridge.js";
import { createDirectService } from "./direct-global.js";
import { createProChat } from "./prochat.js";
import { bootCompanion, presenceAnchor } from "./companion.js";   /* PV (23/10) : le panda compagnon — présence portable ancrée dans la coquille */
import { mountEclat } from "./eclat.js";
import { createWorkspace } from "./workspace.js";
import { initRailPeek } from "./peek.js";   /* V4-A : Live Peek Cards (survol de la barre) + aperçus du panneau libre */
import { startGlass } from "./glass.js";   /* 24/10 : moteur Liquid Glass (réfraction WebGL du fond Aurore) */   /* 24/10 : panneaux côte à côte + fenêtres flottantes */   /* LOT-13 : Éclat, la luciole de verre */

bootTheme();   // cache local immédiat ; le serveur confirme ensuite (source de vérité)

export const MODULES = [
  { id: "accueil", icon: "house", label: "Accueil", desc: "L'état du monde en un écran" },
  { id: "veille", icon: "brief", label: "Feeds", desc: "Activité des agents, signaux Sahel · WCA · ESA, BRVM et Fundings" },   /* V4 : « Veille » devient « Feeds » (id inchangé) */
  { id: "finance", icon: "chart", label: "Finance", desc: "Portefeuille, cours BRVM et coûts" },
  { id: "fundings", icon: "brief", label: "Fundings", desc: "Pipeline des candidatures startups : en attente, acquis, échéances" },   /* Lot C 27/10 */
  { id: "messages", icon: "inbox", label: "Messages", desc: "Messageries et brouillons à approuver" },
  { id: "taches", icon: "check", label: "Approbations", desc: "Tâches des agents en direct : étape, modèle, coût — Approuver, Modifier, Annuler" },   /* Phase 4 (31/10) */
  { id: "couts", icon: "chart", label: "Coûts", desc: "Mois contre le plafond de 125 $, par profil et modèle, réservations, économies, prix vérifiés" },   /* Phase 4 (31/10) */
  { id: "attente", icon: "check", label: "En attente", desc: "Centre de contrôle : tout ce qui attend ton GO (brouillons, préparations)" },   /* plan UI 27/10 */
  { id: "dots", icon: "agent", label: "Éclats", desc: "Tes agents permanents : horaires, décisions, exécutions, santé" },
  { id: "conversations", icon: "chat", label: "Conversations", desc: "L'agent en direct : étapes, outils, approbations", rail: false },
  /* FUSION DOTS (22/10) : l'entrée « Automatisations » du rail a disparu —
     l'écran a fusionné dans « Dots » (même objet, même moteur). Les
     navigations profondes vers « automatisations » sont redirigées par
     navigate() vers « dots » : aucun lien mort. */
  { id: "conseil", icon: "council", label: "Conseil", desc: "Le conseil des cerveaux, en direct" },
  { id: "livrables", icon: "file", label: "Livrables", desc: "Documents CAFU produits : PDF, Word, PowerPoint, Excel" },
  { id: "radio", icon: "radio", label: "Médias", desc: "Radios du monde, podcasts et TV" },
  { id: "studio", icon: "sparkle", label: "Studio Muse", desc: "Créer avec Meta : images Muse Image, segmentation SAM 3.1, voix temps réel" },   /* NOUVEAU 26/10 : capacités Meta hors chat */
  { id: "vie", icon: "kanban", label: "Projets", desc: "Projets et notes" },
  { id: "temps", icon: "calendar", label: "Agenda", desc: "Réunions, engagements, matin" },
  { id: "reunions", icon: "note", label: "Comptes rendus", desc: "Réunion : notes ou transcription → compte rendu → engagements" },   /* Lot H 28/10 */
  { id: "savoir", icon: "know", label: "Savoir", desc: "Index de tes dossiers et faits retenus — les documents d'identité sont dans Âme" },
  { id: "journal", icon: "journal", label: "Journal", desc: "La trace de Nova, ligne par ligne — lecture seule" },
  { id: "ame", icon: "avatar", label: "Âme", desc: "Identité, documents d'âme, miroir — ce que Nova garde et peut oublier" },
  { id: "relations", icon: "book", label: "Relations", desc: "Le gardien des relations : qui relancer, et quand" },
  { id: "engagements", icon: "check", label: "Engagements", desc: "Qui a promis quoi, à qui, pour quand — par personne et par dossier" },
  { id: "dossiers", icon: "file", label: "Dossiers", desc: "Suivi de dossiers : pièces à rassembler, échéances" },   /* Lot F 28/10 */
  { id: "confiance", icon: "shield", label: "Confiance", desc: "Ce que Nova fait seule, ce qu'elle demande, ce qu'elle ne fera jamais — et sa fiabilité prouvée" },
  { id: "controle", icon: "system", label: "Contrôle", desc: "Piloter le Mac : fenêtres, actions, délégations" },
  { id: "outils", icon: "zap", label: "Outils", desc: "Outils forgés par Nova et points de restauration de tes fichiers" },   /* V5-G */
  { id: "systeme", icon: "cpu", label: "Système", desc: "État du Mac, boîte noire, sauvegardes" },
  { id: "vault", icon: "lock", label: "Coffre", desc: "Documents et secrets chiffrés" },
  { id: "settings", icon: "gear", label: "Réglages", desc: "Paramètres — 4 écrans cherchables" },
];

const view = document.getElementById("view");
const rail = document.getElementById("rail");
let current = null;        // instance visible : { id, root, destroy, onHide, onShow, scrollTop }
let navToken = 0;

/* Modules NON persistants (détruits à la sortie, comme avant) — raisons :
   vault/finance/systeme : leur démontage appelle vaultLock() (verrouillage auto du
   coffre E3 en quittant l'écran — un module caché mais vivant garderait le coffre
   OUVERT en arrière-plan : régression de sécurité interdite) ;
   messages : ses volets WKWebView sont NATIFS (Swift les positionne au-dessus de la
   page) ; seul son démontage envoie « web.close » — caché sans fermeture, le volet
   resterait visible par-dessus la conversation (fuite constatée par Ahadi). */
/* 27/10 (Ahadi : « le travail en cours ne doit pas s'arrêter ») : seuls vault (verrouillage du
   coffre) et messages (volet WKWebView natif qui fuirait au-dessus des autres modules) restent
   démontés à la sortie. finance et systeme deviennent persistants comme les autres : un calcul
   ou un relevé en cours survit au changement d'onglet. */
const NON_PERSIST = new Set(["vault", "messages"]);
const MODULE_FILES = { accueil: "accueil", conversations: "agent", dots: "agents" };   // 24/10 : nouvel Accueil NDL (l'ancien bento modules/dots.js reste au dépôt)
const instances = new Map();   // id → instance montée (DOM conservé dans #view)

/* Service Direct global : sondage des sources + événements Dots + état « vu »
   partagé. Instancié UNE fois ici ; démarré dans boot(). */
const directService = createDirectService({ api, bus });

/* PROCHAT (21/10) : le fil direct sans clic — consommateur permanent du journal
   proactif du moteur ; il injecte les événements (mails, Teams, Dots, alertes)
   dans les fils de conversation enregistrés, sans aucun clic. Instancié UNE
   fois ici, comme le service Direct ; démarré dans boot(). */
const proChat = createProChat({ api, bus });
try {
  window.NovaProChat = {
    registerThread: (id, log, ask) => proChat.registerThread(id, log, ask),
    sync: () => proChat.sync(),
  };
} catch (e) {}
try {
  window.NovaDirect = {
    push: (d) => directService.push(d),
    list: () => directService.list(),
    seen: (key) => directService.markSeen(key),
    snooze: (key, min) => directService.snooze(key, min),
  };
} catch (e) {}

const ctx = {
  api, bus, esc, every, h, ic,
  direct: directService,
  watch: null,   // posé plus bas (lecteur flottant) : { attach(el, meta), release(reason), close(), active() }
  navigate: (id, force) => navigate(id, force),
  refresh: () => { if (current) navigate(current.id, true); },
  currentId: () => (current ? current.id : null),
  toast(msg, bad = false, ms = 4600, iconName) {
    return showToast(String(msg), { bad: !!bad, ms, icon: iconName || undefined });
  },
};

/* §36 (21/10, ordre d'Ahadi : « tout doit arriver en direct — le Dot amène
   son message ») : à chaque livraison d'un Dot ou du courrier, un toast
   coquille vient à lui SUR L'ÉCRAN OÙ IL EST (le #toasts est global). La
   carte Direct garde le détail et la lecture complète (bouton « Lire »). */
const court36 = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };
try {
  bus.on("nova:dot-run", (d) => {
    if (!d || typeof d !== "object") return;
    const name = String(d.dot_name || d.name || (d.dot && d.dot.name) || d.dot || "Éclat");
    try { const P = window.__novaPresence; if (P) { if (d.phase === "ready") P("done", "Éclat " + name + " terminé"); else if (d.phase === "waiting") P("ecoute", "Éclat " + name + " attend ta décision"); else P("reflexion", "Éclat " + name + " en cours…"); } } catch (e) {}
    if (d.phase === "ready") ctx.toast(name + " a terminé — " + court36(d.summary || d.result || "", 110), d.ok === false, 9000, "agent");
    else if (d.phase === "waiting") ctx.toast(name + " attend ta décision — " + court36(d.summary || "", 90), false, 9000, "agent");
  });
  bus.on("nova:mail-new", (d) => {
    if (!d || typeof d !== "object") return;
    const lines = Array.isArray(d.lines) ? d.lines : [];
    const BOXN = { ol: "Outlook", gm: "Gmail", tm: "Teams", wa: "WhatsApp", zm: "Zoho" };   // VEILLE-MAIL (24/10) : nom du service, plus l'identifiant brut « gm »
    const nm = BOXN[String(d.box || "")] || String(d.box || "Courrier");
    ctx.toast("📨 " + nm + " — " + (lines.length > 1 ? lines.length + " nouveaux" : "nouveau message") + (lines[0] ? " · " + court36(lines[0], 90) : ""), false, 15000, "mail");
  });
} catch (e) {}

/* ── FIX-DIRECT-WEB (22/10, correctif ⑤ du diagnostic Direct/Fil) ─────────
   Compteur de messages Direct non lus sur l'onglet « Conversations » du
   rail (setBadge existait, sans aucun appelant). L'état vit dans
   localStorage « nova2_direct_unread_v1 », PARTAGÉ avec le module Agent :
     · le shell (toujours vivant) compte les arrivées « direct.appended »
       quand l'utilisateur n'est PAS en train de lire le fil ;
     · le module Agent, quand il est monté, recalcule sur vérité moteur
       (messages du fil − acquittés) et acquitte à l'ouverture — il écrit le
       même état et émet « nova:direct-unread », que le shell suit ici.
   Un seul compteur, deux écrivains, l'état persisté fait foi. ──────────── */
const DIRECT_UNREAD_KEY = "nova2_direct_unread_v1";
const directStoreRead = () => { try { return JSON.parse(localStorage.getItem(DIRECT_UNREAD_KEY) || "{}") || {}; } catch (e) { return {}; } };
const directStoreWrite = (st) => { try { localStorage.setItem(DIRECT_UNREAD_KEY, JSON.stringify(st)); } catch (e) {} };
let shellActiveConvCid = "";        // conversation affichée dans le module Agent (signalée par « nova:conv-active »)
function paintDirectRailBadge() {
  const st = directStoreRead();
  /* 28/10 : le badge Conversations = directs non lus + tâches finies non vues. */
  let unseen = 0;
  try { unseen = Object.keys(JSON.parse(localStorage.getItem("nova2_unseen_done_v1") || "{}") || {}).length; } catch (e) {}
  setBadge("conversations", (st.cid ? (st.count || 0) : 0) + unseen);
}
try {
  bus.on("nova:conv-active", (d) => { shellActiveConvCid = (d && d.cid) ? String(d.cid) : ""; reportVisible(); });
  bus.on("nova:direct-unread", () => { paintDirectRailBadge(); });   // recalcul/acquittement du module Agent → le rail suit l'état partagé
  bus.on("nova:unseen-done", () => { paintDirectRailBadge(); });   // 28/10 : tâche finie ailleurs -> badge
  bus.on("direct.appended", (d) => {
    if (!d || !d.conv) return;
    traceMirror(d.feed, "RECU_SHELL", "", String(d.conv || ""), "");
    if (d.update) return;   // FIXES-MAIL (24/10) : carte enrichie EN PLACE — pas une arrivée de plus au compteur
    const cid = String(d.conv);
    const st = directStoreRead();
    const cidChanged = st.cid !== cid;
    if (cidChanged) { st.cid = cid; st.seen = 0; st.count = 0; st.seeded = false; }   // fil (re)créé : le module Agent amorcera « seen » à son prochain montage
    const reading = !!(current && current.id === "agent" && shellActiveConvCid === cid);
    if (!reading) {
      st.count = (st.count || 0) + 1;
      directStoreWrite(st);
      paintDirectRailBadge();
      bus.emit("nova:direct-unread", { cid, count: st.count });   // le module Agent repeint sa ligne s'il est monté (il resynchronise depuis l'état partagé)
    } else if (cidChanged) { directStoreWrite(st); paintDirectRailBadge(); }
  });
} catch (e) {}

/* ── 01/11 : notifications natives « une conversation t'attend » ─────────────
   Le moteur (NovaNotifier+Attention.swift) ne notifie pas ce qu'Ahadi a sous les yeux : l'interface lui signale
   l'écran et la conversation affichés (POST /api/notify/visible, regroupé à 250 ms). Un clic sur une
   notification ouvre l'écran (NovaNotify.openScript) puis émet « nova:notif-open » : pour une conversation,
   on attend que l'écran soit monté et on ouvre LE fil visé (même voie que le retour d'historique). */
let visModule = "", visTimer = 0;
function reportVisible() {
  clearTimeout(visTimer);
  visTimer = setTimeout(() => {
    try { const p = api.post("/api/notify/visible", { module: visModule || (current ? current.id : ""), cid: shellActiveConvCid || "" }); if (p && p.catch) p.catch(() => {}); } catch (e) {}
  }, 250);
}
try {
  bus.on("nova:module", (d) => { visModule = (d && d.id) ? String(d.id) : ""; reportVisible(); });
  bus.on("nova:notif-open", async (d) => {
    if (!d || !d.id || (d.module !== "conversations" && d.module !== "agent")) return;
    const cid = String(d.id).replace(/^confirm:/, "");
    try { await navigate("conversations"); } catch (e) {}
    bus.emit("nova:nav-open-conv", { cid });
  });
} catch (e) {}

/* ── Rail ──────────────────────────────────────────────────────────────── */
const railBtns = new Map();
function buildRail() {
  /* §50 LE PANDA EN TOUT PREMIER, RÉPLIQUE DE MUSE (ordre d'Ahadi, 21/10
     11:59 : « la réplique exacte des tiens » — emplacement, taille,
     comportements). §48 le mettait sous le logo à 76 px : dans un rail
     d'icônes de ~76 px de large, il était ROGNÉ par le overflow:hidden.
     Désormais : la présence est le PREMIER élément du rail (le logo-orbe
     disparaît, le panda EST l'identité), à 104 px — le rail s'élargit pour
     elle en tête, comme l'avatar de Muse en haut de sa barre latérale.
     Comportements = ceux du moteur panda3d, branchés sur la vie de l'app :
     idle (respiration, clignements, salut automatique ~20 s, regard qui
     suit le curseur), thinking (main au menton), tool, listening (un Dot
     attend sa décision), speaking (bouche sur le niveau audio réel),
     error (secoue la tête) ; salut DÉCLENCHÉ à l'ouverture de l'app et à
     chaque travail terminé (le geste natif du panda : pointerdown sur sa
     couche 3D, panda3d.js:174). Une seule présence (discipline avatar.js). */
  try {
    /* 24/10 — PANDA VIVANT v2 : le rail ne monte plus son propre moteur 3D ; il RÉSERVE
       la place (ancre) et l'unique compagnon s'y pose. Même pilotage qu'avant (av.setState…). */
    try { bootCompanion(ctx); } catch (e) {}
    const pres = h("div", { class: "rail-presence", title: "Nova — présence et activité en direct" });
    const av = presenceAnchor(ctx, { slot: "rail", px: 44 });
    const lab = h("div", { class: "rp-label" }, "Au repos");
    pres.append(av, h("div", { class: "rp-txt" }, h("div", { class: "rp-name" }, "Nova"), lab)); rail.append(pres);
    /* C5 (23/10) : le salut d'ouverture passe par l'état partagé « done »
       (pose bras ouverts du moteur, retour automatique à « repos » dans
       avatar.js). L'ancien déclencheur — un pointerdown synthétique sur la
       couche 3D — ne produit plus qu'un clignement depuis LOT-12 (le salut
       par pointerdown a été retiré du moteur) : il ne saluait plus rien, ce
       qui explique le « zéro salut » de la batterie du 23/10.
       LOT WEB v3 / W-13 : le salut est déclenché par « moteur prêt »
       (événement nova:avatar-ready émis par avatar.js au montage réel),
       plus par une horloge aveugle. Le minuteur ne reste qu'en repli
       tardif, si le moteur était déjà monté avant cet écouteur. */
    const greet = () => { try { if (av.setState) av.setState("done"); } catch (e) {} };
    try { window.__novaCompanion.addEventListener("nova:avatar-ready", greet, { once: true }); } catch (e) {}
    setTimeout(() => { try { if (document.querySelector(".pv-companion .avatar-3d.on")) greet(); } catch (e) {} }, 3400);
    let idleT = 0, doneT = 0;
    window.__novaPresence = (state, label) => {
      try {
        clearTimeout(doneT);
        if (state === "tool") { if (av.noteTool) av.noteTool(); }
        else if (state === "error") { if (av.noteError) av.noteError(); }
        else if (state === "done") {
          /* C5 (23/10) : « done » REJOINT la présence. Avant, il était
             intercepté ici en « repos » + pointerdown : l'état E7 du moteur
             (bras ouverts + salut bref si travail > 10 s) n'était JAMAIS
             atteint, et le réglage « Saluts du panda » — lu par le moteur
             au seul setState("done") — ne pilotait donc rien d'observable.
             La présence partagée repasse seule à « repos » après la pose. */
          if (av.setState) av.setState("done");
          lab.textContent = String(label || "Terminé").replace(/^Nova · /, "").replace(/\*\*|__|`/g, ""); lab.title = lab.textContent;   // V6 : libellé tronqué proprement → texte complet en infobulle
          clearTimeout(idleT);
          doneT = setTimeout(() => { try { lab.textContent = "Au repos"; lab.title = ""; } catch (e) {} }, 6000);
          return;
        }
        else if (av.setState) av.setState(state);
        if (label != null) { const L = String(label).replace(/^Nova · /, "").replace(/\*\*|__|`/g, "");   /* 29/10 : pas de markdown brut */ lab.textContent = L; lab.title = L; }
        clearTimeout(idleT);
        if (state !== "repos") idleT = setTimeout(() => { try { lab.textContent = "Au repos"; lab.title = ""; if (av.setState) av.setState("repos"); } catch (e) {} }, 60000);
      } catch (e) {}
    };
  } catch (e) {}
  /* PV (23/10) : le compagnon vivant — monté dans la coquille, HORS des
     modules d'écran : il suit Ahadi partout, s'ancre selon l'écran et la
     géométrie de la fenêtre, célèbre les tâches et porte l'humeur.
     Échec borné et silencieux : le rail reste la présence de repli. */
  try { bootCompanion(ctx); } catch (e) {}
  /* ── NDL (24/10) : barre latérale de verre, sections nommées, pied ─────────── */
  const byId = (gid) => MODULES.find((m) => m.id === gid);
  /* Précédent / Suivant (historique de vues) — toujours visibles en tête du rail. */
  const navRow = h("div", { class: "sb-navrow" });
  navBackBtn = h("button", { class: "sb-navbtn", title: "Précédent (⌘[) — clic droit : historique", "aria-label": "Précédent", onclick: () => navGo(-1),
    oncontextmenu: (e) => { e.preventDefault(); showNavHistory(navBackBtn, -1); } });
  navBackBtn.innerHTML = '<span class="sb-navflip">' + ic("chev-r", 15) + "</span>";
  navFwdBtn = h("button", { class: "sb-navbtn", title: "Suivant (⌘]) — clic droit : historique", "aria-label": "Suivant", onclick: () => navGo(1),
    oncontextmenu: (e) => { e.preventDefault(); showNavHistory(navFwdBtn, 1); } });
  navFwdBtn.innerHTML = ic("chev-r", 15);
  /* Appui long (28/10) : maintenir Précédent/Suivant ouvre l'historique, comme un
     navigateur — le clic droit seul était introuvable au trackpad. Le clic qui suit
     un appui long est absorbé pour ne pas naviguer en plus. */
  for (const [btn, dir] of [[navBackBtn, -1], [navFwdBtn, 1]]) {
    let lpTimer = 0, lpDone = false;
    btn.addEventListener("pointerdown", () => {
      lpDone = false;
      clearTimeout(lpTimer);
      lpTimer = setTimeout(() => { lpDone = true; showNavHistory(btn, dir); }, 450);
    });
    for (const ev of ["pointerup", "pointerleave", "pointercancel"]) btn.addEventListener(ev, () => clearTimeout(lpTimer));
    btn.addEventListener("click", (e) => { if (lpDone) { e.preventDefault(); e.stopImmediatePropagation(); lpDone = false; } }, true);
  }
  navBackBtn.title = "Précédent (⌘[) — maintenir ou clic droit : historique";
  navFwdBtn.title = "Suivant (⌘]) — maintenir ou clic droit : historique";
  const focusBtn = h("button", { class: "sb-navbtn", title: "Mode focus (⌘.) — un écran, zéro rail", "aria-label": "Mode focus", onclick: () => toggleFocus() });
  focusBtn.innerHTML = ic("maximize", 15);
  navRow.append(navBackBtn, navFwdBtn, focusBtn);
  rail.append(navRow);
  navPaint();
  /* Préréglages d'espace (plan UI 27/10) : un clic pose les deux panneaux
     utiles côte à côte — les presets sont mémorisés implicitement par la
     persistance du workspace (le dernier agencement est restauré). */
  const presets = h("div", { class: "sb-presets", role: "group", "aria-label": "Espaces préréglés" },
    ...[["Matin", "accueil", "temps"], ["Réunion", "temps", "conversations"], ["Veille", "veille", "messages"]].map(([label, a, b]) =>
      h("button", { type: "button", class: "sb-preset", title: label + " : " + a + " + " + b + " côte à côte",
        onclick: async () => { try { if (workspace) workspace.setLayout(2); await navigate(a); openBeside(b); } catch (e) {} } }, label)));
  rail.append(presets);
  const search = h("button", { class: "sb-search", onclick: () => bus.emit("nova:palette") });
  search.innerHTML = ic("search", 16) + '<span>Rechercher</span><kbd>⌘K</kbd>';
  rail.append(search);
  const zone = h("div", { class: "rail-mods" });
  const GROUPS = [
    ["", ["accueil", "conversations", "taches", "attente"]],   /* Phase 4 : Approbations */
    ["Flux", ["messages", "veille", "temps", "reunions", "engagements", "dossiers", "relations"]],
    ["Agents", ["dots", "conseil", "livrables", "studio"]]   /* NOUVEAU 26/10 : Studio Muse dans le rail (groupe Agents) */,
    ["Moi", ["finance", "couts", "fundings", "vie", "savoir", "journal", "ame"]],
    ["Mac", ["controle", "confiance", "outils", "systeme", "radio"]],
  ];
  let collapsed = {};
  try { collapsed = JSON.parse(localStorage.getItem("nova2_sb_groups") || "{}") || {}; } catch (e) {}
  for (const [name, ids] of GROUPS) {
    const list = h("div", { class: "sb-group-list" });
    for (const gid of ids) {
      if (gid === "conversations") { if (byId(gid)) list.append(convRailBtn()); continue; }
      const m = byId(gid); if (!m || m.rail === false) continue;
      list.append(railBtn(m));
    }
    if (!list.childElementCount) continue;
    const grp = h("div", { class: "sb-group" + (collapsed[name] ? " is-collapsed" : "") });
    if (name) {
      const head = h("button", { class: "sb-ghead", "aria-expanded": collapsed[name] ? "false" : "true", title: (collapsed[name] ? "Déplier « " : "Replier « ") + name + " »" }, h("span", {}, name), h("span", { class: "sb-chev", html: ic("chev-d", 12) }));
      head.addEventListener("click", () => {
        grp.classList.toggle("is-collapsed"); collapsed[name] = grp.classList.contains("is-collapsed");
        head.setAttribute("aria-expanded", collapsed[name] ? "false" : "true");
        head.title = (collapsed[name] ? "Déplier « " : "Replier « ") + name + " »";
        try { localStorage.setItem("nova2_sb_groups", JSON.stringify(collapsed)); } catch (e) {}
        railFades();
      });
      grp.append(head);
    }
    grp.append(list); zone.append(grp);
  }
  rail.append(zone);
  /* V6 (25/10) : la liste DÉFILE entre l'en-tête et le pied fixes (Système / Médias
     inaccessibles sur un écran de 896 px). Fondus haut/bas seulement s'il reste du
     contenu de ce côté — plus de masque permanent qui effaçait le dernier élément. */
  railZone = zone;
  zone.addEventListener("scroll", railFades, { passive: true });
  try { new ResizeObserver(railFades).observe(zone); } catch (e) {}
  window.addEventListener("resize", railFades, { passive: true });
  try { rail.append(createHalo()); } catch (e) { reportError(e, "halo", true); }   /* VAGUE 1 (24/10) : Halo d'activité, au pied de la barre */
  const foot = h("div", { class: "sb-foot" });
  for (const gid of ["settings", "vault"]) { const m = byId(gid); if (m) foot.append(railBtn(m)); }
  const tog = h("button", { class: "rail-btn sb-toggle", title: "Réduire / déployer la barre (⌘0)", "aria-label": "Réduire la barre latérale", onclick: () => toggleSidebar() });
  tog.innerHTML = ic("sidebar", 18);
  foot.append(tog);
  rail.append(foot);
  try { initRailPeek({ rail, modules: MODULES }); } catch (e) { reportError(e, "peek", true); }
  /* Zone de déplacement de la fenêtre (barre de titre transparente) */
  const drag = h("div", { class: "win-drag", "aria-hidden": "true" });
  document.body.append(drag);
  const nat = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nova;
  drag.addEventListener("pointerdown", (e) => {
    const n = nat(); if (!n) return;
    if (e.detail === 2) { n.postMessage({ cmd: "winZoom" }); return; }
    n.postMessage({ cmd: "winDragStart" }); drag.setPointerCapture(e.pointerId);
    const mv = () => n.postMessage({ cmd: "winDrag" });
    drag.addEventListener("pointermove", mv);
    drag.addEventListener("pointerup", () => drag.removeEventListener("pointermove", mv), { once: true });
  });
}
/* LE VIDE (R-127, U4) : un voile calme sur toute l'app ; seul le compagnon reste, endormi. Échap pour revenir. */
let videEl = null;
function toggleVide(force) {
  const on = force != null ? !!force : !document.documentElement.hasAttribute("data-vide");
  if (on) {
    if (!videEl) {
      videEl = h("div", { class: "vide", role: "dialog", "aria-label": "Le Vide" },
        presenceAnchor(ctx, { slot: "vide", px: 260 }),
        h("div", { class: "vide-t" }, "Le Vide"),
        h("div", { class: "vide-s" }, "Respire. Tout est en pause visuelle — les Éclats continuent en silence. Échap pour revenir."));
      videEl.addEventListener("click", (e) => { if (e.target === videEl) toggleVide(false); });
      document.body.append(videEl);
    }
    document.documentElement.setAttribute("data-vide", "");
  } else {
    document.documentElement.removeAttribute("data-vide");
    if (videEl) { const a = videEl.querySelector(".pv-anchor"); if (a && a.destroyAvatar) a.destroyAvatar(); videEl.remove(); videEl = null; }
  }
  bus.emit("nova:vide", { on });
}
try { bus.on("nova:vide-toggle", () => toggleVide()); } catch (e) {}
function toggleSidebar() {
  const sh = document.querySelector(".shell");
  const on = !sh.classList.contains("sb-mini");
  sh.classList.toggle("sb-mini", on);
  try { localStorage.setItem("nova2_rail", on ? "mini" : "ext"); } catch (e) {}
  setTimeout(() => window.dispatchEvent(new Event("resize")), 300);
}
/* Mode focus (plan UI 27/10, ⌘.) : le rail disparaît, l'écran courant prend
   toute la largeur — pour rédiger et relire. Échap ou ⌘. pour revenir. */
let focusChip = null;
function toggleFocus(force) {
  const sh = document.querySelector(".shell"); if (!sh) return;
  const on = force != null ? !!force : !sh.classList.contains("nova-focus");
  sh.classList.toggle("nova-focus", on);
  /* Plein écran réel (retoqué 27/10 — première version « trop coincée ») : le
     panneau focalisé prend toute la grille, les autres panneaux et les
     séparateurs sont masqués sans toucher à l'agencement persisté ; à la
     sortie, les colonnes d'origine sont restaurées à l'identique. */
  try {
    const ws = document.querySelector(".ws");
    if (ws && on) {
      if (ws.dataset.prevCols == null) ws.dataset.prevCols = ws.style.gridTemplateColumns || "";
      ws.style.gridTemplateColumns = "minmax(0, 1fr)";
      ws.querySelectorAll(".pane:not(.on), .ws-split").forEach((el) => el.classList.add("nova-focus-hide"));
    } else if (ws && !on) {
      ws.style.gridTemplateColumns = ws.dataset.prevCols || "";
      delete ws.dataset.prevCols;
      ws.querySelectorAll(".nova-focus-hide").forEach((el) => el.classList.remove("nova-focus-hide"));
    }
  } catch (e) {}
  if (on && !focusChip) {
    focusChip = h("button", { type: "button", class: "nova-focus-chip", title: "Quitter le mode focus (⌘. ou Échap)", onclick: () => toggleFocus(false) }, "Quitter le focus ✕");
    document.body.append(focusChip);
  }
  if (!on && focusChip) { focusChip.remove(); focusChip = null; }
  setTimeout(() => window.dispatchEvent(new Event("resize")), 300);
}
/* Historique au clic droit sur Précédent/Suivant (plan UI 27/10), comme un
   navigateur : la pile des vues, saut direct à n'importe laquelle. */
let navHistMenu = null;
function showNavHistory(anchor, dir) {
  if (navHistMenu) { navHistMenu.remove(); navHistMenu = null; }
  const ids = dir < 0 ? navHist.stack.slice(0, navHist.idx).map((e, i) => [e, i]).reverse()
                      : navHist.stack.slice(navHist.idx + 1).map((e, i) => [e, navHist.idx + 1 + i]);
  if (!ids.length) return;
  const labelOf = (id) => (MODULES.find((m) => m.id === id) || {}).label || id;
  navHistMenu = h("div", { class: "nav-hist-menu", role: "menu" },
    ...ids.slice(0, 12).map(([e, idx]) => h("button", { type: "button", class: "nav-hist-i", role: "menuitem",
      onclick: () => { const delta = idx - navHist.idx; navHistMenu.remove(); navHistMenu = null; if (delta) navGo(delta); } },
      labelOf(e.id) + (e.cid ? " · conversation" : ""))));
  document.body.append(navHistMenu);
  const r = anchor.getBoundingClientRect();
  navHistMenu.style.left = Math.max(8, r.left) + "px";
  navHistMenu.style.top = (r.bottom + 6) + "px";
  const close = (ev) => { if (navHistMenu && !navHistMenu.contains(ev.target)) { navHistMenu.remove(); navHistMenu = null; document.removeEventListener("pointerdown", close, true); } };
  setTimeout(() => document.addEventListener("pointerdown", close, true), 0);
}
/* 24/10 — gestes de page sur chaque entrée de la barre : glisser vers un panneau,
   clic droit → menu (ici · à côté · fenêtre flottante). */
function wirePageGestures(b, id) {
  b.draggable = true;
  b.addEventListener("dragstart", (e) => { try { e.dataTransfer.setData("text/nova-module", id); e.dataTransfer.effectAllowed = "move"; } catch (err) {} document.body.classList.add("ws-dragging"); });
  b.addEventListener("dragend", (e) => {
    document.body.classList.remove("ws-dragging");
    try { if (e.dataTransfer && e.dataTransfer.dropEffect === "none" && e.clientX > 240) openFloating(id); } catch (err) {}   // lâchée hors panneau → fenêtre flottante
  });
  b.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    document.querySelectorAll(".ws-menu").forEach((n) => n.remove());
    const item = (icon, label, fn) => { const x = h("button", { class: "ctx-item" }); x.innerHTML = ic(icon, 15) + "<span>" + esc(label) + "</span>"; x.addEventListener("click", () => { menu.remove(); fn(); }); return x; };
    const menu = h("div", { class: "ctxmenu ws-menu", role: "menu" },
      item("chev-r", "Ouvrir ici", () => (id === "conversations" ? gotoConversations() : navigate(id))),
      item("layers", "Ouvrir à côté", () => openBeside(id)),
      item("external", "Ouvrir en fenêtre flottante", () => openFloating(id)));
    menu.style.left = e.clientX + 4 + "px"; menu.style.top = e.clientY + 4 + "px";
    document.body.append(menu);
    setTimeout(() => document.addEventListener("pointerdown", (ev) => { if (!menu.contains(ev.target)) menu.remove(); }, { once: true }), 0);
  });
}
let railZone = null;
function railFades() {
  const z = railZone; if (!z) return;
  const up = z.scrollTop > 2, down = z.scrollTop + z.clientHeight < z.scrollHeight - 2;
  if (z.classList.contains("can-up") !== up) z.classList.toggle("can-up", up);
  if (z.classList.contains("can-down") !== down) z.classList.toggle("can-down", down);
}
/* V6 : l'entrée active est toujours visible dans la liste (défilement interne seulement). */
function revealRailBtn(b) {
  const z = railZone; if (!z || !b || !z.contains(b) || !b.offsetParent) return;
  const zr = z.getBoundingClientRect(), br = b.getBoundingClientRect();
  if (br.top < zr.top + 4) z.scrollTop -= (zr.top + 4 - br.top);
  else if (br.bottom > zr.bottom - 10) z.scrollTop += (br.bottom - zr.bottom + 10);
  railFades();
}
function railBtn(m) {
  const b = h("button", {
    class: "rail-btn", title: m.label + " — ⌥-clic : ouvrir à côté · clic droit : options", "data-tip": m.label, "aria-label": m.label, "data-page": m.id,
    onclick: (e) => { if (e.altKey) openBeside(m.id); else navigate(m.id); },
  });
  wirePageGestures(b, m.id);
  const i3 = ico3dImg(m.id), k3 = i3 ? " ri3d" : "";
  b.innerHTML = '<span class="ri ri-off' + k3 + '">' + ic(m.icon, 18) + i3 + '</span><span class="ri ri-on' + k3 + '">' + ic(m.icon, 18, { fill: true }) + i3 + '</span><span class="rail-lb">' + esc(m.label) + "</span>";
  railBtns.set(m.id, b);
  return b;
}
export function setBadge(id, n) {
  const b = railBtns.get(id); if (!b) return;
  let el = b.querySelector(".bdg");
  if (!n) { if (el) el.remove(); return; }
  if (!el) { el = h("span", { class: "bdg" }); b.append(el); }
  el.textContent = n > 99 ? "99+" : String(n);
  el.title = n + (n > 1 ? " non lus" : " non lu");
  railFades();
}

/* ── Conversations : ONGLET du rail, sous Accueil (ordre d'Ahadi, 21/10/2026
   ~08:58, qui REMPLACE le panneau tiroir du matin) : « place l'onglet
   conversation en dessous de l'onglet accueil, et conversation se déploie
   ensuite vers la droite avec ses sous-éléments, comme le tien ».
   Donc : aucun overlay, rien ne cache les onglets principaux. L'onglet
   Conversations mène à l'espace de conversation (module Agent, qui n'a plus
   son propre onglet — fini le doublon Agent/Agents) et la liste des
   conversations s'y déploie EN COLONNE, à droite du rail : préférence
   « nova2_agent_side » forcée visible + signal bus si le module est monté. ── */
function convRailBtn() {
  const b = h("button", {
    class: "rail-btn rail-conv-btn", title: "Conversations — tes échanges avec l'agent, liste déployée à droite du rail",
    "data-tip": "Conversations", "aria-label": "Conversations", "data-page": "conversations", onclick: (e) => { if (e.altKey) openBeside("conversations"); else gotoConversations(); },
  });
  wirePageGestures(b, "conversations");
  const i3 = ico3dImg("conversations");
  b.innerHTML = '<span class="ri ri-off ri3d">' + ic("chat", 18) + i3 + '</span><span class="ri ri-on ri3d">' + ic("chat", 18, { fill: true }) + i3 + '</span><span class="rail-lb">Conversations</span>';
  railBtns.set("conversations", b);
  return b;
}
function gotoConversations() {
  try { localStorage.setItem("nova2_agent_side", "1"); } catch (e) {}
  navigate("conversations");
  bus.emit("nova:show-conv-side", {});
  /* 27/10 (reproduit à l'écran) : le rail sélectionnait Conversations mais la vue
     restait sur l'écran précédent — le module était garé dans un emplacement
     invisible (stash/panneau hors champ) et la navigation le « focalisait » sans
     l'afficher. Contrôle après coup : si la racine du module n'est pas réellement
     visible, on repasse en 1 panneau et on rouvre pour de vrai. */
  setTimeout(() => {
    try {
      const inst = instances.get("conversations");
      const r = inst && inst.root && inst.root.getBoundingClientRect();
      const vis = !!r && r.width >= 200 && r.height >= 200;
      if (!vis) {
        if (workspace) workspace.setLayout(1);
        navigate("conversations");
        bus.emit("nova:show-conv-side", {});
      }
    } catch (e) {}
  }, 900);
}

/* ── Navigation paresseuse PERSISTANTE ───────────────────────────────────
   Point de destruction HISTORIQUE (avant ce correctif) : navigate() appelait
   current.unmount() puis view.replaceChildren(root) — le DOM du module sortant
   était détruit, donc l'élément <video> de Médias mourait (TV coupée), les fils
   SSE se fermaient et les vues en direct se détachaient. Le correctif : les
   racines vivent toutes dans #view, une seule est visible ; quitter un module
   le cache (display:none + visibility:hidden, double verrou anti-fuite : aucun
   pixel d'un autre module ne peut apparaître dans la vue courante), jamais ne
   le démonte — sauf NON_PERSIST et rafraîchissement forcé (ctx.refresh). */
function skeleton(slot) {
  const sk = h("div", { class: "mod", "data-boot-skel": "1" },   // marque du boot : le chien de garde ne rafraîchit que cette surface, jamais un module en montage
    h("div", { class: "skel", style: "height:34px;width:260px;margin-bottom:18px" }),
    h("div", { class: "bento" },
      h("div", { class: "skel t-hero", style: "min-height:300px" }),
      h("div", { class: "skel t-fin" }), h("div", { class: "skel t-briefs" }),
      h("div", { class: "skel t-msg" }), h("div", { class: "skel t-audio" }), h("div", { class: "skel t-vault" })));
  (slot || view).append(sk);
  return sk;
}
function cleanupBootNotes(except) {
  view.querySelectorAll("[data-boot-skel], .boot-note, .boot-skel").forEach((n) => { if (n !== except) n.remove(); });
}
function hideInstance(inst) {
  if (!inst) return;
  try { inst.scrollTop = inst.root.scrollTop; } catch (e) {}
  inst.root.style.display = "none";
  inst.root.style.visibility = "hidden";
  inst.root.setAttribute("aria-hidden", "true");
  try { if (workspace && inst.root.isConnected) workspace.stash.append(inst.root); } catch (e) {}   // 24/10 : la page retourne au dépôt (ré-accrochée intacte à la prochaine ouverture)
  if (inst.onHide) { try { inst.onHide(); } catch (e) { reportError(e, "onHide " + inst.id, true); } }
}
function showInstance(inst, fresh) {
  inst.root.style.display = "";
  inst.root.style.visibility = "";
  inst.root.removeAttribute("aria-hidden");
  /* Correctif « en-têtes coupés » (audit écrans 20/10) PRÉSERVÉ, sans démontage :
     premier montage → haut ; data-reset-scroll="1" → haut à chaque retour ; sinon
     restauration du scroll exact (persistance). */
  const root = inst.root;
  const toTop = () => { try { root.scrollTop = 0; } catch (e) {} };
  if (fresh || root.dataset.resetScroll === "1") { requestAnimationFrame(toTop); setTimeout(toTop, 350); }
  else { const y = inst.scrollTop || 0; requestAnimationFrame(() => { try { root.scrollTop = y; } catch (e) {} }); }
  if (inst.onShow) { try { inst.onShow(); } catch (e) { reportError(e, "onShow " + inst.id, true); } }
  try { if (window.NovaMotion) window.NovaMotion.shown(root, inst.id); } catch (e) {}   /* 30/10 mouvement : bord de défilement + fil (motion.js) */
}
function destroyInstance(inst) {
  if (!inst) return;
  instances.delete(inst.id);
  if (current === inst) current = null;
  if (inst.destroy) { try { inst.destroy(); } catch (e) { reportError(e, "destroy " + inst.id, true); } }
  try { inst.root.remove(); } catch (e) {}
}
const NAV_REDIRECT = { agent: "conversations", agents: "dots", automatisations: "dots" };
function setFocusedCurrent(id) {
  const inst = instances.get(id);
  if (inst) current = inst;
  try { window.__novaModule = id; } catch (e) {}
  for (const [mid, b] of railBtns) { const on = mid === id; b.classList.toggle("on", on); if (on) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current"); }
  try { revealRailBtn(railBtns.get(id)); } catch (e) {}
  try { const fab = document.querySelector(".dock-fab"); if (fab) fab.hidden = (id === "accueil"); } catch (e) {}
}
/* 24/10 — ESPACE DE TRAVAIL : navigate() ouvre la page dans le PANNEAU ACTIF (ou donne le
   focus au panneau / à la fenêtre qui l'affiche déjà). Le montage réel est fait par
   openInSlot(), appelé par workspace.js pour l'emplacement choisi. */
export async function navigate(id, force = false) {
  if (NAV_REDIRECT[id]) id = NAV_REDIRECT[id];
  if (!MODULES.some((m) => m.id === id)) { reportError(new Error("Module inconnu : " + id), "navigate"); return; }
  try { api.get("/api/vault/status").then((j) => { try { vaultOpenCache = !!(j && (j.locked === false || j.unlocked === true || j.state === "open")); } catch (e) {} }).catch(() => {}); } catch (e) {}
  try { localStorage.setItem("nova2_last_module", id); } catch (e) {}
  if (force) {
    const old = instances.get(id);
    const slot = old && old.root.parentElement;
    if (old) destroyInstance(old);
    if (slot && slot.classList.contains("pane-body")) { await openInSlot(id, slot); bus.emit("nova:module", { id }); return; }
  }
  if (!workspace) return;
  /* 30/10 (mouvement) : transition de page — motion.js capture le panneau actif, sortante/entrante
     chorégraphiées, annulée par la navigation suivante ; sans NovaMotion, comportement inchangé. */
  const __mo = window.NovaMotion, __from = current ? current.id : "";
  if (__mo && __mo.page && __from !== id) await __mo.page(() => workspace.show(id), { from: __from, to: id });
  else await workspace.show(id);
  setFocusedCurrent(id);
  navPush({ id });
  bus.emit("nova:module", { id });
}
export function openBeside(id, opts) { if (NAV_REDIRECT[id]) id = NAV_REDIRECT[id]; if (workspace) workspace.openBeside(id, opts || {}); }   /* opts.target : élément à surligner à l'arrivée (V4-A) */

/* ── 27/10 (Ahadi) — HISTORIQUE DE NAVIGATION : Précédent / Suivant comme un navigateur.
   Pile de vues { id, cid? } : navigate() y pousse chaque écran, le module Conversations y
   pousse chaque conversation ouverte (window.NovaNav.push). Revenir ne détruit rien :
   on ré-affiche l'instance conservée, flux en cours compris. ── */
const navHist = { stack: [], idx: -1, restoring: false };
const navKey = (e) => e.id + "|" + (e.cid || "");
let navBackBtn = null, navFwdBtn = null;
function navPaint() {
  if (navBackBtn) navBackBtn.disabled = navHist.idx <= 0;
  if (navFwdBtn) navFwdBtn.disabled = navHist.idx >= navHist.stack.length - 1;
}
function navPush(entry) {
  if (!entry || !entry.id || navHist.restoring) return;
  const e = { id: entry.id, cid: entry.cid ? String(entry.cid) : "" };
  const cur = navHist.stack[navHist.idx];
  if (cur && navKey(cur) === navKey(e)) return;
  navHist.stack.splice(navHist.idx + 1);
  navHist.stack.push(e);
  if (navHist.stack.length > 80) navHist.stack.shift();
  navHist.idx = navHist.stack.length - 1;
  navPaint();
}
async function navGo(delta) {
  const t = navHist.stack[navHist.idx + delta];
  if (!t) return;
  navHist.idx += delta;
  navHist.restoring = true;
  try {
    await navigate(t.id);
    if (t.cid) bus.emit("nova:nav-open-conv", { cid: t.cid });
  } finally { navHist.restoring = false; navPaint(); }
}
try {
  window.NovaNav = {
    push: (entry) => navPush(entry),
    back: () => navGo(-1),
    forward: () => navGo(1),
  };
  window.addEventListener("keydown", (e) => {
    if (!e.metaKey && !e.altKey) return;
    if (e.key === "[") { e.preventDefault(); navGo(-1); }
    else if (e.key === "]") { e.preventDefault(); navGo(1); }
    else if (e.altKey && e.key === "ArrowLeft") { e.preventDefault(); navGo(-1); }
    else if (e.altKey && e.key === "ArrowRight") { e.preventDefault(); navGo(1); }
  });
} catch (e) {}
export function openFloating(id) { if (NAV_REDIRECT[id]) id = NAV_REDIRECT[id]; if (workspace) workspace.openFloating(id); }
function releaseModule(id) { const inst = instances.get(id); if (inst) hideInstance(inst); }
async function openInSlot(id, slot) {
  const token = ++navToken;
  slot.querySelectorAll(".pane-empty").forEach((n) => n.remove());
  const cached = instances.get(id);
  if (cached) { slot.append(cached.root); cleanupBootNotes(cached.root); showInstance(cached, false); return; }
  const sk = skeleton(slot);
  let mod;
  try { mod = await import("./modules/" + (MODULE_FILES[id] || id) + ".js"); }
  catch (e) {
    sk.remove();
    reportError(e, "import " + id);
    const root = h("div", { class: "mod" },
      h("div", { class: "errbox" }, h("b", {}, "Module « " + id + " » illisible. "), "Le fichier du module n'a pas pu être chargé.",
        h("div", { style: "margin-top:10px" }, h("button", { class: "btn", onclick: () => navigate(id, true) }, "Réessayer"))));
    slot.append(root);
    instances.set(id, { id, root, destroy: null, onHide: null, onShow: null, scrollTop: 0 });
    return;
  }
  void token;
  sk.remove();
  const root = h("div", { class: "mod", "data-mod": id });
  slot.append(root);
  try { if (window.NovaMotion) window.NovaMotion.mounting(root, id); } catch (e) {}   /* 30/10 mouvement : révélation au PREMIER montage seulement */
  const ac = new AbortController();
  const __fpT0 = performance.now();   /* first_paint : durée de montage mesurée, pas l'âge de la page */
  try {
    const ret = await mod.mount(root, { ...ctx, signal: ac.signal });
    /* Contrat de cycle de vie : fonction historique (= destroy) OU objet { destroy, onHide, onShow }. */
    const inst = { id, root, scrollTop: 0, destroy: null, onHide: null, onShow: null };
    inst.destroy = () => { ac.abort(); if (typeof ret === "function") ret(); else if (ret && typeof ret.destroy === "function") ret.destroy(); };
    if (ret && typeof ret === "object") { inst.onHide = ret.onHide || null; inst.onShow = ret.onShow || null; }
    if (NON_PERSIST.has(id)) inst.onHide = () => destroyInstance(inst);
    instances.set(id, inst);
    cleanupBootNotes(root);
    showInstance(inst, true);
    window.__novaBooted = true;
    /* 29/10 : témoin de démarrage — après chaque mise à jour, le moteur sait que l'interface a VRAIMENT démarré. */
    try { if (!window.__novaBootSent) { window.__novaBootSent = true; api.post("/api/ui/booted", { at: Date.now() }).catch(() => {}); } } catch (e) {}
    if (!window.__novaFirstPaint) window.__novaFirstPaint = {};
    if (!window.__novaFirstPaint[id]) { window.__novaFirstPaint[id] = 1; try { const pfp = api.post("/api/perf/first-paint", { ecran: id, delta_ms: Math.max(0, Math.round(performance.now() - __fpT0)) }); if (pfp && pfp.catch) pfp.catch(() => {}); } catch (e) {} }
  } catch (e) {
    reportError(e, "mount " + id);
    root.replaceChildren(h("div", { class: "errbox" }, h("b", {}, "Le module « " + id + " » a échoué au démarrage. "), String((e && e.message) || e)));
    instances.set(id, { id, root, destroy: null, onHide: null, onShow: null, scrollTop: 0 });
  }
}
let workspace = null;
function bootWorkspace() {
  try { view.querySelectorAll(".boot-skel").forEach((n) => n.remove()); } catch (e) {}   // le squelette d'amorçage ne doit pas transparaître sous les panneaux de verre
  workspace = createWorkspace({
    view, h, ic, bus,
    labelOf: (id) => (MODULES.find((m) => m.id === id) || {}).label || id,
    iconOf: (id) => (MODULES.find((m) => m.id === id) || {}).icon || "dot",
    descOf: (id) => (MODULES.find((m) => m.id === id) || {}).desc || "",
    open: (id, slot) => openInSlot(id, slot).then(() => { if (workspace && workspace.focusedId() === id) setFocusedCurrent(id); }),
    release: (id) => releaseModule(id),
  });
  bus.on("nova:pane-focus", (d) => { if (d && d.id) { setFocusedCurrent(d.id); bus.emit("nova:module", { id: d.id }); } });
  try { window.NovaWorkspace = { openBeside, openFloating, setLayout: (n) => workspace.setLayout(n), navigate }; } catch (e) {}
}

/* ── V4-A · GOUVERNEUR DE PERFORMANCE : un média qui joue (radio, podcast, TV, pièce jointe
   audio/vidéo) déclare la source « media » occupée — POST /api/perf {busy, source} — pour que le
   moteur diffère l'indexation lourde et les Éclats planifiés. Écoute en phase de capture (les
   événements média ne remontent pas) ; renouvelé toutes les 10 min tant que ça joue (le moteur
   oublie une source après 15 min) ; relâché dès que plus rien ne joue. Le chat est géré par
   agent.js (source « chat »). */
(function mediaPerf() {
  const playing = new Set();
  let last = null, renew = 0;
  const send = (b) => { try { const p = api.post("/api/perf", { busy: b, source: "media" }, 5000); if (p && p.catch) p.catch(() => {}); } catch (e) {} };
  const sync = () => {
    for (const m of [...playing]) if (!m.isConnected || m.paused || m.ended) playing.delete(m);
    const b = playing.size > 0;
    if (b === last) return;
    last = b; send(b);
    clearInterval(renew); renew = 0;
    if (b) renew = setInterval(() => { if (playing.size) send(true); }, 10 * 60000);
  };
  const isMedia = (t) => typeof HTMLMediaElement !== "undefined" && t instanceof HTMLMediaElement;
  document.addEventListener("playing", (e) => { if (isMedia(e.target) && !e.target.muted) { playing.add(e.target); sync(); } }, true);
  for (const ev of ["pause", "ended", "emptied", "abort", "error", "volumechange"]) document.addEventListener(ev, (e) => { const t = e.target; if (!isMedia(t)) return; if (t.muted) playing.delete(t); else if (ev === "volumechange" && !t.paused && !t.ended) playing.add(t); sync(); }, true);
  window.addEventListener("pagehide", () => { if (last) send(false); });
})();

/* ── Mini-lecteur persistant : l'élément <audio> vit ici, jamais dans un module ── */
const audio = document.getElementById("audio");
const mp = document.getElementById("miniplayer");
let mpState = { title: "", sub: "", url: "" };
function renderPlayer() {
  const playing = !audio.paused && !!audio.src;
  mp.className = mpState.url ? "show" : "";
  mp.replaceChildren(
    h("div", { class: "orb orb-sm", "data-state": playing ? "parole" : "repos" }, h("div", { class: "orb-core" }), h("div", { class: "orb-ring" })),
    h("div", { class: "grow" }, h("div", { class: "tt" }, mpState.title || "—"), h("div", { class: "ss" }, mpState.sub || "")),
    h("button", { class: "mp-btn main", title: playing ? "Pause" : "Lecture", html: ic(playing ? "pause" : "play", 19),
      onclick: () => { if (audio.src) { audio.paused ? audio.play() : audio.pause(); } } }),
    h("button", { class: "mp-btn", title: "Arrêter et fermer", html: ic("close", 16),
      onclick: () => { audio.pause(); audio.removeAttribute("src"); audio.load(); mpState = { title: "", sub: "", url: "" }; renderPlayer(); bus.emit("nova:player-state", { playing: false }); } }));
}
bus.on("nova:play", (d) => {
  if (!d || !d.url) return;
  mpState = { title: d.title || "Audio", sub: d.sub || "", url: d.url };
  if (audio.src !== d.url) audio.src = d.url;
  audio.play().catch((e) => reportError(e, "lecture audio", true));
  renderPlayer();
});
for (const ev of ["play", "pause", "ended", "error"]) audio.addEventListener(ev, () => { renderPlayer(); bus.emit("nova:player-state", { playing: !audio.paused && !!audio.src, title: mpState.title }); });
/* NOVA2 (vague 2) : arrêt du lecteur demandé par le pont UI (ordre « media stop » de l'agent). */
bus.on("nova:player-stop", () => { try { audio.pause(); audio.removeAttribute("src"); audio.load(); mpState = { title: "", sub: "", url: "" }; renderPlayer(); bus.emit("nova:player-state", { playing: false }); } catch (e) {} });

/* ── Lecteur flottant (TV/radio vidéo) : l'élément média vit dans le SHELL ──
   Problème : un <video> dans le module Médias mourait au démontage, et même
   caché, quitter l'écran arrêtait la lecture. Mécanique retenue (la plus sûre) :
   on DÉPLACE le nœud DOM lui-même (appendChild sur un élément déjà lu NE le
   recharge PAS : ni la source, ni la position, ni l'état de lecture ne changent
   — recréer un élément ou réassigner src, au contraire, repartirait à zéro).
   Un commentaire-placeholder garde la place exacte dans le module ; « Retour
   plein écran » réinsère le nœud devant son placeholder et navigue au module.
   Le flottant appartient au shell : visible et audible depuis n'importe quel
   module, déplaçable par sa barre de titre, boutons pause / retour / fermer.
   (L'audio radio/podcast, lui, vit déjà ici : #audio + mini-lecteur, inchangés.)
   Limite web, dite : pas de vraie fenêtre macOS séparée ni de PiP système
   garanti — document.pictureInPicture n'est pas fiable sous WKWebView ; le
   flottant reste donc un overlay DANS la fenêtre de l'app. Voir LISEZ-MOI.md. */
const watchbox = h("div", { id: "watchbox", role: "dialog", "aria-label": "Lecteur vidéo flottant" });
watchbox.style.display = "none";
document.body.append(watchbox);
const watchState = { el: null, title: "", sub: "", module: "radio", onRelease: null, slot: null };
function renderWatch() {
  const el = watchState.el;
  watchbox.style.display = el ? "flex" : "none";
  try { const fabEl = document.querySelector(".dock-fab"); if (fabEl) fabEl.hidden = el ? true : ((current && current.id === "accueil") ? true : false); } catch (e) {}
  if (!el) { watchbox.replaceChildren(); return; }
  const playing = !el.paused && !el.ended;
  const head = h("div", { class: "watch-head", title: "Glisser pour déplacer" },
    h("span", { class: "watch-tt" }, watchState.title || "Vidéo"),
    h("span", { class: "watch-ss" }, watchState.sub || ""),
    h("span", { class: "sp", style: "flex:1" }),
    h("button", { class: "mp-btn", title: playing ? "Pause" : "Lecture", html: ic(playing ? "pause" : "play", 16),
      onclick: () => { try { el.paused ? el.play() : el.pause(); } catch (e) {} renderWatch(); } }),
    h("button", { class: "mp-btn", title: "Retour plein écran (dans Médias)", html: ic("video", 16),
      onclick: () => watchExpand() }),
    h("button", { class: "mp-btn", title: "Fermer le lecteur", html: ic("close", 15),
      onclick: () => watchClose() }));
  head.addEventListener("pointerdown", (e) => {
    if (e.target.closest("button")) return;
    const r = watchbox.getBoundingClientRect();
    const dx = e.clientX - r.left, dy = e.clientY - r.top;
    watchbox.dataset.dragged = "1";
    watchbox.style.left = r.left + "px"; watchbox.style.top = r.top + "px"; watchbox.style.right = "auto"; watchbox.style.bottom = "auto";
    const move = (ev) => {
      const x = Math.max(0, Math.min(innerWidth - 80, ev.clientX - dx));
      const y = Math.max(0, Math.min(innerHeight - 60, ev.clientY - dy));
      watchbox.style.left = x + "px"; watchbox.style.top = y + "px";
    };
    const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up); };
    addEventListener("pointermove", move); addEventListener("pointerup", up);
  });
  watchbox.replaceChildren(head, h("div", { class: "watch-stage" }));
  watchbox.querySelector(".watch-stage").append(el);
}
function watchAttach(el, meta = {}) {
  if (!el || el.nodeType !== 1) return false;
  if (watchState.el && watchState.el !== el) watchRelease("replace");
  if (watchState.el === el) {
    if (Object.prototype.hasOwnProperty.call(meta, "title")) watchState.title = String(meta.title || "");
    if (Object.prototype.hasOwnProperty.call(meta, "sub")) watchState.sub = String(meta.sub || "");
    if (Object.prototype.hasOwnProperty.call(meta, "module")) watchState.module = String(meta.module || "radio");
    if (typeof meta.onRelease === "function") watchState.onRelease = meta.onRelease;
    renderWatch();
    bus.emit("nova:watch", { active: true, title: watchState.title });
    return true;
  }
  const slot = document.createComment("watch-slot");
  if (el.parentNode) el.parentNode.insertBefore(slot, el);
  watchState.el = el; watchState.slot = slot;
  watchState.title = String(meta.title || ""); watchState.sub = String(meta.sub || "");
  watchState.module = String(meta.module || "radio");
  watchState.onRelease = typeof meta.onRelease === "function" ? meta.onRelease : null;
  el.classList.add("watch-media");
  try { el.controls = true; } catch (e) {}
  if (!el._watchHook) { el._watchHook = true; for (const ev of ["play", "pause", "ended"]) el.addEventListener(ev, () => { if (watchState.el === el) renderWatch(); }); }
  renderWatch();
  bus.emit("nova:watch", { active: true, title: watchState.title });
  return true;
}
function watchRelease(reason) {
  const el = watchState.el; if (!el) return;
  const cb = watchState.onRelease, slot = watchState.slot;
  watchState.el = null; watchState.onRelease = null; watchState.slot = null;
  el.classList.remove("watch-media");
  if (slot && slot.parentNode) slot.parentNode.insertBefore(el, slot);
  if (slot) slot.remove();
  renderWatch();
  bus.emit("nova:watch", { active: false });
  if (cb) { try { cb(reason || "release"); } catch (e) { reportError(e, "watch onRelease", true); } }
}
function watchExpand() { const target = watchState.module || "radio"; watchRelease("expand"); navigate(target); }
function watchClose() {
  const el = watchState.el;
  if (el) { try { el.pause(); } catch (e) {} }
  watchRelease("close");
}
ctx.watch = { attach: watchAttach, release: watchRelease, close: watchClose, expand: watchExpand, active: () => !!watchState.el };
bus.on("nova:watch-stop", () => watchClose());

/* NOVA2 (vague 2, item 10) : trace de présence pour le compte rendu d'absence.
   La valeur lue AU DÉMARRAGE (avant écrasement) = la dernière fois que Nova a été vue ;
   l'accueil compare les passages de Dots à cette borne. Rafraîchie chaque minute tant
   que l'app est ouverte, et à la fermeture. */
try { window.__novaPrevSeen = Number(localStorage.getItem("nova2_last_seen")) || 0; } catch (e) { window.__novaPrevSeen = 0; }
const stampSeen = () => { try { localStorage.setItem("nova2_last_seen", String(Date.now())); } catch (e) {} };
stampSeen(); setInterval(stampSeen, 60000); addEventListener("beforeunload", stampSeen);

/* 29/10 (fluidité — jank.js : 42 gels de 250–490 ms en 10 min sur Conversations SANS AUCUN geste) —
   SIGNAL DE REPOS PARTAGÉ. html[data-idle="1"] est posé après 10 s sans geste (souris, clic, molette,
   clavier, défilement) ou quand la fenêtre perd le focus, et retiré au premier geste. Tant que Nova
   travaille ou parle (état de présence ≠ repos/sommeil), on ne passe pas au repos. Le CSS s'en sert pour
   suspendre les respirations décoratives (chaque image d'une animation infinie oblige le compositeur à
   recomposer les flous du rail et du panneau) ; les moteurs d'avatar baissent leur cadence.
   Un seul minuteur, réarmé paresseusement (aucun setTimeout par mouvement de souris). */
(function idleSignal() {
  const root = document.documentElement;
  const IDLE_MS = 10000;
  let lastAct = performance.now(), idle = false, t = 0, presenceBusy = false;
  const set = (v) => {
    if (v === idle) return;
    idle = v;
    if (v) root.dataset.idle = "1"; else delete root.dataset.idle;
    try { window.dispatchEvent(new CustomEvent("nova:idle", { detail: { idle: v } })); } catch (e) {}
  };
  const check = () => {
    t = 0;
    const left = IDLE_MS - (performance.now() - lastAct);
    if (presenceBusy) { t = setTimeout(check, IDLE_MS); return; }
    if (left <= 0) set(true); else t = setTimeout(check, left + 50);
  };
  const act = () => { lastAct = performance.now(); if (idle) set(false); if (!t) t = setTimeout(check, IDLE_MS + 50); };
  for (const ev of ["pointermove", "pointerdown", "keydown", "wheel", "touchstart"]) addEventListener(ev, act, { passive: true, capture: true });
  document.addEventListener("scroll", act, { passive: true, capture: true });
  addEventListener("focus", act);
  addEventListener("blur", () => { if (!presenceBusy) { clearTimeout(t); t = 0; set(true); } });
  window.addEventListener("nova:presence-state", (e) => {
    const st = String((e && e.detail && e.detail.state) || "repos");
    presenceBusy = !(st === "repos" || st === "sleep");
    if (presenceBusy) { if (idle) set(false); lastAct = performance.now(); }
    if (!t) t = setTimeout(check, IDLE_MS + 50);
  });
  t = setTimeout(check, IDLE_MS + 50);
})();

/* ── Pont natif (volets Swift) : NovaNative.onNav est appelé par main.swift ── */
window.NovaNative = {
  onNav(info) { bus.emit("nova:panenav", info || {}); },
  onText(id, text) { bus.emit("nova:panetext", { id, text }); },
  /* NOVA2 (vague 3 CONNECT) : main.swift rapporte l'état Tor (torReport → onTor) —
     ce récepteur n'existait pas : l'état ne remontait jamais et le volet Tor, pourtant
     entièrement câblé côté Swift (binaire détecté, SOCKS local, volet proxifié),
     restait invisible et indémarrable depuis l'interface. */
  onTor(info) { bus.emit("nova:tor", info || {}); },
};
/* Ctrl+Tab / Option+Tab : main.swift pilote window.NovaSwitch (sélecteur d'onglets natif) */
let vaultOpenCache = false;
let switchIdx = -1;
const SWITCH_ORDER = ["accueil", "conversations", "messages", "veille", "temps", "dots", "conseil", "livrables", "radio", "finance", "vie", "savoir", "relations", "journal", "ame", "controle", "systeme", "settings"];
function switchIds() { const ids = SWITCH_ORDER.slice(); if (vaultOpenCache) { const i = ids.indexOf("controle"); if (i >= 0) ids.splice(i, 0, "vault"); } return ids; }
function switchLabel(id) { const m = MODULES.find((x) => x.id === id); return m ? m.label : id; }
window.NovaSwitch = {
  step(d) { const ids = switchIds(); let i = ids.indexOf(current ? current.id : "dots"); if (i < 0) i = 0; switchIdx = ((switchIdx < 0 ? i : switchIdx) + d + ids.length) % ids.length; ctx.toast("Module : " + switchLabel(ids[switchIdx])); },
  commit() { if (switchIdx >= 0) { const ids = switchIds(); const id = ids[switchIdx]; switchIdx = -1; if (id === "conversations") { try { if (typeof gotoConversations === "function") gotoConversations(); else navigate("conversations"); } catch (e) { navigate("conversations"); } } else navigate(id); } },
};

/* ── Erreurs de thème visibles (fini le repli silencieux de Nova 1) ────── */
window.addEventListener("nova:theme-error", (e) => ctx.toast("Thème inconnu : « " + ((e.detail && e.detail.id) || "inconnu") + " » — thème actuel conservé.", true));

/* ── Démarrage ─────────────────────────────────────────────────────────── */
function applyRailWidth() {
  let mini = false;
  try { mini = localStorage.getItem("nova2_rail") === "mini"; } catch (e) {}
  try { document.querySelector(".shell").classList.toggle("sb-mini", mini || window.innerWidth < 1000); } catch (e) {}
}
/* ── VAGUE 1 (24/10) — HALO D'ACTIVITÉ ─────────────────────────────────────
   Pastille de verre au pied de la barre latérale : ce que Nova et chaque Dot font
   À L'INSTANT, d'après GET /api/activity (états connus du moteur : runs de Dots
   en vol + dernier outil réellement exécuté, conversations dont la réponse
   s'écrit, tâches de fond). Réveillé par les événements SSE (dot, engagements,
   delegation, meeting) et par la présence du panda (runs de chat de cette
   fenêtre) ; sondage lent (45 s) au repos, 4 s tant que quelque chose tourne.
   Jamais d'état simulé : si rien ne tourne — ou si le moteur ne répond pas —
   le halo se tait. Clic = panneau « Activité » (en cours + récent), Stop quand
   le moteur expose un arrêt (conversation : /api/chat/stop), lien vers l'écran. */
function createHalo() {
  const el = h("button", { class: "halo is-off", type: "button", tabindex: "-1", "aria-hidden": "true", "aria-haspopup": "dialog", title: "Activité de Nova et des Éclats" });
  const txt = h("span", { class: "halo-txt" });
  const more = h("span", { class: "halo-more", hidden: true });
  el.append(h("span", { class: "halo-dot", "aria-hidden": "true" }), txt, more);
  const panel = h("div", { class: "halo-panel", role: "dialog", "aria-label": "Activité", hidden: true });
  document.body.append(panel);
  let running = [], recent = [], inflight = false, pollT = 0, kickTs = [];
  const RANK = { conversation: 0, dot: 1, tache: 2 };
  const ago = (iso) => {
    const t = Date.parse(iso || ""); if (!isFinite(t)) return "";
    const s = Math.max(0, Math.round((Date.now() - t) / 1000));
    return s < 60 ? s + " s" : s < 3600 ? Math.round(s / 60) + " min" : Math.floor(s / 3600) + " h " + String(Math.round((s % 3600) / 60)).padStart(2, "0");
  };
  function goto(it) {
    if (it.kind === "conversation" && it.id) {
      try { localStorage.setItem("nova2_pending_conv", String(it.id)); } catch (e) {}
      navigate("conversations");
      setTimeout(() => { try { bus.emit("nova:open-conv", { id: String(it.id) }); } catch (e) {} }, 120);
    } else if (it.ecran) navigate(String(it.ecran));
    closePanel();
  }
  async function stop(it, btn) {
    if (!it.stop || !it.stop.path) return;
    btn.disabled = true;
    /* VAGUE 2 FIABILITÉ : la réponse est lue — « ok:false » (rien en vol) n'est jamais annoncé comme un arrêt. */
    try {
      const j = await api.post(String(it.stop.path), it.stop.body || {});
      if (j && j.ok === false) { ctx.toast(String(j.error || "Rien à arrêter : l'exécution est déjà terminée.")); btn.disabled = false; }
      else ctx.toast("Arrêt demandé — " + (it.kind === "dot" ? "Éclat " : "") + (it.name || "exécution") + " : il s'interrompt à la prochaine étape.");
    }
    catch (e) { ctx.toast("Arrêt impossible : le moteur n'a pas répondu.", true); btn.disabled = false; }
    setTimeout(() => refresh(), 800);
  }
  function rowEl(it, live) {
    const icon = it.kind === "dot" ? h("span", { class: "halo-ic" }, String(it.emoji || "●")) : h("span", { class: "halo-ic", html: ic(it.kind === "conversation" ? "chat" : "sparkle", 14) });
    const sub = live
      ? [it.kind === "dot" ? "Éclat " + (it.name || "") : it.name || "", it.since ? "depuis " + ago(it.since) : "", it.detail || ""].filter(Boolean).join(" · ")
      : [it.kind === "dot" ? "Éclat" : "", it.ts ? "il y a " + ago(it.ts) : ""].filter(Boolean).join(" · ");
    const title = live ? (it.label || it.name || "") : ((it.kind === "dot" ? (it.name || "") + " — " : (it.name ? it.name + " — " : "")) + (it.label || ""));
    const acts = h("div", { class: "halo-ra" },
      live && it.stop ? h("button", { class: "btn sm", title: "Arrêter cette exécution", onclick: (e) => stop(it, e.currentTarget) }, h("span", { html: ic("stop", 12) }), "Stop") : null,
      it.ecran ? h("button", { class: "btn sm ghost", title: "Ouvrir l'écran concerné", onclick: () => goto(it) }, "Ouvrir") : null);
    return h("div", { class: "halo-row" + (live ? " is-run" : it.ok === false ? " is-bad" : "") }, icon,
      h("div", { class: "halo-rm" }, h("div", { class: "halo-rt", title }, title), sub ? h("div", { class: "halo-rs", title: sub }, sub) : null), acts);
  }
  function paintPanel() {
    if (panel.hidden) return;
    const pb = h("div", { class: "halo-pb" });
    pb.append(h("div", { class: "halo-sec" }, "En cours"));
    if (running.length) for (const it of running) pb.append(rowEl(it, true));
    else pb.append(h("div", { class: "halo-empty" }, "Rien ne tourne en ce moment."));
    if (recent.length) { pb.append(h("div", { class: "halo-sec" }, "Récent")); for (const it of recent) pb.append(rowEl(it, false)); }
    panel.replaceChildren(
      h("div", { class: "halo-ph" }, h("h3", {}, "Activité"), h("button", { class: "btn sm ghost", title: "Fermer", "aria-label": "Fermer", onclick: () => closePanel(), html: ic("close", 14) })),
      pb);
    place();
  }
  function place() {
    const r = el.getBoundingClientRect();
    const left = Math.min(Math.max(12, r.right + 10), window.innerWidth - panel.offsetWidth - 12);
    panel.style.left = left + "px";
    panel.style.bottom = Math.max(12, window.innerHeight - r.bottom) + "px";
  }
  function paint() {
    const on = running.length > 0;
    el.classList.toggle("is-off", !on);
    el.setAttribute("aria-hidden", on ? "false" : "true");
    el.tabIndex = on ? 0 : -1;
    if (on) {
      const first = running[0];
      const label = String(first.label || first.name || "En cours");
      txt.textContent = label;
      el.title = running.map((x) => x.label || x.name).join("\n") + "\n— clic : panneau Activité";
      more.hidden = running.length < 2;
      more.textContent = "+" + (running.length - 1);
    }
    paintPanel();
  }
  async function refresh() {
    if (inflight) return; inflight = true;
    try {
      const j = await api.get("/api/activity", 8000);
      try { window.__novaActivity = { t: Date.now(), j }; } catch (e) {}   // 29/10 : partagé avec la pastille du compagnon (un seul sondage de /api/activity)
      running = (Array.isArray(j && j.running) ? j.running : []).filter((x) => x && (x.label || x.name)).sort((a, b) => (RANK[a.kind] ?? 3) - (RANK[b.kind] ?? 3));
      recent = (Array.isArray(j && j.recent) ? j.recent : []).filter((x) => x && (x.label || x.name)).slice(0, 8);
    } catch (e) { running = []; }   /* moteur muet : on ne prétend rien */
    inflight = false;
    paint();
    schedule();
  }
  function schedule() {
    clearTimeout(pollT);
    pollT = setTimeout(() => { if (document.hidden) schedule(); else refresh(); }, running.length ? 4000 : 45000);
  }
  /* Rafale courte après un événement : la conversation n'est visible côté moteur
     qu'à son premier point de sauvegarde (quelques secondes après le départ). */
  let kickAt = 0;
  function kick(first = 600) {
    if (first >= 600 && Date.now() - kickAt < 2500) return;   /* la présence bat à chaque fragment de réponse : une rafale à la fois */
    kickAt = Date.now();
    kickTs.forEach((t) => clearTimeout(t));
    kickTs = [first, 3000, 7000].map((ms) => setTimeout(() => { if (!document.hidden) refresh(); }, ms));
  }
  function openPanel() { panel.hidden = false; el.setAttribute("aria-expanded", "true"); paintPanel(); refresh(); }
  function closePanel() { panel.hidden = true; el.setAttribute("aria-expanded", "false"); }
  el.addEventListener("click", () => { if (panel.hidden) openPanel(); else closePanel(); });
  document.addEventListener("pointerdown", (e) => { if (!panel.hidden && !panel.contains(e.target) && !el.contains(e.target)) closePanel(); }, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !panel.hidden) { closePanel(); try { el.focus(); } catch (err) {} } });
  window.addEventListener("resize", () => { if (!panel.hidden) place(); });
  for (const ev of ["dot", "engagements", "delegation", "meeting", "brief"]) { try { bus.on(ev, () => kick()); } catch (e) {} }
  try {
    const P0 = window.__novaPresence;
    if (typeof P0 === "function") window.__novaPresence = (state, label) => { try { P0(state, label); } finally { kick(); } };
  } catch (e) {}
  setTimeout(() => refresh(), 1500);
  try { window.NovaHalo = { refresh, open: openPanel, close: closePanel }; } catch (e) {}
  return el;
}

async function boot() {
  try {
    const LEGACY = { dots: "accueil", agents: "dots", agent: "conversations", automatisations: "dots" };
    const stored = localStorage.getItem("nova2_last_module");
    if (stored && LEGACY[stored]) {
      localStorage.setItem("nova2_last_module", LEGACY[stored]);
      if (document.documentElement.dataset.lastModule === stored) document.documentElement.dataset.lastModule = LEGACY[stored];
    }
  } catch (e) {}
  rail.dataset.glass = "1";
  buildRail();
  applyRailWidth();
  try { startGlass(); } catch (e) { reportError(e, "glass", true); }
  import("./fx.js").then((m) => { try { m.initFx(); } catch (e) {} }).catch(() => {});   /* 24/10 : micro-animations */
  try { window.addEventListener("resize", applyRailWidth); } catch (e) {}
  paintDirectRailBadge();   // FIX-DIRECT-WEB ⑤ : badge « Conversations » repeint dès le boot depuis l'état partagé
  directService.start();   // Direct global : il veille dès le boot, pas seulement dans l'écran Agent
  proChat.start();         // PROCHAT : le fil sans clic veille dès le boot, lui aussi
  try { mountEclat(); } catch (e) {}   // LOT-13 : Éclat ne doit jamais casser le boot
  initPalette({ ...ctx, modules: MODULES });
  /* NOVA2 (vague 2, items 7+9) : le pont UIPilot — les ordres « app » de l'agent arrivent
     en SSE « ui » et sont exécutés ici, contre le vrai DOM, avec constat renvoyé. */
  initUIBridge({ api, bus, modules: MODULES, navigate: (id, force) => navigate(id, force), currentId: () => (current ? current.id : null), watch: () => ctx.watch });   // 25/10 : + lecteur flottant (outil « media » de l'agent)

  /* DIAG2-VEILLE (optionnel) : aucun lien de la coquille ne doit quitter
     Nova. Les liens http(s) target=_blank rendus dans la vue principale
     (markdown du chat et des briefs, cartes…) sont interceptés et ouverts
     dans le volet Navigateur de Messages (patron nova:open-url,
     P-VEILLE-5) au lieu d'être abandonnés à la politique native
     (main.swift : NSWorkspace.shared.open). Les volets natifs sont des
     WKWebView séparés, hors de ce DOM : jamais interceptés. Les mailto:
     restent au système. */
  const openUrlBeside = (url) => {
    if (!/^https?:\/\//i.test(url || "")) return;
    try { localStorage.setItem("nova2_pending_url", JSON.stringify({ url, at: Date.now() })); } catch (err) {}
    navigate("messages");
    setTimeout(() => { try { bus.emit("nova:open-url", { url }); } catch (err) {} }, 60);
  };
  /* Point d'entrée des volets natifs (main.swift) : lien cliqué dans un volet
     courrier — la page s'ouvre à côté dans Messages, jamais dans le volet mail. */
  try { window.NovaOpenUrl = (url) => openUrlBeside(String(url || "")); } catch (err) {}
  document.addEventListener("click", (e) => {
    const a = e.target && e.target.closest ? e.target.closest('a[target="_blank"]') : null;
    if (!a) return;
    const url = a.href || "";
    if (!/^https?:\/\//i.test(url)) return;
    e.preventDefault();
    openUrlBeside(url);
  });
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); bus.emit("nova:palette"); }
    if (e.metaKey && !e.shiftKey && !e.altKey && e.key === ".") { e.preventDefault(); toggleFocus(); return; }   // ⌘. : mode focus (plan UI 27/10)
    if (e.key === "Escape" && document.querySelector(".shell.nova-focus")) { e.preventDefault(); toggleFocus(false); return; }
    if (e.metaKey && e.shiftKey && !e.altKey && !e.ctrlKey && e.code === "KeyR") { e.preventDefault(); location.reload(); return; }   // ⇧⌘R : recharger l'interface (sans relancer le moteur)
    if (e.metaKey && !e.altKey && !e.shiftKey && !e.ctrlKey && e.code === "KeyJ") { e.preventDefault(); openBeside("conversations"); setTimeout(() => { const t = document.querySelector('.mod[data-mod="conversations"] .composer textarea'); if (t) t.focus(); }, 300); return; }
    if (e.key === "Escape" && document.documentElement.hasAttribute("data-vide")) { e.preventDefault(); toggleVide(false); return; }
    if (e.metaKey && !e.altKey && !e.shiftKey && !e.ctrlKey && /^Digit[0-9]$/.test(e.code)) {
      const n = +e.code.slice(5);
      if (n === 0) { e.preventDefault(); toggleSidebar(); return; }
      const order = [...rail.querySelectorAll(".rail-mods .rail-btn")];
      const b = order[n - 1]; if (b) { e.preventDefault(); b.click(); }
    }
  });
  /* NOVA2-FIX (reco n°2) : rouvrir là où l'utilisateur s'était arrêté — le dernier
     module, lu par le script inline d'index.html (data-last-module), validé contre
     le registre ; repli Accueil si absent ou inconnu. */
  const startId = document.documentElement.dataset.lastModule;
  const target = MODULES.some((m) => m.id === startId) ? startId : "accueil";   // 24/10 : le repli était « dots » (= écran Dots), contraire au commentaire — corrigé en Accueil
  bootWorkspace();
  workspace.restore(target).then(() => { const fid = workspace.focusedId() || target; setFocusedCurrent(fid); bus.emit("nova:module", { id: fid }); }).catch((e) => { reportError(e, "workspace.restore"); navigate(target); });
  fetchState();
  bootWatchdog(target);
}

/* État serveur d'amorçage (thème, accessibilité, verre) — fonction nommée pour
   que le bouton « Réessayer » du chien de garde puisse la relancer telle quelle. */
async function fetchState() {
  try {
    const st = await api.get("/api/state");
    const s = (st && st.settings) || {};
    if (s.theme) {
      let themeId = String(s.theme);
      /* V4-A — nouvelle identité « Nova Souverain » : UNE SEULE FOIS, l'ancien thème par défaut
         (Liquid Glass / Verre) passe à Obsidienne & Or Solaire, dans le même mode (jour, nuit,
         auto). Enregistré côté moteur, annoncé, et réversible dans Réglages › Apparence
         (« Verre Céleste »). Un choix fait ensuite n'est plus jamais touché. */
      let migrated = true; try { migrated = localStorage.getItem("nova2_identity_v4") === "1"; } catch (e) {}
      if (!migrated) {
        const NEW_DEFAULT = { "verre-nuit": "obsidienne-nuit", "verre-jour": "obsidienne-jour", "verre-auto": "obsidienne-auto" };
        if (NEW_DEFAULT[themeId]) {
          themeId = NEW_DEFAULT[themeId];
          try { const p = api.post("/api/settings", { theme: themeId }); if (p && p.catch) p.catch(() => {}); } catch (e) {}
          setTimeout(() => { try { softToast("Nouvelle identité de Nova : Obsidienne & Or Solaire. Verre Céleste reste disponible dans Réglages › Apparence.", 7000); } catch (e) {} }, 1200);
        }
        try { localStorage.setItem("nova2_identity_v4", "1"); } catch (e) {}
      }
      const t = applyTheme(themeId); if (t) { /* thème serveur appliqué */ }
    }
    if (s.reduce_motion) document.documentElement.dataset.reduceMotion = "1";
    const systemReduced = (() => { try { return !!(window.matchMedia && matchMedia("(prefers-reduced-transparency: reduce)").matches); } catch (e) { return false; } })();
    if (s.reduce_transparency) applyReducedTransparency(true, "application");
    else if (systemReduced) applyReducedTransparency(true, "systeme");
    else applyReducedTransparency(false, "application");
    /* Cache d'amorçage (reco n°2) : les préférences d'accessibilité et le curseur
       Liquid Glass (n°15) sont réappliqués AVANT le premier paint au prochain boot. */
    try {
      localStorage.setItem("nova2_reduce_motion", s.reduce_motion ? "1" : "0");
      localStorage.setItem("nova2_reduce_transparency", s.reduce_transparency ? "1" : "0");
    } catch (e) {}
    if (s.appearance_tint != null || s.appearance_density != null || s.appearance_blur != null) applyAppearance({ tint: s.appearance_tint, density: s.appearance_density, blur: s.appearance_blur });
    else if (s.glass_tint != null || s.glass_blur != null) applyGlass(s.glass_tint, s.glass_blur);
    bus.emit("nova:state", st || {});
  } catch (e) {
    // Le moteur ne répond pas : état d'erreur sobre DANS le shell (remplace le « bootguard » de Nova 1).
    reportError(e, "boot /api/state", true);
    if (!current) view.replaceChildren(h("div", { class: "mod" },
      h("div", { class: "errbox" }, h("b", {}, "Le moteur Nova ne répond pas. "),
        "Vérifie que l'application est bien lancée, puis recharge l'interface.",
        h("div", { style: "margin-top:10px" }, h("button", { class: "btn acc", onclick: () => location.reload() }, "Recharger")))));
  }
}

/* NOVA2-FIX (bug démarrage 20/10 — gel de ~5 min sur les squelettes, captures 14:56) :
   chien de garde du boot. Le premier écran doit monter immédiatement ; si le moteur
   est lent (indexation initiale de la base de connaissances, Trousseau froid), le
   shell le DIT au lieu de geler : « Nova démarre… » dès 3 s avec la progression
   RÉELLE de l'indexation (GET /api/knowledge/status), erreur nommée + Réessayer
   à 25 s. Il ne rafraîchit QUE la surface marquée « data-boot-skel » (le squelette
   de boot) — jamais le DOM d'un module en montage — et s'arrête dès le montage. */
function bootWatchdog(target) {
  const t0 = Date.now();
  let know = null, lastPoll = 0;
  const timer = setInterval(async () => {
    if (current) { clearInterval(timer); return; }
    if (Date.now() - lastPoll > 2500) {
      lastPoll = Date.now();
      try { know = await api.get("/api/knowledge/status", 3000); } catch (e) { /* état inconnu : message générique */ }
      if (current) { clearInterval(timer); return; }
    }
    const el = (Date.now() - t0) / 1000;
    if (el < 3) return;
    if (!view.querySelector("[data-boot-skel], .boot-skel")) return;   // un module monte (ou une erreur nommée est affichée) : ne pas toucher
    /* LOT1-FIX M8 : /api/knowledge/status sert {status:{…}, roots} (Extras.swift,
       inscription gagnante) — la forme plate lue ici (know.progress/know.scanning)
       est celle du doublon MORT d'App.swift : progression  oujours invisible. */
    const p = (know && know.status) || {};
    const prog = know && p.scanning
      ? "Indexation de la base de connaissances (arrière-plan) : " + (p.files || 0) + " fichiers, " + (p.chunks || 0) + " extraits" + (p.current ? " — en cours : " + p.current : "") + "."
      : "";
    if (el < 25) {
      view.querySelectorAll("[data-boot-skel]").forEach((n) => n.remove());
      view.append(h("div", { class: "mod boot-note", "data-boot-skel": "1" },
        h("div", { class: "card flat", style: "max-width:560px;margin:40px auto;text-align:center;padding:28px" },
          h("div", { style: "font-size:15px;font-weight:600" }, "Nova démarre… (" + Math.round(el) + " s)"),
          h("div", { class: "ss", style: "color:var(--ink-2);margin-top:8px" }, "Le premier écran arrive. Le travail lourd du moteur se fait en arrière-plan — il ne doit plus figer l'interface."),
          prog ? h("div", { class: "ss", style: "margin-top:8px" }, prog) : null)));
    } else {
      view.querySelectorAll("[data-boot-skel]").forEach((n) => n.remove());
      view.append(h("div", { class: "mod boot-note" },
        h("div", { class: "errbox", style: "max-width:560px;margin:40px auto" },
          h("b", {}, "Le moteur ne répond pas encore. "),
          "Démarrage trop long (" + Math.round(el) + " s) — le moteur est peut-être encore en initialisation. " + prog,
          h("div", { style: "margin-top:10px;display:flex;gap:8px" },
            h("button", { class: "btn acc", onclick: () => { navigate(target, true); fetchState(); } }, "Réessayer"),
            h("button", { class: "btn", onclick: () => location.reload() }, "Recharger l'interface")))));
    }
  }, 1000);
}

/* ═══ §40 — LA CONVERSATION PARTOUT (ordre d'Ahadi, 21/10 09:40) ═══════
   La conversation le suit d'écran en écran : un bouton « Parler à Nova »
   ouvre un panneau latéral lié à la conversation EN COURS (le même fil
   moteur que l'écran Conversations, même historique). Chaque premier
   envoi depuis un nouvel écran part avec le contexte de cet écran —
   Nova sait d'où il parle ; il n'a plus ni à retourner à l'onglet
   Conversations, ni à réexpliquer ce qu'il faisait ailleurs. */
const dockLabel = (id) => { const m = MODULES.find((x) => x.id === id); return m ? m.label : (id || "Accueil"); };
const dock = (() => {
  let cid = null, running = false, abortCtl = null, lastCtxLabel = "", statusEl = null;
  let dQuote = null;   // §42-dock : message ciblé par une relance
  let dSteer = [];     // §44-dock : suivis écrits PENDANT que Nova travaille (file de pilotage)
  const fab = h("button", { class: "dock-fab", title: "Parler à Nova sans quitter cet écran — la conversation te suit" }, h("span", { html: ic("orb", 18) }), " Parler à Nova");
  const convSel = h("select", { class: "fld dock-convsel", title: "Conversation à emporter" });
  const log = h("div", { class: "dock-log" });
  try { if (window.NovaProChat) window.NovaProChat.registerThread("dock", log); } catch (e) {}   // PROCHAT : les événements arrivent aussi dans le fil du dock
  const ctxLine = h("div", { class: "dock-ctx" }, "");
  const input = h("textarea", { class: "fld dock-input", rows: "2", placeholder: "Écris à Nova… (Entrée pour envoyer, Maj+Entrée pour une ligne)" });
  const sendBtn = h("button", { class: "btn acc" }, h("span", { html: ic("send", 16) }), " Envoyer");
  const stopBtn = h("button", { class: "btn", hidden: true }, "Stop");
  const quotebar = h("div", { class: "cs-quotebar dock-quotebar", hidden: true });
  const dAtt = createAttachments();
  const dAttMenu = h("div", { class: "cs-att-menu", hidden: true },
    h("button", { onclick: () => { dAttMenu.hidden = true; dAtt.btn.click(); } }, h("span", { html: ic("attach", 15) }), "Joindre des fichiers…"),
    h("button", { onclick: () => { dAttMenu.hidden = true; dAtt.dirBtn.click(); } }, h("span", { html: ic("layers", 15) }), "Joindre un dossier entier…"));
  const dAttBtn = h("button", { class: "btn icon", title: "Joindre des fichiers ou un dossier", html: ic("attach", 17), onclick: () => { dAttMenu.hidden = !dAttMenu.hidden; } });
  const dAttWrap = h("div", { class: "cs-att-wrap" }, dAttBtn, dAttMenu);
  /* 26/10 (audit) : au silence, on ATTEND la transcription finale puis on envoie (avant : envoi aveugle après 1,2 s, texte perdu s'il arrivait plus tard). */
  const dVoice = createVoice({ onAutoEnd: async () => {
    try {
      if (!dVoice.isListening()) return;
      dMicBtn.classList.remove("rec");
      const t = await dVoice.listenStop();
      if (t && t.trim()) { const cur = input.value; input.value = (cur && !/\s$/.test(cur) ? cur + " " : cur) + t.trim(); }
      if (input.value.trim()) sendBtn.click();
    } catch (e) { try { ctx.toast("Dictée : " + String((e && e.message) || e), true); } catch (e2) {} }
  } });
  const dMicBtn = h("button", { class: "btn icon", title: "Dicter (micro) — clique, parle, reclique : le texte tombe dans le champ", html: ic("mic", 17) });
  dMicBtn.addEventListener("click", async () => {
    if (dVoice.isListening()) {
      dMicBtn.classList.remove("rec");
      try {
        const t = await dVoice.listenStop();
        if (t && t.trim()) {
          const cur = input.value;
          input.value = (cur && !/\s$/.test(cur) ? cur + " " : cur) + t.trim();
          input.focus();
        }
      } catch (e) {}
      return;
    }
    try {
      await dVoice.listenStart();
      dMicBtn.classList.add("rec");
    } catch (e) {}
  });
  dAtt.attachTo(log, input);
  document.addEventListener("click", (e) => { if (!dAttWrap.contains(e.target)) dAttMenu.hidden = true; });
  log.addEventListener("nova:att-rejected", (e) => { (e.detail || []).forEach((m) => ctx.toast(m, true)); });
  const panel = h("aside", { class: "dock-panel", hidden: true },
    h("div", { class: "dock-head" },
      h("span", { class: "tt" }, "Conversation avec Nova"),
      h("span", { class: "sp" }),
      h("button", { class: "btn sm", title: "Ouvrir cette conversation en plein écran", onclick: () => { if (cid) { try { localStorage.setItem("nova2_pending_conv", cid); } catch (e) {} } close(); navigate("agent"); if (cid) bus.emit("nova:open-conv", { id: cid }); } }, "Ouvrir en plein écran"),
      h("button", { class: "btn sm", title: "Nouvelle conversation", onclick: () => { cid = null; lastCtxLabel = ""; log.replaceChildren(); convSel.value = ""; status("Nouvelle conversation — écris, le fil se retrouvera aussi dans l'écran Conversations."); input.focus(); } }, "Nouvelle"),
      h("button", { class: "btn sm", title: "Fermer le panneau (la conversation continue)", onclick: () => close(), html: ic("close", 16) })),
    convSel, ctxLine, log, quotebar,
    h("div", { class: "composer dock-composer" }, dAtt.bar, h("div", { class: "composer-row" }, h("div", { class: "composer-tools" }, dAttWrap, dMicBtn), input, stopBtn, sendBtn)));
  document.body.append(fab, panel);
  function onAgentScreen() { return !!(current && current.id === "agent"); }
  function paintCtx() { ctxLine.replaceChildren(h("span", { html: ic("look", 14) }), " Tu es sur : " + dockLabel(current && current.id) + " — Nova reçoit ce contexte avec ton message."); }
  function bubble(role, text, ts) {
    const b = h("div", { class: "msg " + (role === "user" ? "me" : "nova") });
    if (role === "user") b.append(text); else b.innerHTML = md(text || "");
    if (ts) stampMsgTime(b, ts);   // HORODATAGE : ts stocké du moteur ; absent → aucune heure affichée, jamais inventée
    log.append(b); log.scrollTop = log.scrollHeight; return b;
  }
  function status(text) { const s2 = h("div", { class: "dock-status" }, text); log.append(s2); log.scrollTop = log.scrollHeight; return s2; }
  /* LOT WEB v3 : le dock consomme le même lieur de message que les deux
     autres surfaces (core.bindChatMessage) — réactions et magasin partagés,
     menu relié dès la création de la bulle, donc PENDANT le streaming, et
     déclencheurs clic droit / clavier / appui long identiques. */
  function dSetQuote(text) {
    dQuote = text || null;
    quotebar.replaceChildren();
    if (!dQuote) { quotebar.hidden = true; return; }
    quotebar.hidden = false;
    quotebar.append(
      h("span", { class: "cs-quote-txt" }, h("span", { html: ic("undo", 14) }), " " + dQuote.replace(/\s+/g, " ").slice(0, 140)),
      h("button", { class: "btn sm", title: "Retirer la relance", onclick: () => dSetQuote(null), html: ic("close", 16) }));
    input.focus();
  }
  function dAttachActions(b, getText) {
    return bindChatMessage(b, getText, {
      cid: () => cid || "local",
      quote: (text) => dSetQuote(text),
      follow: (text, label, instruction) => { dSetQuote(text); input.value = instruction || label; send(); },
    });
  }
  async function loadConvs() {
    try {
      const j = await api.get("/api/conversations");
      const items = (j && j.items) || [];
      convSel.replaceChildren(...items.slice(0, 30).map((c) => h("option", { value: String(c.id) }, String(c.title || c.id))));
      if (!cid && items.length) cid = String(items[0].id);
      if (cid) convSel.value = cid;
    } catch (e) {}
  }
  async function loadMsgs() {
    log.replaceChildren();
    if (!cid) { status("Choisis une conversation ou écris directement : le fil se créera ici et se retrouvera dans l'écran Conversations."); return; }
    try {
      const j = await api.get("/api/conversation?id=" + encodeURIComponent(cid));
      const msgs = (j && j.messages) || [];
      if (!msgs.length) status("Conversation vide.");
      let prevTs = null;   // HORODATAGE : séparateur de jour dès que le jour change dans le fil rejoué
      for (const m of msgs.slice(-30)) {
        if (m.ts && !sameDay(prevTs, m.ts)) { const sep = daySepEl(m.ts); if (sep) log.append(sep); }
        if (m.role === "user") bubble("user", String(m.content || ""), m.ts);
        else if (m.role === "assistant") { const t = String(m.content || ""); dAttachActions(bubble("nova", t, m.ts), () => t); }
        if (m.ts) prevTs = m.ts;
      }
    } catch (e) { status("Historique illisible pour le moment."); }
  }
  async function open() {
    panel.hidden = false; fab.hidden = true;
    document.body.classList.add("dock-open");   // la vue se compresse : le panneau ne recouvre plus le module (capture 10:08)
    paintCtx();
    await loadConvs();
    try { await loadMsgs(); } catch (e) {}
    input.focus();
  }
  function close() { panel.hidden = true; fab.hidden = onAgentScreen(); document.body.classList.remove("dock-open"); }
  fab.onclick = open;
  convSel.addEventListener("change", () => { cid = convSel.value || null; lastCtxLabel = ""; loadMsgs(); });
  /* §44 : un suivi écrit pendant que Nova travaille part dans la file de
     pilotage — injecté à la prochaine étape du moteur, sans attendre la
     fin de sa réponse et sans repartir de zéro. */
  async function dSteerSend(it) {
    let t = String(it.text || "");
    if (it.quote) t = "[RELANCE — l'utilisateur répond à CE message précis de toi :\n« " + String(it.quote).slice(0, 900) + " »\nRéponds à ce message-là, pas à la conversation en général.]\n" + t;
    t = "[AJOUT EN COURS DE TÂCHE — intègre ceci à ton travail en cours, ne recommence pas à zéro] " + t;
    try { await sse("/api/chat", { text: t, tools: true, ...(cid ? { conversation_id: cid } : {}) }, () => {}); }
    catch (e) { status("Un ajout en cours de tâche n'a pas pu partir — réessaie à la fin de la réponse."); }
  }
  async function send() {
    const text = input.value.trim(); if (!text && !dAtt.count()) return;
    if (running) {
      const q = dQuote; dSetQuote(null);
      dSteer.push({ text, quote: q });
      input.value = "";
      status("Ajouté à la tâche en cours — Nova l'intègre sans repartir de zéro.");
      return;
    }
    let dAtts = [];
    try { await dAtt.uploadPending(); dAtts = dAtt.take(); } catch (e) { status("Pièce jointe : " + String((e && e.message) || e)); return; }
    input.value = "";
    paintCtx();
    const ub = bubble("user", text);
    const ack = h("div", { class: "msg-ack" }, h("span", { html: ic("check", 13) }), " reçu"); ub.append(ack);
    running = true; sendBtn.replaceChildren(h("span", { html: ic("send", 16) }), " Ajouter à la file"); stopBtn.hidden = false;
    const label = dockLabel(current && current.id);
    let engineText = text + (dAtts.length ? (text ? "\n\n" : "") + describeForBrain(dAtts) : "");
    if (label !== lastCtxLabel) {
      engineText = "[Contexte : l'utilisateur te parle depuis le panneau latéral, écran « " + label + " » de Nova. Tiens compte de ce qu'il y fait — ne lui demande pas où il est ni ce qu'il regardait.]\n" + text;
      lastCtxLabel = label;
    }
    if (dQuote) {
      engineText = "[RELANCE — l'utilisateur répond à CE message précis de toi :\n« " + dQuote.slice(0, 900) + " »\nRéponds à ce message-là, pas à la conversation en général.]\n" + engineText;
      dSetQuote(null);
    }
    let novaB = null, acc = "";
    abortCtl = new AbortController();
    try {
      await sse("/api/chat", { text: engineText, tools: true, ecran: dockLabel(current && current.id), ...(cid ? { conversation_id: cid } : {}) }, (type, d) => {
        d = d || {};
        if (!ack.dataset.seen) { ack.dataset.seen = "1"; ack.textContent = "Nova s'en occupe…"; }
        try { const P = window.__novaPresence; if (P) { if (type === "tool") P("tool", String(d.name || "outil en cours")); else if (type === "step") P("reflexion", String(d.label || "Étape en cours…")); else if (type === "error") P("error", "Erreur du moteur"); else if (type === "done") P("done", "Nova · terminé"); else if (type === "delta" || type === "meta") P("reflexion", "Nova réfléchit…"); } } catch (e) {}
        if (type === "meta") {
          if (d.conversation_id) cid = String(d.conversation_id);
          if (d.user_ts) {   // HORODATAGE : ts stocké du message d'Ahadi, écrit par le moteur avant le flux
            if (!sameDay(prevStampedTs(log, ub), d.user_ts)) { const sep = daySepEl(d.user_ts); if (sep) ub.before(sep); }
            stampMsgTime(ub, d.user_ts);
          }
        }
        else if (type === "reset") { acc = ""; if (novaB) novaB.textContent = ""; }   // 24/10 : tentative remplacée effacée
        else if (type === "delta") {
          if (statusEl) { statusEl.remove(); statusEl = null; }
          if (!novaB) { novaB = bubble("nova", ""); dAttachActions(novaB, () => acc); }
          acc += d.t || ""; novaB.textContent = acc; log.scrollTop = log.scrollHeight;
        }
        else if (type === "step" || type === "tool") {
          /* DIAG2-CONTEXTE P-CTX-3 : ne plus lancer les ajouts en parallèle du run en cours
             (chaque dSteerSend était un POST concurrent sur le même fil, réponse ignorée).
             Les ajouts restent dans dSteer et sont émis séquentiellement à la fin de send()
             (hunk 4), chacun comme son propre tour. */
          if (dSteer.length) status(dSteer.length + " ajout(s) en file — ils partiront un par un à la fin de ce tour.");
          if (!novaB) {
            /* DIAG2-FLUX P6 : nommer l'étape — le payload « step » n'a pas de « label » : on compose
               depuis tool + arg (et « beat » pour les outils longs, P-FLUX-3). */
            const t = type === "tool"
              ? String(d.name || "outil") + "…"
              : (d.beat != null
                  ? String(d.tool || "étape") + " — toujours en cours · " + d.beat + " s"
                  : String(d.tool || "étape") + (d.arg ? " — " + String(d.arg).slice(0, 80) : "") + (d.state === "err" ? " — échec" : "…"));
            if (statusEl) statusEl.textContent = t; else statusEl = status(t);
          }
        }
        /* DIAG2-FLUX P6 : bascule de cerveau et relance annoncées dans le dock (avant : ignorées). */
        else if (type === "failover") { const t = "Bascule : " + String(d.from || "?") + " → " + String(d.to || "?"); if (statusEl) statusEl.textContent = t; else statusEl = status(t); }
        else if (type === "retry") { const t = d.reason ? "Nouvelle tentative : " + String(d.reason) : "Nouvelle tentative"; if (statusEl) statusEl.textContent = t; else statusEl = status(t); }
        else if (type === "confirm" && !d.resolved) {
          const card = h("div", { class: "dock-confirm" },
            h("div", { class: "tt" }, "Approbation demandée : " + String(d.tool || "action")),
            d.input ? h("div", { class: "appr-cmd" }, String(d.input).slice(0, 240)) : null,
            h("div", { class: "dock-confirm-row" },
              h("button", { class: "btn sm acc", onclick: async () => { try { const j = await api.post("/api/confirm", { id: d.id, ok: true }); if (j && j.message && String(j.message) !== "Autorisé.") status("Confirmation non appliquée — moteur : " + String(j.message)); } catch (e) { status("Confirmation non envoyée : " + ((e && e.message) || e)); } card.remove(); } }, "Approuver"),
              h("button", { class: "btn sm", onclick: async () => { try { const j = await api.post("/api/confirm", { id: d.id, ok: false }); if (j && j.message && String(j.message) !== "Refusé.") status("Refus non appliqué — moteur : " + String(j.message)); } catch (e) { status("Refus non envoyé : " + ((e && e.message) || e)); } card.remove(); } }, "Refuser")));
          log.append(card); log.scrollTop = log.scrollHeight;
        }
        else if (type === "stamp") {
          if (novaB && d.assistant_ts) {   // HORODATAGE : ts stocké de la réponse (checkpoint final du moteur)
            if (!sameDay(prevStampedTs(log, novaB), d.assistant_ts)) { const sep = daySepEl(d.assistant_ts); if (sep) novaB.before(sep); }
            stampMsgTime(novaB, d.assistant_ts);
          }
          if (d.user_ts && !ub.dataset.ts) stampMsgTime(ub, d.user_ts);
        }
        else if (type === "error") status(String(d.message || "Erreur du moteur"));
        else if (type === "done") {
          if (statusEl) { statusEl.remove(); statusEl = null; }
          if (novaB && acc) { novaB.innerHTML = md(acc); dAttachActions(novaB, () => acc); if (novaB._paintRx) novaB._paintRx(); }   // textContent du flux a détaché la ligne de réactions : on la repeint (parade déjà en place côté Conversations)
          /* DIAG2-FLUX P6 : fin sans réponse — avant : « ✅ » sans bulle (run mort en silence).
             Désormais la fin vide se nomme, et l'accusé ne dit pas succès. */
          if (!acc) { status("Le run s'est terminé sans réponse — rien n'a été exécuté. Relance la demande."); ack.innerHTML = ic("alert", 13); }
          else { ack.innerHTML = ic("check", 13); setTimeout(() => { try { ack.remove(); } catch (e) {} }, 1500); }
        }
      }, abortCtl.signal);
    } catch (e) { if (!abortCtl.signal.aborted) status("Connexion au moteur interrompue — la conversation reste côté moteur, rouvre le panneau pour reprendre."); }
    running = false; sendBtn.replaceChildren(h("span", { html: ic("send", 16) }), " Envoyer"); stopBtn.hidden = true;
    loadConvs();
    /* DIAG2-CONTEXTE P-CTX-3 : vidange SÉQUENTIELLE des ajouts du dock — chacun part comme son
       propre tour, dans l'ordre écrit, et son exécution est attendue avant le suivant
       (dSteerSend attend déjà la fin de son flux). Leurs réponses vivent dans le fil : on
       recharge le fil après la vidange pour les rendre visibles. */
    if (dSteer.length) {
      const items = dSteer.splice(0);
      status("Envoi des ajouts, un par un…");
      for (const it of items) { await dSteerSend(it); }
      await loadMsgs();
    }
  }
  sendBtn.onclick = send;
  stopBtn.onclick = async () => { try { abortCtl && abortCtl.abort(); } catch (e) {} if (cid) { try { await api.post("/api/chat/stop", { conversation_id: cid }); } catch (e) {} } };
  input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); } });
  /* Le bouton se masque sur l'écran Conversations (le fil y est déjà plein
     écran) et réapparaît sur tous les autres écrans. */
  const syncFab = () => { if (panel.hidden) fab.hidden = onAgentScreen(); };
  try { new MutationObserver(syncFab).observe(document.getElementById("view"), { attributes: true, childList: true, attributeFilter: ["aria-hidden"] }); } catch (e) {}
  syncFab();
  /* LOT WEB v3 : GESTIONNAIRE D'EMPILEMENT DES FLOTTANTS (W-02/W-09).
     Un seul propriétaire des positions du coin bas : mini-lecteur (bas
     gauche), fab (bas droite), lecteur vidéo (bas droite, AU-DESSUS du
     fab), panneau dock (pleine hauteur à droite, fab masqué). Les
     positions sont recalculées sur événements (mutations DOM, resize,
     changement de lecteur) — aucun setInterval, aucun décalage magique.
     Un lecteur vidéo déplacé à la main (dataset.dragged) sort de la pile :
     le gestionnaire ne se bat jamais contre le geste de l'utilisateur. */
  const floatManager = (() => {
    const gap = 12;
    function layout() {
      try {
        const mpEl = document.getElementById("miniplayer");
        const wb = document.getElementById("watchbox");
        const mpVisible = !!(mpEl && mpEl.classList.contains("show"));
        const wbVisible = !!(wb && wb.style.display !== "none" && wb.childElementCount);
        const fabVisible = !fab.hidden && panel.hidden;
        const audioH = mpVisible ? mpEl.offsetHeight + "px" : "0px";
        if (document.documentElement.style.getPropertyValue("--float-audio-h") !== audioH) document.documentElement.style.setProperty("--float-audio-h", audioH);
        if (wbVisible && wb.dataset.dragged !== "1") {
          const wbBottom = (gap + (fabVisible ? fab.offsetHeight + gap : 0)) + "px";
          if (wb.style.bottom !== wbBottom) wb.style.bottom = wbBottom;
          if (wb.style.right !== gap + "px") wb.style.right = gap + "px";
          if (wb.style.top) wb.style.top = "";
          if (wb.style.left) wb.style.left = "";
        }
        if (wbVisible && panel.hidden) fab.hidden = false;   // §51 : pendant une vidéo, l'accès rapide reste visible
      } catch (e) {}
    }
    const mo = new MutationObserver(() => layout());
    mo.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "style", "hidden"] });
    addEventListener("resize", layout);
    bus.on("nova:watch", () => layout());
    bus.on("nova:player-state", () => layout());
    layout();
    return { layout };
  })();
  return { open, close };
})();

boot();
