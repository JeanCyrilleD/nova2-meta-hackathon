#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Nova 2 — empaquetage de Nova.app (v2.0.0), À LANCER SUR LE MAC.
#
#   bash tools/package_app.sh           → build release + bundle + signature
#   bash tools/package_app.sh --debug   → build debug (plus rapide, même bundle)
#
# Produit : build/Nova.app
#   Contents/MacOS/NovaMac          le binaire (produit SwiftPM « NovaMac »)
#   Contents/Resources/web/         la couche web (main.swift la cherche là :
#                                   Bundle.main.resourcePath + "/web")
#   Contents/Resources/AppIcon.icns dérivé de tools/AppIcon-1024.png (sips+iconutil)
#   Contents/Info.plist             copié de tools/Info.plist (version 2.0.0)
# Signature : identité stable « Nova Dev » si elle existe (créée une fois par
# tools/setup_signing.sh — voir tools/SIGNING.md), sinon repli ad hoc (codesign -s -) ;
# NOVA_SIGN_IDENTITY, s'il est fourni, reste prioritaire. L'identité stable conserve
# les autorisations macOS (TCC) entre builds ; l'ad hoc les révoque à chaque build.
# Aucune élévation, aucun réseau. Idempotent : le bundle est reconstruit à neuf.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="2.0.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
[ "${1:-}" = "--debug" ] && CONFIG="debug"

# ── F7 (brief Sentry) — dSYM : archivage par UUID AVANT écrasement ─────────
# Le dSYM change à chaque build et son chemin de sortie est fixe : sans cette
# archive, le build qui vient écrase le dSYM du build précédent (perte du
# dSYM de NOVA2-1, 23/10). Archive : dsym-archive/<UUID>_<date>/ — aucun dSYM
# ne doit exister en un seul exemplaire. Échec de copie = arrêt net : mieux
# vaut un build interrompu qu'un dSYM perdu.
DSYM_FIXED=".build/out/Products/Release/NovaMac.dSYM"
dsym_uuid_of() { dwarfdump --uuid "$1" 2>/dev/null | awk 'NR==1 {print tolower($2)}'; }
archive_dsym() {
  local src="$1" dwarf uuid dest
  [ -d "$src" ] || return 0
  dwarf="$src/Contents/Resources/DWARF/NovaMac"
  uuid="$(dsym_uuid_of "$dwarf" || true)"
  if [ -z "$uuid" ]; then
    uuid="uuid-illisible-$(date +%F_%H%M%S)"
    echo "⚠️  F7 : UUID illisible pour $src — archivage sous nom de secours."
  fi
  dest="dsym-archive/${uuid}_$(date +%F)"
  if [ -d "$dest" ]; then
    echo "F7 : dSYM $uuid déjà archivé ($dest)."
    return 0
  fi
  mkdir -p "dsym-archive"
  if cp -R "$src" "$dest"; then
    echo "F7 : dSYM archivé → $dest"
  else
    echo "❌ F7 : échec de l'archivage de $src — build arrêté (anti-perte)."
    exit 1
  fi
}
archive_dsym "$DSYM_FIXED"

APP="build/Nova.app"
BIN=".build/$CONFIG/NovaMac"

echo "── 1/5 Compilation Swift ($CONFIG)…"
swift build -c "$CONFIG"
[ -x "$BIN" ] || { echo "❌ Binaire introuvable : $BIN"; exit 1; }

echo "── 2/5 Assemblage du bundle ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NovaMac"
cp tools/Info.plist "$APP/Contents/Info.plist"
cp -R web "$APP/Contents/Resources/web"
[ -d Config ] && cp -R Config "$APP/Contents/Resources/Config"   # PHASE2 : registre des cerveaux, conditions des fournisseurs, jours fériés (lus seulement si routage_v2)
# 25/10 : sources de travail exclues du paquet (PNG 1024 de [tiers] ~13 Mo, scripts de construction, sauvegardes) —
# l'app n'utilise que les WebP produits dans web/avatars/illus/<espèce>/.
rm -rf "$APP/Contents/Resources/web/avatars/NOVA_2_AVATARS_HD" "$APP/Contents/Resources/web/avatars/illus/_build"
find "$APP/Contents/Resources/web" \( -name "*.bak" -o -name "*.bak-*" -o -name ".DS_Store" \) -delete 2>/dev/null || true
find "$APP" -name ".DS_Store" -delete

echo "── 3/5 Icône (sips + iconutil)…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="tools/AppIcon-1024.png"
# Le PNG n'est pas versionné octet par octet : il se régénère depuis le dessin
# (tools/AppIcon.svg) via make_icon.py — bibliothèque standard seule, aucun PIL requis.
[ -f "$SRC" ] || python3 tools/make_icon.py
[ -f "$SRC" ] || { echo "❌ Icône source absente et régénération impossible : $SRC"; exit 1; }
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" \
            "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
  px="${spec%%:*}"; name="${spec##*:}"
  sips -z "$px" "$px" "$SRC" --out "$ICONSET/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "── 4/5 Version et signature…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
# DIAG-CALENDRIER : une signature AD HOC change de cdhash à chaque build, donc macOS
# « oublie » les autorisations TCC (Calendriers, Automatisation, Accès complet au disque)
# à chaque recompilation. Signature STABLE, par ordre de priorité :
#   1. NOVA_SIGN_IDENTITY, s'il est fourni (choix explicite, inchangé) ;
#   2. l'identité auto-signée « Nova Dev », créée une seule fois par
#      tools/setup_signing.sh, si elle est valide pour la signature de code ;
#   3. repli ad hoc, comportement historique inchangé.
if [ -n "${NOVA_SIGN_IDENTITY:-}" ]; then
  SIGN_ID="$NOVA_SIGN_IDENTITY"; SIGN_LABEL="$SIGN_ID (explicite)"
elif APPLE_DEV="$(security find-identity -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)" && [ -n "$APPLE_DEV" ] \
     && T_SIG="$(mktemp -d)" && cp /usr/bin/true "$T_SIG/t" && codesign --force --sign "$APPLE_DEV" "$T_SIG/t" 2>"$T_SIG/err"; then
  rm -rf "$T_SIG"
  # 29/10 (Ahadi : Touch ID puis mot de passe du trousseau à CHAQUE redémarrage du coffre Finance) : « Nova Dev » est
  # auto-signé, donc SANS Team ID — macOS rattache alors « Toujours autoriser » au cdhash, qui change à chaque build.
  # Un certificat « Apple Development » (Apple ID gratuit, Xcode › Réglages › Comptes) porte un Team ID stable :
  # l'autorisation du trousseau survit aux recompilations. Prioritaire dès qu'il existe.
  SIGN_ID="$APPLE_DEV"; SIGN_LABEL="Apple Development (Team ID stable — trousseau sans invite répétée)"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"Nova Dev"'; then
  SIGN_ID="Nova Dev"; SIGN_LABEL="Nova Dev (stable)"
else
  SIGN_ID="-"; SIGN_LABEL="ad hoc (repli)"
fi
echo "Signature : $SIGN_LABEL"
[ -n "${T_SIG:-}" ] && [ -f "$T_SIG/err" ] && echo "Apple Development refusé à l'essai : $(head -c 200 "$T_SIG/err" | tr '\n' ' ')" && rm -rf "$T_SIG"
# 29/10 : diagnostic — identités de signature vues par le build (noms seulement), valides et toutes
echo "Identités valides : $(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | sed 's/ (.*//' | tr '\n' ';')"
echo "Apple Development (état) : $(security find-identity -p codesigning 2>/dev/null | grep 'Apple Development' | sed -E 's/^ *[0-9]+\) [0-9A-F]+ "[^"]*"//' | tr '\n' ';')"
# 29/10 : signature Apple Development → droit get-task-allow (profilage Instruments / sample de Nova par son propriétaire)
if [ "${SIGN_LABEL#Apple Development}" != "$SIGN_LABEL" ]; then
  ENT="$(mktemp)"; printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n' > "$ENT"
  codesign --force --deep --sign "$SIGN_ID" --entitlements "$ENT" "$APP"; rm -f "$ENT"
else
  codesign --force --deep --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict --verbose=1 "$APP"

echo "── 5/5 Contrôle final…"
[ -f "$APP/Contents/Resources/web/index.html" ] || { echo "❌ web/index.html absent du bundle"; exit 1; }
PLIST_V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$SIGN_ID" = "-" ]; then
  echo "⚠️  Signature ad hoc : à la prochaine recompilation, macOS révoquera les accès"
  echo "    Calendriers / Automatisation / Accès complet au disque de Nova."
  echo "    Il faudra les ré-accorder (Réglages Système › Confidentialité et sécurité),"
  echo "    ou créer l'identité stable, une seule fois : bash tools/setup_signing.sh"
  echo "    (ou forcer une identité : NOVA_SIGN_IDENTITY — voir tools/SIGNING.md)."
fi
echo "✅ Nova.app prêt : $ROOT/$APP"
echo "   version $PLIST_V · bundle $BID · signature $SIGN_LABEL vérifiée"
echo
echo "Lancement :  open build/Nova.app"
echo "Si macOS bloque la première ouverture (app non notarisée) : clic droit sur"
echo "Nova.app → Ouvrir. Au premier usage, macOS demandera les accès micro,"
echo "reconnaissance vocale, automatisation et calendrier : les accepter."

# ── F7 (brief Sentry) — dSYM du build : archivage + upload + check ──────────
# Le dSYM retenu est celui dont l'UUID égale celui du binaire empaqueté.
# Auth : sentry-cli lit ~/.sentryclirc (org nova-ouagadougou, projet nova2) —
# aucun token dans ce script, jamais. Gate G1 : sans dSYM uploadé, le build
# n'est pas livrable.
BIN_UUID="$(dsym_uuid_of "$APP/Contents/MacOS/NovaMac" || true)"
DSYM_UUID="$(dsym_uuid_of "$DSYM_FIXED/Contents/Resources/DWARF/NovaMac" || true)"
if [ -n "$BIN_UUID" ] && [ "$BIN_UUID" = "$DSYM_UUID" ]; then
  archive_dsym "$DSYM_FIXED"
  if command -v sentry-cli >/dev/null 2>&1; then
    echo "── F7 Upload du dSYM vers Sentry…"
    if sentry-cli debug-files upload "$DSYM_FIXED" && sentry-cli debug-files check "$DSYM_FIXED/Contents/Resources/DWARF/NovaMac"; then
      echo "✅ F7 : dSYM $DSYM_UUID uploadé et vérifié."
    else
      echo "❌ F7 : échec de l'upload ou du check du dSYM — build non livrable (gate G1)."
      exit 1
    fi
  else
    echo "⚠️  F7 : sentry-cli absent — dSYM archivé mais NON uploadé."
    echo "    Installer une fois :  brew install getsentry/tools/sentry-cli"
    echo "    Puis lancer :         sentry-cli debug-files upload $DSYM_FIXED"
    echo "    Gate G1 : sans dSYM uploadé, ce build n'est pas livrable."
  fi
else
  echo "⚠️  F7 : aucun dSYM d'UUID correspondant au binaire empaqueté à $DSYM_FIXED"
  echo "    (binaire : ${BIN_UUID:-illisible} · dSYM fixe : ${DSYM_UUID:-absent/illisible})."
  echo "    Le dSYM précédent reste protégé par l'archive d'avant-build."
  echo "    Gate G1 : dSYM de CE build à archiver et uploader à la main."
fi
