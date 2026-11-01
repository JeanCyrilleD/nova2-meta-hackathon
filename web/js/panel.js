/* Nova 2 — panneau flottant (chargé par NovaMac dans /panel.html).
   Même moteur, même bus, même orbe que la fenêtre principale : une seule conversation.
   Nova 1 y empilait une seconde interface complète ; ici c'est un compagnon : l'orbe,
   un champ, et le fil. Le glisser de la fenêtre est natif (cmd panelDrag* côté Swift). */
import { api, bootTheme, bus, h } from "./core.js";
import { createProChat } from "./prochat.js";
import { createOrb, createChat } from "./orb.js";
import { createAttachments } from "./attach.js";
import { createVoice, createVoiceLive, parseBiChannel, speakable } from "./voice.js";
import { ic } from "./icons.js";

bootTheme();

/* PROCHAT (21/10) : le panneau flottant est une fenêtre séparée — il a donc sa
   PROPRE instance du consommateur du fil sans clic (le shell de la fenêtre
   principale ne peut pas écrire dans ce document). Démarrée AVANT la création
   du chat (plus bas) pour que createChat trouve window.NovaProChat et
   enregistre ce fil. */
try {
  const proChatPanel = createProChat({ api, bus });
  window.NovaProChat = {
    registerThread: (id, log, ask) => proChatPanel.registerThread(id, log, ask),
    sync: () => proChatPanel.sync(),
  };
  proChatPanel.start();
} catch (e) {}
const orb = createOrb("sm");
const head = document.getElementById("p-head");
const log = document.getElementById("p-log");
const composer = document.getElementById("p-composer");
/* NOVA PARTOUT (24/10) : pont natif du panneau compact — fermer (Échap / ✕),
   « Continuer dans Nova » (même conversation dans la fenêtre principale), glisser. */
const native = () => { try { return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nova; } catch (e) { return null; } };
const post = (o) => { const n = native(); if (n) { try { n.postMessage(o); return true; } catch (e) {} } return false; };
document.body.classList.add("nw-panel");
const contBtn = h("button", { class: "btn sm ghost nw-cont", type: "button", title: "Continuer dans Nova : cette conversation dans la fenêtre principale", "aria-label": "Continuer dans Nova",
  onclick: () => { const cid = (chat && chat.cid && chat.cid()) || ""; post(cid ? { cmd: "panelContinue", cid } : { cmd: "openMain" }); } },
  h("span", { html: ic("arrow-up-right", 13) }), h("span", {}, "Continuer"));
const closeBtn = h("button", { class: "btn sm ghost nw-x", type: "button", title: "Fermer (Échap)", "aria-label": "Fermer le panneau", html: ic("close", 14),
  onclick: () => hidePanel() });
head.classList.add("nw-head");
head.append(orb, h("div", { class: "grow nw-title", style: "flex:1;min-width:0" },
  h("div", { style: "font-weight:650" }, "Demander à Nova"),
  h("div", { class: "nw-sub" }, "Échap ou ✕ pour fermer · ⌃⌥Espace")), contBtn, closeBtn);
/* Glisser : le calcul est natif (panelDragStart / panelDrag) ; seuls les fonds de l'en-tête déplacent. */
head.addEventListener("pointerdown", (e) => {
  if (e.button !== 0 || e.target.closest("button, a, input, textarea")) return;
  if (!post({ cmd: "panelDragStart" })) return;
  try { head.setPointerCapture(e.pointerId); } catch (err) {}
  const mv = () => post({ cmd: "panelDrag" });
  const up = () => { head.removeEventListener("pointermove", mv); head.removeEventListener("pointerup", up); head.removeEventListener("pointercancel", up); };
  head.addEventListener("pointermove", mv); head.addEventListener("pointerup", up); head.addEventListener("pointercancel", up);
});

const input = h("textarea", { class: "fld", rows: "1", placeholder: "Demande à Nova…", "aria-label": "Demande à Nova" });

/* DS §9.10 : dans le panneau flottant, une erreur SYSTÈME se rend en toast —
   jamais en bulle « Nova » (une panne ne doit pas prendre la voix de
   l'assistante). Conteneur unique, variante `.toast.bad`, fermeture manuelle
   et durée du système (4 600 ms). */
function panelToast(text, bad) {
  let box = document.getElementById("toasts");
  if (!box) { box = h("div", { id: "toasts", "aria-live": "polite" }); document.body.append(box); }
  const t = h("div", { class: "toast" + (bad ? " bad" : ""), role: bad ? "alert" : "status" },
    h("span", {}, String(text)),
    h("button", { class: "toast-x", "aria-label": "Fermer la notification", html: ic("close", 13), onclick: () => t.remove() }));
  box.append(t);
  setTimeout(() => { try { t.remove(); } catch (e) {} }, 4600);
}
/* Conversation vocale du panneau (chantier conversation) : le raccourci voix de la
   coquille Swift (Nova.toggleVoice) pilotait jusqu'ici un leurre — il ne faisait que
   changer l'état visuel de l'orbe, sans micro ni parole. Désormais : écoute réelle
   (micro → /api/stt), envoi en mode vocal (réponse bi-canal), lecture de la réponse. */
let voiceNext = false, lastVoice = false;
const voice = createVoice({ onAutoEnd: () => { try { window.Nova && window.Nova.toggleVoice && window.Nova.toggleVoice(true); } catch (e) {} } });   /* 25/10 : envoi au silence */
/* 25/10 : la voix suit le texte en direct (phrase après phrase), comme dans Conversations. */
const vq = { said: 0, chars: 0, items: [], busy: false, bic: false };
const vPump = async () => {
  if (vq.busy) return; vq.busy = true;
  try { while (vq.items.length) { const t = vq.items.shift(); try { await voice.speak(t); } catch (e) { break; } } }
  finally { vq.busy = false; }
};
const vFeed = (acc, final) => {
  if (!lastVoice || vq.chars > 1500) return;
  if (/<PARLE>/i.test(acc)) { vq.bic = true; return; }
  const rest = String(acc || "").slice(vq.said);
  let cut = -1;
  if (final) cut = rest.length;
  else { const re = /[.!?…](\s|$)/g; let m; while ((m = re.exec(rest))) cut = m.index + 1; if (cut < (vq.said ? 220 : 25)) cut = -1; }
  if (cut <= 0) return;
  const chunk = speakable(rest.slice(0, cut)).trim();
  vq.said += cut;
  if (chunk) { vq.chars += chunk.length; vq.items.push(chunk); vPump(); }
};
const chat = createChat({ log, orb,
  extra: () => { const v = voiceNext; voiceNext = false; lastVoice = v; vq.said = 0; vq.chars = 0; vq.items.length = 0; vq.bic = false; return v ? { voice: true } : {}; },
  onDelta: (acc) => vFeed(acc, false),
  onDone: ({ text }) => {
    if (!lastVoice) return;
    if (vq.said > 0 && !vq.bic) { vFeed(text, true); return; }
    const p = parseBiChannel(text || "");
    const say = (p.bic ? p.parle : speakable(text || "")).slice(0, 1200);
    if (say) voice.speak(say).catch(() => {});
  } });
/* Pièces jointes : même conversation, même mécanique que l'Accueil (attach.js). */
const att = createAttachments();
const sendBtn = h("button", { class: "btn acc", title: "Envoyer", "aria-label": "Envoyer", html: ic("send", 16),
  onclick: () => submitPanel() });
/* LOT WEB v3 : même contrat de composeur que les autres surfaces —
   conteneur .composer > .att-bar + .composer-row(.composer-tools, champ, envoi). */
/* 25/10 (Ahadi : « pas d'option Live » dans le panneau) : micro (dictée) + Nova Live, comme le composeur principal. */
const micBtn = h("button", { class: "btn icon nw-mic", type: "button", title: "Dicter : parle, le message part tout seul quand tu te tais (reclic pour couper)", "aria-label": "Dicter", html: ic("mic", 16),
  onclick: () => { try { window.Nova.toggleVoice(); } catch (e) {} } });
let live = null;
const liveBtn = h("button", { class: "btn icon nw-live", type: "button", title: "Nova Live — parler en continu (reclic pour arrêter)", "aria-label": "Nova Live", html: ic("radio", 16),
  onclick: async () => {
    try {
      if (!live) live = createVoiceLive({
        onState: (st) => { liveBtn.classList.toggle("on", st !== "off" && st !== "repos"); liveBtn.dataset.st = String(st || ""); try { orb.setState(st === "off" ? "repos" : st); } catch (e) {} },
        missionConv: () => (chat && chat.cid && chat.cid()) || "",
        onMission: (m) => { if (m && m.phase === "start") panelToast("Nova Live lance la tâche : « " + String(m.text || "").slice(0, 70) + " »"); if (m && m.phase === "done" && !m.ok) panelToast("Nova Live : " + (m.summary || "la tâche n'a pas abouti."), true); },
      });
      if (live.actif()) { await live.stop(); liveBtn.classList.remove("on"); }
      else { await live.start(); liveBtn.classList.add("on"); }
    } catch (e) { panelToast("Nova Live : " + String((e && e.message) || e), true); }
  } });
const composerRow = h("div", { class: "composer-row" },
  h("div", { class: "composer-tools" }, att.btn, micBtn), input, liveBtn, sendBtn);
/* Contexte venu d'ailleurs (Service macOS « Demander / Résumer avec Nova », nova://ask) :
   montré en clair au-dessus du champ, retirable, joint au message SEULEMENT à l'envoi (Entrée). */
let ctxText = "", ctxSource = "";
const ctxBox = h("div", { class: "nw-ctx", hidden: true });
function setContext(text, source) {
  ctxText = String(text || "").slice(0, 12000); ctxSource = String(source || "");
  ctxBox.replaceChildren();
  ctxBox.hidden = !ctxText;
  if (!ctxText) return;
  ctxBox.append(
    h("div", { class: "nw-ctx-h" },
      h("span", { class: "nw-ctx-k" }, "Texte sélectionné"),
      h("span", { class: "nw-ctx-n" }, ctxText.length + " caractères"),
      h("button", { class: "btn sm ghost nw-ctx-x", type: "button", title: "Retirer ce texte", "aria-label": "Retirer le texte sélectionné", html: ic("close", 12), onclick: () => { setContext("", ""); input.focus(); } })),
    h("div", { class: "nw-ctx-t" }, ctxText.length > 420 ? ctxText.slice(0, 420) + "…" : ctxText));
}
composer.append(att.bar, ctxBox, composerRow);
att.attachTo(log, input);
let attSending = false;
async function submitPanel() {
  let t = input.value;
  if (attSending || (!t.trim() && !att.count() && !ctxText)) return;
  if (ctxText) { t = (t.trim() || "Voici un texte : qu'en retiens-tu ?") + "\n\n---\nTexte sélectionné" + (ctxSource === "service" ? " (Service macOS)" : "") + " :\n" + ctxText; }
  const hadCtx = !!ctxText;
  if (!att.count()) { if (chat.send(t)) { input.value = ""; if (hadCtx) setContext("", ""); autosize(); } return; }
  /* File d'attente (createChat) : l'envoi pendant une génération est accepté et part
     dans l'ordre — le panneau se comporte comme l'Accueil. */
  attSending = true;
  try {
    await att.uploadPending();
    const desc = att.take();
    if (await chat.send(t, desc)) { input.value = ""; if (hadCtx) setContext("", ""); autosize(); }
  } catch (e) { /* la puce en échec affiche déjà la cause nommée */ }
  finally { attSending = false; }
}
input.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendBtn.click(); } });

input.addEventListener("keydown", () => { if (voice.isSpeaking()) voice.stopSpeaking(); });   // barge-in : taper coupe la parole

/* Champ qui grandit avec le texte (plafonné) ; focus immédiat à chaque ouverture. */
function autosize() { try { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; } catch (e) {} }
input.addEventListener("input", autosize);
function focusEnd() { try { input.focus(); const n = input.value.length; input.setSelectionRange(n, n); } catch (e) {} }
window.addEventListener("focus", () => { if (!document.activeElement || document.activeElement === document.body) focusEnd(); });

/* Échap ferme le panneau (une carte « Retenir » ouverte se ferme d'abord). Rien n'est annulé :
   une réponse en cours continue et sera là à la réouverture. */
let memCard = null;
function hidePanel() { if (!post({ cmd: "panelHide" })) { /* hors app (banc) : rien à fermer */ } }
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || e.isComposing) return;
  if (document.querySelector(".halo-panel:not([hidden])")) return;
  e.preventDefault();
  if (memCard) { memCard.remove(); memCard = null; focusEnd(); return; }
  hidePanel();
});

/* « Retenir dans Nova » (Service macOS) : carte de confirmation, texte modifiable ;
   rien n'entre en mémoire sans le clic « Retenir ». Même route que Savoir (/api/memory/add). */
function showRemember(text) {
  if (memCard) memCard.remove();
  const ta = h("textarea", { class: "fld fld-area nw-mem-t", rows: "4", "aria-label": "Texte à retenir" });
  ta.value = String(text || "").slice(0, 4000);
  const msg = h("div", { class: "nw-mem-m", role: "status" });
  const okBtn = h("button", { class: "btn acc sm", type: "button" }, "Retenir");
  const noBtn = h("button", { class: "btn sm ghost", type: "button" }, "Annuler");
  const card = h("div", { class: "nw-mem", role: "group", "aria-label": "Retenir dans Nova" },
    h("div", { class: "nw-mem-h" }, h("span", { html: ic("know", 14) }), h("span", {}, "Retenir dans ta mémoire ?")),
    h("div", { class: "nw-mem-s" }, "Relis et corrige si besoin : ce texte deviendra un fait que Nova utilisera."),
    ta, msg, h("div", { class: "nw-mem-a" }, noBtn, okBtn));
  noBtn.onclick = () => { card.remove(); memCard = null; focusEnd(); };
  okBtn.onclick = async () => {
    const v = ta.value.trim(); if (!v) { msg.textContent = "Rien à retenir."; return; }
    okBtn.disabled = true; noBtn.disabled = true; msg.textContent = "Enregistrement…";
    try {
      const r = await api.post("/api/memory/add", { text: v });
      if (r && r.item) { panelToast("Retenu dans ta mémoire (Savoir › Faits retenus)."); card.remove(); memCard = null; focusEnd(); }
      else { msg.textContent = "Déjà en mémoire (ou mémoire coupée) : rien d'ajouté."; noBtn.disabled = false; noBtn.textContent = "Fermer"; }
    } catch (e) { msg.textContent = "Enregistrement impossible : " + String((e && e.message) || e); okBtn.disabled = false; noBtn.disabled = false; }
  };
  memCard = card;
  log.append(card);
  card.scrollIntoView({ block: "end" });
  setTimeout(() => { try { ta.focus(); } catch (e) {} }, 30);
}

/* Pré-remplissage par la coquille (raccourci, nova://ask, Services) : n'envoie JAMAIS. */
function prefill(p) {
  const o = p || {};
  const mode = String(o.mode || "ask");
  if (mode === "retenir") { showRemember(o.context || o.text || ""); return; }
  if (o.context) setContext(o.context, o.source || "");
  if (mode === "resume") input.value = "Résume ce texte en quelques points clairs (BLUF d'abord).";
  else if (typeof o.text === "string" && o.text) input.value = o.text.slice(0, 4000);
  autosize();
  focusEnd();
}

/* API attendue par la coquille Swift (main.swift appelle Nova.focusAsk / Nova.toggleVoice).
   toggleVoice est désormais RÉEL : 1er appel = Nova écoute (micro, état « ecoute » mérité) ;
   2e appel = la dictée part en mode vocal et la réponse est lue. Si Nova parle, l'appel la
   coupe d'abord. Une erreur (micro refusé, transcription impossible) part en
   toast système (DS §9.10) — jamais en bulle Nova, et jamais un état « ecoute »
   affiché sans écoute derrière. */
let voiceBusy = false;
window.Nova = {
  focusAsk() { focusEnd(); },
  prefill,
  async toggleVoice(fromAuto) {
    if (voiceBusy) return;
    /* 26/10 (audit) : la fin de dictée automatique ne doit pas être avalée par une lecture en cours. */
    if (voice.isSpeaking()) { voice.stopSpeaking(); if (!(fromAuto && voice.isListening())) return; }
    voiceBusy = true;
    try {
      if (voice.isListening()) {
        const t = await voice.listenStop();
        orb.setState("repos");
        try { micBtn.classList.remove("on"); } catch (e) {}
        if (t && t.trim()) { voiceNext = true; if (!chat.send(t)) { voiceNext = false; input.value = t; } }
      } else {
        if (chat.busy()) return;
        await voice.listenStart();
        orb.setState("ecoute");
        try { micBtn.classList.add("on"); } catch (e) {}
      }
    } catch (e) {
      orb.setState("repos");
      panelToast("Voix : " + String((e && e.message) || e), true);
    } finally { voiceBusy = false; }
  },
};
input.focus();
