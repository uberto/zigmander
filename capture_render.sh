#!/usr/bin/env bash
# capture_render.sh — build zig-mc, launch in a tmux pane, send keys, capture rendered output.
#
# Usage:  ./capture_render.sh [KEY [KEY ...]]
#
# Each KEY is a tmux key name (case-sensitive).  Regular characters are sent as-is.
# Examples:
#   ./capture_render.sh            — just show the default view
#   ./capture_render.sh m          — toggle modified-date column
#   ./capture_render.sh m c        — toggle both date columns
#   ./capture_render.sh m c p b    — all optional columns + cycle size
#
# Output is written to /tmp/zig-mc-render.txt and also printed to stdout.

set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
BIN="$PROJ/zig-out/bin/zig-mc"
SESSION="zig_mc_capture_$$"
WIDTH=120
HEIGHT=40
OUTPUT=/tmp/zig-mc-render.txt

# ── Build ──────────────────────────────────────────────────────────────────
echo "Building..." >&2
cd "$PROJ"
zig build 2>&1
echo "Build OK." >&2

# ── Launch in a detached tmux session ──────────────────────────────────────
tmux new-session -d -s "$SESSION" -x "$WIDTH" -y "$HEIGHT" "$BIN"

# Give vaxis time to initialise (enter alternate screen, draw first frame)
sleep 0.6

# ── Send keys ─────────────────────────────────────────────────────────────
for key in "$@"; do
    tmux send-keys -t "$SESSION" "$key" ""
    sleep 0.1
done

# Wait one more frame after last keypress
sleep 0.3

# ── Capture the pane content ───────────────────────────────────────────────
tmux capture-pane -t "$SESSION" -p -e > "$OUTPUT"

# ── Tear down ─────────────────────────────────────────────────────────────
tmux send-keys -t "$SESSION" q "" 2>/dev/null || true
sleep 0.1
tmux kill-session -t "$SESSION" 2>/dev/null || true

echo "Saved to $OUTPUT" >&2
echo "--- render ---" >&2
cat "$OUTPUT"
