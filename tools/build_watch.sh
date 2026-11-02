#!/bin/bash
# 26/10 (accord d'Ahadi, 11:20) — déclencheur de build sans écran : lancé par launchd quand
# ~/spark-local/Nova2/dormant/BUILD_REQUEST apparaît. Compile, puis relance Nova en arrière-plan.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$HOME/spark-local/Nova2"
REQ="$ROOT/dormant/BUILD_REQUEST"
LOCK="$ROOT/dormant/.build_running"
[ -f "$REQ" ] || exit 0
[ -f "$LOCK" ] && exit 0
touch "$LOCK"
# 29/10 : « PROFILE_ONLY » dans la demande = profilage seul, sans recompiler (tools/profile_nova.sh)
if grep -q "PROFILE_ONLY" "$REQ" 2>/dev/null; then
  rm -f "$REQ"; [ -f "$ROOT/dormant/PROFILE_REQUEST" ] || echo 90 > "$ROOT/dormant/PROFILE_REQUEST"
  bash "$ROOT/tools/profile_nova.sh"; rm -f "$LOCK"; [ -f "$REQ" ] && exec "$0"; exit 0
fi
# 31/10 (audit Phase 0) : « TEST_ONLY » = swift build + swift test seuls (aucune relance), journal dans releves/diag/test_log.txt.
if grep -q "TEST_ONLY" "$REQ" 2>/dev/null; then
  rm -f "$REQ"; cd "$ROOT" || exit 1; TL="$ROOT/releves/diag/test_log.txt"
  { echo "DEBUT $(date '+%H:%M:%S')"; T0=$(date +%s); swift build 2>&1 | tail -40; echo "BUILD_RC=${PIPESTATUS[0]} BUILD_S=$(( $(date +%s) - T0 ))"; T1=$(date +%s); swift test 2>&1 | tail -150; echo "TEST_RC=${PIPESTATUS[0]} TEST_S=$(( $(date +%s) - T1 ))"; echo "FIN $(date '+%H:%M:%S')"; } > "$TL" 2>&1
  rm -f "$LOCK"; [ -f "$REQ" ] && exec "$0"; exit 0
fi
# 31/10 (phases du brief) : FILE DE TESTS — dormant/TESTQ/<nom>.req contient le chemin d'un worktree (+ « tsan » éventuel).
# Traités un par un (disque serré : un seul cache partagé $ROOT/.build), journal releves/diag/tests/<nom>.log.
run_testq() {
  mkdir -p "$ROOT/dormant/TESTQ" "$ROOT/releves/diag/tests"
  for rq in "$ROOT"/dormant/TESTQ/*.req; do
    [ -f "$rq" ] || continue
    nm=$(basename "$rq" .req); wt=$(head -1 "$rq" | awk '{print $1}'); fl=$(head -1 "$rq" | awk '{print $2}'); rm -f "$rq"
    out="$ROOT/releves/diag/tests/$nm.log"; san=""; [ "$fl" = "tsan" ] && san="--sanitize=thread"
    { echo "DEBUT $(date '+%H:%M:%S') $wt $fl"; T0=$(date +%s); swift build --package-path "$wt" --scratch-path "$ROOT/.build" $san 2>&1 | tail -60; echo "BUILD_RC=${PIPESTATUS[0]} BUILD_S=$(( $(date +%s) - T0 ))"; T1=$(date +%s); swift test --package-path "$wt" --scratch-path "$ROOT/.build" $san 2>&1 | tail -200; echo "TEST_RC=${PIPESTATUS[0]} TEST_S=$(( $(date +%s) - T1 ))"; [ -x "$wt/tools/verify.sh" ] && { (cd "$wt" && ./tools/verify.sh) 2>&1 | tail -40; echo "VERIFY_RC=${PIPESTATUS[0]}"; }; echo "FIN $(date '+%H:%M:%S')"; } > "$out" 2>&1
  done
}
if grep -q "TEST_QUEUE" "$REQ" 2>/dev/null; then
  rm -f "$REQ"; cd "$ROOT" || exit 1; run_testq; rm -f "$LOCK"; [ -f "$REQ" ] && exec "$0"; exit 0
fi
# 31/10 : « RELAUNCH_ONLY » = relance seule (Nova figée), sans recompiler.
RELAUNCH_ONLY=0; grep -q "RELAUNCH_ONLY" "$REQ" 2>/dev/null && RELAUNCH_ONLY=1
rm -f "$REQ"
cd "$ROOT" || exit 1
LOG="$ROOT/build_log_cmd.txt"
if { [ $RELAUNCH_ONLY = 1 ] && echo "Relance seule demandée $(date '+%H:%M:%S') — Nova.app prêt" > "$LOG"; } || { bash tools/package_app.sh > "$LOG" 2>&1 && grep -q "Nova.app prêt" "$LOG"; }; then
  ( osascript -e 'tell application id "com.ahadi.nova" to quit' 2>/dev/null & )
  sleep 6
  # 31/10 : Nova figée ne répond pas à « quit » — arrêt forcé, sinon « open » ne relance rien.
  if pgrep -x NovaMac >/dev/null; then pkill -x NovaMac; sleep 3; pgrep -x NovaMac >/dev/null && { pkill -9 -x NovaMac; echo "ARRET FORCE $(date '+%H:%M:%S')" >> "$LOG"; }; fi
  sleep 1
  open -g "$ROOT/build/Nova.app"
  echo "RELANCE OK $(date '+%H:%M:%S')" >> "$LOG"
  # 29/10 : contrôle de démarrage RÉEL de l'interface (témoin posé par shell.js via /api/ui/booted)
  T0=$(date +%s); UIB="$ROOT/releves/diag/ui_boot.txt"; ok=0
  for i in $(seq 1 18); do sleep 5; if [ -f "$UIB" ] && [ $(stat -f %m "$UIB") -ge $T0 ]; then ok=1; break; fi; done
  if [ $ok = 1 ]; then echo "UI OK $(date '+%H:%M:%S')" >> "$LOG"; else echo "UI FIGEE (aucun démarrage d'interface en 90 s) $(date '+%H:%M:%S')" >> "$LOG"; fi
else
  echo "BUILD ECHEC $(date '+%H:%M:%S')" >> "$LOG"
fi
run_testq   # 31/10 : tests en attente traités après chaque build
rm -f "$LOCK"
# une demande arrivée pendant le build relance un tour
[ -f "$REQ" ] && exec "$0"
exit 0
