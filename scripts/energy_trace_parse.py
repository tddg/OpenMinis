#!/usr/bin/env python3
"""Convert OpenMinis energy-trace JSONL files into runs.csv and spans.csv.

Usage:
    python3 scripts/energy_trace_parse.py trace1.jsonl [trace2.jsonl ...] -o outdir

Outputs one row per run (runs.csv) and one row per span (spans.csv), plus
integrity warnings on stderr:
  - unclosed spans / runs lacking a final outcome;
  - clock-order violations (monotonic_ns decreasing within a file);
  - undecodable lines (e.g. a partial final line after a crash) — skipped;
  - duplicate span_end records.

Only decodes the operational metadata the app writes (schema_version 1); no
Power Profiler parsing here — align .trace files in Instruments via the
com.openminis.app.energytrace signposts and the wall_time column.
"""

import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

SPAN_COLUMNS = [
    "run_id", "span_id", "parent_span_id", "name", "start_ns", "end_ns",
    "duration_ms", "success", "cancelled", "timed_out", "leaked", "error_class",
    "execution_surface", "tool_family", "tool_name", "operation",
    "input_bytes", "output_bytes", "exit_code", "command_hash", "pid",
    "provider", "model", "request_index", "input_tokens", "output_tokens",
    "cached_input_tokens", "cache_creation_tokens", "context_tokens",
    "finish_reason", "action", "domain", "tab_id", "screenshot_bytes",
    "downloaded_bytes", "live_tabs", "started_in_background",
    "wall_start", "wall_end", "source_file",
]

RUN_COLUMNS = [
    "run_id", "task_class", "experiment_label", "implementation_variant",
    "run_origin", "success", "completion_reason", "error_class", "duration_ms",
    "start_ns", "end_ns", "wall_start", "wall_end",
    "device_model", "os_version", "app_version", "build_number",
    "network_type", "battery_level_start", "battery_level_end",
    "battery_state_start", "thermal_state_start", "max_thermal_state",
    "low_power_mode", "screen_brightness_start", "app_state_start",
    "model_calls", "tool_calls", "shell_calls", "browser_actions",
    "native_calls", "persist_calls", "input_tokens", "output_tokens",
    "cached_input_tokens", "stream_ms_total", "ttft_ms_mean",
    "shell_ms_total", "browser_ms_total",
    "bytes_downloaded", "screenshot_bytes", "shell_stdout_bytes",
    "resource_samples", "mean_cpu_percent", "peak_cpu_percent",
    "peak_memory_mb", "background_ms_approx", "lifecycle_events",
    "web_content_terminations", "retries", "failed_spans", "leaked_spans",
    "unclosed", "source_file",
]

THERMAL_ORDER = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3, "unknown": -1}


def warn(msg):
    print(f"WARNING: {msg}", file=sys.stderr)


def load_records(path):
    records, bad = [], 0
    with open(path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
                if lineno < sum(1 for _ in open(path)):
                    warn(f"{path}:{lineno}: undecodable line (not the last) — corrupt?")
    if bad:
        warn(f"{path}: skipped {bad} undecodable line(s)")
    return records


def process_file(path, runs_out, spans_out):
    records = load_records(path)
    if not records:
        return

    last_ns = 0
    for r in records:
        ns = r.get("monotonic_ns", 0)
        if ns < last_ns:
            warn(f"{path}: clock-order violation ({ns} < {last_ns})")
        last_ns = ns

    spans = {}           # span_id -> row dict
    ended = set()
    runs = {}            # run_id -> row dict
    samples = defaultdict(list)
    events = defaultdict(list)

    for r in records:
        rt = r.get("record_type")
        rid = r.get("run_id")
        if rt == "run_start":
            runs[rid] = {"run_id": rid, "start_ns": r.get("monotonic_ns"),
                         "wall_start": r.get("wall_time"), "meta": r,
                         "source_file": Path(path).name}
        elif rt == "run_end":
            if rid in runs:
                runs[rid]["end"] = r
        elif rt == "span_start":
            spans[r.get("span_id")] = {"start": r}
        elif rt == "span_end":
            sid = r.get("span_id")
            if sid in ended:
                warn(f"{path}: duplicate span_end for {sid}")
                continue
            ended.add(sid)
            spans.setdefault(sid, {})["end"] = r
        elif rt == "resource_sample":
            samples[rid].append(r)
        elif rt == "event":
            events[rid].append(r)

    def g(rec, key, default=""):
        v = rec.get(key, default)
        return "" if v is None else v

    # ---- spans.csv rows
    span_rows = []
    for sid, pair in spans.items():
        start = pair.get("start", {})
        end = pair.get("end", {})
        if not end:
            warn(f"{path}: unclosed span {sid} ({start.get('name')})")
        if not start and end:
            warn(f"{path}: span_end without span_start {sid} ({end.get('name')})")
        merged = {**start, **end}
        row = {
            "run_id": merged.get("run_id", ""),
            "span_id": sid,
            "parent_span_id": g(merged, "parent_span_id"),
            "name": g(merged, "name"),
            "start_ns": start.get("monotonic_ns", ""),
            "end_ns": end.get("monotonic_ns", ""),
            "wall_start": start.get("wall_time", ""),
            "wall_end": end.get("wall_time", ""),
            "source_file": Path(path).name,
        }
        for col in SPAN_COLUMNS:
            if col not in row:
                row[col] = g(merged, col)
        span_rows.append(row)
        spans_out.writerow({c: row.get(c, "") for c in SPAN_COLUMNS})

    # ---- runs.csv rows
    for rid, run in runs.items():
        meta = run["meta"]
        end = run.get("end")
        if end is None:
            warn(f"{path}: run {rid} lacks run_end")
        endrec = end or {}
        rspans = [s for s in span_rows if s["run_id"] == rid]

        def spans_named(*names):
            return [s for s in rspans if s["name"] in names]

        def total_ms(rows):
            return round(sum(float(s["duration_ms"]) for s in rows
                             if s.get("duration_ms") not in ("", None)), 1)

        model = spans_named("model_request")
        shell = spans_named("shell_execute")
        browser = spans_named("browser_action")
        native = [s for s in shell if s.get("tool_family") not in ("shell", "", None)]
        ttfts = [float(s["duration_ms"]) for s in spans_named("model_time_to_first_token")
                 if s.get("duration_ms") not in ("", None)]
        smp = samples.get(rid, [])
        cpus = [s.get("app_cpu_percent") for s in smp if isinstance(s.get("app_cpu_percent"), (int, float))]
        mems = [s.get("app_memory_mb") for s in smp if isinstance(s.get("app_memory_mb"), (int, float))]
        bg = sum(1 for s in smp if s.get("app_state") == "background")
        interval = 2.0
        thermals = [s.get("thermal_state") for s in smp if s.get("thermal_state")] + \
                   [meta.get("thermal_state", "")]

        def isum(rows, key):
            return sum(int(s[key]) for s in rows if str(s.get(key, "")).lstrip("-").isdigit())

        row = {
            "run_id": rid,
            "task_class": g(meta, "task_class"),
            "experiment_label": g(meta, "experiment_label"),
            "implementation_variant": g(meta, "implementation_variant"),
            "run_origin": g(meta, "run_origin"),
            "success": g(endrec, "success"),
            "completion_reason": g(endrec, "completion_reason"),
            "error_class": g(endrec, "error_class"),
            "duration_ms": g(endrec, "duration_ms"),
            "start_ns": run.get("start_ns", ""),
            "end_ns": endrec.get("monotonic_ns", ""),
            "wall_start": run.get("wall_start", ""),
            "wall_end": endrec.get("wall_time", ""),
            "device_model": g(meta, "device_model"),
            "os_version": g(meta, "os_version"),
            "app_version": g(meta, "app_version"),
            "build_number": g(meta, "build_number"),
            "network_type": g(meta, "network_type"),
            "battery_level_start": g(meta, "battery_level"),
            "battery_level_end": g(endrec, "battery_level"),
            "battery_state_start": g(meta, "battery_state"),
            "thermal_state_start": g(meta, "thermal_state"),
            "max_thermal_state": max(thermals, key=lambda t: THERMAL_ORDER.get(t, -1), default=""),
            "low_power_mode": g(meta, "low_power_mode"),
            "screen_brightness_start": g(meta, "screen_brightness"),
            "app_state_start": g(meta, "app_state"),
            "model_calls": len(model),
            "tool_calls": len(rspans) - len(model)
                          - len(spans_named("model_time_to_first_token", "model_stream",
                                            "model_postprocess", "agent_task",
                                            "shell_output_sanitize")),
            "shell_calls": len(shell),
            "browser_actions": len(browser),
            "native_calls": len(native),
            "persist_calls": len(spans_named("state_persist")),
            "input_tokens": isum(model, "input_tokens"),
            "output_tokens": isum(model, "output_tokens"),
            "cached_input_tokens": isum(model, "cached_input_tokens"),
            "stream_ms_total": total_ms(spans_named("model_stream")),
            "ttft_ms_mean": round(sum(ttfts) / len(ttfts), 1) if ttfts else "",
            "shell_ms_total": total_ms(shell),
            "browser_ms_total": total_ms(browser),
            "bytes_downloaded": isum(browser, "downloaded_bytes"),
            "screenshot_bytes": isum(browser, "screenshot_bytes"),
            "shell_stdout_bytes": isum(shell, "output_bytes") or isum(shell, "stdout_bytes"),
            "resource_samples": len(smp),
            "mean_cpu_percent": round(sum(cpus) / len(cpus), 1) if cpus else "",
            "peak_cpu_percent": round(max(cpus), 1) if cpus else "",
            "peak_memory_mb": max(mems) if mems else "",
            "background_ms_approx": int(bg * interval * 1000),
            "lifecycle_events": len(events.get(rid, [])),
            "web_content_terminations": sum(1 for e in events.get(rid, [])
                                            if e.get("name") == "web_content_terminated"),
            "retries": sum(1 for s in rspans if str(s.get("retry_index", "0")) not in ("0", "")),
            "failed_spans": sum(1 for s in rspans if str(s.get("success")) == "False"),
            "leaked_spans": sum(1 for s in rspans if str(s.get("leaked")) == "True"),
            "unclosed": end is None,
            "source_file": Path(path).name,
        }
        runs_out.writerow({c: row.get(c, "") for c in RUN_COLUMNS})


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", nargs="+", help="energy-trace-*.jsonl files")
    ap.add_argument("-o", "--outdir", default=".", help="output directory")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    with open(outdir / "runs.csv", "w", newline="") as rf, \
         open(outdir / "spans.csv", "w", newline="") as sf:
        runs_out = csv.DictWriter(rf, fieldnames=RUN_COLUMNS)
        spans_out = csv.DictWriter(sf, fieldnames=SPAN_COLUMNS)
        runs_out.writeheader()
        spans_out.writeheader()
        for trace in args.traces:
            process_file(trace, runs_out, spans_out)
    print(f"wrote {outdir/'runs.csv'} and {outdir/'spans.csv'}")


if __name__ == "__main__":
    main()
