import Foundation
import IslandCore

// island-hook — the bridge between Claude Code's hooks and the notch app.
//
// Invoked by Claude Code hooks as:   island-hook claude <kind>
//   kind:     session-start | prompt | pre | post | post-fail | permission | denied |
//             notify | subagent-start | subagent-stop | compact | stop | stop-fail | session-end
//
// The hook's JSON payload arrives on stdin. We map the event to this session's normalized
// state and write it atomically to a per-session file. Hooks must be fast and must never
// fail the agent, so everything here is best-effort and exits 0.

let args = CommandLine.arguments
let providerArg = args.count > 1 ? args[1] : ""
let kind = args.count > 2 ? args[2] : ""
let provider = Provider(rawValue: providerArg) ?? .claude

// Read the hook payload (JSON on stdin). Tolerate empty/garbage input.
let rawInput = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: rawInput) as? [String: Any]) ?? [:]

func str(_ key: String) -> String { (payload[key] as? String) ?? "" }

// The agent process that spawned this hook (stable for the session). kill(pid,0) drives liveness.
let parentPID = getppid()

func now() -> Double { Date().timeIntervalSince1970 }

// How long a finished fast tool's label (and file name) lingers before the island falls back to
// "Thinking…". Long enough to actually read the file name on a quick Read/Edit, without holding a
// stale label so long it feels laggy.
let toolLingerSeconds = 1.9

// Debug tracing: ISLAND_DEBUG=1 in the agent's environment, or — since hooks spawned by the
// VS Code extension don't inherit a terminal's env — the presence of a `debug-on` file next to
// the state directory (`touch "~/Library/Application Support/Pookify/debug-on"`).
let debugOn = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"
    || FileManager.default.fileExists(atPath: Island.supportDir.appendingPathComponent("debug-on").path)

func debugLog(_ msg: String) {
    guard debugOn else { return }
    Island.ensureDirs()
    let line = "\(Date()) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: Island.debugLog) {
        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
    } else {
        try? data.write(to: Island.debugLog)
    }
}

// session_id is resolved just below; log it here so a specific session can be isolated in the
// trace (the VS Code extension interleaves several). Kept short for readable lines.
let dbgSess = str("session_id").isEmpty ? "pid-\(parentPID)" : String(str("session_id").prefix(8))
if debugOn {
    debugLog("[\(dbgSess)] [\(provider.rawValue)/\(kind)] tool=\(str("tool_name")) type=\(str("notification_type")) source=\(str("source")) permMode=\(str("permission_mode")) keys=\(payload.keys.sorted().joined(separator: ","))")
    if let bt = payload["background_tasks"] {
        debugLog("    background_tasks(raw) = \(bt)")
    }
}

// The background tasks the CLI is still waiting on after a turn stops. Claude Code stamps a
// `background_tasks` array onto the Stop and SubagentStop payloads (the roster behind the CLI's
// "Waiting for N background agents to finish"). Each entry is a dict:
//   { type: "subagent" | "shell", status: "running" | …, id, description, agent_type|command }
// so we can tell delegated agents apart from background shell commands, and count only the ones
// still running. Absent / any other shape reads as empty, so the feature simply doesn't trigger —
// safe even if this (undocumented) field changes.
//
// A subagent still appears as `status:running` in its OWN SubagentStop payload (the roster lags
// that event by one), so callers pass `excludingId` = the event's `agent_id` to get the true
// remaining set.
func runningBackgroundTasks(excludingId: String = "") -> (agents: Int, others: Int) {
    let arr = (payload["background_tasks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    var agents = 0, others = 0
    for t in arr {
        if !excludingId.isEmpty, (t["id"] as? String) == excludingId { continue }
        // A missing status counts as running — better to show "waiting" than a premature "done".
        let status = ((t["status"] as? String) ?? "running").lowercased()
        guard status == "running" else { continue }
        if (t["type"] as? String) == "subagent" { agents += 1 } else { others += 1 }
    }
    return (agents, others)
}

/// The status label for a session parked on background work. Mirrors the CLI's wording for agents
/// ("Waiting for N agents"); background shells read as "tasks"; a mix reads generically as "tasks".
func waitingLabel(agents: Int, others: Int) -> String {
    let n = agents + others
    if n <= 0 { return "Waiting for agents" }
    if others == 0 { return n == 1 ? "Waiting for 1 agent" : "Waiting for \(n) agents" }
    if agents == 0 { return n == 1 ? "Waiting for 1 task"  : "Waiting for \(n) tasks" }
    return "Waiting for \(n) tasks"
}

/// This event belongs to a background subagent (its tool calls fire pre/post under the parent
/// session id, but tagged with agent_id), as opposed to the main agent's own activity.
let isSubagentEvent = !str("agent_id").isEmpty

// Resolve which session this is. Hook payloads carry session_id; fall back to the agent pid
// so a payload without one still maps to a stable file for the session's lifetime.
let sessionId: String = {
    let s = str("session_id")
    return s.isEmpty ? "pid-\(parentPID)" : s
}()

let cwd = str("cwd")
let project = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
let model = str("model")

/// One `ps` field for a pid (e.g. its tty or ppid), trimmed. Empty on any failure.
func psField(_ field: String, _ pid: Int32) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "\(field)=", "-p", "\(pid)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The terminal a pid's stdin/stdout/stderr are wired to, via `lsof` — e.g. "ttys000". This catches
/// the common case a process has NO *controlling* tty (launched detached / by a wrapper, so `ps tty`
/// says "??") yet its stdio still goes to a real terminal tab. Returns "" if none.
func ttyViaStdio(_ pid: Int32) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-a", "-d", "0,1,2", "-p", "\(pid)", "-Fn"]   // machine output; name fields
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    // `-Fn` emits name lines like "n/dev/ttys000". Return the first ttys device found.
    for line in out.split(separator: "\n") where line.hasPrefix("n/dev/ttys") {
        return String(line.dropFirst("n/dev/".count))
    }
    return ""
}

/// The session's terminal (e.g. "ttys003"), for click-to-navigate. The agent process often has no
/// *controlling* tty — it's commonly launched through a wrapper or detached — so we look both at the
/// controlling tty AND at where its (or an ancestor's) stdio actually points, walking up the process
/// tree and returning the first real terminal found. Computed once and carried forward on later
/// events (it's stable for the session), so only the first event pays the `ps`/`lsof` cost.
func resolveTTY() -> String {
    var pid = parentPID
    var hops = 0
    while pid > 1 && hops < 12 {
        let ctl = psField("tty", pid)
        if !ctl.isEmpty && ctl != "??" && ctl != "?" { return ctl }
        let io = ttyViaStdio(pid)
        if !io.isEmpty { return io }
        guard let pp = Int32(psField("ppid", pid)), pp > 1, pp != pid else { break }
        pid = pp
        hops += 1
    }
    return ""
}

// Previous snapshot (for turn-start continuity and carrying over fields the event lacks).
let prev = StateStore.read(StateStore.fileURL(provider: provider, sessionId: sessionId))

// The session's tty is stable, so resolve it once and carry it forward — only the first event of
// a session pays the `ps` cost.
let tty: String = {
    if let t = prev?.tty, !t.isEmpty { return t }
    return resolveTTY()
}()

// Claude Code stamps every event of one turn with the same prompt_id. The turn clock
// (`startedAt`) belongs to a turn, so we key it off this: the clock only restarts when a
// genuinely new turn begins. Carry the current turn's id forward on events that omit it.
let eventPromptId = str("prompt_id")
let turnPromptId = eventPromptId.isEmpty ? (prev?.promptId ?? "") : eventPromptId
// True when this event belongs to the SAME turn as the last snapshot — so re-fired activity
// within a turn (e.g. the VS Code extension re-emitting a prompt/tool around a permission
// accept) must NOT reset the clock.
let sameTurn = !turnPromptId.isEmpty && turnPromptId == (prev?.promptId ?? "")

func launchApp() {
    // Bring the (background) app up if it isn't already. Ignore failures (e.g. not yet
    // registered with Launch Services during local development).
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", Island.bundleID]
    try? p.run()
    // Dev convenience: if an explicit app path is provided, try that too.
    if let path = ProcessInfo.processInfo.environment["ISLAND_APP_PATH"], !path.isEmpty {
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        q.arguments = ["-g", path]
        try? q.run()
    }
}

/// Whether the notch app is currently running, via the pid file it maintains. A missing or
/// stale pid reads as "not running", which just means we spawn a redundant `open` — harmless.
func appIsRunning() -> Bool {
    guard let s = try? String(contentsOf: Island.appPidFile, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
    else { return false }
    return kill(pid, 0) == 0
}

// The file a file-tool is acting on, basename only ("App.swift"), for the status subtitle. Empty for
// tools without a file path. Read from the hook's tool_input payload.
func toolDetail() -> String {
    guard let input = payload["tool_input"] as? [String: Any] else { return "" }
    for key in ["file_path", "notebook_path", "path"] {
        if let p = input[key] as? String, !p.isEmpty { return (p as NSString).lastPathComponent }
    }
    return ""
}

func writeState(_ state: AgentState, label: String, tool: String = "", startedAt: Double,
                started: Bool, toolEndsAt: Double = 0, detail: String = "") {
    let snap = SessionSnapshot(
        provider: provider,
        sessionId: sessionId,
        state: state,
        label: label,
        tool: tool,
        project: project.isEmpty ? (prev?.project ?? "") : project,
        cwd: cwd.isEmpty ? (prev?.cwd ?? "") : cwd,
        model: model.isEmpty ? (prev?.model ?? "") : model,
        pid: parentPID,
        startedAt: startedAt,
        ts: now(),
        started: started,
        toolEndsAt: toolEndsAt,
        detail: detail,
        promptId: turnPromptId,
        transcript: str("transcript_path").isEmpty ? (prev?.transcript ?? "") : str("transcript_path"),
        tty: tty
    )
    StateStore.write(snap)
    debugLog("    wrote state=\(state.rawValue) label=\(label) startedAt=\(String(format: "%.1f", startedAt)) promptId=\(turnPromptId.prefix(8)) (prev.startedAt=\(String(format: "%.1f", prev?.startedAt ?? 0)) prev.state=\(prev?.state.rawValue ?? "nil"))")
}

/// The turn's start time: reuse the previous snapshot's when we're still in the same turn (a
/// running clock), otherwise start it now. This is the single source of truth for the clock.
func turnStart() -> Double {
    if sameTurn, let s = prev?.startedAt, s > 0 { return s }
    return carriedStart > 0 ? carriedStart : now()
}

let carriedStart = prev?.startedAt ?? 0

switch kind {
case "session-start":
    if str("source") == "compact", let p = prev, p.tool == "compact-auto" {
        // Auto-compaction restarts the session mid-turn (SessionStart fires again with
        // source:"compact"): keep the turn alive and its clock intact instead of resetting to idle,
        // so the island doesn't blink and the timer doesn't restart in the middle of real work.
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    } else if str("source") == "compact", let p = prev, p.tool == "compact-manual" {
        // A manual /compact just finished: mark it Done — it flashes the green "Done" and then
        // settles/recedes like any completed turn — so compaction reads as a finished action.
        writeState(.done, label: "Done", startedAt: 0, started: true)
    } else {
        // Seed an idle marker so the session counts immediately. started:false keeps a
        // merely-opened session quiet until it does real work.
        writeState(.idle, label: "", startedAt: 0, started: false)
    }

case "prompt":
    // A prompt with a NEW prompt_id starts a fresh turn: clock from NOW — even if the previous
    // turn never got a Stop (an interrupted extension turn leaves a stale working snapshot, and
    // carrying its clock forward would show a bogus old timer). Only a prompt re-fired within the
    // SAME turn — which the VS Code extension can do around a permission accept — resumes the
    // running clock.
    writeState(.thinking, label: "Thinking…",
               startedAt: sameTurn && carriedStart > 0 ? carriedStart : now(), started: true)

case "pre":
    // While parked on background agents (main turn already Stopped), the subagents' own tool
    // calls keep firing pre/post under this session. Don't let them flip the label off
    // "Waiting …" — hold the waiting state. A tool call from the MAIN agent (no agent_id) means
    // the turn genuinely resumed, so let that fall through and show the tool.
    if prev?.state == .waiting, isSubagentEvent {
        writeState(.waiting, label: prev?.label ?? "Waiting for agents",
                   startedAt: turnStart(), started: true)
        break
    }
    let tool = str("tool_name")
    writeState(.tool, label: toolLabel(provider: provider, tool: tool), tool: tool,
               startedAt: turnStart(), started: true,
               detail: toolDetail())

case "post", "post-fail":
    // Same as `pre`: a background subagent finishing a tool during the post-turn wait must not
    // knock the island off "Waiting …". Only the main agent (no agent_id) proceeds normally.
    if prev?.state == .waiting, isSubagentEvent {
        writeState(.waiting, label: prev?.label ?? "Waiting for agents",
                   startedAt: turnStart(), started: true)
        break
    }
    // The tool just finished. Keep its label (and the file name) up for a short linger: fast tools
    // fire pre+post within milliseconds — faster than the app's poll — so without this every
    // read/edit/command would flash by too fast to read. The linger holds the label ~1.9s after the
    // tool finishes, long enough to actually read the file name, then the app falls back to
    // "Thinking…" for the reasoning that follows. So the status is visible and readable during
    // tools AND accurate ("Thinking…") while it reasons.
    let postTool = str("tool_name").isEmpty ? (prev?.tool ?? "") : str("tool_name")
    if postTool.isEmpty {
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    } else {
        let d = toolDetail().isEmpty ? (prev?.detail ?? "") : toolDetail()
        writeState(.tool, label: toolLabel(provider: provider, tool: postTool), tool: postTool,
                   startedAt: turnStart(), started: true,
                   toolEndsAt: now() + toolLingerSeconds, detail: d)
    }

case "subagent-start":
    writeState(.tool, label: "Delegating", tool: "Task",
               startedAt: turnStart(), started: true)

case "subagent-stop":
    // A background agent just finished. Exclude it from the roster (it still shows as running in
    // its own SubagentStop payload) to get what's genuinely left.
    let remaining = runningBackgroundTasks(excludingId: str("agent_id"))
    if prev?.state == .waiting {
        // We were parked waiting on background work. If anything is still running, stay waiting
        // (refresh the count); if that was the last one, the turn is truly finished → Done.
        if remaining.agents + remaining.others > 0 {
            writeState(.waiting, label: waitingLabel(agents: remaining.agents, others: remaining.others),
                       startedAt: turnStart(), started: true)
        } else {
            writeState(.done, label: "Done", startedAt: 0, started: true)
        }
    } else if let p = prev, p.state == .thinking || p.state == .tool {
        // Mid-turn: a delegated (in-turn) subagent returned and the main agent keeps going. Claude
        // Code also runs background auxiliary agents (conversation title, memory) whose
        // SubagentStop lands seconds AFTER the turn's Stop — those hit the .done/.completed branch
        // above (no-op) and never resurrect a finished session into a phantom "Thinking…".
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    }

case "compact":
    // Stash the trigger ("auto" mid-turn vs "manual" /compact) in the tool field so the
    // compact-restarted session-start above knows whether to keep the turn alive.
    writeState(.compacting, label: "Compacting…", tool: "compact-\(str("trigger"))",
               startedAt: turnStart(), started: true)

case "permission":
    writeState(.permission, label: "Awaiting permission",
               startedAt: turnStart(), started: true)   // keep the turn clock; don't restart it on resume

case "denied":
    // A permission was denied — the model is about to respond to that, so fall back to thinking
    // right away instead of leaving the amber "Awaiting permission" up until the next event.
    if let p = prev, p.state == .permission || p.state.isWorking {
        writeState(.thinking, label: "Thinking…",
                   startedAt: turnStart(), started: true)
    }

case "notify":
    // ONLY an explicit permission prompt drives the island. The old version also matched any message
    // containing "permission"/"approve"/"allow", which fired on unrelated notifications — e.g. right
    // after you accepted, an "…allowed" notification re-opened "Awaiting permission" and caused the
    // open/close/timer churn. Match the exact notification type instead; ignore everything else.
    if str("notification_type").lowercased() == "permission_prompt" {
        writeState(.permission, label: "Awaiting permission",
                   startedAt: turnStart(), started: true)   // keep the turn clock; don't restart it
    }

case "stop":
    // A turn cannot truly end while a tool is still awaiting your approval. Some surfaces (the VS
    // Code extension) fire Stop when they suspend the turn to show a permission dialog; honoring it
    // would flash "Done", collapse the island, then re-open on accept — the churn you'd notice as
    // "it closed and reopened with a fresh timer". Ignore a Stop that lands mid-permission; the
    // real end (post -> stop) arrives after you accept.
    if prev?.state == .permission {
        debugLog("    ignored spurious stop while awaiting permission")
    } else {
        // The main turn has stopped, but if background agents are still running the turn is NOT
        // done — the CLI shows "Waiting for N background agents to finish". Reflect that as a
        // distinct (gray) waiting state, keeping the turn clock, instead of a premature "Done".
        // The real Done lands later, when the last background agent's SubagentStop fires.
        let bg = runningBackgroundTasks()
        if bg.agents + bg.others > 0 {
            writeState(.waiting, label: waitingLabel(agents: bg.agents, others: bg.others),
                       startedAt: turnStart(), started: true)
        } else {
            writeState(.done, label: "Done", startedAt: 0, started: true)
        }
    }

case "stop-fail":
    if prev?.state == .permission {
        debugLog("    ignored spurious stop-fail while awaiting permission")
    } else {
        writeState(.error, label: "Error", startedAt: 0, started: true)
    }

case "session-end":
    StateStore.remove(provider: provider, sessionId: sessionId)

default:
    break
}

// The app quits itself when idle, so ANY sign of life must be able to bring it back — not just
// session-start. Without this, a session whose start the app missed (or that outlives an idle
// self-quit) would stay invisible for its whole life.
if kind != "session-end", !appIsRunning() {
    launchApp()
}

exit(0)
