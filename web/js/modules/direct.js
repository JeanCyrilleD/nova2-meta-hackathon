/* ═══════════════════════════════════════════════════════════════════════════
   FIL DIRECT — Nova proactive (spec : nova-rebuild/NOVA_PROACTIVE_spec.md,
   ordre d'Ahadi du 20/10/2026 : « Nova doit être comme toi — elle m'affiche
   directement dans notre discussion mes mails qui arrivent, plus tes
   commentaires ; elle me met à jour sur les travaux ; elle m'écrit pour les
   routines et actions planifiées, sans que j'aie à demander. »)

   Monté en tête de l'écran Agent (la discussion), ce fil poste TOUT SEUL :
     📬 les mails Outlook non lus NOUVEAUX (route moteur /api/mailapi/unread),
        avec des repères de dossier calculés localement (RH, GHO, visa…) ;
     ✅ les exécutions de Dots en attente de décision (/api/dots/waiting),
        avec les mêmes gestes que l'écran Agents (Vu / Plus tard) ;
     ⏰ les engagements ouverts à échéance proche ou en retard
        (/api/commitments, forme moteur {quoi, qui, echeance, dir, status}) ;
     🛠️ le dernier brief assemblé (/api/briefs) tant qu'il est frais.
   Règles : le fil PROPOSE, n'envoie jamais rien (RÈGLE D'OR n°2) ; un élément
   marqué « Vu » ne réapparaît pas (état local) ; rafraîchissement à
   l'ouverture puis toutes les 90 s tant que l'écran vit (ctx.every).
   ═══════════════════════════════════════════════════════════════════════════ */

const SEEN_KEY = "nova2_direct_seen_v1";

const cleanResume = (s) => {
  let t = String(s || "").replace(/\*\*/g, "").replace(/__/g, "").replace(/`/g, "").replace(/^#+\s*/gm, "").replace(/\s+/g, " ").trim();
  t = t.replace(/^((?:STATUT|STATUS)\s*:\s*[A-ZÀ-Þ]+)\s*[-—·]?\s*\1\b/i, "$1");
  return t.slice(0, 140);
};
const truncWords = (s, n) => { const t = String(s || ""); if (t.length <= n) return t; const cut = t.slice(0, n); const sp = cut.lastIndexOf(" "); return (sp > n * 0.6 ? cut.slice(0, sp) : cut).trim() + "…"; };
const fmtEch = (v) => { const t = String(v || ""); const d = new Date(t + "T12:00:00"); return t && !isNaN(d) ? d.toLocaleDateString("fr-FR", { weekday: "short", day: "numeric", month: "short" }) : t; };

/* Repères de dossier — heuristique locale, aucun appel IA : un libellé court
   quand l'expéditeur ou l'objet touche un dossier suivi d'Ahadi. */
const TAG_RULES = [
  [/\brh\b|ressources humaines|human resources/i, "Dossier : RH"],
  [/recrutement|recruitment/i, "Recrutement"],
  [/gho|global outlook/i, "GHO 2027"],
  [/visa|e-visa|voyage|travel/i, "Voyage / visa"],
  [/paiement|payment|facture|invoice|virement/i, "Paiements"],
  [/brvm|bourse/i, "BRVM"],
  [/urgent|deadline|échéance|rappel|avant le|dès que possible/i, "À traiter vite"],
];
const tagsFor = (from, subject) => {
  const hay = String(from || "") + " " + String(subject || "");
  const out = [];
  for (const [re, label] of TAG_RULES) if (re.test(hay) && !out.includes(label)) out.push(label);
  return out.slice(0, 2);
};

export function mountDirect(ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  /* FD (23/10) : clés des lignes du fil proactif déjà montrées — amorcées
     silencieusement au premier refresh (même patron que seen.seeded pour
     les mails), puis seules les lignes NOUVELLES entrent animées. */
  let fdFeedSeen = null;

  const loadSeen = () => { try { return JSON.parse(localStorage.getItem(SEEN_KEY) || "{}"); } catch (e) { return {}; } };
  const saveSeen = (s) => { try { localStorage.setItem(SEEN_KEY, JSON.stringify(s)); } catch (e) {} };
  const mailKey = (m) => String(m.from || "") + "|" + String(m.subject || "") + "|" + String(m.date || "");

  const body = h("div", {});
  const stamp = h("span", { class: "ss", style: "color:var(--ink-3)" }, "");
  const el = h("div", { class: "card flat direct-card", style: "margin-bottom:14px" },
    h("div", { style: "display:flex;align-items:center;gap:8px;margin-bottom:2px" },
      h("span", { html: ic("zap", 16) }),
      h("div", { class: "tt", style: "font-weight:650" }, "Direct"),
      h("span", { class: "sp", style: "flex:1" }), stamp,
      h("button", { class: "btn", title: "Rafraîchir le fil", onclick: () => refresh() }, h("span", { html: ic("refresh", 14) }))),
    h("div", { class: "ss", style: "color:var(--ink-2);margin-bottom:8px" }, "Nova te parle d'elle-même — mails arrivés, travaux, échéances. Elle propose, elle n'envoie jamais sans ton accord."),
    body);
  body.append(h("div", { class: "empty" }, "Je veille…"));

  function sectionTitle(icon, label) {
    return h("div", { style: "display:flex;align-items:center;gap:6px;margin:10px 0 4px;color:var(--ink-2)" },
      h("span", { html: ic(icon, 14) }), h("span", { class: "ss", style: "font-weight:650;letter-spacing:.04em;text-transform:uppercase" }, label));
  }

  async function refresh() {
    if (dead) return;
    const seen = loadSeen();
    if (!Array.isArray(seen.mail)) seen.mail = [];
    if (typeof seen.seeded !== "boolean") seen.seeded = false;
    const parts = [];

    /* 🔴 Fil proactif (moteur, PRO-1/PRO-2) : mails, Teams, Dots, briefs — horodaté, complet, dépliable en 1 clic */
    try {
      const pf = await api.get("/api/proactive/feed?limit=12");
      const evs = (pf && pf.items) || [];
      if (evs.length) {
        parts.push(sectionTitle("pro", "En direct"));
        const fdKeys = new Set();
        for (const ev of evs) {
          const icn = ev.kind === "dot.done" ? "dot" : ev.kind === "brief" ? "brief" : ev.kind === "teams.new" ? "teams" : "mail";
          const full = h("div", { class: "ss", style: "display:none;white-space:pre-wrap" }, String(ev.text || ""));
          /* FD (23/10) : repères de dossier sur le fil proactif aussi (ils
             n'existaient que sur la section mails) — même heuristique
             locale tagsFor, foin = expéditeur + titre + texte. */
          const evTags = tagsFor(ev.who, String(ev.title || "") + " " + String(ev.text || ""));
          const fdKey = String(ev.id || (String(ev.kind || "") + "|" + String(ev.ts || "") + "|" + String(ev.title || "")));
          fdKeys.add(fdKey);
          const row = h("div", { class: "row-item" },
            h("span", { class: "dotst" + (ev.urgent ? " warn" : "") }),
            h("div", { class: "grow" },
              h("div", { class: "tt" }, h("span", { html: ic(icn, 13) }), " " + truncWords(String(ev.title || ""), 90)),
              h("div", { class: "ss" }, [String(ev.ts || "").slice(0, 16).replace("T", " "), ev.who ? "· " + ev.who : ""].filter(Boolean).join(" ")),
              evTags.length ? h("div", { style: "margin-top:3px" }, ...evTags.map((t) => h("span", { class: "direct-tag" }, t))) : null,
              full),
            h("button", { class: "btn", onclick: () => { full.style.display = full.style.display === "none" ? "" : "none"; } }, "Lire"));
          if (fdFeedSeen && !fdFeedSeen.has(fdKey)) row.classList.add("fd-in");
          parts.push(row);
        }
        fdFeedSeen = fdKeys;
      }
    } catch (e) { /* fil illisible : les autres sections restent affichées */ }

    /* 📬 Mails nouveaux (Outlook local, lus par le moteur) */
    try {
      const j = await api.get("/api/mailapi/unread");
      const boxes = (j && j.boxes) || [];
      const items = boxes.length && Array.isArray(boxes[0].items) ? boxes[0].items : [];
      if (!seen.seeded && items.length) {           // 1er passage : ne montrer que les 3 plus récents
        seen.mail = items.slice(3).map(mailKey); seen.seeded = true; saveSeen(seen);
      }
      const fresh = items.filter((m) => !seen.mail.includes(mailKey(m))).slice(0, 3);
      if (fresh.length) {
        parts.push(sectionTitle("mail", "Nouveaux mails"));
        for (const m of fresh) {
          const tags = tagsFor(m.from, m.subject);
          parts.push(h("div", { class: "row-item" },
            h("span", { class: "dotst warn" }),
            h("div", { class: "grow" },
              h("div", { class: "tt" }, truncWords(m.subject || "(sans objet)", 90)),
              h("div", { class: "ss" }, [String(m.from || ""), String(m.date || ""), truncWords(m.preview || "", 80)].filter(Boolean).join(" · ")),
              tags.length ? h("div", { style: "margin-top:3px" }, ...tags.map((t) => h("span", { class: "direct-tag" }, t))) : null),
            h("button", { class: "btn", onclick: () => { const s = loadSeen(); s.mail = Array.isArray(s.mail) ? s.mail : []; s.mail.push(mailKey(m)); saveSeen(s); refresh(); } }, "Vu")));
        }
      }
    } catch (e) { /* boîte illisible : section simplement absente */ }

    /* ✅ Exécutions en attente de décision */
    try {
      const w = await api.get("/api/dots/waiting");
      const waiting = (w && (w.items || w.waiting)) || [];
      if (waiting.length) {
        parts.push(sectionTitle("zap", waiting.length + " exécution(s) en attente de ta décision"));
        for (const r of waiting.slice(0, 3)) {
          const rid = r.run_id || r.id || "";
          parts.push(h("div", { class: "row-item" },
            h("span", { class: "dotst warn" }),
            h("div", { class: "grow" }, h("div", { class: "tt" }, String(r.dot_name || r.title || r.dot || "Éclat")),
              h("div", { class: "ss" }, cleanResume(r.summary || r.text || r.question || ""))),
            h("button", { class: "btn", onclick: async () => { try { await api.post("/api/dots/snooze", { run_id: rid, minutes: 15 }); ctx.toast("Reporté de 15 minutes."); refresh(); } catch (e) { ctx.toast("Report impossible.", true); } } }, "Plus tard"),
            h("button", { class: "btn acc", onclick: async () => { try { await api.post("/api/dots/ack", { run_id: rid }); ctx.toast("Vu et acquitté."); refresh(); } catch (e) { ctx.toast("Accusé impossible.", true); } } }, "Vu")));
        }
      }
    } catch (e) { /* file illisible */ }

    /* ⏰ Engagements : en retard ou dus d'ici demain */
    try {
      const j = await api.get("/api/commitments");
      const items = (j && j.items) || [];
      const today = new Date(); today.setHours(0, 0, 0, 0);
      const limit = today.getTime() + 36 * 3600 * 1000;
      const due = items.filter((c) => (c.status || "ouvert") === "ouvert" && c.echeance && !isNaN(new Date(c.echeance + "T12:00:00")) && new Date(c.echeance + "T12:00:00").getTime() <= limit)
        .sort((a, b) => String(a.echeance).localeCompare(String(b.echeance))).slice(0, 3);
      if (due.length) {
        parts.push(sectionTitle("alert", "Échéances proches"));
        for (const c of due) {
          const late = new Date(c.echeance + "T12:00:00").getTime() < today.getTime();
          parts.push(h("div", { class: "row-item" },
            h("span", { class: "dotst " + (late ? "bad" : "warn") }),
            h("div", { class: "grow" }, h("div", { class: "tt" }, String(c.quoi || "Engagement")),
              h("div", { class: "ss", style: late ? "color:var(--bad,#ff7a7a)" : "" }, [(c.dir === "eux" ? "Promesse reçue" : "Mon engagement") + (c.qui ? " · " + c.qui : ""), fmtEch(c.echeance) + (late ? " — EN RETARD" : "")].filter(Boolean).join(" · ")))));
        }
      }
    } catch (e) { /* engagements illisibles */ }

    /* 🛠️ Dernier brief frais (< 36 h), une fois par brief */
    try {
      const j = await api.get("/api/briefs");
      const items = (j && (j.items || j.briefs)) || [];
      const b = items[0];
      if (b) {
        const at = new Date(b.at || b.date || b.created || b.ts).getTime();
        const key = String(b.id || b.title || "") + "|" + String(b.at || b.date || "");
        if (!isNaN(at) && Date.now() - at < 36 * 3600 * 1000 && seen.brief !== key) {
          parts.push(sectionTitle("send", "Dernier brief"));
          parts.push(h("div", { class: "row-item" },
            h("span", { class: "dotst ok" }),
            h("div", { class: "grow" }, h("div", { class: "tt" }, String(b.title || b.kind || "Brief")),
              h("div", { class: "ss" }, "Assemblé " + new Date(at).toLocaleString("fr-FR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) + " — il t'attend dans Veille.")),
            h("button", { class: "btn", onclick: () => ctx.navigate("veille") }, "Ouvrir"),
            h("button", { class: "btn", onclick: () => { const s = loadSeen(); s.brief = key; saveSeen(s); refresh(); } }, "Vu")));
        }
      }
    } catch (e) { /* historique optionnel */ }

    if (dead) return;
    body.replaceChildren(...(parts.length ? parts : [h("div", { class: "empty" }, "Rien de nouveau — je veille. Les mails, travaux et échéances arriveront ici tout seuls.")]));
    stamp.textContent = "à " + new Date().toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  }

  const stopEvery = ctx.every ? ctx.every(90000, () => refresh()) : null;
  return { el, refresh, stop: () => { dead = true; if (stopEvery) stopEvery(); } };
}
