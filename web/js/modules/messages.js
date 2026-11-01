/* Module Messages — messageries unifiées + brouillons.
   Les services web (WhatsApp, Outlook, Teams…) vivent dans des volets WKWebView NATIFS,
   créés À LA DEMANDE par la coquille Swift (pont « nova », cmd web.show). §41 (21/10) :
   ils ne sont PLUS détruits au changement de service — deux emplacements côte à côte,
   volets parqués vivants hors écran (plafond 4, récolteur d'inactivité du moteur en
   filet ; la cause CPU de Nova 1, c'était des volets invisibles NON bornés). Ici, on
   garde la liste des services, les emplacements, et les brouillons : chaque envoi
   passe par une carte d'approbation.
   VAGUE 3 CONNECT : Telegram ajouté au catalogue ; le Navigateur devient un vrai volet
   piloté (barre d'adresse, retour/avance/recharge, lecture de page) ; le Navigateur Tor
   est câblé sur le moteur Swift existant (tor.start/tor.status, volet proxifié SOCKS) avec
   son état RÉEL affiché — jamais d'ouverture tant que Tor n'est pas prêt, donc jamais de
   chargement « en direct » déguisé en Tor. Bouton « Lire le contenu » + diagnostic des
   mails : ils empruntent le lecteur robuste d'uibridge (window.NovaPanes), le même
   chemin que l'assistant — attente du chargement, bloqueur de session nommé, extraction. */
/* V6 (25/10) — refonte premium (contrat conseil_24-10/V6_DESIGN.md) : en-tête ds (une phrase, une action
   primaire « Écrire pour un tiers », le reste dans « Plus d'actions », la mesure « Ta voix » en méta discrète) ;
   services en UNE rangée groupée (Courrier · Messageries · Réseaux · Navigateurs) qui défile, service actif
   marqué, point « volet vivant » quand une session est gardée ; barre d'outils compacte (lecture, navigateur,
   Tor) avec la bascule « Côte à côte » ; barres de volet aux boutons libellés (Agrandir, Détacher, Masquer,
   Fermer) — plus de menu « ⋯ » déroulé sous le volet natif. Ponts natifs, routes, cartes d'approbation et
   confirmation « ENVOYER » inchangés. */
import { approvalCard } from "../orb.js";
import * as ds from "../ds.js";

const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const native = () => { try { return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nova; } catch (e) { return null; } };

/* §41 (21/10) : registre des volets natifs VIVANTS, au niveau fichier pour
   survivre aux remontages du module. Un volet ouvert n'est plus détruit
   au changement de service : il est parqué hors écran et revient par un
   simple web.move. Plafond PANE_MAX (leçon CPU de Nova 1) + récolteur
   d'inactivité du moteur comme filet. */
const PANE_REG = new Map();   // id -> { url, at }
const PANE_MAX = 4;
/* LOT VOLETS+JOURNALISATION ③④ (22/10) : dernier événement nova:panenav connu par
   volet — { url, loading, error }. Au niveau fichier comme PANE_REG pour survivre
   aux remontages du module (la réouverture après retour doit retrouver l'état). */
const PANE_NAV = new Map();   // id -> { url, loading, error }
/* §43-S1 : volets actuellement détachés en fenêtre séparée — leur emplacement
   affiche « détaché », movePanes ne les touche pas, la fermeture réelle les sort du registre. */
const PANE_DETACHED = new Set();   // id de volet détaché
const PANE_ERR_MAX = 80;   // plafond du texte d'erreur affiché dans la barre d'emplacement
const ICON_BY_ID = { ol: "outlook", gm: "gmail", zm: "mail", tm: "teams", wa: "whatsapp", tg: "telegram", fb: "facebook", ig: "instagram", li: "linkedin", x: "x", web: "globe", tor: "shield" };   // 24/10 : bouclier réel (plus la puce « Système »)
/* V6 : groupes de la barre de services — un service hors groupe rejoint le dernier groupe. */
const SVC_GROUPS = [["Courrier", ["ol", "gm", "zm"]], ["Messageries", ["tm", "wa", "tg"]], ["Réseaux", ["fb", "ig", "li", "x"]], ["Navigateurs", ["web", "tor"]]];

export async function mount(root, ctx) {
  const { api, bus, h, ic } = ctx;
  let dead = false, openPane = null, rafMove = 0;
  let split = false, focusSlot = "A";   // §41 : deux emplacements A/B, volet focalisé
  const offs = [];
  root.classList.add("mod-fill");   // §45 : le module devient une colonne flex pleine hauteur — la zone de volet remplit l'écran au lieu de se dimensionner sur son contenu vide
  /* UI TOTALE Phase 3 (DS §6.10) : l'erreur est un composant distinct du vide,
     toujours avec « Réessayer » câblé sur le chargement du bloc. */
  const stateError = (label, retry) => ds.errorBox({ cause: label, retry });
  /* Compteur d'approbations en attente, accolé au titre (DS §6.2, §8.2) :
     une décision qui attend ne doit jamais être hors champ sans signal. */
  const draftsBadge = h("span", { class: "ds-count ms-dbadge", hidden: true, title: "Brouillons en attente d'approbation", "aria-label": "Brouillons en attente d'approbation" }, "0");
  /* §41 : bascule « Côte à côte » — deux volets ouverts face à face. */
  /* V3 « RÉPONSES DANS SA VOIX » (24/10) : indicateur « taux d'envoi sans retouche » des
     réponses préparées depuis le Fil direct (mesuré par le moteur à l'envoi RÉEL, statut
     « envoyé » du magasin — jamais estimé ici) + profil d'écriture lisible et éditable. */
  const vaChip = h("button", { class: "ms-voice", type: "button", title: "Réponses dans ta voix : profil d'écriture et mesure des envois sans retouche", "aria-expanded": "false" }, "Ta voix · …");
  const vaProf = h("div", { class: "va-prof ds-card ms-prof", hidden: true, role: "region", "aria-label": "Profil d'écriture" });
  let vaData = null;
  const vaPct = (ind) => (ind && ind.taux != null ? ind.taux + " %" : "—");
  function vaPaintChip() {
    const ind = (vaData && vaData.indicateur) || null;
    if (!ind) { vaChip.textContent = "Ta voix · —"; vaChip.title = "Mesure des réponses dans ta voix non lue (moteur injoignable) — clic : profil d'écriture"; return; }
    vaChip.textContent = ind.envoyees > 0 ? "Ta voix · " + vaPct(ind) + " sans retouche" : "Ta voix · pas encore mesuré";
    vaChip.title = ind.envoyees > 0
      ? "Réponses préparées dans ta voix : " + ind.sans_retouche + " envoyée(s) sans retouche sur " + ind.envoyees + " — clic : profil d'écriture"
      : "Aucune réponse préparée dans ta voix n'a encore été envoyée — clic : profil d'écriture";
  }
  async function vaLoad() {
    try { const j = await api.get("/api/voix-ahadi/profil", 15000); vaData = j && j.indicateur && j.regles ? j : null; } catch (e) { vaData = null; }
    if (dead) return;
    vaPaintChip();
    if (!vaProf.hidden) vaPaintProf();
  }
  function vaPaintProf() {
    if (!vaData) { vaProf.replaceChildren(stateError("Profil d'écriture injoignable pour le moment", vaLoad)); return; }
    const d = vaData, ind = d.indicateur || {}, st = d.stats || {}, regles = d.regles || {}, src = d.regles_source || {}, lib = d.libelles || {};
    const champs = Array.isArray(d.champs) ? d.champs : Object.keys(regles);
    const tas = {};
    const rows = champs.map((k) => {
      const ta = h("textarea", { class: "fld fld-area va-rule", rows: "2", "aria-label": String(lib[k] || k) });
      ta.value = String(regles[k] || "");
      tas[k] = ta;
      return h("label", { class: "va-row" },
        h("span", { class: "va-k" }, String(lib[k] || k), h("span", { class: "va-src" }, String(src[k] || ""))),
        ta);
    });
    const obs = d.observe || null;
    const obsLine = obs && obs.corpus > 0
      ? "Appris de " + obs.corpus + " message(s) envoyé(s)" + (obs.mots_median != null ? " · médiane " + obs.mots_median + " mots" : "") + " · " + String(obs.ts || "").slice(0, 10)
      : "Pas encore appris de tes envois : les règles affichées sont tes règles de départ.";
    const srcLine = obs && Array.isArray(obs.sources) && obs.sources.length ? "Sources : " + obs.sources.join(" ; ") : "";
    const pv = st.par_variante || {};
    const pvTxt = Object.keys(pv).sort((a, b) => pv[b] - pv[a]).slice(0, 5).map((k) => k + " (" + pv[k] + ")").join(", ");
    const mailApp = h("input", { type: "checkbox" });
    const save = h("button", { class: "btn sm acc", onclick: async () => {
      const changed = {};
      for (const k of champs) if (tas[k].value !== String(regles[k] || "")) changed[k] = tas[k].value;
      if (!Object.keys(changed).length) { ctx.toast("Aucune modification."); return; }
      save.disabled = true;
      try { const j = await api.post("/api/voix-ahadi/profil", { regles: changed }, 15000); if (!j || j.ok !== true) throw new Error((j && j.error) || "refusé"); ctx.toast("Profil d'écriture enregistré."); }
      catch (e) { ctx.toast("Enregistrement impossible : " + ((e && e.message) || e), true); }
      save.disabled = false; vaLoad();
    } }, "Enregistrer");
    const learn = h("button", { class: "btn sm", disabled: !!d.apprentissage_en_cours, onclick: async () => {
      learn.disabled = true;
      try { const j = await api.post("/api/voix-ahadi/profil", { apprendre: true, mail_app: !!mailApp.checked }, 15000); if (!j || j.ok !== true) throw new Error((j && j.error) || "refusé"); ctx.toast("Apprentissage lancé en arrière-plan — tes champs édités ne seront pas écrasés."); }
      catch (e) { ctx.toast("Apprentissage impossible : " + ((e && e.message) || e), true); }
      setTimeout(vaLoad, 4000);
    } }, d.apprentissage_en_cours ? "Apprentissage en cours…" : "Apprendre de mes envois");
    const ex = (Array.isArray(d.exemples) ? d.exemples : []).slice(-2).reverse();
    vaProf.replaceChildren(
      h("div", { class: "va-stats" },
        h("span", {}, h("b", {}, vaPct(ind)), " sans retouche"),
        h("span", {}, h("b", {}, String(ind.envoyees || 0)), " envoyée(s)"),
        h("span", {}, h("b", {}, String(ind.preparees || 0)), " préparée(s)"),
        h("span", {}, h("b", {}, String(ind.generations || 0)), " jeu(x) de variantes"),
        ind.ecart_moyen != null ? h("span", {}, "écart moyen ", h("b", {}, Math.round(ind.ecart_moyen * 100) + " %")) : null),
      pvTxt ? h("div", { class: "ss" }, "Intentions choisies : " + pvTxt) : null,
      h("div", { class: "ss" }, obsLine), srcLine ? h("div", { class: "ss" }, srcLine) : null,
      d.derniere_erreur ? h("div", { class: "ss va-warn" }, String(d.derniere_erreur)) : null,
      h("div", { class: "va-rows" }, ...rows),
      ex.length ? h("details", { class: "va-ex" }, h("summary", {}, "Dernières corrections mesurées (" + ex.length + ")"),
        ...ex.map((e) => h("div", { class: "va-exi" },
          h("div", { class: "ss" }, String(e.variante || "") + " · écart " + Math.round((Number(e.ecart) || 0) * 100) + " %"),
          h("div", { class: "va-exp" }, "Proposé : " + String(e.propose || "").slice(0, 280)),
          h("div", { class: "va-exf" }, "Envoyé : " + String(e.final || "").slice(0, 280))))) : null,
      h("div", { class: "va-actions" },
        h("label", { class: "ss va-opt" }, mailApp, " inclure la boîte Envoyés de Mail.app (lecture seule, arrière-plan)"),
        h("span", { class: "sp" }), learn, save));
  }
  const toggleProf = () => {
    vaProf.hidden = !vaProf.hidden;
    vaChip.setAttribute("aria-expanded", vaProf.hidden ? "false" : "true");
    if (!vaProf.hidden) vaPaintProf();
    try { requestAnimationFrame(() => movePanes()); } catch (e) {}
  };
  vaChip.addEventListener("click", toggleProf);
  const splitBtn = h("button", { class: "btn sm ds-btn-secondary ms-split", type: "button", "aria-pressed": "false", title: "Afficher deux volets côte à côte (ex. WhatsApp et Telegram en même temps)", onclick: () => setSplit(!split) });
  splitBtn.innerHTML = ic("split", 14);
  splitBtn.append(h("span", { class: "ms-split-l" }, "Côte à côte"));
  /* V6 : « Plus d'actions » — menu court (2 entrées). Garde-volet : s'il recouvrait un volet
     natif (qui peindrait par-dessus), les volets visibles sont écartés le temps du menu. */
  let menuParked = false;
  const moreMenu = h("div", { class: "ms-menu", role: "menu", hidden: true });
  const moreBtn = h("button", { type: "button", class: "ds-icon-btn ms-more-btn", title: "Plus d'actions", "aria-label": "Plus d'actions", "aria-haspopup": "menu", "aria-expanded": "false" });
  moreBtn.innerHTML = ic("ellipsis", 16);
  const menuItem = (icon, label, tip, fn) => {
    const b = h("button", { type: "button", class: "ms-menu-i", role: "menuitem", title: tip, onclick: (e) => { e.stopPropagation(); closeMenu(); fn(); } });
    b.innerHTML = ic(icon, 15); b.append(h("span", {}, label)); return b;
  };
  moreMenu.append(
    /* Vague 3 : preuve de lecture à la demande — même chemin que l'assistant. */
    menuItem("mail", "Tester la lecture des mails", "Teste la lecture réelle d'Outlook, Gmail et Teams (attente du chargement, détection de session, extraction)", () => runDiagnostic()),
    menuItem("draft", "Profil d'écriture (ta voix)", "Profil d'écriture et mesure des envois sans retouche", () => toggleProf()));
  function closeMenu() {
    if (moreMenu.hidden) return;
    moreMenu.hidden = true; moreBtn.setAttribute("aria-expanded", "false");
    if (menuParked) { menuParked = false; movePanes(); }
  }
  function openMenu(byKeyboard) {
    moreMenu.hidden = false; moreBtn.setAttribute("aria-expanded", "true");
    try {
      const mr = moreMenu.getBoundingClientRect(); const n = native();
      if (n) for (const k of visibleKeys()) {
        const S = slotEls[k]; if (!S.pane || PANE_DETACHED.has(S.pane)) continue;
        const r = S.el.getBoundingClientRect();
        if (mr.bottom > r.top && mr.top < r.bottom && mr.right > r.left && mr.left < r.right) { n.postMessage({ cmd: "web.move", id: S.pane, x: -20000, y: 0, w: 1100, h: 760 }); menuParked = true; }
      }
    } catch (e) {}
    if (byKeyboard) { const first = moreMenu.querySelector("button"); if (first) first.focus(); }
  }
  moreMenu.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const items = [...moreMenu.querySelectorAll("button")]; const i = items.indexOf(document.activeElement);
    e.preventDefault(); items[(i + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length].focus();
  });
  moreBtn.addEventListener("click", (e) => { e.stopPropagation(); if (moreMenu.hidden) openMenu(e.detail === 0); else closeMenu(); });
  const onDocDown = (e) => { if (!moreMenu.hidden && !moreWrap.contains(e.target)) closeMenu(); };
  const onKey = (e) => { if (e.key === "Escape" && !moreMenu.hidden) { closeMenu(); moreBtn.focus(); } };
  document.addEventListener("pointerdown", onDocDown, true);
  document.addEventListener("keydown", onKey);
  offs.push(() => { document.removeEventListener("pointerdown", onDocDown, true); document.removeEventListener("keydown", onKey); });
  const moreWrap = h("div", { class: "ms-more" }, moreBtn, moreMenu);
  const head = ds.pageHead({ title: "Messages", sub: "Un volet par service · aucun envoi sans ta carte",
    actions: [vaChip,
      /* Amendement 16 « Ambassadeur » : Nova rédige pour un tiers à partir du seul
         contexte qu'elle a d'Ahadi ; le résultat arrive en brouillon, à approuver ici. */
      { label: "Écrire pour un tiers", icon: "send", primary: true, tip: "Nova rédige un message pour un tiers, en brouillon à approuver",
        onClick: () => { ctx.navigate("accueil"); setTimeout(() => bus.emit("nova:ask", { text: "Rédige un brouillon de message pour un tiers, à partir de ce que tu sais de moi (ton, rôle, contexte) : je te donne son nom et l'objet dans ma prochaine phrase. Ne l'envoie pas : laisse-le en brouillon à approuver." }), 350); } },
      moreWrap] });
  const titleEl = head.querySelector(".ds-title"); if (titleEl) titleEl.append(draftsBadge);
  root.append(head);

  root.append(vaProf);
  const draftsBox = h("div", { class: "msg-drafts" });
  const svcBar = h("div", { class: "svc-bar ms-svc-scroll", role: "toolbar", "aria-label": "Services de messagerie" });
  const svcWrap = h("div", { class: "ms-svc" }, svcBar);
  const syncSvcFade = () => {
    const l = svcBar.scrollLeft > 2, r = svcBar.scrollLeft + svcBar.clientWidth < svcBar.scrollWidth - 2;
    svcWrap.classList.toggle("can-l", l); svcWrap.classList.toggle("can-r", r);
  };
  svcBar.addEventListener("scroll", syncSvcFade, { passive: true });
  /* État initial du volet (M2, DS §8.2) : un vide assumé, à icône, avec raccourcis
     vers les services fréquents. Le volet se choisit dans la barre de services —
     l'ancien texte « Choisis un service ci-dessus » est supprimé. */
  /* §41 : l'hôte contient DEUX emplacements (A, B) — chacun avec sa barre
     (nom du service, agrandir, fermer) et sa zone de volet. Le volet natif
     est positionné sur la zone par web.move ; la barre reste visible, elle
     n'est jamais recouverte. B est masqué tant que « Côte à côte » est off. */
  const slotEls = {};
  const mkSlot = (key) => {
    /* V6 : barre de volet — icône + nom du service, lettre d'emplacement (côte à côte), état
       (chargement / erreur / détaché) en pastille, et quatre boutons LIBELLÉS (icône seule +
       infobulle quand le volet est étroit). Plus de menu « ⋯ » qui passait sous le volet natif. */
    const icoEl = h("span", { class: "ms-slot-ic", "aria-hidden": "true" });
    const letter = h("span", { class: "ms-slot-k", title: "Emplacement " + key }, key);
    const name = h("span", { class: "pane-slotname" }, "Aucun service");
    const stEl = h("span", { class: "ms-slot-st" });
    const sbBtn = (icon, label, tip, fn) => {
      const b = h("button", { type: "button", class: "btn sm ds-btn-ghost ms-sb", title: tip, "aria-label": label, onclick: (e) => { e.stopPropagation(); fn(); } });
      b.innerHTML = ic(icon, 15); b.append(h("span", { class: "ms-sb-l" }, label));
      b.setLabel = (l, t) => { b.querySelector(".ms-sb-l").textContent = l; b.setAttribute("aria-label", l); if (t) b.title = t; };
      return b;
    };
    const zoomBtn = sbBtn("maximize", "Agrandir", "Agrandir ce volet (pleine page) ou restaurer", () => zoomSlot(key));
    const detachBtn = sbBtn("external", "Détacher", "Détacher ce volet dans une fenêtre séparée / le ramener dans son emplacement", () => toggleDetach(key));
    const hideBtn = sbBtn("eye-off", "Masquer", "Masquer ce volet — il reste vivant, sa session est conservée", () => closeSlot(key));
    const closeBtn = sbBtn("close", "Fermer", "Fermer définitivement ce volet — il sera rechargé à sa prochaine ouverture", () => closeSlotDefinitive(key));
    const bar = h("div", { class: "pane-slotbar" },
      h("span", { class: "ms-slot-id" }, letter, icoEl, name, stEl), h("span", { class: "sp" }),
      h("span", { class: "ms-sb-acts" }, zoomBtn, detachBtn, hideBtn, closeBtn));
    const el = h("div", { class: "pane-slot", "data-slot": key });
    /* V5-E : bandeau de passation de main, entre la barre et le volet (jamais sous le volet natif). */
    const tko = h("div", { class: "tko", hidden: true, role: "status", "aria-live": "polite" });
    const wrap = h("div", { class: "pane-slotwrap", "data-wrap": key }, bar, tko, el);
    wrap.addEventListener("pointerdown", () => setFocusSlot(key), true);
    slotEls[key] = { wrap, bar, el, name, pane: null, svcId: "", detachBtn, zoomBtn, hideBtn, closeBtn, icoEl, stEl, tko };
    return wrap;
  };
  const host = h("div", { class: "pane-host" });
  const wrapA = mkSlot("A"), wrapB = mkSlot("B");
  wrapB.hidden = true;
  const emptySlot = (key) => h("div", { class: "ds-empty ms-empty" },
    h("span", { class: "ds-empty-ic", html: ic("talk", 20) }),
    h("div", { class: "ds-empty-t" }, key === "A"
      ? "Choisis un service ci-dessus : son volet s'ouvre ici et reste vivant quand tu changes de service."
      : "Second volet : choisis un autre service pour l'afficher ici, face au premier."),
    h("div", { class: "ms-quick" },
      ...[["ol", "Outlook"], ["gm", "Gmail"], ["zm", "Zoho"], ["tm", "Teams"]].map(([sid, label]) => {
        const b = h("button", { type: "button", class: "btn sm ds-btn-secondary", onclick: () => { setFocusSlot(key); const s = SERVICES.find((x) => x.id === sid); if (s) selectService(s); } });
        b.innerHTML = ic(ICON_BY_ID[sid] || "mail", 14); b.append(label); return b;
      })));
  slotEls.A.el.append(emptySlot("A"));
  slotEls.B.el.append(emptySlot("B"));
  host.append(wrapA, wrapB);
  /* V5-E : activité de Nova sur un volet qui n'est PAS à l'écran (parqué hors champ) — même bandeau, au-dessus des emplacements. */
  const tkoBg = h("div", { class: "tko-bg", hidden: true, role: "status", "aria-live": "polite" });
  const note =h("div", { class: "pane-note" }, native() ? "" : "Aperçu hors application : les volets web sont hébergés par l'app macOS et n'apparaissent que dans Nova.");

  /* ── Vague 3 CONNECT : barre du Navigateur, barre Tor, lecture ────── */
  let currentSvc = null;   // service sélectionné (catalogue intégré ou liste moteur)
  let barPane = null;      // volet piloté par la barre d'adresse : "web" ou "tor"
  let lastTor = null;
  const READABLE = new Set(["ol", "gm", "tm", "wa", "tg", "fb", "ig", "li", "x"]);
  const urlInput = h("input", { class: "url-input", type: "text", placeholder: "Adresse ou recherche…", spellcheck: "false" });
  const goBtn = ds.action({ label: "Aller", primary: true, onClick: () => goUrl() });
  const syncGo = () => { goBtn.disabled = !urlInput.value.trim(); };
  urlInput.addEventListener("input", syncGo);
  syncGo();
  const browserBar = h("div", { class: "browser-bar ms-browser", hidden: true },
    ds.action({ icon: "prev", tip: "Précédent", onClick: () => navCmd("back") }),
    ds.action({ icon: "next", tip: "Suivant", onClick: () => navCmd("forward") }),
    ds.action({ icon: "refresh", tip: "Recharger", onClick: () => navCmd("reload") }),
    urlInput,
    goBtn,
    ds.action({ label: "Lire", icon: "look", tip: "Lire le contenu de la page (même lecteur que l'assistant)", onClick: () => readCurrent() }),
    ds.action({ label: "Retour au courrier", icon: "close", tip: "Fermer cette page et revenir au courrier (le volet reste vivant, session conservée)", onClick: () => closeWebPage() }));
  urlInput.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") goUrl(); });
  const torState = h("div", { class: "ds-meta ms-torstate" }, "État Tor : pas encore sondé.");
  const torStartBtn = ds.action({ label: "Démarrer Tor", primary: true, onClick: () => startTor() });
  const torOpenBtn = ds.action({ label: "Ouvrir le navigateur Tor", disabled: true, onClick: () => openTor() });
  const torBar = h("div", { class: "browser-bar ms-tor", hidden: true },
    h("span", { class: "ms-tor-ic", html: ic("shield", 16) }), torState,
    h("span", { class: "ms-tor-acts" },
      ds.action({ label: "Revérifier", icon: "refresh", tip: "Revérifier l'état réel de Tor", onClick: () => refreshTor() }),
      torStartBtn, torOpenBtn));
  const readBar = h("div", { class: "browser-bar ms-readbar", hidden: true },
    /* 29/10 (Ahadi : « pas de bouton pour revenir au mail ») : retour arrière DANS la boîte affichée. */
    ds.action({ icon: "prev", label: "Précédent", tip: "Revenir à la page précédente de cette boîte", onClick: () => { const n = native(); if (n && openPane) n.postMessage({ cmd: "web.nav", id: openPane, action: "back" }); } }),
    ds.action({ label: "Lire le contenu", icon: "look", tip: "Lire le contenu de ce service (même lecteur que l'assistant)", onClick: () => readCurrent() }),
    h("span", { class: "ds-meta ms-hint", title: "Lecture en arrière-plan, par le même chemin que l'assistant — inutile d'ouvrir le volet. Si une session manque, la cause exacte s'affiche." }, "En arrière-plan, sans ouvrir le volet — la cause s'affiche si une session manque"));
  const readBody = h("div", { class: "ms-read-body" });
  const readClose = h("button", { type: "button", class: "ds-icon-btn ms-read-x", title: "Fermer le résultat de lecture", "aria-label": "Fermer le résultat de lecture", onclick: () => { readBox.hidden = true; try { requestAnimationFrame(() => movePanes()); } catch (e) {} } });
  readClose.innerHTML = ic("close", 14);
  const readBox = h("div", { class: "read-box ms-read", hidden: true }, readClose, readBody);
  const barsRow = h("div", { class: "browser-bars", hidden: true }, browserBar, torBar, readBar);
  const toolsRow = h("div", { class: "ms-tools" }, barsRow, splitBtn);
  function syncBarsRow() { barsRow.hidden = (browserBar.hidden && torBar.hidden && readBar.hidden); }

  function navCmd(action) { const n = native(); if (n && barPane) n.postMessage({ cmd: "web.nav", id: barPane, action }); }
  function goUrl() {
    if (!barPane) return;
    let v = urlInput.value.trim(); if (!v) return;
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(v)) v = /^[^\s]+\.[a-z]{2,}([/?#]|$)/i.test(v) ? "https://" + v : "https://www.google.com/search?q=" + encodeURIComponent(v);
    urlInput.value = v;
    if (openPane === barPane) { const n = native(); if (n) n.postMessage({ cmd: "web.nav", id: barPane, action: "go", url: v }); }
    else assignPane(barPane, v);
  }
  function selectService(s) {
    currentSvc = s;
    const id = String((s && s.id) || "");
    try { if (id) localStorage.setItem("nova2_msg_svc", id); } catch (e) {}
    svcBar.querySelectorAll(".svc-tile").forEach((t) => { const on = t.dataset.svc === id; t.classList.toggle("on", on); t.classList.toggle("is-on", on); t.setAttribute("aria-pressed", on ? "true" : "false"); if (on) try { t.scrollIntoView({ block: "nearest", inline: "nearest" }); } catch (e) {} });
    /* §41 : le service va dans l'emplacement FOCALISÉ (celui qu'on a touché
       en dernier, ou A par défaut) — l'autre volet reste ouvert à côté. */
    /* LOT-02.1 : en split, si l'autre emplacement est vide on y place le service pour le côte-à-côte. */
    if (split) {
      const other = focusSlot === "A" ? "B" : "A";
      if (slotEls[other] && slotEls[other].pane === null && !slotEls[other].svcId) focusSlot = other;
    }
    slotEls[focusSlot].svcId = id;
    barPane = id === "tor" ? "tor" : id === "web" ? "web" : null;
    browserBar.hidden = !barPane;
    torBar.hidden = id !== "tor";
    readBar.hidden = !READABLE.has(id);
    syncBarsRow();
    if (id === "tor") { refreshTor(); return; }   // Tor : aucun volet tant que le circuit n'est pas prêt (pas de direct déguisé)
    assignPane(id, (s && s.url) || "");
    if (id === "web") urlInput.value = (s && s.url) || "";
  }
  /* Tor : l'état vient de la coquille (NovaPanes.torStatus → cmd tor.status → NovaNative.onTor). */
  async function refreshTor() {
    const NP = window.NovaPanes;
    if (!NP) { torState.textContent = "État Tor : pont indisponible (aperçu hors application)."; return; }
    torState.textContent = "État Tor : sondage en cours…";
    renderTor(await NP.torStatus());
  }
  function renderTor(st) {
    lastTor = st;
    if (!st) { torState.textContent = "État Tor : la coquille n'a pas répondu (état inconnu — rien n'a été chargé)."; torOpenBtn.disabled = true; return; }
    if (!st.installed) {
      torState.textContent = "Tor NON installé sur ce Mac : ni binaire tor (Homebrew), ni Tor Browser.app détectés. Procédure : installe Tor Browser depuis torproject.org/download — Nova détectera son binaire automatiquement, sans réglage.";
      torStartBtn.disabled = true; torOpenBtn.disabled = true; return;
    }
    torStartBtn.disabled = !!st.ready;
    torOpenBtn.disabled = !st.ready;
    torState.textContent = st.ready
      ? "Tor ACTIF (bootstrap 100 %) — le volet Navigateur Tor passe par le proxy SOCKS local de tor, avec un stockage éphémère (rien n'est conservé). Preuve à l'ouverture : check.torproject.org doit afficher « This browser is configured to use Tor » ; sinon, ce n'est pas du Tor et il faut le dire. Tor reste actif tant que Nova tourne et s'arrête à sa fermeture."
      : "Tor installé mais " + (st.running ? "en cours de démarrage — bootstrap " + (st.pct || 0) + " %." : "à l'arrêt.") + " Clique « Démarrer Tor » et attends 100 % : le volet ne s'ouvrira qu'ensuite.";
  }
  async function startTor() {
    const NP = window.NovaPanes; if (!NP) return;
    torStartBtn.disabled = true;
    torState.textContent = "Tor : démarrage en cours (création du circuit)…";
    const st = await NP.torStart((s) => renderTor(s));
    renderTor(st);
    if (st && st.ready) ctx.toast("Tor est actif (bootstrap 100 %).");
    else if (!dead) ctx.toast("Tor n'est pas prêt — vois l'état affiché dans la barre Tor.", true);
  }
  function openTor() {
    let v = (urlInput.value || "").trim();
    const url = (!v || /check\.torproject\.org/.test(v)) ? "https://check.torproject.org/" : (/^[a-z][a-z0-9+.-]*:\/\//i.test(v) ? v : "https://" + v);
    urlInput.value = url;
    if (PANE_REG.has("tor")) { const n = native(); if (n) n.postMessage({ cmd: "web.nav", id: "tor", action: "go", url }); }
    else assignPane("tor", url);
  }
  /* Lecture : le lecteur robuste d'uibridge, exposé en window.NovaPanes. */
  async function readCurrent() {
    const id = currentSvc && String(currentSvc.id || "");
    if (!id) { ctx.toast("Choisis d'abord un service.", true); return; }
    await runRead(id, currentSvc.name || id);
  }
  async function runRead(id, name) {
    const NP = window.NovaPanes;
    readBox.hidden = false;
    readBody.replaceChildren(h("div", { class: "tt" }, "Lecture de " + name + " en cours… la page doit finir de charger (jusqu'à ~30 s)."));
    const t0 = Date.now();
    const liveEl = h("div", { class: "ss", "aria-live": "polite" });
    const timer = setInterval(() => { if (dead) { clearInterval(timer); return; } const s = Math.floor((Date.now() - t0) / 1000); if (s >= 3) { if (!liveEl.isConnected) readBody.append(liveEl); liveEl.textContent = "Lecture de " + name + " — " + s + " s"; } }, 1000);
    if (!NP) { clearInterval(timer); readBody.replaceChildren(h("div", { class: "tt" }, "Lecture impossible : le pont de lecture (NovaPanes) n'est pas initialisé.")); return; }
    let res;
    try { res = await NP.read(id, { budgetMs: 26000 }); } catch (e) { res = { ok: false, erreur: String((e && e.message) || e) }; }
    clearInterval(timer);
    if (dead) return;
    renderRead(name, id, res);
  }
  function renderRead(name, id, res) {
    const kids = [];
    if (res && res.ok && res.messages) {
      kids.push(h("div", { class: "read-head" }, ds.pill("Lu · " + res.compte + " élément(s)", "ok"), h("span", { class: "ss" }, res.source || res.url || "")));
      if (res.note) kids.push(h("div", { class: "ss" }, res.note));
      for (const m of res.messages.slice(0, 15)) kids.push(h("div", { class: "read-item" },
        h("div", { class: "tt" }, (m.de ? m.de + " — " : "") + (m.objet || "(sans objet)")),
        h("div", { class: "ss" }, [m.heure, m.apercu].filter(Boolean).join(" · "))));
    } else if (res && res.ok && res.texte) {
      kids.push(h("div", { class: "read-head" }, ds.pill("Lu · texte de la page", "ok"), h("span", { class: "ss" }, (res.titre ? res.titre + " · " : "") + (res.url || "") + (res.chargement ? " · " + res.chargement : ""))));
      kids.push(h("div", { class: "read-text" }, res.texte.slice(0, 1800)));
    } else {
      const blocked = !!(res && res.bloqueur);
      kids.push(h("div", { class: "read-head" }, ds.pill(blocked ? "Bloqué" : "Échec", blocked ? "warn" : "danger"), h("span", { class: "ss" }, (res && res.url) || "")));
      kids.push(h("div", { class: "read-text" }, (res && res.erreur) || "Échec sans détail."));
      if (blocked) kids.push(h("button", { class: "btn sm ds-btn-primary ms-read-cta", onclick: () => { const s = SERVICES.find((x) => x.id === id); if (s) selectService(s); } }, "Ouvrir " + name + " pour me connecter"));
    }
    readBody.replaceChildren(...kids);
  }
  let diagRunning = false;
  async function runDiagnostic() {
    if (diagRunning) return; diagRunning = true;
    const NP = window.NovaPanes;
    readBox.hidden = false;
    const lines = new Map();
    const draw = () => {
      if (dead) return;
      const kids = [h("div", { class: "tt ms-read-t" }, "Diagnostic de lecture — le même chemin que l'assistant (attente du chargement, détection de session, extraction)")];
      for (const [nm, st] of lines) kids.push(h("div", { class: "read-item" }, h("div", { class: "tt" }, nm), h("div", { class: "ss ss--wrap" }, st)));
      readBody.replaceChildren(...kids);
    };
    const targets = [["ol", "Outlook"], ["gm", "Gmail"], ["tm", "Teams"]];
    for (const [, nm] of targets) lines.set(nm, "lecture en cours…");
    draw();
    if (!NP) { for (const [, nm] of targets) lines.set(nm, "pont de lecture absent (NovaPanes non initialisé)"); draw(); diagRunning = false; return; }
    for (const [id, nm] of targets) {
      let res;
      try { res = await NP.read(id, { budgetMs: 22000 }); } catch (e) { res = { ok: false, erreur: String((e && e.message) || e) }; }
      if (dead) { diagRunning = false; return; }
      if (res.ok && res.messages) lines.set(nm, "LU — " + res.compte + " élément(s)" + (res.messages[0] ? " · premier : " + (res.messages[0].de || res.messages[0].objet || "").slice(0, 70) : ""));
      else if (res.ok) lines.set(nm, "LU — texte de page (" + (res.texte || "").length + " caractères)" + (res.chargement ? " · " + res.chargement : ""));
      else lines.set(nm, (res.bloqueur ? "BLOQUÉ — " : "ÉCHEC — ") + (res.erreur || "sans détail"));
      draw();
    }
    diagRunning = false;
  }
  const offNavUrl = bus.on("nova:panenav", (info) => {
    if (!info || !barPane || info.id !== barPane) return;
    if (document.activeElement !== urlInput && info.url) urlInput.value = info.url;
  });
  offs.push(offNavUrl);
  /* LOT VOLETS+JOURNALISATION ③④ : mémorise le dernier état connu de CHAQUE volet
     (socle commun) sans toucher au comportement de la barre du Navigateur ci-dessus.
     Repeint les barres d'emplacement si l'événement concerne un volet hébergé ;
     sinon aucune peinture (état gardé pour ③). */
  const offPaneState = bus.on("nova:panenav", (info) => {
    if (!info || info.id == null || info.id === "") return;
    const pid = String(info.id);
    PANE_NAV.set(pid, { url: info.url || "", loading: !!info.loading, error: String(info.error || "") });
    if (info.closed) {
      PANE_REG.delete(pid);
      PANE_DETACHED.delete(pid);
      let freed = false;
      for (const k of ["A", "B"]) {
        if (slotEls[k] && slotEls[k].pane === pid) { slotEls[k].pane = null; slotEls[k].svcId = ""; freed = true; }
      }
      if (!dead) paintLive();
      if (freed && !dead) paintSlotBars();
      if (freed) return;
    }
    if (dead) return;
    for (const k of ["A", "B"]) {
      if (slotEls[k] && slotEls[k].pane === pid) { paintSlotBars(); break; }
    }
  });
  offs.push(offPaneState);

  /* DS §8.2, B-03 : ordre imposé — barre de services → zone d'approbations
     (AU-DESSUS du volet hébergé : la carte d'approbation est le seul chemin
     d'envoi, elle ne passe jamais sous un volet plein hauteur) → barre
     contextuelle du service → résultat de lecture juste sous la barre qui
     le produit → volet → note. */
  root.append(svcWrap, draftsBox,
    h("div", { class: "pane-col" }, toolsRow, readBox, tkoBg, host, note));

  /* ── §41 — Volets natifs : emplacements A/B, parcage, suivi continu ────
     Avant : UN volet, détruit à chaque changement de service (web.close),
     repositionné seulement au redimensionnement de la fenêtre — d'où les
     « mélanges » : la carte d'approbation décalait la page, le volet natif
     restait à son ancien rectangle et peignait par-dessus. Maintenant :
     le volet suit son emplacement en continu (ResizeObserver sur l'hôte
     ET ses voisins, scroll du module, resize fenêtre). */
  /* FIX-VOLETS GARDE-VIEWPORT — fonction pure (rectangles en {x,y,w,h},
     viewport en vw×vh) : si le rectangle « visible » demandé n'a AUCUNE
     intersection avec le viewport, retourne le rectangle de repli — celui
     de l'hôte clampé dans la zone visible (hauteur relevée à 320 depuis
     le bas de la fenêtre si l'hôte est lui-même écrasé sous 220) ; sinon
     retourne null (aucune intervention, le rectangle part inchangé). */
  function voletGardeViewport(rect, hostRect, vw, vh) {
    if (rect.y < vh && rect.y + rect.h > 0 && rect.x < vw && rect.x + rect.w > 0) return null;
    const w = Math.max(0, Math.min(Math.round(hostRect.w), vw));
    let h = Math.max(0, Math.min(Math.round(hostRect.h), vh));
    const x = Math.min(Math.max(Math.round(hostRect.x), 0), Math.max(0, vw - w));
    let y = Math.min(Math.max(Math.round(hostRect.y), 0), Math.max(0, vh - h));
    if (h < 220 && vh >= 220) { h = Math.min(320, vh); y = Math.max(0, vh - h); }
    return { x, y, w, h };
  }
  function slotRect(key) {
    const S = slotEls[key];
    const r = S.el.getBoundingClientRect();
    let rect = { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
    /* FIXPREP D-R5 — repli diagnostique : ne jamais envoyer une bande au
       natif sans le savoir. Si l'emplacement mesure < 220 px alors que
       l'hôte en fait ≥ 320, la chaîne de hauteur est encore cassée : on
       envoie le rectangle de l'emplacement COMPLET (son wrap : barre + zone)
       moins la hauteur de la barre, et on le signale. Le wrap — pas l'hôte —
       est le rectangle juste en côte à côte : l'hôte contient les DEUX
       emplacements. Filet de diagnostic : la correction de fond reste la
       chaîne CSS ci-dessus. Écart assumé avec la description moteur
       (« rectangle de l'hôte »), pour cette raison précise. */
    if (rect.h < 220) {
      const hr = host.getBoundingClientRect();
      if (hr.height >= 320) {
        const wr = S.wrap.getBoundingClientRect();
        const barH = Math.round(S.bar.getBoundingClientRect().height);
        const fb = { x: Math.round(wr.x), y: Math.round(wr.y) + barH, w: Math.round(wr.width), h: Math.round(wr.height) - barH };
        if (fb.h >= 220) {
          console.warn("[messages] slotRect(" + key + ") : bande mesurée " + rect.h + " px — repli sur le rectangle d'emplacement (" + fb.h + " px), barre déduite. Chaîne de hauteur CSS à vérifier (.pane-host/.pane-slotwrap).");
          rect = fb;   // FIX-VOLETS : le repli D-R5 traverse ensuite la GARDE-VIEWPORT ci-dessous avant l'envoi
        }
      }
    }
    /* FIX-VOLETS GARDE-VIEWPORT — ne JAMAIS envoyer au moteur un rectangle
       « visible » sans intersection avec le viewport : le moteur applique
       un tel rectangle tel quel (placePane : intersection nulle → cadre
       brut posé hors fenêtre, alpha 1), et chaque movePanes le renvoie —
       le volet existerait hors écran indéfiniment (défaut du 22/10 : hôte
       expulsé à y ≈ 4 000 par la file de brouillons non bornée). Repli :
       l'hôte clampé au viewport, signalé par le warn nommé GARDE-VIEWPORT.
       Cas nominal : la garde retourne null, le rectangle part inchangé. */
    const hrV = host.getBoundingClientRect();
    const gv = voletGardeViewport(rect, { x: hrV.x, y: hrV.y, w: hrV.width, h: hrV.height }, window.innerWidth, window.innerHeight);
    if (gv) {
      console.warn("[messages] GARDE-VIEWPORT slotRect(" + key + ") : rectangle hors fenêtre (" + rect.x + "," + rect.y + " " + rect.w + "×" + rect.h + " ; fenêtre " + window.innerWidth + "×" + window.innerHeight + ") — repli sur l'hôte clampé au viewport (" + gv.x + "," + gv.y + " " + gv.w + "×" + gv.h + ").");
      return gv;
    }
    return rect;
  }
  function parkPane(id) {
    const n = native(); if (n) n.postMessage({ cmd: "web.move", id, x: -20000, y: 0, w: 1100, h: 760 });
    /* V5-E : une pause née d'un simple clic dans le volet se lève quand le volet quitte l'écran
       (Ahadi ne le regarde plus) ; « Prendre la main » / « Arrêter » restent jusqu'à « Rendre la main ». */
    try { const NP = window.NovaPanes; if (NP && NP.release) NP.release(id, "clic"); } catch (e) {}
  }

  /* ── V5-E — Passation de main (Muse « Shared computer ») ─────────────
     État lu chez uibridge (window.NovaPanes.activity) : « active » = une opération réelle
     de Nova est en cours dans ce volet (ordre UIPilot / BodyFetcher, relevé d'instantané) ;
     « held » = Ahadi tient le volet (clic natif dans le volet, « Prendre la main »,
     « Arrêter ») — uibridge refuse alors tout ordre de Nova sur ce volet. Ni l'un ni
     l'autre → aucun bandeau. Rien n'est simulé ici. */
  const TKO_ACTION = /clique|saisit|appuie|ouvre|règle/;
  function tkoState(pid) {
    const NP = window.NovaPanes;
    if (!pid || !NP || typeof NP.activity !== "function") return null;
    try { const st = NP.activity(pid); return st && (st.active || st.held) ? st : null; } catch (e) { return null; }
  }
  function tkoTake(st, openIt) {
    const NP = window.NovaPanes; if (!NP) return;
    if (openIt) { const s = SERVICES.find((x) => x.id === st.id); if (s) selectService(s); }
    NP.hold(st.id, "main");
    ctx.toast("Tu as la main sur " + st.name + " — Nova n'y lit plus et n'y agit plus jusqu'à « Rendre la main à Nova ».");
  }
  function tkoStop(st) {
    const NP = window.NovaPanes; if (!NP) return;
    NP.hold(st.id, "arret");
    ctx.toast("Nova arrêtée sur " + st.name + " : l'étape en cours s'interrompt, rien d'autre n'y sera lu ni cliqué.");
  }
  function tkoGive(st) {
    const NP = window.NovaPanes; if (!NP) return;
    NP.release(st.id);
    /* 29/10 (Ahadi : « j'appuie sur Rendre la main et rien ne se passe ») : Nova reprend AUSSITÔT, de façon visible —
       relecture immédiate du volet (même lecteur que l'assistant), puis le résultat en clair. */
    ctx.toast("Main rendue à Nova — relecture de " + st.name + " en cours…");
    try { paintTakeover(); } catch (e) {}
    if (typeof NP.read === "function") {
      Promise.resolve(NP.read(st.id)).then((r) => {
        if (dead) return;
        if (r && r.ok) {
          const n = typeof r.compte === "number" ? r.compte : (Array.isArray(r.messages) ? r.messages.length : 0);
          ctx.toast(st.name + " relu par Nova" + (n ? " : " + n + " élément(s) vus" : "") + ". Les nouveaux messages arrivent dans tes directs.");
        } else {
          ctx.toast(st.name + " : " + String((r && r.erreur) || "relecture impossible pour l'instant"), true);
        }
      }).catch(() => {});
    }
  }
  function tkoRow(st, where) {
    const btn = (label, cls, fn) => h("button", { class: "btn sm " + cls, type: "button", onclick: (e) => { e.stopPropagation(); fn(); } }, label);
    if (st.held) {
      const why = st.why === "arret" ? "Nova arrêtée sur " + st.name : "Nova en pause sur " + st.name;
      const tail = st.active ? " — elle termine l'étape en cours puis s'arrête" : where === "bg" ? " (volet masqué)" : "";
      return [h("span", { class: "tko-dot hold", "aria-hidden": "true" }),
        h("span", { class: "tko-t" }, h("b", {}, "Tu as la main"), " · " + why + tail),
        h("span", { class: "sp" }),
        btn("Rendre la main à Nova", "acc", () => tkoGive(st))];
    }
    const verb = TKO_ACTION.test(st.label) ? "Nova agit en arrière-plan" : "Nova lit en arrière-plan";
    return [h("span", { class: "tko-dot live", "aria-hidden": "true" }),
      h("span", { class: "tko-t" }, h("b", {}, verb), " · " + (where === "bg" ? st.name + " — " : "") + st.label),
      h("span", { class: "sp" }),
      btn("Prendre la main", "", () => tkoTake(st, where === "bg")),
      btn("Arrêter", "ghost", () => tkoStop(st))];
  }
  function paintTakeover() {
    if (dead) return;
    let changed = false;
    const inSlots = new Set();
    const vis = visibleKeys();
    for (const k of ["A", "B"]) {
      const S = slotEls[k];
      const on = !!S.pane && (k === "A" || split);
      if (on && vis.includes(k)) inSlots.add(S.pane);
      const st = on ? tkoState(S.pane) : null;
      const was = !S.tko.hidden;
      /* 29/10 (Ahadi : « Rendre la main ne marche pas ») : le pointerdown sur l'emplacement relançait ce rendu et
         REMPLAÇAIT le bouton entre l'appui et le relâchement — le clic n'arrivait jamais. On ne redessine plus un
         bandeau dont l'état n'a pas changé. */
      const sig = st ? [st.id, st.held, st.why, st.active, st.label].join("|") : "";
      if (st) { if (S.tko._sig !== sig) { S.tko.replaceChildren(...tkoRow(st, "slot")); S.tko._sig = sig; } S.tko.classList.toggle("held", !!st.held); S.tko.hidden = false; }
      else { S.tko.hidden = true; if (S.tko._sig) { S.tko.replaceChildren(); S.tko._sig = ""; } }
      if (was !== !S.tko.hidden) changed = true;
    }
    const NP = window.NovaPanes;
    const ids = NP && typeof NP.activeIds === "function" ? NP.activeIds() : [];
    const bg = ids.filter((pid) => !inSlots.has(pid)).map(tkoState).filter(Boolean);
    const wasBg = !tkoBg.hidden;
    const bgSig = bg.map((st) => [st.id, st.held, st.why, st.active, st.label].join("|")).join(";");
    if (tkoBg._sig !== bgSig) {
      if (bg.length) tkoBg.replaceChildren(...bg.map((st) => h("div", { class: "tko" + (st.held ? " held" : "") }, ...tkoRow(st, "bg"))));
      else tkoBg.replaceChildren();
      tkoBg._sig = bgSig;
    }
    tkoBg.hidden = !bg.length;
    if (wasBg !== !tkoBg.hidden) changed = true;
    if (changed) movePanes();
  }
  offs.push(bus.on("nova:pane-activity", () => paintTakeover()));
  function visibleKeys() {
    if (!split) return ["A"];
    if (host.classList.contains("zoom-a")) return ["A"];
    if (host.classList.contains("zoom-b")) return ["B"];
    return ["A", "B"];
  }
  const lastPaneRect = {};   // 27/10 : dernier rectangle envoyé par volet (anti-bougé)
  function movePanes() {
    const n = native(); if (!n || rafMove) return;
    rafMove = requestAnimationFrame(() => {
      rafMove = 0;
      const n2 = native(); if (!n2 || dead) return;
      const vis = visibleKeys();
      for (const k of ["A", "B"]) {
        const p = slotEls[k].pane;
        if (!p) continue;
        if (PANE_DETACHED.has(p)) continue;
        if (vis.includes(k)) {
          const r = slotRect(k);
          const last = lastPaneRect[p];
          // Ne renvoyer web.move que si le rectangle a RÉELLEMENT bougé (≥ 2 px) :
          // avant, chaque ResizeObserver/scroll repositionnait le volet natif, qui
          // repeignait la page, qui refaisait bouger la mise en page — l'écran
          // « bougeait constamment » (retour Ahadi 27/10).
          if (last && last.parked !== true && Math.abs(last.x - r.x) < 2 && Math.abs(last.y - r.y) < 2 && Math.abs(last.w - r.w) < 2 && Math.abs(last.h - r.h) < 2) continue;
          lastPaneRect[p] = { ...r };
          n2.postMessage({ cmd: "web.move", id: p, ...r });
        } else {
          if (lastPaneRect[p] && lastPaneRect[p].parked === true) continue;
          lastPaneRect[p] = { parked: true };
          parkPane(p);
        }
      }
    });
  }
  function paintSlotBars() {
    for (const k of ["A", "B"]) {
      const S = slotEls[k];
      const svc = SERVICES.find((x) => String(x.id) === S.svcId);
      /* LOT VOLETS+JOURNALISATION ④ : suffixe d'état depuis le dernier nova:panenav
         connu du volet hébergé — erreur nommée (plafonnée à PANE_ERR_MAX) prioritaire
         sur « chargement… » ; sinon format historique strictement inchangé. */
      /* V6 : même information, mise en forme — nom du service + pastille d'état. */
      const svcName = S.pane ? (svc ? svc.name : "Volet web") : "Aucun service";
      let label = "Volet " + k + " — " + (S.pane ? svcName : "vide");
      let pillEl = null;
      if (S.pane && PANE_DETACHED.has(S.pane)) { label += " — détaché"; pillEl = ds.pill("Détaché", "neutral"); pillEl.title = "Ce volet vit dans une fenêtre séparée — « Ramener » le replace ici."; }
      if (S.pane) {
        const st = PANE_NAV.get(String(S.pane));
        if (st) {
          if (st.error) { const er = st.error.slice(0, PANE_ERR_MAX); label += " — erreur : " + er; pillEl = ds.pill("Erreur", "danger"); pillEl.title = "Erreur de chargement : " + er; }
          else if (st.loading) { label += " — chargement…"; pillEl = pillEl || ds.pill("Chargement…", "neutral"); }
        }
      }
      S.name.textContent = svcName;
      S.name.title = label;
      S.bar.setAttribute("aria-label", label);
      S.icoEl.innerHTML = S.pane ? ic((svc && ICON_BY_ID[svc.id]) || "globe", 15) : "";
      S.stEl.replaceChildren(...(pillEl ? [pillEl] : []));
      S.bar.classList.toggle("is-empty", !S.pane);
      const det = !!(S.pane && PANE_DETACHED.has(S.pane));
      S.detachBtn.setLabel(det ? "Ramener" : "Détacher");
      S.detachBtn.disabled = !S.pane;
      S.hideBtn.disabled = !S.pane;
      S.closeBtn.disabled = !S.pane;
      const zoomed = split ? host.classList.contains("zoom-" + k.toLowerCase()) : root.classList.contains("pane-focus");
      S.zoomBtn.setLabel(zoomed ? "Réduire" : "Agrandir");
      S.wrap.classList.toggle("focused", focusSlot === k && split);
    }
    host.classList.toggle("is-split", split);
    paintLive();
    paintTakeover();   // V5-E : le bandeau suit le volet hébergé par chaque emplacement
  }
  /* V6 : point « volet vivant » sur les services dont la session est gardée (registre PANE_REG). */
  function paintLive() {
    svcBar.querySelectorAll(".svc-tile").forEach((t) => {
      const live = PANE_REG.has(t.dataset.svc);
      t.classList.toggle("is-live", live);
      const base = t.dataset.hint || "";
      t.title = live ? base + (base ? " — " : "") + "volet ouvert, session gardée" : base;
    });
  }
  function setFocusSlot(k) {
    focusSlot = k;
    openPane = slotEls[k].pane;
    const id = slotEls[k].svcId;
    barPane = id === "tor" ? "tor" : id === "web" ? "web" : null;
    browserBar.hidden = !barPane;
    torBar.hidden = id !== "tor";
    readBar.hidden = !READABLE.has(id);
    syncBarsRow();
    paintSlotBars();
  }
  function zoomSlot(k) {
    if (!split) {
      /* §45 : hors côte à côte, « agrandir » = PLEINE PAGE — on replie
         l'en-tête du module, la barre de services, les brouillons et les
         barres d'outils ; la zone de volet prend toute la hauteur.
         (Avant : le zoom ne masquait que l'autre emplacement — invisible
         en mode simple, d'où le bouton « qui ne marche pas ».) */
      root.classList.toggle("pane-focus");
      setFocusSlot(k);
      movePanes();
      return;
    }
    const cls = "zoom-" + k.toLowerCase();
    const on = !host.classList.contains(cls);
    host.classList.remove("zoom-a", "zoom-b");
    if (on) host.classList.add(cls);
    setFocusSlot(k);
    movePanes();
  }
  function toggleDetach(key) {
    const S = slotEls[key]; if (!S || !S.pane) return;
    const n = native(); if (!n) return;
    const p = S.pane;
    if (PANE_DETACHED.has(p)) {
      n.postMessage({ cmd: "web.dock", id: p, ...slotRect(key) });
      PANE_DETACHED.delete(p);
    } else {
      n.postMessage({ cmd: "web.popout", id: p });
      PANE_DETACHED.add(p);
    }
    paintSlotBars();
  }
  function closeSlot(k) {
    try { localStorage.removeItem("nova2_msg_svc"); } catch (e) {}
    const S = slotEls[k];
    if (S.pane && PANE_DETACHED.has(S.pane)) {
      const n0 = native(); if (n0) n0.postMessage({ cmd: "web.dock", id: S.pane, ...slotRect(k) });
      PANE_DETACHED.delete(S.pane);
    }
    if (S.pane) {
      /* LOT WEB v3 / W-17 : sémantique UNIQUE de fermeture = PARQUER.
         Le volet disparaît de l'écran mais reste vivant dans PANE_REG :
         sa réouverture est un simple web.move, sans rechargement ni perte
         de session (la promesse §41). Seul le récolteur d'éviction
         (evictIfNeeded, plafond PANE_MAX) peut fermer réellement un volet
         parqué, jamais le bouton ✕. */
      parkPane(S.pane);
      const rec = PANE_REG.get(S.pane); if (rec) rec.at = Date.now();
      S.pane = null; S.svcId = "";
      if (openPane && !slotEls.A.pane && !slotEls.B.pane) openPane = null;
    }
    host.classList.remove("zoom-" + k.toLowerCase());
    paintSlotBars();
  }
  function closeSlotDefinitive(k) {
    try { localStorage.removeItem("nova2_msg_svc"); } catch (e) {}
    const S = slotEls[k];
    if (!S) return;
    if (S.pane) {
      try { const n = native(); if (n) n.postMessage({ cmd: "web.close", id: S.pane }); } catch (_) {}
      try { PANE_REG.delete(S.pane); } catch (_) {}
      try { PANE_DETACHED.delete(S.pane); } catch (_) {}
      S.pane = null;
      S.svcId = "";
      if (openPane && !slotEls.A.pane && !slotEls.B.pane) openPane = null;
    }
    host.classList.remove("zoom-" + k.toLowerCase());
    paintSlotBars();
  }
  function setSplit(on) {
    split = !!on;
    wrapB.hidden = !split;
    splitBtn.classList.toggle("on", split);
    splitBtn.setAttribute("aria-pressed", split ? "true" : "false");
    if (!split) host.classList.remove("zoom-b");
    paintSlotBars();
    movePanes();
    paintTakeover();
  }
  function evictIfNeeded() {
    if (PANE_REG.size <= PANE_MAX) return;
    const inSlots = new Set([slotEls.A.pane, slotEls.B.pane]);
    const parked = [...PANE_REG.entries()].filter(([id]) => !inSlots.has(id)).sort((a, b) => a[1].at - b[1].at);
    const n = native();
    while (PANE_REG.size > PANE_MAX && parked.length) {
      const [id] = parked.shift();
      PANE_REG.delete(id);
      if (n) n.postMessage({ cmd: "web.close", id });
    }
  }
  function assignPane(id, url) {
    const n = native(); if (!n) return;
    for (const k of ["A", "B"]) {
      if (slotEls[k].pane === id) {
        if (k === "A" || split) { setFocusSlot(k); movePanes(); return; }
        slotEls.B.pane = null;   // côte à côte off : le volet B devient un volet parqué, récupéré ci-dessous
      }
    }
    const S = slotEls[focusSlot];
    if (S.pane && S.pane !== id) { parkPane(S.pane); S.pane = null; }
    if (PANE_REG.has(id)) {
      if (PANE_DETACHED.has(id)) {
        n.postMessage({ cmd: "web.dock", id, ...slotRect(focusSlot) });
        PANE_DETACHED.delete(id);
      }
      PANE_REG.get(id).at = Date.now();
      n.postMessage({ cmd: "web.move", id, ...slotRect(focusSlot) });   // vivant : simple déplacement, rechargement seulement si douteux (③ ci-dessous)
      /* LOT VOLETS+JOURNALISATION ③ : réouverture d'un volet douteux — le seul
         web.move réafficherait un blanc/une erreur tel quel. Si le dernier
         nova:panenav connu signale error non vide, url vide ou about:blank,
         recharger en plus ; sans état connu : inchangé (conservateur). */
      const st = PANE_NAV.get(String(id));
      if (st && (st.error || !st.url || st.url === "about:blank")) n.postMessage({ cmd: "web.nav", id, action: "reload" });
    } else {
      PANE_REG.set(id, { url: url || "", at: Date.now() });
      n.postMessage({ cmd: "web.show", id, url: url || "", ...slotRect(focusSlot) });
    }
    S.pane = id; S.svcId = id; openPane = id;
    paintSlotBars(); evictIfNeeded(); paintLive();
  }
  addEventListener("resize", movePanes);
  offs.push(() => removeEventListener("resize", movePanes));
  root.addEventListener("scroll", movePanes, { passive: true });
  offs.push(() => root.removeEventListener("scroll", movePanes));
  const ro = new ResizeObserver(() => { movePanes(); syncSvcFade(); });
  ro.observe(host); ro.observe(draftsBox); ro.observe(svcWrap); ro.observe(toolsRow);
  ro.observe(slotEls.A.el); ro.observe(slotEls.B.el);   // FIXPREP D-R5 : observer les emplacements eux-mêmes — tout changement réel de hauteur d'un emplacement (carte d'approbation, côte à côte, pleine page, zoom) renvoie un web.move immédiat, sans attendre un resize de fenêtre
  offs.push(() => ro.disconnect());
  const offNav = bus.on("nova:panenav", () => movePanes()); offs.push(offNav);

  /* ── Services ──────────────────────────────────────────────────────── */
  /* NOVA2-FIX : GET /api/webchats n'existe pas côté moteur (seul le POST d'ingestion
     WhatsApp existe) — la liste restait donc sur « Services injoignables » et les volets
     semblaient déconnectés. Les services sont les 4 boîtes suivies par le moteur
     (WebMail : ol / gm / tm / wa — mêmes identifiants que les volets natifs gardés
     vivants par main.swift) + un volet web libre. Si le moteur expose un jour la liste,
     elle remplace celle-ci. */
  const SERVICES = [
    { id: "ol", name: "Outlook", url: "https://outlook.office.com/mail/", icon: "outlook", hint: "Courrier Save the Children" },
    { id: "gm", name: "Gmail", url: "https://mail.google.com/mail/u/0/", icon: "gmail", hint: "Courrier personnel" },
    /* V5-S (25/10) : boîte Zoho campagne (campagne@nova-campagne.example). Le volet est la page de Zoho elle-même —
       Ahadi s'y connecte de sa main, aucune lecture du DOM ici. La lecture pour Nova passe par la connexion IMAP
       en lecture seule (Réglages › Données & comptes › Zoho Mail) : Fil direct, compteur Courrier, canal Fundings. */
    { id: "zm", name: "Zoho", url: "https://mail.zoho.com/zm/", icon: "mail", hint: "Boîte campagne campagne@nova-campagne.example — ta connexion sur la page Zoho" },
    { id: "tm", name: "Teams", url: "https://teams.microsoft.com/", icon: "teams", hint: "Chat et réunions SCI" },
    { id: "wa", name: "WhatsApp", url: "https://web.whatsapp.com/", icon: "whatsapp", hint: "Messagerie — connexion par QR, ton geste" },
    /* Vague 3 : Telegram manquait au catalogue (le moteur de volets le connaît pourtant —
       la doc native le citait dès Nova 1). Même mécanique : volet à la demande, session
       persistante du magasin WebKit par défaut, détruit à la fermeture du module. */
    { id: "tg", name: "Telegram", url: "https://web.telegram.org/k/", icon: "telegram", hint: "Messagerie — connexion par QR ou numéro" },
    /* NOVA2 (vague 2, item 3) : réseaux sociaux — MÊME mécanique que les boîtes mail :
       volets natifs créés à la demande (web.show), détruits à la fermeture du module,
       récolteur d'inactivité côté Swift. Aucun volet permanent. URLs vérifiées le
       20/10/2026 (points d'entrée canoniques ; Gmail/Teams répondent par leurs
       redirections de service normales). */
    { id: "fb", name: "Facebook", url: "https://www.facebook.com/", icon: "facebook", hint: "Réseau social — volet à la demande" },
    { id: "ig", name: "Instagram", url: "https://www.instagram.com/", icon: "instagram", hint: "Réseau social — volet à la demande" },
    { id: "li", name: "LinkedIn", url: "https://www.linkedin.com/", icon: "linkedin", hint: "Réseau professionnel — volet à la demande" },
    { id: "x", name: "X", url: "https://x.com/", icon: "x", hint: "Réseau social — volet à la demande" },
    /* Vague 3 : le Navigateur devient un vrai volet piloté — barre d'adresse au-dessus
       du cadre (retour/avance/recharge via web.nav), lecture de page par NovaPanes. */
    { id: "web", name: "Navigateur", url: "https://www.google.com/", icon: "globe", hint: "Volet web libre — barre d'adresse et lecture de page" },
    /* Vague 3 : Tor — le moteur Swift est complet depuis Nova 1 (findTor, torStart SOCKS
       local, volet « tor » à stockage éphémère + proxyConfigurations), mais aucun écran
       ne l'appelait et NovaNative.onTor n'existait pas côté fenêtre. Ici : sélection =
       état réel d'abord, ouverture seulement quand le circuit est prêt (voir torBar). */
    { id: "tor", name: "Navigateur Tor", url: "https://check.torproject.org/", icon: "shield", hint: "Navigation via Tor — démarrage explicite, état réel affiché", tor: true },
  ];
  async function loadServices() {
    try {
      let svcs = SERVICES;
      /* 24/10 : GET /api/webchats n'existe pas côté moteur — catalogue intégré seul (plus d'appel dans le vide) */
      if (dead) return;
      const iconOf = (s, id) => ICON_BY_ID[id] || s.icon || "talk";
      /* Barre de services TOUJOURS visible en haut du module : chaque service par SON
         glyphe et SA couleur — fini la liste enfouie sous les brouillons. V6 : une seule
         rangée, groupée (Courrier · Messageries · Réseaux · Navigateurs), qui défile. */
      const tile = (s) => {
        const id = String(s.id || s.key || s.name || "");
        const hint = String(s.hint || s.url || s.name || "");
        return h("button", { type: "button", class: "svc-tile ds-chip", "data-svc": id, "data-hint": hint, title: hint, "aria-pressed": "false", "aria-label": id === "x" ? "X" : id === "tor" ? "Navigateur Tor" : undefined,
          onclick: () => selectService(s) },
          h("span", { class: "svc-ic", html: ic(iconOf(s, id), 16) }),
          id === "x" ? null : h("span", { class: "svc-name" }, id === "tor" ? "Tor" : String(s.name || s.title || id)),
          h("span", { class: "ms-live-dot", "aria-hidden": "true" }));
      };
      const used = new Set();
      const groups = SVC_GROUPS.map(([gname, ids]) => [gname, ids.map((i) => svcs.find((x) => String(x.id) === i)).filter(Boolean)]);
      groups.forEach(([, arr]) => arr.forEach((x) => used.add(x)));
      const rest = svcs.filter((x) => !used.has(x));
      if (rest.length && groups.length) groups[groups.length - 1][1].push(...rest);
      svcBar.replaceChildren(...(svcs.length ? groups.filter(([, arr]) => arr.length).map(([gname, arr]) =>
        h("div", { class: "ms-grp", role: "group", "aria-label": gname, title: gname }, ...arr.map(tile)))
        : [ds.empty({ text: "Aucun service configuré — le moteur n'a renvoyé aucune messagerie.", compact: true })]));
      paintLive();
      requestAnimationFrame(syncSvcFade);
      /* 24/10 : le dernier volet ouvert revient tout seul (changement de disposition,
         retour sur l'écran) — le volet parqué est réutilisé, rien ne se recharge. */
      try { const last = localStorage.getItem("nova2_msg_svc"); const sv = last && last !== "tor" && svcs.find((x) => String(x.id || x.key || x.name || "") === last); if (sv && !dead) selectService(sv); } catch (e) {}
    } catch (e) { if (!dead) svcBar.replaceChildren(stateError("Services injoignables pour le moment", loadServices)); }
  }

  /* ── Brouillons : la carte d'approbation est le seul chemin d'envoi ── */
  /* Les corps de brouillons arrivent en HTML (mails) : la carte d'approbation
     affiche du TEXTE — balises converties en retours à la ligne, jamais brutes. */
  const plainText = (html) => String(html || "")
    .replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|li|div|tr|h\d)>/gi, "\n").replace(/<li[^>]*>/gi, "• ")
    .replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;|&apos;/g, "'").replace(/\n{3,}/g, "\n\n").trim();
  /* P-DRAFT-6 — LA COCHE GABARIT, calculée par le moteur (DraftLint) et servie avec le
     brouillon : la carte l'affiche telle quelle, item par item — ✓ verts, ✗ nommés avec
     le détail. Aucun calcul de conformité ici : une seule source de vérité, le moteur. */
  function cocheEl(d) {
    const items = (d.lint && d.lint.items) || [];
    if (!items.length) return null;
    const hardBad = items.filter((it) => it.hard && !it.ok);
    const box = h("div", { class: "appr-coche", style: "padding:8px 14px;border-top:1px solid var(--stroke)" });
    box.append(h("div", { class: "ss", style: "font-weight:600" }, hardBad.length ? "Coche gabarit — à corriger : l'envoi sera refusé" : "Coche gabarit — tout est vert"));
    for (const it of items) box.append(h("div", { class: "ss" }, h("span", { html: ic(it.ok ? "check" : "alert", 13) }), " " + it.label + (!it.ok && it.detail ? " — " + it.detail : "")));
    return box;
  }
  /* 29/10 (Ahadi : « y a trop de brouillons en attente… ajoute une option pour tout supprimer ») — deux temps :
     1er clic arme, 2e clic (dans les 5 s) supprime. Retire les brouillons EN ATTENTE, n'envoie jamais rien. */
  function clearAllBtn(n) {
    const b = h("button", { type: "button", class: "btn sm ghost ms-drafts-clear", title: "Supprimer tous les brouillons en attente (rien n'est envoyé)" }, "Tout supprimer");
    let armed = 0;
    b.addEventListener("click", async () => {
      if (!armed) {
        b.textContent = "Confirmer : supprimer " + n + " brouillon" + (n > 1 ? "s" : "");
        b.classList.add("danger");
        armed = setTimeout(() => { armed = 0; b.textContent = "Tout supprimer"; b.classList.remove("danger"); }, 5000);
        return;
      }
      clearTimeout(armed); armed = 0;
      b.disabled = true; b.textContent = "Suppression…";
      try {
        const r = await api.post("/api/drafts/clear", {});
        ctx.toast(r && r.ok ? (r.removed || 0) + " brouillon" + ((r.removed || 0) > 1 ? "s" : "") + " supprimé" + ((r.removed || 0) > 1 ? "s" : "") + " — rien n'a été envoyé." : "Suppression impossible pour le moment.");
      } catch (e) { ctx.toast("Suppression impossible : le moteur n'a pas répondu."); }
      loadDrafts();
    });
    return b;
  }
  async function loadDrafts() {
    try {
      const j = await api.get("/api/drafts");
      if (dead) return;
      const drafts = arrOf(j, "drafts", "items");
      if (!drafts.length) {
        draftsBadge.hidden = true;
        draftsBox.replaceChildren(); draftsBox.hidden = true;   // 24/10 : rien à approuver = rien à l'écran (l'icône seule flottait)
        return;
      }
      draftsBox.hidden = false;
      draftsBadge.textContent = String(drafts.length);
      draftsBadge.hidden = false;
      draftsBox.replaceChildren(
        h("div", { class: "ds-section-head ms-drafts-head" }, h("h2", { class: "ds-h2", "aria-label": "À approuver (" + drafts.length + ")" }, "À approuver"), h("span", { class: "ds-count" }, String(drafts.length)),
          h("span", { class: "ds-meta ms-drafts-note" }, "Rien ne part sans ta confirmation"), clearAllBtn(drafts.length)),
        ...drafts.map((d) => {
          const isTeams = d.channel === "teams";
          const card = approvalCard({
            title: isTeams ? "Envoyer sur Teams à " + String(d.target || d.to || "—") : "Envoyer à " + String(d.to || d.dest || "—"),
            what: (d.subject ? "Objet : " + d.subject + "\n" : "") + plainText(d.body || d.text || ""),
            approveLabel: "Approuver l'envoi", editLabel: "Modifier", refuseLabel: "Refuser",
          });
          card.setAttribute("data-draft-id", String(d.id || ""));
          const coche = cocheEl(d);
          if (coche) card.insertBefore(coche, card.children[2] || null);
          if (d.origine === "auto" || d.origine === "relance") card.insertBefore(h("div", { class: "ss va-origin" }, (d.origine === "auto" ? "Brouillon préparé automatiquement par Nova pour une arrivée du Fil direct" : "Relance proposée par Nova (mail resté sans réponse)") + (d.auto_cerveau ? " · " + String(d.auto_cerveau) : "") + " — rien n'est parti, l'envoi attend ton ENVOYER."), card.children[2] || null);   // 25/10 AUTONOMIE
          if (d.origine === "voix_ahadi") card.insertBefore(h("div", { class: "ss va-origin" }, "Préparé dans ta voix depuis le Fil direct" + (d.voix_variante ? " · variante « " + String(d.voix_variante) + " »" : "") + " — à l'envoi, l'écart avec ce texte sera mesuré."), card.children[2] || null);
          /* Confiance V1 : relecture indépendante — remarques seulement, rien n'est bloqué ni réécrit */
          try {
            const rel = h("div", { class: "ss appr-review", style: "padding:6px 14px;border-top:1px solid var(--hairline)" }, "Relecture en cours…");
            card.insertBefore(rel, card.children[2] || null);
            api.get("/api/trust/review?id=" + encodeURIComponent(String(d.id || ""))).then((r) => {
              if (!r || (r.hash && d.hash && r.hash !== d.hash)) { rel.textContent = "Relecture en cours…"; return; }
              rel.replaceChildren(h("div", { style: "font-weight:600" }, r.ligne || "Relecture"),
                ...((Array.isArray(r.points) ? r.points : []).map((pt) => (typeof pt === "string" ? pt : String((pt && (pt.texte || pt.text)) || ""))).filter(Boolean).map((t) => h("div", {}, "• " + t))));   // V5-N : un point sans texte n'affiche plus « [object Object] »
            }).catch(() => { rel.textContent = "Relecture pas encore disponible."; });
          } catch (e) {}
          card.promise.then(async (v) => {
            try {
              if (v === "approve") {
                /* LOT1-FIX C1 : le moteur (Feat_SendQueue) exige body.confirm == "ENVOYER"
                   et répond {ok:true} seulement après envoi réel. La confirmation se
                   SAISIT dans la carte, la réponse se LIT, et « Envoyé » ne s'affiche
                   que sur ok confirmé — sinon la cause moteur s'affiche.
                   LOT4 P-D1 : provenance posée par ce handler (window.__novaProv,
                   injecté par le natif, origine gardée) — l'envoi en HTTP local par
                   défaut est débloqué ; les deux verrous moteur (provenance +
                   confirm == "ENVOYER") restent exigés et cumulatifs. */
                /* P-DRAFT-6 — L'APERÇU EST RELU AVANT CONFIRMATION : le brouillon est rechargé ;
                   si son empreinte a changé depuis l'affichage, la confirmation ne s'ouvre pas —
                   la carte se recharge, la nouvelle version devra être relue puis reconfirmée.
                   L'empreinte relue part dans la demande d'envoi (expect, P-DRAFT-3). */
                let fresh = null;
                try { const fj = await api.get("/api/drafts"); fresh = arrOf(fj, "drafts", "items").find((x) => String(x.id) === String(d.id)) || null; } catch (e) {}
                if (!fresh) { ctx.toast("Brouillon introuvable — il a peut-être été retiré. Aucun envoi.", true); loadDrafts(); return; }
                if (fresh.hash && d.hash && fresh.hash !== d.hash) { ctx.toast("Le brouillon a changé depuis l'affichage — relis la nouvelle version puis reconfirme.", true); loadDrafts(); return; }
                const cin = h("input", { type: "text", class: "fld", placeholder: "Tape ENVOYER pour confirmer l'envoi", "aria-label": "Confirmation d'envoi : tape ENVOYER", style: "width:100%" });
                const cerr = h("div", { class: "ss ms-cerr", role: "alert" });
                const cbtn = h("button", { class: "btn acc" }, "Confirmer l'envoi");
                const cback = h("button", { class: "btn" }, "Annuler");
                cbtn.onclick = async () => {
                  if (cin.value.trim() !== "ENVOYER") { cerr.textContent = "Tape exactement ENVOYER pour confirmer."; cin.focus(); return; }
                  cbtn.disabled = true; cerr.textContent = "";
                  try {
                    /* LOT4 P-D1 : provenance posée ICI, dans le geste d'envoi, et nulle part ailleurs.
                       window.__novaProv est injecté par le natif (origine gardée) ; absent = on s'arrête
                       en le disant, plutôt qu'un 403 opaque. */
                    if (!window.__novaProv) { cerr.textContent = "Provenance d'interface indisponible : relance Nova puis réessaie — aucun envoi n'a été fait."; cbtn.disabled = false; return; }
                    const j = await api.post("/api/drafts/send", { id: d.id, confirm: "ENVOYER", expect: (fresh && fresh.hash) || d.hash || "" }, 150000, { "x-nova-provenance": window.__novaProv });
                    /* WP4 : envoi INCERTAIN (délai, plantage, relecture ambiguë) — ni « refusé » ni « envoyé » : à vérifier, jamais relancé seul. */
                    if (j && j.code === "delivery_unknown") { ctx.toast(String(j.error || "Envoi incertain — vérifie avant tout renvoi."), true); loadDrafts(); return; }
                    if (!j || j.ok !== true) throw new Error((j && j.error) || "le moteur n'a pas confirmé l'envoi");
                    if (isTeams) {
                      ctx.toast(j.verified ? "Envoyé sur Teams et relu dans le fil." : (j.evidence === "weak_readback" ? "Soumis sur Teams et relu dans le fil (preuve faible : extrait du texte, pas un reçu)." : "Soumis sur Teams — relecture du fil non concluante, vérifie le volet."), !j.verified);
                    } else {
                      ctx.toast("Envoyé à " + (d.to || d.dest || "") + " — preuve en cours de relecture…");
                      /* P-DRAFT-6 — PREUVE RELUE : le moteur recherche l'envoi dans les Éléments
                         envoyés de Mail.app et journalise le résultat ; la carte le dit tel quel,
                         jamais un vert maquillé (P-DRAFT-3, route /api/drafts/verify). */
                      try { const vr = await api.post("/api/drafts/verify", { id: d.id }, 60000, { "x-nova-provenance": window.__novaProv }); ctx.toast(vr && vr.verified ? "Preuve : retrouvé dans les Éléments envoyés." : "Preuve : non retrouvé dans les Éléments envoyés — à vérifier dans Mail.", !(vr && vr.verified)); }
                      catch (e) { ctx.toast("Preuve : relecture des Éléments envoyés impossible.", true); }
                    }
                  } catch (e) { ctx.toast("Envoi refusé : " + ((e && e.message) || e), true); }
                  loadDrafts();
                };
                cback.onclick = () => loadDrafts();
                card.replaceChildren(card.children[0],
                  h("div", { class: "appr-what" }, (isTeams ? "Envoi sur Teams à " + String(d.target || d.to || "—") : "Envoi à " + String(d.to || d.dest || "—") + (d.subject ? " — " + String(d.subject) : "")) + ". Le moteur n'exécute l'envoi que sur confirmation explicite."),
                  cin, cerr,
                  h("div", { class: "appr-actions" }, cback, cbtn));
                cin.focus();
                return;
              }
              else if (v === "refuse") { await api.post("/api/drafts/remove", { id: d.id }); ctx.toast("Brouillon refusé et retiré."); }
              else {   // Modifier : éditeur inline, l'envoi repassera par une carte
                const ta = h("textarea", { rows: "8", class: "fld fld-area" }, String(d.body || d.text || ""));
                const save = h("button", { class: "btn acc" }, "Enregistrer la modification");
                save.onclick = async () => { try { const j = await api.post("/api/drafts/update", { id: d.id, body: ta.value }); if (j && j.ok === false) throw new Error(j.error || "mise à jour refusée"); ctx.toast("Brouillon mis à jour."); } catch (e) { ctx.toast("Mise à jour impossible : " + ((e && e.message) || e), true); } loadDrafts(); };
                card.replaceChildren(card.children[0], ta, h("div", { class: "appr-actions" }, save));
                return;
              }
            } catch (e) { ctx.toast("Échec : " + ((e && e.message) || e), true); }
            loadDrafts();
          });
          return card;
        }));
    } catch (e) { if (!dead) draftsBox.replaceChildren(stateError("Brouillons injoignables pour le moment", loadDrafts)); }
  }
  const offDraft = bus.on("nova:draft-new", () => { loadDrafts(); vaLoad(); }); offs.push(offDraft);
  /* P-DRAFT-6 — La palette ne vend plus d'envoi direct : elle demande l'ouverture de la
     carte du brouillon ici, dans Messages (deep-link par data-draft-id, hunk 2). */
  const offFocus = bus.on("nova:draft-focus", (p) => {
    const id = p && p.id;
    loadDrafts();
    setTimeout(() => {
      const el = id ? draftsBox.querySelector('[data-draft-id="' + id + '"]') : null;
      if (el) { el.scrollIntoView({ block: "center" }); el.style.outline = "2px solid var(--accent)"; setTimeout(() => { el.style.outline = ""; }, 2400); }
    }, 450);
  });
  offs.push(offFocus);

  /* DIAG2-VEILLE : « Ouvrir dans Nova » depuis un autre écran (Veille) —
     même patron que nova:draft-focus / nova:open-conv : événement bus +
     attente localStorage consommée ici, y compris si Messages n'était
     pas encore monté. La page part dans le volet Navigateur (service
     « web ») — jamais dans le navigateur système. */
  const readPendingUrl = (freshOnly) => {
    try {
      const raw = localStorage.getItem("nova2_pending_url"); if (!raw) return "";
      localStorage.removeItem("nova2_pending_url");
      const o = JSON.parse(raw);
      if (!o || !o.url) return "";
      if (freshOnly && Date.now() - (o.at || 0) > 5 * 60 * 1000) return "";
      return String(o.url);
    } catch (e) { return ""; }
  };
  const openUrlInBrowser = (url) => {
    if (!url) return;
    const s = SERVICES.find((x) => x.id === "web"); if (!s) return;
    /* 27/10 (Ahadi) : la page s'ouvre À CÔTÉ du courrier, jamais à sa place —
       côte à côte forcé, volet web dans l'autre emplacement, courrier intact. */
    const webSlot = slotEls.A.svcId === "web" ? "A" : slotEls.B.svcId === "web" ? "B" : null;
    if (webSlot) setFocusSlot(webSlot);
    else {
      if (!split) setSplit(true);
      setFocusSlot(focusSlot === "A" ? "B" : "A");
    }
    selectService(s);
    setTimeout(() => { urlInput.value = url; goUrl(); }, 350);
  };
  /* Retour explicite au courrier : ferme la page web (volet parqué, session
     conservée), referme le côte à côte s'il n'y a plus rien en face, et
     refocalise le volet courrier. */
  function closeWebPage() {
    const k = slotEls.A.svcId === "web" ? "A" : slotEls.B.svcId === "web" ? "B" : null;
    if (!k) { browserBar.hidden = true; syncBarsRow(); return; }
    const other = k === "A" ? "B" : "A";
    closeSlot(k);
    if (!slotEls[other].svcId && split) setSplit(false);
    setFocusSlot(other);
    try { movePanes(); } catch (e) {}
  }
  /* Accueil › Courrier : ouvrir directement la boîte du message (Outlook, Gmail, Teams, WhatsApp). */
  const offOpenBox = bus.on("nova:open-box", (p) => { const s = SERVICES.find((x) => x.id === String((p && p.box) || "")); if (s && !dead) selectService(s); }); offs.push(offOpenBox);
  const offOpenUrl = bus.on("nova:open-url", (p) => openUrlInBrowser((p && p.url) || readPendingUrl(false))); offs.push(offOpenUrl);
  openUrlInBrowser(readPendingUrl(true));

  loadServices(); loadDrafts(); vaLoad(); paintTakeover();
  return () => {
    dead = true; offs.forEach((o) => { try { o(); } catch (e) {} });
    /* §41 : en quittant l'écran, les volets sont PARQUÉS, pas détruits —
       la session (et la connexion) survit au retour. Le récolteur
       d'inactivité du moteur fermera ce qui dort trop longtemps. */
    for (const k of ["A", "B"]) { const p = slotEls[k].pane; if (p) parkPane(p); }
    openPane = null;
  };
}
