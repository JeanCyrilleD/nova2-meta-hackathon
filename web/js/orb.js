/* Nova 2 — l'orbe et les cartes. L'orbe a 4 états et seulement 4 (recherche §2.3) :
   repos (respiration 4 s) · ecoute (pulsation) · reflexion (contraction + anneau) · parole (ondulation).
   Le morphing est un ressort CSS (~350 ms) : on change data-state, jamais de coupure.
   Ce module porte aussi le client de conversation (POST /api/chat en SSE via core.js) et la
   carte d'approbation — le pattern agent 2026 : fric­tion visible AVANT l'action, pas après. */
import { api, bus, esc, h, md, sse, reportError, bindChatMessage, stampMsgTime, daySepEl, sameDay, prevStampedTs, msgTimeLabel } from "./core.js";
import { ic } from "./icons.js";
import { renderSent, describeForBrain } from "./attach.js";

export const ORB_STATES = ["repos", "ecoute", "reflexion", "parole"];
/* DS §6.15 : aux 4 états de présence s'ajoutent 2 états TRANSITOIRES DE CANAL —
   tool (un outil tourne) et error (le canal vient d'échouer) — documentés comme
   transitoires et lus par les trois présences (orbe CSS, panda, Singularity). */
export const ORB_TRANSIENT = ["tool", "error"];
export function createOrb(size = "lg") {
  const el = h("div", { class: "orb orb-" + size, "data-state": "repos", role: "img", "aria-label": "Nova" },
    h("div", { class: "orb-halo" }), h("div", { class: "orb-core" }), h("div", { class: "orb-ring" }), h("div", { class: "orb-ripple" }));
  el.setState = (s) => { if (ORB_STATES.includes(s) || ORB_TRANSIENT.includes(s)) el.dataset.state = s; };
  el.getState = () => el.dataset.state;
  return el;
}

/* Carte d'approbation : décrit l'action, le destinataire, et n'exécute RIEN tant qu'Ahadi
   n'a pas cliqué. Renvoie une promesse résolue par "approve" | "edit" | "refuse". */
export function approvalCard({ title, what, approveLabel = "Approuver", editLabel = "Modifier", refuseLabel = "Refuser", major = false }) {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  const el = h("div", { class: "appr" },
    h("div", { class: "appr-head" }, h("span", { html: ic("shield", 18) }), h("span", {}, title)),
    h("div", { class: "appr-what" }, String(what || "")),
    h("div", { class: "appr-actions" },
      h("button", { class: "btn ghost danger", onclick: () => { done("refuse"); } }, refuseLabel),
      editLabel ? h("button", { class: "btn", onclick: () => { done("edit"); } }, editLabel) : null,
      h("button", { class: "btn lg acc", onclick: () => { done("approve"); } }, approveLabel)));
  function done(v) { el.querySelectorAll("button").forEach((b) => { b.disabled = true; }); try { window.dispatchEvent(new CustomEvent("nova:approval-wait", { detail: { phase: "resolved", verdict: v, major: !!major } })); } catch (e) {} resolve(v); }
  /* PV (23/10) : la carte signale son attente et son verdict — le
     compagnon pose « attend un GO » tant qu'elle vit, et l'humeur suit
     le verdict (approve → joie, refuse → attention). Point unique :
     toutes les cartes d'approbation naissent ici. */
  try { window.dispatchEvent(new CustomEvent("nova:approval-wait", { detail: { phase: "shown" } })); } catch (e) {}
  el.promise = promise;
  return el;
}

/* Conversation : envoie un message, diffuse la réponse dans un élément .msg.nova,
   pilote l'orbe (reflexion → parole → repos) et signale les outils appelés (plan visible).
   NOVA2 (chantier conversation) — LE FIL EST RÉEL : le conversation_id émis par le moteur
   (évènement « meta ») est conservé et renvoyé à chaque tour. Avant, chaque message créait
   une conversation neuve côté moteur : l'historique de 40 messages, le résumé de fil et
   followPrompt tournaient à vide, et la continuité ne tenait qu'au rappel tronqué des
   3 dernières conversations. L'historique local continue d'être envoyé (le moteur
   l'ignore : sa source de vérité est son propre fil, désormais le bon). */
export function createChat({ log, orb, onTool, onDone, onQuote, extra, onDelta }) {
  let ac = null, history = [], cid = "", pendingQuote = "";
  /* ── FILE D'ATTENTE (exigence d'Ahadi : enchaîner les messages comme avec Muse) ──
     Avant : un envoi pendant une génération était REFUSÉ (return false) — le message
     était perdu ou devait être retapé. Désormais send() ACCEPTE toujours (hors vide) :
     si un tour tourne, le message entre en file, visible en puces numérotées juste
     après le fil (donc au-dessus du composeur), retirable d'un clic ; la pompe traite
     les messages DANS L'ORDRE, chacun créant SES bulles au moment de SON traitement —
     aucune réponse ne s'entrelace avec une autre. Un message qui contredit le précédent
     (« en fait, plutôt… ») part tel quel, dans l'ordre : aucune fusion silencieuse
     (côté moteur, followPrompt est fait pour ces reprises). « Tout arrêter » vide la
     file ET coupe le tour en cours. Le contexte du tour (extra : profondeur, mode
     vocal) est figé À L'ENVOI : un message en file part avec les réglages de son moment. */
  const queue = [];
  let pumping = false;
  const qbar = h("div", { class: "chat-queue", hidden: true, "aria-live": "polite" });
  if (log && typeof log.after === "function") log.after(qbar);
  /* PROCHAT (21/10) : ce fil reçoit aussi les événements — mails, Teams, résultats
     de Dots, alertes — sans aucun clic. Le service est celui du shell dans la
     fenêtre principale, celui du panneau dans la fenêtre flottante ; les deux
     exposent window.NovaProChat avant toute création de chat. */
  try { if (typeof window !== "undefined" && window.NovaProChat) window.NovaProChat.registerThread("chat", log, (t) => { try { send(t); } catch (e) {} }); } catch (e) {}
  function renderQueue() {
    if (!pumping && !queue.length) { qbar.setAttribute("hidden", ""); qbar.replaceChildren(); return; }
    qbar.removeAttribute("hidden");
    const kids = [];
    if (queue.length) kids.push(h("span", { class: "qhead" }, "En file :"));
    queue.forEach((it, i) => {
      const label = it.text ? (it.text.length > 42 ? it.text.slice(0, 42) + "…" : it.text) : (it.atts.length + " pièce(s) jointe(s)");
      kids.push(h("span", { class: "qchip" },
        h("b", {}, String(i + 1)),
        h("span", { class: "qt" }, label),
        h("button", { class: "qx", title: "Retirer de la file", "aria-label": "Retirer le message " + (i + 1) + " de la file", onclick: () => { queue.splice(i, 1); renderQueue(); } }, h("span", { html: ic("close", 12) }))));
    });
    kids.push(h("button", { class: "btn qstop", onclick: () => stopAll() }, "Tout arrêter"));
    qbar.replaceChildren(...kids);
  }
  /* attachments (optionnel) : descripteurs de pièces jointes DÉJÀ reçues par le moteur
     (attach.js → POST /api/chat/upload : {name, path, size, kind, url, label}). La bulle
     affiche les aperçus ; le texte transmis au cerveau inclut les chemins réels et ce
     qu'il peut en faire (read_file / transcribe) — ou l'interdiction honnête de
     prétendre avoir vu une image (aucun cerveau vision dans la chaîne). */
  async function runOne(item) {
    const text = item.text, atts = item.atts;
    const mine = h("div", { class: "msg me" });
    if (text) mine.append(text);
    if (atts.length) mine.append(renderSent(atts));
    const ack = h("div", { class: "msg-ack" }, h("span", { html: ic("check", 13) }), " reçu");
    log.append(mine, ack);
    const quotePrefix = item.quote ? "[RELANCE — l'utilisateur répond à CE message précis de toi :\n« " + String(item.quote).slice(0, 900) + " »\nRéponds à ce message-là, pas à la conversation en général.]\n" : "";
    const engineText = quotePrefix + text + (atts.length ? (text ? "\n\n" : "") + describeForBrain(atts) : "");
    const bubble = h("div", { class: "msg nova" });
    const body = h("div", {}); bubble.append(body); log.append(bubble);
    /* DIAG2-FLUX P4 : ligne de progression TRANSITOIRE dans le fil — l'étape en cours (outil, bascule,
       réessai) vit SOUS le texte de la bulle pendant le run et disparaît à la fin. Avant : createChat
       ignorait step/failover/retry, le fil restait figé pendant tout le travail des outils. */
    const stLine = h("div", { class: "ss nova-step-line", hidden: true });
    bubble.append(stLine);
    const stShow = (t) => { stLine.textContent = t; stLine.hidden = false; };
    const stHide = () => { stLine.hidden = true; };
    let acc = "", brain = "", runFailed = false;   // DIAG-CONV 21/10 : déclaré AVANT bindChatMessage — son paintRx() évalue le getter () => acc synchronement (TDZ sinon)
    /* LOT WEB v3 : createChat consomme le lieur §44 partagé dès la création
       de la bulle — Accueil et panneau flottant ont donc accusés, réactions,
       menu pendant le streaming, relances et voie clavier/appui long. */
    bindChatMessage(bubble, () => acc, {
      cid: () => cid || "local",
      quote: (quoted) => { if (typeof onQuote === "function") onQuote(quoted); pendingQuote = String(quoted || ""); },
      follow: (quoted, label, instruction) => { send(instruction || label, [], quoted); },
    });
    bubble.scrollIntoView({ block: "end", behavior: "smooth" });
    history.push({ role: "user", content: engineText });
    ac = new AbortController();
    if (orb) orb.setState("reflexion");
    const caret = h("span", { class: "caret", "aria-hidden": "true", style: "display:inline-block;width:7px;height:1em;background:currentColor;vertical-align:text-bottom" });   // curseur de saisie pendant le flux
    body.append(caret);
    /* 25/10 : le journal suit la réponse en direct (avant : réponse « coupée », il fallait défiler) — sauf si
       Ahadi remonte lui-même pour relire. */
    let stick = true;
    const onLogScroll = () => { try { stick = (log.scrollHeight - log.scrollTop - log.clientHeight) < 80; } catch (e) {} };
    try { log.addEventListener("scroll", onLogScroll, { passive: true }); } catch (e) {}
    const follow = () => { try { if (stick) log.scrollTop = log.scrollHeight; } catch (e) {} };
    const render = () => { body.innerHTML = md(acc); body.append(caret); follow(); };
    follow();
    /* 25/10 : anti-doublon de narration — après une étape d'outil, le cerveau reprend souvent par la
       même phrase (« Je lance… » deux fois, collées). Le texte d'après l'étape (seg) est retenu
       jusqu'à sa 1re phrase ; si elle répète la dernière phrase d'avant (mots communs ≥ 60 %), elle
       est retirée. Sinon tout s'affiche, séparé par un saut de paragraphe. */
    let base = "", seg = "", segOn = false, segCut = -1;
    const words = (x) => String(x).toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9 ]+/g, " ").split(/\s+/).filter((w) => w.length > 2);
    const simil = (a, b) => { const A = new Set(words(a)), B = new Set(words(b)); if (!A.size || !B.size) return 0; let n = 0; A.forEach((w) => { if (B.has(w)) n++; }); return n / Math.max(A.size, B.size); };
    const lastSent = (x) => { const parts = String(x).trim().split(/(?<=[.!?…])\s*/).filter((y) => y.trim()); return parts.length ? parts[parts.length - 1] : ""; };
    const compose = (final) => {
      if (!segOn) { acc = base; return; }
      let shown = "";
      if (segCut < 0) {
        const m = seg.match(/^[\s\S]*?[.!?…](\s|$)/);
        if (m || seg.length > 240 || final) { const first = m ? m[0] : seg; segCut = simil(first, lastSent(base)) >= 0.6 ? first.length : 0; }
      }
      if (segCut >= 0) shown = seg.slice(segCut).replace(/^\s+/, "");
      acc = base + (shown && base.trim() && !/\n\s*$/.test(base) ? "\n\n" : "") + shown;
    };
    const boundary = () => { if (!acc.trim()) return; compose(true); base = acc; seg = ""; segOn = true; segCut = -1; };
    try {
      await sse("/api/chat", { text: engineText, ...(cid ? { conversation_id: cid } : {}), history: history.slice(0, -1), ...item.extraSnap }, (ev, d) => {
        if (ack && !ack.dataset.seen) { ack.dataset.seen = "1"; ack.textContent = "Nova s'en occupe…"; }
        if (ev === "meta") {
          if (d && d.conversation_id) cid = String(d.conversation_id);
          if (d && d.user_ts) {   // HORODATAGE : ts stocké du message d'Ahadi, écrit par le moteur avant le flux
            if (!sameDay(prevStampedTs(log, mine), d.user_ts)) { const sep = daySepEl(d.user_ts); if (sep) mine.before(sep); }
            stampMsgTime(mine, d.user_ts);
          }
        }
        else if (ev === "brain") { brain = (d && d.label) || ""; if (orb) orb.setState("reflexion"); }
        else if (ev === "reset") { acc = ""; base = ""; seg = ""; segOn = false; segCut = -1; render(); }
        else if (ev === "delta") { const t = (d && d.t) || ""; if (segOn) seg += t; else base += t; compose(false); render(); if (orb && acc) orb.setState("parole"); if (onDelta) { try { onDelta(acc); } catch (e) {} } }
        /* DIAG2-FLUX P4 : progression réelle dans le fil — étape d'outil (début, fin, battement),
           bascule de cerveau, relance : tout ce que le moteur annonce devient visible ICI, pas
           seulement dans un panneau annexe. La ligne est transitoire : le « done » l'efface. */
        else if (ev === "step") {
          if (d && d.state === "run" && d.beat == null) boundary();
          const tool = (d && d.tool) || "étape";
          if (d && d.beat != null) stShow(tool + " — toujours en cours · " + d.beat + " s");
          else if (d && d.state === "run") stShow(tool + (d.arg ? " — " + String(d.arg).slice(0, 90) : "") + "…");
          else if (d && d.state === "err") stShow(tool + (d.arg ? " — " + String(d.arg).slice(0, 90) : ""));
          else if (d && d.state === "ok") stShow(tool + " — terminé");
        }
        else if (ev === "failover") { stShow("Bascule de cerveau : " + ((d && d.from) || "?") + " → " + ((d && d.to) || "?") + ((d && d.reason) ? " (" + String(d.reason).slice(0, 90) + ")" : "")); }
        else if (ev === "retry") { stShow("Nouvelle tentative : " + ((d && d.reason) || "")); }
        else if (ev === "tool") { boundary(); if (onTool) onTool(d); }
        else if (ev === "error") { runFailed = true; stHide(); body.innerHTML = md(acc + "\n\n" + ((d && d.message) || "Erreur du moteur.")); }
        else if (ev === "stamp") {
          if (d && d.assistant_ts) {   // HORODATAGE : ts stocké de la réponse (checkpoint final du moteur)
            if (!sameDay(prevStampedTs(log, bubble), d.assistant_ts)) { const sep = daySepEl(d.assistant_ts); if (sep) bubble.before(sep); }
            stampMsgTime(bubble, d.assistant_ts);
          }
          if (d && d.user_ts && !mine.dataset.ts) stampMsgTime(mine, d.user_ts);
        }
        else if (ev === "done") {
          compose(true);
          { const paras = acc.split(/\n{2,}/); let n = 0; const kept = paras.filter((p) => { const t = p.trim(); const ann = t.length < 140 && !t.includes("\n") && /^(Je |J['’])/.test(t); if (ann) { n++; return n === 1; } return true; }); if (kept.length) acc = kept.join("\n\n"); }   /* 25/10 : une seule annonce d'étape */
          render();
          brain = (d && d.label) || brain;
          stHide();
          /* DIAG2-FLUX P4 : fin SANS réponse — avant, l'accusé passait « ✅ » au-dessus d'une bulle
             restée vide (mort silencieuse du run, 21/10 17:04). Désormais l'échec se lit dans le fil. */
          if (!acc.trim()) {
            body.innerHTML = md("Le run s'est terminé **sans réponse exploitable** — rien n'a été exécuté. Relance la demande.");
            if (ack) { ack.innerHTML = ic("alert", 13) + " sans réponse"; }
          } else if (ack) { const _t = (() => { try { const _ts = mine.dataset && mine.dataset.ts; return _ts ? msgTimeLabel(_ts) : ""; } catch (e) { return ""; } })(); ack.innerHTML = ic("check", 13) + (_t ? " " + _t : ""); setTimeout(() => { try { ack.remove(); } catch (e) {} }, 1500); }
        }
      }, ac.signal);
      follow(); try { log.removeEventListener("scroll", onLogScroll); } catch (e) {}
      history.push({ role: "assistant", content: acc });
      if (onDone) onDone({ text: acc, brain, cid });
    } catch (e) {
      runFailed = true;
      if (e && e.name !== "AbortError") { reportError(e, "chat"); body.innerHTML = md(acc + "\n\nLe moteur n'a pas répondu."); }
    } finally {
      caret.remove();
      /* C5 (23/10) : une fin de run propre émet l'état « done » de la source
         partagée (pose du panda + salut éventuel, réglé par « Saluts du
         panda ») ; échec ou abandon → « repos » direct, jamais de pose de
         fin sur un run qui n'a pas abouti. Avant : « repos » systématique —
         le héros ne recevait jamais « done », pas plus que le rail. */
      ac = null; if (orb) orb.setState(runFailed ? "repos" : "done");
      bubble.scrollIntoView({ block: "end" });
    }
  }
  async function pump() {
    if (pumping) return;
    pumping = true; renderQueue();
    try { while (queue.length) { const it = queue.shift(); renderQueue(); await runOne(it); } }
    finally { pumping = false; renderQueue(); }
  }
  /* Accepte le message : il part tout de suite (file vide) ou attend son tour (puce
     visible). Renvoie false seulement pour un message vide sans pièce jointe. La
     promesse se résout dès l'acceptation — les appelants vident leur champ aussitôt,
     c'est ce qui permet d'enchaîner les envois pendant une génération. */
  async function send(text, attachments, quoteText) {
    text = String(text || "").trim();
    const atts = (attachments || []).filter((a) => a && a.path);
    if (!text && !atts.length) return false;
    const quote = String(quoteText != null ? quoteText : pendingQuote || "");
    pendingQuote = "";
    queue.push({ text, atts, quote, extraSnap: extra ? extra() : {} });
    renderQueue();
    pump();
    return true;
  }
  function stop() {
    if (ac) ac.abort();
    /* L'abandon du flux coupe la lecture côté client ; on prévient aussi le moteur, qui
       arrête la génération (sinon elle se poursuit en tâche de fond et se « checkpoint »). */
    if (cid) { try { api.post("/api/chat/stop", { conversation_id: cid }).catch(() => {}); } catch (e) {} }
  }
  /* « Tout arrêter » : la file est vidée (ces messages ne partiront jamais, aucune
     bulle ne sera créée pour eux) et le tour en cours est coupé. */
  function stopAll() { queue.length = 0; renderQueue(); stop(); }
  /* Nouveau fil explicite : file vidée, prochain envoi = conversation neuve (le rappel
     mémoire du moteur prend alors le relais, comme avant ce chantier). */
  function reset() { cid = ""; history = []; queue.length = 0; renderQueue(); }
  return { send, stop, stopAll, reset, busy: () => pumping, queued: () => queue.length, cid: () => cid };
}
