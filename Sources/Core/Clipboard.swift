import AppKit

enum ClipKind: String {
    case text, url, image
}

/// One captured clipboard value.
struct ClipContent: Equatable {
    var kind: ClipKind
    /// The text or URL. For images, a short searchable description ("Image 800×600").
    var text: String
    /// Raw PNG/TIFF bytes for images, nil otherwise.
    var data: Data?

    /// Items larger than this are ignored rather than stored.
    static let maxBytes = 10 * 1024 * 1024

    // Markers used by password managers etc. to say "do not record this".
    private static let skippedTypes = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ].map { NSPasteboard.PasteboardType($0) }

    static func text(_ string: String) -> ClipContent {
        ClipContent(kind: looksLikeURL(string) ? .url : .text, text: string, data: nil)
    }

    static func looksLikeURL(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: s), let scheme = url.scheme?.lowercased()
        else { return false }
        switch scheme {
        case "http", "https", "ftp", "ssh":
            return !(url.host ?? "").isEmpty
        case "file", "mailto":
            return true
        default:
            return false
        }
    }

    /// Reads the current pasteboard value. Text wins over images.
    static func read(from pasteboard: NSPasteboard) -> ClipContent? {
        let types = pasteboard.types ?? []
        if skippedTypes.contains(where: types.contains) { return nil }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string.utf8.count <= maxBytes ? .text(string) : nil
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            guard data.count <= maxBytes else { return nil }
            var description = "Image"
            if let rep = NSBitmapImageRep(data: data) {
                description += " \(rep.pixelsWide)×\(rep.pixelsHigh)"
            }
            return ClipContent(kind: .image, text: description, data: data)
        }
        return nil
    }

    /// Replaces the pasteboard contents with this value.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if kind == .image, let data = data {
            let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            pasteboard.setData(data, forType: isPNG ? .png : .tiff)
        } else {
            pasteboard.setString(text, forType: .string)
        }
    }
}
