#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// Picks the form for the sheet the model asks for.
struct EditSheetView: View {
    @ObservedObject var model: AppModel
    var sheet: EditSheet

    var body: some View {
        switch sheet {
        case .addServer:
            AddServerForm(model: model)
        case .editServer(let id):
            if let s = model.status(id) { ServerEditForm(model: model, original: s.server) }
            else { Missing(title: "Сервер уже удалён") }
        case .addSite:
            SiteForm(model: model, original: nil)
        case .editSite(let id):
            if let s = model.siteConfigs.first(where: { $0.id == id }) { SiteForm(model: model, original: s) }
            else { Missing(title: "Сайт уже удалён") }
        }
    }
}

private struct Missing: View {
    var title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text(title)
            Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(30)
    }
}

/// Bottom row of every form: destructive action on the left, cancel and the
/// main action on the right, as in System Settings sheets.
private struct FormButtons<Leading: View>: View {
    var primary: String
    var enabled: Bool
    var busy: Bool
    var action: () -> Void
    var leading: Leading
    @Environment(\.dismiss) private var dismiss

    init(primary: String, enabled: Bool, busy: Bool, action: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.primary = primary; self.enabled = enabled; self.busy = busy
        self.action = action; self.leading = leading()
    }

    var body: some View {
        HStack {
            leading
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled || busy)
        }
        .padding(16)
    }
}

extension FormButtons where Leading == EmptyView {
    init(primary: String, enabled: Bool, busy: Bool, action: @escaping () -> Void) {
        self.init(primary: primary, enabled: enabled, busy: busy, action: action) { EmptyView() }
    }
}

private func errorText(_ e: Error) -> String {
    (e as? LocalizedError)?.errorDescription ?? String(describing: e)
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

private func tagList(_ s: String) -> [String]? {
    let t = s.split(separator: ",").map { trimmed(String($0)) }.filter { !$0.isEmpty }
    return t.isEmpty ? nil : t
}

private func optional(_ s: String) -> String? {
    let t = trimmed(s)
    return t.isEmpty ? nil : t
}

// MARK: - Site

/// Add or edit a site: name, address, and which servers check it.
struct SiteForm: View {
    @ObservedObject var model: AppModel
    var original: SiteConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var group = ""
    @State private var everywhere = true
    @State private var from: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var normalizedURL: String {
        let u = trimmed(url)
        if u.isEmpty || u.contains("://") { return u }
        return "https://" + u
    }

    private var host: String? {
        guard let u = URL(string: normalizedURL), u.scheme == "https" || u.scheme == "http",
              let h = u.host, h.contains(".") else { return nil }
        return h.lowercased()
    }

    private var problem: String? {
        if trimmed(url).isEmpty { return nil }
        if host == nil { return "Адрес вида https://example.ru" }
        if !everywhere && from.isEmpty { return "Выберите хотя бы один сервер" }
        if original == nil, model.siteConfigs.contains(where: { URL(string: $0.url)?.host?.lowercased() == host }) {
            return "Этот сайт уже есть в списке"
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Адрес", text: $url, prompt: Text("https://example.ru"))
                    TextField("Название", text: $name, prompt: Text(host ?? "Как показывать в списке"))
                    TextField("Группа", text: $group, prompt: Text("необязательно"))
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.orange) }
                }
                Section("Откуда проверять") {
                    Picker("Серверы", selection: $everywhere) {
                        Text("Со всех серверов").tag(true)
                        Text("Только с выбранных").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if !everywhere {
                        ForEach(model.statuses) { s in
                            Toggle(isOn: binding(s.id)) {
                                HStack(spacing: 6) {
                                    Text(s.server.name)
                                    if let c = s.country { Text(c.name).foregroundStyle(.secondary) }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    Text("Проверка раз в минуту: код ответа, время, SSL. Срок домена проверяется дважды в сутки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .formStyle(.grouped)
            FormButtons(primary: original == nil ? "Добавить" : "Сохранить",
                        enabled: host != nil && problem == nil, busy: busy, action: save) {
                if original != nil {
                    Button("Удалить сайт…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .frame(width: 500)
        .frame(minHeight: 380)
        .onAppear(perform: load)
        .confirmationDialog("Удалить сайт «\(original?.name ?? "")»?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive, action: remove)
        } message: {
            Text("Проверки прекратятся, история сайта останется в журнале.")
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { from.contains(id) }, set: { on in if on { from.insert(id) } else { from.remove(id) } })
    }

    private func load() {
        guard let o = original else { return }
        name = o.name; url = o.url; group = o.group ?? ""
        everywhere = o.from == nil
        from = Set(o.from ?? [])
    }

    private func save() {
        guard let host else { return }
        var site = original ?? SiteConfig(id: newID(host), name: "", url: "")
        site.name = optional(name) ?? host
        site.url = normalizedURL
        site.group = optional(group)
        site.from = everywhere ? nil : model.statuses.map(\.id).filter { from.contains($0) }
        run { try await model.save(site: site) }
    }

    private func remove() {
        guard let id = original?.id else { return }
        run { try await model.delete(site: id) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                self.error = errorText(error)
            }
            busy = false
        }
    }

    /// "shop.example.ru" -> "shop-example-ru", unique among existing sites.
    private func newID(_ host: String) -> String {
        let base = host.replacingOccurrences(of: "www.", with: "")
            .map { $0.isLetter && $0.isASCII || $0.isNumber ? String($0) : "-" }.joined()
        var id = base
        var n = 2
        let taken = Set(model.siteConfigs.map(\.id))
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}

// MARK: - Server: edit

/// Rename, regroup or move a server; replace its token; remove it.
struct ServerEditForm: View {
    @ObservedObject var model: AppModel
    var original: ServerConfig
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = 9443
    @State private var group = ""
    @State private var tags = ""
    @State private var token = ""
    @State private var fingerprint = ""
    @State private var showConnection = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Название", text: $name)
                    TextField("Группа", text: $group, prompt: Text("например, страна"))
                    TextField("Теги", text: $tags, prompt: Text("через запятую"))
                }
                Section {
                    DisclosureGroup("Подключение к агенту", isExpanded: $showConnection) {
                        TextField("Адрес", text: $host)
                        TextField("Порт агента", value: $port, format: .number.grouping(.never))
                        SecureField("Токен", text: $token, prompt: Text("оставьте пустым, чтобы не менять"))
                        TextField("Отпечаток", text: $fingerprint).font(.body.monospaced())
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .formStyle(.grouped)
            FormButtons(primary: "Сохранить", enabled: !trimmed(name).isEmpty && !trimmed(host).isEmpty,
                        busy: busy, action: save) {
                Button("Удалить сервер…", role: .destructive) { confirmDelete = true }
            }
        }
        .frame(width: 500)
        .frame(minHeight: 300)
        .onAppear {
            name = original.name; host = original.host; port = original.port
            group = original.group ?? ""; tags = (original.tags ?? []).joined(separator: ", ")
            fingerprint = original.fingerprint
        }
        .confirmationDialog("Удалить «\(original.name)» из мониторинга?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive, action: remove)
        } message: {
            Text("История и графики этого сервера удалятся. Агент на самом сервере останется работать.")
        }
    }

    private func save() {
        var s = original
        s.name = trimmed(name)
        s.host = trimmed(host)
        s.port = port
        s.group = optional(group)
        s.tags = tagList(tags)
        if let t = optional(token) { s.token = t.filter(\.isHexDigit) }
        s.fingerprint = trimmed(fingerprint)
        run { try await model.save(server: s) }
    }

    private func remove() {
        run { try await model.delete(server: original.id) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                self.error = errorText(error)
            }
            busy = false
        }
    }
}

// MARK: - Server: add

/// Two ways in: install the agent over SSH (step by step), or connect to an
/// agent that is already running by its token and fingerprint.
struct AddServerForm: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Mode: Hashable { case install, existing }
    enum Auth: Hashable { case key, password }

    @State private var mode: Mode = .install
    @State private var name = ""
    @State private var host = ""
    @State private var group = ""
    @State private var tags = ""
    // SSH
    @State private var user = "root"
    @State private var sshPort = 22
    @State private var auth: Auth = .key
    @State private var keyPath = ""
    @State private var password = ""
    // Existing agent
    @State private var agentPort = 9443
    @State private var token = ""
    @State private var fingerprint = ""

    @State private var running = false
    @State private var showProgress = false
    @State private var steps: [InstallStep: StepState] = [:]
    @State private var error: String?
    @State private var unverified: ServerConfig?

    enum StepState: Equatable { case running(String?), done(String?) }

    private var canInstall: Bool { model.backend.canInstallAgent }

    private var cleanToken: String { token.filter(\.isHexDigit) }
    private var cleanFingerprint: String { trimmed(fingerprint) }

    private var ready: Bool {
        guard !trimmed(host).isEmpty else { return false }
        switch mode {
        case .install:
            return canInstall && !trimmed(user).isEmpty && (auth == .key || !password.isEmpty)
        case .existing:
            return cleanToken.count >= 32 && Fingerprint.bytes(cleanFingerprint) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showProgress { progress } else { form }
            Divider()
            buttons
        }
        .frame(width: 540)
        .frame(minHeight: 460)
        .onAppear {
            if !canInstall { mode = .existing }
            keyPath = defaultKey() ?? ""
        }
    }

    // Page 1: where the server is and how to reach the agent.
    private var form: some View {
        Form {
            Section {
                TextField("Адрес", text: $host, prompt: Text("IP или домен"))
                TextField("Название", text: $name, prompt: Text(trimmed(host).isEmpty ? "Как показывать в списке" : trimmed(host)))
                TextField("Группа", text: $group, prompt: Text("например, Нидерланды"))
                TextField("Теги", text: $tags, prompt: Text("через запятую"))
            }
            Section {
                Picker("Агент", selection: $mode) {
                    Text("Установить по SSH").tag(Mode.install)
                    Text("Уже установлен").tag(Mode.existing)
                }
                .pickerStyle(.segmented)
                if mode == .install {
                    if canInstall {
                        TextField("Пользователь", text: $user)
                        TextField("Порт SSH", value: $sshPort, format: .number.grouping(.never))
                        Picker("Вход", selection: $auth) {
                            Text("Ключ").tag(Auth.key)
                            Text("Пароль").tag(Auth.password)
                        }
                        .pickerStyle(.radioGroup)
                        if auth == .key {
                            HStack {
                                TextField("Ключ", text: $keyPath, prompt: Text("~/.ssh/id_ed25519"))
                                Button("Выбрать…", action: pickKey)
                            }
                        } else {
                            SecureField("Пароль", text: $password)
                            Text("Пароль нужен только на время установки и нигде не сохраняется.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Установка из приложения появится в следующем обновлении. Пока поставьте агента командой remote-install.sh и выберите «Уже установлен».")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    TextField("Порт агента", value: $agentPort, format: .number.grouping(.never))
                    TextField("Токен", text: $token, prompt: Text("64 символа"))
                        .font(.body.monospaced())
                    TextField("Отпечаток", text: $fingerprint, prompt: Text("AB:CD:…"))
                        .font(.body.monospaced())
                    Text("На сервере: grep token /etc/monitor-agent/config.json и monitor-agent fingerprint")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    if unverified != nil {
                        Text("Агент не ответил. Можно всё равно добавить сервер: он появится с ошибкой, пока связь не наладится.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // Page 2: the install, one line per step.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Установка на \(trimmed(host))").font(.headline)
            ForEach(InstallStep.allCases) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon(steps[step]).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.rawValue).foregroundStyle(steps[step] == nil ? .secondary : .primary)
                        if let d = detail(steps[step]) {
                            Text(d).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if let error {
                AlertStrip(level: .critical, text: error, trailing: nil)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func icon(_ s: StepState?) -> some View {
        switch s {
        case .none: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func detail(_ s: StepState?) -> String? {
        switch s {
        case .running(let d), .done(let d): return d
        case .none: return nil
        }
    }

    private var buttons: some View {
        HStack {
            if showProgress && !running && error != nil {
                Button("Назад") { showProgress = false; steps = [:] }
            }
            Spacer()
            if running { ProgressView().controlSize(.small) }
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(running && mode == .install)
            if let s = unverified, !running {
                Button("Всё равно добавить") { add(s, verify: false) }
            }
            if !showProgress {
                Button(mode == .install ? "Установить" : "Добавить", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || running)
            }
        }
        .padding(16)
    }

    private func newServer(token: String, fingerprint: String, port: Int) -> ServerConfig {
        let h = trimmed(host)
        return ServerConfig(id: UUID().uuidString.lowercased(), name: optional(name) ?? h, host: h, port: port,
                            token: token, fingerprint: fingerprint, group: optional(group), tags: tagList(tags))
    }

    private func start() {
        error = nil
        unverified = nil
        switch mode {
        case .existing:
            add(newServer(token: cleanToken, fingerprint: cleanFingerprint, port: agentPort), verify: true)
        case .install:
            install()
        }
    }

    /// Checks that the agent answers with this token and certificate, then saves.
    private func add(_ server: ServerConfig, verify: Bool) {
        running = true
        error = nil
        Task {
            do {
                if verify {
                    do {
                        _ = try await AgentClient(transport: PinnedTransport()).snapshot(server)
                    } catch {
                        self.error = "Агент не отвечает: \(errorText(error))"
                        unverified = server
                        running = false
                        return
                    }
                }
                try await model.save(server: server)
                model.show(server: server.id)
                dismiss()
            } catch {
                self.error = errorText(error)
            }
            running = false
        }
    }

    private func install() {
        let req = InstallRequest(host: trimmed(host), sshPort: sshPort, user: trimmed(user),
                                 keyPath: auth == .key ? optional(keyPath) : nil,
                                 password: auth == .password ? password : nil)
        showProgress = true
        running = true
        steps = [:]
        Task {
            do {
                for try await update in model.backend.installAgent(req) {
                    switch update {
                    case .running(let step, let d): steps[step] = .running(d)
                    case .done(let step, let d): steps[step] = .done(d)
                    case .finished(let token, let fp):
                        password = ""
                        let server = newServer(token: token, fingerprint: fp, port: req.agentPort)
                        try await model.save(server: server)
                        model.show(server: server.id)
                        running = false
                        dismiss()
                        return
                    }
                }
                error = "Установка закончилась без токена агента"
            } catch {
                self.error = errorText(error)
            }
            password = ""
            running = false
        }
    }

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    private func defaultKey() -> String? {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
            let p = ssh.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }
}
#endif
