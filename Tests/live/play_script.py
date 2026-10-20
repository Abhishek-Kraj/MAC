"""Speak an interview script out loud and log when each line ended.

  python3 -I Tests/live/play_script.py <script.json> <spoken.jsonl>

The interviewer is Daniel, the candidate Samantha (macOS `say` voices).
"""
import json
import subprocess
import sys
import time
from datetime import datetime, timezone

VOICES = {"them": "Daniel", "you": "Samantha"}


def main(script_path: str, log_path: str) -> None:
    lines = json.load(open(script_path, encoding="utf-8"))["lines"]
    with open(log_path, "w", encoding="utf-8") as log:
        for index, line in enumerate(lines):
            subprocess.run(["say", "-v", VOICES[line["speaker"]], line["text"]], check=True)
            ended = datetime.now(timezone.utc).isoformat()
            log.write(json.dumps({"index": index, "speaker": line["speaker"], "end": ended}) + "\n")
            log.flush()
            print(f"{index:2} {line['speaker']:4} {line['text'][:60]}", flush=True)
            time.sleep(line.get("pause", 3))


main(sys.argv[1], sys.argv[2])
