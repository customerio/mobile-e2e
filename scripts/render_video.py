#!/usr/bin/env python3
"""Render an annotated side-by-side MP4 from a Maestro run.

Left  = device screen recording
Right = steps panel that highlights the currently-running step, plus a
        backend-response panel that appears when a runScript assertion
        lands a real Ext-API match.

Usage:
    render_video.py \
        --commands <debug>/commands-*.json \
        --device <out>/device.mp4 \
        --rec-started-ms <epoch_ms> \
        --sink <out>/sink.jsonl \
        --out <out>/annotated.mp4

We generate one PNG overlay per frame step (low fps) and use ffmpeg to
composite: pad the device video, paste the overlay on the right side.
PIL renders the overlays because drawtext+long labels in ffmpeg is painful.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow required: pip3 install pillow", file=sys.stderr)
    sys.exit(2)


PANEL_W = 720
PANEL_H = 1280  # will stretch to device video height
FPS = 10  # panel fps; ffmpeg will conform device video to this


def summarize_command(cmd: dict) -> tuple[str, str]:
    if not cmd:
        return "?", ""
    key = next(iter(cmd.keys()))
    body = cmd[key] or {}

    if key == "assertConditionCommand":
        cond = body.get("condition") or {}
        if "visible" in cond:
            return "assertVisible", cond["visible"].get("textRegex", "")
        if "notVisible" in cond:
            return "assertNotVisible", cond["notVisible"].get("textRegex", "")
        if "scriptCondition" in cond:
            return "assertTrue", cond["scriptCondition"]
    if key == "tapOnElement":
        sel = body.get("selector") or {}
        return "tapOn", sel.get("textRegex") or sel.get("idRegex") or ""
    if key == "inputTextCommand":
        return "inputText", body.get("text", "")
    if key == "runScriptCommand":
        env = body.get("env") or {}
        if "EXPECTED_TYPE" in env:
            bits = [f'expect {env.get("EXPECTED_TYPE")}', f'metric >= {env.get("MIN_METRIC", "sent")}']
            if env.get("CAMPAIGN_ID"):
                bits.append(f'campaign {env["CAMPAIGN_ID"]}')
            return "assertBackend", " / ".join(bits)
        src = body.get("script") or ""
        for line in src.splitlines():
            s = line.strip()
            if s.startswith("//") and len(s) > 3:
                return "runScript", s[2:].strip()
        return "runScript", ""
    if key == "takeScreenshotCommand":
        return "takeScreenshot", body.get("path", "")
    if key == "swipeCommand":
        return "swipe", "notification shade" if "start" in json.dumps(body) else ""
    if key == "launchAppCommand":
        return "launchApp", body.get("appId", "")
    if key == "backPressCommand":
        return "back", ""
    if key == "hideKeyboardCommand":
        return "hideKeyboard", ""
    if key == "defineVariablesCommand":
        return "defineVars", ""
    if key == "applyConfigurationCommand":
        return "applyConfig", ""
    if key == "runFlowCommand":
        return "runFlow", "(conditional)"
    return key, ""


def build_step_timeline(commands: list, rec_started_ms: int) -> list[dict]:
    """Convert commands to (start_s, end_s, ...) relative to video time."""
    rows = sorted(commands, key=lambda c: c.get("metadata", {}).get("timestamp", 0))
    out = []
    for i, entry in enumerate(rows):
        m = entry.get("metadata", {}) or {}
        ts = m.get("timestamp") or 0
        dur = m.get("duration") or 0
        verb, detail = summarize_command(entry.get("command") or {})
        start_s = max(0.0, (ts - rec_started_ms) / 1000.0)
        end_s = max(start_s + 0.05, (ts + dur - rec_started_ms) / 1000.0)
        out.append({
            "i": i,
            "verb": verb,
            "detail": detail,
            "status": m.get("status", "?"),
            "start_s": start_s,
            "end_s": end_s,
            "command_ts_ms": ts,
        })
    return out


def load_sink(sink_path: Path | None, rec_started_ms: int) -> list[dict]:
    if not sink_path or not sink_path.exists():
        return []
    out = []
    for line in sink_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        rx = ev.get("received_at_ms") or 0
        ev["_t"] = max(0.0, (rx - rec_started_ms) / 1000.0)
        out.append(ev)
    return out


def pick_font(size: int):
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for c in candidates:
        if Path(c).exists():
            try:
                return ImageFont.truetype(c, size)
            except Exception:
                pass
    return ImageFont.load_default()


def render_panel_frame(
    t_s: float,
    steps: list[dict],
    sink_events: list[dict],
    w: int,
    h: int,
    f_h1,
    f_body,
    f_small,
    f_mono,
) -> Image.Image:
    img = Image.new("RGB", (w, h), (247, 250, 252))
    d = ImageDraw.Draw(img)

    # Header.
    d.rectangle([(0, 0), (w, 70)], fill=(26, 32, 44))
    d.text((20, 16), "Maestro E2E \u2014 Campaign 141", font=f_h1, fill=(255, 255, 255))
    d.text((20, 44), f"t = {t_s:5.1f}s", font=f_small, fill=(160, 174, 192))

    # Find current step: first where start_s <= t <= end_s; if none, latest before t.
    current_idx = -1
    for i, s in enumerate(steps):
        if s["start_s"] <= t_s <= s["end_s"]:
            current_idx = i
            break
    if current_idx < 0:
        for i, s in enumerate(steps):
            if s["start_s"] <= t_s:
                current_idx = i

    # Progress bar
    total = len(steps)
    progress = (current_idx + 1) / total if total else 0
    d.rectangle([(20, 82), (w - 20, 98)], fill=(226, 232, 240))
    d.rectangle([(20, 82), (20 + int((w - 40) * progress), 98)], fill=(47, 157, 85))
    d.text((20, 106), f"Step {max(current_idx+1, 0)} of {total}", font=f_small, fill=(74, 85, 104))

    # Steps list: window of 12 around current
    list_top = 140
    row_h = 38
    if total == 0:
        return img
    window = 12
    start = max(0, current_idx - window // 3)
    end = min(total, start + window)
    start = max(0, end - window)

    for row, i in enumerate(range(start, end)):
        s = steps[i]
        y = list_top + row * row_h
        is_current = i == current_idx
        is_past = i < current_idx
        status = s["status"]
        if is_current:
            bg = (255, 250, 205) if status == "RUNNING" or s["end_s"] > t_s else (
                (230, 255, 240) if status == "COMPLETED" else (255, 245, 245)
            )
            d.rectangle([(10, y - 2), (w - 10, y + row_h - 4)], fill=bg, outline=(203, 213, 224))
        icon = "\u2705" if status == "COMPLETED" and is_past else (
            "\u274C" if status == "FAILED" else ("\u23ED" if status == "SKIPPED" else ("\u25B6" if is_current else "\u2022"))
        )
        icon_color = (
            (47, 157, 85) if status == "COMPLETED" and is_past else
            (204, 31, 26) if status == "FAILED" else
            (135, 149, 161) if status == "SKIPPED" else
            (52, 144, 220) if is_current else (160, 174, 192)
        )
        d.text((20, y + 4), icon, font=f_body, fill=icon_color)
        verb = s["verb"]
        detail = s["detail"] or ""
        max_detail = 44
        if len(detail) > max_detail:
            detail = detail[: max_detail - 1] + "\u2026"
        label = f"{verb}  {detail}" if detail else verb
        d.text((60, y + 4), label, font=f_body, fill=(26, 32, 44) if is_current or is_past else (113, 128, 150))

    # Backend panel: show the latest sink event that has arrived by now.
    latest = None
    for ev in sink_events:
        if ev.get("kind") != "assert_message":
            continue
        if ev.get("_t", 1e9) > t_s:
            continue
        if latest is None or ev["_t"] > latest["_t"]:
            latest = ev
    # Only show if the latest event is within the last 12s (fresh).
    if latest and t_s - latest["_t"] <= 12:
        panel_top = h - 260
        is_match = latest.get("result") == "match"
        bg = (230, 255, 240) if is_match else (255, 245, 245)
        border = (47, 157, 85) if is_match else (204, 31, 26)
        d.rectangle([(10, panel_top), (w - 10, h - 20)], fill=bg, outline=border, width=2)
        title = "Backend response (Customer.io Ext API)"
        d.text((24, panel_top + 10), title, font=f_small, fill=(45, 55, 72))
        result_label = ("\u2705 matched" if is_match else "\u274C no match") + f"  \u00b7  {latest.get('attempts')} attempts / {int(latest.get('elapsed_ms', 0))}ms"
        d.text((24, panel_top + 36), result_label, font=f_body, fill=border)
        y = panel_top + 68
        if is_match:
            d.text((24, y), f"message_id   {latest.get('message_id')}", font=f_mono, fill=(26, 32, 44))
            y += 24
            d.text((24, y), f"campaign_id  {latest.get('campaign_id')}   template  {latest.get('msg_template_id')}", font=f_mono, fill=(26, 32, 44))
            y += 24
            metrics = latest.get("metrics") or {}
            chips = "   ".join(f"{k}:{v}" for k, v in metrics.items())
            d.text((24, y), f"metrics      {chips}", font=f_mono, fill=(26, 32, 44))
        else:
            d.text((24, y), f"reason       {latest.get('reason', '')[:48]}", font=f_mono, fill=(26, 32, 44))

    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commands", required=True)
    ap.add_argument("--device", required=True)
    ap.add_argument("--rec-started-ms", required=True, type=int)
    ap.add_argument("--sink", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    commands_path = Path(args.commands)
    if not commands_path.exists():
        # Allow glob-like
        import glob
        matches = glob.glob(args.commands)
        if not matches:
            print(f"no commands json at {args.commands}", file=sys.stderr)
            return 2
        commands_path = Path(matches[0])
    commands = json.loads(commands_path.read_text())
    steps = build_step_timeline(commands, args.rec_started_ms)
    sink_events = load_sink(Path(args.sink), args.rec_started_ms) if args.sink else []

    if not shutil.which("ffmpeg"):
        print("ffmpeg not found on PATH", file=sys.stderr)
        return 2

    # Determine device video dimensions + duration.
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,duration,nb_frames,avg_frame_rate",
         "-of", "json", args.device],
        capture_output=True, text=True, check=True,
    )
    info = json.loads(probe.stdout)["streams"][0]
    dw, dh = int(info["width"]), int(info["height"])
    # duration may be missing on some containers; fall back via format.
    if "duration" in info:
        duration = float(info["duration"])
    else:
        fmt = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "json", args.device], capture_output=True, text=True, check=True,
        )
        duration = float(json.loads(fmt.stdout)["format"]["duration"])

    panel_h = dh
    panel_w = int(dh * 0.56)  # 16:9-ish for panel
    panel_w = min(max(panel_w, 720), 900)

    # Fonts
    f_h1 = pick_font(24)
    f_body = pick_font(18)
    f_small = pick_font(14)
    f_mono = pick_font(16)

    # Render overlay frames at FPS to a tmp dir.
    with tempfile.TemporaryDirectory() as td:
        td_p = Path(td)
        frame_count = int(duration * FPS) + 1
        for f in range(frame_count):
            t_s = f / FPS
            img = render_panel_frame(t_s, steps, sink_events, panel_w, panel_h, f_h1, f_body, f_small, f_mono)
            img.save(td_p / f"p_{f:05d}.png")

        # Build the final video: hstack device + panel sequence.
        # Panel frames are a constant-FPS sequence.
        overlay_pattern = str(td_p / "p_%05d.png")
        total_w = dw + panel_w
        total_h = dh

        cmd = [
            "ffmpeg", "-y",
            "-r", str(FPS), "-i", overlay_pattern,
            "-i", args.device,
            "-filter_complex",
            f"[1:v]scale={dw}:{dh},setsar=1[dev];"
            f"[0:v]scale={panel_w}:{panel_h},setsar=1[pan];"
            f"[dev][pan]hstack=inputs=2[v]",
            "-map", "[v]",
            "-r", "30",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-pix_fmt", "yuv420p",
            args.out,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[-2000:], file=sys.stderr)
            return r.returncode

    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
