# Changelog

All notable changes to Pookify are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- **Multi-session management — the session stack.** With two or more live sessions,
  expanding the island now shows every session as a row: state dot, project name,
  current activity (and file), and its live turn timer — most urgent first (a session
  awaiting permission always tops the list). Click a row to pin that session to the
  closed bar; click it again (or right-click → Unpin) to go back to following urgency.
  A permission request anywhere still takes the island over any pin.
- The stack shows at most three rows; with more sessions it scrolls — the next row
  peeks out and dissolves into a deep fog at the bottom edge (the fog lifts at the
  bottom of the scroll, and mirrors at the top once rows sit above).
- With several sessions live, the closed bar's right wing shows a small session-count
  badge instead of a single turn timer (one clock can't speak for many sessions);
  the amber permission dot, the done check, and the single-session timer are unchanged.
- Otherwise the closed bar and the single-session island are completely unchanged.
- Demo harness: `./scripts/demo.sh multi [n]` now spawns 2–6 fake sessions.
- Fixed a crash when the island emerged while the session stack was visible (a
  zero-scale transform is singular; the stack's scroll view asserted converting
  through its inverse).

## [0.1.0]

Initial release: a Dynamic-Island-style status display for Claude Code, live
on the MacBook notch.

- Live activity labels — Thinking, Reading, Writing, Editing, Searching,
  Searching web, Browsing web, Running command, Planning, Delegating,
  Using MCP tool, Compacting and more — with the file name shown under file
  tools and a live turn timer that keeps running across permission waits.
- Amber "Awaiting permission" state that auto-opens once, stays dismissible,
  and resumes (never restarts) the turn clock when you approve.
- Multiple sessions fold into one island; a session awaiting permission
  outranks one that is merely working.
- Clawd the crab (default) or the official Claude spark as the working glyph —
  switchable from the island's right-click menu.
- Works with Claude Code in the terminal and in the VS Code extension; pausing
  or ending a session retracts the island promptly.
- The app launches itself when a session starts and quits itself when nothing
  is running — no daemon, no login item, no network, ever.
- Polished motion: the island always emerges slim from the notch and always
  de-expands before retracting; closing sweeps in from the sides.
- One-command install (`./scripts/install.sh`) and reversible uninstall; a dev
  demo harness previews every state and plays recordable stories (DEMO.md).
