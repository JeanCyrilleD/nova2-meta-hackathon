/* Module Système — l'« État machine » de l'ancienne UI, restauré sur du réel :
   GET /api/system (instantané du Mac), GET /api/blackbox (journal scellé, chaîne
   vérifiée — amendement n°13 « double écriture » : chaque action y laisse sa trace),
   GET /api/actions (les actions des outils, annulables), GET /api/souverain
   (gouvernance F5 : quel cerveau a le droit de répondre, et pourquoi),
   GET /api/localfirst (F3 : le petit modèle local d'abord), GET /api/backup,
   POST /api/backup/run, GET /api/system/selftest (l'audit interne, C6 partiel). */
/* NOVA2 vague 3 — E3 + C6 : Système est le compartiment « Santé » (santé de l'app et
   du système, pas de données de santé personnelles) : il s'ouvre derrière la porte du
   coffre (vaultgate.js) et se reverrouille en quittant l'écran. C6 : l'audit interne
   du moteur (GET /api/system/selftest → NovaSelfTest) s'affiche EN ENTIER ci-dessous,
   plus seulement un toast renvoyant à la boîte noire. */
/* V6 (25/10) — refonte premium (contrat conseil_24-10/V6_DESIGN.md) : en-tête ds ; Réseau = ligne d'état +
   métriques NUMÉRIQUES seulement (.ds-kpis) + lignes « Cerveau local / File / Instantané » avec leurs actions ;
   Charge du jour = lignes alignées « valeur / seuil » + pastille sémantique, le Compagnon dans une vraie ligne
   de réglage expliquée ; Gouvernance en lignes ; détail de l'audit replié ; actions des outils et boîte noire
   (traces techniques) en sections repliées. Routes, porte du coffre, verrouillage au départ et cartes
   d'approbation inchangés. */
import { vaultGate, vaultLock } from "../vaultgate.js";
import { approvalCard } from "../orb.js";
import * as ds from "../ds.js";
import { LBL, fmtV, fmtDateFR, fmtTimeFR, fmtDurFR, fmtNumFR, ligneBrute, truncWords } from "../core.js";
import { autotestSection } from "./systeme-autotest.js";   // 25/10 : autotest de la nuit (Feat_Autotest.swift)
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
/* Normalisation d'horodatage puis rendu délégué aux formateurs partagés (§9.8). */
const fmtDate = (v) => {
  if (!v) return "";
  const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v);
  return isNaN(d) ? String(v).slice(0, 16) : fmtDateFR(d) + " " + fmtTimeFR(d);
};
const scalars = (o, n = 10) => Object.entries(o || {}).filter(([, v]) => ["string", "number", "boolean"].includes(typeof v)).slice(0, n);
const plur = (n, one, many) => fmtNumFR(n) + " " + (Number(n) > 1 ? many : one);
const cap = (s) => { const t = String(s || ""); return t ? t.charAt(0).toUpperCase() + t.slice(1) : t; };
/* U6 (23/10) : table de libellés de l'audit NovaSelfTest — vocabulaire fixe du
   moteur (UltraDatabase/VectorEngine). Clé inconnue → ligne OMISSE (doctrine
   §9.4), jamais « LBL[k] || k ». */
const AUDIT_LBL = { ok: "Réussi", ms_moy: "Durée moyenne (ms)", NovaIPC: "IPC Nova", NovaIsolation: "Isolation", NovaIsolationCOEP: "Isolation COEP", NovaSQLite: "SQLite", NovaVectors: "Vecteurs", flag: "Interrupteur", mirror_json: "Miroir JSON", fts5_compiled: "FTS5 compilé", open: "Base ouverte", fts5: "FTS5 actif", path: "Chemin", kv: "Clés KV", activity: "Activité", n: "Échantillon", ecriture_transaction_ms: "Écriture transaction (ms)", ecriture_unitaire_ms_moy: "Écriture unitaire moy. (ms)", lecture_ms_total: "Lecture totale (ms)", lecture_us_moy: "Lecture moy. (µs)", payload_octets: "Charge (octets)", enabled: "Activé", rows: "Lignes", dim: "Dimension", building: "Construction en cours", build_ms: "Construction (ms)", last_query_ms: "Dernière requête (ms)", kind: "Moteur", requete_reelle_ms: "Requête réelle (ms)", requete_reelle_hits: "Requête réelle (résultats)", synthetique_top: "Synthétique (top)", moteur: "Moteur", error: "Erreur" };
const auditLabel = (k) => AUDIT_LBL[k] || (/^synthetique_5000x\d+_ms$/.test(k) ? "Synthétique 5 000 vecteurs (ms)" : null);

export async function mount(root, ctx) {
  const { api, h } = ctx;
  let dead = false;
  root.classList.add("mod--data");   // plafond écran de données (§2.3)
  root.classList.add("is-locked");   // §6.13 : état verrouillé porté par l'écran tant que la porte n'a pas ouvert
  const errBox = (msg, retry) => ds.errorBox({ cause: msg, retry });
  const list = (...rows) => h("div", { class: "ds-list" }, ...rows);
  /* Bouton d'action qui se désactive pendant son travail (asynchrone). */
  const busyBtn = (desc, work) => {
    const b = ds.action({ ...desc, onClick: async () => { b.disabled = true; try { await work(b); } finally { if (b.isConnected) b.disabled = false; } } });
    return b;
  };

  root.append(ds.pageHead({ title: "Système", sub: "Le Mac, le moteur et la trace scellée de ce qui s'y fait",
    actions: [{ label: "Actualiser", icon: "refresh", tip: "Relire l'état du réseau, de la charge et, coffre ouvert, du Mac", onClick: () => refreshAll() }] }));

  const sysBox = h("div", {}, ds.skeleton(2));
  const netBox = h("div", {}, ds.skeleton(2));      // VAGUE 2 RÉSILIENCE : Réseau
  const chargeBox = h("div", {}, ds.skeleton(3));   // VAGUE 2 : Charge du jour
  const govBox = h("div", {});
  const auditBox = h("div", {});
  const actBox = h("div", {});
  const droitsBox = h("div", {});
  const bbBox = h("div", {});
  const body = h("div", { class: "sy-body" });
  body.hidden = true;   // Audit ecrans 20/10 : verrouille, seule la porte est visible — pas les titres de sections a nu.
  /* 24/10 : Réseau et Charge ne sont pas des secrets — visibles sans ouvrir le coffre */
  root.append(h("div", { class: "rz-public" },
    ds.section({ title: "Réseau", body: netBox }),
    ds.section({ title: "Charge du jour", body: chargeBox })));
  const autoTest = autotestSection(ctx, () => dead);   // 25/10 : autotest de la nuit — public (pas un secret), visible coffre fermé
  root.append(autoTest.el);
  autoTest.load();
  root.append(vaultGate(ctx, "Santé du système", () => { body.hidden = false; root.classList.remove("is-locked"); if (!dead) start(); }), body);

  const backupBtn = busyBtn({ label: "Sauvegarder maintenant", icon: "download", tip: "Lancer une sauvegarde de Nova maintenant" }, async () => {
    try { await api.post("/api/backup/run", {}); ctx.toast("Sauvegarde lancée."); loadBackup(); } catch (err) { ctx.toast("Sauvegarde impossible.", true); }
  });
  const recheckBtn = busyBtn({ label: "Revérifier", icon: "refresh", tip: "Relire l'état réel des droits macOS" }, () => loadDroits(true));
  const auditBtn = busyBtn({ label: "Relancer l'audit", icon: "refresh", tip: "Relancer l'auto-test du moteur" }, () => loadAudit());
  const govDesc = h("p", { class: "ds-meta sy-desc" }, "Mode souverain : seuls les cerveaux nommés répondent.");
  const actSec = ds.section({ title: "Actions des outils", count: "—", collapsible: true, open: false, body: [h("p", { class: "ds-meta sy-desc" }, "Les actions faites par les outils de Nova — annulables par carte d'approbation."), actBox] });
  const bbChain = h("span", { class: "sy-chain" });
  const bbSec = ds.section({ title: "Boîte noire", count: "—", collapsible: true, open: false, actions: [bbChain], body: bbBox });
  body.append(
    ds.section({ title: "Ce Mac", actions: [backupBtn], body: sysBox }),
    ds.section({ title: "Droits d'accès macOS", actions: [recheckBtn], body: droitsBox }),
    ds.section({ title: "Gouvernance des cerveaux", body: [govDesc, govBox] }),
    ds.section({ title: "Auto-test du moteur", actions: [auditBtn], body: auditBox }),
    actSec, bbSec);

  async function loadSys() {
    try {
      const j = await api.get("/api/system");
      if (dead) return;
      /* §9.4/§9.8 : libellés et formats = helpers partagés de core.js (octets → fmtBytesFR,
         durées → fmtDurFR, thermique nettoyé par la table — plus de « modéré (modéré) »).
         Une clé inconnue est omise et journalisée, jamais affichée brute (CT1). */
      const pairs = scalars(j, 12)
        .filter(([k]) => { if (!LBL[k]) { try { console.warn("Système : clé inconnue omise :", k); } catch (e) {} return false; } return true; })
        .map(([k, v]) => [LBL[k], fmtV(k, v)]);
      /* V5-Y : des valeurs TEXTE (« macOS 26.1 », « Apple M3 ») ne sont pas des chiffres géants — grille
         clé/valeur sobre ; l'heure du relevé passe en méta. */
      const tsPair = pairs.find(([lb]) => lb === LBL.ts);
      const kv = pairs.filter((p) => p !== tsPair);
      sysBox.replaceChildren(ds.card({ class: "sy-mac" },
        kv.length ? h("dl", { class: "sy-kv" }, ...kv.map(([label, val]) => h("div", { class: "sy-kv-i" }, h("dt", {}, label), h("dd", { class: "ds-num", title: String(val) }, String(val)))))
          : ds.empty({ text: "Le moteur n'a servi aucune valeur connue sur ce Mac.", compact: true }),
        h("div", { class: "sy-foot ds-meta" },
          tsPair ? h("span", {}, "Relevé à " + tsPair[1]) : null,
          h("span", { class: "backup-slot" }, "Sauvegarde : lecture…"))));
      loadBackup();
    } catch (e) { if (!dead) sysBox.replaceChildren(errBox("État du Mac injoignable.", loadSys)); }
  }
  async function loadBackup() {
    try {
      const j = await api.get("/api/backup");
      if (dead) return;
      const slot = sysBox.querySelector(".backup-slot");
      const items = arrOf(j, "items", "backups");
      if (slot) slot.textContent = items.length ? "Dernière sauvegarde : " + String((items[0] && (items[0].name || items[0].date || items[0].at)) || "—") + " · " + plur(items.length, "archive", "archives") : "Aucune archive de sauvegarde lue.";
    } catch (e) { /* sauvegarde : affichage secondaire */ }
  }
  /* ── P-CAL-3b : droits d'accès macOS (GET /api/droits, moteur Feat_Droits) ──
     La demande d'accès EventKit ne part QUE d'un clic ici : « Demander l'accès »
     (calendrier → POST /api/droits/request-calendar ; rappels → …/request-reminders).
     La route répond tout de suite { ok, state: « demande affichée » } pendant que la
     boîte système macOS décide en asynchrone : on nomme cet état, puis on revérifie
     l'état réel (force=1, le moteur invalide son cache à la fin de la demande) pour
     afficher accordé / refusé / en attente — jamais un succès supposé. */
  const droitsReq = { calendrier: "/api/droits/request-calendar", rappels: "/api/droits/request-reminders" };
  let droitsMsg = "";
  function renderDroitsMsg() { const m = droitsBox.querySelector(".droits-msg"); if (m) { m.textContent = droitsMsg; m.hidden = !droitsMsg; } }
  async function loadDroits(force) {
    try {
      const j = await api.get("/api/droits" + (force ? "?force=1" : ""));
      if (dead) return;
      const items = arrOf(j, "items");
      const pillOf = (it) => it.ok === true ? ds.pill("Accordé", "ok") : (it.state === "no" ? ds.pill("Refusé", "danger") : ds.pill("À demander", "warn"));
      const acts = (it) => [
        (droitsReq[it.id] || (String(it.id || "").startsWith("auto-") && it.state === "na")) && it.ok !== true ? busyBtn({ label: "Demander l'accès" }, async () => {
          try {
            const r = await api.post(droitsReq[it.id] || "/api/droits/request-automation", droitsReq[it.id] ? {} : { id: it.id });
            droitsMsg = String(it.label || it.id) + " : " + String((r && r.state) || "demande envoyée") + " — réponds dans la boîte macOS ; l'état se revérifie ici.";
          } catch (err) {
            droitsMsg = String(it.label || it.id) + " : demande impossible — " + String((err && err.message) || err);
          }
          renderDroitsMsg();
          setTimeout(() => { if (!dead) loadDroits(true); }, 1800);
        }) : null,
        it.pane && it.ok !== true ? busyBtn({ label: "Ouvrir le réglage", icon: "external" }, async () => {
          try { await api.post("/api/droits/open", { pane: it.pane }); droitsMsg = String(it.label || it.id) + " : panneau Réglages ouvert — l'état se revérifie au retour."; }
          catch (err) { droitsMsg = String(it.label || it.id) + " : ouverture impossible — " + String((err && err.message) || err); }
          renderDroitsMsg();
        }) : null];
      droitsBox.replaceChildren(
        items.length ? ds.card({ flush: true, class: "sy-acts" }, list(...items.map((it) => ds.row({
          title: String(it.label || it.id || ""), meta: String(it.detail || "") || null, side: pillOf(it), actions: acts(it) }))))
          : ds.empty({ text: "Aucun droit lu pour le moment — « Revérifier » relit l'état macOS.", compact: true }),
        h("p", { class: "ds-meta droits-msg sy-msg", role: "status", hidden: !droitsMsg }, droitsMsg));
    } catch (e) { if (!dead) droitsBox.replaceChildren(errBox("Droits injoignables.", () => loadDroits(true))); }
  }
  async function loadGov() {
    try {
      const j = await api.get("/api/souverain");
      if (dead) return;
      const lf = await api.get("/api/localfirst").catch(() => null);
      if (dead) return;
      const govPairs = scalars(j, 8)
        .filter(([k]) => { if (!LBL[k]) { try { console.warn("Système : clé de gouvernance inconnue omise :", k); } catch (e) {} return false; } return true; })
        .map(([k, v]) => [LBL[k], fmtV(k, v)]);
      const lfEtat = !lf ? "non lu" : (lf.enabled === true || lf.local_first === true) ? "activé" : (lf.enabled === false || lf.local_first === false) ? "désactivé" : "état inconnu";
      const lfPill = lfEtat === "activé" ? ds.pill("Activé", "ok") : lfEtat === "désactivé" ? ds.pill("Désactivé", "neutral") : ds.pill(lfEtat === "non lu" ? "Non lu" : "Inconnu", "neutral");
      if (!lf) lfPill.title = "Le moteur n'a pas répondu sur le réglage « local d'abord ».";
      /* V5-Y : plus de rangée vide quand le moteur ne sert aucune clé connue ; codes internes (F3, S1/C4) retirés du texte. */
      govBox.replaceChildren(ds.card({ flush: true }, list(
        ...govPairs.map(([label, val]) => ds.row({ title: label, side: h("span", { class: "sy-txtval", title: String(val) }, truncWords(String(val), 42)) })),
        ds.row({ title: "Local d'abord", meta: "Le modèle local reste toujours le dernier repli.", side: lfPill }))));
    } catch (e) { if (!dead) govBox.replaceChildren(errBox("Gouvernance injoignable.", loadGov)); }
  }
  async function loadActions() {
    try {
      const j = await api.get("/api/actions");
      if (dead) return;
      const items = arrOf(j, "items", "actions");
      actSec.setCount(items.length);
      actBox.replaceChildren(items.length ? ds.card({ flush: true, class: "sy-acts" }, list(...items.slice(0, 12).map((a) => ds.row({
        title: h("span", { class: "sy-trace" }, String(a.tool || a.name || a.action || ligneBrute(a))),
        meta: [fmtDate(a.at || a.date || a.ts), truncWords(String(a.why || a.input || a.summary || ""), 110)].filter(Boolean).join(" · ") || null,
        side: a.undone ? ds.pill("Annulée", "neutral") : null,
        /* §9.4 : annulation par carte d'approbation .appr PARTOUT — plus d'annulation directe. */
        actions: a.undone ? null : [{ label: "Annuler", icon: "undo", tip: "Annuler cette action (carte d'approbation)", onClick: async () => {
          const card = approvalCard({ title: "Annuler cette action ?", what: (a.tool || a.name || a.action ? String(a.tool || a.name || a.action) + (a.why ? " · " + truncWords(String(a.why), 110) : "") : ligneBrute(a)) + " — le moteur tentera l'opération inverse exacte.", approveLabel: "Annuler l'action", refuseLabel: "Laisser" });
          actBox.prepend(card);
          try { card.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (e) {}
          const v = await card.promise; card.remove(); if (v !== "approve") return;
          try { const r = await api.post("/api/actions/undo", { id: a.id }); ctx.toast(String((r && r.message) || "Action annulée.")); loadActions(); }
          catch (e) { ctx.toast("Annulation impossible.", true); }
        } }] }))))
        : ds.empty({ text: "Aucune action d'outil enregistrée dans cette session.", compact: true }));
    } catch (e) { if (!dead) actBox.replaceChildren(errBox("Actions injoignables.", loadActions)); }
  }
  async function loadBB() {
    try {
      const j = await api.get("/api/blackbox");
      if (dead) return;
      const items = arrOf(j, "items");
      const ver = (j && j.verify) || {};
      const okChain = ver.ok === true || ver.valid === true;
      bbChain.replaceChildren(okChain ? ds.pill("Chaîne vérifiée", "ok") : ver.ok === false ? ds.pill("Écart signalé", "danger") : ds.pill("Non vérifiée", "neutral"));
      bbChain.title = okChain ? "La chaîne scellée du journal a été vérifiée par le moteur." : ver.ok === false ? "Le moteur signale un écart dans la chaîne du journal." : "Le moteur n'a pas renvoyé de vérification de la chaîne.";
      bbSec.setCount(items.length);
      bbBox.replaceChildren(
        h("p", { class: "ds-meta sy-desc" }, "Journal scellé : chaque action sensible y laisse sa trace (qui, quoi, effet). " + plur(items.length, "entrée récente", "entrées récentes") + "."),
        items.length ? ds.card({ flush: true }, list(...items.slice(0, 15).map((b) => ds.row({
          title: h("span", { class: "sy-trace" }, String(b.tool || b.action || ligneBrute(b))),
          meta: [b.actor || "", b.effect || "", fmtDate(b.at || b.ts || b.date), truncWords(String(b.result || ""), 80)].filter(Boolean).join(" · ") || null,
          side: b.ok === false ? ds.pill("Échec", "danger") : ds.pill("Réussie", "ok") }))))
          : ds.empty({ text: "Journal vide pour le moment.", compact: true }));
    } catch (e) { if (!dead) bbBox.replaceChildren(errBox("Boîte noire injoignable.", loadBB)); }
  }
  /* ── C6 : l'audit indépendant, rendu EN ENTIER (détail replié) ──────────
     GET /api/system/selftest → NovaSelfTest.run : interrupteurs du moteur, routage
     interne éprouvé 20 fois (dispatch direct), bancs SQLite et vecteurs, le tout
     horodaté. On affiche ce que le moteur renvoie, section par section — le verdict
     n'est « OK » que si chaque sous-test connu l'est. */
  async function loadAudit() {
    auditBox.replaceChildren(ds.skeleton(1));
    try {
      const j = await api.get("/api/system/selftest");
      if (dead) return;
      const sect = (title, o) => {
        /* U6 (23/10) : même doctrine que loadSys/loadGov — clé inconnue OMISSE
           (jamais « LBL[k] || k »), valeur formatée par fmtV (booléen → oui/non). */
        const rows = scalars(o, 12)
          .map(([k, v]) => { const lb = auditLabel(k); if (!lb) { try { console.warn("Système (audit) : clé inconnue omise :", k); } catch (e) {} return null; } return [lb, k === "moteur" ? (v === "vDSP_mmul" ? "vDSP (Accelerate)" : String(v)) : fmtV(k, v)]; })
          .filter(Boolean);
        return h("div", { class: "sy-au" },
          h("div", { class: "ds-h3" }, title),
          rows.length ? h("dl", { class: "sy-au-kv" }, ...rows.map(([lb, val]) => h("div", {}, h("dt", {}, lb), h("dd", { class: "ds-num", title: String(val) }, truncWords(String(val), 60)))))
            : h("div", { class: "ds-meta", title: "Le moteur n'a renvoyé aucune valeur connue pour ce sous-test." }, "—"));
      };
      const dd = (j && j.dispatch_direct) || {};
      const vec = (j && j.vecteurs) || {};
      const sq = (j && j.sqlite) || {};
      const oks = [dd.ok, vec.ok, sq.ok].filter((v) => v != null);
      const nOk = oks.filter((v) => v === true).length;
      /* D-26 : trois états distincts — vert / écarts / NON MESURÉ (aucun sous-test connu). */
      const verdict = !oks.length ? "none" : (nOk === oks.length ? "ok" : "warn");
      const dur = j && j.total_ms != null ? (Number(j.total_ms) < 1000 ? fmtNumFR(Math.round(Number(j.total_ms))) + " ms" : fmtDurFR(j.total_ms)) : "";   // V5-Y : 420 ms s'affichait « 0 s »
      auditBox.replaceChildren(ds.card({ class: "sy-audit" },
        list(ds.row({
          lead: "check",
          title: verdict === "ok" ? "Tous les sous-tests connus sont au vert" : verdict === "warn" ? "Écarts — voir le détail des sous-tests" : "Non mesuré — aucun sous-test connu renvoyé",
          meta: [nOk + "/" + oks.length + " au vert", j && j.ts ? "mesuré le " + fmtDate(j.ts) : "", dur ? "durée " + dur : ""].filter(Boolean).join(" · "),
          side: verdict === "ok" ? ds.pill("Au vert", "ok") : verdict === "warn" ? ds.pill("Écarts", "warn") : ds.pill("Non mesuré", "neutral") })),
        ds.fold("Détail des sous-tests", h("div", { class: "sy-au-grid" },
          sect("Routage interne", dd),
          sect("Interrupteurs du moteur", (j && j.interrupteurs) || {}),
          sect("SQLite", sq),
          sect("Banc SQLite", (j && j.sqlite_bench) || {}),
          sect("Index vectoriel", vec)), verdict === "warn")));
      loadBB();
    } catch (e) { if (!dead) auditBox.replaceChildren(errBox("Auto-test injoignable pour le moment.", loadAudit)); }
  }
  /* ── VAGUE 2 RÉSILIENCE : Réseau (GET /api/reseau, /api/offline/file, POST /api/offline/rejouer) ──
     État mesuré par le moteur (NWPathMonitor + sonde HEAD espacée vers l'API du cerveau principal) :
     bon / faible / hors ligne. La file hors ligne ne contient que des lectures / compositions ; le rejeu
     repasse par le chat normal (cartes de confirmation intactes). Événement « net » : rechargement. */
  const NET_TONE = { bon: "ok", faible: "warn", hors_ligne: "danger" };
  const Q_LBL = { attente: "en attente", fait: "traitée", echec: "en échec", relance: "rendue au planificateur", annule: "retirée" };
  let netOpen = "";   // "" | "file" | "cache"
  async function loadNet() {
    try {
      const j = await api.get("/api/reseau" + (netOpen === "cache" ? "?cache=1" : ""));
      if (dead) return;
      const etat = j && j.etat;
      const f = (j && j.file) || {};
      const pc = (j && j.precalcul) || {};
      const lat = j && (j.latence_mediane_ms ?? j.latence_ms);
      const slow = j && Number(j.seuil_lent_ms) > 0 ? Number(j.seuil_lent_ms) : null;
      const attente = Number(f.attente) || 0;
      const head = ds.row({
        lead: "globe",
        title: etat ? "Connexion : " + String(j.libelle || etat) : "État du réseau non lu",
        meta: etat
          ? [j.depuis ? "depuis " + fmtDate(j.depuis) : "", j.interface ? "interface " + j.interface : "", j.sonde_hote ? "sonde " + j.sonde_hote : "", j.sonde_erreur ? "dernière erreur : " + truncWords(String(j.sonde_erreur), 60) : ""].filter(Boolean).join(" · ")
          : "Le moteur n'a pas encore répondu sur l'état du réseau.",
        side: etat ? ds.pill(cap(j.libelle || etat), NET_TONE[etat] || "neutral") : ds.pill("Non lu", "neutral") });
      const stats = etat ? ds.kpis([
        { label: "Latence médiane", value: lat != null ? fmtNumFR(lat) + " ms" : null, tip: lat != null ? "Médiane des dernières sondes du moteur" : "Aucune sonde mesurée pour le moment",
          delta: slow ? "lent au-delà de " + fmtNumFR(slow) + " ms" : null, tone: slow && lat != null && lat >= slow ? "warn" : null },
        { label: "En file hors ligne", value: f.attente != null ? fmtNumFR(f.attente) : null, tip: f.attente != null ? "Demandes gardées en attente du réseau" : "Compte de la file non servi par le moteur", tone: attente > 0 ? "warn" : null, delta: attente > 0 ? "à rejouer" : null },
        { label: "Traitées au retour", value: f.fait != null ? fmtNumFR(f.fait) : null, tip: f.fait != null ? "Demandes rejouées au retour du réseau" : "Compte non servi par le moteur" },
        { label: "Dernier pré-calcul", value: pc.fait ? String(pc.heure || "") || null : null, tip: pc.fait ? "Heure de l'instantané hors ligne" : String(pc.note || "Aucun pré-calcul pour le moment") },
      ]) : null;
      const cl = j && j.cerveau_local;
      const clRow = etat ? ds.row({ lead: "brain", title: "Cerveau local",
        meta: cl ? "Repli hors ligne prêt" + (typeof cl === "string" ? " : " + cl : "") : "Aucun cerveau local disponible : pas de repli hors ligne.",
        side: cl ? ds.pill("Prêt", "ok") : ds.pill("Absent", "neutral") }) : null;
      const fileRow = ds.row({ lead: "inbox", title: "File hors ligne",
        meta: plur(attente, "demande en attente", "demandes en attente") + " · lectures et compositions seulement, rejouées par le chat normal",
        actions: [
          attente > 0 ? { label: "Rejouer la file", icon: "refresh", tip: "Rejouer les " + attente + " demande(s) en file hors ligne", onClick: async (e) => {
            const b = e.currentTarget; if (b) b.disabled = true;
            try { const r = await api.post("/api/offline/rejouer", {}); ctx.toast(String((r && r.message) || "Demande envoyée.")); }
            catch (err) { ctx.toast("Rejeu impossible pour le moment.", true); }
            if (b) b.disabled = false; setTimeout(() => { if (!dead) loadNet(); }, 1500);
          } } : null,
          { label: netOpen === "file" ? "Masquer la file" : "Voir la file", onClick: () => { netOpen = netOpen === "file" ? "" : "file"; loadNet(); } }] });
      const snapMeta = pc.fait
        ? "Prêt à " + String(pc.heure || "—") + " · " + [plur(pc.agenda || 0, "évènement", "évènements"), plur(pc.mails || 0, "mail trié", "mails triés"), plur(pc.engagements || 0, "engagement", "engagements"), plur(pc.brief || 0, "carte du Pulse", "cartes du Pulse")].join(", ")
        : String(pc.note || "Aucun pré-calcul pour le moment.");
      const snapRow = ds.row({ lead: "layers", title: "Instantané hors ligne", meta: snapMeta,
        actions: [{ label: netOpen === "cache" ? "Masquer l'instantané" : "Voir l'instantané", onClick: () => { netOpen = netOpen === "cache" ? "" : "cache"; loadNet(); } }] });
      if (netOpen === "file") fileRow.classList.add("is-selected");
      if (netOpen === "cache") snapRow.classList.add("is-selected");
      const extra = h("div", { class: "sy-extra" });
      netBox.replaceChildren(
        ds.card({ flush: true }, list(head)),
        stats,
        ds.card({ flush: true, class: "sy-acts" }, list(clRow, fileRow, snapRow)),
        extra);
      if (netOpen === "file") renderQueue(extra);
      if (netOpen === "cache") renderCache(extra, (j && j.cache) || {});
    } catch (e) { if (!dead) netBox.replaceChildren(errBox("Réseau injoignable.", loadNet)); }
  }
  async function renderQueue(box) {
    box.replaceChildren(ds.skeleton(1));
    try {
      const j = await api.get("/api/offline/file");
      if (dead) return;
      const items = arrOf(j, "items");
      const tone = (s) => s === "fait" ? "ok" : s === "echec" ? "danger" : s === "attente" ? "warn" : "neutral";
      box.replaceChildren(items.length ? ds.card({ flush: true, class: "sy-acts" }, list(...items.slice(0, 20).map((it) => ds.row({
        title: it.type === "eclat" ? "Éclat « " + String(it.nom || it.eclat || "") + " » — créneau " + String(it.creneau || "").slice(11) : truncWords(String(it.texte || ""), 90),
        meta: [fmtDate(it.ts), it.essais ? plur(it.essais, "essai", "essais") : "", truncWords(String(it.note || ""), 70)].filter(Boolean).join(" · ") || null,
        side: ds.pill(cap(Q_LBL[it.statut] || "inconnu"), tone(it.statut)),
        actions: it.statut === "attente" ? [{ label: "Retirer", tip: "Retirer cette demande de la file", onClick: async () => {
          try { await api.post("/api/offline/rejouer", { annuler: it.id }); renderQueue(box); loadNet(); } catch (e) { ctx.toast("Retrait impossible.", true); }
        } }] : null }))))
        : ds.empty({ text: "File vide : aucune demande en attente du réseau.", compact: true }));
    } catch (e) { if (!dead) box.replaceChildren(errBox("File injoignable.", () => renderQueue(box))); }
  }
  function renderCache(box, c) {
    if (!c || !c.ts) { box.replaceChildren(ds.empty({ text: "Aucun instantané hors ligne pour le moment.", compact: true })); return; }
    const col = (titre, arr, fmt) => h("div", { class: "sy-col" }, h("div", { class: "ds-h3" }, titre),
      ...(Array.isArray(arr) && arr.length ? arr.slice(0, 8).map((x) => { const t = fmt(x); return h("div", { class: "sy-col-i", title: t }, t); }) : [h("div", { class: "ds-meta" }, "—")]));
    box.replaceChildren(ds.card({ class: "sy-cache" },
      h("div", { class: "ds-meta" }, "Ce que Nova garde pour travailler hors ligne — état de " + String(c.heure || "—")),
      h("div", { class: "sy-cols" },
        col("Agenda du jour", c.agenda, (x) => String(x.heure || "") + " · " + String(x.titre || "")),
        col("Mails triés", c.mails, (x) => (x.urgent ? "Urgent · " : "") + String(x.boite || "") + " · " + String(x.titre || "")),
        col("Engagements", c.engagements, (x) => String(x.quoi || "") + (x.echeance ? " · " + x.echeance : "") + (x.en_retard ? " (en retard)" : "")))));
  }
  /* ── VAGUE 2 : Charge du jour (GET /api/charge, POST /api/charge/reglage {actif}) ──
     Signaux RÉELS, chacun avec sa source et son seuil ; « non mesuré » plutôt qu'une estimation.
     Aucun diagnostic : un rythme de travail, pas un état de santé. */
  const LVL_PILL = { dense: ["Dense", "warn"], soutenue: ["Soutenue", "warn"], legere: ["Habituelle", "ok"] };
  async function loadCharge() {
    try {
      const j = await api.get("/api/charge");
      if (dead) return;
      const sig = arrOf(j, "signaux");
      const sugg = arrOf(j, "suggestions");
      const pl = (j && j.plafond) || {};
      const on = j && j.actif !== false;
      const swb = h("button", { class: "switch", type: "button", role: "switch", "aria-checked": on ? "true" : "false", "aria-label": "Activer ou couper le compagnon de charge",
        onclick: async () => {
          const v = swb.getAttribute("aria-checked") !== "true"; swb.setAttribute("aria-checked", String(v));
          try { await api.post("/api/charge/reglage", { actif: v }); ctx.toast(v ? "Compagnon de charge activé." : "Compagnon de charge coupé."); } catch (e) { ctx.toast("Réglage impossible.", true); }
          loadCharge();
        } });
      const lv = j && j.niveau ? (LVL_PILL[j.niveau] || [cap(j.niveau_libelle || j.niveau), "neutral"]) : null;
      const head = ds.row({ lead: "pulse",
        title: j && j.niveau_libelle ? "Aujourd'hui : " + j.niveau_libelle : "Charge du jour non lue",
        meta: sig.length ? plur(j.signaux_au_dessus ?? 0, "signal au-dessus du seuil", "signaux au-dessus du seuil") + " · " + (pl.emises ?? 0) + "/" + (pl.max_jour ?? 2) + " proposition(s) aujourd'hui" : "Le moteur n'a pas encore servi de signaux.",
        side: lv ? ds.pill(lv[0], lv[1]) : ds.pill("Non lu", "neutral") });
      const sigRow = (s) => {
        const measured = !(s.mesure === false || s.valeur == null);
        const u = s.unite ? " " + s.unite : "";
        const val = h("span", { class: "sy-val" + (measured && s.depasse ? " is-over" : ""), title: measured ? null : (String(s.detail || "") || "Non mesuré par le moteur") }, measured ? fmtNumFR(s.valeur) + u : "—");
        const thr = h("span", { class: "sy-thr" }, "/ seuil " + (s.seuil != null ? fmtNumFR(s.seuil) + u : "—"));
        const st = !measured ? ds.pill("Non mesuré", "neutral") : s.depasse ? ds.pill(Number(s.valeur) === Number(s.seuil) ? "Seuil atteint" : "Au-dessus", "warn") : ds.pill("Sous le seuil", "ok");
        return ds.row({ title: String(s.label || ""), meta: [String(s.source || ""), measured ? String(s.detail || "") : ""].filter(Boolean).join(" · ") || null,
          side: h("span", { class: "sy-measure" }, h("span", { class: "sy-vt" }, val, thr), st) });
      };
      const settings = ds.row({ lead: "gear", title: "Compagnon de charge",
        meta: "Au plus " + (pl.max_jour ?? 2) + " propositions par jour dans le Pulse, sous le plafond d'interruptions (" + String(pl.interruptions_aujourdhui ?? 0) + "/" + String(pl.plafond_interruptions ?? 6) + " aujourd'hui). Aucun diagnostic de santé ; rien n'est déplacé ni envoyé tout seul.",
        side: h("label", { class: "sy-switch" }, h("span", { class: "ds-meta" }, on ? "Activé" : "Coupé"), swb) });
      settings.classList.add("sy-wrap");
      chargeBox.replaceChildren(
        ds.card({ flush: true, class: "sy-charge" }, list(head),
          sig.length ? h("div", { class: "sy-sig" }, list(...sig.map(sigRow))) : ds.empty({ text: "Aucun signal lu pour le moment.", compact: true })),
        sugg.length ? ds.card({ flush: true, class: "sy-sugg" }, h("div", { class: "sy-cap" }, "Propositions du jour"), list(...sugg.map((x) => { const r = ds.row({ lead: "sparkle", title: String(x.titre || ""), meta: (Array.isArray(x.lignes) ? x.lignes : []).join(" ") || null }); r.classList.add("sy-wrap"); return r; }))) : null,
        ds.card({ flush: true, class: "sy-set" }, list(settings)));
    } catch (e) { if (!dead) chargeBox.replaceChildren(errBox("Charge du jour injoignable.", loadCharge)); }
  }
  let netOff = null, netT = null;
  function listenNet() {   // flux partagé /api/events (core.js) : événement serveur « net »
    try {
      netOff = ctx.bus && typeof ctx.bus.on === "function" ? ctx.bus.on("net", (d) => {
        if (d && d.message) ctx.toast(String(d.message));
        clearTimeout(netT); netT = setTimeout(() => { if (!dead) loadNet(); }, 600);
      }) : null;
    } catch (e) { netOff = null; }
  }
  let started = false;
  function start() {   // E3 : rien ne se charge avant l'ouverture du coffre
    if (started) return; started = true;
    loadSys(); loadDroits(); loadGov(); loadAudit(); loadActions(); loadBB();
  }
  function refreshAll() {
    loadNet(); loadCharge();
    if (started) { loadSys(); loadDroits(true); loadGov(); loadActions(); loadBB(); }
  }
  setTimeout(() => { if (!dead) { loadNet(); loadCharge(); listenNet(); } }, 0);
  return () => { dead = true; clearTimeout(netT); try { if (typeof netOff === "function") netOff(); } catch (e) {} vaultLock(); };   // E3 : verrouillage auto au changement d'écran
}
