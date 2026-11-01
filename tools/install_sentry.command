#!/bin/zsh
# 26/10 : installe sentry-cli (rapports de plantage de Nova2). Aucun jeton ici :
# la connexion se fait par « sentry-cli login », que Ahadi tape lui-même.
set -e
if ! command -v brew >/dev/null 2>&1; then echo "Homebrew absent : https://brew.sh"; exit 1; fi
brew install getsentry/tools/sentry-cli
sentry-cli --version
echo ""
echo "Étape suivante (à faire toi-même, une fois) : sentry-cli login"
echo "Puis relance build_nova.command : le dSYM sera envoyé automatiquement."
