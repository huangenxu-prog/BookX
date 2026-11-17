#!/usr/bin/env python3
"""Preflight the minimum CosyVoice3 offline model bundle before iOS packaging.

This is a presence/size check, NOT a claim of model correctness or inference quality.
The upstream engine discovers GGUF components by prefix and requires Qwen2 BPE files
and a baked voice.gguf. Zero-shot cloning components are deliberately optional.
"""
import argparse
from pathlib import Path
import sys

REQUIRED = {
    "llm": "cosyvoice3-llm*.gguf",
    "flow": "cosyvoice3-flow*.gguf",
    "hift": "cosyvoice3-hift*.gguf",
    "voice": "voice.gguf",
    "vocab": "vocab.json",
    "merges": "merges.txt",
}
def check(root: Path) -> list[str]:
    errors = []
    for component, pattern in REQUIRED.items():
        matches = sorted(p for p in root.glob(pattern) if p.is_file())
        if not matches:
            errors.append(f"missing {component}: {pattern}")
        elif len(matches) > 1:
            errors.append(f"ambiguous {component}: {', '.join(p.name for p in matches)}")
        elif matches[0].stat().st_size == 0:
            errors.append(f"empty {component}: {matches[0].name}")
        else:
            print(f"{component:8} {matches[0].name:42} {matches[0].stat().st_size / (1024**2):.1f} MiB")
    return errors

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("model_dir", type=Path)
    args = parser.parse_args()
    if not args.model_dir.is_dir():
        print(f"Not a directory: {args.model_dir}", file=sys.stderr)
        return 2
    errors = check(args.model_dir)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Model file preflight passed (not an inference test).")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
