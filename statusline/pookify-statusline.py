#!/usr/bin/env python3
"""Pookify status line for Claude Code — a text mirror of the notch island.

Claude Code pipes a JSON blob on stdin (~every 300ms). It carries context-window
usage but NOT the activity state, so we read that from Pookify's own per-session
state file (written by the island-hook, keyed by session_id) to stay in lockstep
with the notch: same states, same colors.

Layout:  ●  project  <label> <spinner>   ██████░░ NN%

Colors match the notch — orange while working/thinking, green when done, amber for
permission/error, gray while waiting, violet while compacting. The context meter is
grey below 50%, amber 50–75%, red at/above 75% (the /compact cue).
"""
import sys, os, json, glob, time

# ── ANSI (256-color) ──────────────────────────────────────────────────────────
RESET, BOLD, DIM = "\033[0m", "\033[1m", "\033[2m"
def fg(n): return "\033[38;5;%dm" % n
ORANGE, GREEN, AMBER, GRAY, RED, DIMW, TRACK = (
    fg(208), fg(78), fg(214), fg(245), fg(203), fg(250), fg(238))

STATE_DIR = os.path.expanduser("~/Library/Application Support/Pookify/state.d")

def read_stdin():
    try:
        return json.loads(sys.stdin.read() or "{}")
    except Exception:
        return {}

def pookify_state(session_id):
    """The island's snapshot for this session: (state, label, project). Empty if none."""
    if not session_id:
        return {}
    # Files are named claude-<sessionId>.json; match by suffix so provider prefix stays flexible.
    for p in glob.glob(os.path.join(STATE_DIR, "*-%s.json" % session_id)):
        try:
            with open(p) as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def color_for(state):
    """(color, is_working) for a Pookify state — the same mapping as the notch dots."""
    if state in ("thinking", "tool", "compacting"):
        return (fg(183) if state == "compacting" else ORANGE), True
    if state in ("done", "completed"):
        return GREEN, False
    if state in ("permission", "error"):
        return AMBER, False
    if state == "waiting":
        return GRAY, False
    return DIMW, False

def context_pct(data):
    """Context-window fill 0..100. Prefer CC's pre-computed value; else derive from the
    transcript's newest usage (older CC builds lack context_window)."""
    cw = data.get("context_window") or {}
    if isinstance(cw.get("used_percentage"), (int, float)):
        return max(0.0, min(100.0, float(cw["used_percentage"])))
    # Fallback: read the transcript tail for the latest assistant usage.
    tr = data.get("transcript_path", "")
    if not tr or not os.path.exists(tr):
        return None
    try:
        with open(tr, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 262144))
            text = f.read().decode("utf-8", "ignore")
    except Exception:
        return None
    for line in reversed(text.split("\n")):
        if '"usage"' not in line:
            continue
        try:
            o = json.loads(line)
            u = (o.get("message") or {}).get("usage") or {}
        except Exception:
            continue
        if not u:
            continue
        tok = sum(float(u.get(k, 0) or 0) for k in (
            "input_tokens", "cache_read_input_tokens",
            "cache_creation_input_tokens", "output_tokens"))
        if tok <= 0:
            return None
        size = cw.get("context_window_size")
        model = (data.get("model") or {}).get("id", "")
        limit = float(size) if size else (1_000_000 if ("[1m]" in model or tok > 190_000) else 200_000)
        return max(0.0, min(100.0, tok / limit * 100))
    return None

def write_ctx_sidecar(session_id, pct):
    """Mirror CC's authoritative context % into a per-session sidecar the notch ring reads.
    CC hides the [1m] 1M window from hooks/transcripts, so the notch's token heuristic can't size
    the window; this hands it CC's real number. Separate file from the island-hook's state (no
    write race); atomic replace so the reader never sees a partial write."""
    if not session_id or pct is None:
        return
    try:
        path = os.path.join(STATE_DIR, "ctx-%s.json" % session_id)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w") as f:
            json.dump({"pct": pct, "ts": time.time()}, f)
        os.replace(tmp, path)
    except Exception:
        pass

def meter(pct, width=8):
    """Plain blocks — no color of its own. The whole bar is tinted one state color by the caller,
    so fill vs. empty reads by block density (█ vs ░), not hue."""
    filled = int(round(pct / 100.0 * width))
    return "█" * filled + "░" * (width - filled)

def main():
    data = read_stdin()
    snap = pookify_state(data.get("session_id", ""))

    state = snap.get("state", "")
    color, _ = color_for(state)

    # Project: prefer the island's (follows `cd`), else the launch dir basename.
    project = snap.get("project") or os.path.basename(
        (data.get("workspace") or {}).get("current_dir", "") or data.get("cwd", "") or "")
    project = project or "session"

    label = snap.get("label", "")
    if not label:
        label = {"done": "Done", "completed": "Done", "permission": "Awaiting permission",
                 "error": "Error", "idle": "Idle"}.get(state, "")

    # The WHOLE bar — context meter included — is one color, the active state color, so it reads
    # from across the room (orange working, green done, amber attention, gray waiting, violet compacting).
    parts = ["●", project]
    if label:
        parts.append(label)
    pct = context_pct(data)
    write_ctx_sidecar(data.get("session_id", ""), pct)
    if pct is not None:
        parts.append("%s %d%%" % (meter(pct), int(round(pct))))

    sys.stdout.write("%s%s%s%s" % (BOLD, color, "  ".join(parts), RESET))

if __name__ == "__main__":
    main()
