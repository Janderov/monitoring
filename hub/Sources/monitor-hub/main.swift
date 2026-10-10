import Crypto
import Foundation
import HubAccounts
import HubCore
import HubWeb
import Logging

// monitor-hub run                  — the hub itself (systemd / Docker runs this)
// monitor-hub migrate              — only bring the database up to date
// monitor-hub import FILE [NAME]   — take servers, sites and history from the
//                                    Mac's transfer file; password on stdin
// monitor-hub new-key              — a fresh encryption key for the credentials folder
// monitor-hub owner-invite [LOGIN] [NAME] [--reset]
//                                  — the owner's link to the web cabinet (first
//                                    time, or after a lost password or phone)

LoggingSystem.bootstrap { label in
    var h = StreamLogHandler.standardOutput(label: label)
    h.logLevel = Logger.Level(rawValue: ProcessInfo.processInfo.environment["HUB_LOG"] ?? "info") ?? .info
    return h
}
let logger = Logger(label: "monitor-hub")

/// Every part of the hub with web routes. Add yours here.
let webModules: [any WebModule] = [CabinetModule()]
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

do {
    switch args.first ?? "run" {
    case "run":
        let config = try HubConfig.fromEnvironment()
        let web = try WebConfig.fromEnvironment()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Hub(config: config, logger: logger).run() }
            if let web {
                group.addTask {
                    try await WebServer(config: config, web: web, modules: webModules, logger: logger).run()
                }
            }
            try await group.next()
            group.cancelAll()
        }
    case "owner-invite":
        let config = try HubConfig.fromEnvironment()
        let rest = args.dropFirst().filter { $0 != "--reset" }
        let login = rest.first ?? "owner"
        let name = rest.dropFirst().first ?? "Владелец"
        let token = try await Hub(config: config, logger: logger).withDatabase { db in
            let accounts = Accounts(db: db, box: try config.secretKey.map { try SecretBox(key: $0) })
            return try await accounts.ownerInvite(login: login, name: name, reset: args.contains("--reset"))
        }
        let path = "/#/invite/\(token)"
        if let base = (try? WebConfig.fromEnvironment())??.publicURL {
            print("Откройте в браузере в течение 48 часов:\n\(base.absoluteString)\(path)")
        } else {
            print("Откройте адрес кабинета и допишите в конце: \(path)")
        }
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
    case "version", "--version":
        print(HubVersion.current)
    default:
        fail("неизвестная команда \(args[0]); есть: run, migrate, import, new-key, owner-invite, version")
    }
} catch {
    fail("ошибка: \(HubError.describe(error))")
}
