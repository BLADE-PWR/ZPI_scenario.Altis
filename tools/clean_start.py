#!/usr/bin/env python3
"""
Start from clean folders: deletes the tool outputs, the screenshots and the old Arma logs.

    python tools/clean_start.py            # shows what would be deleted, asks before deleting
    python tools/clean_start.py --yes      # no question

Deleted:
  - everything in <mission>\\output\\ (datasets, orthophotos, sessions, geolocation results),
    except trained models (runs\\ folders and *.pt files)
  - the zpi folder in the Arma Screenshots folder (all screenshot sessions)
  - old Arma logs (*.rpt) and crash dumps (*.mdmp, *.bidmp) in %LOCALAPPDATA%\\Arma 3
    (the log of a game that is running right now is locked and stays)
Kept: the mission files, the tools, the README, trained models, your game settings.
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zpi_paths  # noqa: E402

KEEP_NAMES = {"runs"}           # YOLO training results
KEEP_SUFFIXES = {".pt", ".onnx"}


def size_of(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def has_kept(p: Path) -> bool:
    """True when a folder holds trained models (then it is not deleted as a whole)."""
    return p.is_dir() and any(f.name in KEEP_NAMES or f.suffix.lower() in KEEP_SUFFIXES for f in p.rglob("*"))


def output_targets() -> list[Path]:
    out: list[Path] = []
    o = zpi_paths.OUTPUT_DIR
    if o.is_dir():
        for p in sorted(o.iterdir()):
            if p.name in KEEP_NAMES or p.suffix.lower() in KEEP_SUFFIXES:
                continue
            if has_kept(p):
                print(f"  (kept, holds trained models: {p})")
                continue
            out.append(p)
    return out


def main():
    print(zpi_paths.describe(), "\n")
    targets = output_targets()
    if (zpi_paths.SCREENSHOT_DIR / "zpi").is_dir():
        targets.append(zpi_paths.SCREENSHOT_DIR / "zpi")
    logs = zpi_paths.RPT_DIR
    if logs.is_dir():
        targets += sorted(p for p in logs.iterdir() if p.is_file() and p.suffix.lower() in (".rpt", ".mdmp", ".bidmp"))

    if not targets:
        print("Nothing to delete: already clean.")
        return
    total = 0
    print("Will delete:")
    for t in targets:
        s = size_of(t)
        total += s
        print(f"  {t}   ({s / 1e9:.2f} GB)")
    print(f"total {total / 1e9:.2f} GB")
    if "--yes" not in sys.argv:
        if input("Type YES to delete: ").strip() != "YES":
            print("Nothing deleted.")
            return
    failed = []
    for t in targets:
        try:
            shutil.rmtree(t) if t.is_dir() else t.unlink()
        except Exception as e:
            failed.append((t, e))
    print(f"Deleted {len(targets) - len(failed)} of {len(targets)}.")
    for t, e in failed:
        print(f"  not deleted (in use? close Arma first): {t}")


if __name__ == "__main__":
    main()
