#!/usr/bin/env python3
"""IMG-B-PERF-01: read-only audit of retained measurements, no media execution.
Does not treat repeated cumulative snapshots as new samples. P95 withheld for n<20.
"""
import argparse
import hashlib
import json
import math
import re
import statistics
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stats(values):
    if not values or any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError("invalid or empty retained timing series")
    ordered = sorted(values)
    return {"n": len(values), "medianSeconds": statistics.median(values),
            "minimumSeconds": min(values), "maximumSeconds": max(values),
            "p95Seconds": ordered[math.ceil(.95 * len(values)) - 1] if len(values) >= 20 else None,
            "p95Policy": "withheld when n<20; no population tail estimate",
            "samplesSeconds": values}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repository.resolve()
    output = args.output.resolve()
    if not output.is_relative_to(repo / "app/selftest-work") or output.exists():
        raise ValueError("fresh disposable output required")
    work = repo / "app/selftest-work"
    files = {
        "gate1": work / "img-b-poc1r-20261028-01/reader/results.json",
        "gate2": work / "img-b-poc2-20261028-01/gate2/results.json",
        "qa02": work / "img-b-qa02-20261028-01/canonical-v1-reassessment.json",
        "mp4": work / "img-b-poc2-20261028-01/gate2/six-frames.unvalidated.mp4",
    }
    before = {key: digest(path) for key, path in files.items()}
    data = {key: json.loads(files[key].read_text()) for key in ["gate1", "gate2", "qa02"]}
    g1 = {r["name"]: r["fields"] for r in data["gate1"]}
    g2 = {r["name"]: r["fields"] for r in data["gate2"]}
    gate1rows = g1["gate1-decision"]["requests"]
    player = g2["player-six-frame-scheduler"]["requests"]
    afterdetach = g2["player-after-detach"]["requests"]
    export = g2["export-scheduler"]["requests"]
    # This log is cumulative. Only the suffix after the exact retained player prefix is export work.
    if export[:len(afterdetach)] != afterdetach:
        raise ValueError("cannot separate historical export request sequence")
    suffix = export[len(afterdetach):]
    result = {"TASK": "IMG-B-PERF-01", "STATUS": "INCONCLUSIVE",
              "sourceHashes": before, "newMediaRuns": 0, "groups": {},
              "timingBoundary": "Date interval inside process(), after admission worker start; includes source lookup/validation, context allocation, fused renderer and tag/cancellation checks; excludes pending wait/framework predecode/setup/reference/JSON",
              "missing": ["per-stage CPU", "source acquisition duration", "PNG/setup duration", "conversion versus blend versus output split", "allocation versus copying split", "timed queue events", "isolated encoder overhead", "isolated diagnostic overhead"]}
    for scope, rows in [("historicalGate1", gate1rows), ("historicalPlayer", player), ("historicalExport", suffix)]:
        rendered = [r for r in rows if r.get("event") == "rendered"]
        if len(rendered) != 6 or sorted(r["frame"] for r in rendered) != list(range(6)):
            raise ValueError("unexpected retained successful frame sequence")
        groups = {}
        for label, keep in [("imageActive", lambda f: 1 <= f < 5),
                            ("imageOverVideoNoTop", lambda f: f in [1, 4]),
                            ("imageAndTopVideo", lambda f: f in [2, 3]),
                            ("customNoActiveImage", lambda f: f in [0, 5])]:
            selected = [r for r in rendered if keep(r["frame"])]
            groups[label] = stats([r["seconds"] for r in selected])
            groups[label]["frameNumbersInCompletionOrder"] = [r["frame"] for r in selected]
        snapshots = [r["scheduler"] for r in rows if "scheduler" in r]
        groups["scheduler"] = {
            "maximumActive": max(s["maxActive"] for s in snapshots),
            "maximumPending": max(s["maxPending"] for s in snapshots),
            "eventTimestampsPresent": any("timestamp" in e or "seconds" in e for s in snapshots for e in s["events"]),
            "note": "scheduler-instance high-water snapshots; not time-weighted queue depth or per-frame wait"}
        result["groups"][scope] = groups
    result["historicalWrapperCPU"] = {}
    for label, path in [("Gate1", work / "img-b-poc1r-20261028-01/gate1-first.log"),
                        ("Gate2", work / "img-b-poc2-20261028-01/gate2-first.log")]:
        text = path.read_text()
        match = re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", text)
        memory = re.search(r"(\d+)\s+maximum resident set size", text)
        if not match or not memory:
            raise ValueError("retained wrapper accounting absent")
        result["historicalWrapperCPU"][label] = {
            "wallSeconds": float(match[1]), "userSeconds": float(match[2]),
            "systemSeconds": float(match[3]), "maximumRSSBytes": int(memory[1]),
            "scope": "whole historical invocation, includes diagnostics/framework work; not compositor stage CPU"}
    result["historicalExportSessionSeconds"] = g2["export-session-completed"]["seconds"]
    result["historicalGate2Verdict"] = g2["gate2-decision"]["EXPORT"]
    result["historicalQA02Verdict"] = data["qa02"]["REASSESSMENT"]
    if result["historicalGate2Verdict"] != "QUALITY FAIL" or result["historicalQA02Verdict"] != "PASS":
        raise ValueError("historical quality evidence mismatch")
    if before != {key: digest(path) for key, path in files.items()}:
        raise ValueError("retained input changed")
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"status": result["STATUS"], "groups": result["groups"]}, indent=2))


if __name__ == "__main__":
    main()
