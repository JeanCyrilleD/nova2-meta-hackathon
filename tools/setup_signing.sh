#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Nova 2 — création UNIQUE de l'identité de signature stable « Nova Dev ».
#
#   bash tools/setup_signing.sh        (à lancer UNE fois sur le Mac, Terminal)
#
# Pourquoi : une signature ad hoc change à chaque compilation, donc macOS
# révoque à chaque build les autorisations TCC de Nova (Calendriers,
# Automatisation, Accès complet au disque…). Une identité auto-signée stable
# fait survivre ces autorisations d'un build à l'autre.
#
# Ce que fait le script, et rien d'autre :
#   1. Vérifie si une identité « Nova Dev » valide pour la signature de code
#      existe déjà dans le trousseau de session → si oui, il s'arrête là.
#      Il n'écrase JAMAIS une identité existante.
#   2. Sinon, crée un certificat auto-signé « Nova Dev » (OpenSSL), l'importe
#      dans le trousseau de session, et le déclare de confiance UNIQUEMENT
#      pour la signature de code (security add-trusted-cert -p codeSign).
#   3. Autorise codesign à utiliser la clé sans invite répétée
#      (security set-key-partition-list — peut demander le mot de passe du
#      trousseau, saisi par vous, jamais lu ni stocké par ce script).
#   4. Vérifie le résultat : identité listée ET signature d'essai réussie.
#
# Aucun mot de passe en clair dans ce script : la phrase de passe du fichier
# d'import (.p12) est aléatoire, éphémère (variable mémoire), et les fichiers
# temporaires sont détruits à la sortie. Aucune élévation (pas de sudo),
# aucun réseau.
#
# Révocation (voir aussi tools/SIGNING.md) :
#   security find-certificate -c "Nova Dev" -p ~/Library/Keychains/login.keychain-db > /tmp/nova-dev.pem
#   security remove-trusted-cert /tmp/nova-dev.pem
#   security delete-certificate -c "Nova Dev" ~/Library/Keychains/login.keychain-db
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

IDENTITY="Nova Dev"
KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//')"

echo "Nova 2 — identité de signature stable « $IDENTITY »"
echo "Trousseau de session : $KEYCHAIN"
echo

count_valid() {
  security find-identity -v -p codesigning 2>/dev/null | grep -c "\"$IDENTITY\"" || true
}

# ── Étape 1/4 : l'identité existe-t-elle déjà et est-elle valide ? ──────────
echo "── 1/4 Vérification de l'existant…"
if [ "$(count_valid)" -ge 1 ]; then
  echo "✅ Identité « $IDENTITY » déjà présente et valide pour la signature de code."
  echo "   Rien à faire : tools/package_app.sh l'utilisera automatiquement."
  exit 0
fi

TMPDIR_WORK="$(mktemp -d)"
chmod 700 "$TMPDIR_WORK"
cleanup() {
  rm -rf "$TMPDIR_WORK"
  unset P12_PASS 2>/dev/null || true
}
trap cleanup EXIT
CERT_PEM="$TMPDIR_WORK/nova-dev-cert.pem"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  # Un certificat « Nova Dev » existe mais l'identité n'est pas valide :
  # on tente UNIQUEMENT la réparation de confiance — jamais d'écrasement.
  echo "⚠️  Un certificat « $IDENTITY » existe déjà, mais il n'est pas (encore)"
  echo "    reconnu comme identité de signature valide. Tentative de réparation"
  echo "    de la confiance (étape 3) sans toucher au certificat ni à sa clé…"
  security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$CERT_PEM"
  REPAIR_ONLY=1
else
  REPAIR_ONLY=0
  # ── Étape 2/4 : création du certificat auto-signé ─────────────────────────
  echo "── 2/4 Création du certificat auto-signé « $IDENTITY »…"
  cat > "$TMPDIR_WORK/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3_ext
prompt             = no
[ dn ]
CN = Nova Dev
O  = Nova 2 (local)
[ v3_ext ]
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EOF
  # Phrase de passe d'import : aléatoire, mémoire seule, jamais affichée.
  P12_PASS="$(openssl rand -hex 24)"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR_WORK/nova-dev-key.pem" \
    -out "$CERT_PEM" \
    -days 3650 -config "$TMPDIR_WORK/openssl.cnf"
  LEGACY=()
  if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY=(-legacy); fi
  openssl pkcs12 -export "${LEGACY[@]}" \
    -inkey "$TMPDIR_WORK/nova-dev-key.pem" -in "$CERT_PEM" \
    -name "$IDENTITY" -out "$TMPDIR_WORK/nova-dev.p12" \
    -passout "pass:$P12_PASS"
  echo "   Import dans le trousseau de session (accès réservé à codesign)…"
  security import "$TMPDIR_WORK/nova-dev.p12" -k "$KEYCHAIN" \
    -P "$P12_PASS" -T /usr/bin/codesign
  rm -f "$TMPDIR_WORK/nova-dev-key.pem" "$TMPDIR_WORK/nova-dev.p12"
  unset P12_PASS
fi

# ── Étape 3/4 : confiance limitée à la signature de code ────────────────────
echo "── 3/4 Confiance limitée à la signature de code…"
echo "   (macOS peut demander le mot de passe de session — saisi par vous,"
echo "    le script ne le voit pas et ne le conserve pas.)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM"
if [ "$REPAIR_ONLY" -eq 0 ]; then
  echo "   Autorisation de codesign sur la clé (le mot de passe du trousseau"
  echo "   peut être redemandé, une dernière fois)…"
  if ! security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -l "$IDENTITY" "$KEYCHAIN"; then
    echo "⚠️  Étape d'autorisation de la clé non confirmée. Conséquence possible :"
    echo "    au premier build, une boîte « codesign veut utiliser la clé » —"
    echo "    choisir « Toujours autoriser »."
  fi
fi

# ── Étape 4/4 : vérification (identité listée + signature d'essai) ────────
echo "── 4/4 Vérification…"
if [ "$(count_valid)" -lt 1 ]; then
  echo "❌ L'identité « $IDENTITY » n'apparaît pas comme valide pour la signature."
  if [ "$REPAIR_ONLY" -eq 1 ]; then
    echo "   Le certificat existant n'a probablement pas de clé privée associée :"
    echo "   ce script ne supprime rien tout seul. Pour repartir de zéro :"
    echo "   supprimer « $IDENTITY » dans Accès aux trousseaux, puis relancer ce script."
  fi
  exit 1
fi
security find-identity -v -p codesigning | grep "\"$IDENTITY\"" || true
SMOKE_BIN="$TMPDIR_WORK/smoke-echo"
cp /bin/echo "$SMOKE_BIN"
codesign --force --sign "$IDENTITY" "$SMOKE_BIN"
codesign --verify --verbose=1 "$SMOKE_BIN"
echo
echo "✅ Identité « $IDENTITY » prête et vérifiée (signature d'essai réussie)."
echo "   À partir de maintenant :  bash tools/package_app.sh"
echo "   signera Nova avec « $IDENTITY » et affichera « Signature : Nova Dev (stable) »."
echo "   Les autorisations macOS accordées à Nova survivront aux prochains builds —"
echo "   elles seront demandées une dernière fois au premier build signé ainsi."
echo
echo "Révocation, si un jour nécessaire : voir tools/SIGNING.md, section « Révoquer »."
