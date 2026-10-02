import AppKit
import Darwin

// CaffeinateBar v2 — single-purpose menu bar toggle for `caffeinate`.
// Minimal polling: ONE coalesced Timer (default every 10s, configurable
// 5/10/30s) that checks for *external* caffeinate via libproc (pure syscall,
// no fork/exec) and refreshes the countdown label. No per-second work.
// State changes otherwise come from menu actions + the child's
// terminationHandler (kernel event).

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // MARK: UI
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var onIndefinitelyItem: NSMenuItem!
    private var onForItem: NSMenuItem!
    private var offItem: NSMenuItem!
    private var assertionItems: [String: NSMenuItem] = [:] // flag -> item
    private var pollItems: [NSMenuItem] = []

    // MARK: Session state
    private var caffeinate: Process?
    private var deadline: Date? // nil = indefinite session
    private var externalActive = false
    private var pollTimer: Timer?

    private let iconOff = "cup.and.saucer"
    private let iconOn = "cup.and.saucer.fill"

    // MARK: Persisted settings (UserDefaults)
    private let kWanted = "wantedOn"
    private let kDeadline = "deadlineEpoch"   // 0 = indefinite
    private let kPoll = "pollInterval"        // seconds
    private let flagKeys = ["d", "i", "m", "s", "u"]
    private let flagTitles = [
        "d": "Prevent display sleep (-d)",
        "i": "Prevent idle system sleep (-i)",
        "m": "Prevent disk sleep (-m)",
        "s": "Keep system awake on AC (-s)",
        "u": "Declare user active (-u)",
    ]

    private var pollInterval: Double {
        let v = UserDefaults.standard.double(forKey: kPoll)
        return v > 0 ? v : 10
    }

    private func flag(_ f: String) -> Bool {
        if UserDefaults.standard.object(forKey: "flag_\(f)") == nil {
            return f == "d" || f == "i" || f == "s" // defaults
        }
        return UserDefaults.standard.bool(forKey: "flag_\(f)")
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = .terminationOnRemoval
        statusItem.autosaveName = "CaffeinateBar"

        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "Status: —", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        onIndefinitelyItem = NSMenuItem(title: "Turn On Indefinitely", action: #selector(turnOnIndefinitely), keyEquivalent: "")
        onIndefinitelyItem.target = self
        menu.addItem(onIndefinitelyItem)

        onForItem = NSMenuItem(title: "Turn On For…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, secs) in [("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("5 hours", 18000)] as [(String, Int)] {
            let it = NSMenuItem(title: title, action: #selector(turnOnFor(_:)), keyEquivalent: "")
            it.target = self
            it.tag = secs
            sub.addItem(it)
        }
        onForItem.submenu = sub
        menu.addItem(onForItem)

        offItem = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
        offItem.target = self
        menu.addItem(offItem)
        menu.addItem(.separator())

        let assertions = NSMenuItem(title: "Caffeinate Assertions…", action: nil, keyEquivalent: "")
        let asub = NSMenu()
        for f in flagKeys {
            let it = NSMenuItem(title: flagTitles[f]!, action: #selector(toggleAssertion(_:)), keyEquivalent: "")
            it.target = self
            it.identifier = NSUserInterfaceItemIdentifier("flag_\(f)")
            asub.addItem(it)
            assertionItems[f] = it
        }
        assertions.submenu = asub
        menu.addItem(assertions)

        let pollMenu = NSMenuItem(title: "Check External Every…", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        for secs in [5, 10, 30] {
            let it = NSMenuItem(title: secs == 1 ? "1 second" : "\(secs) seconds", action: #selector(setPollInterval(_:)), keyEquivalent: "")
            it.target = self
            it.tag = secs
            psub.addItem(it)
            pollItems.append(it)
        }
        pollMenu.submenu = psub
        menu.addItem(pollMenu)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Restore previous session (no polling involved).
        let wanted = UserDefaults.standard.bool(forKey: kWanted)
        if wanted {
            let epoch = UserDefaults.standard.double(forKey: kDeadline)
            if epoch == 0 {
                start(duration: nil)
            } else if epoch > Date().timeIntervalSince1970 {
                start(duration: epoch - Date().timeIntervalSince1970)
            } else {
                UserDefaults.standard.set(false, forKey: kWanted)
            }
        }

        externalActive = isExternalCaffeinateRunning()
        updateUI()
        schedulePollTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        stopOwnProcess()
    }

    // MARK: Menu delegate — refresh synchronously on open (cheap libproc call).

    func menuWillOpen(_ menu: NSMenu) {
        checkStatus()
        updateUI()
    }

    // MARK: Actions

    @objc private func turnOnIndefinitely() { start(duration: nil) }

    @objc private func turnOnFor(_ sender: NSMenuItem) {
        start(duration: TimeInterval(sender.tag))
    }

    @objc private func turnOff() {
        UserDefaults.standard.set(false, forKey: kWanted)
        UserDefaults.standard.set(0, forKey: kDeadline)
        deadline = nil
        if externalActive {
            killExternalCaffeinate() // one-shot; timer will confirm on next tick
            externalActive = false
        }
        stop()
    }

    @objc private func toggleAssertion(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("flag_") else { return }
        let f = String(id.dropFirst(5))
        UserDefaults.standard.set(!flag(f), forKey: "flag_\(f)")
        // If currently running with our own process, restart with new flags
        // preserving the remaining time.
        if let p = caffeinate, p.isRunning {
            let remaining = deadline.map { max(0, $0.timeIntervalSinceNow) }
            stopOwnProcess()
            start(duration: remaining)
            if let r = remaining, r == 0 { turnOff() }
        }
        updateUI()
    }

    @objc private func setPollInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag), forKey: kPoll)
        schedulePollTimer()
        updateUI()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Start / stop (owned child process)

    private var isOwnRunning: Bool {
        if let p = caffeinate, p.isRunning { return true }
        return false
    }

    private var isActive: Bool { isOwnRunning || externalActive }

    private func assertionArgs() -> [String] {
        var args: [String] = []
        for f in flagKeys where flag(f) { args.append("-\(f)") }
        if args.isEmpty { args = ["-i"] } // never launch bare; keep a sane default
        return args
    }

    private func start(duration: TimeInterval?) {
        if isOwnRunning { return }
        // Don't double up on a foreign instance — just adopt it.
        if isExternalCaffeinateRunning() {
            externalActive = true
            UserDefaults.standard.set(false, forKey: kWanted)
            UserDefaults.standard.set(0, forKey: kDeadline)
            deadline = nil
            updateUI()
            return
        }
        externalActive = false
        var args = assertionArgs()
        if let d = duration { args += ["-t", "\(Int(d))"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = args
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.caffeinate = nil
                self.deadline = nil
                UserDefaults.standard.set(false, forKey: self.kWanted)
                UserDefaults.standard.set(0, forKey: self.kDeadline)
                self.updateUI()
            }
        }
        do {
            try p.run()
            caffeinate = p
            if let d = duration {
                deadline = Date().addingTimeInterval(d)
                UserDefaults.standard.set(true, forKey: kWanted)
                UserDefaults.standard.set(deadline!.timeIntervalSince1970, forKey: kDeadline)
            } else {
                deadline = nil
                UserDefaults.standard.set(true, forKey: kWanted)
                UserDefaults.standard.set(0, forKey: kDeadline)
            }
        } catch {
            caffeinate = nil
            deadline = nil
            UserDefaults.standard.set(false, forKey: kWanted)
        }
        updateUI()
    }

    private func stop() {
        stopOwnProcess()
        deadline = nil
        updateUI()
    }

    private func stopOwnProcess() {
        if let p = caffeinate, p.isRunning {
            p.terminationHandler = nil
            p.terminate()
        }
        caffeinate = nil
    }

    // MARK: Minimal polling — one timer, libproc only, skips work when we own it.

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        let iv = pollInterval
        let t = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            self?.checkStatus()
            self?.updateUI()
        }
        t.tolerance = max(1, iv * 0.25) // let the system coalesce wakeups
        pollTimer = t
    }

    private func checkStatus() {
        if isOwnRunning {
            // Our child is alive; if it was a timed session that somehow
            // outlived its deadline, normalize the label. No syscall needed.
            if let dl = deadline, dl.timeIntervalSinceNow <= 0 {
                deadline = nil // label falls back; terminationHandler closes out
            }
            return
        }
        externalActive = isExternalCaffeinateRunning()
    }

    /// True if any `caffeinate` process other than our own child exists.
    /// Pure syscall via libproc — no fork/exec, microseconds per call.
    private func isExternalCaffeinateRunning() -> Bool {
        let ownPID: pid_t? = (caffeinate?.isRunning == true) ? caffeinate!.processIdentifier : nil
        var pids = [pid_t](repeating: 0, count: 2048)
        let bufSize = Int32(pids.count * MemoryLayout<pid_t>.size)
        let bytes = pids.withUnsafeMutableBytes { ptr in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress, bufSize)
        }
        guard bytes > 0 else { return false }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        for i in 0 ..< count {
            let pid = pids[i]
            if pid == 0 { continue }
            if let own = ownPID, pid == own { continue }
            var name = [CChar](repeating: 0, count: 256)
            let len = name.withUnsafeMutableBytes { ptr in
                proc_name(pid, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(256))
            }
            if len > 0, String(cString: name) == "caffeinate" { return true }
        }
        return false
    }

    private func killExternalCaffeinate() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", "caffeinate"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: UI (event-driven + one slow timer; menu refreshes on open)

    private func remainingText() -> String? {
        guard let dl = deadline else { return nil }
        let r = max(0, Int(dl.timeIntervalSinceNow))
        if r >= 3600 { return "\(r / 3600)h \((r % 3600) / 60)m left" }
        if r >= 60 { return "\(r / 60)m left" }
        return "\(r)s left"
    }

    private func updateUI() {
        let active = isActive
        let own = isOwnRunning
        let img = NSImage(
            systemSymbolName: active ? iconOn : iconOff,
            accessibilityDescription: active ? "Caffeinate on" : "Caffeinate off"
        )
        if let img {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = active ? "☕︎●" : "☕︎○"
        }

        if active {
            if own, let rem = remainingText() {
                statusMenuItem.title = "Status: Active — \(rem)"
                statusItem.button?.toolTip = "Caffeinate: Active (\(rem))"
            } else if own {
                statusMenuItem.title = "Status: Active — stays awake indefinitely"
                statusItem.button?.toolTip = "Caffeinate: Active (indefinite)"
            } else {
                statusMenuItem.title = "Status: Active — started externally"
                statusItem.button?.toolTip = "Caffeinate: Active (external)"
            }
        } else {
            statusMenuItem.title = "Status: Inactive"
            statusItem.button?.toolTip = "Caffeinate: Inactive"
        }

        onIndefinitelyItem.isHidden = active
        onForItem.isHidden = active
        offItem.isHidden = !active

        for f in flagKeys {
            assertionItems[f]?.state = flag(f) ? .on : .off
        }
        for it in pollItems {
            it.state = Double(it.tag) == pollInterval ? .on : .off
        }

        // Machine-readable status for debugging/tests (no polling needed to read).
        UserDefaults.standard.set(active ? (own ? "active-own" : "active-external") : "inactive", forKey: "lastStatus")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
