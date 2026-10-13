#!/usr/bin/env python3
"""Repair the original Catdex v1 artwork without regenerating its poses.

Requires Pillow and NumPy. Writes staged packages and QA artifacts only; it
never changes the installed pet, terminal preferences, or application binaries.
The terminal package compensates Codex CLI 0.153.2's fixed 9x5-cell placement.
"""

import argparse
from collections import deque
import hashlib
import json
from pathlib import Path
import statistics

import numpy as np
from PIL import Image, ImageDraw


CELL = (192, 208)
STATES = ["idle", "running-right", "running-left", "waving", "jumping",
          "failed", "waiting", "running", "review"]
COUNTS = [6, 8, 8, 4, 5, 8, 6, 6, 6]
DURATIONS = [[280, 110, 110, 140, 140, 320], [120] * 7 + [220],
             [120] * 7 + [220], [140] * 3 + [280], [140] * 4 + [280],
             [140] * 7 + [240], [150] * 5 + [260], [120] * 5 + [220],
             [150] * 5 + [280]]
SOURCE_SHA256 = "a187f5c845c3fe6cb4e35b535460cb3d322cd2539da42112433c7beed885caa9"


def face_bounds(frame):
    """Find the connected dark screen, excluding the separate ear triangles."""
    a = np.asarray(frame)
    mask = (a[:, :, 0] < 90) & (a[:, :, 1] < 110) & (a[:, :, 2] < 115) & (a[:, :, 3] > 180)
    seen = np.zeros_like(mask)
    components = []
    for y, x in zip(*np.where(mask)):
        if seen[y, x]:
            continue
        points = []
        queue = deque([(y, x)])
        seen[y, x] = True
        while queue:
            yy, xx = queue.pop()
            points.append((yy, xx))
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                ny, nx = yy + dy, xx + dx
                if 0 <= ny < frame.height and 0 <= nx < frame.width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        components.append(points)
    points = np.asarray(max(components, key=len))
    y0, x0 = points.min(axis=0)
    y1, x1 = points.max(axis=0) + 1
    return [int(x0), int(y0), int(x1), int(y1)]


def alpha_bounds(frame, threshold=16):
    return frame.getchannel("A").point(lambda a: 255 if a >= threshold else 0).getbbox()


def resize(frame, size):
    # Premultiplied alpha prevents transparent RGB from bleeding into the fur.
    return frame.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")


def put_pose(frame, scale, source_floor, destination_floor):
    bounds = frame.getchannel("A").getbbox()
    x0, y0, x1, y1 = bounds
    pose = resize(frame.crop(bounds), (round((x1 - x0) * scale), round((y1 - y0) * scale)))
    x = round(96 + (x0 - 96) * scale)
    y = round(destination_floor + (y0 - source_floor) * scale)
    if x < 0 or y < 0 or x + pose.width > CELL[0] or y + pose.height > CELL[1]:
        raise ValueError("Pose would be clipped; change the shared scale/trajectory")
    result = Image.new("RGBA", CELL)
    result.alpha_composite(pose, (x, y))
    return result


def atlas(rows):
    image = Image.new("RGBA", (1536, 1872))
    for r, row in enumerate(rows):
        for c, frame in enumerate(row):
            image.paste(frame, (c * 192, r * 208))
    return image


def contact_sheet(rows, path):
    sheet = Image.new("RGB", (1536, 9 * 232), "#2d3139")
    draw = ImageDraw.Draw(sheet)
    for r, row in enumerate(rows):
        for c, frame in enumerate(row):
            sheet.paste(frame, (c * 192, r * 232), frame)
            draw.text((c * 192 + 6, r * 232 + 210), f"{STATES[r]} {c}", fill="white")
    sheet.save(path)


def motion_preview(rows, path):
    timeline = []
    # Explicit idle/hover/drag/state transitions catch popping between rows.
    for r in (0, 4, 0, 1, 0, 2, 0, 3, 0, 6, 7, 8, 0, 5, 0):
        timeline.extend((r, c, ms) for c, ms in enumerate(DURATIONS[r]))
    images = []
    durations = []
    for r, c, ms in timeline:
        out = Image.new("RGB", (256, 256), "#2d3139")
        frame = rows[r][c]
        out.paste(frame, (32, 12), frame)
        ImageDraw.Draw(out).text((12, 232), STATES[r], fill="white")
        images.append(out)
        durations.append(ms)
    images[0].save(path, save_all=True, append_images=images[1:], duration=durations, loop=0, disposal=2)


def save_package(rows, path, manifest):
    path.mkdir(parents=True, exist_ok=True)
    image = atlas(rows)
    image.save(path / "spritesheet.webp", lossless=True, exact=True)
    (path / "pet.json").write_text(json.dumps(manifest, indent=2) + "\n")
    decoded = Image.open(path / "spritesheet.webp").convert("RGBA")
    if not np.array_equal(np.asarray(image), np.asarray(decoded)):
        raise ValueError("Lossless atlas verification failed")
    for r, count in enumerate(COUNTS):
        for c in range(8):
            frame = decoded.crop((c * 192, r * 208, (c + 1) * 192, (r + 1) * 208))
            bounds = alpha_bounds(frame)
            if c >= count:
                assert frame.getchannel("A").getbbox() is None, (r, c, "unused cell")
            else:
                assert bounds and bounds[0] >= 3 and bounds[1] >= 3 and bounds[2] <= 189 and bounds[3] <= 205, (r, c, bounds)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--cell-width", type=float, required=True)
    parser.add_argument("--cell-height", type=float, required=True)
    args = parser.parse_args()
    if args.cell_width <= 0 or args.cell_height <= 0:
        parser.error("Terminal cell dimensions must be positive")
    source_hash = hashlib.sha256(args.source.read_bytes()).hexdigest()
    if source_hash != SOURCE_SHA256:
        parser.error("This repair is calibrated for the original Catdex atlas; refusing a different/already repaired image")
    source = Image.open(args.source).convert("RGBA")
    assert source.size == (1536, 1872)
    rows = [[source.crop((c * 192, r * 208, (c + 1) * 192, (r + 1) * 208)) for c in range(count)]
            for r, count in enumerate(COUNTS)]
    args.output.mkdir(parents=True, exist_ok=True)
    original_faces = [[face_bounds(f) for f in row] for row in rows]
    corrected = []
    scales = []
    target_width = 78.0
    idle_scale = target_width / statistics.median(b[2] - b[0] for b in original_faces[0])
    target_height = statistics.median(b[3] - b[1] for b in original_faces[0]) * idle_scale
    for r, row in enumerate(rows):
        faces = original_faces[r]
        # Profile views naturally have narrower faces: use their vertical metric.
        if r in (1, 2):
            scale = target_height / statistics.median(b[3] - b[1] for b in faces)
        elif r == 5:
            # Bending forward is real pose foreshortening, not a scale defect.
            scale = target_width / (faces[0][2] - faces[0][0])
        else:
            scale = target_width / statistics.median(b[2] - b[0] for b in faces)
        scales.append(scale)
        floor = max(alpha_bounds(f, 128)[3] for f in row)
        frames = []
        for c, frame in enumerate(row):
            source_floor = alpha_bounds(frame, 128)[3] if r == 4 else floor
            destination_floor = [200, 192, 182, 192, 200][c] if r == 4 else 200
            frames.append(put_pose(frame, scale, source_floor, destination_floor))
        corrected.append(frames)

    # The CLI forces BOTH dimensions of a 9-column x 5-row Kitty image. Widen
    # the artwork inside its transparent margins to undo horizontal squeezing,
    # preserving the corrected pet's height and jump trajectory.
    terminal_columns, terminal_rows = 9, 5
    correction_y = ((terminal_columns * args.cell_width) / (terminal_rows * args.cell_height)) / (192 / 208)
    if not 0.5 <= correction_y <= 1.0:
        parser.error("This terminal's ratio needs a different canvas strategy")
    terminal = []
    for row in corrected:
        frames = []
        for frame in row:
            wider = resize(frame, (round(192 / correction_y), 208))
            left = (wider.width - 192) // 2
            bounds = alpha_bounds(wider)
            if bounds[0] < left + 3 or bounds[2] > left + 189:
                raise ValueError("Terminal correction would clip the pet")
            out = wider.crop((left, 0, left + 192, 208))
            frames.append(out)
        terminal.append(frames)

    manifest = json.loads((args.source.parent / "pet.json").read_text())
    manifest["spritesheetPath"] = "spritesheet.webp"
    save_package(corrected, args.output / "desktop", manifest)
    terminal_manifest = dict(manifest, id="catdex-terminal", displayName="Catdex (Terminal)",
                             description=f"Catdex with aspect correction for {args.cell_width:g}x{args.cell_height:g} px iTerm cells.")
    save_package(terminal, args.output / "terminal", terminal_manifest)
    contact_sheet(rows, args.output / "before.png")
    contact_sheet(corrected, args.output / "after.png")
    motion_preview(corrected, args.output / "motion.gif")
    motion_preview(rows, args.output / "before-motion.gif")
    metrics = [[face_bounds(f) for f in row] for row in corrected]
    for r in (0, 3, 4, 6, 7, 8):
        widths = [b[2] - b[0] for b in metrics[r]]
        assert max(abs(w - target_width) for w in widths) <= 4, (r, widths)
    for r in (1, 2):
        heights = [b[3] - b[1] for b in metrics[r]]
        assert max(abs(h - target_height) for h in heights) <= 3, (r, heights)
    # Compare the terminal's actual pixel output with an undistorted reference.
    display_width = round(terminal_columns * args.cell_width)
    display_height = round(terminal_rows * args.cell_height)
    comparison = Image.new("RGB", (display_width * 3, display_height + 24), "#2d3139")
    for i, (label, f, size) in enumerate([
        ("before", rows[0][0], (display_width, display_height)),
        ("corrected", terminal[0][0], (display_width, display_height)),
        ("reference", corrected[0][0], (round(display_height * 192 / 208), display_height)),
    ]):
        shown = resize(f, size)
        if shown.width > display_width:
            left = (shown.width - display_width) // 2
            shown = shown.crop((left, 0, left + display_width, display_height))
        comparison.paste(shown, (i * display_width, 0), shown)
        ImageDraw.Draw(comparison).text((i * display_width + 4, display_height + 6), label, fill="white")
    comparison.save(args.output / "terminal-comparison.png")
    report = {
        "ok": True, "source_sha256": source_hash,
        "desktop_sha256": hashlib.sha256((args.output / "desktop" / "spritesheet.webp").read_bytes()).hexdigest(),
        "terminal_sha256": hashlib.sha256((args.output / "terminal" / "spritesheet.webp").read_bytes()).hexdigest(),
        "sprite_version": 1, "dimensions": list(source.size),
        "used_frames": sum(COUNTS), "row_scales": dict(zip(STATES, scales)),
        "face_bounds_before": original_faces, "face_bounds_after": metrics,
        "terminal_cell_pixels": [args.cell_width, args.cell_height],
        "terminal_placement_cells": [terminal_columns, terminal_rows],
        "terminal_horizontal_correction": 1 / correction_y,
        "terminal_horizontal_correction_realized": round(192 / correction_y) / 192,
        "desktop_width_compensation": 1 / idle_scale,
        "checks": ["lossless_round_trip", "57_nonempty_frames", "15_transparent_unused_cells",
                   "all_frames_unclipped", "shared_scale_per_animation", "consistent_face_scale",
                   "jump_displacement_preserved", "terminal_inverse_aspect_correction"],
    }
    (args.output / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if not k.startswith("face_bounds")}, indent=2))


if __name__ == "__main__":
    main()
