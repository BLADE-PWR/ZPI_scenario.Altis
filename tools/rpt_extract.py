#!/usr/bin/env python3
"""
Extract ZPI records from an Arma 3 RPT log into per-session JSON Lines files.

Every record the mission writes is one RPT line:   HH:MM:SS ZPI|<type>|<json>
  tel   -> telemetry.jsonl     (one line per frame)
  gt    -> ground_truth.jsonl  (multi-part lines merged per frame, objects as dicts)
  spawn -> objects.jsonl       (class, classname, 3D bbox of every object)
  evt   -> events.jsonl        (scene start/ready, time, weather, explosions, props ...)

A new session starts at every "session_start" event (= mission start).

Usage (from the mission folder; output goes to <mission>\\output\\sessions):
  python tools/rpt_extract.py                       # all RPT logs in %LOCALAPPDATA%\\Arma 3
  python tools/rpt_extract.py path\\to\\file.rpt -o sessions
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zpi_paths  # noqa: E402

LINE_RE = re.compile(r"ZPI\|(tel|gt|spawn|evt)\|(.*)$")
GT_FIELDS = ("id", "pos_asl", "dir_deg", "vel", "stance")


def parse_line(line: str):
    m = LINE_RE.search(line.rstrip("\r\n"))
    if not m:
        return None
    kind, payload = m.groups()
    return kind, json.loads(payload.strip().replace("\\", "/"))


class Session:
    def __init__(self, root: Path, start_evt: dict):
        data = start_evt["data"]
        world = data["world"]
        tag = data["session"]
        self.dir = root / f"session_{tag}_{world}"     # same name as the screenshot folder
        self.dir.mkdir(parents=True, exist_ok=True)
        self.files = {
            name: open(self.dir / f"{name}.jsonl", "w", encoding="utf-8")
            for name in ("telemetry", "ground_truth", "objects", "events")
        }
        self.cls = {}                      # id -> cls, from spawn records
        self.gt_parts = defaultdict(dict)  # frame -> {part: record}
        self.counts = defaultdict(int)

    def write(self, name: str, rec: dict):
        self.files[name].write(json.dumps(rec, separators=(",", ":")) + "\n")
        self.counts[name] += 1

    def add(self, kind: str, rec: dict):
        if kind == "tel":
            self.write("telemetry", rec)
        elif kind == "spawn":
            self.cls[rec["id"]] = rec["cls"]
            self.write("objects", rec)
        elif kind == "evt":
            self.write("events", rec)
        elif kind == "gt":
            parts = self.gt_parts[rec["frame"]]
            parts[rec["part"]] = rec
            if len(parts) == rec["parts"]:
                self._flush_gt(rec["frame"])

    def _flush_gt(self, frame: int):
        parts = self.gt_parts.pop(frame)
        first = parts[0]
        objs = []
        for k in sorted(parts):
            for o in parts[k]["objs"]:
                d = dict(zip(GT_FIELDS, o))
                d["cls"] = self.cls.get(d["id"], "unknown")
                objs.append(d)
        self.write("ground_truth", {"frame": frame, "t_game": first["t_game"], "objs": objs})

    def close(self):
        for frame in list(self.gt_parts):  # incomplete multi-part frames (log cut off)
            self.counts["gt_incomplete"] += 1
            self.gt_parts.pop(frame)
        for f in self.files.values():
            f.close()


def extract(rpts, out_root: Path) -> list[Session]:
    sessions: list[Session] = []
    current: Session | None = None
    bad = 0
    for rpt in rpts:
        with open(rpt, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    parsed = parse_line(line)
                except json.JSONDecodeError:
                    bad += 1
                    continue
                if parsed is None:
                    continue
                kind, rec = parsed
                if kind == "evt" and rec.get("kind") == "session_start":
                    if current:
                        current.close()
                    current = Session(out_root, rec)
                    sessions.append(current)
                current.add(kind, rec)
        if current:
            current.close()
            current = None
    for s in sessions:
        summary = ", ".join(f"{k}={v}" for k, v in sorted(s.counts.items()))
        print(f"{s.dir}: {summary}")
    if bad:
        print(f"warning: {bad} ZPI lines were not valid JSON (truncated log lines?)")
    return sessions


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rpt", nargs="?", help="RPT file (default: all logs in %%LOCALAPPDATA%%\\Arma 3)")
    ap.add_argument("-o", "--out", default="sessions", help="output folder; a plain name goes into the mission's output\\ folder")
    args = ap.parse_args()

    if args.rpt:
        rpts = [Path(args.rpt)]
    else:   # every log, oldest first: a new log starts at each game launch
        rpts = zpi_paths.rpt_files()
        if not rpts:
            sys.exit(f"No .rpt files in {zpi_paths.RPT_DIR}")
    extract(rpts, zpi_paths.out_path(args.out))


if __name__ == "__main__":
    main()
