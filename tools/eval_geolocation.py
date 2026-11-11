#!/usr/bin/env python3
"""
Localisation error of "pixel -> world" on the Arma dataset, split by error source.

For every object in every picture the box's bottom-centre pixel is turned into a ray of the
pinhole camera (camera pose + FOV from the picture's JSON) and intersected with the terrain
(the DEM patch saved with the picture). The hit is compared with the object's true ground point.

    step 1  geometry   true ground point -> pixel -> back onto the DEM. Must be ~0: checks the
                       camera model, the axes and the DEM. Objects on floors/roofs are left out.
    step 2  labels     bottom-centre of the ground-truth (label) box -> DEM: geometry + the offset
                       between the box bottom and the true ground point.
    step 3  detector   bottom-centre of YOLO detections (--pred) matched to the labels by IoU:
                       everything above + detection error.

Errors are horizontal (map plane) distances in metres. CEP50 = radius that holds 50 % of the
estimates around the truth = median horizontal error; CEP90 = 90th percentile. Also split into
"along" (along the camera heading = range direction) and "across" components.

Usage (from the mission folder; --dataset and --out are folders inside <mission>\\output\\ unless absolute):
    python tools/eval_geolocation.py                          # output\\dataset -> output\\geoloc_eval
    python tools/eval_geolocation.py --dataset run1 --out geoloc_run1
    python tools/eval_geolocation.py --pred runs/detect/predict/labels --iou 0.5   # --pred: relative to the current folder
    python tools/eval_geolocation.py --square-pixels     # vfov from hfov and the aspect ratio
    python tools/eval_geolocation.py --anchor keypoint --pred runs/pose/predict/labels   # YOLO-pose: predicted ground point

--anchor keypoint (dataset built with make_yolo_dataset.py --pose, model trained as YOLO-pose): step 2
uses the labelled ground point itself (= step 1), step 3 the keypoint the detector predicts.
Output: <out>/per_object.csv, <out>/summary.json and a table on screen.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zpi_paths  # noqa: E402

TYPES = ("soldier", "tank", "military_vehicle", "explosion", "tank_fire", "building")
# --anchor center: the box centre is assumed to be this high above the ground (m)
HALF_HEIGHT = {"soldier": 0.9, "tank": 1.2, "military_vehicle": 1.2, "explosion": 3.0, "tank_fire": 2.0, "building": 3.0}


# ---------------------------------------------------------------- small vector helpers
def sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def add(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def mul(a, k): return [a[0] * k, a[1] * k, a[2] * k]
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def norm(a):
    n = math.sqrt(dot(a, a))
    return [a[0] / n, a[1] / n, a[2] / n]


# ---------------------------------------------------------------- camera
class Camera:
    def __init__(self, meta: dict, square_pixels: bool = False):
        c = meta["camera"]
        self.W, self.H = meta["width"], meta["height"]
        self.o = c["pos_asl"]
        self.r, self.u, self.f = c["right_axis"], c["up_axis"], c["forward_axis"]
        self.tx = math.tan(math.radians(c["hfov_deg"]) / 2)
        self.ty = self.tx * self.H / self.W if square_pixels else math.tan(math.radians(c["vfov_deg"]) / 2)
        self.heading = math.atan2(self.f[0], self.f[1])

    def project(self, p):
        """world ASL -> pixel (x right, y down), None if behind the camera"""
        d = sub(p, self.o)
        zc = dot(d, self.f)
        if zc <= 0.1:
            return None
        un = 0.5 + dot(d, self.r) / (zc * 2 * self.tx)
        vn = 0.5 - dot(d, self.u) / (zc * 2 * self.ty)
        return un * self.W, vn * self.H

    def ray(self, px, py):
        un, vn = px / self.W, py / self.H
        return norm(add(add(self.f, mul(self.r, (2 * un - 1) * self.tx)), mul(self.u, (1 - 2 * vn) * self.ty)))


# ---------------------------------------------------------------- terrain
class Terrain:
    """Bilinear DEM from the picture's terrain grid."""

    def __init__(self, meta: dict):
        g = meta["terrain_grid"]
        self.x0, self.y0, self.d = g["x0"], g["y0"], g["spacing_m"]
        self.h = g["heights_asl"]
        self.nx, self.ny = len(self.h[0]), len(self.h)

    def height(self, x, y):
        fx = min(max((x - self.x0) / self.d, 0), self.nx - 1.000001)
        fy = min(max((y - self.y0) / self.d, 0), self.ny - 1.000001)
        i, j = int(fx), int(fy)
        ax, ay = fx - i, fy - j
        h = self.h
        return ((h[j][i] * (1 - ax) + h[j][i + 1] * ax) * (1 - ay) +
                (h[j + 1][i] * (1 - ax) + h[j + 1][i + 1] * ax) * ay)

    def intersect(self, o, d, tmax=8000.0, lift=0.0):
        """first point where the ray o + t*d goes below the terrain (raised by lift m); returned on the terrain"""
        if lift:
            o = sub(o, [0, 0, lift])                 # same as raising the terrain
        hit = self._intersect(o, d, tmax)
        if hit is None:
            return None
        return [hit[0], hit[1], self.height(hit[0], hit[1])]

    def _intersect(self, o, d, tmax):
        step = self.d / 3
        # jump straight to just above the highest terrain point, then march
        hmax = max(max(r) for r in self.h)
        if d[2] >= 0 and o[2] > hmax:
            return None
        t = 0.0
        if d[2] < 0 and o[2] > hmax:
            t = max(0.0, (o[2] - hmax) / -d[2] - step)
        prev_t = None
        while t < tmax:
            p = add(o, mul(d, t))
            f = p[2] - self.height(p[0], p[1])
            if f <= 0:
                if prev_t is None:
                    return p
                lo, hi = prev_t, t                       # bisection between the last two samples
                for _ in range(50):
                    mid = (lo + hi) / 2
                    q = add(o, mul(d, mid))
                    if q[2] - self.height(q[0], q[1]) > 0:
                        lo = mid
                    else:
                        hi = mid
                return add(o, mul(d, (lo + hi) / 2))
            prev_t = t
            t += step
        return None


# ---------------------------------------------------------------- helpers
def class_type(name: str) -> str:
    for t in TYPES:
        if name.startswith(t):
            return t
    return name


def box_px(cx, cy, w, h, W, H):
    return (cx - w / 2) * W, (cy - h / 2) * H, (cx + w / 2) * W, (cy + h / 2) * H


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0


def error_parts(est, truth, heading):
    dx, dy = est[0] - truth[0], est[1] - truth[1]
    along = dx * math.sin(heading) + dy * math.cos(heading)       # + = further away than the truth
    across = dx * math.cos(heading) - dy * math.sin(heading)      # + = to the right
    return math.hypot(dx, dy), along, across


def stats(vals):
    if not vals:
        return None
    v = sorted(vals)
    n = len(v)
    p = lambda q: v[min(n - 1, max(0, math.ceil(q * n) - 1))]
    return {"n": n, "median_CEP50_m": round(statistics.median(v), 3), "CEP90_P90_m": round(p(0.9), 3),
            "mean_m": round(statistics.fmean(v), 3), "rmse_m": round(math.sqrt(sum(x * x for x in v) / n), 3),
            "max_m": round(v[-1], 3)}


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", default="dataset", help="folder made by make_yolo_dataset.py")
    ap.add_argument("--pred", help="folder with YOLO prediction .txt files (class cx cy w h [conf]), named like the images")
    ap.add_argument("--iou", type=float, default=0.5, help="IoU to match a detection to a label (default 0.5)")
    ap.add_argument("--conf", type=float, default=0.25, help="minimum detection confidence (default 0.25)")
    ap.add_argument("--square-pixels", action="store_true", help="derive vfov from hfov and the image aspect ratio")
    ap.add_argument("--on-terrain-tol", type=float, default=0.3,
                    help="step 1 only uses objects whose ground point is within this many m of the DEM (default %(default)s)")
    ap.add_argument("--anchor", choices=["bottom", "center", "keypoint"], default="bottom",
                    help="pixel used for steps 2 and 3: box bottom-centre on the ground (default), box centre "
                         "intersected at half the object height above the ground (better for vehicles seen at an angle), "
                         "or the ground-point keypoint (labels: ground_px; detections: YOLO-pose keypoint)")
    ap.add_argument("--out", default="geoloc_eval")
    args = ap.parse_args()

    ds = zpi_paths.out_path(args.dataset)
    if not ds.exists() and Path(args.dataset).exists():
        ds = Path(args.dataset)
    metas = sorted((ds / "meta").glob("*.json"))
    if not metas:
        raise SystemExit(f"no JSON files in {ds / 'meta'}; build the dataset first (make_yolo_dataset.py)")
    out = zpi_paths.out_path(args.out)
    print(f"dataset: {ds}\nresults: {out}")
    out.mkdir(parents=True, exist_ok=True)

    rows = []
    err = defaultdict(list)            # (step, type) -> horizontal errors
    comp = defaultdict(list)           # (step, type) -> (along, across)
    pix_off = defaultdict(list)        # type -> (dx, dy) box bottom-centre minus ground point, px
    proj_chk = []
    model_vs_game = []
    n_off_terrain = 0
    det_total = det_matched = gt_total = 0

    for mp in metas:
        m = json.loads(mp.read_text(encoding="utf-8"))
        if not m.get("terrain_grid"):
            continue
        cam = Camera(m, args.square_pixels)
        terr = Terrain(m)
        for c in m["projection_check_px"]:
            proj_chk.append(math.hypot(*c))
        name = mp.stem
        gts = []
        for o in m["objects"]:
            t = o["type"]
            g = o["ground_pos_asl"]
            bx = o["box_px"]
            gts.append((o, t, g, bx))

            # step 1: truth -> pixel -> DEM
            pg = cam.project(g)
            on_terrain = abs(g[2] - terr.height(g[0], g[1])) <= args.on_terrain_tol
            if pg and o.get("ground_px"):
                model_vs_game.append(math.hypot(pg[0] - o["ground_px"][0], pg[1] - o["ground_px"][1]))
            if pg and on_terrain:
                hit = terr.intersect(cam.o, cam.ray(*pg))
                if hit:
                    e, al, ac = error_parts(hit, g, cam.heading)
                    err[("1_geometry", t)].append(e); comp[("1_geometry", t)].append((al, ac))
            elif pg and not on_terrain:
                n_off_terrain += 1

            # step 2: label box bottom-centre -> DEM
            if args.anchor == "keypoint":
                if not o.get("ground_px"):
                    continue
                bc, lift = tuple(o["ground_px"]), 0.0
            else:
                bc = ((bx[0] + bx[2]) / 2, bx[3]) if args.anchor == "bottom" else ((bx[0] + bx[2]) / 2, (bx[1] + bx[3]) / 2)
                lift = 0.0 if args.anchor == "bottom" else HALF_HEIGHT.get(t, 1.0)
            hit = terr.intersect(cam.o, cam.ray(*bc), lift=lift)
            if hit:
                e, al, ac = error_parts(hit, g, cam.heading)
                err[("2_labels", t)].append(e); comp[("2_labels", t)].append((al, ac))
                if pg and args.anchor == "bottom":
                    pix_off[t].append((bc[0] - pg[0], bc[1] - pg[1]))
                rows.append([name, o.get("object_id"), t, o["class"], "label", round(bc[0], 1), round(bc[1], 1),
                             *[round(v, 2) for v in hit], *[round(v, 2) for v in g], round(e, 3), round(al, 3), round(ac, 3),
                             o.get("inside_building")])

        # step 3: detections
        if args.pred:
            pf = Path(args.pred) / f"{name}.txt"
            if not pf.exists():
                continue
            classes = m["classes"]
            dets = []
            for line in pf.read_text().split("\n"):
                v = line.split()
                if len(v) < 5:
                    continue
                # detect: cls cx cy w h [conf];  pose: cls cx cy w h kx ky [kv] [conf]
                kp = None
                if args.anchor == "keypoint":
                    if len(v) < 7:
                        continue
                    if float(v[5]) == 0 and float(v[6]) == 0 or (len(v) >= 8 and float(v[7]) <= 0):
                        continue          # no ground point for this object (buildings, gun fire)
                    kp = (float(v[5]) * cam.W, float(v[6]) * cam.H)
                    conf = float(v[-1]) if len(v) in (8, 9) else 1.0
                else:
                    conf = float(v[5]) if len(v) > 5 else 1.0
                if conf < args.conf:
                    continue
                cid = int(v[0])
                t = class_type(classes[cid]) if cid < len(classes) else str(cid)
                dets.append((conf, t, box_px(*map(float, v[1:5]), cam.W, cam.H), kp))
            dets.sort(key=lambda d: -d[0])
            det_total += len(dets)
            gt_total += len(gts)
            used = set()
            for conf, t, db, kp in dets:
                best, bi = 0, -1
                for k, (o, gt_t, g, bx) in enumerate(gts):
                    if k in used or gt_t != t:
                        continue
                    v = iou(db, bx)
                    if v > best:
                        best, bi = v, k
                if bi < 0 or best < args.iou:
                    continue
                used.add(bi)
                det_matched += 1
                o, gt_t, g, bx = gts[bi]
                if kp is not None:
                    bc, lift = kp, 0.0
                else:
                    bc = ((db[0] + db[2]) / 2, db[3]) if args.anchor == "bottom" else ((db[0] + db[2]) / 2, (db[1] + db[3]) / 2)
                    lift = 0.0 if args.anchor == "bottom" else HALF_HEIGHT.get(t, 1.0)
                hit = terr.intersect(cam.o, cam.ray(*bc), lift=lift)
                if hit:
                    e, al, ac = error_parts(hit, g, cam.heading)
                    err[("3_detector", t)].append(e); comp[("3_detector", t)].append((al, ac))
                    rows.append([name, o.get("object_id"), t, o["class"], f"detection {conf:.2f}", round(bc[0], 1), round(bc[1], 1),
                                 *[round(v, 2) for v in hit], *[round(v, 2) for v in g], round(e, 3), round(al, 3), round(ac, 3),
                                 o.get("inside_building")])

    with open(out / "per_object.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["image", "object_id", "type", "class", "source", "px", "py", "est_x", "est_y", "est_z",
                    "true_x", "true_y", "true_z", "error_m", "along_m", "across_m", "inside_building"])
        w.writerows(rows)

    summary = {"pictures": len(metas), "anchor": args.anchor,
               "step1_left_out_not_on_terrain": n_off_terrain,
               "pinhole_vs_engine_worldToScreen_px": stats(proj_chk),
               "python_projection_vs_logged_ground_px": stats(model_vs_game), "steps": {}}
    print(f"\n{len(metas)} pictures   (CEP50 = median horizontal error, CEP90 = 90th percentile; metres)\n")
    print(f"{'step':<12} {'type':<17} {'n':>6} {'CEP50':>8} {'CEP90':>8} {'mean':>8} {'RMSE':>8} {'max':>8} {'along':>8} {'across':>8}")
    for step in ("1_geometry", "2_labels", "3_detector"):
        types = [t for t in TYPES if (step, t) in err]
        if not types:
            continue
        summary["steps"][step] = {}
        groups = [(t, err[(step, t)], comp[(step, t)]) for t in types]
        no_b = [t for t in types if t != "building"]
        groups.append(("ALL (no bldg)", [e for t in no_b for e in err[(step, t)]], [c for t in no_b for c in comp[(step, t)]]))
        for t, es, cs in groups:
            st = stats(es)
            st["mean_along_m"] = round(statistics.fmean(c[0] for c in cs), 3) if cs else None
            st["mean_across_m"] = round(statistics.fmean(c[1] for c in cs), 3) if cs else None
            summary["steps"][step][t] = st
            print(f"{step:<12} {t:<17} {st['n']:>6} {st['median_CEP50_m']:>8} {st['CEP90_P90_m']:>8} {st['mean_m']:>8} "
                  f"{st['rmse_m']:>8} {st['max_m']:>8} {st['mean_along_m']:>8} {st['mean_across_m']:>8}")
        print()
    summary["label_box_bottom_minus_ground_point_px"] = {
        t: {"n": len(v), "median_dx": round(statistics.median(a for a, _ in v), 2), "median_dy": round(statistics.median(b for _, b in v), 2)}
        for t, v in pix_off.items() if v}
    if args.pred:
        summary["detections"] = {"detections": det_total, "matched": det_matched, "labels": gt_total,
                                 "recall_at_iou": round(det_matched / gt_total, 3) if gt_total else None}
        print(f"detections: {det_total}, matched to a label (IoU >= {args.iou}): {det_matched} of {gt_total} labels")
    (out / "summary.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")

    if summary["pinhole_vs_engine_worldToScreen_px"]:
        s = summary["pinhole_vs_engine_worldToScreen_px"]
        print(f"camera model check (pinhole vs the game's worldToScreen): median {s['median_CEP50_m']} px, max {s['max_m']} px")
    if summary["python_projection_vs_logged_ground_px"]:
        s = summary["python_projection_vs_logged_ground_px"]
        print(f"python projection vs ground_px logged by the game: median {s['median_CEP50_m']} px, max {s['max_m']} px")
    for t, v in summary["label_box_bottom_minus_ground_point_px"].items():
        print(f"label box bottom-centre minus true ground point, {t}: median dx {v['median_dx']} px, dy {v['median_dy']} px")
    if n_off_terrain:
        print(f"NOTE: step 1 left out {n_off_terrain} object(s) standing off the terrain (floors, roofs, bridges).")
    print(f"\n{out / 'per_object.csv'}\n{out / 'summary.json'}")


if __name__ == "__main__":
    main()
