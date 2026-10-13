"""Blind test for EN->AR translation: Apple live vs LLM-refined (Haiku / Sonnet / local Qwen ...).

1) make:  python translation_blind_test.py make --archive lecture1.json lecture2.json --n 200
          [--extra sonnet=sonnet.json]  (extra = {"<segment uid>": "translation"} from another system)
   -> blind.csv (what you rate) + key.json (keep closed until scoring)
2) Rate each option 1-5 in blind.csv (A_score, B_score, ...): 5 = correct, natural, right terms.
3) score: python translation_blind_test.py score --csv blind.csv --key key.json

`lecture.json` is the archive the app writes into each lecture folder and backs up to S3.
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import statistics
from pathlib import Path


def load_systems(archives: list[str], extras: list[str]) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    english: dict[str, str] = {}
    systems: dict[str, dict[str, str]] = {"apple": {}, "refined": {}}
    for path in archives:
        archive = json.loads(Path(path).read_text(encoding="utf-8"))
        for segment in archive["segments"]:
            uid = segment["uid"]
            english[uid] = segment["text"]
            if segment.get("translation"):
                systems["apple"][uid] = segment["translation"]
            if segment.get("refinedTranslation"):
                systems["refined"][uid] = segment["refinedTranslation"]
    for item in extras:
        name, _, path = item.partition("=")
        systems[name] = json.loads(Path(path).read_text(encoding="utf-8"))
    return english, {k: v for k, v in systems.items() if v}


def command_make(args: argparse.Namespace) -> None:
    english, systems = load_systems(args.archive, args.extra or [])
    names = sorted(systems)
    common = [uid for uid in english if all(uid in systems[n] for n in names) and len(english[uid].split()) >= 4]
    random.seed(args.seed)
    sample = random.sample(common, min(args.n, len(common)))
    letters = [chr(ord("A") + i) for i in range(len(names))]
    key: dict[str, dict[str, str]] = {}
    with open(args.csv, "w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(["row", "english"] + [f"{l}_text" for l in letters] + [f"{l}_score" for l in letters])
        for row, uid in enumerate(sample, 1):
            order = names[:]
            random.shuffle(order)
            key[str(row)] = dict(zip(letters, order))
            writer.writerow([row, english[uid]] + [systems[n][uid] for n in order] + [""] * len(letters))
    Path(args.key).write_text(json.dumps(key, indent=1), encoding="utf-8")
    print(f"{len(sample)} rows, systems: {', '.join(names)} -> {args.csv}")


def command_score(args: argparse.Namespace) -> None:
    key = json.loads(Path(args.key).read_text(encoding="utf-8"))
    scores: dict[str, list[int]] = {}
    wins: dict[str, int] = {}
    with open(args.csv, newline="", encoding="utf-8-sig") as handle:
        for record in csv.DictReader(handle):
            mapping = key[record["row"]]
            row_scores = {mapping[l]: int(record[f"{l}_score"]) for l in mapping if record.get(f"{l}_score", "").strip()}
            for system, value in row_scores.items():
                scores.setdefault(system, []).append(value)
            if row_scores:
                best = max(row_scores.values())
                for system, value in row_scores.items():
                    if value == best:
                        wins[system] = wins.get(system, 0) + 1
    print(f"{'system':<12}{'mean':>7}{'n':>6}{'best-or-tied':>14}")
    for system, values in sorted(scores.items(), key=lambda kv: -statistics.mean(kv[1])):
        print(f"{system:<12}{statistics.mean(values):>7.2f}{len(values):>6}{wins.get(system, 0):>14}")
    print("\nAdopt a refinement system by default only if its mean beats 'apple' by >= 0.5.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("make")
    make.add_argument("--archive", nargs="+", required=True)
    make.add_argument("--extra", nargs="*")
    make.add_argument("--n", type=int, default=200)
    make.add_argument("--seed", type=int, default=7)
    make.add_argument("--csv", default="blind.csv")
    make.add_argument("--key", default="key.json")
    score = sub.add_parser("score")
    score.add_argument("--csv", default="blind.csv")
    score.add_argument("--key", default="key.json")
    args = parser.parse_args()
    {"make": command_make, "score": command_score}[args.command](args)


if __name__ == "__main__":
    main()
