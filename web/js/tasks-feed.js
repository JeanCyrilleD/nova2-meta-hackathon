/* tasks-feed.js — Phase 4 : CONSOMMATEUR des états de tâche de la Phase 3.
   Source réelle (contrat RÉEL de la branche phase-3, Sources/NovaCore/AgentsV2.swift, vérifié le 31/10) :
     GET  /api/agents2          → { ok, enabled, agents:[spec], tasks:[summary] } ; enabled=false tant que le réglage agents_v2 est faux
     POST /api/agents2/approve  { id, sha256 } + en-tête x-nova-provenance (window.__novaProv) ; 409 « modifie_depuis_apercu »
     POST /api/agents2/cancel   { id }
     (403 « agents_v2_off » sur les POST quand le réglage est faux). Pas de flux SSE ni de route d'édition côté Phase 3 :
     l'écran relit GET /api/agents2 toutes les 4 s tant qu'il est ouvert ; « Modifier » n'est proposé qu'en simulé.
   Tant que la source réelle est absente (403/404/erreur) ou désactivée (enabled=false), un SIMULATEUR rejoue le format
   d'évènements v1 (docs/PHASE4_CONTRATS.md §1), et l'écran l'annonce en clair. Aucun pourcentage : une tâche montre ses
   étapes réelles, son modèle, son coût (micro-dollars entiers, estimé ou réel, toujours dit), jamais une progression inventée.
   Couper : supprimer l'entrée « taches » de MODULES (shell.js) ; ce fichier n'est importé que par modules/taches.js. */

export const STATES = ["draft", "awaiting_approval", "running", "verifying", "done", "failed", "cancelled", "paused", "unknown"];
export const STATE_FR = { draft: "Brouillon", awaiting_approval: "Attend ton accord", running: "En cours", verifying: "Vérification", done: "Terminée", failed: "Échec", cancelled: "Annulée", paused: "En pause", unknown: "État inconnu" };
export const TERMINAL = new Set(["done", "failed", "cancelled"]);

/** Micro-dollars entiers → texte « 0,0123 $ ». null/undefined → « — ». */
export function usd(micro, digits = 4) {
  if (micro == null || !Number.isFinite(Number(micro))) return "—";
  const v = Number(micro) / 1e6;
  return new Intl.NumberFormat("fr-FR", { minimumFractionDigits: Math.min(2, digits), maximumFractionDigits: digits }).format(v) + " $";
}

/** Réducteur PUR : applique un évènement (format v1) à la table des tâches ; renvoie une nouvelle table.
    Évènement ignoré si v ≠ 1, si task_id manque, ou si seq ≤ dernier seq connu de la tâche (rejeu idempotent). */
export function applyEvent(tasks, ev) {
  if (!ev || ev.v !== 1 || !ev.task_id) return tasks;
  const prev = tasks[ev.task_id];
  if (prev && Number(ev.seq) <= Number(prev.last_seq || 0)) return tasks;
  const t = prev ? { ...prev, steps: prev.steps.slice() } : { id: ev.task_id, agent: ev.agent || "", title: ev.title || "", state: "unknown", steps: [], spent_usd_micro: 0, last_seq: 0 };
  t.last_seq = Number(ev.seq) || 0;
  if (ev.kind === "created") Object.assign(t, pick(ev, ["agent", "title", "profile", "data_class", "cap_usd_micro", "deadline", "steps_max"]));
  if (ev.state && STATES.includes(ev.state)) t.state = ev.state;
  else if (ev.state) t.state = "unknown";
  if (ev.kind === "approval_requested" && ev.approval) t.approval = { ...ev.approval };
  else if (ev.kind === "approval_cleared" || ev.kind === "approval_granted" || (ev.state && ev.state !== "awaiting_approval")) t.approval = null;   // tout changement annule l'approbation affichée
  if (ev.kind === "receipt" && ev.receipt) t.receipt = { ...ev.receipt };
  if (ev.cost && Number.isFinite(Number(ev.cost.usd_micro))) {
    if (ev.cost.actual) t.spent_usd_micro = (t.spent_usd_micro || 0) + Number(ev.cost.usd_micro);
    else t.estimated_usd_micro = (t.estimated_usd_micro || 0) + Number(ev.cost.usd_micro);
  }
  if (ev.reserved_usd_micro != null) t.reserved_usd_micro = Number(ev.reserved_usd_micro);
  t.steps.push({ seq: t.last_seq, at: ev.at, kind: ev.kind, label: ev.label || STATE_FR[ev.state] || ev.kind, state: ev.state || null, model: ev.model || null, profile: ev.profile || null, cost: ev.cost || null, error: ev.error || null });
  if (t.steps.length > 60) t.steps = t.steps.slice(-60);
  t.updated_at = ev.at;
  return { ...tasks, [t.id]: t };
}
const pick = (o, ks) => { const r = {}; for (const k of ks) if (o[k] != null) r[k] = o[k]; return r; };

/** Évènements de démonstration — EXACTEMENT le format v1 ; horodatages relatifs à `t0` (ms). */
export function simulatedScript(t0 = Date.now()) {
  const at = (s) => new Date(t0 + s * 1000).toISOString();
  const E = (task, seq, s, o) => ({ v: 1, task_id: task, seq, at: at(s), ...o });
  const mail = "Bonjour Mariam,\n\nMerci pour le tableau. Je confirme la session de cadrage jeudi 10 h (UTC). Je t'envoie l'ordre du jour d'ici mercredi.\n\nBien à toi,\nAhadi";
  return [
    E("sim-mail-1", 1, 0, { kind: "created", state: "draft", agent: "Mail", title: "Réponse à Mariam — session de cadrage", profile: "main", data_class: "personal", cap_usd_micro: 750000, steps_max: 6, label: "Tâche créée" }),
    E("sim-mail-1", 2, 1, { kind: "step", state: "running", label: "Lecture du fil (3 messages)", model: "muse-spark-1.3", profile: "triage", cost: { usd_micro: 412, actual: true } }),
    E("sim-mail-1", 3, 3, { kind: "step", state: "running", label: "Rédaction du brouillon", model: "muse-spark-1.3", profile: "main", reserved_usd_micro: 30000, cost: { usd_micro: 8120, actual: true } }),
    E("sim-mail-1", 4, 5, { kind: "approval_requested", state: "awaiting_approval", label: "Brouillon prêt : ton accord est requis avant l'envoi",
      approval: { content_preview: mail, content_sha256: "sim-0f3a…(simulé)", destination: "mariam@exemple.org (Gmail)", data_leaving: ["texte du brouillon", "adresse du destinataire"], estimated_usd_micro: 0 } }),
    E("sim-cafu-2", 1, 0, { kind: "created", state: "draft", agent: "CAFU Analyst", title: "Quarterly Horizon Brief — Sahel central (brouillon)", profile: "deep", data_class: "public", cap_usd_micro: 750000, steps_max: 8, label: "Tâche créée" }),
    E("sim-cafu-2", 2, 2, { kind: "step", state: "running", label: "Recherche de sources publiques (OCHA, ACLED)", model: "muse-spark-1.3", profile: "bulk_public", cost: { usd_micro: 1900, actual: true } }),
    E("sim-cafu-2", 3, 6, { kind: "step", state: "running", label: "Synthèse et scénarios", model: "muse-wonder-1.0", profile: "deep", reserved_usd_micro: 420000, cost: { usd_micro: 236000, actual: false } }),
    E("sim-cafu-2", 4, 10, { kind: "step", state: "verifying", label: "Relecture Spark Open (poids ouverts)", model: "meta-models/muse-spark-open", profile: "verify", cost: { usd_micro: 6400, actual: true } }),
    E("sim-tri-3", 1, 0, { kind: "created", state: "running", agent: "Triage", title: "Tri des mails de la nuit", profile: "triage", data_class: "personal", cap_usd_micro: 750000, steps_max: 4, label: "Tâche créée" }),
    E("sim-tri-3", 2, 2, { kind: "step", state: "running", label: "Étiquetage de 23 messages", model: "muse-spark-1.3", profile: "triage", cost: { usd_micro: 2210, actual: true } }),
    E("sim-tri-3", 3, 4, { kind: "receipt", state: "done", label: "Étiquettes posées", receipt: { kind: "gmail_labels", id: "sim-batch-77" } }),
  ];
}

/** Résumé Phase 3 (AgentEngine.summary) → tâche affichée. `specs` = agents de GET /api/agents2 (plafond, étapes max). */
const STEP_STATE = { pending: "draft", started: "running", done: "done", failed: "failed" };
export function fromAgents2(o, specs = {}) {
  const sp = specs[o.agent] || {};
  const steps = (Array.isArray(o.steps) ? o.steps : []).map((st, i) => ({ seq: i + 1, at: null, kind: "step",
    label: String(st.tool || "étape") + (st.attempts > 1 ? " (essai " + st.attempts + ")" : ""), state: STEP_STATE[st.status] || null,
    model: null, profile: null, cost: null, error: st.status === "failed" ? "échec" : null, receipt: st.receipt || "" }));
  const withReceipt = steps.filter((x) => x.receipt);
  const state = STATES.includes(o.state) ? o.state : "unknown";
  return { id: String(o.id || ""), agent: sp.label || o.agent || "", title: (sp.label || o.agent || "Tâche") + (o.reason ? " — " + o.reason : ""),
    state, data_class: o.dataClass || null, cap_usd_micro: sp.capMicros != null ? Number(sp.capMicros) : null, steps_max: sp.maxSteps || null,
    spent_usd_micro: Number(o.spentMicros || 0), steps, updated_at: o.createdAt || "", last_seq: steps.length,
    approval: state === "awaiting_approval" ? { content_preview: String(o.content || ""), content_sha256: String(o.contentSha256 || "") } : null,
    receipt: withReceipt.length ? { kind: withReceipt[withReceipt.length - 1].label, id: withReceipt[withReceipt.length - 1].receipt } : null };
}

/** Flux de tâches : réel si GET /api/agents2 répond avec enabled=true, sinon simulé. onChange(tasks, meta) à chaque changement. */
export function createTaskFeed({ api, bus }, onChange) {
  let tasks = {}, simulated = false, timers = [], poll = null, reason = "", stopped = false;
  const emit = () => { try { onChange(tasks, { simulated, reason }); } catch (e) {} };
  const feed = (ev) => { const n = applyEvent(tasks, ev); if (n !== tasks) { tasks = n; emit(); } };
  async function readReal() {
    const j = await api.get("/api/agents2", 8000);
    if (!j || j.enabled !== true) { const e = new Error(j && j.enabled === false ? "réglage agents_v2 désactivé" : "réponse sans « enabled »"); e.off = true; throw e; }
    if (!Array.isArray(j.tasks)) throw new Error("réponse sans « tasks »");
    const specs = {}; for (const a of (Array.isArray(j.agents) ? j.agents : [])) if (a && a.id) specs[a.id] = a;
    const n = {}; for (const o of j.tasks) { if (!o || !o.id) continue; const t = fromAgents2(o, specs); n[t.id] = t; }
    tasks = n; emit();
  }
  async function start() {
    try {
      await readReal();
      simulated = false; reason = "";
      poll = setInterval(() => { if (!stopped) readReal().catch(() => {}); }, 4000);
    } catch (e) {
      if (stopped) return;
      simulated = true; reason = String((e && e.message) || e);
      const t0 = Date.now(), script = simulatedScript(t0);
      for (const ev of script) { const d = Math.max(0, Date.parse(ev.at) - t0); timers.push(setTimeout(() => feed(ev), Math.min(d, 12000))); }
      emit();
    }
  }
  /* Actions : en simulé, l'effet est local ET dit ; en réel, la Phase 3 répond puis on relit l'état qui fait foi. */
  async function act(id, verb, body = {}) {
    const t = tasks[id]; if (!t) return { ok: false, error: "tâche inconnue" };
    if (simulated) {
      const seq = (t.last_seq || 0) + 1, at = new Date().toISOString();
      const map = { approve: { kind: "approval_granted", state: "running", label: "Approuvé (simulé) — rien n'a été envoyé" }, cancel: { kind: "cancelled", state: "cancelled", label: "Annulée par toi (simulé)" }, edit: { kind: "approval_cleared", state: "draft", label: "Renvoyée en brouillon pour modification (simulé)" } };
      feed({ v: 1, task_id: id, seq, at, ...map[verb] });
      return { ok: true, simulated: true };
    }
    if (verb === "edit") return { ok: false, error: "la Phase 3 n'expose pas de route de modification" };
    const hdrs = {};
    if (verb === "approve") {
      if (typeof window === "undefined" || !window.__novaProv) return { ok: false, error: "provenance d'interface indisponible — relance Nova puis réessaie ; rien n'a été approuvé" };
      hdrs["x-nova-provenance"] = window.__novaProv;
    }
    try {
      const j = await api.post("/api/agents2/" + verb, { id, ...body }, 20000, hdrs);
      try { await readReal(); } catch (e) {}
      return j && j.ok === false ? { ok: false, error: String(j.error || j.code || "refusé") } : { ok: true, ...j };
    } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  }
  start();
  return {
    get tasks() { return tasks; }, get simulated() { return simulated; }, get canEdit() { return simulated; },
    approve: (id) => act(id, "approve", { sha256: tasks[id] && tasks[id].approval ? tasks[id].approval.content_sha256 : "" }),
    edit: (id, content) => act(id, "edit", { content }),
    cancel: (id) => act(id, "cancel"),
    stop() { stopped = true; for (const x of timers) clearTimeout(x); timers = []; if (poll) clearInterval(poll); poll = null; },
  };
}
