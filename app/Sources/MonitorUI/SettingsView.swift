#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// The app's Settings window (⌘,).
public struct SettingsView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            UpdateSettings(updates: model.updates)
                .tabItem { Label("Обновления", systemImage: "arrow.down.circle") }
            AccessSettings()
                .tabItem { Label("Доступ", systemImage: "person.2") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage("sshUser.default") private var sshUser = "root"

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
                LabeledContent("Опрос", value: "раз в \(Int(Poller.interval)) с")
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
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }

    private func role(_ name: String, _ detail: String) -> some View {
        LabeledContent(name) { Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}
#endif
