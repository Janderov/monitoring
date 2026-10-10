import Crypto
import Foundation
import HubCore
import Logging

// monitor-hub run                  — the hub itself (systemd / Docker runs this)
// monitor-hub migrate              — only bring the database up to date
// monitor-hub import FILE [NAME]   — take servers, sites and history from the
//                                    Mac's transfer file; password on stdin
// monitor-hub new-key              — a fresh encryption key for the credentials folder
// monitor-hub telegram-link [LOGIN] — a one-time t.me link that ties a Telegram
//                                    chat to the account (the owner by default)
// monitor-hub report …             — monthly client reports (see `report help`)

LoggingSystem.bootstrap { label in
    var h = StreamLogHandler.standardOutput(label: label)
    h.logLevel = Logger.Level(rawValue: ProcessInfo.processInfo.environment["HUB_LOG"] ?? "info") ?? .info
    return h
}
let logger = Logger(label: "monitor-hub")
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

do {
    switch args.first ?? "run" {
    case "run":
        let config = try HubConfig.fromEnvironment()
        try await Hub(config: config, logger: logger, services: [TelegramService(config: config), ReportService(), ReportWebService(config: config)]).run()
    case "migrate":
        let hub = Hub(config: try HubConfig.fromEnvironment(), logger: logger)
        try await hub.withDatabase { _ in () }
        print("база в порядке")
    case "import":
        guard args.count >= 2 else { fail("укажите файл переноса: monitor-hub import FILE [имя Mac]") }
        let config = try HubConfig.fromEnvironment()
        guard let key = config.secretKey else { fail("нет ключа шифрования \(HubConfig.credentialNames.key)") }
        let box = try SecretBox(key: key)
        let file = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let password = ProcessInfo.processInfo.environment["HUB_IMPORT_PASSWORD"]
            ?? readLine(strippingNewline: true) ?? ""
        let source = args.count >= 3 ? args[2] : "Mac"
        let report = try await Hub(config: config, logger: logger).withDatabase { db in
            try await TransferImport.run(db, box: box, file: file, password: password, source: source)
        }
        print(report)
    case "new-key":
        print(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString())
    case "telegram-link":
        let hub = Hub(config: try HubConfig.fromEnvironment(), logger: logger)
        let login = args.count >= 2 ? args[1] : nil
        let link = try await hub.withDatabase { db in try await TelegramLink.make(db, login: login) }
        print(link)
    case "report":
        let config = try HubConfig.fromEnvironment()
        let out = try await Hub(config: config, logger: logger).withDatabase { db in
            try await ReportCommand.run(Array(args.dropFirst()), db: db, config: config)
        }
        print(out)
    case "version", "--version":
        print(HubVersion.current)
    default:
        fail("неизвестная команда \(args[0]); есть: run, migrate, import, new-key, telegram-link, report, version")
    }
} catch {
    fail("ошибка: \(HubError.describe(error))")
}
