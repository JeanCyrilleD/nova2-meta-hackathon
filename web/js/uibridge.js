/* uibridge.js — le côté fenêtre du pilotage UIPilot (vague 2, items 7+9 ; vague 3 CONNECT).
   Le moteur (UIPilot.swift, outil « app » de l'agent) envoie ses ordres en événements SSE
   « ui » et attend un constat RÉEL via POST /api/ui/result : sans réponse, il dit
   « injoignable » et ne prétend jamais avoir agi.
   - interface : go (naviguer), onglets, etat, lire (texte + éléments numérotés), clic
     (par libellé ou n° — les libellés sensibles renvoient {confirmation:true} au premier
     passage, le moteur demande alors la confirmation d'Ahadi via Tools.needConfirm),
     saisir, touche, defiler ;
   - pages : les volets natifs (web.show en arrière-plan, x < -5000 = silencieux) pilotés
     par web.eval / web.text, résultats via NovaNative.onText (bus « nova:panetext ») ;
   - médias : radio (recherche + nova:play), stop, état, volume sur le mini-lecteur.
   Chaque ordre reçoit TOUJOURS une réponse (succès ou échec constaté).

   VAGUE 3 — pourquoi la lecture des mails échouait, et ce qui la répare :
   1. L'ancien chemin appelait web.text IMMÉDIATEMENT après web.show : Outlook, Teams et
      Gmail sont des SPA qui mettent 5 à 20 s à s'hydrater — l'agent recevait l'écran de
      chargement ou une page vide. → waitForContent() sonde le volet (adresse, titre,
      readyState, longueur du texte visible) jusqu'à contenu stable, dans le budget que
      le moteur accorde à chaque ordre (lire 40 s, aller 25 s, etat 15 s).
   2. Aucune détection de session : si le volet affichait la page de connexion Microsoft
      ou Google, son texte partait tel quel, sans que personne ne nomme le bloqueur.
      → loginInfo() reconnaît les pages de connexion (hôte + marqueurs interactifs) et
      renvoie un bloqueur EXACT (« session Microsoft à reconnecter… »), jamais un
      « injoignable » générique.
   3. Aucune extraction structurée : même chargée, la liste des messages restait noyée
      dans le chrome de la page. → extracteurs par service (Outlook, Gmail, Teams,
      WhatsApp via le cmd natif web.chats, Telegram) + repli honnête sur le texte brut.
   Le même lecteur est exposé aux modules via window.NovaPanes (diagnostic Messages,
   barre du Navigateur, état Tor) : un seul code chemin pour l'agent et pour l'écran. */
import { handleForm } from "./formfill.js";   // 25/10 : outil « formulaire » (Feat_Formulaire.swift)
const norm = (s) => String(s || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
/* 26/10 : « Submit order » passait (httpbin) — soumettre/valider/commander/acheter/réserver/s'inscrire… ajoutés ;
   et tout bouton qui SOUMET un formulaire (type submit, ou <button> sans type dans un <form>) exige la carte. */
const DANGER = /envoyer|supprimer|payer|effacer|vider|publier|confirmer|soumettre|valider|commander|acheter|réserver|reserver|s'inscrire|inscription|postuler|virement|transf[ée]rer|accepter|delete|send|pay|\b(submit|order|checkout|purchase|buy|book|confirm|register|sign up|apply|transfer|accept)\b/i;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function initUIBridge({ api, bus, modules, navigate, currentId, watch }) {
  const native = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nova;
  const waiters = new Map();   // rid → resolve
  bus.on("nova:panetext", ({ id, text }) => { const w = waiters.get(id); if (w) { waiters.delete(id); w(String(text ?? "")); } });
  let lastClickables = [];
  let evalSeq = 0;

  /* §49 CORRECTIF E1 (21/10, diagnostic Muse prouvé dans le code des DEUX côtés) :
     le moteur (App.swift, route POST /api/ui/result) ne délivre le constat à
     UIPilot que s'il arrive EMBALLÉ : j["result"] as? [String: Any]. L'ancien
     envoi à plat ({ id, ...obj }) rendait j["result"] toujours nil → deliver
     jamais appelé → le sémaphore d'UIPilot expirait à CHAQUE ordre → le
     fameux « INJOIGNABLE » systématique (go, ui-etat, page-messages, TV,
     lecture des volets Outlook/Teams). La route répond quand même ok:true,
     donc la fenêtre ne voyait aucune erreur. Contrat désormais respecté :
     { id, result: obj }. */
  const reply = (id, obj) => { api.post("/api/ui/result", { id, result: obj }).catch(() => {}); };
  const view = () => document.getElementById("view");
  const visible = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== "hidden" && cs.display !== "none"; };
  function clickables() {
    const rootEl = view() || document.body;
    /* §9.10/D-35 : le rail de navigation global est EXCLU des cliquables d'écran —
       un « clic » d'agent ne doit jamais changer d'écran en croyant agir dans le
       module ; sans #view, on retombe sur body mais on filtre quand même le rail. */
    const els = [...rootEl.querySelectorAll("button, a, [role='button'], input[type='submit'], input[type='button']")]
      .filter((el) => visible(el) && !el.closest(".rail") && !el.classList.contains("rail-btn"));
    lastClickables = els.map((el, i) => ({ n: i + 1, el, label: (el.getAttribute("aria-label") || el.textContent || el.value || "").trim().replace(/\s+/g, " ").slice(0, 80), kind: el.tagName.toLowerCase() }));
    return lastClickables;
  }
  function paneEval(paneId, js, timeoutMs = 15000) {
    return new Promise((resolve) => {
      const n = native(); if (!n) { resolve(null); return; }
      const rid = "ui" + (++evalSeq) + "x" + Date.now().toString(36);
      const to = setTimeout(() => { waiters.delete(rid); resolve(null); }, timeoutMs);
      waiters.set(rid, (t) => { clearTimeout(to); resolve(t); });
      n.postMessage({ cmd: "web.eval", id: paneId, js, rid });
    });
  }
  function paneText(paneId, timeoutMs = 8000) {
    return new Promise((resolve) => {
      const n = native(); if (!n) { resolve(null); return; }
      const to = setTimeout(() => { waiters.delete(paneId); resolve(null); }, timeoutMs);
      waiters.set(paneId, (t) => { clearTimeout(to); resolve(t); });
      n.postMessage({ cmd: "web.text", id: paneId });
    });
  }
  /* WhatsApp : le cmd natif web.chats renvoie les conversations NON LUES (groupe \t nom \t badge \t aperçu),
     réponse sur le canal « <id>#c » (voir main.swift). null = pas de réponse ; "" = répondu, aucun non-lu. */
  function paneChats(paneId, timeoutMs = 10000) {
    return new Promise((resolve) => {
      const n = native(); if (!n) { resolve(null); return; }
      const key = paneId + "#c";
      const to = setTimeout(() => { waiters.delete(key); resolve(null); }, timeoutMs);
      waiters.set(key, (t) => { clearTimeout(to); resolve(t); });
      n.postMessage({ cmd: "web.chats", id: paneId });
    });
  }
  const PANES = { outlook: "ol", ol: "ol", gmail: "gm", gm: "gm", teams: "tm", tm: "tm", whatsapp: "wa", wa: "wa",
    telegram: "tg", tg: "tg", facebook: "fb", fb: "fb", instagram: "ig", ig: "ig", linkedin: "li", li: "li",
    x: "x", twitter: "x", navigateur: "nav", nav: "nav", web: "web", tor: "tor" };
  const PANE_URLS = { ol: "https://outlook.office.com/mail/", gm: "https://mail.google.com/mail/u/0/", tm: "https://teams.microsoft.com/", wa: "https://web.whatsapp.com/",
    tg: "https://web.telegram.org/k/", fb: "https://www.facebook.com/", ig: "https://www.instagram.com/", li: "https://www.linkedin.com/", x: "https://x.com/",
    nav: "about:blank", web: "https://www.google.com/", tor: "https://check.torproject.org/" };
  const SVC_NAMES = { ol: "Outlook", gm: "Gmail", tm: "Teams", wa: "WhatsApp", tg: "Telegram", fb: "Facebook", ig: "Instagram", li: "LinkedIn", x: "X", nav: "le Navigateur", web: "le Navigateur", tor: "le Navigateur Tor" };
  /* ── V5-E PASSATION DE MAIN (Muse « Shared computer ») ──────────────────────────
     Toute lecture ou action de Nova dans un volet passe par CE fichier : ordres « page »
     du moteur (UIPilot : outil « app » de l'agent ; BodyFetcher : « page / corps ») et
     pilote d'instantanés (SNAP, plus bas). ACT recense ces opérations EN COURS, volet par
     volet — c'est le seul signal d'activité affiché (bandeau de Messages) : aucun volet
     sans opération réelle n'a de bandeau. HOLD est la pause RÉELLE : un volet tenu par
     Ahadi (clic natif dans le volet → NovaNative.onPaneTouch, « Prendre la main »,
     « Arrêter ») refuse tout nouvel ordre de Nova, et les boucles d'attente en cours
     s'interrompent au prochain tour ; le moteur reçoit un constat « pause » nommé
     (BodyFetcher le traite en transitoire → relance plus tard, rien n'est perdu).
     Les lectures demandées par Ahadi lui-même (boutons de Messages) ne sont pas
     bloquées : c'est son geste. Pause levée par « Rendre la main à Nova » ; une pause
     née d'un simple clic se lève aussi quand le volet quitte l'écran (sinon Nova
     resterait muette sur cette boîte à l'insu d'Ahadi). */
  const ACT = new Map();    // paneId → { n, label, since }
  const HOLD = new Map();   // paneId → { since, why: "clic" | "main" | "arret" }
  const actState = (pid) => {
    const a = ACT.get(pid), hd = HOLD.get(pid);
    return { id: pid, name: SVC_NAMES[pid] || pid, active: !!a, label: a ? a.label : "", since: a ? a.since : 0, held: !!hd, why: hd ? hd.why : "", heldSince: hd ? hd.since : 0 };
  };
  const actEmit = (pid) => { try { bus.emit("nova:pane-activity", actState(pid)); } catch (e) {} };
  function actBegin(pid, label) {
    const a = ACT.get(pid);
    if (a) { a.n += 1; a.label = label; } else ACT.set(pid, { n: 1, label, since: Date.now() });
    actEmit(pid);
  }
  function actEnd(pid) {
    const a = ACT.get(pid); if (!a) return;
    a.n -= 1; if (a.n <= 0) ACT.delete(pid);
    actEmit(pid);
  }
  const held = (pid) => HOLD.has(pid);
  function heldResult(pid) {
    const hd = HOLD.get(pid) || { why: "main" };
    const how = hd.why === "arret" ? "il a arrêté Nova sur ce volet" : hd.why === "clic" ? "il travaille dans ce volet" : "il a pris la main";
    return { ok: false, pane: pid, code: "pause", bloqueur: "pause_ahadi",
      erreur: "Volet " + (SVC_NAMES[pid] || pid) + " en pause : Ahadi a la main (" + how + "). Nova ne lit ni n'agit dans ce volet tant qu'il n'a pas cliqué « Rendre la main à Nova ». Rien n'a été lu, cliqué ni saisi par cet ordre. Ne contourne pas la pause : réessaie plus tard ou dis-le-lui." };
  }
  /* 29/10 (Ahadi : « Rendre la main à Nova ne marche pas ») : chaque clic dans le volet reprenait aussitôt la main,
     donc le bouton semblait sans effet. Désormais : (1) après « Rendre la main », les clics dans ce volet ne
     reprennent plus la main pendant 10 min (seuls « Prendre la main » / « Arrêter » le font) ; (2) une pause née
     d'un simple clic se lève seule 2 min après le dernier clic. */
  const holdTrace = (ev, pid, why) => { try { api.post("/api/ui/trace", { ev, pid, why: why || "", t: Date.now() }).catch(() => {}); } catch (e) {} };
  const NO_CLICK_HOLD = new Map();   // paneId → horodatage jusqu'auquel les clics n'arrêtent pas Nova
  function holdPane(pid, why) {
    if (!pid) return;
    holdTrace("hold", pid, why);
    const cur = HOLD.get(pid);
    if (why === "clic") {
      if ((NO_CLICK_HOLD.get(pid) || 0) > Date.now()) return;
      if (cur) { if (cur.why === "clic") cur.last = Date.now(); return; }   // une pause explicite n'est jamais rétrogradée
      HOLD.set(pid, { since: Date.now(), last: Date.now(), why: "clic" });
      actEmit(pid);
      return;
    }
    HOLD.set(pid, { since: cur ? cur.since : Date.now(), why: why || "main" });
    actEmit(pid);
  }
  function releasePane(pid, onlyWhy) {
    holdTrace("release", pid, onlyWhy);
    if (!onlyWhy) NO_CLICK_HOLD.set(pid, Date.now() + 10 * 60 * 1000);   // « Rendre la main » explicite
    const cur = HOLD.get(pid); if (!cur) return false;
    if (onlyWhy && cur.why !== onlyWhy) return false;
    HOLD.delete(pid); actEmit(pid);
    return true;
  }
  setInterval(() => {
    const now = Date.now();
    for (const [pid, hd] of HOLD) { if (hd.why === "clic" && now - (hd.last || hd.since) > 2 * 60 * 1000) { HOLD.delete(pid); actEmit(pid); } }
  }, 15000);
  const PAGE_LABELS = { corps: "lit le corps d'un message", lire: "lit la page", messages: "lit la liste des messages", etat: "vérifie l'état du volet",
    aller: "ouvre une adresse", clic: "clique dans le volet", saisir: "saisit du texte", touche: "appuie sur une touche", absence: "règle la réponse automatique" };
  try {
    window.NovaNative = window.NovaNative || {};
    // main.swift (V5-E) : clic gauche réel d'Ahadi dans un volet affiché → pause de ce volet.
    window.NovaNative.onPaneTouch = (o) => { const pid = String((o && o.id) || ""); if (pid) holdPane(pid, "clic"); };
  } catch (e) {}

  function ensurePane(paneId, url) {
    const n = native(); if (!n) return false;
    n.postMessage({ cmd: "web.show", id: paneId, url: url || PANE_URLS[paneId] || "about:blank", x: -20000, y: 0, w: 1100, h: 760, bg: true });
    return true;
  }

  /* ── Sonde de volet : adresse, titre, état du document, texte visible (longueur + échantillon) ── */
  const PROBE_JS = "(function(){try{var b=document.body;var t=b?b.innerText:'';return JSON.stringify({url:location.href,titre:document.title||'',pret:document.readyState,len:t.length,ech:t.slice(0,500)})}catch(e){return JSON.stringify({url:'',titre:'',pret:'',len:0,ech:''})}})()";
  async function paneProbe(paneId) {
    const t = await paneEval(paneId, PROBE_JS, 6000);
    if (!t) return null;
    try { const j = JSON.parse(t); return (j && typeof j === "object") ? j : null; } catch (e) { return null; }
  }

  /* ── Détection de session : la page affichée est-elle un écran de connexion ? ──
     Renvoie {code, msg, interactif} ou null. « interactif » = l'écran attend un geste
     (choix de compte, mot de passe, QR) : la SSO silencieuse, elle, transite par ces
     mêmes hôtes en quelques secondes — on ne conclut donc pas sur la seule adresse. */
  function loginInfo(paneId, url, ech) {
    let host = ""; try { host = new URL(String(url || "")).host; } catch (e) {}
    const u = String(url || ""), t = norm(ech || "");
    const interactif = /(choisir un compte|choose an account|saisissez votre mot de passe|enter your password|mot de passe|password|verification en deux etapes|two-step|code de securite)/.test(t);
    if (host === "login.microsoftonline.com" || host === "login.live.com" || host === "login.windows.net")
      return { code: "session_microsoft", interactif, msg: "Session Microsoft à reconnecter : le volet " + (SVC_NAMES[paneId] || paneId) + " affiche la page de connexion Microsoft (" + host + "). Ouvre ce service dans Messages et connecte-toi une fois dans le volet — la session restera mémorisée par Nova, et la lecture marchera ensuite en arrière-plan." };
    if (host === "accounts.google.com")
      return { code: "session_google", interactif, msg: "Session Google à reconnecter : le volet Gmail affiche la page de connexion Google (accounts.google.com). Ouvre Gmail dans Messages et connecte-toi une fois dans le volet — la session restera mémorisée par Nova." };
    if (paneId === "wa" && /(scanner( le)? (code|qr)|scan (the )?(code|qr)|relier un appareil|link a device|utilisez whatsapp sur votre|use whatsapp on your (phone|computer)|appareils connectes)/.test(t))
      return { code: "session_whatsapp", interactif: true, msg: "WhatsApp non relié : le volet affiche l'écran de liaison (code QR). Ouvre WhatsApp dans Messages, puis sur ton téléphone : WhatsApp › Réglages › Appareils connectés › Connecter un appareil, et scanne le code. La liaison restera mémorisée par Nova." };
    if (paneId === "tg" && /(qr code|numero de telephone|phone number|log in by qr|connexion par qr)/.test(t))
      return { code: "session_telegram", interactif: true, msg: "Telegram non connecté : le volet affiche l'écran de connexion (code QR ou numéro). Ouvre Telegram dans Messages et connecte-toi une fois — la session restera mémorisée par Nova." };
    if (paneId === "fb" && (u.includes("/login") || u.includes("/checkpoint") || /(se connecter a facebook|log in to facebook|mot de passe oublie)/.test(t)))
      return { code: "session_facebook", interactif: true, msg: "Session Facebook à reconnecter : le volet affiche la page de connexion Facebook. Ouvre Facebook dans Messages et connecte-toi une fois dans le volet." };
    if (paneId === "ig" && (u.includes("/accounts/login") || /(se connecter a instagram|log in to instagram)/.test(t)))
      return { code: "session_instagram", interactif: true, msg: "Session Instagram à reconnecter : le volet affiche la page de connexion Instagram. Ouvre Instagram dans Messages et connecte-toi une fois dans le volet." };
    if (paneId === "li" && (u.includes("/login") || u.includes("/uas/login") || u.includes("/checkpoint")))
      return { code: "session_linkedin", interactif: true, msg: "Session LinkedIn à reconnecter : le volet affiche la page de connexion LinkedIn (" + host + "). Ouvre LinkedIn dans Messages et connecte-toi une fois dans le volet." };
    if (paneId === "x" && (u.includes("/i/flow/login") || u.endsWith("/login")))
      return { code: "session_x", interactif: true, msg: "Session X à reconnecter : le volet affiche la page de connexion X. Ouvre X dans Messages et connecte-toi une fois dans le volet." };
    return null;
  }

  /* ── Attente de contenu : sonde jusqu'à texte stable (readyState complete + longueur
     constante sur 3 sondes) ou bloqueur de session confirmé. Budgets : l'appelant les
     choisit sous les timeouts moteur d'UIPilot (lire 40 s, aller 25 s, etat 15 s). ── */
  async function waitForContent(paneId, budgetMs, stopOnHold = false) {
    const t0 = Date.now();
    let probe = null, lastLen = -1, stable = 0, login = null, loginSince = 0;
    while (Date.now() - t0 < budgetMs) {
      if (stopOnHold && held(paneId)) return { ready: false, probe, login: null, held: true };   // V5-E : Ahadi a pris la main pendant l'attente
      const p = await paneProbe(paneId);
      if (p) {
        probe = p;
        const li = loginInfo(paneId, p.url, p.ech);
        if (li) {
          if (!loginSince) loginSince = Date.now();
          login = li;
          const duree = Date.now() - loginSince;
          // Écran interactif (compte/mot de passe/QR) : bloqué après 4 s de persistance.
          // Simple transit SSO : on laisse jusqu'à 12 s avant de conclure.
          if ((li.interactif && duree > 4000) || duree > 12000) return { ready: false, probe, login };
        } else { login = null; loginSince = 0; }
        if (p.pret === "complete" && p.len >= 120) {
          if (p.len === lastLen) { stable++; if (stable >= 2) return { ready: true, probe }; }
          else stable = 0;
        } else stable = 0;
        lastLen = p.len;
      }
      await sleep(900);
    }
    return { ready: false, probe, login };
  }

  /* ── Extracteurs structurés (best effort par service ; repli texte brut sinon) ── */
  const EXTRACTORS = {
    ol: "(function(){var rows=[].slice.call(document.querySelectorAll('[role=\"option\"]')).filter(function(e){return e.getBoundingClientRect().height>10});var out=[];for(var i=0;i<rows.length&&out.length<25;i++){var el=rows[i];var lignes=(el.innerText||'').split('\\n').map(function(x){return x.trim()}).filter(Boolean);var aria=el.getAttribute('aria-label')||'';if(!aria&&lignes.length<2)continue;out.push({aria:aria,lignes:lignes})}return JSON.stringify({items:out})})()",
    gm: "(function(){var rows=[].slice.call(document.querySelectorAll('tr.zA'));var out=[];for(var i=0;i<rows.length&&out.length<25;i++){var tr=rows[i];var de=tr.querySelector('.yW span[email]')||tr.querySelector('.yW span[title]')||tr.querySelector('.yW span[name]')||tr.querySelector('td.yX .yW span,.yW span');var su=tr.querySelector('.y6 span[id],.y6 span,.bog');var sn=tr.querySelector('.y2');var ti=tr.querySelector('.xW span[title],td.xW span');var it={de:de?(de.getAttribute('email')||de.getAttribute('title')||de.getAttribute('name')||de.textContent||'').trim():'',objet:su?(su.textContent||'').trim():'',heure:ti?(ti.getAttribute('title')||ti.textContent||'').trim():'',apercu:sn?(sn.textContent||'').trim():''};if(it.de||it.objet||it.apercu)out.push(it)}return JSON.stringify({items:out})})()",
    // 26/10 (Ahadi : « Teams ne fait que lister les noms ») : chaque conversation porte aussi son aria-label (nom + dernier message
    // + heure, texte complet chez Teams 2) et les lignes de l'élément ; l'aperçu = la ligne de contenu la plus longue. Lecture seule :
    // aucune conversation n'est ouverte (ouvrir une conversation la marquerait lue et enverrait un accusé de lecture).
    tm: "(function(){function lignes(e){return (e.innerText||'').split('\\n').map(function(x){return x.trim()}).filter(Boolean)}var conv=[];var diag=[];var items=[].slice.call(document.querySelectorAll('[data-tid=\"chat-list-item\"],[data-testid=\"chat-list-item\"],[role=\"treeitem\"]'));for(var i=0;i<items.length&&conv.length<20;i++){var it=items[i];var l=lignes(it);if(!l.length)continue;var tid0=(it.getAttribute('data-tid')||it.getAttribute('data-testid')||'');if(/copilot|^slice-|discover|saved|mentions|activit/i.test(tid0)||l.length>8||it.querySelector('[role=\"treeitem\"],[data-tid=\"chat-list-item\"]'))continue;if(l.length<2&&!/\\d{1,2}[:h]\\d{2}|hier|yesterday|lun|mar|mer|jeu|ven|sam|dim|mon|tue|wed|thu|fri|sat|sun/i.test(it.getAttribute('aria-label')||''))continue;var al=it.getAttribute('aria-label')||'';if(!al){var q=it.querySelector('[aria-label]');if(q)al=q.getAttribute('aria-label')||''}var pv=it.querySelector('[data-tid*=\"preview\"],[data-testid*=\"preview\"],[class*=\"preview\"],[class*=\"Preview\"]');conv.push({l:l,aria:al.slice(0,600),pv:pv?(pv.textContent||'').trim().slice(0,600):'',unread:/unread|non lu/i.test(al)||!!it.querySelector('[data-tid*=\"unread\"],[class*=\"unread\"]')});if(diag.length<8)diag.push({lvl:it.getAttribute('aria-level')||'',tid:it.getAttribute('data-tid')||it.getAttribute('data-testid')||it.getAttribute('role')||'',lignes:l.map(function(x){return x.length}),aria_len:al.length,pv_len:pv?(pv.textContent||'').length:-1})}var msgs=[];var ms=[].slice.call(document.querySelectorAll('[data-tid$=\"-message\"],[data-testid$=\"-message\"],[data-tid=\"channel-pane-message\"],[data-tid=\"chat-pane-message\"]')).filter(function(e,k,arr){var t=(e.getAttribute('data-tid')||e.getAttribute('data-testid')||'');if(/author|list|preview|count|status|edit|input|compose|toast|banner/.test(t))return false;for(var q2=0;q2<arr.length;q2++){if(arr[q2]!==e&&arr[q2].contains(e))return false}return true});for(var j=0;j<ms.length&&msgs.length<30;j++){var m=ms[j];var tid=(m.getAttribute('data-tid')||m.getAttribute('data-testid')||'');var a=m.querySelector('[data-tid=\"message-author-name\"],[data-tid=\"message-author\"],[class*=\"author\"]');msgs.push({de:a?(a.textContent||'').trim():'',texte:(m.innerText||'').trim().slice(0,2000),canal:/channel|post|reply|thread/.test(tid)})}return JSON.stringify({conversations:conv,messages:msgs,diag:diag})})()",
    tg: "(function(){var rows=[].slice.call(document.querySelectorAll('.chatlist-chat,.chatlist .row,[class*=\"chatlist-chat\"]')).filter(function(e){return e.getBoundingClientRect().height>10});var out=[];for(var i=0;i<rows.length&&out.length<25;i++){var l=(rows[i].innerText||'').split('\\n').map(function(x){return x.trim()}).filter(Boolean);if(l.length)out.push({de:l[0]||'',heure:l.length>1?l[l.length-1]:'',apercu:l.slice(1,-1).join(' ')||l[1]||''})}return JSON.stringify({items:out})})()",
  };
  /* C1 (SPARK8) : secours aria Outlook — grammaire établie sur l'échantillon réel
     « préfixe d'état · expéditeur suivi d'une virgule · objet · jeton HH:MM · corps ».
     Succès → { de, objet, heure, apercu } ; échec → null (la cascade retombe alors
     sur le repli honnête, sans champ inventé). */
  function parseAriaOl(aria) {
    try {
      let s = String(aria || "").trim();
      if (!s) return null;
      s = s.replace(/^(Non lu|Lu|Unread|Read)\s+/, "");
      const virg = s.indexOf(",");
      if (virg < 0) return null;
      const de = s.slice(0, virg).trim();
      if (de.length < 2 || de.length > 60) return null;
      if (de.indexOf(":") >= 0) return null;
      if (/\b\d{1,2}:\d{2}\b/.test(de)) return null;
      const reste = s.slice(virg + 1);
      const m = /\b\d{1,2}:\d{2}\b/.exec(reste);
      if (!m) return null;
      const objet = reste.slice(0, m.index).trim();
      const heure = m[0];
      const apercu = reste.slice(m.index + m[0].length).trim();
      return { de: de, objet: objet, heure: heure, apercu: apercu };
    } catch (e) { return null; }
  }
  function normalizeItems(paneId, j) {
    if (!j || typeof j !== "object") return null;
    if (paneId === "tm") {
      const out = [];
      // 26/10 : aperçu = texte réel du dernier message (élément d'aperçu, sinon aria-label débarrassé du nom et de l'heure,
      // sinon la ligne de contenu la plus longue) — plus jamais le seul nom de la conversation.
      const EST_H = /^(\d{1,2}:\d{2}(\s?[AP]M)?|hier|yesterday|aujourd'hui|today|lun\.?|mar\.?|mer\.?|jeu\.?|ven\.?|sam\.?|dim\.?|mon|tue|wed|thu|fri|sat|sun|\d{1,2}\/\d{1,2}(\/\d{2,4})?)$/i;
      for (const c of (j.conversations || [])) {
        const l = Array.isArray(c) ? c : (c.l || []);
        const nom = l[0] || "";
        const heure = l.slice(1).find((x) => EST_H.test(x)) || "";
        const reste = l.slice(1).filter((x) => x !== heure && !EST_H.test(x) && !/^\d+$/.test(x));
        let apercu = (!Array.isArray(c) && c.pv) ? c.pv : "";
        if (!apercu && !Array.isArray(c) && c.aria) {
          let a = String(c.aria);
          if (nom && a.indexOf(nom) === 0) a = a.slice(nom.length);
          a = a.replace(/^[\s,.:;—-]+/, "").replace(/^(chat|conversation|discussion|groupe|group|unread|non lu)[\s,.:;—-]+/i, "");
          if (heure) a = a.replace(heure, "");
          a = a.replace(/[\s,.;—-]+$/, "").trim();
          if (a.length > 3) apercu = a;
        }
        // REPRISE TEAMS (26/10) : un statut de presence n'est JAMAIS un apercu de message
        // (« Out of office », « Occupé »…) — ces lignes sortent des candidates, des deux langues.
        const EST_PRESENCE = /^(out of office|busy|available|offline|online|away|do not disturb|be right back|in a meeting|in a call|focusing|presenting|occupé|occupe|disponible|hors ligne|en ligne|absent|absente|ne pas déranger|en réunion|en appel|de retour bientôt)\.?$/i;
        if (apercu && EST_PRESENCE.test(apercu.trim())) apercu = "";
        if (!apercu) apercu = reste.filter((x) => !EST_PRESENCE.test(x)).slice().sort((x, y) => y.length - x.length)[0] || "";
        out.push({ de: nom, objet: "conversation", heure, apercu });
      }
      for (const m of (j.messages || [])) out.push({ de: m.de || "", objet: "message", heure: "", apercu: m.texte || "" });
      return out.length ? out : null;
    }
    if (paneId === "ol") {
      // C1 (SPARK8) : cascade lignes d'abord (structure), aria parsée en secours, repli honnête.
      const EST_HEURE = /^\d{1,2}:\d{2}$|^\d{1,2}\s+(janv|févr|mars|avr|mai|juin|juil|août|sept|oct|nov|déc)\.?$|^(lun|mar|mer|jeu|ven|sam|dim)\.?$|^(hier|aujourd'hui)$/i;
      // DIRECT-STYLE (23/10) : la ligne [role=option] d'Outlook commence par la
      // PASTILLE avatar — initiales (« T », « FJ », « IA ») ou glyphe d'icône
      // (zone privée) — et le nom de l'expéditeur est le segment SUIVANT.
      // L'ancienne cascade posait de = seg[0], objet = seg[1] : l'expéditeur
      // devenait « T » et l'objet le nom (cas d'un expéditeur au prénom court ; cas d'un prénom seul,
      // 23/10 07:46 — lignes reconstituées et re-simulation au caractère près
      // sur les événements stockés). Les segments 100 % glyphes (icônes
      // épinglé / pièce jointe en queue de ligne) ne sont pas des faits :
      // retirés avant tout découpage.
      const GLYPHE_SEUL = /^[\uE000-\uF8FF\s]+$/;
      const estPastille = (s) => {
        const t = String(s || "").trim();
        if (!t) return false;
        if (GLYPHE_SEUL.test(t)) return true;
        return t.length <= 3 && !/\s/.test(t) && /^[A-Z0-9&]+$/.test(t);
      };
      const nomPlausible = (s) => {
        const t = String(s || "").trim();
        return t.length >= 3 && (/[a-zà-ÿ]/.test(t) || t.indexOf(",") >= 0);
      };
      const REF_RAPPEL = /^<<\s*(.+?)\s*>>$/;
      const out = [];
      for (const it of (j.items || [])) {
        const l = it.lignes || [];
        // 1. Les lignes portent la structure : on les préfère à l'aria fusionnée.
        if (l.length >= 2) {
          const seg = l.map((x) => String(x || "").trim()).filter((x) => x !== "" && !GLYPHE_SEUL.test(x));
          if (seg.length >= 2) {
            let s = seg;
            // 1a. Pastille avatar en tête + nom plausible ensuite : décalage d'un cran.
            if (s.length >= 3 && estPastille(s[0]) && nomPlausible(s[1])) s = s.slice(1);
            // 1b. Ligne de RAPPEL : titre propre, référence au courriel
            // « <<objet>> », heure, extrait du corps (cas d'un expéditeur au prénom court : le sujet du
            // courriel est DANS la référence, pas dans le titre du rappel).
            let idxRef = -1, objetRef = "";
            for (let i = 1; i < Math.min(s.length, 4); i++) {
              const m = REF_RAPPEL.exec(s[i]);
              if (m) { idxRef = i; objetRef = m[1].trim(); break; }
            }
            if (idxRef > 0 && objetRef) {
              const titre = s.slice(1, idxRef).join(" ");
              let rest = s.slice(idxRef + 1);
              let heureR = "";
              if (rest.length && EST_HEURE.test(rest[0])) { heureR = rest[0]; rest = rest.slice(1); }
              const morceaux = [];
              if (titre) morceaux.push(titre);
              if (rest.length) morceaux.push(rest.join(" "));
              out.push({ de: s[0] || "", objet: objetRef, heure: heureR, apercu: morceaux.join(" — ").slice(0, 300) });
              continue;
            }
            // 1c. Forme ordinaire : nom, objet, horodatage éventuel, aperçu.
            const cand = String(s[2] || "").trim();
            const aHeure = cand !== "" && EST_HEURE.test(cand);
            out.push({ de: s[0] || "", objet: s[1] || "", heure: aHeure ? cand : "", apercu: (aHeure ? s.slice(3) : s.slice(2)).join(" ").slice(0, 300) });
            continue;
          }
        }
        // 2. Secours : l'aria n'est parsée que sans lignes exploitables.
        if (it.aria) {
          const p = parseAriaOl(it.aria);
          if (p) { out.push(p); continue; }
          // 3. Repli honnête : on garde l'événement (aria ≤ 320) sans inventer de champ, on ne perd aucun message.
          out.push({ de: "", objet: String(it.aria).slice(0, 320), heure: "", apercu: "" });
        } else {
          out.push({ de: l[0] || "", objet: l[1] || "", heure: "", apercu: l.slice(2).join(" ").slice(0, 300) });
        }
      }
      return out.length ? out : null;
    }
    const out = (j.items || []).filter((it) => it && (it.de || it.objet || it.apercu));
    return out.length ? out : null;
  }

  /* ── Tor : état réel via la coquille (tor.status → NovaNative.onTor → bus « nova:tor »).
     JAMAIS de chargement direct si Tor n'est pas prêt : pas de faux sentiment d'anonymat. ── */
  function torStatus(timeoutMs = 3500) {
    return new Promise((resolve) => {
      const n = native(); if (!n) { resolve(null); return; }
      let done = false;
      const off = bus.on("nova:tor", (st) => { if (done) return; done = true; try { off(); } catch (e) {} resolve(st || null); });
      const to = setTimeout(() => { if (done) return; done = true; try { off(); } catch (e) {} resolve(null); }, timeoutMs);
      void to;
      try { n.postMessage({ cmd: "tor.status" }); } catch (e) { if (!done) { done = true; try { off(); } catch (e2) {} resolve(null); } }
    });
  }
  async function torStart(onProgress) {
    const n = native(); if (!n) return null;
    try { n.postMessage({ cmd: "tor.start" }); } catch (e) { return null; }
    const t0 = Date.now(); let st = null;
    while (Date.now() - t0 < 90000) {
      await sleep(1500);
      st = await torStatus(3000);
      if (st && onProgress) { try { onProgress(st); } catch (e) {} }
      if (st && st.ready) break;
    }
    return st;
  }
  async function torGate(paneId) {
    const st = await torStatus(3500);
    if (!st) return { ok: false, pane: paneId, bloqueur: "tor_etat_inconnu", erreur: "Tor : la coquille n'a renvoyé aucun état (NovaNative.onTor sans réponse). Aucune page n'a été chargée — ni via Tor, ni en direct." };
    if (!st.installed) return { ok: false, pane: paneId, bloqueur: "tor_absent", erreur: "Tor n'est pas installé sur ce Mac : ni binaire tor (Homebrew), ni Tor Browser.app n'ont été trouvés. Pour l'activer : installe Tor Browser (torproject.org/download) — Nova détectera son binaire — puis redemande. Aucune page n'a été chargée en direct." };
    if (!st.ready) return { ok: false, pane: paneId, bloqueur: "tor_non_demarre", erreur: "Tor est installé mais pas prêt (bootstrap " + (st.pct || 0) + " %, en cours d'exécution : " + (st.running ? "oui" : "non") + "). Démarre-le depuis Messages › Navigateur Tor › « Démarrer Tor », attends 100 %, puis réessaie. Aucune page n'a été chargée en direct." };
    return null;
  }

  /* 29/10 : veille des intégrations (Feat_Integrations.swift) — un signal par volet, au plus toutes les 10 min s'il ne change pas. */
  const SESSION_RX = /we need you to sign in again|sign in again to continue|your session has expired|session (has )?expired|votre session a expiré|vous devez vous reconnecter|reconnectez-vous/i;
  const INTEG_LAST = new Map();
  function integSignal(pane, ok, code, msg) {
    if (!["ol", "gm", "tm", "wa", "zm"].includes(pane)) return;
    const key = ok ? "ok" : "ko:" + (code || "");
    const prev = INTEG_LAST.get(pane);
    if (prev && prev.key === key && Date.now() - prev.at < 10 * 60 * 1000) return;
    INTEG_LAST.set(pane, { key, at: Date.now() });
    try { api.post("/api/integrations/signal", { pane, ok: !!ok, code: code || "", msg: msg || "" }).catch(() => {}); } catch (e) {}
  }

  /* ── Lecture complète d'un volet : attente + session + structure + texte ── */
  /* 29/10 (fluidité) : horodatage de la dernière lecture COMPLÈTE de chaque volet — la relève de 60 s et la
     veille Teams de 3 min lisaient toutes deux « tm » (double lecture) ; elles sautent désormais un volet lu
     récemment (veille : 50 s, relève : 30 s), quelle que soit la source de la lecture. */
  const LAST_READ = new Map();
  const readRecently = (pid, ms = 50000) => Date.now() - (LAST_READ.get(pid) || 0) < ms;
  async function readPane(paneId, opts = {}) {
    try { return await readPaneInner(paneId, opts); } finally { if (!opts.q) LAST_READ.set(paneId, Date.now()); }
  }
  async function readPaneInner(paneId, opts = {}) {
    if (!native()) return { ok: false, erreur: "coquille native absente : les volets web ne sont pas pilotables depuis l'aperçu" };
    if (paneId === "tor") { const g = await torGate(paneId); if (g) return g; }
    // V5-E : une lecture de Nova (opts.user absent) respecte la pause ; celle qu'Ahadi lance lui-même, non.
    const stop = () => !opts.user && held(paneId);
    if (stop()) return heldResult(paneId);
    ensurePane(paneId, opts.url);
    const budget = opts.budgetMs || 26000;
    const w = await waitForContent(paneId, budget, !opts.user);
    if (w.held || stop()) return heldResult(paneId);
    const probe = w.probe || {};
    if (w.login) { integSignal(paneId, false, "session", w.login.msg); return { ok: false, pane: paneId, bloqueur: w.login.code, erreur: w.login.msg, url: probe.url || "" }; }
    let items = null, source = "", diagTm = null;
    if (paneId === "wa") {
      const c = await paneChats(paneId);
      if (c !== null) {
        // PRO-5 (M7) : producteur de l'instantané WhatsApp — le format brut « g⇥nom⇥badge⇥aperçu »
        // est exactement celui que WebMail.putChats consomme. Échec silencieux : la lecture prime.
        api.post("/api/webchats", { text: String(c) }).catch(() => {});
        items = String(c).split("\n").filter(Boolean).map((l) => { const p = l.split("\t"); return { de: p[1] || "", objet: (p[2] ? p[2] + " non lu(s)" : "") + (p[0] === "1" ? " · groupe" : ""), heure: "", apercu: p[3] || "" }; });
        source = "WhatsApp — conversations non lues";
      }
    }
    if (!items && EXTRACTORS[paneId]) {
      const raw = await paneEval(paneId, EXTRACTORS[paneId], 6000);
      if (raw) { try { const pj = JSON.parse(raw); if (paneId === "tm" && pj && pj.diag) diagTm = pj.diag; items = normalizeItems(paneId, pj); if (items) source = SVC_NAMES[paneId] + " — liste extraite de la page"; } catch (e) {} }
    }
    if (stop()) return heldResult(paneId);
    const text = await paneText(paneId);
    const clean = String(text || "").trim();
    // 29/10 : veille des intégrations — bandeau « reconnecte-toi » DANS l'app (session expirée) ou lecture saine.
    if (clean.length >= 80) {
      const exp = SESSION_RX.exec(clean.slice(0, 4000));
      if (exp) integSignal(paneId, false, "session", "la session de " + (SVC_NAMES[paneId] || paneId) + " dans Nova a expiré (« " + exp[0] + " »).");
      else integSignal(paneId, true);
    }
    const q = String(opts.q || "").trim();
    // PRO-5 (M7) : producteur des instantanés mail/Teams. On ne poste que le texte COMPLET et non filtré
    // (q vide) des boîtes connues de WebMail, ≥ 80 caractères (le plancher de WebMail.put) — un texte
    // filtré par recherche fausserait la détection des lignes nouvelles. Échec silencieux : la lecture prime.
    // SPARK6 (22/10) : on JOINT l'extraction structurée déjà calculée (items) — le texte part TOUJOURS,
    // les items s'y ajoutent (≤ 25, 4 champs coercés et bornés) ; sans items, corps identique à avant.
    if (!q && clean.length >= 80 && (paneId === "ol" || paneId === "gm" || paneId === "tm")) {
      const corps = { id: paneId, text: clean.slice(0, 12000), titre: String(probe.titre || "").slice(0, 200) };
      if (paneId === "tm" && diagTm) corps.diag = diagTm;   // 26/10 : forme du DOM Teams (longueurs seulement) pour le diagnostic   // 24/10 : le titre porte le compteur de non-lus (jauge de l'Accueil)
      try {
        if (Array.isArray(items) && items.length) {
          const propres = [];
          for (const it of items.slice(0, 25)) {
            if (!it || typeof it !== "object") continue;
            propres.push({ de: String(it.de || "").slice(0, 200), objet: String(it.objet || "").slice(0, 320), heure: String(it.heure || "").slice(0, 80), apercu: String(it.apercu || "").slice(0, paneId === "tm" ? 2000 : 300) });
          }
          if (propres.length) corps.items = propres;
        }
      } catch (e) {}
      api.post("/api/webmail", corps).catch(() => {});
    }
    if (items && items.length) {
      let list = items;
      if (q) {
        const nq = norm(q);
        list = items.filter((it) => norm([it.de, it.objet, it.apercu].join(" ")).includes(nq));
        if (!list.length) return { ok: true, pane: paneId, url: probe.url || "", source, compte: 0, messages: [], note: "La liste est lue (" + items.length + " élément(s)), mais aucun ne contient « " + q + " »." };
      }
      const out = { ok: true, pane: paneId, url: probe.url || "", titre: probe.titre || "", source, compte: list.length, messages: list };
      if (clean) out.extrait = clean.slice(0, 700);
      return out;
    }
    if (clean.length >= 40) {
      let txt = clean;
      if (q) { const lines = txt.split("\n").filter((l) => norm(l).includes(norm(q))); txt = lines.join("\n") || "(aucune ligne ne contient « " + q + " »)"; }
      return { ok: true, pane: paneId, url: probe.url || "", titre: probe.titre || "", texte: txt.slice(0, 3400), chargement: w.ready ? "complet" : "partiel — la page chargeait encore quand le budget d'attente s'est épuisé" };
    }
    return { ok: false, pane: paneId, url: probe.url || "",
      erreur: "Page sans contenu lisible après " + Math.round(budget / 1000) + " s d'attente — adresse : " + (probe.url || "inconnue") + ", document : " + (probe.pret || "?") + ", texte visible : " + (probe.len || 0) + " caractère(s). Cause probable : le service est resté sur son écran de chargement, ou il refuse l'affichage dans un volet intégré. Ouvre " + (SVC_NAMES[paneId] || "le service") + " dans Messages pour voir ce que le volet affiche réellement." };
  }

  /* ── API publique pour les modules (Messages : diagnostic + navigateur + Tor) ── */
  const NovaPanes = {
    // Lecture demandée par Ahadi (boutons de Messages) : son geste, jamais bloqué par la pause.
    read: (name, opts) => readPane(PANES[norm(name)] || String(name || ""), Object.assign({}, opts || {}, { user: true })),
    // V5-E : état réel de passation (activité de Nova en cours + pause tenue par Ahadi).
    activity: (name) => actState(PANES[norm(name)] || String(name || "")),
    activeIds: () => [...new Set([...ACT.keys(), ...HOLD.keys()])],
    hold: (name, why) => holdPane(PANES[norm(name)] || String(name || ""), why === "arret" ? "arret" : why === "clic" ? "clic" : "main"),
    release: (name, onlyWhy) => releasePane(PANES[norm(name)] || String(name || ""), onlyWhy || ""),
    state: async (name) => {
      const id = PANES[norm(name)] || String(name || "");
      if (!native()) return { ok: false, erreur: "coquille native absente" };
      ensurePane(id);
      const p = await paneProbe(id);
      if (!p) return { ok: false, pane: id, erreur: "volet sans réponse (pas encore créé ou page muette)" };
      const li = loginInfo(id, p.url, p.ech);
      return { ok: true, pane: id, url: p.url, titre: p.titre, pret: p.pret, texte_visible: p.len, session: li ? li.code : (p.len >= 120 ? "contenu présent" : "indéterminé"), bloqueur: li ? li.msg : "" };
    },
    torStatus, torStart, panes: PANES, urls: PANE_URLS,
  };
  try { window.NovaPanes = NovaPanes; } catch (e) {}

  /* 26/10 (Ahadi : « pourquoi je ne reçois pas les directs de Teams ? ») — Teams n'a ni API ni Mail.app :
     ses messages n'entraient que lorsqu'un outil lisait le volet (5 h de trou ce matin). Veille légère :
     lecture du volet Teams en arrière-plan toutes les 3 min de 07:00 à 21:00, jamais pendant une pause
     tenue par Ahadi, jamais deux à la fois. Lecture seule : aucun clic, aucun envoi. */
  if (!window.__novaVeilleTeams) {
    window.__novaVeilleTeams = true;
    let tmBusy = false;
    /* 29/10 (Ahadi : « Nova lague, surtout dans la messagerie : les clics répondent avec retard, les fenêtres bougent seules ») —
       la veille ne lit plus JAMAIS pendant qu'Ahadi travaille : seulement après 2 min sans clic ni frappe, et pas quand
       Messages est à l'écran. */
    let lastInput = Date.now();
    for (const ev of ["pointerdown", "keydown", "wheel"]) { try { window.addEventListener(ev, () => { lastInput = Date.now(); }, { capture: true, passive: true }); } catch (e) {} }
    const onMessages = () => { try { return document.visibilityState === "visible" && /messages/i.test(String(location.hash || "") + " " + String((document.querySelector(".nav-item.on, [aria-current=page]") || {}).textContent || "")); } catch (e) { return false; } };
    const veilleTeams = async () => {
      const h = new Date().getHours();
      if (tmBusy || h < 7 || h >= 21 || !native() || held("tm") || readRecently("tm")) return;
      if (Date.now() - lastInput < 120000 || onMessages()) return;
      tmBusy = true;
      try { await readPane("tm", { budgetMs: 20000 }); } catch (e) {} finally { tmBusy = false; }
    };
    setTimeout(veilleTeams, 90 * 1000);
    setInterval(veilleTeams, 3 * 60 * 1000);
  }

  /* DIAG2 P2 : énumération UNIQUE des éléments cliquables d'un volet — le clic et la liste
     « cliquables » de page-lire partagent EXACTEMENT les mêmes sélecteurs et le même ordre,
     y compris les lignes de conversations (Teams/Outlook/Gmail) que lisent les extracteurs,
     qui ne sont ni des boutons ni des liens. Index 1-based des deux côtés. */
  const CLIC_SEL = 'button,a,[role="button"],input[type="submit"],[data-tid="chat-list-item"],[data-testid="chat-list-item"],[role="treeitem"],[role="option"]';
  const CLIC_CORE = `var norm=function(s){return String(s||"").toLowerCase().normalize("NFD").replace(/[\\u0300-\\u036f]/g,"")};var els=[...document.querySelectorAll(${JSON.stringify(CLIC_SEL)})].filter(function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0});var lab=function(e){var t=(e.innerText||e.textContent||"").split("\\n").map(function(x){return x.trim()}).filter(Boolean);return t[0]||""};`;
  const CLIC_ENUM_JS = `(function(){${CLIC_CORE}return JSON.stringify(els.map(function(e,i){return {n:i+1,label:lab(e).slice(0,80)}}))})()`;
  /* AUDIT-24/10: P0 — un clic dont le libellé / aria-label / title / data-tid évoque un envoi, une suppression
     ou un paiement (DANGER) n'est JAMAIS exécuté sans « confirmed » (carte de confirmation d'Ahadi côté moteur).
     Sur un volet de messagerie, un bouton sans aucun libellé (icône « avion » d'envoi) est traité pareil. */
  const MSG_PANES = ["ol", "gm", "tm", "wa", "tg", "fb", "ig", "li", "x"];
  const clicJS = (q, confirmed, msgPane) => `(function(){${CLIC_CORE}var q=${JSON.stringify(String(q || ""))};var t=null;if(/^#?\\d+$/.test(q.trim())){t=els[parseInt(q.trim().replace("#",""),10)-1]||null}else{var nq=norm(q);t=els.find(function(e){return norm(lab(e))===nq})||els.find(function(e){return norm(e.innerText||e.textContent||"").includes(nq)})}if(!t)return JSON.stringify({ok:false,erreur:'élément introuvable : '+q});var l=lab(t);var dz=new RegExp(${JSON.stringify(DANGER.source)},"i");var sig=l+" "+(t.getAttribute("aria-label")||"")+" "+(t.title||"")+" "+(t.getAttribute("data-tid")||"")+" "+(t.getAttribute("data-testid")||"")+" "+(t.getAttribute("data-icon")||"");var isSub=(t.tagName==="INPUT"&&/^(submit|image)$/i.test(t.type||""))||(t.tagName==="BUTTON"&&(!t.getAttribute("type")||/^submit$/i.test(t.getAttribute("type")))&&!!t.closest("form"));if(!${confirmed ? "true" : "false"}&&(dz.test(sig)||isSub||${msgPane ? "true" : "false"}&&!l.trim()&&!(t.getAttribute("aria-label")||"").trim()))return JSON.stringify({ok:false,confirmation:true,label:(l||t.getAttribute("aria-label")||"").slice(0,80),erreur:"action sensible (envoi/suppression possible) : confirmation d'Ahadi requise"});t.click();return JSON.stringify({ok:true,clique:l.slice(0,80),effet:{clique:l.slice(0,80),present:document.contains(t)}})})()`;

  /* ── FIXES-MAIL (24/10) : LECTURE DU CORPS d'un message dans le volet Gmail / Outlook,
     en ARRIÈRE-PLAN (volet hors écran, aucune fenêtre ni app au premier plan), lecture seule.
     Le moteur (BodyFetcher.fetchWebPane) envoie « page / corps » avec {de, objet, apercu}.
     evaluateJavaScript n'attend pas une promesse : le script de volet démarre un travail
     asynchrone qui dépose son résultat dans window.__novaCorps[clé] ; la fenêtre le relève
     par sondes courtes (budget 15 s). Les scripts de volet sont des fonctions AUTONOMES
     (aucune fermeture) sérialisées par toString().
     · Gmail : la ligne tr.zA est retrouvée par objet/expéditeur/aperçu ; ses identifiants
       (data-legacy-last-message-id, data-legacy-thread-id) permettent un fetch MÊME ORIGINE
       (cookies de session du volet) de la source du message (view=om, décodage MIME) puis,
       à défaut, de la vue impression (view=pt). Aucune navigation du volet, aucun clic.
     · Outlook : clic sur la ligne [role=option] du volet caché, lecture du volet de lecture
       (plusieurs sélecteurs), puis remise « non lu » si la ligne l'était, retour à la liste
       si la lecture a remplacé la liste. Refus si le volet a le focus (Ahadi le regarde). */
  function paneGmailCorps(K, Q) {
    window.__novaCorps = window.__novaCorps || {};
    window.__novaCorps[K] = { fini: false };
    var put = function (r) { window.__novaCorps[K] = { fini: true, r: r }; };
    var norm = function (s) { return String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/\s+/g, " ").trim(); };
    var strip = function (s) { var t = norm(s), p = t.replace(/^(re|fw|fwd|tr)\s*:\s*/, ""); while (p !== t) { t = p; p = t.replace(/^(re|fw|fwd|tr)\s*:\s*/, ""); } return t.replace(/(…|\.\.\.)$/, "").trim(); };
    var attr = function (root, name) { var e = root.querySelector("[" + name + "]"); return e ? String(e.getAttribute(name) || "") : ""; };
    var decodeBytes = function (bin, cs) { var u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i) & 255; try { return new TextDecoder(cs || "utf-8").decode(u); } catch (e) { return new TextDecoder("utf-8").decode(u); } };
    var decodePart = function (body, enc, cs) {
      enc = String(enc || "").toLowerCase();
      if (enc.indexOf("base64") >= 0) { try { return decodeBytes(atob(body.replace(/[^A-Za-z0-9+\/=]/g, "")), cs); } catch (e) { return body; } }
      if (enc.indexOf("quoted-printable") >= 0) { var b = body.replace(/=\r?\n/g, "").replace(/=([0-9A-Fa-f]{2})/g, function (_, h) { return String.fromCharCode(parseInt(h, 16)); }); return decodeBytes(b, cs); }
      return body;
    };
    var hdr = function (head, name) { var m = new RegExp("^" + name + ":\\s*([^\\n]*(?:\\n[ \\t][^\\n]*)*)", "im").exec(head); return m ? m[1].replace(/\n[ \t]+/g, " ").trim() : ""; };
    var mime = function (raw, depth) {
      var out = { plain: "", html: "" };
      raw = String(raw || "").replace(/\r\n/g, "\n");
      var cut = raw.indexOf("\n\n");
      var head = cut >= 0 ? raw.slice(0, cut) : raw, body = cut >= 0 ? raw.slice(cut + 2) : "";
      var ct = hdr(head, "Content-Type").toLowerCase(), enc = hdr(head, "Content-Transfer-Encoding");
      var csm = /charset="?([^";\s]+)/i.exec(hdr(head, "Content-Type")); var cs = csm ? csm[1] : "utf-8";
      if (ct.indexOf("multipart/") === 0 && depth < 6) {
        var bm = /boundary="?([^";]+)"?/i.exec(hdr(head, "Content-Type"));
        if (!bm) return out;
        var parts = body.split("--" + bm[1]);
        for (var i = 1; i < parts.length; i++) {
          var p = parts[i]; if (p.indexOf("--") === 0) break;
          var r = mime(p.replace(/^\n/, ""), depth + 1);
          if (!out.plain && r.plain) out.plain = r.plain;
          if (!out.html && r.html) out.html = r.html;
        }
        return out;
      }
      if (ct.indexOf("text/html") === 0) out.html = decodePart(body, enc, cs);
      else if (ct === "" || ct.indexOf("text/plain") === 0) out.plain = decodePart(body, enc, cs);
      return out;
    };
    /* Gmail impose Trusted Types : DOMParser/innerHTML sur une chaîne peuvent lever. Extraction
       texte par expressions régulières seulement (aucun « sink » HTML). */
    var ent = function (s) { return String(s || "").replace(/&#x([0-9a-f]+);/gi, function (_, h) { return String.fromCodePoint(parseInt(h, 16)); }).replace(/&#(\d+);/g, function (_, n) { return String.fromCodePoint(parseInt(n, 10)); }).replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;|&apos;/g, "'").replace(/&amp;/g, "&"); };
    var htmlText = function (h) { try { var s = String(h || "").replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, " ").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|tr|li|h[1-6]|table)>/gi, "\n").replace(/<[^>]+>/g, " "); return ent(s).replace(/[ \t ]+/g, " ").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").trim(); } catch (e) { return ""; } };
    var getText = function (url, ms) {
      var ctl = (typeof AbortController !== "undefined") ? new AbortController() : null;
      var to = setTimeout(function () { if (ctl) ctl.abort(); }, ms);
      return fetch(url, { credentials: "include", signal: ctl ? ctl.signal : undefined }).then(function (r) { clearTimeout(to); if (String(r.url || "").indexOf("accounts.google.com") >= 0) throw new Error("session"); if (!r.ok) throw new Error("HTTP " + r.status); return r.text(); });
    };
    (async function () {
      try {
        if (location.host.indexOf("mail.google.com") < 0) { put({ ok: false, code: "session", erreur: "le volet Gmail n'est pas sur mail.google.com (" + location.host + ")" }); return; }
        var qs = strip(Q.objet), qd = norm(Q.de), qa = norm(Q.apercu).slice(0, 30);
        var rows = [].slice.call(document.querySelectorAll("tr.zA"));
        var best = null, bs = 0;
        rows.forEach(function (tr) {
          var su = tr.querySelector(".y6 span[id],.y6 span,.bog"); var s = strip(su ? su.textContent : "");
          var de = tr.querySelector(".yW span[email]") || tr.querySelector(".yW span[title]") || tr.querySelector(".yW span[name]") || tr.querySelector(".yW span");
          var d = de ? norm([de.getAttribute("email"), de.getAttribute("title"), de.getAttribute("name"), de.textContent].join(" ")) : "";
          var sn = norm((tr.querySelector(".y2") || {}).textContent || "");
          var sc = 0;
          if (qs && s && (s === qs || s.indexOf(qs) === 0 || qs.indexOf(s) === 0)) sc += 2;
          if (qd && d && d.indexOf(qd) >= 0) sc += 2;
          if (qa.length >= 12 && sn && (sn.indexOf(qa.slice(0, 20)) >= 0 || qa.indexOf(sn.replace(/^[-–\s]+/, "").slice(0, 20)) >= 0)) sc += 1;
          if (sc > bs) { bs = sc; best = tr; }
        });
        var need = (qs && qd) ? 3 : 2;
        if (!best || bs < need) { put({ ok: false, code: "introuvable", erreur: "ligne introuvable dans la liste du volet Gmail (" + rows.length + " lignes examinées)" }); return; }
        var lastHex = attr(best, "data-legacy-last-message-id"), thHex = attr(best, "data-legacy-thread-id"), thPerm = attr(best, "data-thread-id").replace(/^#/, "");
        var bm = /^\/mail\/u\/\d+\//.exec(location.pathname); var base = location.origin + (bm ? bm[0] : "/mail/u/0/");
        var ik = (window.GLOBALS && window.GLOBALS[9]) ? String(window.GLOBALS[9]) : "";
        var pre = base + "?" + (ik ? "ik=" + encodeURIComponent(ik) + "&" : "");
        var corps = "", via = "", verif = false;
        if (lastHex && /^[0-9a-f]+$/i.test(lastHex) && typeof BigInt !== "undefined") {
          try {
            var src = await getText(pre + "view=om&permmsgid=msg-f:" + BigInt("0x" + lastHex).toString(), 7000);
            var pm = /<pre[^>]*id="?raw_message_text"?[^>]*>([\s\S]*?)<\/pre>/i.exec(src) || /<pre[^>]*>([\s\S]*?)<\/pre>/i.exec(src);
            if (pm) { var mm = mime(ent(pm[1].replace(/<[^>]+>/g, "")), 0); corps = (mm.plain || htmlText(mm.html) || "").trim(); via = "gmail-source"; }
          } catch (e) { if (String(e && e.message) === "session") { put({ ok: false, code: "session", erreur: "session Google expirée dans le volet Gmail" }); return; } }
        }
        if (corps && qa.length >= 12) verif = norm(corps).indexOf(qa.slice(0, 20)) >= 0;
        if ((!corps || (qa.length >= 12 && !verif)) && (thHex || thPerm)) {
          try {
            var pt = await getText(pre + "view=pt&search=all&th=" + encodeURIComponent(thHex || thPerm), 7000);
            var chunks = pt.split(/<table[^>]*class="?message"?[^>]*>/i);
            var t2 = htmlText(chunks.length > 1 ? chunks[chunks.length - 1] : pt);
            if (t2 && (!corps || (qa.length >= 12 && norm(t2).indexOf(qa.slice(0, 20)) >= 0))) { corps = t2; via = "gmail-impression"; verif = qa.length >= 12 ? norm(t2).indexOf(qa.slice(0, 20)) >= 0 : false; }
          } catch (e) { if (String(e && e.message) === "session") { put({ ok: false, code: "session", erreur: "session Google expirée dans le volet Gmail" }); return; } }
        }
        if (!corps) { put({ ok: false, code: "vide", erreur: "ligne trouvée, mais ni la source ni la vue impression n'ont rendu de texte" }); return; }
        put({ ok: true, corps: corps.slice(0, 20000), via: via, verif: verif, fil: thHex || thPerm });
      } catch (e) { put({ ok: false, code: "script", erreur: "lecture Gmail : " + String((e && e.message) || e).slice(0, 160) }); }
    })();
    return "demarre";
  }
  function paneOutlookCorps(K, Q) {
    window.__novaCorps = window.__novaCorps || {};
    window.__novaCorps[K] = { fini: false };
    var put = function (r) { window.__novaCorps[K] = { fini: true, r: r }; };
    var norm = function (s) { return String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/\s+/g, " ").trim(); };
    var strip = function (s) { var t = norm(s), p = t.replace(/^(re|fw|fwd|tr)\s*:\s*/, ""); while (p !== t) { t = p; p = t.replace(/^(re|fw|fwd|tr)\s*:\s*/, ""); } return t.replace(/(…|\.\.\.)$/, "").trim(); };
    var vis = function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 10; };
    var SEL = ['[aria-label="Corps du message"]', '[aria-label="Message body"]', '#UniqueMessageBody', 'div[id^="UniqueMessageBody"]', '[role="main"] [role="document"]', '[role="document"]'];
    var bodies = function () { var out = []; SEL.forEach(function (s) { [].slice.call(document.querySelectorAll(s)).forEach(function (e) { if (out.indexOf(e) < 0) out.push(e); }); }); return out.filter(function (e) { return (e.innerText || "").trim().length > 0; }); };
    var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
    (async function () {
      try {
        if (document.hasFocus()) { put({ ok: false, code: "premier_plan", erreur: "volet Outlook au premier plan (Ahadi le consulte) — lecture différée pour ne rien changer à son écran" }); return; }
        var qs = strip(Q.objet), qd = norm(Q.de), qa = norm(Q.apercu).slice(0, 30);
        var rows = [].slice.call(document.querySelectorAll('[role="option"]')).filter(vis);
        var best = null, bs = 0;
        rows.forEach(function (el) {
          var t = norm((el.getAttribute("aria-label") || "") + " " + (el.innerText || ""));
          var sc = 0;
          if (qs && t.indexOf(qs.slice(0, 60)) >= 0) sc += 2;
          if (qd && t.indexOf(qd) >= 0) sc += 2;
          if (qa.length >= 12 && t.indexOf(qa.slice(0, 20)) >= 0) sc += 1;
          if (sc > bs) { bs = sc; best = el; }
        });
        var need = (qs && qd) ? 3 : 2;
        if (!best || bs < need) { put({ ok: false, code: "introuvable", erreur: "ligne introuvable dans la liste du volet Outlook (" + rows.length + " lignes examinées)" }); return; }
        var wasUnread = /^(non lu|unread)\b/i.test(String(best.getAttribute("aria-label") || "").trim());
        var before = bodies().map(function (e) { return (e.innerText || "").trim().slice(0, 200); });
        ["pointerdown", "mousedown", "pointerup", "mouseup"].forEach(function (ty) { try { best.dispatchEvent(new MouseEvent(ty, { bubbles: true, cancelable: true, view: window })); } catch (e) {} });
        best.click();
        var corps = "", t0 = Date.now();
        while (Date.now() - t0 < 10000) {
          await sleep(400);
          var bs2 = bodies();
          var fresh = bs2.filter(function (e) { return before.indexOf((e.innerText || "").trim().slice(0, 200)) < 0; });
          var pool = fresh.length ? fresh : (Date.now() - t0 > 3000 ? bs2 : []);
          if (!pool.length) continue;
          var pick = pool[0];
          if (qa.length >= 12) { for (var i = 0; i < pool.length; i++) { if (norm(pool[i].innerText).indexOf(qa.slice(0, 20)) >= 0) { pick = pool[i]; break; } } }
          corps = String(pick.innerText || "").trim();
          if (corps) break;
        }
        var restaure = false;
        if (wasUnread) {
          await sleep(300);
          var rx = /marquer comme non lu|mark as unread/i;
          var btn = [].slice.call(best.querySelectorAll("button,[role='button']")).find(function (b) { return rx.test((b.getAttribute("aria-label") || "") + " " + (b.title || "")); })
            || [].slice.call(document.querySelectorAll("button,[role='button'],[role='menuitem']")).find(function (b) { return rx.test((b.getAttribute("aria-label") || "") + " " + (b.title || "") + " " + (b.innerText || "")); });
          if (btn) { try { btn.click(); restaure = true; } catch (e) {} }
        }
        if ([].slice.call(document.querySelectorAll('[role="option"]')).filter(vis).length === 0) { try { history.back(); } catch (e) {} }
        if (!corps) { put({ ok: false, code: "vide", erreur: "ligne ouverte, mais le volet de lecture n'a rendu aucun corps en 10 s", non_lu_restaure: restaure }); return; }
        put({ ok: true, corps: corps.slice(0, 20000), via: "outlook-lecture", non_lu_restaure: restaure, etait_non_lu: wasUnread });
      } catch (e) { put({ ok: false, code: "script", erreur: "lecture Outlook : " + String((e && e.message) || e).slice(0, 160) }); }
    })();
    return "demarre";
  }
  async function readBody(paneId, d) {
    if (paneId !== "gm" && paneId !== "ol") return { ok: false, code: "boite", erreur: "lecture de corps : volet non pris en charge (" + paneId + ")" };
    const t0 = Date.now();
    ensurePane(paneId);
    let p0 = await paneProbe(paneId);
    if (!p0 || (p0.len || 0) < 120) {
      const w = await waitForContent(paneId, 10000, true);
      if (w.held) return heldResult(paneId);
      if (w.login) return { ok: false, code: "session", erreur: w.login.msg };
      if (!w.probe || (w.probe.len || 0) < 120) return { ok: false, code: "muet", erreur: "volet " + (SVC_NAMES[paneId] || paneId) + " pas encore chargé (10 s d'attente)" };
      p0 = w.probe;
    } else {
      const li = loginInfo(paneId, p0.url, p0.ech);
      if (li) return { ok: false, code: "session", erreur: li.msg };
    }
    if (held(paneId)) return heldResult(paneId);   // V5-E : pas de script de lecture lancé dans un volet qu'Ahadi tient
    const K = "c" + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
    const Q = { de: String(d.de || "").slice(0, 200), objet: String(d.objet || "").slice(0, 320), apercu: String(d.apercu || "").slice(0, 300) };
    const fn = paneId === "gm" ? paneGmailCorps : paneOutlookCorps;
    const start = await paneEval(paneId, "(" + fn.toString() + ")(" + JSON.stringify(K) + "," + JSON.stringify(Q) + ")", 6000);
    if (start == null || String(start).indexOf("demarre") < 0) return { ok: false, code: "muet", erreur: "le volet " + (SVC_NAMES[paneId] || paneId) + " n'a pas exécuté le script de lecture" };
    const pollJS = "(function(){try{var x=(window.__novaCorps||{})[" + JSON.stringify(K) + "];if(!x)return 'null';if(x.fini){delete window.__novaCorps[" + JSON.stringify(K) + "];}return JSON.stringify(x)}catch(e){return 'null'}})()";
    const tRead = Date.now();   // budget de lecture : 15 s après le démarrage du script (l'attente d'hydratation du volet est à part, ≤ 10 s)
    void t0;
    while (Date.now() - tRead < 15000) {
      await sleep(600);
      if (held(paneId)) {   // V5-E : « Arrêter » / prise de main pendant la lecture — on cesse de relever et on le dit
        paneEval(paneId, "(function(){try{delete (window.__novaCorps||{})[" + JSON.stringify(K) + "]}catch(e){}return ''})()", 2000);
        return heldResult(paneId);
      }
      const raw = await paneEval(paneId, pollJS, 4000);
      if (!raw || raw === "null") continue;
      let x = null; try { x = JSON.parse(raw); } catch (e) { x = null; }
      if (x && x.fini) return x.r || { ok: false, code: "script", erreur: "résultat vide" };
    }
    paneEval(paneId, "(function(){try{delete (window.__novaCorps||{})[" + JSON.stringify(K) + "]}catch(e){}return ''})()", 2000);
    return { ok: false, code: "delai", erreur: "lecture du corps : délai dépassé dans le volet " + (SVC_NAMES[paneId] || paneId) };
  }

  /* ── 26/10 (Ahadi : « fais le brouillon directement dans Outlook / Teams ») — BROUILLONS DANS LES VOLETS ──
     Outlook web : « Nouveau message », À / Cc / Objet / corps, puis attente de l'enregistrement automatique du
     brouillon par Outlook (serveur : visible partout). Teams : conversation retrouvée dans la liste, texte posé dans
     la zone de saisie EN UN SEUL PARAGRAPHE (un retour à la ligne pourrait déclencher l'envoi). Jamais de clic sur
     Envoyer, jamais Entrée. Scripts autonomes (toString), résultat relevé par sondes comme readBody. */
  function paneOutlookBrouillon(K, Q) {
    window.__novaCorps = window.__novaCorps || {};
    window.__novaCorps[K] = { fini: false };
    var put = function (r) { window.__novaCorps[K] = { fini: true, r: r }; };
    var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
    var vis = function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    var lab = function (e) { return ((e.getAttribute("aria-label") || "") + " " + (e.getAttribute("title") || "") + " " + (e.getAttribute("placeholder") || "")).trim(); };
    var all = function (sel) { return [].slice.call(document.querySelectorAll(sel)).filter(vis); };
    var wait = async function (fn, ms) { var t = Date.now(); while (Date.now() - t < ms) { var x = fn(); if (x) return x; await sleep(300); } return null; };
    (async function () {
      try {
        var nouveau = all('button,[role="button"]').find(function (b) { var t = (lab(b) + " " + (b.textContent || "")).toLowerCase(); return /nouveau (message|courrier)|new (mail|message)/.test(t); });
        if (!nouveau) { put({ ok: false, erreur: "bouton « Nouveau message » introuvable dans Outlook web (session ou affichage différent)" }); return; }
        nouveau.click();
        var corps = await wait(function () {
          var c = all('div[contenteditable="true"]').filter(function (e) { return /corps|body|message/i.test(lab(e)); });
          return c.length ? c[c.length - 1] : null;
        }, 15000);
        if (!corps) { put({ ok: false, erreur: "la fenêtre de rédaction ne s'est pas ouverte" }); return; }
        await sleep(600);
        var champ = function (rx) { return all('input,div[contenteditable="true"],[role="combobox"]').find(function (e) { return e !== corps && rx.test(lab(e)); }); };
        var poser = function (el, val) { el.focus(); if (el.isContentEditable) { document.execCommand("insertText", false, val); } else { var st = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), "value"); if (st && st.set) st.set.call(el, val); else el.value = val; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); } };
        var manque = [];
        if (Q.a) { var to = champ(/^(à|to)\b|^(à|to)$/i); if (to) { poser(to, Q.a.split(/\s*,\s*/).join("; ") + ";"); } else manque.push("destinataires"); await sleep(500); }
        if (Q.cc) { var cc = champ(/^cc\b/i); if (cc) { poser(cc, Q.cc.split(/\s*,\s*/).join("; ") + ";"); } else manque.push("copie"); await sleep(400); }
        if (Q.objet) { var ob = champ(/objet|subject/i); if (ob) poser(ob, Q.objet); else manque.push("objet"); await sleep(300); }
        corps.focus();
        document.execCommand("insertHTML", false, Q.html || "");
        corps.dispatchEvent(new Event("input", { bubbles: true }));
        var sauve = await wait(function () { var t = (document.body.innerText || ""); return /brouillon enregistr|draft saved|enregistr[ée] [àa] \d/i.test(t) ? true : null; }, 25000);
        put({ ok: true, sauve: !!sauve, manque: manque });
      } catch (e) { put({ ok: false, erreur: "script Outlook : " + String(e && e.message || e).slice(0, 160) }); }
    })();
    return "demarre";
  }

  function paneTeamsBrouillon(K, Q) {
    window.__novaCorps = window.__novaCorps || {};
    window.__novaCorps[K] = { fini: false };
    var put = function (r) { window.__novaCorps[K] = { fini: true, r: r }; };
    var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
    var vis = function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    var norm = function (s) { return String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/\s+/g, " ").trim(); };
    var wait = async function (fn, ms) { var t = Date.now(); while (Date.now() - t < ms) { var x = fn(); if (x) return x; await sleep(300); } return null; };
    (async function () {
      try {
        var nq = norm(Q.conversation);
        var items = [].slice.call(document.querySelectorAll('[data-tid="chat-list-item"],[data-testid="chat-list-item"],[role="treeitem"]')).filter(vis);
        var premiere = function (e) { return norm((e.innerText || "").split("\n")[0]); };
        var it = items.find(function (e) { return premiere(e) === nq; }) || items.find(function (e) { return premiere(e).indexOf(nq) >= 0; }) || items.find(function (e) { return norm(e.innerText).indexOf(nq) >= 0; });
        if (!it) { put({ ok: false, erreur: "conversation « " + Q.conversation + " » introuvable dans la liste Teams visible" }); return; }
        var nom = (it.innerText || "").split("\n")[0].trim();
        it.click();
        var box = await wait(function () { var c = [].slice.call(document.querySelectorAll('[data-tid="ckeditor"][contenteditable="true"],div[role="textbox"][contenteditable="true"]')).filter(vis); return c.length ? c[c.length - 1] : null; }, 12000);
        if (!box) { put({ ok: false, erreur: "zone de saisie de la conversation introuvable" }); return; }
        if ((box.innerText || "").trim().length > 0) { put({ ok: false, erreur: "la zone de saisie de « " + nom + " » contient déjà un texte : je n'y touche pas" }); return; }
        await sleep(400);
        box.focus();
        var texte = String(Q.texte || "").replace(/\s*\n+\s*/g, " ").replace(/\s{2,}/g, " ").trim();
        document.execCommand("insertText", false, texte);
        await sleep(800);
        var pose = (box.innerText || "").trim().length > 0;
        put({ ok: pose, nom: nom, erreur: pose ? "" : "le texte n'a pas pris dans la zone de saisie" });
      } catch (e) { put({ ok: false, erreur: "script Teams : " + String(e && e.message || e).slice(0, 160) }); }
    })();
    return "demarre";
  }

  async function paneBrouillon(paneId, d) {
    if (paneId !== "ol" && paneId !== "tm") return { ok: false, erreur: "brouillon : volet non pris en charge (" + paneId + ")" };
    ensurePane(paneId);
    let p0 = await paneProbe(paneId);
    if (!p0 || (p0.len || 0) < 120) {
      const w = await waitForContent(paneId, 15000, true);
      if (w.held) return heldResult(paneId);
      if (w.login) return { ok: false, erreur: w.login.msg };
      if (!w.probe || (w.probe.len || 0) < 120) return { ok: false, erreur: "volet " + SVC_NAMES[paneId] + " pas encore chargé (15 s d'attente)" };
    } else {
      const li = loginInfo(paneId, p0.url, p0.ech);
      if (li) return { ok: false, erreur: li.msg };
    }
    if (held(paneId)) return heldResult(paneId);
    const K = "b" + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
    const Q = paneId === "ol"
      ? { a: String(d.a || "").slice(0, 600), cc: String(d.cc || "").slice(0, 600), objet: String(d.objet || "").slice(0, 300), html: String(d.html || "").slice(0, 60000) }
      : { conversation: String(d.conversation || "").slice(0, 120), texte: String(d.texte || "").slice(0, 8000) };
    const fn = paneId === "ol" ? paneOutlookBrouillon : paneTeamsBrouillon;
    actBegin(paneId, paneId === "ol" ? "prépare un brouillon Outlook" : "pose un brouillon Teams");
    try {
      const start = await paneEval(paneId, "(" + fn.toString() + ")(" + JSON.stringify(K) + "," + JSON.stringify(Q) + ")", 6000);
      if (start == null || String(start).indexOf("demarre") < 0) return { ok: false, erreur: "le volet " + SVC_NAMES[paneId] + " n'a pas exécuté le script" };
      const pollJS = "(function(){try{var x=(window.__novaCorps||{})[" + JSON.stringify(K) + "];if(!x)return 'null';if(x.fini){delete window.__novaCorps[" + JSON.stringify(K) + "];}return JSON.stringify(x)}catch(e){return 'null'}})()";
      const t0 = Date.now();
      while (Date.now() - t0 < 50000) {
        await sleep(700);
        const raw = await paneEval(paneId, pollJS, 4000);
        if (!raw || raw === "null") continue;
        let x = null; try { x = JSON.parse(raw); } catch (e) { x = null; }
        if (!x || !x.fini) continue;
        const r = x.r || { ok: false, erreur: "résultat vide" };
        if (!r.ok) return { ok: false, erreur: r.erreur || "échec" };
        if (paneId === "ol") {
          const qui = Q.a ? ", pour " + Q.a : "";
          const manque = (r.manque && r.manque.length) ? " Champs non trouvés, à compléter toi-même : " + r.manque.join(", ") + "." : "";
          const msg = r.sauve
            ? "Brouillon Outlook créé — objet « " + Q.objet + " »" + qui + ". Outlook l'a enregistré dans Brouillons (visible dans ton Outlook). Rien n'est envoyé." + manque
            : "Brouillon Outlook rédigé dans le volet Outlook de Nova — objet « " + Q.objet + " »" + qui + ", mais Outlook n'a pas encore affiché « brouillon enregistré » : vérifie Brouillons dans quelques secondes. Rien n'est envoyé." + manque;
          return { ok: true, message: msg };
        }
        return { ok: true, message: "Brouillon posé dans la conversation Teams « " + (r.nom || Q.conversation) + " » (zone de saisie du volet Teams de Nova, non envoyé). Teams ne synchronise pas les brouillons : relis et envoie depuis Messages › Teams dans Nova." };
      }
      return { ok: false, erreur: "délai dépassé dans le volet " + SVC_NAMES[paneId] };
    } finally { actEnd(paneId); }
  }

  async function handlePage(d) {
    const paneId = PANES[norm(d.pane || "navigateur")] || "nav";
    const sub = d.sub || "etat";
    if (!native()) return { ok: false, erreur: "coquille native absente : les volets web ne sont pas pilotables depuis l'aperçu" };
    if (sub === "corps") return await readBody(paneId, d);
    if (sub === "brouillon") return await paneBrouillon(paneId, d);
    if (sub === "aller") {
      if (paneId === "tor") { const g = await torGate(paneId); if (g) return g; }
      ensurePane(paneId, d.url);
      if (d.url) { native().postMessage({ cmd: "web.nav", id: paneId, action: "go", url: d.url }); }
      const w = await waitForContent(paneId, 16000);
      const p = w.probe;
      if (!p) return { ok: false, pane: paneId, erreur: "volet sans réponse après l'ordre de navigation (page pas encore créée ?)" };
      if (w.login) return { ok: false, pane: paneId, bloqueur: w.login.code, erreur: w.login.msg, url: p.url || "" };
      return { ok: true, pane: paneId, url: p.url || d.url || "", titre: p.titre || "", chargement: w.ready ? "complet" : "partiel — la page chargeait encore" };
    }
    if (sub === "etat") {
      ensurePane(paneId);
      let p = null;
      for (let i = 0; i < 4 && !p; i++) { p = await paneProbe(paneId); if (!p) await sleep(1200); }
      if (!p) return { ok: false, pane: paneId, erreur: "volet sans réponse (page pas encore chargée ou pas encore créée)" };
      const li = loginInfo(paneId, p.url, p.ech);
      return { ok: true, pane: paneId, url: p.url, titre: p.titre, pret: p.pret, texte_visible: p.len, session: li ? li.code : (p.len >= 120 ? "contenu présent" : "indéterminé"), bloqueur: li ? li.msg : "" };
    }
    if (sub === "lire" || sub === "messages") {
      const res = await readPane(paneId, { q: d.q, budgetMs: 26000 });
      // DIAG2 P2 : les éléments cliquables du volet, énumérés EXACTEMENT comme le clic les
      // résoudra (CLIC_CORE : mêmes sélecteurs, même ordre, index 1-based, libellé = 1re ligne).
      if (res && res.ok) {
        const raw = await paneEval(paneId, CLIC_ENUM_JS, 8000);
        if (raw) { try { const cl = JSON.parse(raw); if (Array.isArray(cl) && cl.length) res.cliquables = cl.slice(0, 40); } catch (e) {} }
      }
      return res;
    }
    if (sub === "clic" || sub === "saisir" || sub === "touche") {
      /* Volet froid (créé à l'instant) : laisser la SPA s'hydrater avant d'agir, sinon
         l'élément cherché n'existe pas encore et l'ordre échoue à tort. */
      ensurePane(paneId);
      const p0 = await paneProbe(paneId);
      if (p0 && p0.len < 120 && !loginInfo(paneId, p0.url, p0.ech)) await waitForContent(paneId, 7000, true);
      if (held(paneId)) return heldResult(paneId);   // V5-E : rien n'est cliqué ni saisi dans un volet qu'Ahadi a repris
      /* AUDIT-24/10: P0 — Entrée (touche ou « saisir … | entree ») dans un volet = envoi possible : refus sans « confirmed »
         (le moteur ne le pose qu'après la carte de confirmation d'Ahadi). Rien n'est tapé ni pressé avant. */
      const sendKeyAsked = sub === "touche" ? /enter|return|retour|entr[ée]e/i.test(String(d.q || "Enter")) : (sub === "saisir" && !!d.enter);
      if (sendKeyAsked && !d.confirmed) return { ok: false, confirmation: true, erreur: "touche Entrée dans un volet web (envoi possible) : confirmation d'Ahadi requise" };
      const js = sub === "clic"
        ? clicJS(d.q, !!d.confirmed, MSG_PANES.includes(paneId))
        : sub === "saisir"
        ? `(function(){var q=${JSON.stringify(String(d.q || ""))},v=${JSON.stringify(String(d.value || ""))};var ins=[...document.querySelectorAll('input,textarea,[contenteditable="true"]')].filter(function(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0});var t=ins.find(function(e){return ((e.placeholder||'')+' '+(e.getAttribute('aria-label')||'')+' '+(e.name||'')).toLowerCase().includes(q.toLowerCase())});if(!t)return JSON.stringify({ok:false,erreur:'champ introuvable : '+q});t.focus();if(t.isContentEditable){document.execCommand('insertText',false,v)}else{var s=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(t),'value');if(s&&s.set)s.set.call(t,v);else t.value=v;t.dispatchEvent(new Event('input',{bubbles:true}));t.dispatchEvent(new Event('change',{bubbles:true}))}${d.enter ? "t.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));" : ""}return JSON.stringify({ok:true,champ:(t.placeholder||t.getAttribute('aria-label')||t.name||'').slice(0,60)})})()`
        : `(function(){var k=${JSON.stringify(String(d.q || "Enter"))};document.activeElement&&document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true}));return JSON.stringify({ok:true,touche:k})})()`;
      const t = await paneEval(paneId, js, 15000);
      if (t == null) return { ok: false, erreur: "volet sans réponse" };
      try { return JSON.parse(t); } catch (e) { return { ok: false, erreur: "réponse illisible du volet" }; }
    }
    if (sub === "absence") {
      const val = String(d.value || "off").toLowerCase();
      const js = `(function(){var want=${JSON.stringify(val)};var sw=[...document.querySelectorAll('button[role="switch"],input[type="checkbox"]')].find(function(e){var l=((e.getAttribute('aria-label')||'')+' '+(e.textContent||'')).toLowerCase();return l.includes('automatic')||l.includes('absence')||l.includes('out of office')});if(!sw)return JSON.stringify({ok:false,erreur:'bascule des réponses automatiques introuvable sur cette page'});var on=sw.getAttribute('aria-checked')==='true'||sw.checked===true;var target=want.startsWith('on');if(on!==target)sw.click();var save=[...document.querySelectorAll('button')].find(function(b){return /save|enregistrer|ok/i.test(b.textContent||'')});if(save)setTimeout(function(){save.click()},400);return JSON.stringify({ok:true,etat_avant:on?'on':'off',demande:want})})()`;
      const t = await paneEval(paneId, js, 20000);
      if (t == null) return { ok: false, erreur: "volet sans réponse" };
      try { return JSON.parse(t); } catch (e) { return { ok: false, erreur: "réponse illisible du volet" }; }
    }
    return { ok: false, erreur: "sous-ordre page inconnu : " + sub };
  }

  /* ── 25/10 : LECTEUR PILOTÉ PAR L'AGENT (outil « media », Feat_Media.swift) ─────────────
     Le moteur envoie des candidats DÉJÀ résolus sur le catalogue réel ({name, country, urls, adult, sub}),
     flux TV morts écartés par sa sonde. La fenêtre essaie chaque flux dans l'ordre et ne répond ok QUE
     sur l'événement « playing » réel du média — sinon elle nomme chaque échec (essais). Lecture en
     ARRIÈRE-PLAN : radio/podcast dans le mini-lecteur (#audio), TV dans le lecteur flottant du shell ;
     aucune navigation, aucun premier plan. 18+ : refusé tant que le réglage n'est pas activé ET confirmé. */
  const mediaAdultOn = () => { try { return localStorage.getItem("nova2_media_adult") === "1" && localStorage.getItem("nova2_media_adult_ack") === "1"; } catch (e) { return false; } };
  const watchApi = () => { try { return typeof watch === "function" ? watch() : null; } catch (e) { return null; } };
  const agentTV = { el: null, hls: null, attached: false };
  let agentHlsP = null;
  function agentLoadHls() {
    if (window.Hls) return Promise.resolve(true);
    if (agentHlsP) return agentHlsP;
    agentHlsP = new Promise((res) => {
      const s = document.createElement("script");
      s.src = new URL("../vendor/hls.min.js", import.meta.url).href; s.async = true;
      s.onload = () => res(!!window.Hls); s.onerror = () => { agentHlsP = null; res(false); };
      document.head.append(s);
    });
    return agentHlsP;
  }
  function waitPlaying(el, ms, sig) {
    return new Promise((resolve) => {
      let done = false, t = 0;
      const onP = () => fin({ ok: true });
      const onE = () => { const e = el.error; fin({ ok: false, why: e ? "erreur média (code " + e.code + ")" : "erreur média" }); };
      function fin(r) {
        if (done) return; done = true; clearTimeout(t);
        el.removeEventListener("playing", onP); el.removeEventListener("error", onE);
        if (sig) sig.fail = null;
        resolve(r);
      }
      t = setTimeout(() => fin({ ok: false, why: "aucune lecture après " + Math.round(ms / 1000) + " s" }), ms);
      el.addEventListener("playing", onP); el.addEventListener("error", onE);
      if (sig) sig.fail = (why) => fin({ ok: false, why });
    });
  }
  function tvTeardown() {
    const t = agentTV;
    if (t.hls) { try { t.hls.destroy(); } catch (e) {} t.hls = null; }
    if (t.el) { const el = t.el; try { el.pause(); el.removeAttribute("src"); el.load(); } catch (e) {} }
    t.el = null; t.attached = false;
  }
  function tvStop() {
    const w = watchApi();
    if (agentTV.attached && w && w.close) { try { w.close(); } catch (e) {} }
    tvTeardown();
  }
  async function tvTry(el, url, ms) {
    if (agentTV.hls) { try { agentTV.hls.destroy(); } catch (e) {} agentTV.hls = null; }
    const sig = {};
    const w = waitPlaying(el, ms, sig);
    const m3u8 = /\.m3u8($|\?|%3F|&)/i.test(url) || /^\/api\/(tv\/)?stream\?u=.*m3u8/i.test(url);
    const hlsOk = m3u8 ? await agentLoadHls() : false;
    if (agentTV.el !== el) { if (sig.fail) sig.fail("lecteur fermé"); return w; }
    if (hlsOk && window.Hls && window.Hls.isSupported()) {
      const hls = new window.Hls({ maxBufferLength: 30, manifestLoadingMaxRetry: 1, fragLoadingMaxRetry: 2, levelLoadingMaxRetry: 2, manifestLoadingTimeOut: 12000, levelLoadingTimeOut: 12000, capLevelToPlayerSize: true });
      agentTV.hls = hls;
      hls.on(window.Hls.Events.MANIFEST_PARSED, () => { el.play().catch(() => {}); });
      hls.on(window.Hls.Events.ERROR, (ev, data) => {
        if (!data || !data.fatal || agentTV.hls !== hls) return;
        if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) { try { hls.recoverMediaError(); return; } catch (e) {} }
        const code = data.response && data.response.code != null ? " — HTTP " + data.response.code : "";
        if (sig.fail) sig.fail("hls.js : " + String(data.details || data.type || "erreur") + code);
      });
      hls.loadSource(url); hls.attachMedia(el);
    } else {
      el.src = url;
      el.play().catch((e) => { if (e && e.name === "AbortError") return; if (sig.fail) sig.fail("démarrage refusé : " + String((e && e.message) || e).slice(0, 80)); });
    }
    return w;
  }
  async function playTVCands(cands, deadline) {
    const w = watchApi();
    if (!w || !w.attach) return { ok: false, erreur: "lecteur flottant indisponible dans cette fenêtre" };
    const essais = [];
    bus.emit("nova:player-stop", {});   // un seul média à la fois
    tvStop();
    const el = document.createElement("video");
    el.playsInline = true; el.setAttribute("playsinline", ""); el.preload = "auto";
    agentTV.el = el;
    for (const c of cands) {
      if (c.adult && !mediaAdultOn()) { essais.push(c.name + " : contenu 18+ refusé (Réglages › Général › Contenus adultes désactivé)"); continue; }
      for (const raw of (c.urls || []).slice(0, 3)) {
        for (const direct of [false, true]) {
          const left = deadline - Date.now();
          if (left < 3000) { tvStop(); essais.push("budget de temps épuisé"); return { ok: false, erreur: "aucun flux TV n'a démarré dans le temps imparti", essais }; }
          const url = direct ? raw : "/api/stream?u=" + encodeURIComponent(raw);
          const meta = { title: String(c.name || "TV en direct"), sub: String(c.country || "") + " · lancé par Nova", module: "radio" };
          if (!agentTV.attached) { meta.onRelease = () => { if (agentTV.el === el) tvTeardown(); }; agentTV.attached = !!w.attach(el, meta); }
          else w.attach(el, { title: meta.title, sub: meta.sub });
          const r = await tvTry(el, url, Math.min(direct ? 12000 : 16000, left));
          if (agentTV.el !== el) return { ok: false, erreur: "lecture interrompue : lecteur fermé ou remplacé pendant l'essai", essais };
          if (r.ok) return { ok: true, titre: c.name, sous_titre: c.country || "", essais };
          essais.push(c.name + (direct ? " (direct)" : " (relais)") + " : " + r.why);
          if (!direct && !/HTTP 403/.test(r.why)) break;   // comme Médias : le direct n'est tenté que si le relais refuse (403)
        }
      }
    }
    tvStop();
    return { ok: false, erreur: "aucun flux TV n'a démarré parmi les candidats", essais };
  }
  async function playAudioCands(cands, kind, deadline) {
    const audio = document.getElementById("audio");
    if (!audio) return { ok: false, erreur: "mini-lecteur absent de la fenêtre" };
    const essais = [];
    tvStop();
    for (const c of cands) {
      for (const u of (c.urls || []).slice(0, 2)) {
        const left = deadline - Date.now();
        if (left < 3000) { essais.push("budget de temps épuisé"); return { ok: false, erreur: "aucun flux n'a démarré dans le temps imparti", essais }; }
        const sub = kind === "podcast" ? String(c.sub || "") : String(c.country || "");
        if (!audio.paused && audio.src === u) return { ok: true, titre: c.name, sous_titre: sub, essais };
        const wp = waitPlaying(audio, Math.min(12000, left));
        bus.emit("nova:play", { url: u, title: c.name, sub });
        const r = await wp;
        if (r.ok) return { ok: true, titre: c.name, sous_titre: sub, essais };
        essais.push(c.name + " : " + r.why);
      }
    }
    bus.emit("nova:player-stop", {});
    return { ok: false, erreur: "aucun flux lisible parmi les candidats", essais };
  }
  const liveMedia = () => { const a = document.getElementById("audio"); const l = [...document.querySelectorAll("#watchbox video, #watchbox audio")]; if (a) l.unshift(a); return l.filter((m) => m && (m.currentSrc || m.src)); };
  const textOf = (sel) => ((document.querySelector(sel) || {}).textContent || "").trim();

  async function handleMedia(d) {
    const audio = document.getElementById("audio");
    if (d.act === "play") {
      const cands = Array.isArray(d.cands) ? d.cands : [];
      if (!cands.length) return { ok: false, erreur: "aucun candidat reçu du moteur" };
      const budget = d.kind === "tv" ? 65000 : d.kind === "radio" ? 50000 : 40000;
      return d.kind === "tv" ? playTVCands(cands, Date.now() + budget) : playAudioCands(cands, d.kind, Date.now() + budget);
    }
    if (d.act === "radio") {   // ancien verbe « app media-radio » : même lecture vérifiée
      const q = String(d.q || "").trim(); if (!q) return { ok: false, erreur: "media-radio <nom de station>" };
      const j = await api.get("/api/radio/search?name=" + encodeURIComponent(q) + "&limit=5");
      const items = ((j && (j.items || j.stations)) || []).filter((s) => s && (s.url || s.stream));
      if (!items.length) return { ok: false, erreur: "aucune station trouvée pour « " + q + " »" };
      const r = await playAudioCands(items.slice(0, 3).map((s) => ({ name: s.name || q, country: s.country || "", urls: [s.url || s.stream] })), "radio", Date.now() + 40000);
      if (r.ok) r.station = r.titre;
      return r;
    }
    if (d.act === "stop") { bus.emit("nova:player-stop", {}); tvStop(); bus.emit("nova:watch-stop", {}); return { ok: true, arrete: true, effet: { lecture: liveMedia().some((m) => !m.paused) } }; }
    if (d.act === "pause") {
      const on = liveMedia().filter((m) => !m.paused);
      if (!on.length) return { ok: false, erreur: "rien ne joue" };
      for (const m of on) { try { m.pause(); } catch (e) {} }
      return { ok: true, pause: true, effet: { lecture: liveMedia().some((m) => !m.paused) } };
    }
    if (d.act === "reprendre") {
      const off = liveMedia().filter((m) => m.paused);
      if (!off.length) return liveMedia().length ? { ok: true, deja: "en lecture" } : { ok: false, erreur: "aucun média chargé à reprendre — utilise media tv|… ou radio|…" };
      const m = off[0];
      const wp = waitPlaying(m, 8000);
      m.play().catch(() => {});
      const r = await wp;
      return r.ok ? { ok: true, reprise: true, effet: { lecture: true } } : { ok: false, erreur: "reprise non constatée : " + r.why };
    }
    if (d.act === "volume") { if (!audio) return { ok: false, erreur: "lecteur absent" }; const v = parseFloat(String(d.q || "").replace("%", "")); const vol = Math.max(0, Math.min(1, isNaN(v) ? 0.8 : v > 1 ? v / 100 : v)); for (const m of liveMedia()) m.volume = vol; audio.volume = vol; return { ok: true, volume: vol }; }
    const vid = document.querySelector("#watchbox video");
    return { ok: true,
      audio: { lecture: !!(audio && !audio.paused && audio.src), titre: textOf("#miniplayer .tt"), detail: textOf("#miniplayer .ss") },
      video: { lecture: !!(vid && !vid.paused), titre: textOf("#watchbox .watch-tt"), detail: textOf("#watchbox .watch-ss") },
      ecran: currentId() || "" };
  }

  async function handle(d) {
    const id = d && d.id, op = d && d.op;
    if (!id || !op) return;
    try {
      if (op === "go") {
        const q = norm(d.q);
        const m = modules.find((x) => norm(x.id) === q || norm(x.label) === q || norm(x.label).includes(q) || q.includes(norm(x.id)));
        if (!m) { reply(id, { ok: false, erreur: "écran introuvable : " + (d.q || "") + " — voir « onglets »" }); return; }
        navigate(m.id);
        if (d.section) setTimeout(() => { const els = [...(view() || document).querySelectorAll("h1,h2,h3,.tt")]; const t = els.find((e) => norm(e.textContent).includes(norm(d.section))); if (t) t.scrollIntoView({ behavior: "smooth", block: "start" }); }, 500);
        reply(id, { ok: true, ecran: m.id, label: m.label });
      }
      else if (op === "onglets") reply(id, { ok: true, ecrans: modules.map((m) => ({ id: m.id, label: m.label, actif: m.id === currentId() })) });
      else if (op === "etat") {
        const v = view();
        reply(id, { ok: true, ecran: currentId() || "", titres: [...(v ? v.querySelectorAll("h1,h2") : [])].slice(0, 8).map((e) => e.textContent.trim().slice(0, 80)), champs: v ? v.querySelectorAll("input,textarea,select").length : 0, boutons: clickables().length });
      }
      else if (op === "lire") {
        const v = view(); let txt = v ? (v.innerText || "") : "";
        const q = String(d.q || "").trim();
        if (q) { const lines = txt.split("\n").filter((l) => norm(l).includes(norm(q))); txt = lines.join("\n") || "(aucune ligne ne contient « " + q + " »)"; }
        reply(id, { ok: true, texte: txt.slice(0, 3000), elements: clickables().slice(0, 40).map(({ n, label, kind }) => ({ n, label, kind })) });
      }
      else if (op === "clic") {
        const q = String(d.q || "").trim(); if (!q) { reply(id, { ok: false, erreur: "clic <libellé ou n°>" }); return; }
        let target = null;
        if (/^#?\d+$/.test(q)) { const c = clickables().find((c) => c.n === parseInt(q.replace("#", ""), 10)); target = c && c.el; if (c) var lbl = c.label; }
        if (!target) { const list = clickables(); target = (list.find((c) => norm(c.label) === norm(q)) || list.find((c) => norm(c.label).includes(norm(q))) || {}).el; var lbl2 = target ? target.textContent.trim().slice(0, 80) : ""; }
        const label = (typeof lbl !== "undefined" ? lbl : (typeof lbl2 !== "undefined" ? lbl2 : q));
        if (!target) { reply(id, { ok: false, erreur: "élément cliquable introuvable : " + q }); return; }
        if (DANGER.test(label) && !d.confirmed) { reply(id, { ok: false, confirmation: true, label, erreur: "action sensible : confirmation requise" }); return; }
        target.click();
        // PRO-4 : effet RELU après le clic (état de l'élément), pas seulement « j'ai cliqué ».
        const effet = { clique: label, present: document.contains(target) };
        if (target.getAttribute && target.getAttribute("aria-checked") != null) effet.etat = target.getAttribute("aria-checked");
        else if (target.checked != null) effet.etat = String(!!target.checked);
        reply(id, { ok: true, clique: label, effet });
      }
      else if (op === "saisir") {
        const q = norm(d.q); const v = view();
        const ins = [...(v ? v.querySelectorAll("input,textarea") : [])].filter(visible);
        const t = ins.find((e) => norm((e.placeholder || "") + " " + (e.getAttribute("aria-label") || "") + " " + (e.name || "")).includes(q));
        if (!t) { reply(id, { ok: false, erreur: "champ introuvable : " + (d.q || "") }); return; }
        t.focus();
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(t), "value");
        if (setter && setter.set) setter.set.call(t, String(d.value ?? "")); else t.value = String(d.value ?? "");
        t.dispatchEvent(new Event("input", { bubbles: true })); t.dispatchEvent(new Event("change", { bubbles: true }));
        if (d.enter) t.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
        // PRO-4 : effet RELU — la valeur présente dans le champ après coup, comparée à la demande.
        reply(id, { ok: true, champ: (t.placeholder || t.getAttribute("aria-label") || t.name || "").slice(0, 60),
                    effet: { valeur_relue: String(t.value ?? "").slice(0, 120), conforme: String(t.value ?? "") === String(d.value ?? "") } });
      }
      else if (op === "touche") {
        const k = String(d.q || "Enter");
        const [key, mods] = k.includes("+") ? [k.split("+").pop(), k] : [k, ""];
        const ev = new KeyboardEvent("keydown", { key: key === "cmd" ? "k" : key, metaKey: /cmd|meta/i.test(mods), ctrlKey: /ctrl/i.test(mods), bubbles: true, cancelable: true });
        (document.activeElement || document.body).dispatchEvent(ev);
        reply(id, { ok: true, touche: k });
      }
      else if (op === "defiler") {
        const v = view(); const q = norm(d.q || "bas");
        const dy = q.includes("haut") ? -600 : q.includes("bas") ? 600 : (parseInt(q, 10) || 600);
        if (v) v.scrollBy({ top: dy, behavior: "smooth" });
        reply(id, { ok: true, defile: dy });
      }
      else if (op === "page") {
        /* V5-E : même résolution de volet que handlePage. Volet tenu par Ahadi → refus
           immédiat (aucun web.show, aucune sonde). Sinon l'opération est inscrite dans ACT
           pendant toute sa durée réelle — c'est elle que le bandeau de Messages affiche. */
        const pid = PANES[norm(d.pane || "navigateur")] || "nav";
        if (held(pid)) { reply(id, heldResult(pid)); return; }
        actBegin(pid, PAGE_LABELS[d.sub || "etat"] || "agit dans le volet");
        let r;
        try { r = await handlePage(d); } finally { actEnd(pid); }
        reply(id, r);
      }
      else if (op === "media") reply(id, await handleMedia(d));
      else if (op === "formulaire") {   // 25/10 : lire / remplir / soumettre un formulaire dans un volet (formfill.js) — même pause V5-E et même bandeau d'activité que « page »
        const pid = PANES[norm(d.pane || "navigateur")] || "nav";
        if (held(pid)) { reply(id, heldResult(pid)); return; }
        actBegin(pid, d.act === "lire" ? "lit le formulaire" : d.act === "soumettre" ? "envoie le formulaire (GO d'Ahadi)" : "remplit le formulaire");
        let r;
        try { r = await handleForm(d, { native, paneId: pid, svc: SVC_NAMES[pid] || pid, paneEval, ensurePane, paneProbe, waitForContent, loginInfo, held, heldResult }); } finally { actEnd(pid); }
        reply(id, r);
      }
      else reply(id, { ok: false, erreur: "ordre ui inconnu : " + op });
    } catch (e) {
      reply(id, { ok: false, erreur: String((e && e.message) || e).slice(0, 200) });
    }
  }
  bus.on("ui", (d) => { handle(d || {}); });
  /* PRO-5 : pilote d'instantanés — toutes les 120 s, pour chaque boîte dont le volet EXISTE déjà
     (sonde d'abord : un volet jamais créé ne répond pas, on n'en crée aucun ici), une lecture courte
     qui alimente WebMail via readPane. Aucune création de volet, aucun affichage : les volets vivent
     hors écran (web.show en bg, x=-20000). Si la session du volet est expirée, paneProbe ne voit
     qu'un écran de login : readPane rend le bloqueur et ne poste rien — voir DÉCISIONS/INDEX. */
  const SNAP_BOXES = ["ol", "gm", "tm", "wa"];
  /* VEILLE-MAIL (24/10 soir) : test d'Ahadi — un mail arrivé pendant un relancement n'était vu
     qu'à la première ouverture de Messages, car AUCUN volet n'existait après le démarrage (la relève
     ne sonde que les volets déjà créés). Désormais, 15 s après le démarrage, les trois boîtes
     (Outlook, Gmail, Teams) sont ouvertes HORS ÉCRAN (x = -20000, arrière-plan : rien ne passe au
     premier plan), une toutes les 8 s. Réglage « watch_boxes » (vrai par défaut) pour l'éteindre.
     Cadence de relève : 60 s (au lieu de 120 s). Lecture seule, rien n'est envoyé. */
  (async () => {
    try {
      await sleep(15000);
      if (!native()) return;
      let on = true;
      try { const r = await api.get("/api/settings"); const st = (r && (r.settings || r)) || {}; if (st.watch_boxes === false) on = false; } catch (e) {}
      if (!on) return;
      for (const id of ["ol", "gm", "tm"]) {
        if (held(id)) continue;
        try { const p = await paneProbe(id); if (!p) ensurePane(id); } catch (e) {}
        await sleep(8000);
      }
    } catch (e) {}
  })();
  setInterval(async () => {
    if (!native()) return;
    for (const id of SNAP_BOXES) {
      if (held(id)) continue;   // V5-E : volet tenu par Ahadi — aucune sonde, aucune lecture
      if (readRecently(id, 30000)) continue;   // 29/10 : déjà lu il y a moins de 30 s (outil, veille Teams, bouton) — pas de double lecture
      try {
        const p = await paneProbe(id);
        if (!p || (p.len || 0) < 120) continue;
        actBegin(id, "relève la boîte");
        try { await readPane(id, { budgetMs: 8000 }); } finally { actEnd(id); }
      } catch (e) { /* un volet muet ne bloque pas les autres */ }
    }
  }, 60000);
  return NovaPanes;
}
