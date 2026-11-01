// fx.js — Micro-animations d'interface pour Nova 2.
// Module ES autonome : exporte uniquement initFx() et ne fait rien à l'import.
// Ajoute .fx-in aux cartes/messages insérés, anime le reflet spéculaire (--fx-x / --fx-y)
// sur #rail et .composer au fil de l'eau (rAF stoppé à l'arrêt), et gère le retour de pression.

let active = false;

export function initFx() {
  if (active) return;
  try {
    if (localStorage.getItem("nova2_fx") === "off") return;
  } catch (e) {}

  const isReduced = () => {
    try {
      return (
        window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
        document.documentElement.dataset.reduceMotion === "1"
      );
    } catch (e) {
      return false;
    }
  };

  active = true;
  const TARGET_SEL = ".card, .home-card, .msg, .fc";

  // 1. MutationObserver : ajoute .fx-in aux nouveaux éléments (.card, .home-card, .msg, .fc)
  const tagElement = (el) => {
    if (isReduced()) return;
    if (!el.classList.contains("fx-in")) {
      el.classList.add("fx-in");
    }
  };

  const mo = new MutationObserver((mutations) => {
    if (isReduced()) return;
    for (let i = 0; i < mutations.length; i++) {
      const added = mutations[i].addedNodes;
      for (let j = 0; j < added.length; j++) {
        const node = added[j];
        if (node.nodeType !== 1) continue;
        if (node.matches && node.matches(TARGET_SEL)) {
          tagElement(node);
        }
        if (node.querySelectorAll) {
          const children = node.querySelectorAll(TARGET_SEL);
          for (let k = 0; k < children.length; k++) {
            tagElement(children[k]);
          }
        }
      }
    }
  });

  if (document.body) {
    mo.observe(document.body, { childList: true, subtree: true });
  }

  // 2. Reflet spéculaire qui suit le pointeur sur #rail et .composer (max 1 fois par rAF, arrêt automatique)
  let px = -1000;
  let py = -1000;
  let rafId = 0;

  /* 29/10 (fluidité) : --fx-x/--fx-y sont des propriétés HÉRITÉES — les écrire recalcule le style de tout
     le sous-arbre (le rail entier : avatar, boutons…). Le reflet est un dégradé de ~220 px : loin de
     l'élément, il est invisible. On n'écrit donc que si le pointeur est à moins de 260 px de l'élément,
     plus UNE écriture « hors champ » en le quittant, et jamais deux fois la même valeur. */
  const FAR = 260;
  const setFx = (el, r) => {
    const out = px < r.left - FAR || px > r.right + FAR || py < r.top - FAR || py > r.bottom + FAR;
    const x = out ? "-9999px" : Math.round(px - r.left) + "px";
    const y = out ? "-9999px" : Math.round(py - r.top) + "px";
    if (el.__fxX === x && el.__fxY === y) return;
    el.__fxX = x; el.__fxY = y;
    el.style.setProperty("--fx-x", x);
    el.style.setProperty("--fx-y", y);
  };
  const updateReflection = () => {
    rafId = 0;
    if (isReduced() || document.hidden) return;
    const rail = document.getElementById("rail");
    if (rail) {
      const r = rail.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) setFx(rail, r);
    }
    const composers = document.querySelectorAll(".composer");
    for (let i = 0; i < composers.length; i++) {
      const c = composers[i];
      const r = c.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) setFx(c, r);
    }
  };

  window.addEventListener(
    "pointermove",
    (e) => {
      if (isReduced()) return;
      px = e.clientX;
      py = e.clientY;
      if (!rafId) {
        rafId = requestAnimationFrame(updateReflection);
      }
    },
    { passive: true }
  );

  // 3. Retour visuel de pression des boutons (passif, sans bloquer aucun événement)
  let pressedBtn = null;
  const clearPress = () => {
    if (pressedBtn) {
      pressedBtn.classList.remove("fx-press");
      pressedBtn = null;
    }
  };

  window.addEventListener(
    "pointerdown",
    (e) => {
      if (isReduced() || !e.target || !e.target.closest) return;
      const btn = e.target.closest(".btn, .rail-btn, .pb-btn");
      if (btn) {
        clearPress();
        pressedBtn = btn;
        btn.classList.add("fx-press");
      }
    },
    { passive: true }
  );

  window.addEventListener("pointerup", clearPress, { passive: true });
  window.addEventListener("pointercancel", clearPress, { passive: true });
}
