#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Pookify — DEV DEMO HARNESS
#
# Preview EVERY state/activity using fake Claude Code sessions. It never
# touches your real ~/.claude config (runs ISLAND_NO_INSTALL=1).
#
# Usage:
#   ./scripts/demo.sh <activity>              Claude doing <activity>
#   ./scripts/demo.sh story1|story2|story3|story4   play a timed story (for recording)
#   ./scripts/demo.sh stories                 list the stories + what each shows
#   ./scripts/demo.sh multi [n]               n live sessions (2-30) → the session stack; a
#                                             permission outranks working; 4+ scrolls
#   ./scripts/demo.sh record [n] [hold]       recordable clip: 5s countdown → n sessions appear
#                                             (nothing auto-expands) → hold → retract
#   ./scripts/demo.sh open|close|blink|finish play the open/close animations
#   ./scripts/demo.sh closes                  play open → close five times, then stop
#   ./scripts/demo.sh cycle                   auto-play through everything
#   ./scripts/demo.sh stop                    close the demo + clean up
#
# Stories (3s countdown, then ~24s of story, then it retracts — good for screen recordings):
#   story1 / permission   think → read → edit → await permission → resume → done
#   story2 / basic        think → read → edit → run → done (no permission)
#   story3 / web          think → search web → browse → read → edit → done
#   story4 / everything   plan → read → search → edit → run → delegate → MCP → done
#   (prefix EXPAND=1 to keep the activity WORDS visible the whole time)
#
# Activities (every label the tool can show):
#   thinking  reading  searching  running  editing  writing  websearch  webfetch
#   planning  delegating  mcp  diagnostics  runcode  working
#   compacting  permission  done  error
#   (the slim bar shows the glyph + a status; the WORDS appear when expanded)
#
# Options (env — applied on (re)start; combine freely):
#   EXPAND=1              force the taller drop-down open so you can read the label
#   STYLE=spark|crab      Claude glyph (default crab — Clawd)
#   SHADE=<0..1 | #hex>   pill color (0 = pure black, the default)
#
# Examples:
#   ./scripts/demo.sh editing
#   EXPAND=1 ./scripts/demo.sh reading      # shows the file-name subtitle too
#   EXPAND=1 STYLE=spark ./scripts/demo.sh delegating
#   SHADE=0.06 ./scripts/demo.sh permission
#   ./scripts/demo.sh blink         # watch open/close
#   ./scripts/demo.sh cycle         # watch everything
#   ./scripts/demo.sh stop
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "demo.sh: failed to cd to the repo root" >&2; exit 1; }

REPO="$(pwd)"
SD="$HOME/Library/Application Support/Pookify/state.d"
RUN="$HOME/Library/Application Support/Pookify/.demo"
APP="$REPO/.build/debug/Pookify"
mkdir -p "$SD" "$RUN"

# Kill the keep-alive sleep (so Ctrl-C out of a loop doesn't orphan it).
kill_sleep() { [ -f "$RUN/sleep.pid" ] && kill "$(cat "$RUN/sleep.pid")" 2>/dev/null; rm -f "$RUN/sleep.pid"; }
# Minimal JSON string escaping (backslash + double quote) for interpolated paths.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

live_pid() {
  if [ -f "$RUN/sleep.pid" ] && kill -0 "$(cat "$RUN/sleep.pid")" 2>/dev/null; then
    cat "$RUN/sleep.pid"
  else
    nohup sleep 100000 >/dev/null 2>&1 &
    echo $! | tee "$RUN/sleep.pid"
  fi
}
app_running() { pgrep -x Pookify >/dev/null 2>&1; }
ensure_app() {
  app_running && return 0
  [ -x "$APP" ] || { echo "Building…"; swift build >/dev/null 2>&1 || { swift build; exit 1; }; }
  ISLAND_NO_INSTALL=1 \
  ISLAND_CLAUDE_STYLE="${STYLE:-crab}" \
  ISLAND_PILL="${SHADE:-}" \
  ISLAND_FORCE_EXPAND="${EXPAND:-}" \
  nohup "$APP" >/dev/null 2>&1 &
  echo $! > "$RUN/app.pid"
  sleep 0.6
}

# write_state <state> <label> <tool> <startedSecondsAgo> [detail]
write_state() {
  local lp now st
  lp="$(live_pid)"; now="$(date +%s)"; st=0
  [ "${4:-0}" -gt 0 ] 2>/dev/null && st=$((now - $4))
  rm -f "$SD"/*.json 2>/dev/null
  printf '{"schema":1,"provider":"claude","sessionId":"demo","state":"%s","label":"%s","tool":"%s","project":"pookify","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":%s,"ts":%s,"started":true,"detail":"%s"}' \
    "$1" "$2" "${3:-}" "$(json_escape "$REPO")" "$lp" "$st" "$now" "${5:-}" > "$SD/claude-demo.json"
}
write_idle() {
  local lp now; lp="$(live_pid)"; now="$(date +%s)"; rm -f "$SD"/*.json 2>/dev/null
  printf '{"schema":1,"provider":"claude","sessionId":"demo","state":"idle","label":"","tool":"","project":"","cwd":"%s","model":"","pid":%s,"startedAt":0,"ts":%s,"started":false}' \
    "$(json_escape "$REPO")" "$lp" "$now" > "$SD/claude-demo.json"
}

# ── Story mode: play a realistic, timed sequence of states for recording ──────
# scene_state writes an ABSOLUTE startedAt (unlike write_state's "seconds ago"),
# so the live timer counts up continuously across a whole story — including
# straight through an "Awaiting permission" pause, exactly like a real turn.
scene_state() { # state label tool startAbs [detail]
  local lp now; lp="$(live_pid)"; now="$(date +%s)"; rm -f "$SD"/*.json 2>/dev/null
  printf '{"schema":1,"provider":"claude","sessionId":"demo","state":"%s","label":"%s","tool":"%s","project":"pookify","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":%s,"ts":%s,"started":true,"detail":"%s"}' \
    "$1" "$2" "${3:-}" "$(json_escape "$REPO")" "$lp" "${4:-0}" "$now" "${5:-}" > "$SD/claude-demo.json"
}

# play_story <replay-name> <title> <step...>   step = "secs|state|label|tool|detail"
# A `done` step shows the check (timer hidden); the story always ends by retracting.
play_story() {
  local replay="$1" title="$2"; shift 2
  if [ -n "${STYLE:-}${SHADE:-}${EXPAND:-}" ]; then pkill -x Pookify 2>/dev/null; sleep 0.25; fi
  echo "▸ story '$replay': $title"
  echo "  (tip: prefix EXPAND=1 to keep the words visible while recording; STYLE=spark|crab to pick the glyph)"
  # A short runway so you can start/arrange your screen recording before the island emerges.
  echo -n "  starting in 3"; sleep 1; echo -n " … 2"; sleep 1; echo -n " … 1"; sleep 1; echo " … go"
  local START; START="$(date +%s)"
  local first="$1"; shift
  local secs st label tool detail
  IFS='|' read -r secs st label tool detail <<< "$first"
  # Write the first state BEFORE launching so the very first poll sees it (a force-expand launch
  # would otherwise reset to collapsed on the first empty tick).
  scene_state "$st" "$label" "$tool" "$START" "$detail"
  ensure_app
  sleep "$secs"
  for step in "$@"; do
    IFS='|' read -r secs st label tool detail <<< "$step"
    case "$st" in
      done) scene_state "done" "Done" "" 0 "" ;;
      error) scene_state error "Error" "" 0 "" ;;
      idle) write_idle ;;
      *)    scene_state "$st" "$label" "$tool" "$START" "$detail" ;;
    esac
    sleep "$secs"
  done
  write_idle                       # retract into the notch (de-expands first, then slides in)
  sleep 1.2                        # let the close animation finish before we return
  echo "  ✓ finished. replay: ./scripts/demo.sh $replay   |   stop: ./scripts/demo.sh stop"
}

# The named stories (each ~24s, plays once, then retracts).
story() {
  case "$1" in
    story1|permission)
      play_story story1 "think → read → edit → await permission → resume → done" \
        "3|thinking|Thinking…||" \
        "4|tool|Reading|Read|sidebar.tsx" \
        "4|tool|Editing|Edit|sidebar.tsx" \
        "5|permission|Awaiting permission|Bash|" \
        "4|tool|Running command|Bash|" \
        "4|done|Done||" ;;
    story2|basic)
      play_story story2 "think → read → edit → run → done (no permission)" \
        "4|thinking|Thinking…||" \
        "5|tool|Reading|Read|sidebar.tsx" \
        "6|tool|Editing|Edit|AppController.swift" \
        "5|tool|Running command|Bash|" \
        "4|done|Done||" ;;
    story3|web)
      play_story story3 "think → search web → browse → read → edit → done" \
        "3|thinking|Thinking…||" \
        "5|tool|Searching web|WebSearch|" \
        "4|tool|Browsing web|WebFetch|" \
        "4|tool|Reading|Read|notch-spec.md" \
        "4|tool|Editing|Edit|README.md" \
        "4|done|Done||" ;;
    story4|everything)
      play_story story4 "the works: plan → read → search → edit → run → delegate → MCP → done" \
        "2|thinking|Thinking…||" \
        "2.4|tool|Planning|TodoWrite|" \
        "2.4|tool|Reading|Read|SessionAggregator.swift" \
        "2.4|tool|Searching|Grep|" \
        "3|tool|Editing|Edit|SessionAggregator.swift" \
        "3|tool|Running command|Bash|" \
        "2.4|tool|Delegating|Task|" \
        "2.4|tool|Using MCP tool|mcp__server__tool|" \
        "4|done|Done||" ;;
    *) echo "Unknown story '$1'. Try: story1 (permission), story2 (basic), story3 (web), story4 (everything)."; exit 1 ;;
  esac
}

# resolve <activity>  -> sets STATE, LABEL, TOOL, AGO, DETAIL (returns 1 if unknown)
resolve() {
  local a="$1"; TOOL=""; AGO=0; DETAIL=""
  case "$a" in
    thinking)   STATE=thinking; LABEL="Thinking…"; AGO=8 ;;
    reading)    STATE=tool; LABEL="Reading"; TOOL=Read; AGO=12; DETAIL="sidebar.tsx" ;;
    searching)  STATE=tool; LABEL="Searching"; TOOL=Grep; AGO=15 ;;
    running)    STATE=tool; LABEL="Running command"; TOOL=Bash; AGO=72 ;;
    editing)    STATE=tool; LABEL="Editing"; TOOL=Edit; AGO=45; DETAIL="AppController.swift" ;;
    writing)    STATE=tool; LABEL="Writing"; TOOL=Write; AGO=20; DETAIL="NewFile.swift" ;;
    websearch)  STATE=tool; LABEL="Searching web"; TOOL=WebSearch; AGO=18 ;;
    webfetch)   STATE=tool; LABEL="Browsing web"; TOOL=WebFetch; AGO=10 ;;
    planning)   STATE=tool; LABEL="Planning"; TOOL=TodoWrite; AGO=6 ;;
    delegating) STATE=tool; LABEL="Delegating"; TOOL=Task; AGO=30 ;;
    mcp)        STATE=tool; LABEL="Using MCP tool"; TOOL="mcp__server__tool"; AGO=14 ;;
    diagnostics) STATE=tool; LABEL="Checking diagnostics"; TOOL=mcp__ide__getDiagnostics; AGO=8 ;;
    runcode)    STATE=tool; LABEL="Running code"; TOOL=mcp__ide__executeCode; AGO=9 ;;
    working)    STATE=tool; LABEL="Working…"; TOOL=SomeTool; AGO=12 ;;
    compacting) STATE=tool; LABEL="Compacting…"; AGO=5 ;;
    permission) STATE=permission; LABEL="Awaiting permission"; TOOL=Bash; AGO=0 ;;
    done)       STATE="done"; LABEL="Done"; AGO=0 ;;
    error)      STATE=error; LABEL="Error"; AGO=0 ;;
    *) return 1 ;;
  esac
}

show() { # activity
  if ! resolve "$1"; then
    echo "Unknown activity '$1'. Run './scripts/demo.sh help' for the list."; exit 1
  fi
  if [ -n "${STYLE:-}${SHADE:-}${EXPAND:-}" ]; then pkill -x Pookify 2>/dev/null; sleep 0.25; fi
  # Write the session BEFORE launching so the very first poll sees it visible (otherwise a
  # force-expand launch gets reset to collapsed on the first empty tick).
  write_state "$STATE" "$LABEL" "$TOOL" "$AGO" "$DETAIL"
  ensure_app
  echo "▸ $1  →  \"$LABEL\"  (STYLE=${STYLE:-crab} SHADE=${SHADE:-black} EXPAND=${EXPAND:-0})"
  echo "  next: ./scripts/demo.sh <activity>   |   stop: ./scripts/demo.sh stop"
}

# The full activity set, used by `cycle`.
CLAUDE_ACTS="thinking reading searching running editing writing websearch webfetch planning delegating mcp diagnostics runcode compacting working permission done error"

cmd="${1:-help}"
case "$cmd" in
  stop)
    for p in blink finish cycle story; do pkill -f "demo.sh $p" 2>/dev/null; done
    pkill -x Pookify 2>/dev/null
    [ -f "$RUN/sleep.pid" ] && kill "$(cat "$RUN/sleep.pid")" 2>/dev/null
    rm -rf "$SD"/*.json "$RUN" 2>/dev/null
    echo "Demo stopped." ;;

  story1|story2|story3|story4|permission|basic|web|everything)
    story "$cmd" ;;

  stories)
    echo "Recordable stories (3s countdown, then ~24s of story, then it retracts):"
    echo "  story1 / permission   think → read → edit → await permission → resume → done"
    echo "  story2 / basic        think → read → edit → run → done (no permission)"
    echo "  story3 / web          think → search web → browse → read → edit → done"
    echo "  story4 / everything   plan → read → search → edit → run → delegate → MCP → done"
    echo
    echo "Run:   ./scripts/demo.sh story1        (add EXPAND=1 to keep the words visible)"
    echo "       EXPAND=1 STYLE=spark ./scripts/demo.sh story3" ;;

  open)
    write_idle; ensure_app; sleep 0.6
    write_state thinking "Thinking…" "" 1
    echo "OPEN — the slim bar emerges from the notch (left↔right)." ;;

  close)
    ensure_app; write_idle
    echo "CLOSE — the slim bar retracts into the notch." ;;

  closes)
    # Play open → close five times in a row, then stop — for judging the close animation.
    ensure_app
    echo "Playing open → close 5 times…"
    for i in 1 2 3 4 5; do
      write_state thinking "Thinking…" "" 1; sleep 2.2
      write_idle; sleep 2.2
      echo "  close #$i"
    done
    echo "Done. Replay: ./scripts/demo.sh closes   |   stop: ./scripts/demo.sh stop" ;;

  blink)
    ensure_app
    echo "Open→close loop (Ctrl-C to stop the loop; 'stop' to close the app)…"
    trap 'kill_sleep; exit 0' INT
    while true; do write_state thinking "Thinking…" "" 1; sleep 3; write_idle; sleep 2.5; done ;;

  finish)
    ensure_app
    echo "The real 'Claude is done' flow: working → done → retract (loops; Ctrl-C to stop)…"
    trap 'kill_sleep; exit 0' INT
    while true; do
      resolve running; write_state "$STATE" "$LABEL" "$TOOL" 5; sleep 3
      resolve "done";  write_state "$STATE" "$LABEL" "$TOOL" 0; sleep 2.5
      write_idle; sleep 2.5
    done ;;

  cycle)
    ensure_app
    echo "Cycling every activity (Ctrl-C to stop the loop; 'stop' to close)…"
    trap 'kill_sleep; exit 0' INT
    while true; do
      for a in $CLAUDE_ACTS; do resolve "$a"; write_state "$STATE" "$LABEL" "$TOOL" "$AGO" "$DETAIL"; sleep 2.6; done
      write_idle; sleep 1.5
    done ;;

  multi)
    # N live sessions at once (2-30, default 2) → the closed bar shows the most urgent one (a
    # permission request outranks the merely-working); expanding reveals the session stack —
    # one row per session, blocked first. 4+ sessions make the stack scroll (3 rows + a fogged
    # half-row peek). Sessions beyond the six named ones are generated with varied projects,
    # activities and turn ages; #14 is a second permission, buried deep, so you can watch
    # blocked sessions float to the top of the stack no matter when they arrived.
    n="${2:-2}"
    case "$n" in *[!0-9]*|'') echo "usage: ./scripts/demo.sh multi [2-30]"; exit 1 ;; esac
    [ "$n" -lt 2 ] && n=2
    [ "$n" -gt 30 ] && n=30
    lp="$(live_pid)"; now="$(date +%s)"; rm -f "$SD"/*.json 2>/dev/null
    if [ -n "${STYLE:-}${SHADE:-}${EXPAND:-}" ]; then pkill -x Pookify 2>/dev/null; sleep 0.25; fi
    # id|project|state|label|tool|startedSecondsAgo|detail  — moon-lander's permission keeps its turn
    # clock running (startedAt > 0), exactly like a real blocked turn.
    specs=(
      "multiA|pixel-forge|tool|Editing|Edit|45|sidebar.tsx"
      "multiB|moon-lander|permission|Awaiting permission|Bash|130|"
      "multiC|coffee-tracker|tool|Running command|Bash|750|deploy.sh"
      "multiD|dream-journal|thinking|Thinking…||8|"
      "multiE|recipe-rocket|tool|Searching web|WebSearch|18|"
      "multiF|synthwave-fm|tool|Reading|Read|65|README.md"
    )
    extra_names=(tiny-rpg plant-daddy budget-ninja meme-factory star-charts lo-fi-player
                 sourdough-lab chess-coach habit-hero robo-vacuum cat-cam wordle-solver
                 retro-arcade taco-finder night-sky paper-plane code-golf pixel-pet
                 rain-sounds road-trip zine-maker garden-gnome drone-pilot portfolio-v9)
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "$i" -lt "${#specs[@]}" ]; then
        IFS='|' read -r id proj st label tool ago detail <<< "${specs[$i]}"
      else
        j=$((i - ${#specs[@]}))
        id="multi$i"; proj="${extra_names[$((j % ${#extra_names[@]}))]}"
        if [ "$j" -eq 7 ]; then
          st=permission; label="Awaiting permission"; tool=Bash; detail=""
        else
          case $((j % 4)) in
            0) st=tool; label="Editing"; tool=Edit; detail="main.swift" ;;
            1) st=tool; label="Running command"; tool=Bash; detail="" ;;
            2) st=thinking; label="Thinking…"; tool=""; detail="" ;;
            3) st=tool; label="Reading"; tool=Read; detail="README.md" ;;
          esac
        fi
        ago=$((25 + (j * 37) % 1100))
      fi
      printf '{"schema":1,"provider":"claude","sessionId":"%s","state":"%s","label":"%s","tool":"%s","project":"%s","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":%s,"ts":%s,"started":true,"detail":"%s"}' \
        "$id" "$st" "$label" "$tool" "$proj" "$(json_escape "$REPO")" "$lp" "$((now-ago))" "$now" "$detail" \
        > "$SD/claude-$id.json"
      i=$((i+1))
    done
    ensure_app
    echo "▸ $n live sessions."
    echo "  → Closed: the bar shows the most urgent session (moon-lander's amber permission), unchanged look."
    echo "  → Hover/click: the session stack — blocked first, then the newest turns; click a row to pin."
    [ "$n" -ge 4 ] && echo "  → With $n sessions the stack scrolls — the fourth row fogs into the black as the hint."
    echo "  next: ./scripts/demo.sh multi 4   |   back to one: ./scripts/demo.sh editing   |   stop: ./scripts/demo.sh stop" ;;

  record)
    # A recordable clip, all default behavior: 5s countdown (arrange your screen recorder) →
    # N working sessions appear at once (island emerges slim; NOTHING auto-expands — no
    # permission session in this set) → holds for a few seconds (hover yourself to show the
    # stack if you like) → sessions clear and the island retracts into the notch.
    #   record [sessions] [holdSecs]     defaults: 10 sessions, 5s hold
    n="${2:-10}"; hold="${3:-5}"
    case "$n" in *[!0-9]*|'') echo "usage: ./scripts/demo.sh record [sessions] [holdSecs]"; exit 1 ;; esac
    case "$hold" in *[!0-9]*|'') echo "usage: ./scripts/demo.sh record [sessions] [holdSecs]"; exit 1 ;; esac
    [ "$n" -lt 2 ] && n=2
    [ "$n" -gt 24 ] && n=24
    lp="$(live_pid)"; rm -f "$SD"/*.json 2>/dev/null
    # A hand-picked cast (project|state|label|tool|turnSecondsAgo|detail): repos that read like
    # a real product company — a SaaS landing page in .tsx, an iOS app in SwiftUI, an API
    # deploying, docs, dashboards — and never a permission (nothing may auto-open on camera).
    rec_specs=(
      "saas-landing|tool|Editing|Edit|47|Hero.tsx"
      "ios-app|tool|Editing|Edit|132|Paywall.swift"
      "pricing-page|thinking|Thinking…||9|"
      "api-server|tool|Running command|Bash|754|"
      "dashboard|tool|Reading|Read|23|Chart.tsx"
      "checkout|tool|Searching web|WebSearch|65|"
      "marketing-site|tool|Writing|Write|38|globals.css"
      "mobile-app|tool|Editing|Edit|210|Onboarding.swift"
      "docs-site|tool|Reading|Read|17|quickstart.md"
      "billing-service|tool|Running command|Bash|92|"
      "admin-panel|tool|Editing|Edit|306|UsersTable.tsx"
      "auth-service|tool|Planning|TodoWrite|12|"
      "blog|tool|Editing|Edit|58|post-editor.tsx"
      "analytics|thinking|Thinking…||81|"
      "widget-kit|tool|Writing|Write|26|StatsWidget.swift"
      "search-service|tool|Searching|Grep|44|"
      "design-system|tool|Reading|Read|173|Button.tsx"
      "landing-v2|tool|Editing|Edit|15|Pricing.tsx"
      "support-bot|thinking|Thinking…||247|"
      "cli-tool|tool|Running command|Bash|530|"
      "onboarding-flow|tool|Editing|Edit|69|StepTwo.swift"
      "status-page|tool|Reading|Read|33|uptime.ts"
      "ios-widgets|tool|Writing|Write|121|Timeline.swift"
      "email-templates|tool|Searching web|WebSearch|29|"
    )
    echo "▸ recording clip: $n sessions, ${hold}s hold, then retract."
    echo -n "  starting in 5"; sleep 1
    for c in 4 3 2 1; do echo -n " … $c"; sleep 1; done; echo " … go"
    now="$(date +%s)"
    i=0
    for spec in "${rec_specs[@]}"; do
      [ "$i" -ge "$n" ] && break
      IFS='|' read -r proj st label tool ago detail <<< "$spec"
      printf '{"schema":1,"provider":"claude","sessionId":"rec%s","state":"%s","label":"%s","tool":"%s","project":"%s","cwd":"%s","model":"claude-opus-4-8","pid":%s,"startedAt":%s,"ts":%s,"started":true,"detail":"%s"}' \
        "$i" "$st" "$label" "$tool" "$proj" "$(json_escape "$REPO")" "$lp" "$((now-ago))" "$now" "$detail" \
        > "$SD/claude-rec$i.json"
      i=$((i+1))
    done
    ensure_app
    sleep "$hold"
    rm -f "$SD"/claude-rec*.json
    echo "  ✓ clip done — the island is retracting. Replay: ./scripts/demo.sh record $n $hold" ;;

  help|-h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0" ;;

  claude)
    show "${2:-thinking}" ;;

  *)
    show "$cmd" ;;
esac
