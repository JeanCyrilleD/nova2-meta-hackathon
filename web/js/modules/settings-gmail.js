/* 25/10 — GMAIL (LECTURE DIRECTE). Carte de Réglages › Données & comptes, à côté de Zoho Mail (même mécanique).
   Ahadi saisit lui-même son adresse Gmail et un MOT DE PASSE D'APPLICATION Google (16 caractères) ; le champ est
   vidé dès l'envoi, jamais réaffiché. Le moteur essaie la connexion IMAP (imap.gmail.com:993, lecture seule), puis
   range le mot de passe au Trousseau macOS (service « nova-gmail-imap ») ; la réponse ne renvoie que {ok, account}.
   Nova ne marque, ne déplace, ne supprime et n'envoie rien : EXAMINE + BODY.PEEK, liste blanche partagée avec Zoho. */
export function gmailControl({ h, api, ctx, bus, cleanups, isDead, errOf }) {
  const wrap = h("div", { class: "og-phone og-gmail" });
  let busy = false;
  const dead = () => { try { return !!isDead(); } catch (e) { return false; } };
  const when = (iso) => { try { const d = new Date(iso); return isNaN(d) ? "" : d.toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }); } catch (e) { return ""; } };
  const emailIn = h("input", { type: "email", class: "fld", value: "", placeholder: "adresse@gmail.com", autocomplete: "off", spellcheck: "false", "aria-label": "Adresse Gmail", style: "flex:1 1 220px;min-width:0" });
  const pwIn = h("input", { type: "password", value: "", autocomplete: "new-password", placeholder: "mot de passe d'application (16 caractères)", "aria-label": "Mot de passe d'application Google", style: "flex:1 1 270px;min-width:0" });
  const statusEl = h("span", { class: "og-status" }, "Lecture de l'état…");
  const dotEl = h("span", { class: "dotst off" });
  const connectBtn = h("button", { class: "btn sm acc" }, "Connecter");
  const syncBtn = h("button", { class: "btn sm" }, "Synchroniser");
  const offBtn = h("button", { class: "btn sm danger" }, "Déconnecter");
  const listEl = h("div", { class: "og-gmail-list", style: "display:flex;flex-direction:column;gap:2px" });
  async function loadList(st) {
    if (!st.connected || !st.count) { listEl.replaceChildren(); return; }
    try {
      const j = await api.get("/api/gmail/messages?limit=5");
      if (dead()) return;
      const ms = (j && Array.isArray(j.messages)) ? j.messages : [];
      listEl.replaceChildren(h("div", { class: "ss", style: "font-weight:600;margin-top:4px" }, "Derniers messages lus (lecture seule)"),
        ...ms.map((m) => h("div", { class: "ss", style: "white-space:nowrap;overflow:hidden;text-overflow:ellipsis" },
          (m.lu === false ? "● " : "") + when(m.date) + " · " + String(m.from_name || m.from || "—") + " — " + String(m.subject || "(sans objet)"))));
    } catch (e) { if (!dead()) listEl.replaceChildren(); }
  }
  function paint(st) {
    const connected = !!st.connected;
    if (st.account) emailIn.value = String(st.account);
    let txt;
    if (connected && st.error) txt = "Connecté — erreur à la dernière synchro : " + String(st.error);
    else if (connected) txt = "Connecté — " + String(st.account || "") + (st.last_ok ? " · dernière synchro " + when(st.last_ok) : " · première synchro en cours") + (st.count ? " · " + st.count + " messages lus" : "") + (st.unread != null ? " · " + st.unread + " non lus" : "");
    else if (st.error) txt = "Non connecté — " + String(st.error);
    else txt = "Non connecté — Gmail reste lu par Mail.app et le volet Gmail (plus lent, délais possibles).";
    statusEl.textContent = st.syncing ? txt + " · synchro en cours…" : txt;
    dotEl.className = "dotst " + (connected && !st.error ? "ok" : (st.error ? "err" : "off"));
    syncBtn.disabled = busy || !connected || !!st.syncing;
    offBtn.disabled = busy || !connected;
    connectBtn.disabled = busy;
    connectBtn.textContent = connected ? "Reconnecter" : "Connecter";
    loadList(st);
  }
  async function load() {
    let st;
    try { st = await api.get("/api/gmail/status"); }
    catch (e) { if (!dead()) { statusEl.textContent = "État de Gmail illisible — le moteur ne répond pas."; dotEl.className = "dotst err"; } return; }
    if (!dead()) paint(st || {});
  }
  connectBtn.addEventListener("click", async () => {
    const email = String(emailIn.value || "").trim();
    const password = String(pwIn.value || "");
    pwIn.value = "";   // jamais gardé dans la page, jamais réaffiché
    if (!email || !password) { ctx.toast("Saisis l'adresse Gmail et le mot de passe d'application.", true); return; }
    busy = true; connectBtn.disabled = true; statusEl.textContent = "Connexion à Gmail… (essai IMAP en lecture seule)";
    try {
      await api.post("/api/gmail/connect", { email, password }, 60000);
      if (!dead()) ctx.toast("Gmail connecté — première synchronisation en cours.");
    } catch (e) { if (!dead()) ctx.toast("Gmail : " + errOf(e), true); }
    busy = false;
    if (!dead()) load();
  });
  syncBtn.addEventListener("click", async () => {
    busy = true; syncBtn.disabled = true; statusEl.textContent = "Synchronisation… (lecture seule)";
    try {
      const j = await api.post("/api/gmail/sync", {}, 150000);
      if (!dead()) ctx.toast(j && j.ok ? "Gmail : " + (j.nouveaux || 0) + " nouveau(x) message(s), " + (j.non_lus != null ? j.non_lus : "?") + " non lus." : "Gmail : " + String((j && j.error) || "synchro non faite"), !(j && j.ok));
    } catch (e) { if (!dead()) ctx.toast("Gmail : " + errOf(e), true); }
    busy = false;
    if (!dead()) load();
  });
  offBtn.addEventListener("click", async () => {
    if (!offBtn.dataset.armed) { offBtn.dataset.armed = "1"; offBtn.textContent = "Confirmer ?"; setTimeout(() => { try { if (offBtn.isConnected) { delete offBtn.dataset.armed; offBtn.textContent = "Déconnecter"; } } catch (e2) {} }, 4000); return; }
    delete offBtn.dataset.armed; offBtn.textContent = "Déconnecter";
    busy = true;
    try { await api.post("/api/gmail/disconnect", {}); if (!dead()) ctx.toast("Gmail déconnecté — mot de passe effacé du Trousseau."); }
    catch (e) { if (!dead()) ctx.toast("Gmail : " + errOf(e), true); }
    busy = false;
    if (!dead()) load();
  });
  try { const off = bus && bus.on ? bus.on("gmail", () => { if (!busy && !dead()) load(); }) : null; if (typeof off === "function") cleanups.push(off); } catch (e) {}
  wrap.append(
    h("div", { class: "og-ctl" }, h("span", { class: "og-status" }, dotEl, " ", statusEl)),
    h("div", { style: "display:flex;gap:8px;flex-wrap:wrap;align-items:center" }, emailIn, pwIn),
    h("div", { style: "display:flex;gap:8px;flex-wrap:wrap" }, connectBtn, syncBtn, offBtn),
    h("div", { class: "ss", style: "font-weight:600" }, "Lecture seule — Nova ne marque, ne déplace, ne supprime et n'envoie rien."),
    h("div", { class: "ss" }, "Mot de passe d'application : myaccount.google.com › Sécurité › Validation en deux étapes (à activer) › Mots de passe des applications. Colle les 16 caractères ici — pas ton mot de passe Google."),
    listEl);
  load();
  return wrap;
}
