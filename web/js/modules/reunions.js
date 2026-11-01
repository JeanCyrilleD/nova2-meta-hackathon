/* Réunions (Lot H, 28/10) — notes/transcription → compte rendu → engagements.
   POST /api/reunions/cr génère un CR structuré (décisions, points ouverts,
   actions relevées avec citation vérifiée). Chaque action devient un
   engagement seulement sur clic, une par une. Aucun envoi depuis cet écran. */

export async function mount(root, ctx) {
  const { api, h } = ctx;
  let dead = false;
  let items = [];

  const head = h("div", { class: "mod-head" },
    h("h1", {}, "Comptes rendus"),
    h("span", { class: "sp" }),
    h("button", { type: "button", class: "btn sm", onclick: () => load() }, "Recharger"));
  const sub = h("p", { class: "ds-meta" }, "Colle tes notes ou la transcription : Nova en fait un compte rendu et relève les actions promises (citation vérifiée). Tu crées les engagements un par un.");

  const titreIn = h("input", { type: "text", class: "fld", placeholder: "Réunion (ex. Point CAFU — GHO 2027)", "aria-label": "Intitulé de la réunion" });
  const dateIn = h("input", { type: "date", class: "fld", "aria-label": "Date de la réunion" });
  const partIn = h("input", { type: "text", class: "fld", placeholder: "Participants (optionnel)", "aria-label": "Participants" });
  const texteIn = h("textarea", { class: "fld reu-texte", rows: "8", placeholder: "Notes ou transcription de la réunion…", "aria-label": "Notes ou transcription" });
  const genBtn = h("button", { type: "button", class: "btn sm", onclick: () => generer() }, "Générer le compte rendu");
  const form = h("div", { class: "reu-form" },
    h("div", { class: "ds-h3" }, "Nouveau compte rendu"), titreIn, dateIn, partIn, texteIn, genBtn);
  const listEl = h("div", { class: "reu-list" });
  root.append(h("div", { class: "mod-fill reu-body" }, head, sub, form, listEl));

  async function generer() {
    const titre = titreIn.value.trim();
    if (!titre) { ctx.toast("Intitulé manquant.", true); return; }
    if (texteIn.value.trim().length < 80) { ctx.toast("Notes trop courtes (80 caractères au moins).", true); return; }
    genBtn.disabled = true; genBtn.textContent = "Génération…";
    try {
      const r = await api.post("/api/reunions/cr",
        { titre, date: dateIn.value || "", participants: partIn.value.trim(), texte: texteIn.value }, 180000);
      if (r && r.ok) {
        titreIn.value = ""; dateIn.value = ""; partIn.value = ""; texteIn.value = "";
        ctx.toast("Compte rendu prêt — relis les actions avant de créer les engagements.");
        await load();
      } else { ctx.toast("CR impossible : " + ((r && r.error) || "erreur"), true); }
    } catch (e) { ctx.toast("CR impossible : " + String((e && e.message) || e), true); }
    genBtn.disabled = false; genBtn.textContent = "Générer le compte rendu";
  }

  function crBlocks(cr) {
    const out = [];
    let list = [];
    const flush = () => { if (list.length) { out.push(h("ul", { class: "reu-ul" }, ...list)); list = []; } };
    for (const line of String(cr || "").split("\n")) {
      const t = line.trim();
      if (t.startsWith("## ")) { flush(); out.push(h("div", { class: "ds-h3 reu-h" }, t.slice(3))); }
      else if (t.startsWith("# ")) { flush(); }
      else if (t.startsWith("- ")) { list.push(h("li", {}, t.slice(2))); }
      else if (t) { flush(); out.push(h("p", { class: "reu-p" }, t)); }
    }
    flush();
    return out;
  }

  async function appliquer(crId, index) {
    try {
      const r = await api.post("/api/reunions/appliquer", { id: crId, index });
      if (r && r.ok) { ctx.toast(r.deja ? "Déjà dans tes engagements (rapproché)." : "Engagement créé."); await load(); }
      else ctx.toast((r && r.error) || "Création impossible", true);
    } catch (e) { ctx.toast("Création impossible : " + String((e && e.message) || e), true); }
  }

  function paint() {
    if (dead) return;
    if (!items.length) {
      listEl.replaceChildren(h("div", { class: "pane-note" }, "Aucun compte rendu pour l'instant. Après ta prochaine réunion, colle la transcription ci-dessus."));
      return;
    }
    const cards = items.map((it) => {
      const engs = (Array.isArray(it.engagements) ? it.engagements : []).map((p, idx) => {
        const who = p.dir === "moi" ? "Toi" : String(p.qui || "");
        return h("div", { class: "reu-eng" + (p.applique ? " reu-eng-done" : "") },
          h("span", { class: "reu-eng-main" }, h("b", {}, who + " : "), String(p.quoi || ""),
            p.echeance ? h("span", { class: "ds-meta" }, " · avant le " + p.echeance) : null),
          p.applique
            ? h("span", { class: "ds-meta" }, "engagement créé ✓")
            : h("button", { type: "button", class: "btn sm", onclick: () => appliquer(it.id, idx) }, "Créer l'engagement"));
      });
      return h("section", { class: "reu-card" },
        h("div", { class: "reu-head" },
          h("span", { class: "ds-h3" }, String(it.titre || "Réunion")),
          h("span", { class: "ds-meta" }, [it.date || "", it.participants || "", it.brain ? "cerveau : " + it.brain : ""].filter(Boolean).join(" · ")),
          h("span", { class: "sp" }),
          h("button", { type: "button", class: "btn sm ghost",
            onclick: async () => { try { await api.post("/api/reunions/supprimer", { id: it.id }); await load(); } catch (e) {} } }, "Retirer")),
        ...crBlocks(it.cr),
        engs.length ? h("div", { class: "reu-engs" }, h("div", { class: "ds-h3 reu-h" }, "Actions proposées"), ...engs) : null);
    });
    listEl.replaceChildren(...cards);
  }

  async function load() {
    if (dead) return;
    try { const j = await api.get("/api/reunions"); items = (j && j.items) || []; }
    catch (e) { listEl.replaceChildren(h("div", { class: "errbox" }, "Comptes rendus injoignables — réessaie avec Recharger.")); return; }
    paint();
  }

  load();
  return () => { dead = true; };
}
