import Foundation
import IslandCore

/// One session as the UI shows it: its effective (display) state plus the strings the pill and
/// the session stack render. `id` is the hook's session id, so a row keeps its identity across
/// polls (SwiftUI diffing, pinning).
struct SessionInfo: Identifiable, Equatable {
    let id: String
    var provider: Provider
    var state: AgentState   // effective state (caps/lingers applied), never .idle here
    var label: String       // "Editing", "Thinking…", "Awaiting permission", …
    var detail: String      // file basename while in a tool, else empty
    var project: String     // basename of the session's cwd
    var startedAt: Double   // turn clock start (0 = no active turn)
}

/// Turns the set of on-disk session files into a single decision about what the island should
/// show. Stateless: it reaps dead sessions, recovers frozen ones, and surfaces every live
/// session, ordered by urgency (a permission request always beats one merely working).
struct IslandDecision {
    /// Non-idle sessions, most deserving of attention first: highest priority, then the newest
    /// turn. `startedAt` (not `ts`) breaks ties so rows don't shuffle mid-turn as heartbeats land.
    var sessions: [SessionInfo]
    var visible: Bool
    var liveCount: Int
    var forceExpand: Bool

    static let hidden = IslandDecision(sessions: [], visible: false,
                                       liveCount: 0, forceExpand: false)
}

enum SessionAggregator {

    /// How long a finished ("Done") session stays on screen before the island collapses — long
    /// enough to read the green "Done" after the island auto-opens on completion.
    static let doneLinger: TimeInterval = 6.0
    static let errorLinger: TimeInterval = 3.5
    // Display caps: when a session stops updating (interrupt, closed extension tab) its last
    // state must not stay on screen forever, so a quiet session goes *display-idle* after a
    // while — WITHOUT deleting its file, so a tool that finally reports back (a 10-minute build,
    // a long test run) resumes with its label and turn clock intact.
    // A tool that is still running (toolEndsAt == 0) gets a long window; quiet reasoning
    // (thinking / a finished tool) goes idle much sooner; permission may legitimately sit.
    static let permissionCap: TimeInterval = 7200
    // Backstop only. A cancelled turn is detected deterministically from the transcript's
    // interruption marker (see `interruptedAt`), so this never fires in normal use — it exists
    // purely to eventually clear a true zombie (a turn that died leaving no marker and no process
    // exit, e.g. a fresh session cancelled within a second, before anything was written). It is
    // deliberately generous so a genuinely long silent think is NEVER hidden: liveness counts both
    // hook writes and transcript writes, and this only bites after neither has moved for this long.
    static let workBackstopCap: TimeInterval = 900
    // How long past its last update a session keeps the app alive (so it can quit when the VS
    // Code extension host — whose pid outlives closed sessions — is all that remains).
    static let appHold: TimeInterval = 300
    // Hard reap: delete a file this old no matter what (protects against pid reuse and junk
    // buildup from extension sessions that never fire session-end).
    static let reapCap: TimeInterval = 7200

    static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Whether the agent process has a live child — i.e. it's actively running a command right now
    /// (a foreground tool, a build, or a background shell). This is the ground truth that tells a
    /// genuinely long, quiet turn apart from a finished one whose Stop hook was dropped: a 40-minute
    /// build or a turn parked on a background shell emits NO hooks and writes NO transcript while it
    /// waits, yet its process subtree has live work; a finished turn is just the idle REPL with no
    /// children. Consulted only on the quiet-backstop path, so its `pgrep` cost is never on the hot
    /// path.
    static func agentHasLiveWork(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(pid)"]   // direct children of the agent process
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return !String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Modification time of the session's transcript, or 0 if none. The turn writes to its
    /// transcript continuously while alive, so this is a liveness signal that survives the gaps
    /// between hooks; it freezes the instant a turn is interrupted.
    static func transcriptMTime(_ s: SessionSnapshot) -> Double {
        guard !s.transcript.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: s.transcript),
              let m = attrs[.modificationDate] as? Date else { return 0 }
        return m.timeIntervalSince1970
    }

    /// The state a session effectively contributes right now.
    ///
    /// A cancelled turn is caught by `interruptedAt` (deterministic, no timeout). The only time
    /// caps here are generous backstops for a zombie that left no marker: a working session stays
    /// alive as long as EITHER a hook fired or the transcript was written within the backstop.
    ///
    /// Known limitation (intentionally not handled): a Ctrl+C in the very first second or two,
    /// before Claude Code writes anything, leaves no signal at all — no hook, no transcript, no
    /// marker — so that turn can only clear on the backstop. Detecting it would require a short
    /// timeout that also hides genuinely long silent thinks, which is worse. A cancel mid-turn
    /// (once there's output) is caught fast by the marker; this only affects the instant-undo case.
    static func effectiveState(_ s: SessionSnapshot, now: Double) -> AgentState {
        func aliveWithin(_ cap: TimeInterval) -> Bool {
            now - max(s.ts, transcriptMTime(s)) <= cap
        }
        // A working session is alive if a hook fired / the transcript moved within the backstop OR —
        // when it's gone quiet past that — the agent still has a live child command running. That
        // second clause is what keeps a long build or a turn parked on a background shell from being
        // wrongly declared "Done" after 15 quiet minutes; short-circuits so `pgrep` only runs on the
        // rare quiet path.
        func working(within cap: TimeInterval) -> Bool {
            aliveWithin(cap) || agentHasLiveWork(s.pid)
        }
        // When a working session goes quiet past the backstop and it actually did work
        // (`started`), treat it as FINISHED (.completed), not .idle. A clean finish fires the
        // Stop hook (→ .done → .completed), but that hook is sometimes dropped — notably the VS
        // Code extension, or a turn whose last act was a tool whose completion hook never landed
        // — leaving the snapshot stuck on .thinking/.tool ("Running command…"). Without this it
        // would silently flip to .idle (hidden) and the finished session vanishes instead of
        // showing as Done. An interrupted turn is already caught upstream (interruptedAt → .idle),
        // so it never reaches here; a never-worked session (started == false) still goes .idle.
        func quietFallback() -> AgentState { s.started ? .completed : .idle }
        switch s.state {
        case .thinking:
            return working(within: workBackstopCap) ? .thinking : quietFallback()
        case .compacting:
            // Compaction is real, sometimes long work; hold the purple state while alive, and if it
            // goes quiet past the backstop fall through to Done/idle just like thinking/tool.
            return working(within: workBackstopCap) ? .compacting : quietFallback()
        case .tool:
            // A finished tool (toolEndsAt > 0) lingers briefly so fast tools are visible, then the
            // session is back to reasoning — surface that as thinking, not a stale tool label.
            if s.toolEndsAt > 0 && now > s.toolEndsAt {
                return working(within: workBackstopCap) ? .thinking : quietFallback()
            }
            return working(within: workBackstopCap) ? .tool : quietFallback()
        case .permission:
            return (now - s.ts > permissionCap) ? .idle : .permission
        case .done:
            // A just-finished turn flashes .done briefly (the collapsed check), then settles into
            // .completed — kept in the stack as "Done" rather than vanishing, so you can glance at
            // the island and see which sessions have finished. It clears when the session's next
            // turn overwrites the file (back to thinking/tool) or the session closes (file reaped).
            return (now - s.ts <= doneLinger) ? .done : .completed
        case .error:
            // An errored turn must NOT rest as "Done" — after its flash it goes display-idle, as
            // before. (A resting "failed" row would need its own state to stay honest.)
            return (now - s.ts <= errorLinger) ? .error : .idle
        case .completed:
            return .completed
        case .idle:
            return .idle
        }
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// When the session's turn was interrupted, as a unix timestamp, or nil if it wasn't.
    ///
    /// Claude Code writes an interruption entry to the transcript on Ctrl+C / stop / a denied tool,
    /// and fires NO hook for it. So the transcript is the source of truth. We scan the tail for the
    /// newest such entry and return its timestamp; the caller compares it to the turn's start, so a
    /// marker from a PRIOR turn is ignored and a fresh prompt naturally supersedes it. No timeout is
    /// involved — a turn is interrupted the instant the marker lands, and never otherwise.
    static func interruptedAt(_ s: SessionSnapshot) -> Double? {
        guard !s.transcript.isEmpty,
              let fh = FileHandle(forReadingAtPath: s.transcript) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return nil }
        let window: UInt64 = 65536
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // Newest line last; scan backward for the first interruption entry.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard isInterruptLine(line) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = obj["timestamp"] as? String else { continue }
            return (isoFrac.date(from: ts) ?? iso.date(from: ts))?.timeIntervalSince1970 ?? 0
        }
        return nil
    }

    /// Whether one transcript line is a genuine interruption entry. Mirrors the patterns Claude
    /// Code writes (user "[Request interrupted…]" markers, an errored/interrupted tool result),
    /// while a cheap substring pre-check keeps the common non-matching line fast.
    private static func isInterruptLine<S: StringProtocol>(_ line: S) -> Bool {
        if line.contains("Request interrupted by user"),
           let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           (obj["type"] as? String) == "user" {
            let marker = "[Request interrupted by user"
            let c = (obj["message"] as? [String: Any])?["content"]
            if let str = c as? String { return str.hasPrefix(marker) }
            if let blocks = c as? [[String: Any]] {
                return blocks.contains { ($0["type"] as? String) == "text"
                    && (($0["text"] as? String) ?? "").hasPrefix(marker) }
            }
        }
        if line.contains("\"interrupted\":true") { return true }
        return false
    }

    /// Read all files, reap dead ones, and decide what to surface.
    static func evaluate(now: Double = Date().timeIntervalSince1970) -> IslandDecision {
        var live: [SessionSnapshot] = []
        for url in StateStore.listFiles() {
            guard var snap = StateStore.read(url) else { continue }
            // Delete a file only on hard evidence: its process died, or it is ancient. Mere
            // staleness hides the session (display-idle above) but keeps the file, preserving
            // turn-clock continuity for tools that go quiet for a long time.
            let processGone = snap.pid > 0 && !pidAlive(snap.pid)
            if processGone || now - snap.ts > reapCap {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // A turn interrupted (Ctrl+C / stop / denied tool) after it began is dead now — the
            // transcript's interruption marker says so, with no hook and no timeout. Collapse it to
            // idle so the island retracts within a poll; the file stays, and the next prompt (a
            // newer startedAt) revives it. Done once per session here, off the hot path.
            if snap.startedAt > 0, let it = interruptedAt(snap), it >= snap.startedAt - 2 {
                snap.state = .idle
                snap.startedAt = 0
                snap.toolEndsAt = 0
            }
            live.append(snap)
        }

        // Effective state per session, then a visibility rule for finished ("completed") ones.
        // A finished session stays on screen only while ANY other session is still active
        // (working / permission / a transient done-or-error flash) — that's when "1 done, 1
        // still going" is worth a glance. The moment nothing is active the completed ones go
        // display-idle too and the island recedes, exactly as a single session always has:
        // with one session the done flash plays and the notch goes dark, pixel-identical to
        // the pre-stack behavior.
        let effs = live.map { effectiveState($0, now: now) }
        let anyActive = effs.contains { $0 != .idle && $0 != .completed }
        // "Busy" = something genuinely demanding attention: working, awaiting permission, or an
        // error flash. When nothing is busy but two or more sessions have finished, keep the whole
        // finished set on screen as a green "all done" roster — each row a green check — instead of
        // receding to a single big checkmark. A lone finished session still flashes done and then
        // recedes, exactly as one session always has.
        let busy = effs.contains { $0.isWorking || $0 == .permission || $0 == .error }
        let finishedCount = effs.filter { $0 == .completed || $0 == .done }.count
        let allDoneRoster = !busy && finishedCount >= 2
        func displayState(_ i: Int) -> AgentState {
            let e = effs[i]
            if allDoneRoster {
                // Surface every finished session as a calm green check, not the orange done flash.
                return (e == .completed || e == .done) ? .completed : .idle
            }
            if e == .completed, !anyActive { return .idle }
            return e
        }

        // Sessions that are visibly doing something — or only went quiet moments ago — keep the
        // app alive. Long-idle files (e.g. closed extension sessions whose host pid persists)
        // don't, so the app can still quit itself.
        let liveCount = live.indices.filter {
            displayState($0) != .idle || now - live[$0].ts <= appHold
        }.count
        guard !live.isEmpty else { return .hidden }

        // Every session with something to say, as the UI will render it. Display-idle sessions
        // are omitted (they're resting, not gone — their files persist for turn-clock continuity).
        let sessions: [SessionInfo] = live.indices.compactMap { i -> SessionInfo? in
            let eff = displayState(i)
            guard eff != .idle else { return nil }
            let s = live[i]
            return SessionInfo(
                id: s.sessionId,
                provider: s.provider,
                state: eff,
                // When a tool has lingered out to thinking, show "Thinking…" rather than the stale tool label.
                label: (s.state == .tool && eff == .thinking) ? "Thinking…" : s.label,
                // The file subtitle only makes sense while actually in a tool (not once it lingers out).
                detail: eff == .tool ? s.detail : "",
                project: s.project,
                startedAt: s.startedAt
            )
        }.sorted { a, b in
            if a.state.priority != b.state.priority { return a.state.priority > b.state.priority }
            // The newest TURN first — `startedAt` is stable for a turn's whole life, so rows never
            // shuffle just because one session's heartbeat (`ts`) landed after another's.
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.id < b.id
        }

        return IslandDecision(
            sessions: sessions,
            visible: !sessions.isEmpty,   // hide while everything rests; the app stays alive
            liveCount: liveCount,
            forceExpand: sessions.first?.state == .permission
        )
    }
}
