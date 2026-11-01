/* Module Accueil — l'état du monde en un écran, alimenté par les VRAIES données du moteur :
   /api/state (salutation, briefs non lus, heures calmes), /api/veille/brvm (cours suivis),
   /api/briefs (les derniers briefs, lisibles), /api/drafts (brouillons à approuver),
   /api/vault/status, /api/dots (le parc de Dots : identité, rôle, persona, planning —
   /api/dots/active ne donne que les exécutions en cours, pas le parc), /api/ame/stats
   (miroir d'activité 14 jours). Aucun chiffre inventé : source absente = état vide dit.
   Amendements : n°3 Miroir (tuile 14 jours), n°15 Silence (badge heures calmes),
   n°20/26 Rituels (bouton Brief du matin), n°21/27 Le Vide (bouton + Échap).
   CORRECTIF 20/10/2026 (plainte d'Ahadi : « la présentation du contenu conversation
   est mélangée avec la page d'accueil ») : la conversation de cet écran vivait AU
   MILIEU de la page — bento et ses tuiles au-dessus, « Pendant ton absence », « Tes
   Dots » et le Miroir en dessous. Désormais le fil vit dans une ZONE DÉDIÉE
   (.chat-zone) et dès qu'un échange démarre, l'écran passe en mode « chat-focus » :
   tous les widgets d'accueil (.home-widget) sont masqués, il ne reste QUE le fil,
   la file d'attente, la barre vocale et le composeur — « Retour à l'accueil »
   réaffiche les widgets. Aucun contenu n'est détruit : c'est un masquage CSS. */
import { createOrb, createChat } from "../orb.js";
import { createAttachments } from "../attach.js";
import { createVoice, parseBiChannel, speakable } from "../voice.js";
import { depthControl, depthBody, getDepth } from "../depth.js";
import { presenceAnchor } from "../companion.js";   // 24/10 : le héros réserve la place, l'unique compagnon s'y pose
import { mountPlush } from "../plush.js";
import { fmtNumFR, fmtDateFR, fmtTimeFR, fmtRelFR, cleanResume, sse, stateErrorNode, phaseLabel, voixLabel, txtPropre } from "../core.js";

const arrOf = (j, ...keys) => {
  if (Array.isArray(j)) return j;
  for (const k of keys) if (j && Array.isArray(j[k])) return j[k];
  return [];
};
const fmtN = (n) => fmtNumFR(Number(n) || 0);
const fmtDate = (v) => {
  if (!v) return "";
  const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v);
  return isNaN(d) ? String(v).slice(0, 16) : fmtDateFR(d) + " · " + fmtTimeFR(d);
};
/* Chiffre qui roule : interpolation douce de la valeur affichée (texte seul, ~550 ms). */
function rollNum(el, to, fmt) {
  /* A-25 / DS §9.8 : un roulement ne joue qu'ENTRE DEUX VALEURS RÉELLES CONNUES
     (rafraîchissement). Sans valeur précédente (premier rendu), la valeur finale
     formatée est posée d'emblée — jamais d'animation depuis un faux « 0 ». */
  if (el.dataset.v == null || el.dataset.v === "") { el.dataset.v = String(to); el.textContent = fmt(to); return; }
  const from = parseFloat(String(el.dataset.v || "0")) || 0;
  el.dataset.v = String(to);
  if (from === to) { el.textContent = fmt(to); return; }
  const t0 = performance.now(), dur = 550;
  (function step(t) {
    const k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
    el.textContent = fmt(from + (to - from) * e);
    if (k < 1 && el.isConnected) requestAnimationFrame(step);
  })(t0);
}

export async function mount(root, ctx) {
  const { api, bus, esc, h, ic } = ctx;
  let dead = false;
  let heroRetryTimer = 0, heroRetries = 0;
  const offs = [];
  const on = (t, f) => { const off = bus.on(t, f); offs.push(off); return off; };

  const today = new Intl.DateTimeFormat("fr-FR", { weekday: "long", day: "numeric", month: "long" }).format(new Date());
  const homeHead = h("div", { class: "mod-head home-widget" },
    h("h1", {}, "Accueil"),
    h("span", { class: "sub" }, today),
    h("span", { class: "sp" }),
    h("button", { class: "btn", title: "Tout masquer sauf Nova — Échap pour revenir", onclick: () => openVide() }, h("span", { html: ic("moon", 15) }), "Le Vide"),
    h("button", { class: "btn", onclick: () => bus.emit("nova:palette") }, "Rechercher ", h("span", { class: "kbd" }, "⌘K")));
  root.append(homeHead);

  /* ── Bento dense : 12 colonnes × 3 rangées, aucune case vide ─────────── */
  /* NOVA2 (vague 2, item 1) : la présence centrale n'est plus l'orbe CSS seule — c'est
     l'AVATAR AIMÉ restauré (avatar.js : le panda 3D de Nova 1 par défaut, le Cœur
     Singularity en option, l'orbe CSS en socle et en repli). createChat le pilote comme
     l'orbe (setState repos/écoute/réflexion/parole, niveau audio réel). */
  const orb = presenceAnchor(ctx, { slot: "hero", px: 190 });
  const say = h("div", { class: "hero-say" }, "…");
  const heroMeta = h("div", { class: "ss hero-meta" }, "");
  const heroSub = h("div", { class: "hero-sub" }, "");
  const heroChips = h("div", { class: "hero-chips" });
  /* A-10 / DS §9.2 : le second champ de saisie du héros est SUPPRIMÉ — il n'existe
     qu'UN endroit pour écrire, le composeur unique de la zone conversation (§6.14).
     Le héros garde présence, salutation et chips d'actions. */
  const finBody = h("div", { class: "grow" }, h("div", { class: "skel", style: "height:64px" }));
  const briefBody = h("div", { class: "grow" }, h("div", { class: "skel", style: "height:64px" }));
  const msgBody = h("div", { class: "grow" }, h("div", { class: "skel", style: "height:20px;width:70%" }));
  const audioBody = h("div", { class: "grow" }, h("div", { class: "ss", style: "color:var(--ink-2)" }, "Radios, podcasts et TV — le mini-lecteur garde l'écoute quand tu changes d'écran."));
  const vaultBody = h("div", { class: "grow" }, h("div", { class: "skel", style: "height:20px;width:60%" }));

  const bento = h("div", { class: "bento" },
    h("section", { class: "card tile t-hero" },
      h("div", { class: "hero-flex" },
        orb,
        h("div", { class: "grow" }, say, heroMeta, heroSub, heroChips,
          h("div", { class: "hero-actions" },
            h("button", { class: "btn ambre", onclick: async (e) => { const btn = e.currentTarget; async function runBrief() { btn.disabled = true; btn.textContent = "Lancement…"; try { await api.post("/api/briefs/run", {}); ctx.toast("Brief du matin lancé."); await loadBriefs(); } catch (err) { heroChips.replaceChildren(stateErrorNode("Échec du lancement du brief", err, runBrief, h)); } finally { if (btn.isConnected) { btn.disabled = false; btn.replaceChildren(h("span", { html: ic("brief", 15) }), "Brief du matin"); } } } await runBrief(); } }, h("span", { html: ic("brief", 15) }), "Brief du matin"),
            h("button", { class: "btn", onclick: async (e) => { const btn = e.currentTarget; async function runRefresh() { btn.disabled = true; btn.textContent = "Rafraîchissement…"; try { await api.post("/api/portfolio/refresh", {}); ctx.toast("Cours rafraîchis."); await loadFinance(); } catch (err) { finBody.replaceChildren(stateErrorNode("Rafraîchissement impossible", err, runRefresh, h)); } finally { if (btn.isConnected) { btn.disabled = false; btn.textContent = "Rafraîchir"; } } } await runRefresh(); } }, "Rafraîchir"),
            h("button", { class: "btn ghost", onclick: () => ctx.navigate("veille") }, "Ouvrir la Veille", h("span", { html: ic("arrow-up-right", 14) })))))),
    h("button", { class: "card tile t-fin", onclick: () => ctx.navigate("finance") },
      h("span", { class: "tile-chev", html: ic("chev-r", 16) }),
      h("h3", {}, h("span", { html: ic("chart", 16) }), "Finance · BRVM"), finBody),
    h("section", { class: "card tile t-briefs" },
      h("h3", {}, h("span", { html: ic("brief", 16) }), "Derniers briefs"),
      briefBody),
    h("button", { class: "card tile t-msg", onclick: () => ctx.navigate("messages") },
      h("span", { class: "tile-chev", html: ic("chev-r", 16) }),
      h("h3", {}, h("span", { html: ic("talk", 16) }), "Messages"), msgBody),
    h("button", { class: "card tile t-audio", onclick: () => ctx.navigate("radio") },
      h("span", { class: "tile-chev", html: ic("chev-r", 16) }),
      h("h3", {}, h("span", { html: ic("radio", 16) }), "Médias"), audioBody),
    h("button", { class: "card tile t-vault", onclick: () => ctx.navigate("vault") },
      h("span", { class: "tile-chev", html: ic("chev-r", 16) }),
      h("h3", {}, h("span", { html: ic("lock", 16) }), "Coffre"), vaultBody));
  bento.classList.add("home-widget");
  root.append(bento);

  /* ── Conversation ──────────────────────────────────────────────────── */
  const log = h("div", { class: "chatlog" });
  const input = h("textarea", { rows: "2", placeholder: "Écris à Nova… (Entrée pour envoyer, Maj+Entrée pour une ligne)", "aria-label": "Message" });
  let depth = getDepth();   // n°14 : profondeur réelle du moteur (depth + mode deep)
  /* Conversation naturelle (chantier conversation) : l'état vocal vit ICI, pas dans le
     composeur. La dictée (micro du composeur) tombe dans le champ et se relit avant
     envoi — elle ne marque donc pas le tour comme vocal. lastVoice mémorise le mode
     du tour en cours pour la lecture de SA réponse. */
  let voiceMode = false, lastVoice = false;
  let readAloud = false; try { readAloud = localStorage.getItem("nova2_voice_read") === "1"; } catch (e) {}
  const chat = createChat({ log, orb, extra: () => { const v = voiceMode; lastVoice = v; return { ...depthBody(depth), ...(v ? { voice: true } : {}) }; }, onTool: (d) => {
    const last = log.querySelector(".msg.nova:last-child");
    if (last && d && d.name) last.append(h("div", { class: "ss" }, "Outil : " + d.name));
  }, onDone: ({ text }) => {
    /* Lecture de la réponse : seulement si « Lire les réponses » est actif ou si le tour
       était vocal. En mode vocal le moteur répond en bi-canal : seul <PARLE> est lu ;
       sinon on lit le texte nettoyé du markdown d'écran (speakable). */
    if (dead || !(readAloud || voiceMode || lastVoice)) return;
    const p = parseBiChannel(text || "");
    const say = (p.bic ? p.parle : speakable(text || "")).slice(0, 1200);
    if (say) voice.speak(say).catch((e) => ctx.toast(String((e && e.message) || e), true));
  } });
  /* Pièces jointes (attach.js) : trombone = fichiers, bouton couches = dossier entier,
     glisser-déposer sur le fil, coller dans le champ. L'envoi au moteur (avec progression)
     précède le message ; un échec est nommé et RIEN ne part en silence. */
  const att = createAttachments();
  /* Composeur UNIQUE (DS §6.14) — même anatomie que l'Agent et le panneau :
     [.att-bar] [.composer-row : Joindre (menu fichiers/dossier) · micro-dictée ·
     textarea .fld-area · Envoyer] [.vrow : Conversation vocale · ⏸ (parole) · état].
     Joindre et pièces jointes réutilisent attach.js comme avant ; la dictée tombe
     DANS LE CHAMP (on relit avant d'envoyer, choix §22 généralisé). */
  const attMenu = h("div", { class: "cs-att-menu", hidden: true },
    h("button", { onclick: () => { attMenu.hidden = true; att.btn.click(); } }, h("span", { html: ic("attach", 15) }), "Joindre des fichiers…"),
    h("button", { onclick: () => { attMenu.hidden = true; att.dirBtn.click(); } }, h("span", { html: ic("layers", 15) }), "Joindre un dossier entier…"));
  const attBtn = h("button", { class: "btn icon-lg", title: "Joindre des fichiers ou un dossier", "aria-label": "Joindre", html: ic("attach", 19),
    onclick: () => { attMenu.hidden = !attMenu.hidden; } });
  const attWrap = h("div", { class: "cs-att-wrap" }, attBtn, attMenu);
  const onDocClickDots = (e) => { if (!attWrap.contains(e.target)) attMenu.hidden = true; };
  document.addEventListener("click", onDocClickDots);
  offs.push(() => document.removeEventListener("click", onDocClickDots));
  input.classList.add("fld");
  const micBtn = h("button", { class: "btn icon-lg", title: "Dicter (micro) — clique, parle, reclique : le texte tombe dans le champ", "aria-label": "Dicter", html: ic("mic", 19) });
  const composerRow = h("div", { class: "composer-row" },
    h("div", { class: "composer-tools" }, attWrap, micBtn),
    input,
    h("button", { class: "btn acc", onclick: () => submitMain() }, h("span", { html: ic("send", 16) }), " Envoyer"));
  const composer = h("div", { class: "composer" }, att.bar, composerRow);
  /* ── Barre de conversation vocale (chantier conversation) ──────────────
     Volontairement HORS du composeur (pièces jointes) : une rangée sobre au-dessus.
     Dicter = push-to-talk (micro → /api/stt → le texte part comme un message vocal) ;
     Lire = Nova lit ses réponses ; Conversation = tous les tours partent en mode vocal
     (réponses bi-canal courtes, lues) ; le bouton pause + taper dans un champ + cliquer
     l'avatar coupent la parole (barge-in). L'état affiche le moteur réel (en-tête
     X-Nova-Voice) et les latences MESURÉES — jamais des promesses. */
  const vstate = h("span", { class: "vstate" }, "Voix : voix système du Mac (ou repli nommé).");
  const vLire = h("button", { class: "btn sm vbtn" + (readAloud ? " on" : ""), title: "Nova lit ses réponses à voix haute" },
    h("span", { html: ic("volume", 15) }), "Lire les réponses");
  const vConv = h("button", { class: "btn sm vbtn", title: "Mode conversation : demandes et réponses à l'oral, phrases courtes" },
    h("span", { html: ic("talk", 15) }), "Conversation vocale");
  const vStop = h("button", { class: "btn icon", title: "Couper la parole de Nova", "aria-label": "Couper la parole", hidden: true, html: ic("pause", 15),
    onclick: () => voice.stopSpeaking() });
  const voicebar = h("div", { class: "vrow" }, vConv, vLire, vStop, vstate);
  const voice = createVoice({
    onLevel: (v) => { if (orb && orb.setLevel) orb.setLevel(v); },
    onEngine: (e) => { if (!dead && e) vstate.textContent = "Voix : " + voixLabel(e) + ".";
    },
    onLatency: () => { /* mesures de latence : jamais dans la .vrow (DS §6.14) — l'état voix reste un libellé court. */ },
    onState: (st) => { vStop.hidden = st !== "parole"; },
  });
  vLire.onclick = () => { readAloud = !readAloud; vLire.classList.toggle("on", readAloud); try { localStorage.setItem("nova2_voice_read", readAloud ? "1" : "0"); } catch (e) {} if (!readAloud) voice.stopSpeaking(); };
  vConv.onclick = () => { voiceMode = !voiceMode; vConv.classList.toggle("on", voiceMode); if (!voiceMode) voice.stopSpeaking(); ctx.toast(voiceMode ? "Conversation vocale : parle ou écris, Nova répond à voix haute, en phrases courtes." : "Conversation vocale coupée."); };
  micBtn.onclick = async () => {
    if (voice.isListening()) {
      micBtn.classList.remove("rec");
      try {
        const t = await voice.listenStop();
        if (dead) return;
        if (t && t.trim()) {
          const cur = input.value;
          input.value = (cur && !/\s$/.test(cur) ? cur + " " : cur) + t.trim();
          input.focus();
        }
      } catch (e) { ctx.toast(String((e && e.message) || e), true); }
      if (orb) orb.setState("repos");
      return;
    }
    voice.stopSpeaking();
    try {
      await voice.listenStart();
      micBtn.classList.add("rec");
      if (orb) orb.setState("ecoute");
    } catch (e) { ctx.toast("Micro : " + String((e && e.message) || e), true); }
  };
  orb.addEventListener("click", () => { if (voice.isSpeaking()) voice.stopSpeaking(); });
  /* Barge-in par la frappe : dès qu'Ahadi tape dans un champ, Nova se tait. */
  const bargeIn = () => { if (voice.isSpeaking()) voice.stopSpeaking(); };
  input.addEventListener("keydown", bargeIn);
  /* Zone conversation ISOLÉE : fil + profondeur + pièces + voix + composeur,
     et RIEN d'autre. La barre de focus n'existe qu'en mode conversation. */
  const focusBar = h("div", { class: "chat-focus-bar" },
    h("span", { class: "tt" }, "Conversation"),
    h("span", { class: "sp" }),
    h("button", { class: "btn", onclick: () => setChatFocus(false) }, "Retour à l'accueil"));
  const depthCtl = depthControl((id) => { depth = id; });
  const depthShare = h("div", { class: "ss" }, "Réglage partagé entre l'Accueil et Conversations.");
  const chatZone = h("div", { class: "chat-zone" }, focusBar, depthCtl, depthShare, log,
    composer, voicebar);
  root.append(chatZone);
  function setChatFocus(on) {
    root.classList.toggle("chat-focus", !!on);
    if (on) { try { chatZone.scrollIntoView({ block: "start" }); } catch (e) {} }
  }
  att.attachTo(log, input);
  log.addEventListener("nova:att-rejected", (e) => { (e.detail || []).forEach((m) => ctx.toast(m, true)); });
  let attSending = false;
  async function submitMain() {
    const t = input.value;
    if (attSending || (!t.trim() && !att.count())) return;
    if (!att.count()) { if (chat.send(t)) { input.value = ""; setChatFocus(true); } return; }
    /* File d'attente (createChat) : même pendant une génération, le message et ses
       pièces sont acceptés et partent dans l'ordre — plus de refus « répond encore ». */
    attSending = true;
    try {
      await att.uploadPending();
      const desc = att.take();
      if (await chat.send(t, desc)) { input.value = ""; setChatFocus(true); }
      else ctx.toast("Envoi refusé — réessaie (les fichiers sont déjà chez Nova).", true);
    } catch (e) { ctx.toast("Pièce jointe : " + String((e && e.message) || e), true); }
    finally { attSending = false; }
  }
  input.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submitMain(); } });
  on("nova:ask", (d) => { if (d && d.text && chat.send(d.text)) setChatFocus(true); });

  /* ── Pendant ton absence (vague 2, item 10) : le compte rendu au retour ──
     La coquille mémorise la dernière fois que Nova a été vue (localStorage, posé par
     shell.js À CHAQUE démarrage) ; si l'écart dépasse 30 minutes, on montre ce que les
     Dots ont fait depuis : passages (historique du moteur, borné à ses 30 derniers),
     réussites/échecs, et décisions en attente (Vu / Plus tard). Limite dite dans la
     carte : le moteur tourne dans l'app — fermée, rien ne passe, et rien n'est inventé. */
  const absenceBox = h("div", { class: "home-widget" });
  root.append(absenceBox);

  /* ── Tes Dots : des entités VIVANTES (vague 2, item 5) ─────────────────
     Chaque Dot est une peluche animée (plush.js, le système de Nova 1) dont la phase
     dit l'état réel, dans le vocabulaire UNIQUE du CSS (plush.js) : actif (en
     cours, /api/dots/active), attente (une décision t'attend, /api/dots/waiting),
     pause (en pause), erreur (dernier passage en échec, /api/dots), repos (rien
     à signaler — rien ne bouge). Les phases du bus moteur (working/ready/idle)
     sont traduites à l'arrivée, jamais posées telles quelles.
     FUSION DOTS (22/10) : l'écran unique est « Dots » (module agents) — le
     widget pointe juste, l'ancien bouton « Automatisations » a disparu avec
     l'écran fusionné. */
  const dotsBox = h("div", {},
    h("div", { class: "sec-head" },
      h("h2", { class: "sec-title" }, "Tes Éclats"),
      h("span", { class: "ss", id: "dots-count" }, ""),
      h("span", { class: "mod-actions" },
        h("button", { class: "btn", onclick: () => ctx.navigate("dots") }, "Ouvrir les Éclats"))));
  const decisionBox = h("div", {});
  const dotsList = h("div", { class: "dots-plush dots-grid" });
  const waitBox = h("div", { style: "margin-top:10px" });
  dotsBox.classList.add("home-widget");
  dotsBox.append(decisionBox, dotsList, waitBox);
  root.append(dotsBox);
  let plushes = [];
  /* Registre id → { p, apply } : permet au bus nova:dot-run de changer la phase
     d'UNE peluche à l'instant du signal moteur, sans recharger la liste. */
  let plushById = new Map();
  const clearPlushes = () => { plushes.forEach((p) => { try { p.dispose(); } catch (e) {} }); plushes = []; plushById = new Map(); };

  root.append(h("button", { class: "mirror-link home-widget", onclick: () => ctx.navigate("ame") }, "Miroir — 14 jours ", h("span", { html: ic("chev-r", 12) }), " Âme"));

  /* ── Le Vide (amendements n°21/27) : tout disparaît sauf l'orbe endormie ── */
  let videEl = null;
  function openVide() {
    if (videEl) return;
    const o = createOrb("lg"); o.setState("repos");
    videEl = h("div", { class: "vide", role: "dialog", "aria-label": "Le Vide — Échap pour revenir" },
      h("div", { class: "vide-orb" }, o),
      h("div", { class: "vide-hint" }, "Le Vide — Échap ou un clic pour revenir."));
    videEl.addEventListener("click", closeVide);
    document.body.append(videEl);
    requestAnimationFrame(() => videEl && videEl.classList.add("on"));
  }
  function closeVide() { if (videEl) { videEl.remove(); videEl = null; } }
  const onKey = (e) => { if (e.key === "Escape") closeVide(); };
  addEventListener("keydown", onKey);
  offs.push(() => removeEventListener("keydown", onKey));

  /* ── Chargements ───────────────────────────────────────────────────── */
  async function loadHero() {
    try {
      const st = await api.get("/api/state"); if (dead) return;
      const s = (st && st.settings) || {};
      const name = s.user_title || s.name || "";
      const hour = new Date().getHours();
      const greet = hour < 12 ? "Bonjour" : hour < 18 ? "Bon après-midi" : "Bonsoir";
      say.textContent = greet + (name ? ", " + name : "") + ".";
      const parts = [];
      if (st && st.unread_briefs) parts.push(st.unread_briefs + " brief(s) non lu(s)");
      heroSub.textContent = parts.length ? "En attente : " + parts.join(" · ") + "." : "Rien d'urgent ne se signale. Dis-moi ce qu'on avance.";
      const chips = [];
      const brains = arrOf(st, "brains");
      /* FIXPREP D-R2 : source primaire = compteurs servis par /api/state
         (Lot 2 P-E5, App.swift) ; les lignes ne servent qu'en repli, avec le
         libellé réellement servi dans `etat` (« prêt »), jamais le compteur
         entier `ok` ni l'ancien code interne "ok". */
      const hasTotal = !!st && st.brains_total != null && isFinite(Number(st.brains_total));
      const hasReady = !!st && st.brains_prets != null && isFinite(Number(st.brains_prets));
      const total = hasTotal ? Number(st.brains_total) : brains.length;
      const readyFromRows = brains.filter((b) => b && (b.etat === "prêt" || b.etat === "ok")).length;
      const ready = hasReady ? Number(st.brains_prets) : (brains.length ? readyFromRows : null);
      const pending = brains.some((b) => b && b.etat === "inconnu");
      const brainsKnown = !!(total && ready != null);
      const brainsMeta = !brainsKnown ? "" : (pending ? "Cerveaux : diagnostic en cours — " + ready + "/" + total + " prêts pour le moment" : "Cerveaux : " + ready + "/" + total + " prêts");
      if (st && st.quiet) {
        chips.push(h("span", { class: "chip" }, "Heures calmes — Nova ne dérange pas"));
        heroMeta.textContent = brainsMeta;
      } else if (!brainsKnown) {
        chips.push(h("span", { class: "chip warn" }, "Cerveaux : état inconnu"));
        heroMeta.textContent = "";
      } else if (ready === 0) {
        chips.push(h("span", { class: "chip warn" }, "Cerveaux : 0/" + total + " prêts — aucun disponible"));
        heroMeta.textContent = "";
      } else {
        heroMeta.textContent = brainsMeta;
      }
      clearTimeout(heroRetryTimer);
      if (pending && heroRetries < 6) {
        heroRetries++;
        heroRetryTimer = setTimeout(() => { if (!dead) loadHero(); }, 10000);
      } else if (!pending) heroRetries = 0;
      heroChips.replaceChildren(...chips);
    } catch (e) { if (!dead) { const hr = new Date().getHours(); say.textContent = (hr < 12 ? "Bonjour" : hr < 18 ? "Bon après-midi" : "Bonsoir") + "."; heroSub.textContent = "Moteur injoignable — l'interface fonctionne ; les données reviendront avec le moteur."; heroMeta.textContent = ""; heroChips.replaceChildren(stateErrorNode("État du moteur injoignable", e, loadHero, h)); } }
  }
  async function loadFinance() {
    try {
      const j = await api.get("/api/veille/brvm"); if (dead) return;
      const quotes = arrOf(j, "quotes");
      const watch = (j && j.watch) || [];
      const rows = (watch.length ? quotes.filter((q) => watch.includes(q.sym)) : quotes).slice(0, 4);
      if (!rows.length) { finBody.replaceChildren(h("div", { class: "ss", style: "color:var(--ink-2)" }, "Aucun cours suivi — ajoute des symboles dans Finance.")); return; }
      finBody.replaceChildren(...rows.map((q) => {
        const pv = Number(q.price) || 0;
        const price = h("span", { class: "num fin-price" }, pv ? fmtN(pv) : "—");
        if (pv) rollNum(price, pv, fmtN);
        return h("div", { class: "row-item", style: "border:0;padding:5px 0" },
          h("div", { class: "grow" }, h("span", { class: "tt" }, String(q.sym)), h("span", { class: "ss" }, " " + String(q.name || ""))),
          price,
          h("span", { class: (Number(q.var) >= 0 ? "up" : "down") + " num" }, (() => { const v = Number(q.var); return isFinite(v) ? (v >= 0 ? "+" : "") + v.toFixed(2).replace(".", ",") + " %" : "—"; })()));
      }), h("div", { class: "ss" },
        "Séance : " + (j.quotes_at ? fmtDate(j.quotes_at) : "—") + " · source brvm.org (bandeau public, peut être différé)"));
    } catch (e) { if (!dead) finBody.replaceChildren(stateErrorNode("Cours injoignables pour le moment", e, loadFinance, h)); }
  }
  async function loadBriefs() {
    try {
      const j = await api.get("/api/briefs"); if (dead) return;
      const items = arrOf(j, "items", "briefs");
      if (!items.length) { briefBody.replaceChildren(h("div", { class: "ss", style: "color:var(--ink-2)" }, "Aucun brief pour le moment — le bouton « Brief du matin » de la tuile principale en génère un.")); return; }
      briefBody.replaceChildren(...items.slice(0, 3).map((b) => {
        const unread = b.read !== true;
        const dot = h("span", { class: "dotst " + (unread ? "warn" : "idle") });
        const row = h("div", { class: "row-item", style: "border:0;padding:6px 0;cursor:pointer", title: "Ouvrir dans Veille" },
          dot,
          h("div", { class: "grow" },
            h("div", { class: "tt" }, String(b.title || b.kind || "Brief")),
            h("div", { class: "ss" }, fmtDate(b.at || b.date || b.created || b.ts) + (b.summary ? " — " + String(b.summary).slice(0, 90) : ""))));
        let markBtn = null;
        async function markRead() {
          if (b.id) { try { await api.post("/api/briefs/read", { id: b.id }); } catch (e) {} }
          dot.className = "dotst idle";
          if (markBtn && markBtn.isConnected) markBtn.remove();
          ctx.toast("Brief marqué comme lu");
          loadHero();
        }
        if (unread) {
          markBtn = h("button", { class: "btn ghost sm", style: "font-size:11px", onclick: (e) => { e.stopPropagation(); markRead(); } }, "Marquer lu");
          row.append(markBtn);
        }
        row.addEventListener("click", async () => {
          if (unread) { await markRead(); }
          ctx.navigate("veille");
          setTimeout(() => bus.emit("nova:brief-focus", { id: b.id }), 350);
        });
        return row;
      }));
    } catch (e) { if (!dead) briefBody.replaceChildren(stateErrorNode("Briefs injoignables pour le moment", e, loadBriefs, h)); }
  }
  async function loadMessages() {
    try {
      const j = await api.get("/api/drafts"); if (dead) return;
      const drafts = arrOf(j, "drafts", "items");
      const first = drafts[0];
      msgBody.replaceChildren(h("div", { class: "big" }, drafts.length ? drafts.length + " brouillon(s)" : "À jour"),
        h("div", { class: "ss", style: "color:var(--ink-2)" }, drafts.length
          ? "En attente de ton approbation" + (first ? " — le dernier : " + String(first.to || first.dest || "destinataire ?") : "") + "."
          : "Aucun brouillon en attente d'approbation."));
    } catch (e) { if (!dead) msgBody.replaceChildren(stateErrorNode("Brouillons injoignables pour le moment", e, loadMessages, h)); }
  }
  async function loadVault() {
    try {
      const j = await api.get("/api/vault/status"); if (dead) return;
      const locked = j && (j.locked === true || j.state === "locked" || j.unlocked === false);
      vaultBody.replaceChildren(h("div", { class: "big" }, locked ? "Portefeuille — coffre verrouillé" : "Ouvert"),
        h("div", { class: "ss", style: "color:var(--ink-2)" }, locked ? "Les cours BRVM publics restent visibles à l'Accueil." : "Pense à le refermer en partant."));
    } catch (e) { if (!dead) vaultBody.replaceChildren(stateErrorNode("État du coffre injoignable pour le moment", e, loadVault, h)); }
  }
  async function loadDots() {
    try {
      const j = await api.get("/api/dots"); if (dead) return;
      const dots = arrOf(j, "items", "dots");
      const runs = arrOf(j, "runs");
      let activeIds = new Set(), waitingIds = new Set(), phaseErr = null;
      try { const a = await api.get("/api/dots/active"); if (!dead) arrOf(a, "items", "runs", "active").forEach((r) => { const id = typeof r === "string" ? r : (r && (r.dot_id || (r.dot && r.dot.id) || (typeof r.dot === "string" ? r.dot : "") || r.id)); if (id) activeIds.add(String(id)); }); /* LOT1-FIX M10 : /api/dots/active sert des identifiants CHAÎNES (DotPacks.activeIds) — les lire comme des objets laissait activeIds toujours vide. */ } catch (e) { phaseErr = e; }
      let waiting = [];
      try { const w = await api.get("/api/dots/waiting"); if (!dead) { waiting = arrOf(w, "items", "waiting"); waiting.forEach((x) => { if (x && x.dot) waitingIds.add(String(x.dot)); }); } } catch (e) { phaseErr = phaseErr || e; }
      const cnt = dotsBox.querySelector("#dots-count");
      if (cnt) cnt.textContent = dots.length ? dots.length + " Éclat(s) dans ton parc" + (activeIds.size ? " · " + activeIds.size + " en cours" : "") + (waiting.length ? " · " + waiting.length + " en attente de décision" : "") : "";
      clearPlushes();
      /* Dernier run par Dot (l'historique est servi du plus récent au plus ancien). */
      const lastRun = {};
      for (const r of runs) { const rid = String((r && (r.dot || r.dot_id)) || ""); if (rid && !lastRun[rid]) lastRun[rid] = r; }
      /* Vocabulaire UNIQUE (celui du CSS, plush.js) : actif / attente / pause /
         erreur / repos. Priorité : un signal du moment (en cours, décision)
         prime le passé (échec), qui prime le repos. */
      /* PHASE_LBL : table unique dans core.js (phaseLabel) — U6 23/10. */
      const PHASE_ST = { actif: "run", attente: "warn", pause: "warn", erreur: "err", repos: "idle" };
      const phaseOf = (d) => {
        const id = String(d.id);
        if (activeIds.has(id)) return "actif";
        if (waitingIds.has(id)) return "attente";
        if (d.paused) return "pause";
        const lr = lastRun[id];
        if (lr && (lr.ok === false || String(lr.status || "").toUpperCase() === "ECHEC")) return "erreur";
        return "repos";
      };
      const order = { attente: 0, actif: 1, erreur: 2, pause: 3, repos: 4 };
      const withPhase = dots.map((d, i) => ({ d, i, phase: phaseOf(d) }));
      withPhase.sort((a, b) => (order[a.phase] - order[b.phase]) || (a.i - b.i));
      const shown = withPhase.slice(0, 6);
      const cards = shown.map(({ d, phase }) => {
        const lr = lastRun[String(d.id)];
        const stDot = h("span", { class: "dotst " + PHASE_ST[phase] });
        const stTxt = h("span", {}, phaseLabel(phase, "État inconnu") + (d.schedule ? " · " + txtPropre(d.schedule) : ""));
        const act = h("span", { class: "dot-plush-act", hidden: !lr }, "Relancer");
        const card = h("div", { class: "dot-plush-card", role: "button", tabindex: "0", title: "Lancer cet Éclat" },
          h("div", { class: "dot-plush-face" }),
          h("div", { class: "tt dot-plush-name" }, String(d.name || d.id || "Éclat")),
          h("div", { class: "dot-plush-state" }, stDot, stTxt),
          h("div", { class: "ss dot-plush-last" }, lr ? "Dernier passage : " + fmtRelFR(lr.ts || lr.at || lr.date) : "Dernier passage : jamais"),
          act);
        async function runDot() {
          const nom = String(d.name || d.id || "Éclat");
          if (card.getAttribute("aria-busy") === "true") return;
          card.setAttribute("aria-busy", "true");
          stTxt.textContent = "En cours…";
          const rec0 = plushById.get(String(d.id)); if (rec0) rec0.apply("actif");
          try {
            await sse("/api/dots/run", { id: d.id }, (ev, data) => {
              if (ev === "brain" && data && data.label) ctx.toast("Éclat « " + nom + " » lancé — cerveau : " + data.label);
              else if (ev === "error") throw new Error((data && data.message) || "erreur du moteur pendant l'exécution");
              else if (ev === "tool" && window.__novaPresence) window.__novaPresence("tool", "Éclat « " + nom + " » au travail…");
            });
            ctx.toast("Éclat « " + nom + " » terminé.");
            if (window.__novaPresence) window.__novaPresence("done", "Éclat « " + nom + " » terminé");
            act.hidden = false;
          } catch (err) {
            ctx.toast("Éclat « " + nom + " » : " + String((err && err.message) || err), true);
          } finally {
            card.removeAttribute("aria-busy");
            if (!dead) { loadDots(); loadAbsence(); }
          }
        }
        card.addEventListener("click", () => { runDot(); });
        card.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); runDot(); } });
        const p = mountPlush(card.querySelector(".dot-plush-face"), String(d.color || "#FF7A29"), 56, String(d.id || ""), "");
        p.setPhase(phase);
        plushes.push(p);
        plushById.set(String(d.id), {
          p,
          base: () => phaseOf(d),
          apply: (ph) => { try { p.setPhase(ph); stTxt.textContent = phaseLabel(ph, "État inconnu") + (d.schedule ? " · " + txtPropre(d.schedule) : ""); stDot.className = "dotst " + (PHASE_ST[ph] || "idle"); } catch (e) {} },
        });
        return card;
      });
      if (dots.length > 6) cards.push(h("button", { class: "dot-plush-card dots-more", onclick: () => ctx.navigate("dots") }, "+" + (dots.length - 6) + " autres → Ouvrir les Éclats"));
      dotsList.replaceChildren(...(dots.length ? cards : [h("div", { class: "empty" }, "Aucun Éclat dans le parc — ouvre l'écran Éclats pour installer un pack.")]));
      if (waiting.length) decisionBox.replaceChildren(h("div", { class: "card card--decision", style: "display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:10px" }, h("span", { class: "grow" }, waiting.length + " exécution(s) en attente de ta décision"), h("button", { class: "btn", onclick: () => ctx.navigate("dots") }, "Voir les décisions")));
      else decisionBox.replaceChildren();
      waitBox.replaceChildren(...(phaseErr ? [stateErrorNode("Phases des Éclats injoignables — les états affichés peuvent être incomplets", phaseErr, loadDots, h)] : []));
    } catch (e) { if (!dead) { clearPlushes(); dotsList.replaceChildren(stateErrorNode("Parc de Éclats injoignable pour le moment", e, loadDots, h)); } }
  }
  async function loadAbsence() {
    const prev = Number(window.__novaPrevSeen || 0);
    if (!prev || Date.now() - prev < 30 * 60 * 1000) { absenceBox.replaceChildren(); return; }
    try {
      const j = await api.get("/api/dots"); if (dead) return;
      const dots = arrOf(j, "items", "dots");
      const nameOf = (id) => { const d = dots.find((x) => String(x.id) === String(id)); return d ? String(d.name || id) : String(id || "Éclat"); };
      const runs = arrOf(j, "runs").filter((r) => { const t = new Date(r.ts || r.at || r.date || 0).getTime(); return t && t > prev; });
      let waiting = [];
      let waitingErr = null;
      try { const w = await api.get("/api/dots/waiting"); if (!dead) waiting = arrOf(w, "items", "waiting"); } catch (e) { waitingErr = e; }
      if (waitingErr) { absenceBox.replaceChildren(h("div", { class: "sec-head" }, h("h2", { class: "sec-title" }, "Pendant ton absence")), stateErrorNode("Décisions en attente injoignables pour le moment", waitingErr, loadAbsence, h)); return; }
      if (!runs.length && !waiting.length) {
        absenceBox.replaceChildren(h("div", { class: "sec-head" }, h("h2", { class: "sec-title" }, "Pendant ton absence")),
          h("div", { class: "card flat" }, h("span", { style: "color:var(--ink-2)" }, "Tu étais absent depuis " + fmtDate(prev) + " — aucun Éclat n'a tourné sur la période couverte par l'historique du moteur (30 derniers passages). Le moteur ne tourne que dans l'app ouverte : fermée, il attend, il ne simule rien.")));
        return;
      }
      const runRow = (r) => {
        const bad = r.ok === false || /err|fail|éch/i.test(String(r.status || ""));
        return h("div", { class: "row-item" },
          h("span", {}, bad ? "🔴" : "🟢"),
          h("div", { class: "grow" }, h("div", { class: "tt" }, nameOf(r.dot || r.dot_id) + " — " + fmtDate(r.ts || r.at) + ((r.usage_in || r.usage_out) ? " · ~" + fmtNumFR((r.usage_in || 0) + (r.usage_out || 0)) + " jetons" : " · jetons inconnus")),
            h("div", { class: "ss", style: "white-space:normal" }, cleanResume(r.summary || r.result || r.error || r.status || "Terminé."))));
      };
      absenceBox.replaceChildren(
        h("div", { class: "sec-head" }, h("h2", { class: "sec-title" }, "Pendant ton absence"),
          h("span", { class: "ss" }, "depuis " + fmtDate(prev) + " · " + runs.length + " passage(s), " + waiting.length + " décision(s) en attente")),
        h("div", { class: "card flat" },
          ...(runs.length ? runs.slice(0, 8).map(runRow) : [h("div", { class: "ss", style: "color:var(--ink-2)" }, "Aucun passage de Éclat pendant l'absence (dans l'historique exposé par le moteur).")]),
          ...waiting.map((w) => h("div", { class: "row-item" },
            h("span", {}, "🟡"),
            h("div", { class: "grow" }, h("div", { class: "tt" }, String(w.name || nameOf(w.dot)) + " attend ta décision"),
              h("div", { class: "ss", style: "white-space:normal" }, cleanResume(w.summary || w.question || ""))),
            h("button", { class: "btn", onclick: async () => { try { await api.post("/api/dots/ack", { run_id: w.run_id }); ctx.toast("Marqué comme vu."); loadAbsence(); } catch (e) { ctx.toast("Action impossible.", true); } } }, "Vu"),
            h("button", { class: "btn", onclick: async () => { try { await api.post("/api/dots/snooze", { run_id: w.run_id, minutes: 60 }); ctx.toast("Reporté d'une heure."); loadAbsence(); } catch (e) { ctx.toast("Report impossible.", true); } } }, "Plus tard"))),
          h("div", { class: "ss", style: "color:var(--ink-3);margin-top:8px" }, "Historique borné à ce que le moteur expose (30 derniers passages). Le détail complet vit dans l'écran Éclats.")));
    } catch (e) { /* compte rendu indisponible : l'accueil reste complet sans lui */ }
  }

  on("nova:player-state", (d) => {
    audioBody.replaceChildren(h("div", { class: "big" }, d && d.playing ? "En écoute" : "Médias"),
      h("div", { class: "ss", style: "color:var(--ink-2)" }, d && d.title ? String(d.title) : "Radios, podcasts et TV — le mini-lecteur garde l'écoute."));
  });
  /* FUSION DOTS (22/10, audit §6.2) : le bus moteur (SSE « dot » : working /
     ready / idle) fait passer la peluche du Dot concerné à l'instant du signal
     — traduction dans le vocabulaire du CSS, SANS rechargement de liste. Un
     rechargement doux différé ne sert qu'à rafraîchir les données (dernier
     run, compteurs), jamais à porter la phase. */
  let dotsRefreshT = 0;
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
    clearTimeout(dotsRefreshT);
    dotsRefreshT = setTimeout(() => { if (!dead) loadDots(); }, 1500);
  });
  on("nova:dot-run", loadAbsence);
  on("nova:draft-new", loadMessages);

  loadHero(); loadFinance(); loadBriefs(); loadMessages(); loadVault(); loadAbsence(); loadDots();
  const destroyHome = () => { dead = true; clearTimeout(heroRetryTimer); clearTimeout(dotsRefreshT); closeVide(); clearPlushes(); if (orb.destroyAvatar) orb.destroyAvatar(); offs.forEach((o) => { try { o(); } catch (e) {} }); chat.stop(); voice.dispose(); };
  return { destroy: destroyHome, onShow: () => { if (!dead) loadHero(); } };
}
