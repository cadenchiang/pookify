# Demo & Testing — every scenario

A dev harness to preview **every** state and activity — the animations, icons, and colors —
using fake sessions. It **never touches your real `~/.claude` config** (runs with
`ISLAND_NO_INSTALL=1`).

Run everything from the repo root. First run builds automatically.

```bash
./scripts/demo.sh help        # this reference, in the terminal
./scripts/demo.sh stop        # close the demo + clean up  (always end with this)
```

> **Tip:** the slim bar shows the Claude glyph + a status (timer / check / dot). The **words**
> ("Editing", "Awaiting permission", …) live in the taller drop-down — **hover** the notch to see
> them, or prefix any command with **`EXPAND=1`** to force it open.

---

## Stories (for recording)

Timed, realistic sequences that play **once** with a continuous turn timer, then retract into
the notch — ideal for screen recordings. Each starts with a **3-second countdown** (time to arm
your recording) followed by **~24 seconds** of story. Prefix **`EXPAND=1`** to keep the
activity words visible the whole time.

```bash
./scripts/demo.sh story1     # think → read → edit → await permission → resume → done
./scripts/demo.sh story2     # think → read → edit → run → done  (no permission)
./scripts/demo.sh story3     # think → search web → browse → read → edit → done
./scripts/demo.sh story4     # plan → read → search → edit → run → delegate → MCP → done

./scripts/demo.sh stories    # print this list in the terminal
./scripts/demo.sh stop       # end early / clean up
```

Options (combine freely; applied when the app (re)starts):

```bash
EXPAND=1 ./scripts/demo.sh story1              # keep the activity WORDS visible the whole time
STYLE=spark ./scripts/demo.sh story1           # use the Claude spark glyph instead of the crab
EXPAND=1 STYLE=spark ./scripts/demo.sh story3  # both together
```

- **story1** — the permission flow: thinks, reads, edits, turns amber for *Awaiting permission*,
  then resumes and finishes. The timer keeps running straight through the permission pause.
- **story2** — the same idea without the permission step.
- **story3** — leads with a web search, then browsing, reading, editing.
- **story4** — the "everything" showcase across most activities.

---

## Switch between scenarios

Form: `./scripts/demo.sh <activity>`. Switching is **live** — the island animates from one to the
next without restarting.

The table below is every label the tool can show. Real Claude Code hooks produce all of them; the
demo writes the label directly so you can preview each one for pure UI testing.

| `<activity>` | Label shown |
|---|---|
| `thinking`    | "Thinking…" (morphing spark / pacing crab) |
| `reading`     | "Reading" + file-name subtitle |
| `searching`   | "Searching" (grep/glob)      |
| `running`     | "Running command" (timer crosses 1 min) |
| `editing`     | "Editing" + file-name subtitle |
| `writing`     | "Writing" + file-name subtitle |
| `websearch`   | "Searching web"              |
| `webfetch`    | "Browsing web"               |
| `planning`    | "Planning" (todos / plan)    |
| `delegating`  | "Delegating" (subagent)      |
| `mcp`         | "Using MCP tool"             |
| `diagnostics` | "Checking diagnostics"       |
| `runcode`     | "Running code"               |
| `working`     | "Working…" (any unmapped tool) |
| `compacting`  | "Compacting…"                |
| `permission`  | amber dot, auto-opens "Awaiting permission" |
| `done`        | resting glyph + check        |
| `error`       | warning triangle + "Error"   |

```bash
./scripts/demo.sh thinking
./scripts/demo.sh editing
./scripts/demo.sh running
./scripts/demo.sh delegating
./scripts/demo.sh diagnostics
./scripts/demo.sh permission
./scripts/demo.sh done

# See the label (and the file-name subtitle) without hovering
EXPAND=1 ./scripts/demo.sh editing
EXPAND=1 ./scripts/demo.sh planning
```

---

## Multiple sessions (the session stack)

Real life runs more than one session at once. The **closed bar** stays exactly the single-session
bar and shows the most urgent session: **awaiting permission > working (thinking/tool) > done/error
> idle**; ties break toward the newest turn. **Expanding** the island (hover/click) with 2+ live
sessions replaces the single-session drop-down with the **session stack** — one row per session
(state dot · project · activity · live timer), most urgent first.

```bash
./scripts/demo.sh multi      # 2 sessions: one Editing + one Awaiting permission
./scripts/demo.sh multi 4    # 4 sessions → the stack scrolls
./scripts/demo.sh multi 6    # the works (2–6 supported)
```

With `multi`, you should see the **amber** "Awaiting permission" bar (auto-opened) — the *Editing*
session is live too, but permission outranks working. Hover to see both as rows. **Click a row** to
pin that session to the closed bar (click it again — or right-click → *Unpin* — to go back to
following urgency; a permission request elsewhere always takes the island regardless of the pin).

At most **three rows** are visible; with more sessions the stack scrolls: the next row peeks out
and dissolves into a **deep fog at the bottom edge** — that fade is the scroll hint. It lifts when
you reach the bottom, and mirrors at the top when rows sit above. With 14+ sessions there's a second permission session ("chess-coach") buried deep in
the write order — it still sits at the top, because blocked sessions always sort first. With a
single session, nothing anywhere changes — the island is exactly the classic design. `stop` to
clear.

---

## Animations (open / close)

The slim bar **emerges from the notch** (left↔right) when a session starts and **retracts** into it
when done. The taller drop-down is separate (hover, or `EXPAND=1`).

```bash
./scripts/demo.sh open               # play the emerge once
./scripts/demo.sh close              # play the retract once
./scripts/demo.sh blink              # loop open → close
./scripts/demo.sh finish             # the real "Claude is done" flow: working → done → retract
./scripts/demo.sh cycle              # auto-play EVERY activity
```

---

## Looks — icon style & color

```bash
STYLE=crab ./scripts/demo.sh running          # Clawd, the walking crab, while working
STYLE=crab ./scripts/demo.sh done             # …and at rest — the crab stops on the done frame
STYLE=spark ./scripts/demo.sh thinking        # the morphing spark instead
SHADE=0 ./scripts/demo.sh thinking            # pure black pill (the default / final)
SHADE=0.06 ./scripts/demo.sh thinking         # experiment with near-black shades
SHADE=#0B0B14 ./scripts/demo.sh editing       # or a tinted black (hex)
```

- Claude glyph: **Clawd crab** (default) or **Spark** — also switchable live via right-click →
  *Claude icon*.
- Glyphs **animate while working** (spark morphs / crab walks) and **rest** on permission / done /
  error (spark → full Claude logo, crab → still).
- Pill color default lives in [`Sources/Pookify/Theme.swift`](Sources/Pookify/Theme.swift), `Theme.pill`.

`EXPAND` / `STYLE` / `SHADE` can be combined and are applied when the app (re)starts.

---

## How this maps to the real agent (so the preview matches reality)

The island is driven by **hooks** Claude Code fires. States:

| Event | State shown |
|---|---|
| `SessionStart` | seeds the session (idle) and launches the app |
| `UserPromptSubmit` | Thinking… |
| `PreToolUse` (per tool) | the activity (Editing / Running command / …) |
| `PostToolUse` / `PostToolUseFailure` | back to Thinking… |
| `SubagentStart` / `SubagentStop` | Delegating / back to Thinking… |
| `PreCompact` | Compacting… |
| `PermissionRequest` / `Notification(permission_prompt)` | Awaiting permission |
| `Stop` | Done |
| `StopFailure` | Error |
| `SessionEnd` | session removed (island retracts once none remain) |

Works with **Claude Code** in the terminal and in the VS Code extension.

Everything here uses fake sessions — your real config is untouched. For the real thing:
`./scripts/install.sh`.
