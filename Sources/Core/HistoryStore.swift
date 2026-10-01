import Foundation
import SQLite3

/// A history row without its (possibly large) image data.
struct HistoryItem {
    let id: Int64
    let kind: ClipKind
    let text: String
    let createdAt: Date

    /// Single-line summary for lists.
    var preview: String {
        let flat = text.prefix(300)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return kind == .image ? "[\(flat)]" : flat
    }
}

struct StoreError: Error, CustomStringConvertible {
    let description: String
}

/// Clipboard history persisted in a local SQLite file.
final class HistoryStore {
    private var db: OpaquePointer?
    var maxItems: Int

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, maxItems: Int = 1000) throws {
        self.maxItems = max(1, maxItems)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError(description: "cannot open database at \(path)")
        }
        chmod(path, 0o600)
        sqlite3_busy_timeout(db, 2000)
        run("PRAGMA secure_delete = ON")
        run("""
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                data BLOB,
                created_at REAL NOT NULL
            )
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Stores a new entry as the newest item. Returns false if it equals the
    /// current newest item (consecutive duplicate). An older identical entry
    /// is moved to the top instead of being stored twice.
    @discardableResult
    func add(_ content: ClipContent, at date: Date = Date()) -> Bool {
        let key: [Any?] = [content.kind.rawValue, content.text, content.data]
        var isNewest = false
        run("""
            SELECT 1 FROM items WHERE id = (SELECT MAX(id) FROM items)
            AND kind = ?1 AND text = ?2 AND data IS ?3
            """, key) { _ in isNewest = true }
        if isNewest { return false }

        run("BEGIN")
        run("DELETE FROM items WHERE kind = ?1 AND text = ?2 AND data IS ?3", key)
        run("INSERT INTO items (kind, text, data, created_at) VALUES (?1, ?2, ?3, ?4)",
            key + [date.timeIntervalSince1970])
        run("DELETE FROM items WHERE id NOT IN (SELECT id FROM items ORDER BY id DESC LIMIT ?1)",
            [maxItems])
        run("COMMIT")
        return true
    }

    /// Newest-first items whose text contains `query` (case-insensitive).
    /// An empty query returns everything.
    func search(_ query: String = "", limit: Int = .max) -> [HistoryItem] {
        var items: [HistoryItem] = []
        run("SELECT id, kind, text, created_at FROM items ORDER BY id DESC") { stmt in
            guard items.count < limit else { return }
            let text = String(cString: sqlite3_column_text(stmt, 2))
            guard query.isEmpty
                || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { return }
            items.append(HistoryItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: ClipKind(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .text,
                text: text,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
        }
        return items
    }

    /// Full content of an item, including image data.
    func content(id: Int64) -> ClipContent? {
        var content: ClipContent?
        run("SELECT kind, text, data FROM items WHERE id = ?1", [id]) { stmt in
            var data: Data?
            if let bytes = sqlite3_column_blob(stmt, 2) {
                data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            content = ClipContent(
                kind: ClipKind(rawValue: String(cString: sqlite3_column_text(stmt, 0))) ?? .text,
                text: String(cString: sqlite3_column_text(stmt, 1)),
                data: data)
        }
        return content
    }

    func delete(id: Int64) {
        run("DELETE FROM items WHERE id = ?1", [id])
    }

    func clear() {
        run("DELETE FROM items")
        run("VACUUM")
    }

    func count() -> Int {
        var n = 0
        run("SELECT COUNT(*) FROM items") { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    private func run(_ sql: String, _ binds: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, index, v)
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Data:
                _ = v.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            default: sqlite3_bind_null(stmt, index)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            row?(stmt)
        }
    }
}
