"""English transcription bake-off: Apple SpeechTranscriber vs Soniox vs Whisper, on the owner's own lectures.

Layout:
  clips/<clip>/audio.wav        10 minutes of real lecture audio (any rate; Whisper/Soniox resample)
  clips/<clip>/reference.txt    human-corrected transcript of exactly that audio
  results/<engine>/<clip>.txt   one hypothesis per engine and clip

Producing hypotheses:
  apple            swift tools/apple_transcribe.swift clips/<clip>/audio.wav en-US > results/apple/<clip>.txt   (Mac, macOS 26+)
  apple-live       export the lecture from the app as TXT and save it as results/apple-live/<clip>.txt
  whisper          python wer_eval.py run --engine whisper   (faster-whisper large-v3-turbo)
  whisper-large    python wer_eval.py run --engine whisper-large
  soniox           SONIOX_API_KEY=... python wer_eval.py run --engine soniox   (real-time API, same model as the app)

Scoring:
  python wer_eval.py score
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import unicodedata
from pathlib import Path

import jiwer

FILLERS = {"um", "uh", "erm", "er", "ah", "hmm", "mm", "mhm", "uhm"}
TIMESTAMP = re.compile(r"\[?\b\d{1,2}:\d{2}(?::\d{2})?\]?")
SPEAKER = re.compile(r"\b(?:speaker|المتحدث)\s*\w+\s*:?", re.IGNORECASE)


def normalize(text: str, drop_fillers: bool = True) -> str:
    """Lower-case, no punctuation, no timestamps or speaker labels; fillers out on both sides."""
    text = unicodedata.normalize("NFKC", text)
    text = TIMESTAMP.sub(" ", text)
    text = SPEAKER.sub(" ", text)
    text = text.replace("’", "'").replace("‘", "'").lower()
    text = re.sub(r"(?<=\w)-(?=\w)", " ", text)          # well-known -> well known
    text = re.sub(r"[^\w\s']", " ", text)                 # punctuation
    text = re.sub(r"(^|\s)'|'(\s|$)", " ", text)          # quotes, keep don't / it's
    words = [w for w in text.split() if not (drop_fillers and w in FILLERS)]
    return " ".join(words)


def read_hypothesis(path: Path) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    # An app TXT export starts with the title and the date and indents translations: keep only
    # lines that begin with a timestamp when the file has any.
    stamped = [l for l in lines if TIMESTAMP.match(l.strip())]
    return "\n".join(stamped if stamped else lines)


def run_whisper(audio: Path, model_name: str) -> str:
    from faster_whisper import WhisperModel

    model = WhisperModel(model_name, device="auto", compute_type="default")
    segments, _ = model.transcribe(str(audio), language="en", vad_filter=True, beam_size=5)
    return " ".join(s.text.strip() for s in segments)


def run_soniox(audio: Path) -> str:
    """Streams the clip to the real-time API exactly like SonioxEngine.swift (16 kHz s16le mono)."""
    import numpy as np
    import soundfile as sf
    from websockets.sync.client import connect

    samples, rate = sf.read(str(audio), dtype="float32", always_2d=True)
    mono = samples.mean(axis=1)
    if rate != 16_000:
        positions = np.arange(0, len(mono), rate / 16_000)
        mono = np.interp(positions, np.arange(len(mono)), mono)
    pcm = (np.clip(mono, -1, 1) * 32767).astype("<i2").tobytes()
    config = {
        "model": "stt-rt-v5", "audio_format": "pcm_s16le", "sample_rate": 16_000, "num_channels": 1,
        "language_hints": ["en"], "enable_endpoint_detection": True,
    }
    words: list[str] = []
    headers = {"Authorization": f"Bearer {os.environ['SONIOX_API_KEY']}"}
    with connect("wss://stt-rt.soniox.com/transcribe-websocket", additional_headers=headers, max_size=None) as ws:
        ws.send(json.dumps(config))
        chunk = 16_000 * 2 // 4                         # 250 ms of audio
        for start in range(0, len(pcm), chunk):
            ws.send(pcm[start:start + chunk])
            time.sleep(0.06)                             # ~4x real time
            words.extend(_drain(ws))
        ws.send("")
        while True:
            message = json.loads(ws.recv())
            words.extend(_final_tokens(message))
            if message.get("finished") or message.get("error_code"):
                break
    return "".join(words)


def _final_tokens(message: dict) -> list[str]:
    return [
        t["text"] for t in message.get("tokens", [])
        if t.get("is_final") and t.get("text") not in ("<end>", "<fin>") and t.get("translation_status") != "translation"
    ]


def _drain(ws) -> list[str]:
    out: list[str] = []
    while True:
        try:
            raw = ws.recv(timeout=0)
        except TimeoutError:
            return out
        out.extend(_final_tokens(json.loads(raw)))


ENGINES = {
    "whisper": lambda audio: run_whisper(audio, "large-v3-turbo"),
    "whisper-large": lambda audio: run_whisper(audio, "large-v3"),
    "soniox": run_soniox,
}


def command_run(args: argparse.Namespace) -> None:
    out_dir = Path(args.results) / args.engine
    out_dir.mkdir(parents=True, exist_ok=True)
    for clip in sorted(p for p in Path(args.clips).iterdir() if (p / "audio.wav").exists()):
        target = out_dir / f"{clip.name}.txt"
        if target.exists() and not args.force:
            continue
        started = time.time()
        target.write_text(ENGINES[args.engine](clip / "audio.wav"), encoding="utf-8")
        print(f"{args.engine} {clip.name}: {time.time() - started:.0f} s")


def command_score(args: argparse.Namespace) -> None:
    clips = sorted(p for p in Path(args.clips).iterdir() if (p / "reference.txt").exists())
    engines = sorted(p.name for p in Path(args.results).iterdir() if p.is_dir())
    table: dict[str, dict[str, float]] = {}
    print(f"{'engine':<16}{'WER %':>8}{'CER %':>8}{'sub':>7}{'del':>7}{'ins':>7}   per clip WER %")
    for engine in engines:
        refs, hyps, per_clip = [], [], []
        for clip in clips:
            hyp_path = Path(args.results) / engine / f"{clip.name}.txt"
            if not hyp_path.exists():
                break
            ref = normalize((clip / "reference.txt").read_text(encoding="utf-8"), not args.keep_fillers)
            hyp = normalize(read_hypothesis(hyp_path), not args.keep_fillers)
            refs.append(ref)
            hyps.append(hyp)
            per_clip.append(jiwer.wer(ref, hyp) * 100)
        else:
            words = jiwer.process_words(refs, hyps)
            cer = jiwer.cer(refs, hyps) * 100
            table[engine] = {"wer": words.wer * 100, "cer": cer}
            print(f"{engine:<16}{words.wer * 100:>8.2f}{cer:>8.2f}{words.substitutions:>7}{words.deletions:>7}{words.insertions:>7}   "
                  + " ".join(f"{w:.1f}" for w in per_clip))
            continue
        print(f"{engine:<16} (missing clips, skipped)")

    baseline = table.get(args.baseline)
    if baseline:
        print(f"\nDecision rule (vs {args.baseline}): adopt an engine only if WER is >= 20% lower (relative) AND >= 2 points lower.")
        for engine, scores in table.items():
            if engine == args.baseline:
                continue
            gain = baseline["wer"] - scores["wer"]
            relative = gain / baseline["wer"] * 100 if baseline["wer"] else 0
            verdict = "ADOPT" if gain >= 2 and relative >= 20 else "keep baseline"
            print(f"  {engine:<14} {gain:+.2f} pts ({relative:+.0f}%)  -> {verdict}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--clips", default="clips")
    parser.add_argument("--results", default="results")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--engine", choices=sorted(ENGINES), required=True)
    run.add_argument("--force", action="store_true")
    score = sub.add_parser("score")
    score.add_argument("--baseline", default="apple-live")
    score.add_argument("--keep-fillers", action="store_true")
    args = parser.parse_args()
    {"run": command_run, "score": command_score}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
