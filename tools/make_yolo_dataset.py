#!/usr/bin/env python3
"""
Turn Arma screenshots (P key) + their automatic labels (RPT log) into a YOLO dataset,
with one JSON file per screenshot (telemetry, laser rangefinder, object coordinates).

Output (Ultralytics layout):
    dataset/
      data.yaml                                class names of the chosen --classes scheme
      images/{train,val,test}/<name>.png
      labels/{train,val,test}/<name>.txt      one "class cx cy w h" line per object
      meta/<name>.json                         everything about that screenshot (see README)
      previews/<name>.jpg                      the image with boxes drawn, for checking
      manifest.csv                             one row per image
      scheme.txt                               which class scheme this dataset uses

Class schemes (--classes), chosen when the dataset is built, no need to retake shots:
    stance       soldier_standing, soldier_kneeling, soldier_prone, tank, military_vehicle, explosion, tank_fire, building  (default)
    simple       soldier, tank, military_vehicle, explosion, tank_fire, building
    size         soldier_small, soldier_large, tank, military_vehicle, explosion, tank_fire, building
    stance_size  soldier_<stance>_<small|large> (6 classes), tank, military_vehicle, explosion, tank_fire, building
  small = box area under 32x32 px in the image (COCO definition), large = everything bigger.

Explosion boxes: when the game took a reference picture just before the impact (same view),
the box is measured from what changed between the two pictures; otherwise the estimated
box from the game is used. Each explosion in the JSON says which ("box_method").

Split (never random per frame: neighbouring frames are near-identical):
    --split region   by location marker: --val-regions / --test-regions (default when 2+ regions)
    --split scene    by scene instance (session + scene + seed), 80/10/10 (default otherwise)

Usage (from the mission folder; output goes to <mission>\\output\\<--out>):
    python tools/make_yolo_dataset.py                      # all Arma logs -> output\\dataset
    python tools/make_yolo_dataset.py --latest --out run1  # newest session only -> output\\run1
    python tools/make_yolo_dataset.py --classes simple --out dataset_simple
    python tools/make_yolo_dataset.py --watch              # keep running, add shots as you take them
    python tools/make_yolo_dataset.py --roboflow --jpg     # also write roboflow_partNN.zip for upload
    python tools/make_yolo_dataset.py --latest --max-buildings 3 --min-green 0.05   # newest session, clean + green only
    python tools/make_yolo_dataset.py --out dataset_pose --pose   # + ground-point keypoint (YOLO-pose)

Filters (pictures that are left out): more than --max-buildings labelled buildings (default 3),
less green than --min-green (share of green pixels, default off). manifest.csv lists burst,
green_fraction and ground_surface per picture, so thresholds can be chosen from real numbers.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import shutil
import sys
import time
import zipfile
from collections import Counter, defaultdict, deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))      # zpi_enhance.py, zpi_paths.py live next to this script
import zpi_paths  # noqa: E402

SCHEMES = {
    "stance": ["soldier_standing", "soldier_kneeling", "soldier_prone", "tank", "military_vehicle", "explosion", "tank_fire", "building"],
    "simple": ["soldier", "tank", "military_vehicle", "explosion", "tank_fire", "building"],
    "size": ["soldier_small", "soldier_large", "tank", "military_vehicle", "explosion", "tank_fire", "building"],
    "stance_size": ["soldier_standing_small", "soldier_standing_large", "soldier_kneeling_small", "soldier_kneeling_large",
                    "soldier_prone_small", "soldier_prone_large", "tank", "military_vehicle", "explosion", "tank_fire", "building"],
}
KIND_NAME = {"s": "soldier", "t": "tank", "v": "military_vehicle", "e": "explosion", "f": "tank_fire", "b": "building"}
STANCE_NAME = {"STAND": "standing", "CROUCH": "kneeling", "PRONE": "prone"}
COLORS = [(255, 60, 60), (255, 140, 140), (255, 0, 160), (255, 200, 0), (60, 200, 255), (255, 120, 0),
          (120, 255, 120), (200, 80, 255), (255, 255, 255)]
LINE_RE = re.compile(r"ZPI\|(label|shot|shotx|evt|dem|ray)\|(.*)$")
SPLITS = ("train", "val", "test")
BROKEN: list[Path] = []          # screenshots that cannot be decoded (half-written by the game)


# ---------------------------------------------------------------- locating files
def default_rpts() -> list[Path]:
    """Every Arma log, oldest first (a new log starts at every game launch)."""
    files = zpi_paths.rpt_files()
    if not files:
        sys.exit(f"No .rpt log files in {zpi_paths.RPT_DIR}. Play the mission once (without -noLogs), or pass --rpt")
    return files


# ---------------------------------------------------------------- reading the log
def _box_to_obj(b) -> dict:
    """One box from the log -> object dict.
    [kind, cx, cy, w, h, id, vis, cut, stance, dist, inside, grid, gx, gy, gz, gu, gv, method, box_3d]"""
    o = {"kind": b[0], "cx": float(b[1]), "cy": float(b[2]), "w": float(b[3]), "h": float(b[4]),
         "object_id": int(b[5]), "visible": float(b[6]), "cut_by_edge": float(b[7]),
         "stance_raw": b[8], "stance_source": "game",
         "distance_m": float(b[9]), "inside_building": bool(int(b[10])), "grid": b[11],
         # ground point (feet / terrain under the hull or building / impact point) and where it is in the image
         "ground_pos_asl": [float(b[12]), float(b[13]), float(b[14])],
         "ground_norm": [float(b[15]), float(b[16])] if b[15] is not None else None}
    if o["kind"] == "s":
        o["soldier_box"] = {"v": "body_parts", "h": "hit_point_parts"}.get(b[17], "3d_box")
        if isinstance(b[18], list) and len(b[18]) == 4:
            o["box_3d"] = [float(v) for v in b[18]]
    return o


def read_labels(rpts: list[Path], diag: Counter | None = None) -> list[dict]:
    """All screenshots in the logs, in log order, as normalized records."""
    diag = diag if diag is not None else Counter()
    done: list[dict] = []
    for rpt in rpts:
        session = "nosession"
        shots: dict[str, dict] = {}
        shotx: dict[str, dict] = {}
        parts: dict[str, dict[int, dict]] = defaultdict(dict)
        dems: dict[str, dict[int, dict]] = defaultdict(dict)
        rays: dict[str, dict[int, dict]] = defaultdict(dict)
        with open(rpt, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = LINE_RE.search(line.rstrip("\r\n"))
                if not m:
                    continue
                kind = m.group(1)
                if kind == "label":
                    diag["label_lines"] += 1
                # Windows paths may contain single backslashes, which JSON does not allow.
                # Our records never contain real escape sequences, so turning them into "/" is safe.
                payload = m.group(2).strip().replace("\\", "/")
                try:
                    rec = json.loads(payload)
                except json.JSONDecodeError as e:
                    if kind in ("label", "shot", "shotx"):
                        diag["cut_off_lines" if not payload.endswith("}") else "invalid_lines"] += 1
                        diag.setdefault("example", f"{e}: {payload[:300]}")
                    continue
                if kind == "evt":
                    if rec.get("kind") == "session_start":
                        session = rec.get("data", {}).get("session", session)
                    continue
                if kind == "dem":
                    dems[rec["image"]][rec["part"]] = rec
                    continue
                if kind == "ray":
                    rays[rec["image"]][rec["part"]] = rec
                    continue
                key = rec["image"]
                if kind == "shot":
                    shots[key] = rec
                    continue
                if kind == "shotx":
                    shotx[key] = rec
                    continue
                parts[key][rec["part"]] = rec
                if len(parts[key]) < rec["parts"]:
                    continue
                p = parts.pop(key)
                objs = [_box_to_obj(b) for k in sorted(p) for b in p[k]["boxes"]]
                r = {**shots.pop(key), **shotx.pop(key, {})}
                r["objects"] = objs
                r["session"] = session
                d = dems.pop(key, {})
                if d and len(d) == next(iter(d.values()))["parts"]:
                    first = d[0]
                    heights = [row for k in sorted(d) for row in d[k]["h"]]
                    r["terrain_grid"] = {"x0": first["x0"], "y0": first["y0"], "spacing_m": first["d"],
                                         "nx": first["nx"], "ny": first["ny"], "heights_asl": heights,
                                         "note": "heights_asl[j][i] = terrain height at (x0 + i*spacing, y0 + j*spacing)"}
                rp = rays.pop(key, {})
                if rp:
                    r["pixel_rays"] = [ray for k in sorted(rp) for ray in rp[k]["rays"]]
                done.append(r)
        diag["incomplete_shots"] += len(parts)   # a part was cut off: labels would be missing, skip the shot
    return done


# ---------------------------------------------------------------- classes
def size_category(o: dict, W: int, H: int) -> str:
    area = o["w"] * W * o["h"] * H
    return "small" if area < 32 * 32 else "medium" if area < 96 * 96 else "large"


def stance_of(o: dict, W: int, H: int) -> str:
    st = STANCE_NAME.get((o.get("stance_raw") or "").upper())
    if st:
        return st
    # stance unknown (e.g. "UNDEFINED"): guess from the box shape, which only works for oblique views
    o["stance_source"] = "guessed_from_box"
    ratio = (o["h"] * H) / max(o["w"] * W, 1e-6)
    return "standing" if ratio > 1.6 else "kneeling" if ratio > 0.9 else "prone"


def class_name(o: dict, scheme: str, W: int, H: int) -> str:
    if o["kind"] != "s":
        return KIND_NAME[o["kind"]]
    if scheme == "simple":
        return "soldier"
    size = "small" if size_category(o, W, H) == "small" else "large"
    if scheme == "size":
        return f"soldier_{size}"
    st = stance_of(o, W, H)
    return f"soldier_{st}" if scheme == "stance" else f"soldier_{st}_{size}"


# ---------------------------------------------------------------- explosion box from the image
EXP_REL = 0.25        # region threshold, fraction of the strongest change (top of the smoke)
EXP_CORE_REL = 0.5    # core threshold: the width comes from the strong core (dense smoke, fire), not faint dust
FIRE_REL = 0.2        # muzzle blast region threshold


def explosion_box_from_diff(ref_path: Path, img_path: Path, o: dict, others: list[dict]) -> tuple | None:
    """Box what changed between the reference picture (just before the impact / shot, same view)
    and the screenshot. Returns (cx, cy, w, h) normalized, or None when nothing convincing was found.

    What counts as the explosion: pixels that changed AND look like smoke (grey) or fire (very
    bright) in the new picture. Smoke rises in a column above the impact point, dust spreads
    sideways along the ground, so the box width comes from the rows ABOVE the impact point
    (plus the fireball), the top from the smoke, and the bottom sits just below the impact point.
    Tuned on real Arma before/after pairs."""
    import numpy as np
    from PIL import Image, ImageFilter
    a = np.asarray(Image.open(ref_path).convert("RGB"), dtype=np.float32)
    b = np.asarray(Image.open(img_path).convert("RGB"), dtype=np.float32)
    if a.shape != b.shape:
        return None
    H, W = a.shape[:2]
    cx, cy, w, h = o["cx"] * W, o["cy"] * H, o["w"] * W, o["h"] * H
    # impact point (explosion) / muzzle (firing) in the image: logged, or the bottom of the estimate
    gn = o.get("ground_norm")
    ix, iy = (gn[0] * W, gn[1] * H) if gn else (cx, cy + h / 2)
    ww, hh = max(w * 2.5, 160), max(h * 2.5, 160)
    if o["kind"] == "f":
        ww = hh = max(ww, hh)
    x0, x1 = int(max(0, cx - ww / 2)), int(min(W, cx + ww / 2))
    y0, y1 = int(max(0, cy - hh / 2)), int(min(H, cy + hh / 2))
    if x1 - x0 < 16 or y1 - y0 < 16:
        return None
    A, B = a[y0:y1, x0:x1], b[y0:y1, x0:x1]
    diff = np.abs(A - B).max(axis=2)
    sat_b = B.max(axis=2) - B.min(axis=2)
    lum_b = B.mean(axis=2)
    grey = np.clip((60.0 - sat_b) / 30.0, 0.0, 1.0)          # smoke: little colour
    fire = np.clip((lum_b - 190.0) / 30.0, 0.0, 1.0)         # fireball / flash: very bright
    if o["kind"] == "f":
        # muzzle blast: the flash and flames ADD light (the tank itself only shifts a little in recoil)
        lum_a = A.mean(axis=2)
        d = np.maximum(0.0, lum_b - lum_a) * 1.5 * np.clip((lum_b - 150.0) / 40.0, 0.0, 1.0)
    else:
        d = diff * np.maximum(grey, fire)
    # units may have moved between the two pictures: ignore their (enlarged) boxes.
    # The firing tank recoils and turns its turret: its hull box is ignored too, but not
    # enlarged, so the flash at the barrel tip and the side flames stay.
    for q in others:
        if q is o or q["kind"] in ("e", "f", "b"):
            continue
        k = 0.45 if (o["kind"] == "f" and q.get("object_id") == o.get("object_id")) else 0.9
        qx0 = int((q["cx"] - q["w"] * k) * W) - x0
        qx1 = int((q["cx"] + q["w"] * k) * W) - x0
        qy0 = int((q["cy"] - q["h"] * k) * H) - y0
        qy1 = int((q["cy"] + q["h"] * k) * H) - y0
        d[max(0, qy0):max(0, qy1), max(0, qx0):max(0, qx1)] = 0
    bl = np.asarray(Image.fromarray(np.clip(d, 0, 255).astype(np.uint8)).filter(ImageFilter.BoxBlur(4)), dtype=np.float32)
    peak = float(bl.max()) if o["kind"] == "f" else float(np.percentile(bl, 99.7))   # a flash is small: use its maximum
    if peak < 30:
        return None
    t = max(20.0, (FIRE_REL if o["kind"] == "f" else EXP_REL) * peak)
    # connected region around the strongest change near the impact point
    f = 4
    m = np.asarray(Image.fromarray(((bl > t) * 255).astype(np.uint8)).resize((max(1, bl.shape[1] // f), max(1, bl.shape[0] // f)), Image.BOX)) > 0
    gh, gw = m.shape
    rx0, rx1 = int(max(0, (ix - x0 - w) / f)), int(min(gw, (ix - x0 + w) / f + 1))
    ry0, ry1 = int(max(0, (iy - y0 - 1.5 * h) / f)), int(min(gh, (iy - y0 + 0.3 * h) / f + 1))
    if o["kind"] == "f":
        # muzzle blast: the flash and the side flames of the muzzle brake are separate blobs,
        # so take everything that changed within the estimated blast area around the muzzle
        rr = 0.9 * max(w, h)
        my0, my1 = int(max(0, (iy - y0 - rr) / f)), int(min(gh, (iy - y0 + rr) / f + 1))
        mx0, mx1 = int(max(0, (ix - x0 - rr) / f)), int(min(gw, (ix - x0 + rr) / f + 1))
        fy, fx = np.nonzero(m[my0:my1, mx0:mx1])
        if len(fy) * f * f < 20:
            return None
        ys = (fy + my0) * f + y0 + f / 2
        xs = (fx + mx0) * f + x0 + f / 2
        lx, rx = float(np.percentile(xs, 2)) - f / 2, float(np.percentile(xs, 98)) + f / 2
        top, bottom = float(np.percentile(ys, 2)) - f / 2, float(np.percentile(ys, 98)) + f / 2
        if rx - lx < 4 or bottom - top < 4:
            return None
        return ((lx + rx) / 2 / W, (top + bottom) / 2 / H, (rx - lx) / W, (bottom - top) / H)
    sub = bl[::f, ::f][:gh, :gw][ry0:ry1, rx0:rx1] * m[ry0:ry1, rx0:rx1]
    if sub.size == 0 or float(sub.max()) <= 0:
        return None
    sy, sx = np.unravel_index(int(np.argmax(sub)), sub.shape)
    sy, sx = sy + ry0, sx + rx0
    seen = np.zeros_like(m, dtype=bool)
    seen[sy, sx] = True
    dq = deque([(sy, sx)])
    ys, xs = [], []
    while dq:
        yy, xx = dq.popleft()
        ys.append(yy); xs.append(xx)
        for ny in (yy - 1, yy, yy + 1):
            for nx in (xx - 1, xx, xx + 1):
                if 0 <= ny < gh and 0 <= nx < gw and m[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    dq.append((ny, nx))
    if len(ys) * f * f < 30:
        return None
    ys = np.array(ys) * f + y0 + f / 2
    xs = np.array(xs) * f + x0 + f / 2
    if o["kind"] == "f":                    # muzzle blast: no smoke column, just the blast region
        lx, rx = float(np.percentile(xs, 3)), float(np.percentile(xs, 97)) + f / 2
        top, bottom = float(np.percentile(ys, 3)), float(np.percentile(ys, 97)) + f / 2
        if rx - lx < 4 or bottom - top < 4:
            return None
        return ((lx + rx) / 2 / W, (top + bottom) / 2 / H, (rx - lx) / W, (bottom - top) / H)
    top = float(np.percentile(ys, 1))
    span = max(iy - top, 8.0)
    # width: the strong core of the smoke column, in the rows clearly above the impact point
    # (dust stays low and is faint)
    core = (bl[::f, ::f][:gh, :gw] > max(25.0, EXP_CORE_REL * peak))
    cy_, cx_ = np.nonzero(core & seen)
    cy_, cx_ = cy_ * f + y0 + f / 2, cx_ * f + x0 + f / 2
    col = cy_ < iy - 0.12 * span
    if col.sum() >= 4:
        lx, rx = float(np.percentile(cx_[col], 1)), float(np.percentile(cx_[col], 99))
    elif len(cx_) >= 4:
        lx, rx = float(np.percentile(cx_, 2)), float(np.percentile(cx_, 98))
    else:
        lx, rx = float(np.percentile(xs, 5)), float(np.percentile(xs, 95))
    # the fireball at the bottom counts too
    fb = (fire[::f, ::f][:gh, :gw] > 0.5) & m
    if fb.any():
        fy, fx = np.nonzero(fb)
        fy, fx = fy * f + y0, fx * f + x0
        near = (np.abs(fx - ix) < max(rx - lx, w)) & (fy > top) & (fy < iy + 0.3 * span)
        if near.any():
            lx, rx = min(lx, float(fx[near].min())), max(rx, float(fx[near].max()) + f)
    bottom = min(float(ys.max()) + f / 2, iy + 0.08 * span + 4)
    if rx - lx < 4 or bottom - top < 4:
        return None
    ratio = ((rx - lx) * (bottom - top)) / max(w * h, 1.0)
    if ratio < 0.02 or ratio > 8:
        return None
    return ((lx + rx) / 2 / W, (top + bottom) / 2 / H, (rx - lx) / W, (bottom - top) / H)


# ---------------------------------------------------------------- split / names
def pick_split(rec: dict, mode: str, val_regions: set[int], test_regions: set[int]) -> str:
    if mode == "region":
        r = int(rec.get("region", 0))
        return "test" if r in test_regions else "val" if r in val_regions else "train"
    key = f'{rec["session"]}|{rec.get("scene")}|{rec.get("seed")}'.encode()
    h = int(hashlib.md5(key).hexdigest(), 16) % 10
    return "test" if h == 0 else "val" if h == 1 else "train"


def out_name(rec: dict) -> str:
    return f'{rec["session"]}_{Path(rec["image"].replace(chr(92), "/")).stem}'


KEYPOINT_TYPES = ("soldier", "tank", "military_vehicle", "explosion")    # ground point is meaningful for these


def keypoint_field(e: dict, W: int, H: int) -> str:
    """--pose: one keypoint = the ground point (feet / terrain under the hull / impact point), YOLO-pose 'x y v'."""
    g = e.get("ground_px")
    if e["type"] in KEYPOINT_TYPES and g and 0 <= g[0] < W and 0 <= g[1] < H:
        return f"{g[0] / W:.6f} {g[1] / H:.6f} 2"
    return "0.000000 0.000000 0"


def write_yaml(out: Path, classes: list[str], pose: bool = False):
    lines = [f"path: {out.resolve().as_posix()}", "train: images/train", "val: images/val", "test: images/test"]
    if pose:   # YOLO-pose: one keypoint per object (the ground point), no left/right pairs to swap when flipping
        lines += ["kpt_shape: [1, 3]", "flip_idx: [0]"]
    lines += [f"nc: {len(classes)}", "names:"] + [f"  {i}: {n}" for i, n in enumerate(classes)]
    (out / "data.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------- soldiers without a tight box
# When the body-part and hit-point boxes both fail, a soldier keeps ONE 3D box around his body, which
# seen from above at an angle is loose at the bottom (10-40 % of its height) and a bit too wide. Every
# soldier logs both boxes, so the tool learns how to turn the 3D box into the tight one (per stance,
# depending on the camera pitch) and applies it to those soldiers.

CAL_MIN_PAIRS = 40


def _stance_key(o: dict) -> str:
    s = (o.get("stance_raw") or "").upper()
    return s if s in ("STAND", "CROUCH", "PRONE") else "ANY"


def _edges(cx, cy, w, h):
    return cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2


def fit_box_calibration(records: list[dict]) -> dict:
    """Learn tight-box edges from the 3D box: per stance, each edge offset (in units of the 3D
    box width / height) = a + b * |pitch|/90, least squares. -> {stance: {...}} (only with enough pairs)."""
    import statistics
    pairs: dict[str, list] = {}
    for rec in records:
        p = rec["cam"]["pitch"]
        for o in rec["objects"]:
            if o["kind"] != "s" or not o.get("box_3d") or o.get("soldier_box") == "3d_box" or o.get("inside_building"):
                continue
            ox0, oy0, ox1, oy1 = _edges(*o["box_3d"])
            tx0, ty0, tx1, ty1 = _edges(o["cx"], o["cy"], o["w"], o["h"])
            ow, oh = ox1 - ox0, oy1 - oy0
            if ow <= 0 or oh <= 0 or ox0 < 0 or oy0 < 0 or ox1 > 1 or oy1 > 1:
                continue                      # cut by the image edge: the boxes are not comparable
            row = (abs(p) / 90.0, (tx0 - ox0) / ow, (ox1 - tx1) / ow, (ty0 - oy0) / oh, (oy1 - ty1) / oh)
            pairs.setdefault(_stance_key(o), []).append(row)
            pairs.setdefault("ANY", []).append(row)
    cal = {}
    for st, rows in pairs.items():
        if len(rows) < CAL_MIN_PAIRS:
            continue
        xs = [r[0] for r in rows]
        mx = sum(xs) / len(xs)
        sxx = sum((x - mx) ** 2 for x in xs)
        coef, resid = [], []
        for k in range(1, 5):
            ys = [r[k] for r in rows]
            my = sum(ys) / len(ys)
            b = (sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx) if sxx > 1e-9 else 0.0
            a = my - b * mx
            coef.append([round(a, 5), round(b, 5)])
            resid.append(round(statistics.median(abs(y - (a + b * x)) for x, y in zip(xs, ys)), 4))
        cal[st] = {"pairs": len(rows), "edges": ["left", "right", "top", "bottom"], "coef_a_b": coef,
                   "median_residual_of_3d_box_size": resid}
    return cal


def apply_box_calibration(rec: dict, cal: dict, stats: Counter):
    """Tighten the one-3D-box soldier boxes of a picture with the learned calibration."""
    p = rec["cam"]["pitch"]
    for o in rec["objects"]:
        if o["kind"] != "s" or o.get("soldier_box") != "3d_box":
            continue
        c = cal.get(_stance_key(o)) or cal.get("ANY")
        if c is None:
            stats["soldier_box_loose"] += 1
            continue
        x = abs(p) / 90.0
        dl, dr, dt, db = (a + b * x for a, b in c["coef_a_b"])
        x0, y0, x1, y1 = _edges(o["cx"], o["cy"], o["w"], o["h"])
        w, h = x1 - x0, y1 - y0
        nx0, nx1, ny0, ny1 = x0 + dl * w, x1 - dr * w, y0 + dt * h, y1 - db * h
        if nx1 - nx0 < 0.2 * w or ny1 - ny0 < 0.2 * h:
            stats["soldier_box_loose"] += 1
            continue
        o["cx"], o["cy"], o["w"], o["h"] = (nx0 + nx1) / 2, (ny0 + ny1) / 2, nx1 - nx0, ny1 - ny0
        o["soldier_box"] = "corrected_3d_box"
        stats["soldier_box_corrected"] += 1


def image_ok(p: Path) -> bool:
    """True if the PNG decodes completely (Arma can leave half-written files, a crash can leave
    files full of zeros)."""
    from PIL import Image
    try:
        if p.stat().st_size < 1000:
            return False
        with open(p, "rb") as fh:
            if fh.read(8) != b"\x89PNG\r\n\x1a\n":
                return False
        with Image.open(p) as im:
            im.convert("RGB").load()
        return True
    except Exception:
        return False


def green_fraction(p) -> float | None:
    """Share of the picture that is green (vegetation): hue 60-170 deg, not grey, not dark. p = path or PIL image."""
    from PIL import Image
    try:
        if isinstance(p, Image.Image):
            hsv = p.convert("RGB").resize((192, 108)).convert("HSV")
        else:
            with Image.open(p) as im:
                hsv = im.convert("RGB").resize((192, 108)).convert("HSV")
        raw = hsv.tobytes()
    except Exception:
        return None
    n = len(raw) // 3
    g = sum(1 for i in range(0, n * 3, 3) if 42 <= raw[i] <= 120 and raw[i + 1] >= 26 and raw[i + 2] >= 30)   # PIL HSV is 0..255
    return round(g / max(n, 1), 4)


def image_size(p: Path) -> tuple[int, int]:
    from PIL import Image
    with Image.open(p) as im:
        return im.size


def build_meta(rec: dict, name: str, split: str, W: int, H: int, classes: list[str], scheme: str, ref_rel: str | None) -> dict:
    cam = rec.get("cam") or {}
    laser = rec.get("laser")
    gsd = None
    if laser and laser.get("range") and cam.get("hfov"):
        gsd = 2 * float(laser["range"]) * math.tan(math.radians(float(cam["hfov"]) / 2)) / W
    burst = rec.get("burst")
    objs = []
    for o in rec["objects"]:
        cname = class_name(o, scheme, W, H)
        x0, y0 = (o["cx"] - o["w"] / 2) * W, (o["cy"] - o["h"] / 2) * H
        x1, y1 = (o["cx"] + o["w"] / 2) * W, (o["cy"] + o["h"] / 2) * H
        e = {"class": cname, "class_id": classes.index(cname), "type": KIND_NAME[o["kind"]],
             "object_id": o["object_id"], "box_norm": {k: round(o[k], 6) for k in ("cx", "cy", "w", "h")},
             "box_px": [round(x0, 1), round(y0, 1), round(x1, 1), round(y1, 1)],
             "size": size_category(o, W, H), "visible": o["visible"], "cut_by_edge": o["cut_by_edge"],
             "grid": o["grid"], "distance_m": o["distance_m"]}
        e["ground_pos_asl"] = o["ground_pos_asl"]
        if o.get("ground_norm"):
            e["ground_px"] = [round(o["ground_norm"][0] * W, 2), round(o["ground_norm"][1] * H, 2)]
        if o["kind"] == "s":
            e["box_method"] = o.get("soldier_box", "3d_box")
            e["stance"] = stance_of(o, W, H)
            e["stance_source"] = o["stance_source"]
            e["inside_building"] = o["inside_building"]
        if o["kind"] in ("e", "f"):
            e["box_method"] = o.get("box_method", "estimated")
        objs.append(e)
    return {
        "image": f"images/{split}/{name}.png", "source_screenshot": rec["image"], "width": W, "height": H,
        "session": rec["session"], "frame": rec.get("frame"), "t_game": rec.get("t_game"),
        "world": rec.get("world"), "scene": rec.get("scene"), "seed": rec.get("seed"), "region": rec.get("region"),
        "camera": {"pos_asl": cam.get("pos_asl"), "grid": cam.get("grid"),
                   "alt_asl_m": cam.get("alt_asl"), "alt_agl_m": cam.get("alt_agl"),
                   "heading_deg": cam.get("hdg"), "pitch_deg": cam.get("pitch"), "bank_deg": cam.get("bank"),
                   "hfov_deg": cam.get("hfov"), "vfov_deg": cam.get("vfov"),
                   "right_axis": cam.get("x_axis"), "up_axis": cam.get("y_axis"), "forward_axis": cam.get("z_axis")},
        "intrinsics": ({"fx": round((W / 2) / math.tan(math.radians(float(cam["hfov"]) / 2)), 3),
                        "fy": round((H / 2) / math.tan(math.radians(float(cam["vfov"]) / 2)), 3),
                        "cx": W / 2, "cy": H / 2,
                        "note": "pinhole; pixel (u, v) from the top-left corner; ray = forward + right*(u-cx)/fx - up*(v-cy)/fy"}
                       if cam.get("hfov") and cam.get("vfov") else None),
        "projection_check_px": cam.get("proj_check_px"),
        "laser_rangefinder": laser,
        "gsd_center_m_per_px": round(gsd, 5) if gsd else None,
        "scale_lock": rec.get("scale_lock"), "target_gsd": rec.get("target_gsd"),
        "environment": {"time_label": rec.get("time_label"), "daytime_h": rec.get("daytime"), "weather": rec.get("weather")},
        "class_scheme": scheme, "classes": classes,
        "objects": objs,
        "building_occupancy": rec.get("occupancy") or [],
        "explosion_reference_image": ref_rel,
        # pictures of one burst were taken from the same camera position, 2 s apart
        "burst": ({"id": burst, "index": int(rec.get("burst_idx") or 0) + 1, "length": rec.get("burst_len")}
                  if isinstance(burst, (int, float)) and burst >= 0 else None),
        "ground_surface": rec.get("surface") or None,
        "green_fraction": rec.get("_green"),
        "buildings_in_picture": sum(1 for o in rec["objects"] if o["kind"] == "b"),
        # generator stage the picture was taken in (ZPI_cfg_tourPlan: far, tank_fire, prone, ...; "" = normal run)
        "tour_stage": rec.get("stage") or None,
        "terrain_grid": rec.get("terrain_grid"),
        # [u, v, x, y, z, kind, object_id]: what the image point (u, v normalized) really hits;
        # kind g ground, b building, t tree/bush, e scene object, o other
        "pixel_rays": rec.get("pixel_rays"),
    }


def draw_preview(img_path: Path, meta: dict, dst: Path):
    from PIL import Image, ImageDraw
    im = Image.open(img_path).convert("RGB")
    W, H = im.size
    d = ImageDraw.Draw(im)
    lw = max(1, W // 960)
    for e in meta["objects"]:
        col = COLORS[e["class_id"] % len(COLORS)]
        x0, y0, x1, y1 = e["box_px"]
        d.rectangle([x0, y0, x1, y1], outline=col, width=lw)
        tag = e["class"] + (" IN" if e.get("inside_building") else "") + (" (measured)" if e.get("box_method") == "image_difference" else "")
        d.text((x0 + 2, max(0, y0 - 11 * lw)), tag, fill=col)
    lr = meta.get("laser_rangefinder")
    info = f"{meta.get('scene')}  FOV {meta['camera'].get('hfov_deg')}  GSD {meta.get('gsd_center_m_per_px')} m/px"
    if meta.get("burst"):
        info += f"  burst {meta['burst']['id']} shot {meta['burst']['index']}/{meta['burst']['length']}"
    if lr:
        info += f"  laser {lr.get('range')} m"
    d.text((6, H - 16 * lw), info, fill=(255, 255, 255))
    dst.parent.mkdir(parents=True, exist_ok=True)
    im.save(dst, quality=85)


# ---------------------------------------------------------------- main processing
def process(records: list[dict], shot_dirs: list[Path], out: Path, args, seen: set[str], stats: Counter) -> int:
    for s in SPLITS:
        (out / "images" / s).mkdir(parents=True, exist_ok=True)
        (out / "labels" / s).mkdir(parents=True, exist_ok=True)
    (out / "meta").mkdir(exist_ok=True)
    classes = SCHEMES[args.classes]
    added = 0
    for rec in records:
        name = out_name(rec)
        if name in seen:
            continue
        if not rec["ok"]:
            seen.add(name); stats["screenshot_failed"] += 1
            continue
        src = zpi_paths.find_image(rec["image"], shot_dirs)
        if src is None:
            stats["image_missing"] += 1
            continue                       # maybe not written yet: retried in --watch mode
        if not image_ok(src):
            if time.time() - src.stat().st_mtime < 15:
                continue                   # probably still being written: try again later
            seen.add(name)
            stats["image_broken"] += 1
            BROKEN.append(src)
            continue
        # pictures with too many buildings (village views) are left out
        nb = sum(1 for o in rec["objects"] if o["kind"] == "b")
        if args.max_buildings >= 0 and nb > args.max_buildings:
            seen.add(name); stats["skipped_too_many_buildings"] += 1
            continue
        # haze / exposure correction (tools/zpi_enhance.py); labels are unchanged
        enhanced = None
        if args.enhance:
            try:
                from PIL import Image
                from zpi_enhance import enhance
                with Image.open(src) as im:
                    enhanced = enhance(im)
            except Exception:
                # damaged picture that slipped through the check (e.g. the PC crashed while saving)
                seen.add(name)
                stats["image_broken"] += 1
                BROKEN.append(src)
                continue
        rec["_green"] = green_fraction(enhanced if enhanced is not None else src)
        if args.min_green > 0 and rec["_green"] is not None and rec["_green"] < args.min_green:
            seen.add(name); stats["skipped_not_green"] += 1
            continue
        seen.add(name)
        W, H = image_size(src)

        # explosions: measure the box from the reference picture when there is one
        ref_rel = rec.get("ref_image") or None
        ref = zpi_paths.find_image(ref_rel, shot_dirs) if ref_rel else None
        for o in rec["objects"]:
            if o["kind"] not in ("e", "f"):
                continue
            what = "explosion" if o["kind"] == "e" else "tank_fire"
            o["box_method"] = "estimated"
            if ref is not None:
                try:
                    box = explosion_box_from_diff(ref, src, o, rec["objects"])
                except Exception:
                    box = None
                if box:
                    o["cx"], o["cy"], o["w"], o["h"] = box
                    o["box_method"] = "image_difference"
                    stats[f"{what}_measured"] += 1
                else:
                    stats[f"{what}_estimated"] += 1
            else:
                stats[f"{what}_estimated"] += 1

        if args.box_calibration:
            apply_box_calibration(rec, args.box_calibration, stats)
        for o in rec["objects"]:
            if o["kind"] == "s":
                stats["soldier_box_" + {"body_parts": "tight", "hit_point_parts": "tight_hitpoints"}.get(o.get("soldier_box"), "x")] += 1
        stats.pop("soldier_box_x", None)

        split = pick_split(rec, args.split, args.val_regions, args.test_regions)
        if enhanced is not None:
            enhanced.save(out / "images" / split / f"{name}.png", compress_level=3)
        else:
            shutil.copy2(src, out / "images" / split / f"{name}.png")
        meta = build_meta(rec, name, split, W, H, classes, args.classes, ref_rel)
        meta["haze_corrected"] = enhanced is not None
        with open(out / "labels" / split / f"{name}.txt", "w", encoding="utf-8") as lf:
            for e in meta["objects"]:
                b = e["box_norm"]
                line = f"{e['class_id']} {b['cx']:.6f} {b['cy']:.6f} {b['w']:.6f} {b['h']:.6f}"
                if args.pose:
                    line += " " + keypoint_field(e, W, H)
                lf.write(line + "\n")
        (out / "meta" / f"{name}.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
        if args.previews and stats["previews"] < args.previews:
            try:
                draw_preview(out / "images" / split / f"{name}.png", meta, out / "previews" / f"{name}.jpg")
                stats["previews"] += 1
            except Exception:
                pass
        stats[split] += 1
        added += 1
    return added


def report_box_fit(out: Path):
    """How far the bottom of a standing soldier's box is below his feet (ground point), per box method.
    Tight boxes: a few % of the box height (toes, boots). One 3D box: 10-40 %."""
    import statistics
    groups: dict[str, list] = {}
    for mp in (out / "meta").glob("*.json"):
        try:
            m = json.loads(mp.read_text(encoding="utf-8"))
        except Exception:
            continue
        for o in m.get("objects", []):
            if o.get("type") != "soldier" or o.get("stance") != "standing" or o.get("inside_building") or not o.get("ground_px"):
                continue
            x0, y0, x1, y1 = o["box_px"]
            h = y1 - y0
            if h < 12 or y1 >= m["height"] - 1 or y0 <= 0:
                continue
            gx, gy = o["ground_px"]
            groups.setdefault(o.get("box_method", "3d_box"), []).append(((y1 - gy) / h, (x0 + x1) / 2 - gx))
    if not groups:
        return
    print("\nstanding soldiers, box bottom below the feet (share of box height) / box centre right of the feet (px):")
    for k, v in sorted(groups.items()):
        print(f"  {k:<18} {len(v):5d} boxes   bottom {statistics.median(r[0] for r in v):+.2f}   centre {statistics.median(r[1] for r in v):+.1f} px")


def write_manifest(out: Path, classes: list[str]):
    """Rebuild manifest.csv from what is actually in the dataset (always consistent)."""
    rows = []
    for s in SPLITS:
        for img in sorted((out / "images" / s).glob("*.png")):
            mp = out / "meta" / f"{img.stem}.json"
            m = json.loads(mp.read_text(encoding="utf-8")) if mp.exists() else {}
            c = Counter(e["class"] for e in m.get("objects", []))
            env = m.get("environment", {})
            b = m.get("burst") or {}
            rows.append([img.stem, s, m.get("scene"), m.get("seed"), m.get("region"), m.get("camera", {}).get("hfov_deg"),
                         m.get("gsd_center_m_per_px"), env.get("time_label"), env.get("weather"), m.get("scale_lock"),
                         sum(c.values())] + [c.get(n, 0) for n in classes]
                        + [b.get("id", ""), b.get("index", ""), m.get("green_fraction"), m.get("ground_surface"), m.get("tour_stage") or ""])
    with open(out / "manifest.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["name", "split", "scene", "seed", "region", "hfov_deg", "gsd_m_per_px", "time", "weather",
                    "scale_lock", "n_boxes"] + classes + ["burst", "burst_shot", "green_fraction", "ground_surface", "tour_stage"])
        w.writerows(rows)
    return rows


# ---------------------------------------------------------------- Roboflow export
RF_SPLIT = {"train": "train", "val": "valid", "test": "test"}   # Roboflow folder names
RF_MAX_BYTES = 1_800_000_000      # stay under the 2 GB zip limit
RF_MAX_FILES = 9_000              # stay under the 10,000 files limit (2 files per image)


def rf_yaml(classes: list[str]) -> str:
    names = ", ".join(f"'{n}'" for n in classes)
    return (f"train: ../train/images\nval: ../valid/images\ntest: ../test/images\n\n"
            f"nc: {len(classes)}\nnames: [{names}]\n")


def export_roboflow(out: Path, jpg: bool, classes: list[str], quality: int = 92) -> list[Path]:
    """Zip the dataset in Roboflow's YOLO layout, in parts that fit the upload limits."""
    for old in out.glob("roboflow_part*.zip"):
        old.unlink()
    items = []
    for split in SPLITS:
        for img in sorted((out / "images" / split).glob("*.png")):
            items.append((split, img, out / "labels" / split / f"{img.stem}.txt"))
    if not items:
        print("roboflow: dataset is empty, nothing to export")
        return []
    if jpg:
        from PIL import Image
        import io
    parts: list[Path] = []
    zf = None
    size = files = 0
    counts: Counter = Counter()

    def new_part():
        nonlocal zf, size, files
        if zf:
            zf.close()
        path = out / f"roboflow_part{len(parts) + 1:02d}.zip"
        parts.append(path)
        zf = zipfile.ZipFile(path, "w", zipfile.ZIP_STORED)   # PNG/JPEG are already compressed
        zf.writestr("data.yaml", rf_yaml(classes))
        size, files = 0, 1

    new_part()
    for split, img, lab in items:
        if jpg:
            buf = io.BytesIO()
            Image.open(img).convert("RGB").save(buf, "JPEG", quality=quality)
            data, ext = buf.getvalue(), ".jpg"
        else:
            data, ext = img.read_bytes(), ".png"
        label = lab.read_text(encoding="utf-8") if lab.exists() else ""
        if files > 1 and (size + len(data) > RF_MAX_BYTES or files + 2 > RF_MAX_FILES):
            new_part()
        folder = RF_SPLIT[split]
        zf.writestr(f"{folder}/images/{img.stem}{ext}", data)
        zf.writestr(f"{folder}/labels/{img.stem}.txt", label)
        size += len(data) + len(label)
        files += 2
        counts[folder] += 1
    zf.close()
    summary = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"roboflow: {len(items)} images ({summary}) -> " + ", ".join(p.name for p in parts))
    return parts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpt", action="append", help="RPT log file (repeatable; default: all logs in %%LOCALAPPDATA%%\\Arma 3)")
    ap.add_argument("--shots", action="append", help="Screenshots folder (repeatable; default: the Screenshots folder of this mission's Arma profile)")
    ap.add_argument("--out", default="dataset", help="output folder; a plain name goes into the mission's output\\ folder")
    ap.add_argument("--classes", choices=sorted(SCHEMES), default="stance", help="class scheme (see top of file)")
    ap.add_argument("--split", choices=["auto", "region", "scene"], default="auto")
    ap.add_argument("--val-regions", default="2", help="comma list, used with --split region")
    ap.add_argument("--test-regions", default="3", help="comma list, used with --split region")
    ap.add_argument("--limit", type=int, help="use only the first N screenshots (in the order they were taken)")
    ap.add_argument("--latest", action="store_true", help="use only the newest session (the last mission start) in the logs")
    ap.add_argument("--session", action="append", help="use only this session (folder name under Screenshots\\zpi, repeatable)")
    ap.add_argument("--previews", type=int, default=300, help="how many preview images with boxes to draw (0 = none)")
    ap.add_argument("--watch", action="store_true", help="keep running and add new screenshots as they appear (Ctrl+C to stop)")
    ap.add_argument("--roboflow", action="store_true", help="also write roboflow_partNN.zip files ready to upload")
    ap.add_argument("--jpg", action="store_true", help="with --roboflow: store images as JPEG (much smaller zips)")
    ap.add_argument("--no-enhance", dest="enhance", action="store_false",
                    help="copy the screenshots unchanged (default: haze / exposure correction, see tools/zpi_enhance.py)")
    ap.add_argument("--pose", action="store_true",
                    help="YOLO-pose labels: every box also gets one keypoint, the ground point (feet / under the hull / "
                         "impact point); train with a -pose model so the detector predicts the ground point directly")
    ap.add_argument("--no-box-fix", dest="box_fix", action="store_false",
                    help="keep the loose one-3D-box soldier boxes as they are")
    ap.add_argument("--max-buildings", type=int, default=3,
                    help="leave out pictures with more labelled buildings than this (default 3, -1 = keep all)")
    ap.add_argument("--min-green", type=float, default=0.0,
                    help="leave out pictures with less green than this share, 0..1 (default 0 = keep all; "
                         "see green_fraction in manifest.csv)")
    args = ap.parse_args()

    rpts = [Path(r) for r in args.rpt] if args.rpt else default_rpts()
    shot_dirs = [Path(s) for s in args.shots] if args.shots else [zpi_paths.SCREENSHOT_DIR]
    out = zpi_paths.out_path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    print(f"dataset folder: {out}")
    classes = SCHEMES[args.classes]

    # one dataset = one class scheme (mixing would scramble the class numbers)
    scheme_file = out / "scheme.txt"
    scheme = args.classes + ("+pose" if args.pose else "")
    old_scheme = scheme_file.read_text(encoding="utf-8").strip() if scheme_file.exists() else None
    if old_scheme and old_scheme != scheme:
        sys.exit(f"'{out}' was built with class scheme '{old_scheme}', not '{scheme}'.\n"
                 f"Delete the folder (everything is rebuilt from the logs) or use --out with another folder name.")
    scheme_file.write_text(scheme + "\n", encoding="utf-8")
    write_yaml(out, classes, args.pose)
    args.val_regions = {int(x) for x in args.val_regions.split(",") if x.strip()}
    args.test_regions = {int(x) for x in args.test_regions.split(",") if x.strip()}

    # already-exported images (re-running is safe and incremental); drop broken ones
    seen = set()
    removed = 0
    for s in SPLITS:
        for p in (out / "images" / s).glob("*.png"):
            if image_ok(p):
                seen.add(p.stem)
            else:
                p.unlink()
                for extra in (out / "labels" / s / f"{p.stem}.txt", out / "meta" / f"{p.stem}.json", out / "previews" / f"{p.stem}.jpg"):
                    if extra.exists():
                        extra.unlink()
                removed += 1
    if removed:
        print(f"removed {removed} broken image(s) from the dataset")
    stats: Counter = Counter()
    stats["previews"] = len(list((out / "previews").glob("*.jpg"))) if (out / "previews").exists() else 0

    diag: Counter = Counter()
    records = read_labels(rpts, diag)
    # soldiers whose tight box failed (one 3D box): learn the correction from soldiers that have both boxes
    args.box_calibration = fit_box_calibration(records) if args.box_fix else {}
    n_loose = sum(1 for r in records for o in r["objects"] if o["kind"] == "s" and o.get("soldier_box") == "3d_box")
    if args.box_calibration:
        (out / "box_calibration.json").write_text(json.dumps(args.box_calibration, indent=1), encoding="utf-8")
        print("soldier box correction (for soldiers without a tight box) learned from "
              + ", ".join(f"{k} {v['pairs']}" for k, v in args.box_calibration.items()) + " pairs (box_calibration.json)")
    elif n_loose and args.box_fix:
        print(f"NOTE: {n_loose} soldier boxes are one 3D box (loose at the bottom, the tight box failed). They are corrected\n"
              f"      once the logs have {CAL_MIN_PAIRS}+ soldiers with both boxes.")
    sessions_all = list(dict.fromkeys(r["session"] for r in records))
    if args.latest and sessions_all:
        args.session = [sessions_all[-1]]
    if args.session:
        records = [r for r in records if r["session"] in set(args.session)]
        print(f"sessions used: {', '.join(args.session)} (of {len(sessions_all)} in the logs)")
    if args.limit:
        records = [r for r in records if r["ok"]][:args.limit]
        print(f"limited to the first {len(records)} screenshots")
    if args.split == "auto":
        regions = {int(r.get("region", 0)) for r in records}
        args.split = "region" if len(regions - {-1}) >= 2 else "scene"
    print(f"logs read: {len(rpts)} file(s) in {rpts[-1].parent}")
    print(f"screenshot folders: {', '.join(map(str, shot_dirs))}")
    print(f"labelled shots in logs: {len(records)}  (label lines {diag['label_lines']}, cut-off lines "
          f"{diag['cut_off_lines']}, unreadable lines {diag['invalid_lines']}, incomplete shots {diag['incomplete_shots']})")
    print(f"classes: {args.classes} -> {', '.join(classes)}")
    print(f"split: {args.split}")

    try:
        while True:
            added = process(records, shot_dirs, out, args, seen, stats)
            if added or not args.watch:
                summary = ", ".join(f"{k}={v}" for k, v in sorted(stats.items()) if v)
                print(f"[{time.strftime('%H:%M:%S')}] +{added} images  ({summary})")
            if not args.watch:
                break
            time.sleep(3)
            records = read_labels(rpts if args.rpt else default_rpts())
            if args.session:
                records = [r for r in records if r["session"] in set(args.session)]
            if args.limit:
                records = [r for r in records if r["ok"]][:args.limit]
            stats["image_missing"] = 0
    except KeyboardInterrupt:
        print("stopped")

    rows = write_manifest(out, classes)
    tot = Counter()
    for r in rows:
        tot[r[1]] += 1
        for i, n in enumerate(classes):
            tot[n] += r[11 + i]
    print(f"\ndataset now: {len(rows)} images (train {tot['train']}, val {tot['val']}, test {tot['test']})")
    print("boxes: " + ", ".join(f"{n} {tot[n]}" for n in classes))
    # pictures that contain each class (what the per-class targets of the generator plan count)
    pics = Counter()
    for r in rows:
        for i, n in enumerate(classes):
            pics[n] += r[11 + i] > 0
    print("pictures with: " + ", ".join(f"{n} {pics[n]}" for n in classes)
          + f", none (background) {sum(1 for r in rows if r[10] == 0)}")
    stages = Counter(r[-1] for r in rows if r[-1])
    if stages:
        print("pictures per generator stage: " + ", ".join(f"{k} {v}" for k, v in stages.items()))

    report_box_fit(out)
    if args.roboflow:
        export_roboflow(out, args.jpg, classes)

    # ---- explain anything that went wrong, in plain words
    if diag["label_lines"] == 0:
        print("\nNO LABELS FOUND in the logs. Did you press P in the mission?\n"
              "Was the game started with logs turned off (No Logs / -noLogs)?")
    if diag["cut_off_lines"] or diag["incomplete_shots"]:
        print(f"\nWARNING: {diag['cut_off_lines']} log lines were cut off; {diag['incomplete_shots']} shots were skipped "
              f"(their labels would be incomplete). Lower ZPI_cfg_labelsPerLine in zpi\\config.sqf.")
    if diag["invalid_lines"]:
        print(f"\nWARNING: {diag['invalid_lines']} lines could not be read. Please send this example:\n  {diag['example']}")
    if stats["image_missing"]:
        miss = [r for r in records if r["ok"] and zpi_paths.find_image(r["image"], shot_dirs) is None]
        print(f"\nWARNING: {stats['image_missing']} labelled shots have no image file.")
        if miss:
            print(f"  e.g. looked for: {shot_dirs[0] / miss[0]['image'].replace(chr(92), '/')}")
        print('  Pass the Screenshots folder, e.g.\n'
              '  python tools/make_yolo_dataset.py --shots "C:\\Users\\you\\Documents\\Arma 3\\Screenshots"')
    if BROKEN:
        print(f"\nWARNING: {len(BROKEN)} screenshot file(s) are broken (half-written) and were skipped:")
        for b in BROKEN[:5]:
            print(f"  {b}")
        print("  Usually the game was closed while saving, or the Screenshots folder hit its size limit.")
    if (out / "previews").exists():
        print(f"\npreviews: {(out / 'previews').resolve()}")
    print(f"per-screenshot JSON: {(out / 'meta').resolve()}")


if __name__ == "__main__":
    main()
