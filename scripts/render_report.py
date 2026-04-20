#!/usr/bin/env python3
"""Render a Maestro debug-output dir into a single-file HTML tick-mark report.

Usage:
  render_report.py <debug_output_dir> <out_html> [--screens-dir <dir>]

Reads commands-*.json (per-step status), maestro.log (script output), and
inlines screenshots + the device screen recording if present.
"""
import argparse
import base64
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

STATUS_ICON = {
    "COMPLETED": "\u2705",  # green check
    "FAILED":    "\u274C",  # red X
    "SKIPPED":   "\u23ED\uFE0F",
    "PENDING":   "\u23F3",
    "RUNNING":   "\U0001F500",
}
STATUS_COLOR = {
    "COMPLETED": "#1f9d55",
    "FAILED":    "#cc1f1a",
    "SKIPPED":   "#8795a1",
    "PENDING":   "#f2994a",
    "RUNNING":   "#3490dc",
}


def summarize_command(cmd: dict) -> tuple[str, str]:
    """Return (verb, detail) for display."""
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
        return "assert", json.dumps(cond)[:120]

    if key == "tapOnElement":
        sel = body.get("selector") or {}
        return "tapOn", sel.get("textRegex") or sel.get("idRegex") or json.dumps(sel)[:80]

    if key == "inputTextCommand":
        return "inputText", body.get("text", "")

    if key == "runScriptCommand":
        src = body.get("script") or ""
        # Try to pull a one-line intent from the script header comment.
        for line in src.splitlines():
            s = line.strip()
            if s.startswith("//") and len(s) > 3:
                return "runScript", s[2:].strip()
        return "runScript", src[:80].replace("\n", " ")

    if key == "takeScreenshotCommand":
        return "takeScreenshot", body.get("path", "")

    if key == "swipeCommand":
        start = body.get("startRelative") or body.get("startPoint") or ""
        end = body.get("endRelative") or body.get("endPoint") or ""
        return "swipe", f"{start} -> {end}"

    if key == "launchAppCommand":
        return "launchApp", body.get("appId", "")

    if key == "backPressCommand":
        return "back", ""

    if key == "hideKeyboardCommand":
        return "hideKeyboard", ""

    if key == "applyConfigurationCommand":
        return "applyConfig", ""

    if key == "defineVariablesCommand":
        return "defineVars", ""

    if key == "runFlowCommand":
        when = body.get("config", {}).get("when") or body.get("when")
        return "runFlow (conditional)", json.dumps(when)[:80] if when else ""

    if key == "extendedWaitUntilCommand":
        return "extendedWaitUntil", json.dumps(body.get("condition", {}))[:120]

    return key, json.dumps(body)[:120]


def phase_for(verb: str, detail: str) -> str:
    """Group commands into logical phases for the report."""
    d = (detail or "").lower()
    if verb == "launchApp" or verb == "applyConfig" or verb == "defineVars":
        return "Setup"
    if verb == "runScript" and ("unique run_id" in d or "setup_run" in d or "generate a unique" in d):
        return "Setup"
    if verb in ("assertVisible",) and "login" in d:
        return "Login"
    if verb in ("tapOn", "inputText", "hideKeyboard") and not any(
        k in d for k in ["continue", "send custom", "event name", "property", "send event", "maestro push"]
    ):
        return "Login"
    if "continue" in d or "thank you for choosing" in d or "c141_01" in d:
        return "Welcome modal (C55)"
    if "send custom event" in d or "event name" in d or "property" in d or "send event" in d or d == "maestro_test" or "c141_02" in d or "c141_03" in d:
        return "Fire event (maestro_test)"
    if verb == "runScript" and "expected_type" in d or "assert_message_delivered" in d or "min_metric" in d:
        return "Backend assertions"
    if verb == "assertTrue" and "assert_ok" in d:
        return "Backend assertions"
    if verb == "swipe" or "maestro push" in d or "maestro_push_ok" in d or "c141_04" in d or "c141_05" in d or "c141_06" in d:
        return "Push visual + tap"
    if verb == "back":
        return "Backend assertions"
    if verb == "runFlow (conditional)" and "allow" in d:
        return "Push permission"
    return "Other"


def load_script_enrichment(commands: list, debug_dir: Path) -> dict[int, dict]:
    """runScript entries have a script.  Extract what they're asserting on."""
    out = {}
    for i, entry in enumerate(commands):
        cmd = entry.get("command") or {}
        if "runScriptCommand" not in cmd:
            continue
        rs = cmd["runScriptCommand"] or {}
        env = rs.get("env") or {}
        if "EXPECTED_TYPE" in env:
            out[i] = {
                "type": env.get("EXPECTED_TYPE"),
                "metric": env.get("MIN_METRIC", "sent"),
                "campaign": env.get("CAMPAIGN_ID"),
                "max_wait_ms": env.get("MAX_WAIT_MS"),
            }
    return out


def try_b64_image(path: Path) -> str | None:
    if not path.exists():
        return None
    b = path.read_bytes()
    return "data:image/png;base64," + base64.b64encode(b).decode()


def find_screenshot(screens_dir: Path, base_name: str) -> Path | None:
    # Screenshots are saved by maestro at whatever path the flow specified.
    # Flow passes e.g. "artifacts/c141_01_welcome_modal" -> .png appended.
    candidates = [
        screens_dir / f"{base_name}.png",
        screens_dir / f"{os.path.basename(base_name)}.png",
    ]
    for c in candidates:
        if c.exists():
            return c
    # Fallback: scan for a match.
    for p in screens_dir.glob("*.png"):
        if os.path.basename(base_name) in p.name:
            return p
    return None


def find_failure_screenshot(debug_dir: Path) -> Path | None:
    for p in debug_dir.glob("screenshot-*.png"):
        return p
    return None


def extract_script_log(maestro_log: Path) -> list[str]:
    if not maestro_log.exists():
        return []
    lines = []
    for line in maestro_log.read_text().splitlines():
        # Maestro prints runScript output under ScriptEngine. Also capture script.log / print lines.
        if "ScriptEngine" in line or "runScript" in line or "assert_ok" in line or "message_id" in line:
            lines.append(line)
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("debug_dir")
    ap.add_argument("out")
    ap.add_argument("--screens-dir", default=None, help="Where checkpoint screenshots live (defaults to <debug_dir>/..)")
    ap.add_argument("--video", default=None, help="Optional path to device.mp4 to embed")
    ap.add_argument("--sink", default=None, help="Optional path to sink.jsonl (backend values captured during run)")
    ap.add_argument("--title", default="Maestro E2E report")
    args = ap.parse_args()

    debug = Path(args.debug_dir)
    out = Path(args.out)
    screens_dir = Path(args.screens_dir) if args.screens_dir else debug.parent

    # Load the first commands-*.json
    cj = next(iter(sorted(debug.glob("commands-*.json"))), None)
    if not cj:
        print(f"No commands-*.json found in {debug}", file=sys.stderr)
        return 2
    commands = json.loads(cj.read_text())
    commands.sort(key=lambda c: c.get("metadata", {}).get("timestamp", 0))

    enrich = load_script_enrichment(commands, debug)

    # Load sink events (real backend values POSTed by scripts during the run).
    sink_events = []
    if args.sink and Path(args.sink).exists():
        for line in Path(args.sink).read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                sink_events.append(json.loads(line))
            except Exception:
                continue
    setup_event = next((e for e in sink_events if e.get("kind") == "setup"), None)
    assert_events = [e for e in sink_events if e.get("kind") == "assert_message"]

    def match_sink_for_runscript(cmd_timestamp_ms: int, script_env: dict) -> dict | None:
        """Match a runScript step to the assert event it most likely produced."""
        if not assert_events or not script_env:
            return None
        want_type = script_env.get("type")
        want_metric = script_env.get("metric")
        want_camp = script_env.get("campaign") or ""
        # Find the first event whose received_at falls after this command started
        # and whose filters match.
        best = None
        for ev in assert_events:
            if ev.get("expected_type") != want_type:
                continue
            if ev.get("min_metric") != want_metric:
                continue
            if want_camp and str(ev.get("campaign_filter") or "") != str(want_camp):
                continue
            if ev.get("received_at_ms", 0) < cmd_timestamp_ms:
                continue
            if best is None or ev["received_at_ms"] < best["received_at_ms"]:
                best = ev
        return best

    total = len(commands)
    by_status = {}
    for c in commands:
        s = c.get("metadata", {}).get("status", "?")
        by_status[s] = by_status.get(s, 0) + 1

    overall_pass = by_status.get("FAILED", 0) == 0
    first_ts = commands[0].get("metadata", {}).get("timestamp")
    last = commands[-1].get("metadata", {})
    last_ts = (last.get("timestamp") or 0) + (last.get("duration") or 0)
    duration_ms = (last_ts - first_ts) if first_ts else 0
    started = datetime.fromtimestamp(first_ts / 1000).strftime("%Y-%m-%d %H:%M:%S") if first_ts else "?"

    # Assemble steps grouped by phase
    step_rows = []
    for idx, entry in enumerate(commands):
        m = entry.get("metadata", {}) or {}
        status = m.get("status", "?")
        duration = m.get("duration", 0)
        verb, detail = summarize_command(entry.get("command") or {})
        phase = phase_for(verb, detail)
        err = (m.get("error") or {}).get("message")

        screenshot_img = None
        if verb == "takeScreenshot":
            p = find_screenshot(screens_dir, detail)
            if p:
                screenshot_img = try_b64_image(p)

        enrich_info = enrich.get(idx)
        sink_match = None
        if enrich_info:
            sink_match = match_sink_for_runscript(m.get("timestamp", 0), enrich_info)
        step_rows.append({
            "idx": idx + 1,
            "phase": phase,
            "status": status,
            "verb": verb,
            "detail": detail,
            "duration_ms": duration,
            "error": err,
            "screenshot": screenshot_img,
            "script_env": enrich_info,
            "sink_match": sink_match,
        })

    fail_screenshot = None
    fp = find_failure_screenshot(debug)
    if fp:
        fail_screenshot = try_b64_image(fp)

    video_b64 = None
    if args.video and os.path.exists(args.video):
        video_b64 = "data:video/mp4;base64," + base64.b64encode(Path(args.video).read_bytes()).decode()

    # Render HTML
    banner_color = "#1f9d55" if overall_pass else "#cc1f1a"
    banner_text = "\u2705 PASSED" if overall_pass else "\u274C FAILED"

    phases_in_order = []
    seen = set()
    for s in step_rows:
        if s["phase"] not in seen:
            seen.add(s["phase"])
            phases_in_order.append(s["phase"])

    html_steps = []
    for phase in phases_in_order:
        phase_steps = [s for s in step_rows if s["phase"] == phase]
        phase_fail = any(s["status"] == "FAILED" for s in phase_steps)
        phase_badge_color = STATUS_COLOR["FAILED"] if phase_fail else STATUS_COLOR["COMPLETED"]
        html_steps.append(
            f'<h3 class="phase"><span class="dot" style="background:{phase_badge_color}"></span>{phase}'
            f' <span class="muted">({len(phase_steps)} steps)</span></h3>'
        )
        html_steps.append('<ol class="steps">')
        for s in phase_steps:
            icon = STATUS_ICON.get(s["status"], "?")
            color = STATUS_COLOR.get(s["status"], "#333")
            safe_detail = (s["detail"] or "").replace("<", "&lt;").replace(">", "&gt;")
            dur = f'{s["duration_ms"]/1000:.2f}s' if s["duration_ms"] else "&mdash;"
            extra = ""
            if s["script_env"]:
                env = s["script_env"]
                extra = (
                    f'<div class="script-detail">'
                    f'<span class="tag">type: <b>{env.get("type")}</b></span> '
                    f'<span class="tag">metric \u2265 <b>{env.get("metric")}</b></span> '
                )
                if env.get("campaign"):
                    extra += f'<span class="tag">campaign: <b>{env.get("campaign")}</b></span> '
                if env.get("max_wait_ms"):
                    extra += f'<span class="tag muted">budget: {int(env["max_wait_ms"])/1000:.0f}s</span>'
                extra += '</div>'

                # Real backend response captured from the sink.
                sm = s["sink_match"]
                if sm:
                    result = sm.get("result") or "?"
                    ok = result == "match"
                    panel_color = "#e6fff0" if ok else "#fff5f5"
                    border_color = "#1f9d55" if ok else "#cc1f1a"
                    result_label = ("\u2705 matched" if ok else "\u274C no match") + f" after {sm.get('attempts')} attempts ({int(sm.get('elapsed_ms', 0))}ms)"
                    rows_html = [f'<div class="backend-row"><span class="k">result</span><span class="v">{result_label}</span></div>']
                    if ok:
                        metrics_obj = sm.get("metrics") or {}
                        metric_chips = " ".join(
                            f'<span class="metric-chip">{k}: {v}</span>'
                            for k, v in metrics_obj.items()
                        )
                        rows_html.append(
                            f'<div class="backend-row"><span class="k">message_id</span>'
                            f'<span class="v mono">{sm.get("message_id")}</span></div>'
                        )
                        rows_html.append(
                            f'<div class="backend-row"><span class="k">campaign_id</span>'
                            f'<span class="v mono">{sm.get("campaign_id")}</span>'
                            f'<span class="k">template</span><span class="v mono">{sm.get("msg_template_id")}</span></div>'
                        )
                        rows_html.append(
                            f'<div class="backend-row"><span class="k">metrics</span>'
                            f'<span class="v">{metric_chips}</span></div>'
                        )
                    else:
                        rows_html.append(
                            f'<div class="backend-row"><span class="k">reason</span>'
                            f'<span class="v mono">{sm.get("reason")}</span></div>'
                        )
                        seen = sm.get("messages_seen")
                        if seen:
                            seen_json = json.dumps(seen, indent=2).replace("<", "&lt;")
                            rows_html.append(
                                f'<details class="backend-row"><summary>messages seen on server</summary>'
                                f'<pre class="mono">{seen_json}</pre></details>'
                            )
                    extra += (
                        f'<div class="backend-panel" style="background:{panel_color};border-left-color:{border_color}">'
                        f'<div class="backend-title">Backend response (Customer.io Ext API)</div>'
                        + "".join(rows_html) +
                        '</div>'
                    )
            err_html = ""
            if s["error"]:
                err_msg = s["error"].replace("<", "&lt;").replace(">", "&gt;")
                err_html = f'<div class="error">{err_msg}</div>'
            shot_html = ""
            if s["screenshot"]:
                shot_html = f'<div class="shot"><img src="{s["screenshot"]}" alt="screenshot"></div>'
            html_steps.append(
                f'<li class="step" style="border-left-color:{color}">'
                f'<div class="row">'
                f'<span class="icon">{icon}</span>'
                f'<span class="verb">{s["verb"]}</span>'
                f'<span class="detail">{safe_detail}</span>'
                f'<span class="dur">{dur}</span>'
                f'</div>'
                f'{extra}{err_html}{shot_html}'
                f'</li>'
            )
        html_steps.append('</ol>')

    fail_block = ""
    if fail_screenshot:
        fail_block = (
            f'<section class="card"><h2>Screen at failure</h2>'
            f'<img class="failshot" src="{fail_screenshot}"></section>'
        )
    video_block = ""
    if video_b64:
        video_block = (
            f'<section class="card"><h2>Device recording</h2>'
            f'<video controls preload="metadata" src="{video_b64}"></video></section>'
        )

    pass_count = by_status.get("COMPLETED", 0)
    fail_count = by_status.get("FAILED", 0)
    skip_count = by_status.get("SKIPPED", 0)

    setup_banner = ""
    if setup_event:
        setup_banner = (
            f'<div class="setup-banner">'
            f'<span class="k">test run</span><span class="v">{setup_event.get("run_id", "")}</span> &nbsp; '
            f'<span class="k">customer email</span><span class="v">{setup_event.get("email", "")}</span>'
            f'</div>'
        )

    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{args.title}</title>
<style>
body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background:#f5f7fa; color:#1a202c; }}
header {{ padding: 24px 32px; background: {banner_color}; color: white; }}
header h1 {{ margin: 0 0 6px; font-size: 22px; }}
header .sub {{ opacity: 0.9; font-size: 14px; }}
.summary {{ display:flex; gap:16px; padding: 18px 32px; background:white; border-bottom:1px solid #e2e8f0; }}
.summary .stat {{ padding: 10px 14px; border-radius: 6px; background:#f7fafc; min-width: 90px; text-align:center; }}
.summary .stat b {{ display:block; font-size: 20px; }}
.summary .stat span {{ font-size: 12px; color:#4a5568; }}
main {{ max-width: 960px; margin: 0 auto; padding: 20px; }}
.card {{ background:white; border-radius: 8px; padding:16px 20px; margin:16px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.04); }}
.phase {{ margin: 22px 0 8px; font-size: 16px; }}
.phase .dot {{ display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:8px; vertical-align:middle; }}
.muted {{ color:#718096; font-weight: normal; font-size: 13px; }}
ol.steps {{ list-style: none; padding: 0; margin: 0; }}
.step {{ background:white; border-left: 4px solid #cbd5e0; border-radius:4px; padding: 10px 14px; margin: 6px 0; box-shadow: 0 1px 2px rgba(0,0,0,0.03); }}
.step .row {{ display: flex; align-items: center; gap: 10px; font-size: 14px; }}
.step .icon {{ font-size: 16px; }}
.step .verb {{ font-weight: 600; color: #2d3748; min-width: 130px; }}
.step .detail {{ color:#4a5568; font-family: "SF Mono", Menlo, monospace; font-size: 13px; flex:1; word-break: break-all; }}
.step .dur {{ color:#718096; font-size: 12px; font-variant-numeric: tabular-nums; }}
.script-detail {{ margin-top: 6px; font-size: 12px; }}
.tag {{ display:inline-block; background:#edf2f7; border-radius:4px; padding: 2px 8px; margin-right:6px; color:#2d3748; }}
.tag.muted {{ background: transparent; color:#718096; padding-left:0; }}
.error {{ margin-top:6px; background:#fff5f5; color:#c53030; padding:8px 12px; border-radius:4px; font-family: "SF Mono", Menlo, monospace; font-size: 12px; }}
.backend-panel {{ margin-top:10px; border-left:4px solid #1f9d55; background:#e6fff0; border-radius:4px; padding:10px 12px; font-size: 12px; }}
.backend-title {{ font-weight: 600; font-size: 12px; color:#2d3748; margin-bottom:6px; letter-spacing: 0.02em; text-transform: uppercase; }}
.backend-row {{ display:flex; gap:8px; margin: 3px 0; align-items:baseline; flex-wrap: wrap; }}
.backend-row .k {{ color:#718096; min-width: 80px; font-weight: 600; font-size:11px; text-transform: uppercase; }}
.backend-row .v {{ color:#1a202c; }}
.backend-row .mono {{ font-family: "SF Mono", Menlo, monospace; }}
.metric-chip {{ display:inline-block; background:#1f9d55; color:white; border-radius:4px; padding: 1px 8px; margin-right: 4px; font-family: "SF Mono", Menlo, monospace; font-size: 11px; }}
.setup-banner {{ background:#fffaf0; border-left:4px solid #dd6b20; padding: 10px 14px; border-radius:4px; margin-bottom:16px; font-size: 13px; }}
.setup-banner .k {{ color:#718096; font-weight:600; font-size: 11px; text-transform: uppercase; margin-right:6px; }}
.setup-banner .v {{ font-family: "SF Mono", Menlo, monospace; }}
.shot {{ margin-top: 10px; }}
.shot img {{ max-height: 360px; border: 1px solid #e2e8f0; border-radius:4px; }}
.failshot {{ max-height: 500px; border: 1px solid #e2e8f0; border-radius:4px; }}
video {{ max-width: 100%; max-height: 560px; background:#000; border-radius:4px; }}
</style>
</head>
<body>
<header>
  <h1>{args.title} &mdash; {banner_text}</h1>
  <div class="sub">Started {started} &middot; Duration {duration_ms/1000:.1f}s</div>
</header>
<div class="summary">
  <div class="stat"><b>{total}</b><span>total</span></div>
  <div class="stat" style="background:#f0fff4"><b style="color:#1f9d55">{pass_count}</b><span>passed</span></div>
  <div class="stat" style="background:#fff5f5"><b style="color:#cc1f1a">{fail_count}</b><span>failed</span></div>
  <div class="stat" style="background:#f7fafc"><b style="color:#718096">{skip_count}</b><span>skipped</span></div>
</div>
<main>
  {setup_banner}
  {''.join(html_steps)}
  {fail_block}
  {video_block}
</main>
</body>
</html>
"""

    out.write_text(html)
    print(f"wrote {out} ({out.stat().st_size/1024:.1f} KB)")


if __name__ == "__main__":
    sys.exit(main() or 0)
