import AppKit

/// Watches a pasteboard's change count and records new values in the store.
/// NSPasteboard has no change notification, so `poll()` is called on a timer.
final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let store: HistoryStore
    private var lastChangeCount: Int

    init(pasteboard: NSPasteboard, store: HistoryStore) {
        self.pasteboard = pasteboard
        self.store = store
        self.lastChangeCount = pasteboard.changeCount
    }

    /// True if the pasteboard changed since the last poll.
    var hasChanged: Bool {
        pasteboard.changeCount != lastChangeCount
    }

    /// Records the pasteboard value if it changed. Returns true if a new
    /// history entry was stored.
    @discardableResult
    func poll() -> Bool {
        guard hasChanged else { return false }
        return captureCurrent()
    }

    /// Records whatever is on the pasteboard right now.
    @discardableResult
    func captureCurrent() -> Bool {
        lastChangeCount = pasteboard.changeCount
        guard let content = ClipContent.read(from: pasteboard) else { return false }
        return store.add(content)
    }
}
