/* NOVA2 V3 COFFRE (24/10/2026) — la porte des compartiments verrouillés.
   Le moteur (Sources/NovaCore/Vault.swift) garde les données côté serveur ET chiffrées au repos
   (AES-256-GCM, clé au Trousseau) : sans jeton valide, /api/vault/* et /api/portfolio* répondent 423.
   Protocole :
     1. « Déverrouiller avec Touch ID » → POST /api/vault/unlock/system : le MOTEUR appelle LAContext
        (Touch ID ou mot de passe du Mac) dans le processus de l'app ; aucun secret ne passe par ici.
        Réponse : {token, ttl} — ou {need_code, ticket} si le code est exigé en second facteur.
     2. Code (repli, ou second facteur) → POST /api/vault/unlock {code[, ticket]} : le moteur dérive
        lui-même l'empreinte salée PBKDF2 et compare. L'interface n'envoie plus d'empreinte : l'ancien
        défaut « l'empreinte vaut mot de passe » est fermé. Délai croissant après échecs (moteur).
     3. Le jeton vit EN MÉMOIRE (jamais localStorage), voyage en en-tête « x-vault » via core.api.
        Il expire après 5 min SANS ACTIVITÉ : les gestes de l'utilisateur (clic, touche, molette)
        sont signalés au moteur au plus toutes les 45 s (POST /api/vault/touch) ; une veille vérifie
        l'état toutes les 30 s et rend la porte si le moteur a refermé.
     4. POST /api/vault/lock révoque le jeton — appelé à la fermeture de chaque écran protégé
        (verrouillage automatique au changement d'écran, inchangé) ; au démarrage l'app est verrouillée. */
import { setVaultToken } from "./core.js";

let token = "";        // jeton de session du coffre — mémoire seulement
let lastCtx = null;    // contexte du dernier écran protégé (pour rendre la porte à l'expiration)

async function jfetch(path, opts = {}) {
  const r = await fetch(path, opts);
  const j = await r.json().then((x) => (x && typeof x === "object" ? x : {}), () => ({}));   // V5-N : un corps « null » ne lève plus « Cannot read properties of null »
  return { status: r.status, ok: r.ok, j: j || {} };
}
const vh = () => (token ? { "x-vault": token } : {});
const post = (path, body) => jfetch(path, { method: "POST", headers: { "Content-Type": "application/json", ...vh() }, body: JSON.stringify(body || {}) });

/* ── Activité et expiration ── */
let lastTouch = 0, watchT = null, listening = false;
function onActivity() {
  if (!token) return;
  const now = Date.now();
  if (now - lastTouch < 45000) return;
  lastTouch = now;
  post("/api/vault/touch", {}).then((r) => { if (r.status === 423) expire(); }).catch(() => {});
}
function startWatch() {
  lastTouch = Date.now();
  if (!listening) { ["pointerdown", "keydown", "wheel"].forEach((ev) => document.addEventListener(ev, onActivity, { capture: true, passive: true })); listening = true; }
  if (!watchT) watchT = setInterval(async () => {
    if (!token) { stopWatch(); return; }
    try { const st = await vaultStatus(); if (token && st && st.unlocked === false) expire(); } catch (e) { /* moteur muet : on ne conclut rien */ }
  }, 30000);
}
function stopWatch() { if (watchT) { clearInterval(watchT); watchT = null; } }
function adopt(t) { token = String(t || ""); setVaultToken(token); if (token) startWatch(); else stopWatch(); }
function expire() {
  if (!token) return;
  adopt("");
  try { window.dispatchEvent(new CustomEvent("nova:vault-locked")); } catch (e) {}
  const c = lastCtx;
  if (c) { try { c.toast("Coffre refermé : 5 min sans activité."); } catch (e) {} try { c.refresh(); } catch (e) {} }
}

/* ── API ── */
export async function vaultStatus() {
  const { j } = await jfetch("/api/vault/status", { headers: vh() });
  return j || {};
}
function accept(r) {
  if (r.ok && r.j.token) { adopt(r.j.token); return { ok: true, ttl: r.j.ttl || 300, migration: r.j.migration || null }; }
  return null;
}
export async function vaultUnlockSystem() {
  const r = await post("/api/vault/unlock/system", {});
  const a = accept(r); if (a) return a;
  if (r.ok && r.j.need_code) return { ok: false, needCode: true, ticket: String(r.j.ticket || "") };
  return { ok: false, status: r.status, cancelled: !!r.j.cancelled, error: r.j.error || "Le moteur a refusé l'ouverture." };
}
export async function vaultUnlock(code, ticket) {
  const body = { code: String(code) };
  if (ticket) body.ticket = ticket;
  const r = await post("/api/vault/unlock", body);
  const a = accept(r); if (a) return a;
  return { ok: false, status: r.status, error: r.j.error || "Le moteur a refusé l'ouverture.", wait: r.j.wait };
}
/* Définir ou changer le code (coffre ouvert ; ou premier code sur un Mac sans authentification système). */
export async function vaultSetup(code) {
  const r = await post("/api/vault/setup", { code: String(code) });
  if (!r.ok) return { ok: false, error: r.j.error || "Configuration refusée par le moteur." };
  if (r.j.token) adopt(r.j.token);
  return { ok: true };
}
export async function vaultSetMode(secondFactor) {
  const r = await post("/api/vault/mode", { second_factor: !!secondFactor });
  return r.ok ? { ok: true } : { ok: false, error: r.j.error || "Réglage refusé par le moteur." };
}
export async function vaultRestoreClear() {
  const r = await post("/api/vault/restore-clear", { confirm: "RESTAURER" });
  return { ok: r.ok && r.j.ok === true, ...r.j };
}
export async function vaultEncrypt() {
  const r = await post("/api/vault/encrypt", { confirm: "CHIFFRER" });
  return { ok: r.ok && r.j.ok === true, ...r.j };
}
export async function vaultLock() {
  const t = token; adopt("");
  if (t) { try { await fetch("/api/vault/lock", { method: "POST", headers: { "x-vault": t } }); } catch (e) { /* révocation best-effort : le jeton expire seul après 5 min sans activité */ } }
}
export const vaultIsUnlocked = () => !!token;

let gateSeq = 0;   // identifiants de champs uniques quand plusieurs portes coexistent dans le DOM

/* La porte : un élément à placer en tête de l'écran protégé. Si le coffre est déjà ouvert
   (jeton vivant), elle se tait et appelle onUnlocked() aussitôt. Sinon : Touch ID en premier
   (si le moteur l'expose), le code en second ; message honnête si Touch ID est indisponible. */
export function vaultGate(ctx, title, onUnlocked) {
  const { h: hh, ic } = ctx;
  lastCtx = ctx;
  const box = hh("div", { class: "vault-gate" });
  const uid = "vg" + (++gateSeq) + "-";
  const cleanTitle = String(title).replace(/\s*—\s*coffre verrouillé\s*$/i, "");
  let done = false;
  const fire = () => { if (!done) { done = true; box.replaceChildren(); onUnlocked(); } };
  const opened = (r) => {
    const m = r && r.migration;
    const n = m && Array.isArray(m.migrated) ? m.migrated.length : 0;
    const pb = m && ((Array.isArray(m.errors) && m.errors.length) || (Array.isArray(m.conflicts) && m.conflicts.length));
    ctx.toast(n ? "Coffre ouvert — " + n + " fichier" + (n > 1 ? "s" : "") + " désormais chiffré" + (n > 1 ? "s" : "") + " au repos." : (pb ? "Coffre ouvert — migration incomplète, détail dans Coffre › Sécurité." : "Coffre ouvert pour cette session d'écran."), !!pb);
    fire();
  };

  async function render() {
    if (token) {
      const st = await vaultStatus().catch(() => ({}));
      if (st.unlocked) { fire(); return; }
      adopt("");   // jeton expiré côté moteur : on re-verrouille proprement
    }
    const st = await vaultStatus().catch(() => null);
    if (!st) {
      box.replaceChildren(hh("div", { class: "state-error" },
        hh("span", { html: ic("alert", 17) }),
        hh("span", { class: "grow" }, "État du coffre injoignable — le moteur ne répond pas."),
        hh("button", { class: "btn sm", onclick: () => render() }, "Réessayer")));
      return;
    }
    const sys = st.system || {};
    const sysOK = sys.available === true;
    const hasCode = !!(st.code || st.configured);
    const sf = st.second_factor === true;

    const errZone = hh("div", {});
    const showErr = (msg, field) => {
      errZone.replaceChildren(hh("div", { class: "field-err", role: "alert" }, String(msg || "")));
      if (field) { field.setAttribute("aria-invalid", "true"); try { field.focus(); } catch (e) {} }
    };
    const clearErr = (...fields) => { errZone.replaceChildren(); fields.forEach((f) => f && f.removeAttribute("aria-invalid")); };
    const head = (txt) => hh("h2", { class: "subhead", style: "display:flex;gap:var(--sp-2);align-items:center" }, hh("span", { html: ic("lock", 17) }), txt);
    const card = (...kids) => box.replaceChildren(hh("div", { class: "card flat vault-gate-card" }, ...kids, errZone));

    /* Champ de code (repli ou second facteur). */
    function codeField(ticket) {
      const pin = hh("input", { type: "password", inputmode: "numeric", autocomplete: "off", id: uid + "pin" + (ticket ? "2" : ""), class: "fld fld-lg", placeholder: "Code du coffre", style: "flex:1 1 auto;min-width:0" });
      const eye = hh("button", { class: "btn ghost sm", type: "button" }, "Afficher");
      eye.addEventListener("click", () => { const show = pin.type === "password"; pin.type = show ? "text" : "password"; eye.textContent = show ? "Masquer" : "Afficher"; });
      let busy = false;
      const btn = hh("button", { class: "btn lg" + (ticket ? " acc" : "") }, "Ouvrir");
      const go = async () => {
        if (busy || !pin.value) return;
        clearErr(pin);
        busy = true; btn.disabled = true; btn.textContent = "Vérification…"; pin.disabled = true;
        try {
          const r = await vaultUnlock(pin.value, ticket);
          if (r.ok) { opened(r); return; }
          const w = Number(r.wait) || 0;
          showErr((r.error || "Code refusé.") + (w > 0 && r.status !== 429 ? " Prochain essai possible dans " + w + " s." : ""), pin);
          if (r.status === 403 && ticket) { setTimeout(() => render(), 1200); }
        } catch (e) { showErr("Le moteur ne répond pas : " + String((e && e.message) || e), pin); }
        busy = false; btn.disabled = false; btn.textContent = "Ouvrir"; pin.disabled = false;
        pin.value = "";
      };
      btn.addEventListener("click", go);
      pin.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go(); } });
      setTimeout(() => { try { pin.focus(); } catch (e) {} }, 60);
      return hh("div", { class: "field" }, hh("label", { class: "field-lb", for: pin.id }, ticket ? "Second facteur — code du coffre" : "Code du coffre"),
        hh("div", { style: "display:flex;gap:var(--sp-2);align-items:center" }, pin, eye, btn));
    }

    /* Premier code, seulement si le Mac n'offre aucune authentification système. */
    function setupForm() {
      const c1 = hh("input", { type: "password", inputmode: "numeric", autocomplete: "off", id: uid + "new", class: "fld fld-lg", placeholder: "Choisis le code du coffre" });
      const c2 = hh("input", { type: "password", inputmode: "numeric", autocomplete: "off", id: uid + "confirm", class: "fld fld-lg", placeholder: "Confirme le code" });
      let busy = false;
      const btn = hh("button", { class: "btn lg acc" }, "Configurer et ouvrir");
      const go = async () => {
        if (busy) return;
        clearErr(c1, c2);
        if (String(c1.value).length < 4) { showErr("Code trop court (4 caractères minimum).", c1); return; }
        if (c1.value !== c2.value) { showErr("Les deux codes ne correspondent pas.", c2); return; }
        busy = true; btn.disabled = true; btn.textContent = "Configuration…"; c1.disabled = true; c2.disabled = true;
        try { const r = await vaultSetup(c1.value); if (r.ok && token) { ctx.toast("Coffre configuré et ouvert."); fire(); return; } showErr(r.error || "Configuration refusée."); }
        catch (e) { showErr(String((e && e.message) || e)); }
        busy = false; btn.disabled = false; btn.textContent = "Configurer et ouvrir"; c1.disabled = false; c2.disabled = false;
      };
      btn.addEventListener("click", go);
      c1.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); c2.focus(); } });
      c2.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go(); } });
      setTimeout(() => { try { c1.focus(); } catch (e) {} }, 60);
      return [
        hh("div", { class: "field" }, hh("label", { class: "field-lb", for: uid + "new" }, "Code du coffre"), c1),
        hh("div", { class: "field" }, hh("label", { class: "field-lb", for: uid + "confirm" }, "Confirmation du code"), c2),
        hh("div", { style: "display:flex;gap:var(--sp-2);flex-wrap:wrap" }, btn)];
    }

    /* Mac sans authentification système : le code est la seule clé (dit honnêtement). */
    if (!sysOK) {
      const why = hh("div", { class: "banner banner--warn" }, hh("span", { class: "dotst warn" }),
        hh("span", { class: "grow ss--wrap" }, String(sys.message || "Touch ID et mot de passe du Mac indisponibles pour Nova ici.") + " Le code est la seule clé du coffre."));
      if (!hasCode) {
        card(head(cleanTitle + " — le coffre n'est pas encore configuré"), why,
          hh("p", { class: "sec-desc" }, "Choisis un code. Le moteur n'en garde qu'une empreinte salée ; le code lui-même n'est jamais enregistré."),
          ...setupForm());
        return;
      }
      card(head(cleanTitle + " — coffre verrouillé"), why, codeField(""));
      return;
    }

    /* Cas normal : Touch ID (ou mot de passe du Mac) en premier, le code en second. */
    const label = String(sys.label || (sys.biometry === "touchid" ? "Déverrouiller avec Touch ID" : "Déverrouiller avec le mot de passe du Mac"));
    const sysBtn = hh("button", { class: "btn lg acc" }, hh("span", { html: ic("lock", 16) }), label);
    const codeZone = hh("div", {});
    let busy = false;
    const goSys = async () => {
      if (busy) return;
      clearErr();
      busy = true; sysBtn.disabled = true; sysBtn.lastChild.textContent = sys.biometry === "touchid" ? "Touch ID en attente…" : "En attente du Mac…";
      try {
        const r = await vaultUnlockSystem();
        if (r.ok) { opened(r); return; }
        if (r.needCode) {
          card(head(cleanTitle + " — second facteur"),
            hh("p", { class: "sec-desc" }, "Identité confirmée par le Mac. Entre maintenant ton code (valable 2 min)."),
            codeField(r.ticket));
          return;
        }
        if (!r.cancelled) showErr(r.error || "Ouverture refusée.");
      } catch (e) { showErr("Le moteur ne répond pas : " + String((e && e.message) || e)); }
      busy = false; sysBtn.disabled = false; sysBtn.lastChild.textContent = label;
    };
    sysBtn.addEventListener("click", goSys);

    const kids = [head(cleanTitle + " — coffre verrouillé"),
      hh("p", { class: "sec-desc" }, ((st && st.encryption && Number(st.encryption.encrypted_files) > 0 && !Number(st.encryption.clear_files))
        ? "Le coffre est chiffré sur le disque (AES-256-GCM)."
        : "Accès protégé par Touch ID ou ton code. Chiffrement du disque : pas encore activé (à lancer depuis Coffre › Sécurité).")
        + " Il se referme quand tu quittes l'écran ou après 5 min sans activité."),
      hh("div", { style: "display:flex;gap:var(--sp-2);flex-wrap:wrap;align-items:center" }, sysBtn)];
    if (sys.message) kids.push(hh("p", { class: "ss ss--wrap" }, String(sys.message)));
    if (hasCode && !sf) {
      const alt = hh("button", { class: "btn ghost sm", type: "button" }, "Utiliser le code du coffre");
      alt.addEventListener("click", () => { alt.remove(); codeZone.replaceChildren(codeField("")); });
      kids.push(hh("div", {}, alt), codeZone);
    } else if (hasCode && sf) {
      kids.push(hh("p", { class: "ss ss--wrap" }, "Second facteur actif : ton code te sera demandé après le Mac."));
    } else {
      kids.push(hh("p", { class: "ss ss--wrap" }, "Aucun code défini. Une fois le coffre ouvert, tu peux en ajouter un (repli ou second facteur) dans Coffre › Sécurité."));
    }
    if (Number(st.wait) > 0) kids.push(hh("p", { class: "ss ss--wrap" }, "Code temporairement bloqué : encore " + Number(st.wait) + " s."));
    card(...kids);
    setTimeout(() => { try { sysBtn.focus(); } catch (e) {} }, 60);
  }
  render();
  return box;
}
