#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// The app's Settings window (⌘,). A plain window rather than the SwiftUI
/// Settings scene: a menu bar app has no app menu, and on macOS 14+ the
/// Settings scene cannot be opened from code without SettingsLink.
public struct SettingsView: View {
    public static let id = "settings"

    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            UpdateSettings(updates: model.updates)
                .tabItem { Label("Обновления", systemImage: "arrow.down.circle") }
            AccessSettings(model: model)
                .tabItem { Label("Доступ", systemImage: "person.2") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage("sshUser.default") private var sshUser = "root"
    @AppStorage(Poller.refreshDefaultsKey) private var refresh = Poller.interval

    var body: some View {
        Form {
            Section("Серверы") {
                LabeledContent("Список серверов") {
                    HStack {
                        Text("servers.json").foregroundStyle(.secondary)
                        Button("Открыть") { model.openConfig() }
                        Button("Перечитать") { Task { await model.reload() } }
                    }
                }
                Picker("Обновление данных", selection: $refresh) {
                    ForEach(Poller.refreshChoices, id: \.self) { s in
                        Text(s >= 60 ? "раз в минуту" : "каждые \(Int(s)) с").tag(s)
                    }
                }
                .onChange(of: refresh) { _, s in model.setRefreshInterval(s) }
                Text("Агенты на серверах снимают показатели с той же частотой. История и уведомления остаются поминутными.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let err = model.configError {
                    Text(err).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("SSH") {
                TextField("Пользователь по умолчанию", text: $sshUser)
                Text("Пароли и ключи хранит Терминал и Связка ключей, приложение их не видит.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Данные") {
                LabeledContent("Папка") {
                    HStack {
                        Text(DataFolder.url.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Показать") { model.openDataFolder() }
                    }
                }
                LabeledContent("Хранение", value: "поминутно \(Int(Store.sampleRetention / 86400)) дн., по часам \(Int(Store.hourlyRetention / 86400)) дн.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }
}

/// Builds come from GitHub Actions of the private repo, so a read-only token
/// is needed to download them.
private struct UpdateSettings: View {
    @ObservedObject var updates: UpdateModel
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Сборка", value: AppUpdater.currentVersion)
                HStack {
                    Button("Проверить обновления") { Task { await updates.check() } }
                        .disabled(!updates.hasToken || updates.busy)
                    if updates.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    if updates.available != nil {
                        Button("Установить и перезапустить") { Task { await updates.install() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                if !updates.statusText.isEmpty {
                    Text(updates.statusText)
                        .foregroundStyle(failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                HStack {
                    SecureField("Токен GitHub", text: $token,
                                prompt: Text(updates.hasToken ? "сохранён в Связке ключей" : "github_pat_…"))
                    Button("Сохранить") { save(token) }.disabled(token.isEmpty)
                    if updates.hasToken { Button("Удалить") { save("") } }
                }
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Fine-grained токен только для репозитория monitoring, права Actions и Contents только на чтение. Как его сделать, написано в README.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }

    private var failed: Bool {
        if case .failed = updates.state { return true }
        return false
    }

    private func save(_ value: String) {
        do {
            try updates.setToken(value)
            token = ""
            error = nil
            if updates.hasToken { Task { await updates.check() } }
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Who may do what. Today there is one user, the owner; the section shows
/// where people and devices will appear once the hub on the Mac mini exists.
private struct AccessSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text("Владелец").foregroundStyle(.secondary)
                } label: {
                    Label(NSFullUserName(), systemImage: "person.crop.circle")
                }
            } header: {
                HStack {
                    Text("Люди")
                    Spacer()
                    Button("Пригласить…") {}
                        .disabled(true)
                        .help("Появится вместе с хабом на Mac mini")
                }
            }
            Section("Роли") {
                role("Владелец", "всё, включая доступ других людей")
                role("Администратор", "SSH, ключи VPN, установка агента на выданных серверах")
                role("Наблюдатель", "только смотреть статусы и графики")
                role("Клиент VPN", "только свои ключи и трафик")
            }
            Section("Устройства") {
                LabeledContent(Host.current().localizedName ?? "Этот Mac", value: "этот Mac, опрашивает серверы")
                Text("iPhone и другие Mac подключатся к хабу, когда он появится.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Журнал действий") {
                AuditList(model: model, objectID: nil, limit: 100)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }

    private func role(_ name: String, _ detail: String) -> some View {
        LabeledContent(name) { Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}
/// Who changed what: server and site edits, agent installs, VPN keys, SSH
/// sessions and app updates, newest first.
struct AuditList: View {
    @ObservedObject var model: AppModel
    var objectID: String?
    var limit: Int
    @State private var records: [AuditRecord] = []

    var body: some View {
        Group {
            if records.isEmpty {
                Text("Пока ничего не менялось").foregroundStyle(.secondary)
            } else {
                ForEach(records) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(r.result))
                            .foregroundStyle(r.result == .done ? Color.green : r.result == .denied ? Color.orange : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.action.title): \(r.object.name)" + (r.detail.isEmpty ? "" : ", \(r.detail)"))
                                .fixedSize(horizontal: false, vertical: true)
                            Text([r.actor.name, Fmt.relative(r.time), r.error].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .task(id: model.lastRound) {
            records = (try? await model.backend.auditLog(limit: limit, objectID: objectID)) ?? []
        }
    }

    private func icon(_ r: AuditRecord.Result) -> String {
        switch r {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .denied: return "hand.raised.fill"
        }
    }
}
#endif
