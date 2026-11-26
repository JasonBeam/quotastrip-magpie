#!/usr/bin/env python3
"""Codex-only local quota reader for QuotaStrip.

The reader scans local Codex session logs and returns remaining percentages only
when a current `limit_id: codex` record contains both quota windows.
"""
import glob
import json
import os
import sys
import time
# ---------------------------------------------------------------- Codex

def find_rate_limits(path, tail_bytes=262144):
    """Scan a session log backwards from the tail for the last rate_limits record."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(max(0, size - tail_bytes))
        chunk = f.read().decode("utf-8", errors="replace")
    for line in reversed(chunk.splitlines()):
        if '"rate_limits"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        rl = dig(obj, "rate_limits")
        if rl and rl.get("limit_id") == "codex":
            return rl
    return None


def dig(obj, key):
    if isinstance(obj, dict):
        if key in obj and isinstance(obj[key], dict):
            return obj[key]
        for v in obj.values():
            found = dig(v, key)
            if found:
                return found
    return None


def codex_window(window):
    """Return a reliable remaining percentage, or None when the source is stale/incomplete."""
    if not isinstance(window, dict):
        return None
    reset = window.get("resets_at")
    used = window.get("used_percent")
    if not isinstance(used, (int, float)) or not isinstance(reset, (int, float)) or reset <= time.time():
        return None
    return {"pct": 100.0 - min(max(float(used), 0.0), 100.0), "reset": reset}


def codex_fetch():
    pattern = os.path.expanduser("~/.codex/sessions/*/*/*/*.jsonl")
    files = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    for path in files[:5]:
        try:
            rl = find_rate_limits(path)
        except OSError:
            continue
        if rl:
            five, week = codex_window(rl.get("primary")), codex_window(rl.get("secondary"))
            if five and week:
                return {"five": five, "week": week}
    return None


# ---------------------------------------------------------------- Output

def service_json(data):
    if data is None:
        return {"ok": False, "source": "none"}
    return {"ok": True, "stale": False, "five": data["five"], "week": data["week"], "attention": False, "source": "session"}


def fmt_text(name, data):
    if data is None:
        return f"{name} --"
    five, week = data["five"]["pct"], data["week"]["pct"]
    return f"{name} {five:.0f}·{week:.0f}"


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "json"
    if which == "codex":
        print(fmt_text("CDX", codex_fetch()))
    elif which == "codex-json":
        print(json.dumps(service_json(codex_fetch())))
    else:
        print(json.dumps(service_json(codex_fetch())))


if __name__ == "__main__":
    main()
