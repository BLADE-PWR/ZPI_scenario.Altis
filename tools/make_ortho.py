#!/usr/bin/env python3
"""
Stitch the orthophoto tiles (Z key in the mission) into one georeferenced map
and draw the soldiers / vehicles on it.

Every tile was taken straight down with north at the top, so a tile pixel (u, v) is at
    X = cam_x + (u / W - 0.5) * footprint_w        (east)
    Y = cam_y - (v / H - 0.5) * footprint_h        (north)
with footprint = 2 * (camera height above ground) * tan(FOV / 2). Only the central part of
each tile (one grid step) is used, which keeps perspective distortion small.

Output (in --out, default "ortho"):
    ortho_<tag>.png            the map
    ortho_<tag>.pgw            world file: opens at the right place in QGIS / ArcGIS (Arma metres)
    ortho_<tag>_objects.png    the map with soldiers / vehicles, grid, scale bar, legend
    ortho_<tag>_objects.csv    id, type, stance, x, y, z, pixel position, inside building
    ortho_<tag>.json           metadata (extent, metres per pixel, tiles, objects)

Usage (from the mission folder; output goes to <mission>\\output\\ortho):
    python tools/make_ortho.py                 # newest orthophoto in the Arma logs
    python tools/make_ortho.py --list          # list all orthophotos found
    python tools/make_ortho.py --tag <tag> --mpp 0.25
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zpi_paths  # noqa: E402

LINE_RE = re.compile(r"ZPI\|(ortho|otile|oobj)\|(.*)$")
STANCE_COL = {"STAND": (255, 60, 60), "CROUCH": (255, 160, 40), "PRONE": (255, 0, 200)}
KIND_COL = {"t": (255, 220, 0), "v": (60, 200, 255)}
KIND_NAME = {"s": "soldier", "t": "tank", "v": "military vehicle"}


def read_orthos(rpts: list[Path]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for rpt in rpts:
        with open(rpt, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = LINE_RE.search(line.rstrip("\r\n"))
                if not m:
                    continue
                try:
                    rec = json.loads(m.group(2).strip().replace("\\", "/"))
                except json.JSONDecodeError:
                    continue
                o = out.setdefault(rec["ortho"], {"meta": None, "tiles": [], "objs": []})
                if m.group(1) == "ortho":
                    o["meta"] = rec
                elif m.group(1) == "otile":
                    o["tiles"].append(rec)
                else:
                    o["objs"] += rec["objs"]
    return {k: v for k, v in out.items() if v["meta"] and v["tiles"]}


def build(o: dict, dirs: list[Path], outdir: Path, mpp: float | None, tag: str):
    from PIL import Image, ImageDraw
    meta = o["meta"]
    sx, sy = float(meta["step"][0]), float(meta["step"][1])

    # tile geometry
    tiles = []
    for t in o["tiles"]:
        if not t["ok"]:
            continue
        p = zpi_paths.find_image(t["image"], dirs)
        if p is None:
            print(f"  missing tile image: {t['image']}")
            continue
        cx, cy, cz = t["cam_pos_asl"]
        hgt = cz - float(t["ground_z"])
        fw = 2 * hgt * math.tan(math.radians(float(t["hfov"]) / 2))
        fh = 2 * hgt * math.tan(math.radians(float(t["vfov"]) / 2))
        tiles.append((t, p, cx, cy, fw, fh))
    if not tiles:
        sys.exit("No tile images found. Check the Screenshots folder (--shots).")

    with Image.open(tiles[0][1]) as im0:
        W0 = im0.size[0]
    if mpp is None:
        mpp = round(min(t[4] / W0 for t in tiles), 3)        # finest tile resolution

    # extent = union of the tile cells (one grid step around each tile center)
    xmin = min(t[2] - sx / 2 for t in tiles); xmax = max(t[2] + sx / 2 for t in tiles)
    ymin = min(t[3] - sy / 2 for t in tiles); ymax = max(t[3] + sy / 2 for t in tiles)
    MW, MH = int(math.ceil((xmax - xmin) / mpp)), int(math.ceil((ymax - ymin) / mpp))
    mosaic = Image.new("RGB", (MW, MH), (0, 0, 0))

    for t, p, cx, cy, fw, fh in tiles:
        with Image.open(p) as im:
            im = im.convert("RGB")
            W, H = im.size
            # the tile's cell (sx x sy metres around its center) in tile pixels
            cw, ch = min(sx, fw) / fw * W, min(sy, fh) / fh * H
            box = (int(round(W / 2 - cw / 2)), int(round(H / 2 - ch / 2)), int(round(W / 2 + cw / 2)), int(round(H / 2 + ch / 2)))
            cell = im.crop(box)
            # where the cell lands in the mosaic
            gx0 = (cx - (box[2] - box[0]) / W * fw / 2 - xmin) / mpp
            gy0 = (ymax - (cy + (box[3] - box[1]) / H * fh / 2)) / mpp
            tw = max(1, int(round((box[2] - box[0]) / W * fw / mpp)))
            th = max(1, int(round((box[3] - box[1]) / H * fh / mpp)))
            mosaic.paste(cell.resize((tw, th), Image.LANCZOS), (int(round(gx0)), int(round(gy0))))

    outdir.mkdir(parents=True, exist_ok=True)
    base = outdir / f"ortho_{tag}"
    mosaic.save(base.with_suffix(".png"))
    # world file: pixel size, rotation (0), -pixel size, center of the upper-left pixel
    base.with_suffix(".pgw").write_text(f"{mpp}\n0\n0\n{-mpp}\n{xmin + mpp / 2}\n{ymax - mpp / 2}\n", encoding="utf-8")

    def to_px(x, y):
        return (x - xmin) / mpp, (ymax - y) / mpp

    # ---- overlay ----
    ov = mosaic.copy()
    d = ImageDraw.Draw(ov)
    # grid every 100 m with labels (Arma map metres)
    step = 100
    for gx in range(int(math.ceil(xmin / step)) * step, int(xmax) + 1, step):
        px, _ = to_px(gx, 0)
        d.line([(px, 0), (px, MH)], fill=(255, 255, 255), width=1)
        d.text((px + 2, 2), str(gx), fill=(255, 255, 255))
    for gy in range(int(math.ceil(ymin / step)) * step, int(ymax) + 1, step):
        _, py = to_px(0, gy)
        d.line([(0, py), (MW, py)], fill=(255, 255, 255), width=1)
        d.text((2, py + 2), str(gy), fill=(255, 255, 255))
    rows = []
    r = max(3, int(round(1.5 / mpp)))          # marker radius ~1.5 m
    for ob in o["objs"]:
        oid, kind, stance, x, y, z, dirn, inside = ob[:8]
        px, py = to_px(float(x), float(y))
        if kind == "s":
            col = STANCE_COL.get(stance, (255, 255, 255))
            if inside:
                d.rectangle([px - r, py - r, px + r, py + r], outline=col, width=2)
            else:
                d.ellipse([px - r, py - r, px + r, py + r], fill=col, outline=(0, 0, 0))
        elif kind in KIND_COL:
            col = KIND_COL[kind]
            a = math.radians(float(dirn))
            L, Wd = 4.5 / mpp, 1.8 / mpp
            pts = []
            for ux, uy in ((-Wd, -L), (Wd, -L), (Wd, L), (-Wd, L)):
                # rotate the vehicle outline by its heading (0 = north, clockwise)
                ex = ux * math.cos(a) + uy * math.sin(a)
                ny = -ux * math.sin(a) + uy * math.cos(a)
                pts.append((px + ex, py - ny))
            d.polygon(pts, outline=col, width=2)
        else:
            col = (200, 200, 200)
            d.ellipse([px - 2, py - 2, px + 2, py + 2], fill=col)
        d.text((px + r + 2, py - r - 2), str(oid), fill=col)
        rows.append([oid, KIND_NAME.get(kind, kind), stance, x, y, z, dirn, int(inside), round(px, 1), round(py, 1)])
    # scale bar + north arrow + legend
    bar = 100 / mpp
    d.rectangle([20, MH - 30, 20 + bar, MH - 24], fill=(255, 255, 255))
    d.text((20, MH - 46), "100 m", fill=(255, 255, 255))
    d.polygon([(MW - 30, 20), (MW - 38, 44), (MW - 22, 44)], fill=(255, 255, 255))
    d.text((MW - 34, 46), "N", fill=(255, 255, 255))
    ly = 24
    d.rectangle([14, ly - 6, 190, ly + 6 * 16], fill=(0, 0, 0))
    for label, col, shape in (("standing", STANCE_COL["STAND"], "o"), ("kneeling", STANCE_COL["CROUCH"], "o"),
                              ("prone", STANCE_COL["PRONE"], "o"), ("soldier inside building", (255, 255, 255), "s"),
                              ("tank", KIND_COL["t"], "s"), ("military vehicle", KIND_COL["v"], "s")):
        if shape == "o":
            d.ellipse([20, ly, 30, ly + 10], fill=col)
        else:
            d.rectangle([20, ly, 30, ly + 10], outline=col, width=2)
        d.text((36, ly - 1), label, fill=(255, 255, 255))
        ly += 16
    ov.save(base.parent / f"{base.name}_objects.png")

    with open(base.parent / f"{base.name}_objects.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "type", "stance", "x_m", "y_m", "z_asl_m", "dir_deg", "inside_building", "px", "py"])
        w.writerows(rows)
    info = {"tag": tag, "world": meta["world"], "scene": meta["scene"], "m_per_px": mpp,
            "extent": {"xmin": xmin, "xmax": xmax, "ymin": ymin, "ymax": ymax}, "size_px": [MW, MH],
            "tiles": len(tiles), "objects": len(rows), "time_label": meta["time_label"], "weather": meta["weather"],
            "pixel_to_world": "x = xmin + (px + 0.5) * m_per_px ;  y = ymax - (py + 0.5) * m_per_px"}
    base.with_suffix(".json").write_text(json.dumps(info, indent=1), encoding="utf-8")
    print(f"  {base.with_suffix('.png')}  ({MW} x {MH} px, {mpp} m/px, {len(tiles)} tiles)")
    print(f"  {base.parent / (base.name + '_objects.png')}  ({len(rows)} objects)")
    return info


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpt", action="append")
    ap.add_argument("--shots", action="append")
    ap.add_argument("--out", default="ortho", help="output folder; a plain name goes into the mission's output\\ folder")
    ap.add_argument("--tag", help="which orthophoto (default: the newest)")
    ap.add_argument("--mpp", type=float, help="metres per pixel of the map (default: tile resolution)")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    rpts = [Path(r) for r in args.rpt] if args.rpt else zpi_paths.rpt_files()
    dirs = [Path(s) for s in args.shots] if args.shots else [zpi_paths.SCREENSHOT_DIR]
    orthos = read_orthos(rpts)
    if not orthos:
        sys.exit("No orthophoto found in the logs. Press Z in the mission first.")
    if args.list:
        for k, v in orthos.items():
            print(f"{k}: {len(v['tiles'])} tiles, {len(v['objs'])} objects, scene {v['meta'].get('scene')}")
        return
    tag = args.tag or list(orthos)[-1]
    if tag not in orthos:
        sys.exit(f"Unknown tag {tag}. Use --list.")
    print(f"orthophoto {tag}:")
    build(orthos[tag], dirs, zpi_paths.out_path(args.out), args.mpp, tag)


if __name__ == "__main__":
    main()
