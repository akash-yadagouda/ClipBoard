import AppKit

/// Panels without a title bar refuse key status unless told otherwise.
private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The small search-and-select window opened by the global shortcut.
final class Picker: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate {
    private let store: HistoryStore
    private let pasteboard: NSPasteboard
    private var items: [HistoryItem] = []

    private let panel: NSPanel
    private let searchField = NSTextField()
    private let table = NSTableView()

    init(store: HistoryStore, pasteboard: NSPasteboard) {
        self.store = store
        self.pasteboard = pasteboard

        // A non-activating panel takes keyboard input without making this
        // process the active app, so focus stays with the previous app.
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let content = panel.contentView!
        let width = content.bounds.width, height = content.bounds.height

        searchField.frame = NSRect(x: 14, y: height - 40, width: width - 28, height: 26)
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.placeholderString = "Search clipboard..."
        searchField.font = .systemFont(ofSize: 17)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        content.addSubview(searchField)

        let separator = NSBox(frame: NSRect(x: 0, y: height - 49, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        content.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseSelected)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 24, width: width, height: height - 74))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)

        let hint = NSTextField(labelWithString: "↑↓ navigate    ⏎ copy    ⌘⌫ delete    esc close")
        hint.frame = NSRect(x: 14, y: 4, width: width - 28, height: 16)
        hint.autoresizingMask = [.width, .maxYMargin]
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        searchField.stringValue = ""
        reload()

        // Centre on the screen the mouse is on, slightly above the middle.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.midY - size.height / 2 + visible.height / 8))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func reload(selecting row: Int = 0) {
        items = store.search(searchField.stringValue)
        table.reloadData()
        guard !items.isEmpty else { return }
        let row = min(max(row, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Puts the selected item on the clipboard and closes the picker.
    @objc private func chooseSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row), let content = store.content(id: items[row].id) else { return }
        content.write(to: pasteboard)
        close()
    }

    private func deleteSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        store.delete(id: items[row].id)
        reload(selecting: row)
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.deleteToBeginningOfLine(_:)): deleteSelected()  // ⌘⌫
        default: return false
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
        cell.textField?.stringValue = items[row].preview
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Window

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
