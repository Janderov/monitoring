#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// The outside pulse: a ping after each round, so a service such as
/// healthchecks.io raises the alarm when the Mac goes quiet.
@MainActor
public final class HeartbeatModel: ObservableObject {
    @Published public private(set) var configured = false
    @Published public private(set) var state = HeartbeatSender.State()
    private let secrets: SecretStore
    private let sender = HeartbeatSender()
    private var url: URL?

    init(secrets: SecretStore) {
        self.secrets = secrets
        url = (try? secrets.get(SecretKey.heartbeat)).flatMap(Heartbeat.parse)
        configured = url != nil
    }

    /// Empty forgets the address. Throws on one that is not https.
    func setAddress(_ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            try secrets.remove(SecretKey.heartbeat)
            url = nil
        } else {
            guard let u = Heartbeat.parse(t) else { throw Transfer.Error("нужна ссылка вида https://hc-ping.com/…") }
            try secrets.set(u.absoluteString, for: SecretKey.heartbeat)
            url = u
        }
        configured = url != nil
        state = HeartbeatSender.State()
    }

    /// After every screen update; the sender keeps it to one ping a minute.
    func roundDone(_ model: AppModel, force: Bool = false) {
        guard let url else { return }
        let servers = (ok: model.statuses.filter { $0.alerts.isEmpty && $0.snapshot != nil }.count, total: model.statuses.count)
        let sites = (ok: model.siteStatuses.filter(\.alerts.isEmpty).count, total: model.siteStatuses.count)
        let request = Heartbeat.request(url, health: model.health, servers: servers, sites: sites)
        Task {
            let s = await sender.tick(request, force: force)
            if s != state { state = s }
        }
    }

    /// Before sleep: a note in the service's log, best effort.
    func goingToSleep() {
        guard let url else { return }
        let request = Heartbeat.sleepNote(url)
        Task { _ = try? await HeartbeatSender.urlSession(request) }
    }

    var statusText: String {
        if let e = state.error { return e }
        if let t = state.lastSent { return "Последний сигнал \(Fmt.relative(t))" }
        return "Сигнал уйдёт после ближайшего опроса"
    }
}

/// Settings → Основные → Внешний пульс.
struct HeartbeatSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var heartbeat: HeartbeatModel
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        Section {
            HStack {
                SecureField("Ссылка для сигнала", text: $address,
                            prompt: Text(heartbeat.configured ? "сохранена в Связке ключей" : "https://hc-ping.com/…"))
                Button("Сохранить") { save(address) }.disabled(address.isEmpty)
                if heartbeat.configured {
                    Button("Проверить") { heartbeat.roundDone(model, force: true) }
                    Button("Удалить") { save("") }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if heartbeat.configured {
                Text(heartbeat.statusText)
                    .foregroundStyle(heartbeat.state.error == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Внешний пульс")
        } footer: {
            Text("Если Мак выключится, уснёт, потеряет сеть или приложение зависнет, уведомлений не будет совсем. Пульс это ловит: Мак раз в минуту отправляет сигнал на healthchecks.io, а если сигналы прекратились, сервис сам пришлёт письмо или сообщение в Telegram. Создайте там бесплатную проверку с периодом 5 минут и вставьте сюда её ссылку. В сигнале только число серверов в норме, без имён и адресов.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(_ value: String) {
        do {
            try heartbeat.setAddress(value)
            address = ""
            error = nil
            heartbeat.roundDone(model, force: true)
        } catch {
            self.error = String(describing: error)
        }
    }
}
#endif
