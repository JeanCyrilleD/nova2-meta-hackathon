#!/bin/bash
# 29/10 (Ahadi : « go with the xcode reco profiling session ») — profilage CPU de Nova pendant l'usage réel.
# Déclenché par build_watch.sh quand dormant/PROFILE_REQUEST existe (contenu : durée en secondes, 90 par défaut).
# 1) Instruments (xctrace, Time Profiler) attaché à Nova ; 2) repli « sample » de macOS ; 3) instantané top.
# Sorties : releves/diag/profil/ (trace, export XML, journal). Lecture seule : rien n'est modifié dans Nova.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$HOME/spark-local/Nova2"
OUT="$ROOT/releves/diag/profil"; mkdir -p "$OUT"
LOG="$OUT/profil_log.txt"
DUR="$(grep -o '[0-9]\+' "$ROOT/dormant/PROFILE_REQUEST" 2>/dev/null | head -1)"; DUR="${DUR:-90}"
rm -f "$ROOT/dormant/PROFILE_REQUEST"
PID="$(pgrep -x NovaMac | head -1)"
echo "début $(date '+%H:%M:%S') pid=${PID:-absent} durée=${DUR}s" > "$LOG"
[ -n "$PID" ] || { echo "Nova ne tourne pas : rien à profiler" >> "$LOG"; exit 0; }
top -l 1 -pid "$PID" -stats pid,cpu,mem,threads,idlew 2>/dev/null | tail -2 >> "$LOG"
TR="$OUT/nova_$(date +%H%M).trace"
rm -rf "$OUT"/*.trace "$OUT/time_profile.xml" "$OUT/sample.txt"
if xcrun xctrace record --template 'Time Profiler' --attach "$PID" --time-limit "${DUR}s" --output "$TR" >> "$LOG" 2>&1; then
  echo "xctrace OK $(date '+%H:%M:%S')" >> "$LOG"
  xcrun xctrace export --input "$TR" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output "$OUT/time_profile.xml" >> "$LOG" 2>&1 \
    && echo "export OK ($(wc -c < "$OUT/time_profile.xml") octets)" >> "$LOG"
else
  echo "xctrace refusé → repli sample $(date '+%H:%M:%S')" >> "$LOG"
  sample "$PID" "$DUR" 5 -mayDie -file "$OUT/sample.txt" >> "$LOG" 2>&1 && echo "sample OK" >> "$LOG"
fi
top -l 2 -pid "$PID" -stats pid,cpu,mem,threads,idlew 2>/dev/null | tail -2 >> "$LOG"
echo "fin $(date '+%H:%M:%S')" >> "$LOG"
