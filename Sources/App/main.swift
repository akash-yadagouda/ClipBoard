import Foundation

let usage = """
    Usage: clipboard-manager [command]

    Commands:
      (none)         Start monitoring in this terminal (Ctrl+C to stop)
      start          Start monitoring in the background
      stop           Stop the running manager
      status         Show whether the manager is running
      show           Open the picker (same as pressing ⌘⇧V)
      history [n]    Print the n most recent entries (default 20)
      clear [-y]     Delete all clipboard history (asks for confirmation)
      help           Show this help
    """

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let config = Config.load()

func openStore() -> HistoryStore {
    do {
        return try HistoryStore(path: config.databasePath, maxItems: config.maxItems)
    } catch {
        fail("Error: \(error)")
    }
}

switch arguments.first ?? "run" {
case "run":
    Daemon.run(config, store: openStore())

case "start":
    Daemon.startInBackground(config)

case "stop":
    Daemon.stop(config)

case "status":
    if let pid = Daemon.runningPID(config) {
        print("Clipboard Manager is running (pid \(pid)).")
    } else {
        print("Clipboard Manager is not running.")
    }
    print("History: \(openStore().count()) of \(config.maxItems) items")
    print("Data:    \(config.dataDir)")

case "show":
    Daemon.showPicker(config)

case "history":
    let limit = arguments.dropFirst().first.flatMap { Int($0) } ?? 20
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let items = openStore().search(limit: max(limit, 0))
    if items.isEmpty { print("Clipboard history is empty.") }
    for item in items {
        print("\(formatter.string(from: item.createdAt))  \(item.preview.prefix(100))")
    }

case "clear":
    let store = openStore()
    let count = store.count()
    if !arguments.contains("-y") && !arguments.contains("--yes") {
        print("Delete all \(count) clipboard history items? [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer == "y" || answer == "yes" else {
            print("Cancelled.")
            exit(0)
        }
    }
    store.clear()
    print("Clipboard history cleared.")

case "help", "-h", "--help":
    print(usage)

default:
    warn("Unknown command: \(arguments[0])\n\n\(usage)")
    exit(2)
}
