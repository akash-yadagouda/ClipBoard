import AppKit

/// Process control for the long-running monitor. A lock held on the PID file
/// is what marks an instance as running, so a stale file is harmless.
enum Daemon {
    private static var lockFD: Int32 = -1
    private static var signalSources: [DispatchSourceSignal] = []

    /// PID of the running manager, or nil if none is running.
    static func runningPID(_ config: Config) -> pid_t? {
        let fd = open(config.pidPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return pid_t(String(decoding: buffer[..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func acquireLock(_ config: Config) -> Bool {
        let fd = open(config.pidPath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            return false
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        lockFD = fd  // kept open for the life of the process
        return true
    }

    /// Runs the monitor in this process until terminated.
    static func run(_ config: Config, store: HistoryStore) -> Never {
        guard acquireLock(config) else {
            let pid = runningPID(config).map { " (pid \($0))" } ?? ""
            fail("Clipboard Manager is already running\(pid).")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar

        let pasteboard = NSPasteboard.general
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
        monitor.captureCurrent()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in monitor.poll() }
        timer.tolerance = 0.1

        let picker = Picker(store: store, pasteboard: pasteboard)
        let hotKeyRegistered = HotKey.register { picker.toggle() }

        signal(SIGHUP, SIG_IGN)
        onSignal(SIGUSR1) { picker.show() }
        for sig in [SIGINT, SIGTERM] {
            onSignal(sig) {
                print("\nClipboard Manager stopped.")
                exit(0)
            }
        }

        print("""
            Clipboard Manager started.

            Monitoring clipboard...
            Press ⌘⇧V to open the picker.
            Press Ctrl+C to stop.
            """)
        if !hotKeyRegistered {
            warn("""
                Warning: could not register ⌘⇧V (another app may own it).
                Use `clipboard-manager show` to open the picker instead.
                """)
        }
        app.run()
        exit(0)
    }

    private static func onSignal(_ sig: Int32, _ handler: @escaping () -> Void) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        signalSources.append(source)
    }

    /// Launches a detached copy of this executable running the monitor.
    static func startInBackground(_ config: Config) {
        if let pid = runningPID(config) {
            print("Clipboard Manager is already running (pid \(pid)).")
            return
        }
        guard let exe = Bundle.main.executablePath else { fail("Cannot locate executable.") }

        // Own session, so closing the Terminal window doesn't take it down.
        // Only status messages go to the log; clipboard contents never do.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, config.logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("run"), nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        guard posix_spawn(&child, exe, &actions, &attributes, argv, environ) == 0 else {
            fail("Failed to start background process.")
        }

        for _ in 0..<30 {
            if let pid = runningPID(config) {
                print("Clipboard Manager started in the background (pid \(pid)).")
                print("Press ⌘⇧V to open the picker. Stop with `clipboard-manager stop`.")
                if let log = try? String(contentsOfFile: config.logPath, encoding: .utf8), !log.isEmpty {
                    warn(log)
                }
                return
            }
            usleep(100_000)
        }
        fail("Background process did not start. See \(config.logPath).")
    }

    static func stop(_ config: Config) {
        guard let pid = runningPID(config) else {
            print("Clipboard Manager is not running.")
            return
        }
        kill(pid, SIGTERM)
        for _ in 0..<30 {
            if runningPID(config) == nil {
                print("Clipboard Manager stopped.")
                return
            }
            usleep(100_000)
        }
        fail("Process \(pid) did not stop.")
    }

    /// Asks the running manager to open the picker.
    static func showPicker(_ config: Config) {
        guard let pid = runningPID(config) else { fail("Clipboard Manager is not running.") }
        kill(pid, SIGUSR1)
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    warn(message)
    exit(1)
}
