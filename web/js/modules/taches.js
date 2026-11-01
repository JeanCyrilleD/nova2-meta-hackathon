/* taches.js — Phase 4 : écran « Approbations » (tâches des agents en direct).
   v2 (31/10, décision d'Ahadi 19:51 : « on garde notre UI actuelle ») : construit UNIQUEMENT avec les composants
   existants de Nova (ds.js : pageHead, section, card, row, pill, empty ; champ .fld ; boutons .ds-btn-*) — aucune
   classe ni couleur nouvelle.
   Données : tasks-feed.js (GET /api/agents2 de la Phase 3 ; simulé — et AFFICHÉ comme tel — tant que le réglage
   agents_v2 est faux ou la route absente). Par tâche : étapes, modèle, coût (réel ou estimé, toujours dit), plafond ;
   Approuver (lié à l'empreinte SHA-256 du contenu montré) / Modifier (simulé seulement) / Annuler.
   Aucun pourcentage ni barre de progression : on ne sait pas combien il reste, on ne l'invente pas. */
import * as ds from "../ds.js";
import { createTaskFeed, STATE_FR, TERMINAL, usd } from "../tasks-feed.js";

const CLASS_FR = { public: "public", personal: "personnel", sci_internal: "interne SCI", vault: "coffre" };
const TONE = { awaiting_approval: "warn", paused: "warn", done: "ok", failed: "danger", cancelled: "danger" };
const hm = (iso) => { if (!iso) return ""; const d = new Date(iso); return isNaN(d) ? "" : d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit", second: "2-digit" }); };

export async function mount(root, ctx) {
  const { h, api, bus } = ctx;
  root.classList.add("mod--data");
  const banner = h("div", { hidden: "" });
  const secs = {
    wait: ds.section({ title: "Attend ton accord", count: "—" }),
    run: ds.section({ title: "En cours", count: "—" }),
    end: ds.section({ title: "Terminées récemment", count: "—" }),
  };
  root.append(ds.pageHead({ title: "Approbations", sub: "Chaque tâche en direct : étape, modèle, coût. Rien ne part sans ton accord." }),
    banner, secs.wait, secs.run, secs.end,
    h("p", { class: "ds-meta" }, "Une tâche n'est « terminée » qu'avec un reçu d'outil."));
  const editing = new Map();   // id → texte en cours de modification

  function stepRow(s) {
    const cost = s.cost && s.cost.usd_micro != null ? (s.cost.actual ? usd(s.cost.usd_micro) : "≈ " + usd(s.cost.usd_micro) + " estimé") : null;
    const meta = [hm(s.at), s.model ? s.model + (s.profile ? " (profil " + s.profile + ")" : "") : null, s.receipt ? "reçu " + s.receipt : null, s.error].filter(Boolean).join(" · ");
    return ds.row({ title: s.label || s.kind, meta, side: cost });
  }
  function taskCard(t) {
    const st = t.state || "unknown";
    const steps = (t.steps || []).filter((s) => s.kind !== "created");
    const meta = [t.agent, t.profile ? "profil " + t.profile : null, t.data_class ? "données : " + (CLASS_FR[t.data_class] || t.data_class) : null].filter(Boolean).join(" · ");
    const money = ["Dépensé " + usd(t.spent_usd_micro || 0),
      t.estimated_usd_micro ? "estimé en cours ≈ " + usd(t.estimated_usd_micro) : null,
      t.reserved_usd_micro != null ? "réservé " + usd(t.reserved_usd_micro) : null,
      t.cap_usd_micro != null ? "plafond " + usd(t.cap_usd_micro, 2) : null].filter(Boolean).join(" · ");
    const kids = [
      h("p", { class: "ds-meta" }, meta),
      h("p", { class: "ds-meta" }, money + " · " + steps.length + (steps.length > 1 ? " étapes" : " étape") + (t.steps_max ? " (au plus " + t.steps_max + ")" : "")),
      h("div", { class: "ds-list", "aria-label": "Étapes de la tâche" }, steps.map(stepRow)),
    ];
    if (t.receipt) kids.push(h("p", { class: "ds-meta" }, "Reçu : " + (t.receipt.kind || "") + " " + (t.receipt.id || "")));
    if (st === "awaiting_approval" && t.approval) kids.push(approvalBlock(t));
    else if (!TERMINAL.has(st)) kids.push(h("div", { class: "ds-actions" }, ds.action({ label: "Annuler la tâche", ghost: true, onClick: () => run(t.id, "cancel") })));
    const c = ds.card({ title: t.title || t.id, actions: [ds.pill(STATE_FR[st] || st, TONE[st] || "neutral")] }, ...kids);
    c.setAttribute("aria-label", (t.title || t.id) + " — " + (STATE_FR[st] || st));
    return c;
  }
  function approvalBlock(t) {
    const a = t.approval, isEd = editing.has(t.id);
    const area = h("textarea", { class: "fld fld-area", rows: "7", "aria-label": isEd ? "Modifier le contenu avant approbation" : "Contenu exact à approuver" });
    area.value = isEd ? editing.get(t.id) : (a.content_preview || "");
    if (!isEd) area.readOnly = true;
    area.addEventListener("input", () => editing.set(t.id, area.value));
    const info = [a.destination ? "Destination : " + a.destination : null, (a.data_leaving || []).length ? "Données qui partent : " + a.data_leaving.join(", ") : null,
      a.estimated_usd_micro != null ? "Coût estimé de l'envoi : " + usd(a.estimated_usd_micro) : null, "Empreinte du contenu : " + (a.content_sha256 || "—")].filter(Boolean);
    const acts = isEd
      ? [ds.action({ label: "Renvoyer modifié", primary: true, onClick: () => run(t.id, "edit", area.value) }),
         ds.action({ label: "Abandonner la modification", ghost: true, onClick: () => { editing.delete(t.id); paint(); } })]
      : [ds.action({ label: "Approuver", primary: true, onClick: () => run(t.id, "approve") }),
         feed && feed.canEdit ? ds.action({ label: "Modifier", onClick: () => { editing.set(t.id, a.content_preview || ""); paint(); } }) : null,
         ds.action({ label: "Annuler", ghost: true, onClick: () => run(t.id, "cancel") })].filter(Boolean);
    return h("div", {}, ...info.map((x) => h("p", { class: "ds-meta" }, x)), area, h("div", { class: "ds-actions" }, acts),
      isEd ? h("p", { class: "ds-meta" }, "Modifier change l'empreinte : l'accord devra être redonné sur le nouveau texte.") : null);
  }
  async function run(id, verb, content) {
    const r = verb === "approve" ? await feed.approve(id) : verb === "edit" ? await feed.edit(id, content) : await feed.cancel(id);
    if (verb === "edit") editing.delete(id);
    if (!r.ok) { try { ctx.toast && ctx.toast("Action refusée : " + r.error); } catch (e) {} }
    paint();
  }
  function paint() {
    const all = Object.values(feed ? feed.tasks : {}).sort((a, b) => String(b.updated_at || "").localeCompare(String(a.updated_at || "")));
    const put = (sec, arr, empty) => { sec.body.replaceChildren(...(arr.length ? arr.map(taskCard) : [ds.empty({ text: empty, compact: true })])); sec.setCount(arr.length); };
    const wait = all.filter((t) => t.state === "awaiting_approval");
    put(secs.wait, wait, "Rien n'attend ton accord.");
    put(secs.run, all.filter((t) => !TERMINAL.has(t.state) && t.state !== "awaiting_approval"), "Aucune tâche en cours.");
    put(secs.end, all.filter((t) => TERMINAL.has(t.state)).slice(0, 8), "Aucune tâche terminée récemment.");
    try { bus.emit("nova:tasks-waiting", { n: wait.length, simulated: feed && feed.simulated }); } catch (e) {}
  }
  let feed = null;
  feed = createTaskFeed({ api, bus }, (tasks, meta) => {
    banner.hidden = !meta.simulated;
    banner.replaceChildren(...(meta.simulated ? [ds.card({ muted: true }, h("p", { class: "ds-meta" },
      "Données simulées : la source réelle GET /api/agents2 (Phase 3) n'est pas active (" + meta.reason + "). Les boutons n'envoient rien."))] : []));
    paint();
  });
  paint();
  return { destroy() { feed.stop(); }, onHide() {}, onShow() { paint(); } };
}
