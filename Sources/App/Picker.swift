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
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let metaLabel = NSTextField(labelWithString: "")

    private static let width: CGFloat = 920
    private static let height: CGFloat = 520
    /// Text previews are cut off here to keep very large copies responsive.
    private static let maxPreviewChars = 50_000

    init(store: HistoryStore, pasteboard: NSPasteboard) {
        self.store = store
        self.pasteboard = pasteboard

        // A non-activating panel takes keyboard input without making this
        // process the active app, so focus stays with the previous app.
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: Picker.width, height: Picker.height),
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
        let listWidth: CGFloat = 330
        let top = height - 49  // y of the separator under the search field
        let bottom: CGFloat = 24  // height of the hint row

        searchField.frame = NSRect(x: 14, y: height - 40, width: width - 28, height: 26)
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.placeholderString = "Search clipboard..."
        searchField.font = .systemFont(ofSize: 17)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        content.addSubview(searchField)

        let separator = NSBox(frame: NSRect(x: 0, y: top, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        content.addSubview(separator)

        // List (left)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        column.width = listWidth
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.headerView = nil
        table.rowHeight = 28
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseSelected)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: bottom, width: listWidth, height: top - bottom))
        scroll.autoresizingMask = [.height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)
        table.sizeLastColumnToFit()

        let divider = NSBox(frame: NSRect(x: listWidth, y: bottom, width: 1, height: top - bottom))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]
        content.addSubview(divider)

        // Preview (right): full text, or the image scaled to fit.
        let previewX = listWidth + 1
        let previewWidth = width - previewX
        let metaHeight: CGFloat = 22
        let previewFrame = NSRect(x: previewX, y: bottom + metaHeight,
                                  width: previewWidth, height: top - bottom - metaHeight)

        textScroll.frame = previewFrame
        textScroll.autoresizingMask = [.width, .height]
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textView.frame = NSRect(origin: .zero, size: previewFrame.size)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        content.addSubview(textScroll)

        imageView.frame = previewFrame.insetBy(dx: 12, dy: 12)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.isHidden = true
        content.addSubview(imageView)

        metaLabel.frame = NSRect(x: previewX + 10, y: bottom + 2, width: previewWidth - 20, height: 16)
        metaLabel.autoresizingMask = [.width, .maxYMargin]
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(metaLabel)

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
        guard !items.isEmpty else {
            updatePreview()
            return
        }
        let row = min(max(row, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updatePreview()
    }

    private func updatePreview() {
        let row = table.selectedRow
        guard items.indices.contains(row), let content = store.content(id: items[row].id) else {
            textView.string = ""
            imageView.image = nil
            textScroll.isHidden = false
            imageView.isHidden = true
            metaLabel.stringValue = ""
            return
        }
        let date = Picker.dateFormatter.string(from: items[row].createdAt)
        if content.kind == .image, let data = content.data, let image = NSImage(data: data) {
            imageView.image = image
            imageView.isHidden = false
            textScroll.isHidden = true
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            metaLabel.stringValue = "\(content.text) · \(size) · \(date)"
        } else {
            let shown = content.text.count > Picker.maxPreviewChars
                ? String(content.text.prefix(Picker.maxPreviewChars)) + "\n… (truncated)"
                : content.text
            textView.string = shown
            textView.scrollToBeginningOfDocument(nil)
            textScroll.isHidden = false
            imageView.isHidden = true
            let kind = content.kind == .url ? "URL" : "Text"
            metaLabel.stringValue = "\(kind) · \(content.text.count) characters · \(date)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

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
        let item = items[row]
        cell.textField?.stringValue = item.preview
        let symbol = [ClipKind.text: "doc.text", .url: "link", .image: "photo"][item.kind] ?? "doc.text"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let icon = NSImageView()
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    // MARK: Window

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
