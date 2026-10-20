#!/usr/bin/env bash
# Feeds Tests/live/interview_script.json, as text, through the live-interview
# path of the dev build (real model calls, no audio, a throwaway session),
# then scores it. Uses the OpenRouter key.
#
#   Tests/live/run_scripted_interview.sh [outdir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/TheCloser Dev.app/Contents/MacOS/thecloser-dev"
SCRIPT="$ROOT/Tests/live/interview_script.json"
OUT="${1:-$(mktemp -d -t interviewtest)}"
mkdir -p "$OUT"

pkill -x thecloser-dev || true
sleep 1
"$APP" -scriptedinterview "$SCRIPT" "$OUT" > "$OUT/app.log" 2>&1 &

for _ in $(seq 1 1200); do
    [[ -f "$OUT/result.json" ]] && break
    sleep 0.5
done
pkill -x thecloser-dev || true
python3 -I "$ROOT/Tests/live/score.py" "$OUT/result.json" | tee "$OUT/scorecard.txt"
echo "Run folder: $OUT"
