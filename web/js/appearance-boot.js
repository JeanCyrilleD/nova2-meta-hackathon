/* LOT WEB v3 / R4 §5.8 — AMORÇAGE D'APPARENCE UNIFIÉ.
   UN SEUL module, consommé par index.html ET panel.html, exécuté avant le
   premier paint : il pose data-material, data-mode, data-transparency,
   data-contrast et les trois variables --u-* depuis le même cache local
   (resynchronisé par /api/state au démarrage de la fenêtre principale).
   Aucune des deux fenêtres ne réinvente son amorçage. */
(function () {
  "use strict";
  /* Même table que core.js (THEMES + THEME_ALIASES) — tout id connu, ancien ou nouveau,
     donne une matière et un mode ; un id inconnu retombe sur l'identité par défaut
     (Obsidienne & Or Solaire — Nuit) : jamais d'écran blanc au démarrage. */
  var MAP = {
    /* 30/10 : identité « Promesse » (css/identite.css) — Harmattan (défaut), Fleuve, Sentinelle */
    "harmattan-jour": ["harmattan", "jour"], "harmattan-nuit": ["harmattan", "nuit"],
    "fleuve-jour": ["fleuve", "jour"], "fleuve-nuit": ["fleuve", "nuit"],
    "sentinelle-jour": ["sentinelle", "jour"], "sentinelle-nuit": ["sentinelle", "nuit"],
    "obsidienne-jour": ["obsidienne", "jour"], "obsidienne-nuit": ["obsidienne", "nuit"],
    "verre-jour": ["verre", "jour"], "verre-nuit": ["verre", "nuit"],
    "graphite-jour": ["graphite", "jour"], "graphite-nuit": ["graphite", "nuit"],
    "sable-jour": ["sable", "jour"], "sable-nuit": ["sable", "nuit"],   /* V5-L : Sable CAFU */
    "sable": ["sable", "jour"], "cafu-sand": ["sable", "jour"], "obsidian-bronze": ["sable", "nuit"],
    /* anciens ids */
    "saphir-jour": ["obsidienne", "jour"], "saphir-nuit": ["obsidienne", "nuit"], "cristal-jour": ["verre", "jour"], "cristal-nuit": ["verre", "nuit"],
    "bleue-jour": ["verre", "jour"], "bleue-nuit": ["verre", "nuit"], "celeste-jour": ["verre", "jour"], "celeste-nuit": ["verre", "nuit"],
    "ambre-jour": ["obsidienne", "jour"], "ambre-nuit": ["obsidienne", "nuit"], "ivoire-jour": ["obsidienne", "jour"], "ivoire": ["obsidienne", "jour"],
    "saphir": ["obsidienne", "nuit"], "cristal": ["verre", "jour"], "graphite": ["graphite", "nuit"], "verre": ["verre", "nuit"], "obsidienne": ["obsidienne", "nuit"], "celeste": ["verre", "nuit"], "ambre": ["obsidienne", "nuit"],
    "nuit-ambre": ["obsidienne", "nuit"], "nuit-bleue": ["verre", "nuit"],
    "observatoire": ["obsidienne", "nuit"], "liquidglass": ["verre", "nuit"], "encre": ["obsidienne", "nuit"],
    "sahel": ["obsidienne", "jour"], "cafu": ["obsidienne", "jour"]
  };
  var AUTO = { "ambre-auto": "obsidienne", "tahoe-auto": "obsidienne", "celeste-auto": "verre", "promesse": "harmattan", "harmattan": "harmattan", "fleuve": "fleuve", "sentinelle": "sentinelle" };
  var IDENTITE = { harmattan: 1, fleuve: 1, sentinelle: 1 };
  try {
    var d = document.documentElement;
    var id = localStorage.getItem("nova2_theme") || "harmattan-auto";   // 30/10 : défaut = identité Promesse, suit le Mac
    if (AUTO[id] && IDENTITE[AUTO[id]]) id = AUTO[id] + "-auto";
    /* 30/10 : migration unique (core.js identiteMigrate) — dès le premier paint, un ancien thème
       s'affiche en Harmattan dans le même mode ; core.js l'enregistre ensuite côté moteur. */
    if (localStorage.getItem("nova2_identite_v1") !== "1") {
      var pm = /-(jour|nuit|auto)$/.exec(id), base = id.replace(/-(jour|nuit|auto)$/, "");
      if (!IDENTITE[base]) id = "harmattan-" + (pm ? pm[1] : (MAP[id] ? MAP[id][1] : "auto"));
    }
    var mm = MAP[id] || MAP["harmattan-nuit"];
    if (/-auto$/.test(id)) {
      var dk = true; try { dk = matchMedia("(prefers-color-scheme: dark)").matches; } catch (e) {}
      var mat = AUTO[id] || id.replace(/-auto$/, "");
      if (mat !== "obsidienne" && mat !== "verre" && mat !== "graphite" && mat !== "sable" && !IDENTITE[mat]) mat = "harmattan";
      mm = [mat, dk ? "nuit" : "jour"];
    }
    d.dataset.material = mm[0];
    d.dataset.mode = mm[1];
    d.dataset.theme = mm[0] + "-" + mm[1];
    if (IDENTITE[mm[0]]) d.dataset.identite = "promesse"; else delete d.dataset.identite;
    /* 30/10 v3 : app native → page transparente (le Liquid Glass d'Apple est derrière) ; même table que core.js. */
    if (window.__NOVA_NATIVE_WEB) {
      d.dataset.native = "1";
      if (IDENTITE[mm[0]]) {
        var WT = { "harmattan-nuit": ["#1A1430", 0], "harmattan-jour": ["#F2EADC", 0], "fleuve-nuit": ["#0A1214", 0], "fleuve-jour": ["#ECF0EF", 0] };
        var wt = WT[mm[0] + "-" + mm[1]];
        var msg = { cmd: "win.appearance", mode: mm[1] === "jour" ? "light" : "dark", glass: !!wt };
        if (wt) { msg.tint = wt[0]; msg.alpha = wt[1]; }
        try { window.webkit.messageHandlers.nova.postMessage(msg); } catch (e) {}
      }
    }
    if (mm[0] !== "graphite" && mm[0] !== "sable" && !IDENTITE[mm[0]]) d.dataset.lg = "1"; else delete d.dataset.lg;
    if (localStorage.getItem("nova2_rail") === "mini") d.dataset.rail = "mini";
    var lm = localStorage.getItem("nova2_last_module"); if (lm) d.dataset.lastModule = lm;
    if (localStorage.getItem("nova2_reduce_motion") === "1") d.dataset.reduceMotion = "1";
    if (localStorage.getItem("nova2_soft_night") === "1") d.dataset.softNight = "1";
    var ts = localStorage.getItem("nova2_text_size"); if (ts === "s" || ts === "l" || ts === "xl") d.dataset.textSize = ts;   /* 29/10 : Réglages › Lecture */
    if (localStorage.getItem("nova2_answer_style") === "sobre") d.dataset.answerStyle = "sobre";   /* 29/10 : rendu CAFU par défaut */
    var rw = localStorage.getItem("nova2_read_width"); if (rw === "narrow" || rw === "wide") d.dataset.readWidth = rw;   /* 29/10 : nuit douce (plus chaude, moins de contraste) */
    /* Apparence : cache v3, sinon migration de l'ancien curseur couplé. */
    var a = null;
    try { a = JSON.parse(localStorage.getItem("nova2_appearance") || "null"); } catch (e) {}
    if (!a) {
      try {
        var g = JSON.parse(localStorage.getItem("nova2_glass") || "null");
        if (g) {
          var cl = function (v) { return Math.max(0, Math.min(1, v)); };
          var t = cl((Number(g.tint) - 0.3) / 2.1);
          a = { tint: Math.round(t * 100), density: Math.round(t * 100), blur: Math.round(cl((Number(g.blur) - 11) / 37) * 100) };
        }
      } catch (e) {}
    }
    if (!a) a = { tint: 50, density: 50, blur: 50 };
    d.style.setProperty("--u-tint", String(a.tint / 100));
    d.style.setProperty("--u-density", String(a.density / 100));
    d.style.setProperty("--u-blur", String(a.blur / 100));
    /* Transparence réduite : application (cache) OU système (matchMedia), en OU logique. */
    var appRT = localStorage.getItem("nova2_reduce_transparency") === "1";
    var sysRT = false;
    try { sysRT = !!(window.matchMedia && matchMedia("(prefers-reduced-transparency: reduce)").matches); } catch (e) {}
    if (appRT || sysRT) {
      d.dataset.transparency = "reduced";
      d.dataset.transparencySource = sysRT ? "systeme" : (localStorage.getItem("nova2_transparency_source") || "application");
      d.dataset.reduceTransparency = "1";
    }
    if (localStorage.getItem("nova2_contrast") === "1") d.dataset.contrast = "more";
  } catch (e) {}
})();
