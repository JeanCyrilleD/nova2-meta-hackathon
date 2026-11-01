#!/bin/bash
# Build + relance de Nova sans passer par l'assistant (double-clic depuis le Finder).
cd "$(dirname "$0")/.." || exit 1
LOG="$PWD/build_log_cmd.txt"
echo "Build Nova en cours… (journal : $LOG)"
if bash tools/package_app.sh > "$LOG" 2>&1 && grep -q "Nova.app prêt" "$LOG"; then
  echo "✅ Build OK — relance de Nova"
  osascript -e 'tell application id "com.ahadi.nova" to quit' 2>/dev/null
  sleep 4
  open "$PWD/build/Nova.app"
  echo "Nova relancé. Cette fenêtre peut être fermée."
else
  echo "❌ Build en échec — voir $LOG"; tail -20 "$LOG"
fi
