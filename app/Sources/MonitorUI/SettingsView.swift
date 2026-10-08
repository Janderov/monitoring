#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// The app's settings (⌘,), a section of the main window like the others, so
/// they open where the window is, full screen included.
public struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// Shown in the main window's detail pane.
    var embedded = false

    public init(model: AppModel) { self.model = model }

    init(model: AppModel, embedded: Bool) {
        self.model = model
        self.embedded = embedded
    }

    public var body: some View {
        if model.showsLockScreen {
            LockScreen(model: model).frame(width: 520, height: 420)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            UpdateSettings(updates: model.updates)
                .tabItem { Label("Обновления", systemImage: "arrow.down.circle") }
            AccessSettings(model: model)
                .tabItem { Label("Доступ", systemImage: "person.2") }
            AdminKeySettings(model: model)
                .tabItem { Label("Ключ администратора", systemImage: "key") }
        }
        .frame(maxWidth: embedded ? 680 : 520)
        .padding(embedded ? 20 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Настройки")
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage("sshUser.default") private var sshUser = "root"
    @AppStorage(Poller.refreshDefaultsKey) private var refresh = Poller.interval
    // Same keys as MorningDigest.
    @AppStorage("digest.enabled") private var digest = true
    @AppStorage("digest.hour") private var digestHour = 9
    @Environment(\.openWindow) private var openWindow

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
            Section("Утренняя сводка") {
                Toggle("Присылать уведомление утром", isOn: $digest)
                Picker("Время", selection: $digestHour) {
                    ForEach(5...12, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                }
                .disabled(!digest)
                Text("Как прошла ночь, что скоро истекает и что ждёт обслуживания. Если Мак спал, сводка придёт, когда он проснётся.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Мини-панель") {
                    Button("Открыть") { openWindow(id: MiniPanel.id) }
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
                LabeledContent("Размер базы", value: databaseSize)
                Text("Агенты помнят последние \(Int(Poller.firstBackfill / 3600)) ч, поэтому графики дополняются, когда Мак был выключен или спал.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }

    /// The database with its write-ahead log, which holds the newest pages.
    private var databaseSize: String {
        let path = DataFolder.database.path
        let bytes = [path, path + "-wal"].reduce(UInt64(0)) { sum, p in
            sum + ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64) ?? 0)
        }
        return bytes == 0 ? "—" : Fmt.bytes(bytes)
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
