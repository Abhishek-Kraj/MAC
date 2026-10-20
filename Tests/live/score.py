"""Score an interview test run written by InterviewTestDriver.

  python3 -I Tests/live/score.py <result.json> [--script <script.json>] [--spoken <spoken.jsonl>]

Scripted runs carry their own per-line results. Live runs are matched back to
the script through the captured transcript, using the times in spoken.jsonl
(written by play_script.py) for latency.
"""
import json
import re
import sys
from datetime import datetime

DEPTH_BANDS = {"Brief": (25, 45), "Standard": (60, 110), "Deep": (150, 250)}
TOLERANCE = 0.4
ONE_LINE_MAX_WORDS = 40
DEBRIEF_SECTIONS = ["Questions asked", "What they cared about", "How you answered",
                    "Strengths", "Gaps", "To research", "Thank-you email"]


def words(text: str | None) -> list[str]:
    return re.findall(r"[A-Za-z0-9']+", text or "")


def tokens(text: str | None) -> set[str]:
    return {w.lower() for w in words(text)}


def first_line(text: str | None) -> str:
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line
    return ""


def say_aloud_ok(answer: str) -> bool:
    line = first_line(answer)
    plain = not line.startswith(("-", "*", "#", "•"))
    return plain and len(words(line)) >= 5 and line.rstrip("*").endswith((".", "!", "?", "\""))


def classify(answer: str | None, sent: bool) -> str:
    if not sent:
        return "nothing"
    if not answer:
        return "sent, empty answer"
    return "oneLine" if len(words(answer)) <= ONE_LINE_MAX_WORDS else "answer"


def verdict(expect: str, actual: str) -> bool:
    if expect in ("ignore", "wait"):
        return actual == "nothing"
    if expect == "brief":
        return actual in ("nothing", "oneLine")
    if expect == "oneLine":
        return actual == "oneLine"
    if expect == "prepared":
        return actual == "prepared"
    if expect in ("answer", "list"):
        return actual in ("answer", "oneLine") if expect == "list" else actual == "answer"
    return False


def length_ok(answer: str, depth: str) -> tuple[bool, int, tuple[int, int]]:
    lo, hi = DEPTH_BANDS.get(depth, (0, 10**6))
    n = len(words(answer))
    return lo * (1 - TOLERANCE) <= n <= hi * (1 + TOLERANCE), n, (lo, hi)


def parse_time(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def scripted_rows(result: dict) -> list[dict]:
    rows = []
    for line in result["lines"]:
        if line["speaker"] != "them":
            continue
        sent = line.get("sentText") is not None
        rows.append({"text": line["text"], "expect": line["expect"], "answer": line.get("answer"),
                     "sent": sent, "decisions": line["decisions"], "latency": None,
                     "prepared": any(d.startswith("prepared answer") for d in line["decisions"])})
    return rows


def live_rows(result: dict, script: dict, spoken: list[dict]) -> list[dict]:
    """Each THEM line counts as sent if a user turn holds most of its words."""
    turns = result["turns"]
    user_turns = [(i, t) for i, t in enumerate(turns) if t["role"] == "user"]
    spoken_at = {s["index"]: parse_time(s["end"]) for s in spoken}
    them = [i for i, line in enumerate(script["lines"]) if line["speaker"] == "them"]
    rows = []
    for idx, line in enumerate(script["lines"]):
        if line["speaker"] != "them":
            continue
        want = tokens(line["text"])
        best, best_overlap = None, 0.0
        for i, t in user_turns:
            overlap = len(want & tokens(t["content"])) / max(1, len(want))
            if overlap > best_overlap:
                best, best_overlap = (i, t), overlap
        sent = best is not None and best_overlap >= 0.6
        # A line that waited goes out joined to the next one: it shares that
        # turn, so it was held, not answered on its own.
        later = [j for j in them if j > idx]
        if sent and line["expect"] == "wait" and later:
            following = tokens(script["lines"][later[0]]["text"])
            if len(following & tokens(best[1]["content"])) >= 0.6 * len(following):
                sent = False
        answer, latency, prepared = None, None, False
        if sent:
            i, t = best
            sent_at = parse_time(t["at"])
            prepared = any(d["text"].startswith("prepared answer")
                           and abs((parse_time(d["at"]) - sent_at).total_seconds()) <= 5
                           for d in result["decisions"])
            nxt = turns[i + 1] if i + 1 < len(turns) else None
            answer = nxt["content"] if nxt and nxt["role"] == "assistant" else None
            if idx in spoken_at:
                latency = (parse_time(t["at"]) - spoken_at[idx]).total_seconds()
        rows.append({"text": line["text"], "expect": line["expect"], "answer": answer, "sent": sent,
                     "decisions": [f"heard {best_overlap:.0%}"], "latency": latency, "prepared": prepared})
    return rows


def score_debrief(minutes: str | None, your_speech: list[str]) -> list[str]:
    if not minutes:
        return ["FAIL no debrief"]
    out = []
    for name in DEBRIEF_SECTIONS:
        out.append(("PASS " if f"### {name}" in minutes else "FAIL ") + f"section '{name}'")
    takeaway = first_line(minutes)
    out.append(("PASS " if takeaway and not takeaway.startswith("#") else "FAIL ") + "opens with a takeaway line")
    answered = tokens(minutes.split("### How you answered", 1)[-1].split("###", 1)[0])
    if your_speech:
        used = sum(1 for said in your_speech if len(tokens(said) & answered) >= 0.6 * len(tokens(said)))
        out.append(("PASS " if used else "FAIL ") + f"How you answered uses your words ({used}/{len(your_speech)} lines)")
    return out


def main() -> None:
    args = sys.argv[1:]
    result = json.load(open(args[0], encoding="utf-8"))
    opt = {args[i]: args[i + 1] for i in range(1, len(args) - 1, 2)}
    print(f"# Interview test — {result['mode']}  ({result['status']})")
    engine = f" · transcription {result['engine']}" if result.get("engine") else ""
    print(f"model {result['model']} · depth {result['depth']} · auto-answer {result['autoAnswer']}{engine}\n")
    if result.get("statusBeforeEnd"):
        print(f"status line during the session: {result['statusBeforeEnd']}\n")

    if result["mode"] == "scripted":
        rows = scripted_rows(result)
    else:
        script = json.load(open(opt["--script"], encoding="utf-8"))
        spoken = [json.loads(row) for row in open(opt["--spoken"], encoding="utf-8") if row.strip()]
        rows = live_rows(result, script, spoken)

    passed = 0
    for n, r in enumerate(rows, 1):
        actual = "prepared" if r["sent"] and r["prepared"] else classify(r["answer"], r["sent"])
        ok = verdict(r["expect"], actual)
        passed += ok
        extra = []
        if r["prepared"]:
            extra.append("prepared answer from your bank (length not checked)")
        elif r["answer"]:
            if actual == "answer" and r["expect"] != "list":
                good, count, band = length_ok(r["answer"], result["depth"])
                extra.append(f"{count} words ({'ok' if good else 'OUT OF BAND'} for {band[0]}–{band[1]})")
            extra.append("say-aloud first line " + ("ok" if say_aloud_ok(r["answer"]) else "MISSING"))
        if r["latency"] is not None:
            extra.append(f"sent {r['latency']:.1f}s after speech ended")
        print(f"{'PASS' if ok else 'FAIL'} {n:2}. [{r['expect']} → {actual}] {r['text'][:70]}")
        print(f"        {' · '.join(r['decisions'])}" + (f" | {'; '.join(extra)}" if extra else ""))
    print(f"\nDetection: {passed}/{len(rows)} lines as expected")

    print("\n## Debrief")
    for line in score_debrief(result.get("minutes"), result.get("yourSpeech")):
        print(line)


main()
