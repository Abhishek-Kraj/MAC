#!/usr/bin/env bash
# Plays Tests/live/interview_script.json out loud into a real interview in the
# dev build, then scores it.
#
# Needs: a dev build, Screen Recording for TheCloser Dev (system audio is the
# interviewer lane), nobody talking and no call running. Uses the ElevenLabs
# (or chosen) transcription key and the OpenRouter key. The session is a real
# interview and stays in History.
#
#   Tests/live/run_live_interview.sh [outdir] [engine]
#
# engine: apple, elevenLabs, grok or auto, for this run only (default: the
# app's own setting).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/TheCloser Dev.app"
SCRIPT="$ROOT/Tests/live/interview_script.json"
OUT="${1:-$(mktemp -d -t interviewtest)}"
ENGINE_ARGS=()
[[ -n "${2:-}" ]] && ENGINE_ARGS=(-engine "$2")
mkdir -p "$OUT"

pkill -x thecloser-dev || true
sleep 1
# Through LaunchServices, not the binary: started from a shell, macOS holds
# the shell responsible for the mic and speech requests, finds no usage
# description there, and kills the app.
open -n "$APP" --stdout "$OUT/app.log" --stderr "$OUT/app.err" --args -livetest "$OUT" ${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"}

for _ in $(seq 1 60); do
    [[ -f "$OUT/ready" || -f "$OUT/result.json" ]] && break
    sleep 0.5
done
if [[ ! -f "$OUT/ready" ]]; then
    echo "The interview did not start recording:"
    cat "$OUT/result.json" 2>/dev/null || tail -20 "$OUT/app.err"
    exit 1
fi

python3 -I "$ROOT/Tests/live/play_script.py" "$SCRIPT" "$OUT/spoken.jsonl"
touch "$OUT/end"

for _ in $(seq 1 400); do
    [[ -f "$OUT/result.json" ]] && break
    sleep 0.5
done
python3 -I "$ROOT/Tests/live/score.py" "$OUT/result.json" --script "$SCRIPT" --spoken "$OUT/spoken.jsonl" \
    | tee "$OUT/scorecard.txt"
echo "Run folder: $OUT"
