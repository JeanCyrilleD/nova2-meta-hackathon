/* Centre de contrôle « En attente de ton GO » (plan UI 27/10, v2 actions groupées) —
   une seule file : brouillons à valider (GET /api/drafts) et préparations à
   apprécier (GET /api/preparations), les plus anciennes d'abord.
   v2 : sélection multiple des brouillons, rejet groupé (POST /api/drafts/remove,
   qui ne fait QUE retirer un brouillon — jamais d'envoi), ancienneté ≥ 48 h
   signalée, sous-comptes. L'envoi reste strictement élément par élément,
   depuis Messages, avec le GO d'Ahadi. */
import { fmtTimeFR } from "../core.js";

const tsOf = (v) => { const d = Date.parse(v || ""); return isNaN(d) ? 0 : d; };
const ageOf = (ms) => {
  if (!ms) return "";
  const m = Math.round((Date.now() - ms) / 60000);
  if (m < 60) return "il y a " + m + " min";
  if (m < 1440) return "il y a " + Math.round(m / 60) + " h";
  return "il y a " + Math.round(m / 1440) + " j";
};

export async function mount(root, ctx) {
  const { api, h } = ctx;
  let dead = false;
  const selected = new Set();   // ids de brouillons cochés
  let armReject = false;        // double geste : 1er clic arme, 2e confirme

  const head = h("div", { class: "mod-head" },
    h("h1", {}, "En attente de ton GO"),
    h("span", { class: "sp" }),
    h("button", { type: "button", class: "btn sm", onclick: () => load() }, "Recharger"));
  const sub = h("p", { class: "ds-meta" }, "Tout ce que Nova a préparé et qui n'attend qu'une décision de toi — rien ne part depuis cet écran.");
  const countsEl = h("p", { class: "ds-meta attente-counts" });
  const barEl = h("div", { class: "attente-bar" });
  const listEl = h("div", { class: "attente-list" });
  root.append(h("div", { class: "mod-fill" }, head, sub, countsEl, barEl, listEl));

  let lastRows = [], lastErrs = [];
  function paintBar() {
    const n = selected.size;
    if (!n) { barEl.replaceChildren(); armReject = false; return; }
    const label = armReject
      ? "Confirmer le rejet de " + n + " brouillon" + (n > 1 ? "s" : "") + " ?"
      : "Rejeter les " + n + " sélectionné" + (n > 1 ? "s" : "");
    barEl.replaceChildren(
      h("span", {}, n + " brouillon" + (n > 1 ? "s" : "") + " sélectionné" + (n > 1 ? "s" : "")),
      h("button", { type: "button", class: "btn sm", onclick: () => rejectSelected() }, label),
      h("button", { type: "button", class: "btn sm ghost", onclick: () => { selected.clear(); armReject = false; paint(); } }, "Tout décocher"));
  }

  async function rejectSelected() {
    if (!armReject) { armReject = true; paintBar(); return; }
    armReject = false;
    const ids = [...selected];
    let ok = 0, ko = 0;
    for (const id of ids) {
      try { await api.post("/api/drafts/remove", { id }); ok++; }
      catch (e) { ko++; }
    }
    selected.clear();
    try { ctx.toast(ok + " brouillon" + (ok > 1 ? "s" : "") + " rejeté" + (ok > 1 ? "s" : "") + (ko ? " · " + ko + " en échec" : "") + " — rien n'a été envoyé.", ko > 0); } catch (e) {}
    load();
  }

  function paint() {
    const children = lastRows.map((r) => {
      const old = r.ts && (Date.now() - r.ts) >= 48 * 3600 * 1000;
      const kids = [];
      if (r.draftId) {
        kids.push(h("input", { type: "checkbox", class: "attente-sel", checked: selected.has(r.draftId),
          onchange: (ev) => { ev.target.checked ? selected.add(r.draftId) : selected.delete(r.draftId); armReject = false; paintBar(); } }));
      }
      kids.push(h("button", { type: "button", class: "attente-open" + (old ? " attente-old" : ""), onclick: r.go },
        h("span", { class: "attente-kind" }, r.kind),
        h("span", { class: "attente-main" }, h("b", {}, String(r.title).slice(0, 110)),
          r.detail ? h("span", { class: "ds-meta" }, " " + r.detail) : null),
        h("span", { class: "ds-meta attente-age" }, (r.ts ? fmtTimeFR(new Date(r.ts)) + " · " : "") + ageOf(r.ts))));
      return h("div", { class: "attente-row" }, kids);
    });
    if (lastErrs.length) children.unshift(h("div", { class: "errbox" }, "Sources en échec : " + lastErrs.join(" · ") + " — le reste est affiché."));
    if (!children.length && !lastErrs.length)
      children.push(h("div", { class: "pane-note" }, "Rien n'attend ton GO. Quand Nova préparera un brouillon ou une action, elle apparaîtra ici."));
    listEl.replaceChildren(...children);
    paintBar();
  }

  async function load() {
    if (dead) return;
    listEl.replaceChildren(h("div", { class: "ds-meta" }, "Lecture des files d'attente…"));
    let drafts = [], preps = [], errs = [];
    try { const d = await api.get("/api/drafts"); drafts = Array.isArray(d) ? d : (d.drafts || []); }
    catch (e) { errs.push("brouillons injoignables"); }
    try { const p = await api.get("/api/preparations"); preps = Array.isArray(p) ? p : (p.preparations || p.items || []); }
    catch (e) { errs.push("préparations injoignables"); }
    if (dead) return;
    const rows = [];
    for (const d of drafts) {
      const st = String(d.status || "").toLowerCase();
      if (!st.startsWith("à valider") && !st.startsWith("a valider")) continue;
      rows.push({ ts: tsOf(d.ts), kind: "Brouillon " + (d.channel === "teams" ? "Teams" : "mail"),
        title: d.subject || d.target || d.to || "Brouillon sans objet",
        detail: "à " + (d.to || d.target || "?"),
        draftId: d.id,
        go: () => { ctx.navigate("messages"); setTimeout(() => { try { ctx.bus.emit("nova:draft-focus", { id: d.id }); } catch (e) {} }, 250); } });
    }
    for (const p of preps) {
      const st = String(p.statut || p.status || "").toLowerCase();
      if (st && !/attente|propos|pret|prêt/.test(st)) continue;
      rows.push({ ts: tsOf(p.ts || p.created || p.quand), kind: "Préparation",
        title: p.titre || p.title || p.resume || "Préparation",
        detail: String(p.pourquoi || p.detail || "").slice(0, 140),
        go: () => ctx.navigate("conversations") });
    }
    rows.sort((a, b) => a.ts - b.ts);   // les plus anciennes d'abord
    for (const id of [...selected]) if (!rows.some((r) => r.draftId === id)) selected.delete(id);
    lastRows = rows;
    const nbD = rows.filter((r) => r.draftId).length, nbP = rows.length - nbD;
    countsEl.textContent = rows.length
      ? nbD + " brouillon" + (nbD > 1 ? "s" : "") + " · " + nbP + " préparation" + (nbP > 1 ? "s" : "") + " — envoi toujours élément par élément, depuis Messages."
      : "";
    lastErrs = errs;
    paint();
    try { ctx.setBadge && ctx.setBadge("attente", rows.length || ""); } catch (e) {}
  }

  const off = ctx.bus ? ctx.bus.on("nova:draft-new", () => load()) : null;
  load();
  const timer = setInterval(load, 60000);
  return () => { dead = true; clearInterval(timer); try { off && off(); } catch (e) {} };
}
