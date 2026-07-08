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

    static func focus(agentPid: Int32, tty: String, cwd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Path 1: the process is alive — activate its owning terminal app RIGHT AWAY. This is
            // the navigation itself: pure AppKit, no AppleScript, so it never needs the Automation
            // permission and can never block. Tab selection (AppleScript) is a best-effort extra
            // done AFTER activation and hard-bounded by a timeout, so a denied/slow prompt can't
            // freeze the jump — the terminal is already frontmost regardless.
            if let owner = owningApp(of: agentPid) {
                activate(owner)
                if scriptable.contains(owner.bundleIdentifier ?? ""), !tty.isEmpty {
                    _ = selectTab(tty: tty, bundleID: owner.bundleIdentifier!)
                }
                return
            }
            // Path 2: no live process (a finished session) — we can't walk the tree, so probe the
            // scriptable terminals for the tab holding this tty and activate whichever has it.
            guard !tty.isEmpty else { return }
            for bundleID in scriptable {
                guard let app = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID).first else { continue }
                if selectTab(tty: tty, bundleID: bundleID) {
                    activate(app)
                    return
                }
            }
        }
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
