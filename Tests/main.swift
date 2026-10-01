import AppKit

// Minimal test runner: XCTest isn't available with the Command Line Tools
// alone, so tests are a plain executable that exits non-zero on failure.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL \(file):\(line): \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  FAIL threw \(error)")
    }
}

let tempDir = NSTemporaryDirectory() + "clipboard-manager-tests-\(UUID().uuidString)"
try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: tempDir) }

func tempDB() -> String { tempDir + "/\(UUID().uuidString).sqlite" }

/// A private pasteboard, so tests never touch the real clipboard.
func copy(_ string: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

test("clipboard change detection") {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = try HistoryStore(path: tempDB())
    let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

    expect(!monitor.hasChanged, "no change before anything is copied")
    expect(!monitor.poll(), "poll without change stores nothing")
    expect(store.count() == 0, "store stays empty")

    copy("hello", to: pasteboard)
    expect(monitor.hasChanged, "copy is detected")
    expect(monitor.poll(), "poll stores the copied text")
    expect(!monitor.hasChanged, "change is consumed by poll")
    expect(!monitor.poll(), "second poll stores nothing")
    expect(store.search().map(\.text) == ["hello"], "stored text matches")
    expect(abs(store.search()[0].createdAt.timeIntervalSinceNow) < 5, "timestamp recorded")
}

test("content type detection") {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = try HistoryStore(path: tempDB())
    let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

    copy("https://github.com/my-project", to: pasteboard)
    monitor.poll()
    copy("just some text with https://github.com inside", to: pasteboard)
    monitor.poll()
    expect(store.search().map(\.kind) == [.text, .url], "URL and text are told apart")

    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
    image.unlockFocus()
    pasteboard.clearContents()
    pasteboard.setData(image.tiffRepresentation, forType: .tiff)
    monitor.poll()
    expect(store.search().first?.kind == .image, "image is captured")

    pasteboard.clearContents()
    pasteboard.setString("hunter2", forType: .string)
    pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    expect(!monitor.poll(), "concealed (password manager) content is skipped")
}

test("duplicate detection") {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = try HistoryStore(path: tempDB())
    let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

    copy("same", to: pasteboard)
    expect(monitor.poll(), "first copy stored")
    copy("same", to: pasteboard)
    expect(monitor.hasChanged, "re-copy changes the pasteboard")
    expect(!monitor.poll(), "consecutive duplicate not stored")
    expect(store.count() == 1, "only one entry")

    copy("other", to: pasteboard)
    monitor.poll()
    copy("same", to: pasteboard)
    expect(monitor.poll(), "non-consecutive repeat is stored")
    expect(store.search().map(\.text) == ["same", "other"], "repeat moves to top without duplicating")
}

test("history persistence") {
    let path = tempDB()
    var store: HistoryStore? = try HistoryStore(path: path)
    store!.add(.text("first"))
    store!.add(.text("second"))
    store!.add(ClipContent(kind: .image, text: "Image 1×1", data: Data([1, 2, 3])))
    store = nil

    let reopened = try HistoryStore(path: path)
    let items = reopened.search()
    expect(items.map(\.text) == ["Image 1×1", "second", "first"], "items survive reopening, newest first")
    expect(reopened.content(id: items[0].id)?.data == Data([1, 2, 3]), "image data survives")

    reopened.delete(id: items[1].id)
    expect(reopened.search().map(\.text) == ["Image 1×1", "first"], "single item deleted")
    reopened.clear()
    expect(reopened.count() == 0, "clear removes everything")
}

test("search") {
    let store = try HistoryStore(path: tempDB())
    for text in ["github.com", "Hello World", "GitHub repository", "SELECT * FROM users;",
                 "https://github.com/my-project", "100% done"] {
        store.add(.text(text))
    }
    expect(store.search("github").map(\.text)
        == ["https://github.com/my-project", "GitHub repository", "github.com"],
        "partial, case-insensitive, newest first")
    expect(store.search("WORLD").map(\.text) == ["Hello World"], "upper-case query matches")
    expect(store.search("* from").map(\.text) == ["SELECT * FROM users;"], "special characters are literal")
    expect(store.search("%").map(\.text) == ["100% done"], "percent is literal, not a wildcard")
    expect(store.search("nomatch").isEmpty, "no match returns nothing")
    expect(store.search("").count == 6, "empty query returns everything")
    expect(store.search("", limit: 2).count == 2, "limit is respected")
}

test("history limit") {
    let store = try HistoryStore(path: tempDB(), maxItems: 5)
    for i in 1...12 { store.add(.text("item \(i)")) }
    expect(store.count() == 5, "count capped at limit")
    expect(store.search().map(\.text) == ["item 12", "item 11", "item 10", "item 9", "item 8"],
           "oldest items dropped")
    let defaultStore = try HistoryStore(path: tempDB())
    expect(defaultStore.maxItems == 1000, "default limit is 1000")
}

test("clipboard restoration") {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = try HistoryStore(path: tempDB())
    let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

    let multiline = "line one\n\tline two — ünïcödé 🎉"
    copy(multiline, to: pasteboard)
    monitor.poll()
    copy("something newer", to: pasteboard)
    monitor.poll()

    let old = store.search("line one")[0]
    store.content(id: old.id)?.write(to: pasteboard)
    expect(pasteboard.string(forType: .string) == multiline, "text restored exactly")

    expect(monitor.poll(), "restored item is seen as a new copy")
    expect(store.search().map(\.text) == [multiline, "something newer"], "restored item becomes newest")

    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
    store.add(ClipContent(kind: .image, text: "Image", data: png))
    store.content(id: store.search()[0].id)?.write(to: pasteboard)
    expect(pasteboard.data(forType: .png) == png, "image data restored")
}

test("image copy and restore round trip") {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = try HistoryStore(path: tempDB())
    let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = rep.representation(using: .png, properties: [:])!
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    expect(monitor.poll(), "PNG on the clipboard is captured")
    expect(store.search().first?.text == "Image 30×20", "image description has dimensions")

    copy("text in between", to: pasteboard)
    monitor.poll()

    let item = store.search("Image")[0]
    store.content(id: item.id)?.write(to: pasteboard)
    expect(pasteboard.data(forType: .png) == png, "PNG restored byte for byte")
    expect(NSImage(pasteboard: pasteboard) != nil, "restored data is a valid image for pasting")
}

print(failures == 0 ? "\nAll tests passed (\(checks) checks)." : "\n\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
