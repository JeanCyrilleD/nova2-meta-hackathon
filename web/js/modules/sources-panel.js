/* V5-V (25/10/2026) — « Sources de Nova » : les dossiers que Nova lit et indexe dans son savoir (outil know).
   Moteur : Sources/NovaCore/Feat_Sources.swift
     GET  /api/sources                → { sources:[{id,label,path,kind,note,on,status,error,files,last_pass,custom}], pass_running, scanning, last_pass, interval_min, caps, fda_hint }
     POST /api/sources/toggle {id,on} · POST /api/sources/add {path} · POST /api/sources/remove {id} · POST /api/sources/scan {id?}
   Tout est en LECTURE SEULE : Nova n'écrit jamais dans une source. Les secrets (mots de passe, codes, clés, cartes)
   ne sont jamais indexés.
   « Ajouter un dossier » : même chemin natif que attach.js — input webkitdirectory, le sélecteur macOS renvoie les
   chemins réels par l'événement window « nova:picked » ([{p, d}]) ; repli : chemin saisi à la main.
   Montage (Réglages) : import { mountSourcesPanel } from "./sources-panel.js"; mountSourcesPanel(conteneur, ctx).
   Styles : classes existantes de web/css/v3-outils.css (og-*) + .switch / .btn de nova2.css — aucune feuille ajoutée. */
import { api as coreApi, h as coreH } from "../core.js";
import { ic as coreIc } from "../icons.js";

const KIND_LABEL = { ia: "Autre IA", sci: "SCI", mac: "Mac", projets: "Projets", perso: "Ajouté" };
const KIND_ICON = { ia: "robot", sci: "cloud", mac: "file", projets: "layers", perso: "plus" };

function fmtWhen(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  try { return d.toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }); } catch (e) { return iso; }
}

export function mountSourcesPanel(container, ctx = {}) {
  const api = ctx.api || coreApi;
  const h = ctx.h || coreH;
  const ic = ctx.ic || coreIc;
  const toast = (msg, kind) => { try { if (ctx.toast) ctx.toast(msg, kind); } catch (e) {} };
  let dead = false;
  let pollT = 0;
  let data = null;
  let pickArmed = 0;

  const root = h("section", { class: "og-sec sources-panel", "aria-label": "Sources de Nova" });
  const bluf = h("p", { class: "og-desc" });
  const list = h("div", { class: "og-list", role: "list" });
  const foot = h("div", { class: "og-foot" });
  const statusLine = h("div", { class: "og-count", "aria-live": "polite" });

  /* Sélecteur de dossier natif (WKWebView → NSOpenPanel « dossiers seulement », main.swift) */
  const dirInput = h("input", { type: "file", style: "display:none", "aria-hidden": "true", tabindex: "-1" });
  dirInput.setAttribute("webkitdirectory", ""); dirInput.setAttribute("directory", "");
  dirInput.addEventListener("change", () => { dirInput.value = ""; });   // le chemin réel arrive par « nova:picked »
  const onPicked = async (e) => {
    if (!pickArmed || Date.now() - pickArmed > 10 * 60 * 1000) return;
    pickArmed = 0;
    const picked = ((e && e.detail) || []).filter((p) => p && p.p && p.d);
    if (!picked.length) { toast("Choisis un dossier (pas un fichier)."); return; }
    for (const p of picked) await addPath(p.p);
  };
  window.addEventListener("nova:picked", onPicked);

  const pathInput = h("input", { type: "text", class: "fld", placeholder: "~/Documents/SCI — ou choisis un dossier", "aria-label": "Chemin d'un dossier à ajouter", style: "flex:1 1 220px;min-width:0" });
  const addBtn = h("button", { class: "btn sm acc", title: "Choisir un dossier de ce Mac : Nova le lira sur place, en lecture seule", onclick: () => { pickArmed = Date.now(); dirInput.click(); } },
    h("span", { html: ic("plus", 14) }), " Ajouter un dossier");
  const addTyped = h("button", { class: "btn sm", title: "Ajouter le chemin saisi", onclick: () => { const v = pathInput.value.trim(); if (v) addPath(v); } }, "Ajouter ce chemin");
  pathInput.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); const v = pathInput.value.trim(); if (v) addPath(v); } });
  const scanBtn = h("button", { class: "btn sm", title: "Relire les sources maintenant (incrémental : seuls les fichiers modifiés sont relus)", onclick: () => scan("") },
    h("span", { html: ic("refresh", 14) }), " Analyser maintenant");

  root.append(
    h("div", { class: "og-sec-h" },
      h("span", { class: "og-ico", html: ic("know", 18) }),
      h("div", { class: "grow" },
        h("h2", {}, "Sources de Nova"),
        bluf)),
    statusLine,
    list,
    h("div", { class: "sources-bar", style: "display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:12px" }, addBtn, pathInput, addTyped, scanBtn),
    foot,
    dirInput);
  container.append(root);

  async function addPath(p) {
    try {
      const r = await api.post("/api/sources/add", { path: p });
      pathInput.value = "";
      toast(r && r.error ? "Dossier ajouté, mais : " + r.error : (r && r.deja ? "Source déjà connue — réactivée." : "Dossier ajouté — analyse en cours (lecture seule)."));
      await load();
    } catch (e) {
      toast(String((e && e.body && e.body.error) || e.message || e), "error");
    }
  }

  async function toggle(s, on, sw) {
    sw.disabled = true;
    try {
      const r = await api.post("/api/sources/toggle", { id: s.id, on });
      data = r; render();
      toast(on ? "« " + s.label + " » activée — analyse en cours." : "« " + s.label + " » désactivée — retirée du savoir à la fin de la passe.");
      schedulePoll();
    } catch (e) {
      sw.setAttribute("aria-checked", String(!on));
      toast(String((e && e.body && e.body.error) || e.message || e), "error");
    } finally { sw.disabled = false; }
  }

  async function remove(s) {
    try { await api.post("/api/sources/remove", { id: s.id }); toast("« " + s.label + " » retirée des sources."); await load(); }
    catch (e) { toast(String((e && e.body && e.body.error) || e.message || e), "error"); }
  }

  async function scan(id) {
    try {
      const r = await api.post("/api/sources/scan", id ? { id } : {});
      toast(r && r.started ? "Analyse lancée (incrémentale, en arrière-plan)." : "Une analyse tourne déjà — elle sera relancée à la fin.");
      await load();
    } catch (e) { toast(String((e && e.body && e.body.error) || e.message || e), "error"); }
  }

  function stateClass(st) {
    if (st === "actif") return "og-state og-state--ok";
    if (st === "accès refusé" || st === "illisible" || st === "exclu") return "og-state og-state--err";
    return "og-state";
  }

  function row(s) {
    const on = !!s.on;
    const usable = s.exists && s.readable && s.status !== "exclu";
    const sw = h("button", { class: "switch", role: "switch", "aria-checked": on ? "true" : "false", "aria-label": "Indexer " + s.label,
      disabled: !usable, title: usable ? (on ? "Désactiver cette source" : "Activer cette source") : "Dossier absent ou illisible",
      onclick: () => { const v = sw.getAttribute("aria-checked") !== "true"; sw.setAttribute("aria-checked", String(v)); toggle(s, v, sw); } });
    const meta = [];
    meta.push(KIND_LABEL[s.kind] || s.kind);
    if (s.status === "actif" || s.files) meta.push((s.files || 0).toLocaleString("fr-FR") + " fichier" + ((s.files || 0) > 1 ? "s" : "") + " indexé" + ((s.files || 0) > 1 ? "s" : ""));
    if (s.last_pass) meta.push("passe " + fmtWhen(s.last_pass));
    if (s.filter === "conversations") meta.push("conversations seulement");
    const showErr = s.error && s.status !== "absent" && s.status !== "actif" && s.status !== "désactivé";
    return h("div", { class: "og-row" + (on ? "" : " is-off"), role: "listitem" },
      h("span", { class: "og-file", html: ic(KIND_ICON[s.kind] || "file", 15) }),
      h("div", { class: "grow" },
        h("div", { class: "og-tt" }, h("span", { class: "og-fname" }, s.label), h("span", { class: stateClass(s.status) }, s.status)),
        h("div", { class: "og-path", title: s.path }, s.path),
        h("div", { class: "og-count", style: "padding:2px 0 0" }, meta.join(" · ")),
        s.note ? h("div", { class: "og-desc", style: "margin-top:2px;font-size:12px" }, s.note) : null,
        showErr ? h("div", { class: "og-err" }, s.error) : null),
      h("div", { class: "og-acts" },
        s.custom ? h("button", { class: "btn sm ghost", title: "Retirer ce dossier des sources", onclick: () => remove(s) }, "Retirer") : null,
        sw));
  }

  function render() {
    if (dead || !data) return;
    const srcs = Array.isArray(data.sources) ? data.sources : [];
    const act = srcs.filter((s) => s.on);
    const files = act.reduce((n, s) => n + (s.files || 0), 0);
    const denied = srcs.filter((s) => s.status === "accès refusé");
    bluf.textContent = "Nova lit ces dossiers en lecture seule et les indexe dans son savoir — autres IA du Mac, travail SCI synchronisé, documents. "
      + "Rien n'y est jamais écrit ; mots de passe, codes, clés et numéros de carte ne sont jamais indexés. Passe incrémentale toutes les " + (data.interval_min || 30) + " min.";
    const running = data.pass_running || data.scanning;
    statusLine.textContent = act.length + " source" + (act.length > 1 ? "s" : "") + " active" + (act.length > 1 ? "s" : "") + " · "
      + files.toLocaleString("fr-FR") + " fichiers indexés"
      + (running ? " · analyse en cours…" : (data.last_pass && data.last_pass.ts ? " · dernière passe " + fmtWhen(data.last_pass.ts) : " · aucune passe encore"));
    scanBtn.disabled = !!running;
    list.replaceChildren(...(srcs.length ? srcs.map(row) : [h("div", { class: "og-empty" }, h("b", {}, "Aucune source détectée."), "Ajoute un dossier ci-dessous.")]));
    foot.replaceChildren(...(denied.length ? [h("div", { class: "og-note" },
      "macOS refuse l'accès à " + denied.length + " dossier" + (denied.length > 1 ? "s" : "") + " : Réglages Système › Confidentialité et sécurité › Accès complet au disque › active Nova, puis « Analyser maintenant ».")] : []));
    if (running) schedulePoll();
  }

  function schedulePoll() {
    if (dead || pollT) return;
    pollT = setTimeout(async () => { pollT = 0; await load(); }, 5000);
  }

  async function load() {
    if (dead) return;
    try { data = await api.get("/api/sources"); render(); }
    catch (e) {
      list.replaceChildren(h("div", { class: "og-err" }, "Sources indisponibles : " + String(e.message || e)),
        h("button", { class: "btn sm", style: "margin-top:8px", onclick: () => load() }, "Réessayer"));
    }
  }

  load();
  return {
    el: root,
    refresh: load,
    destroy() { dead = true; if (pollT) clearTimeout(pollT); window.removeEventListener("nova:picked", onPicked); try { root.remove(); } catch (e) {} },
  };
}
