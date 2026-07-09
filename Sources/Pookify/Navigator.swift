import AppKit
import Foundation

/// "Jump to the terminal running this session." Clicking a session row brings its terminal to the
/// front — and, for terminals that expose their tabs to AppleScript (Terminal.app, iTerm2), selects
/// the exact tab by its tty.
///
/// Two paths, tried in order:
///  1. While the agent process is alive we walk up its parent tree to the owning GUI app (the
///     terminal emulator) and activate it. If that app is Terminal/iTerm we also select the tab.
///  2. Once the agent has exited (a finished session) there's no process to walk, so we probe the
///     running scriptable terminals for a tab whose tty matches and activate whichever one has it.
///
/// Everything that shells out runs off the main thread; app activation hops back to main.
enum Navigator {
    /// Bundle ids of terminals whose tabs we can address by tty via AppleScript.
    private static let scriptable = ["com.apple.Terminal", "com.googlecode.iterm2"]

    static func focus(sessionId: String, agentPid: Int32, tty: String, cwd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // The recorded tty can be stale/empty (a session that hadn't fired a hook since the tty
            // resolver improved). If the process is alive, resolve it fresh from its stdio so the
            // jump works right now.
            var tty = tty
            if tty.isEmpty, agentPid > 0 { tty = resolveTTY(agentPid) }

            // Path 1: the process is alive with an owning GUI app — activate it RIGHT AWAY. Pure
            // AppKit, no AppleScript, so it never needs the Automation permission and can't block.
            // Tab selection (AppleScript) is a best-effort extra done AFTER activation and bounded by
            // a timeout, so a denied/slow prompt can't freeze the jump.
            if jump(toPid: agentPid, tty: tty) { return }

            // Path 2: a Claude Code BACKGROUND-DAEMON session (launched with --bg-pty-host) has no
            // terminal in its own process tree — it's parented to launchd and viewed through a
            // separate foreground `claude` client that attaches to the daemon. Find that client
            // (it holds a cc-daemon socket referencing this session id) and jump to ITS terminal.
            // Relies on Claude Code's daemon socket layout, so it's best-effort and may not hold
            // across CLI versions; if no client is currently attached there's simply nowhere to go.
            if let client = daemonClientPid(sessionId: sessionId, agentPid: agentPid),
               jump(toPid: client, tty: "") {
                return
            }
        }
    }

    /// Bring the terminal hosting `pid` to the front: activate its owning GUI app (AppKit, no
    /// permission) and, for scriptable terminals, select the exact tab by tty. Falls back to
    /// probing scriptable terminals when the process tree has no GUI app but the tty points at a
    /// real tab. Returns whether anything was activated.
    private static func jump(toPid pid: Int32, tty: String) -> Bool {
        let tty = tty.isEmpty ? resolveTTY(pid) : tty
        if let owner = owningApp(of: pid) {
            activate(owner)
            if scriptable.contains(owner.bundleIdentifier ?? ""), !tty.isEmpty {
                _ = selectTab(tty: tty, bundleID: owner.bundleIdentifier!)
            }
            return true
        }
        guard !tty.isEmpty else { return false }
        for bundleID in scriptable {
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first else { continue }
            if selectTab(tty: tty, bundleID: bundleID) {
                activate(app)
                return true
            }
        }
        return false
    }

    /// The foreground `claude` client currently attached to a background-daemon session — the thing
    /// to actually navigate to, since the session's own process is headless. A viewer is a claude
    /// process running in a REAL terminal (so `owningApp` can reach it) that holds an open file in a
    /// `cc-daemon` dir referencing this session: either its id, or the session's pty-host socket
    /// path. Excludes the session's own background processes. Returns nil if no viewer is attached
    /// (then there's genuinely nowhere to jump).
    private static func daemonClientPid(sessionId: String, agentPid: Int32) -> Int32? {
        let shortId = sessionId.split(separator: "-").first.map(String.init) ?? sessionId
        guard shortId.count >= 4 else { return nil }
        let ptySock = ptyHostSocket(near: agentPid)   // this session's pty socket path, if any
        let pids = run("/usr/bin/pgrep", ["-f", "claude"])
            .split(separator: "\n").compactMap { Int32($0) }
        for pid in pids where pid != agentPid {
            // A viewer sits in a real terminal; the background/daemon processes have no tty ("??").
            let t = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == "??" || t == "?" { continue }
            let files = run("/usr/sbin/lsof", ["-p", "\(pid)", "-Fn"])
            guard files.contains("cc-daemon") else { continue }
            if files.contains(shortId) || (ptySock.map { files.contains($0) } ?? false) {
                return pid
            }
        }
        return nil
    }

    /// The pty-host socket path for the session `pid` belongs to, read from the `--bg-pty-host <path>`
    /// argument of the session's process or its parent. This is what a viewer client connects to.
    private static func ptyHostSocket(near pid: Int32) -> String? {
        for p in [pid, parentPid(pid) ?? 0] where p > 1 {
            let cmd = run("/bin/ps", ["-o", "command=", "-p", "\(p)"])
            guard let r = cmd.range(of: "--bg-pty-host ") else { continue }
            if let token = cmd[r.upperBound...].split(separator: " ").first.map(String.init),
               token.contains(".pty.sock") {
                return token
            }
        }
        return nil
    }

    /// Resolve a live process's terminal from its (or an ancestor's) controlling tty or open stdio,
    /// mirroring the hook's resolver — so a click works even when the recorded tty is empty.
    private static func resolveTTY(_ pid: Int32) -> String {
        var cur = pid
        var hops = 0
        while cur > 1 && hops < 12 {
            let ctl = run("/bin/ps", ["-o", "tty=", "-p", "\(cur)"]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: .newlines)
            if !ctl.isEmpty && ctl != "??" && ctl != "?" { return ctl }
            // stdio → terminal, via lsof machine output ("n/dev/ttys000").
            let io = run("/usr/sbin/lsof", ["-a", "-d", "0,1,2", "-p", "\(cur)", "-Fn"])
            for line in io.split(separator: "\n") where line.hasPrefix("n/dev/ttys") {
                return String(line.dropFirst("n/dev/".count))
            }
            guard let pp = parentPid(cur), pp > 1, pp != cur else { break }
            cur = pp
            hops += 1
        }
        return ""
    }

    private static func activate(_ app: NSRunningApplication) {
        DispatchQueue.main.async { app.activate(options: [.activateAllWindows]) }
    }

    // MARK: process tree

    /// The nearest ancestor of `pid` (including itself) that is a regular GUI app — the terminal
    /// emulator hosting the session. Bounded walk so a cycle or a very deep tree can't hang us.
    private static func owningApp(of pid: Int32) -> NSRunningApplication? {
        var byPid: [pid_t: NSRunningApplication] = [:]
        for a in NSWorkspace.shared.runningApplications { byPid[a.processIdentifier] = a }
        var cur = pid
        var hops = 0
        while cur > 1 && hops < 16 {
            if let a = byPid[cur], a.activationPolicy == .regular { return a }
            guard let pp = parentPid(cur), pp != cur else { break }
            cur = pp
            hops += 1
        }
        return nil
    }

    private static func parentPid(_ pid: Int32) -> Int32? {
        let out = run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"])
        return Int32(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: AppleScript tab selection

    /// Select the tab whose tty is `/dev/<tty>` and bring its window forward. Returns whether a
    /// matching tab was found. A denied Automation permission (or any error) reads as "not found".
    private static func selectTab(tty: String, bundleID: String) -> Bool {
        let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script: String
        switch bundleID {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if tty of t is "\(dev)" then
                      set selected tab of w to t
                      set index of w to 1
                      activate
                      return "1"
                    end if
                  end try
                end repeat
              end repeat
            end tell
            return "0"
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    try
                      if tty of s is "\(dev)" then
                        select w
                        select t
                        tell s to select
                        activate
                        return "1"
                      end if
                    end try
                  end repeat
                end repeat
              end repeat
            end tell
            return "0"
            """
        default:
            return false
        }
        return run("/usr/bin/osascript", ["-"], stdin: script)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // MARK: subprocess

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String],
                            stdin: String? = nil, timeout: TimeInterval = 4) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            guard (try? p.run()) != nil else { return "" }
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        } else {
            guard (try? p.run()) != nil else { return "" }
        }
        // Watchdog: a subprocess that outlives the timeout (e.g. osascript stuck on an Automation
        // prompt that never surfaces) is killed, so `readDataToEndOfFile` below can never hang.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
