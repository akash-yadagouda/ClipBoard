import Foundation

/// File locations and user settings.
struct Config {
    static let defaultMaxItems = 1000

    let dataDir: String
    var maxItems = Config.defaultMaxItems

    var databasePath: String { dataDir + "/history.sqlite" }
    var pidPath: String { dataDir + "/clipboard-manager.pid" }
    var logPath: String { dataDir + "/clipboard-manager.log" }
    var configPath: String { dataDir + "/config.json" }

    /// Loads settings from `config.json` in the data directory, creating the
    /// directory if needed. `CLIPBOARD_MANAGER_HOME` overrides the location.
    static func load() -> Config {
        let dir = ProcessInfo.processInfo.environment["CLIPBOARD_MANAGER_HOME"]
            ?? NSHomeDirectory() + "/Library/Application Support/clipboard-manager"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var config = Config(dataDir: dir)
        if let data = FileManager.default.contents(atPath: config.configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let maxItems = json["maxItems"] as? Int, maxItems > 0 {
            config.maxItems = maxItems
        }
        return config
    }
}
