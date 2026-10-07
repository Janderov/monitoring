#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

// MARK: - Toolbar

/// Open padlock in the main window's toolbar while unlocked: locks right away.
struct AdminLockButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.admin?.state == .unlocked {
            Button { model.lockNow() } label: {
                Label("Заблокировать", systemImage: "lock.open")
            }
            .help("Скрыть всё до следующего входа по токену (⌃⌘L)")
        }
    }
}

// MARK: - Lock screen

/// Everything the app shows while locked: «Вставьте ваш токен», then the PIN.
/// Covers the main window and Settings; no data is drawn behind it.
@MainActor
struct LockScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            UnlockPanel(model: model)
                .frame(width: 440)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                .shadow(radius: 12, y: 4)
                .padding(24)
        }
    }
}

/// Waits for the token, then asks for its PIN; or takes the recovery code.
@MainActor
struct UnlockPanel: View {
    @ObservedObject var model: AppModel

    @State private var pin = ""
    @State private var code = ""
    @State private var useCode = false
    @State private var busy = false
    @State private var error: String?
    /// Unlocked with the factory PIN: offer to change it before showing data.
    @State private var factoryPIN = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let code = model.pendingRecoveryCode {
                RecoveryCodeView(code: code, note: "Теперь пароли SSH, сайтов и токен GitHub зашифрованы ключом с вашего Рутокена. Старый код восстановления больше не действует, вот новый.") {
                    model.pendingRecoveryCode = nil
                    if !factoryPIN { finish() }
                }
            } else if factoryPIN {
                ChangePINForm(model: model, knownOld: pin,
                              intro: "На токене всё ещё заводской PIN 12345678. Смените его, чтобы с вашим токеном не мог войти другой человек.") {
                    finish()
                } onSkip: { finish() }
            } else {
                content
                Divider()
                buttons
            }
        }
        // The lock watches the USB slot every second and reports here.
        .onChange(of: presence, initial: true) { _, p in
            if p == .mine { pinFocused = true } else { pin = "" }
        }
        // Held open by an unlock whose follow-up (factory PIN) this view no
        // longer knows about: let the data show rather than ask again.
        .onAppear {
            if model.admin?.state == .unlocked, model.pendingRecoveryCode == nil, !factoryPIN {
                model.holdLockScreen = false
            }
        }
    }

    private var presence: KeyPresence { model.admin?.presence ?? .none }
    private var inserted: Bool { presence == .mine }
    private var noDriver: Bool { presence == .noDriver }

    private var content: some View {
        VStack(spacing: 14) {
            Image(systemName: useCode ? "key.horizontal.fill" : (inserted ? "lock.fill" : "cable.connector"))
                .font(.system(size: 40)).foregroundStyle(.tint)
                .padding(.top, 8)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if useCode {
                TextField("Код восстановления", text: $code, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"))
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(unlock)
            } else if inserted {
                SecureField("PIN", text: $pin, prompt: Text("PIN токена"))
                    .textFieldStyle(.roundedBorder)
                    .focused($pinFocused)
                    .onSubmit(unlock)
            }
            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        if useCode { return "Вход по коду восстановления" }
        switch presence {
        case .noDriver: return "Не установлен драйвер Рутокен"
        case .mine: return "Введите PIN"
        case .other: return "Это не ваш токен"
        case .none: return "Вставьте ваш токен"
        }
    }

    private var detail: String {
        if useCode {
            return "Код показывался один раз при настройке ключа. После входа запишите ключ на новый токен."
        }
        if noDriver {
            return "Установите модуль PKCS#11 для macOS с сайта rutoken.ru («Поддержка» → «Центр загрузки») и вставьте токен."
        }
        let key = [model.admin?.keyName, model.admin?.keyID].compactMap { $0 }.joined(separator: " · ")
        switch presence {
        case .mine: return "Токен \(key) найден."
        case .other: return "Вставлен другой токен. Монитор открывается только с ключом администратора\(key.isEmpty ? "" : " (\(key))")."
        default: return "Монитор открывается только с ключом администратора\(key.isEmpty ? "" : " (\(key))")."
        }
    }

    private var buttons: some View {
        HStack {
            Button(useCode ? "Войти по токену" : "Потерян токен?") {
                useCode.toggle()
                error = nil
            }
            .buttonStyle(.link)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Войти", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .padding(16)
    }

    private var canSubmit: Bool {
        if busy { return false }
        if useCode { return !code.trimmingCharacters(in: .whitespaces).isEmpty }
        return inserted && !pin.isEmpty
    }

    private func unlock() {
        guard canSubmit, let lock = model.backend.adminLock else { return }
        busy = true
        error = nil
        // Keep this screen (and its state) up until the unlock has been
        // handled: the lock reports "unlocked" before `unlock` returns, and
        // dropping the screen then lost the new recovery code and the
        // factory-PIN step, leaving the PIN prompt stuck.
        model.holdLockScreen = true
        Task {
            do {
                if useCode {
                    try await lock.unlock(recoveryCode: code)
                    code = ""
                    busy = false
                    model.holdLockScreen = false
                } else {
                    let r = try await lock.unlock(pin: pin)
                    busy = false
                    // Show the new recovery code and ask to change the
                    // factory PIN before the data shows up.
                    model.pendingRecoveryCode = r.newRecoveryCode
                    if r.defaultPIN {
                        factoryPIN = true
                    } else {
                        pin = ""
                        model.holdLockScreen = false
                    }
                }
            } catch {
                self.error = String(describing: error)
                busy = false
                model.holdLockScreen = false
            }
        }
    }

    private func finish() {
        pin = ""
        factoryPIN = false
        model.holdLockScreen = false
    }
}

// MARK: - Change PIN

/// Old PIN (unless known), new PIN twice.
struct ChangePINForm: View {
    @ObservedObject var model: AppModel
    /// The PIN just typed to unlock, so it is not asked again.
    var knownOld: String?
    var intro: String
    var onDone: () -> Void
    var onSkip: (() -> Void)?

    @State private var old = ""
    @State private var new = ""
    @State private var again = ""
    @State private var busy = false
    @State private var error: String?

    private var problem: String? {
        if new.isEmpty { return nil }
        if new.count < 6 { return "Новый PIN не короче 6 символов" }
        if new == AdminLock.factoryPIN { return "Это заводской PIN, придумайте другой" }
        if !again.isEmpty, again != new { return "PIN не совпадает" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(intro).fixedSize(horizontal: false, vertical: true)
                    if knownOld == nil { SecureField("Текущий PIN", text: $old) }
                    SecureField("Новый PIN", text: $new)
                    SecureField("Ещё раз", text: $again)
                } footer: {
                    Text("Токен заблокируется после нескольких неверных PIN подряд. Запомните новый PIN.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = error ?? problem {
                    Section { Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 260)
            Divider()
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if let onSkip {
                    Button("Позже", action: onSkip).keyboardShortcut(.cancelAction).disabled(busy)
                }
                Button("Сменить PIN", action: change)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || new.isEmpty || again != new || problem != nil || (knownOld == nil && old.isEmpty))
            }
            .padding(16)
        }
    }

    private func change() {
        guard let lock = model.backend.adminLock else { return }
        busy = true
        error = nil
        let current = knownOld ?? old
        Task {
            do {
                try await lock.changePIN(old: current, new: new)
                old = ""; new = ""; again = ""
                busy = false
                onDone()
            } catch {
                self.error = String(describing: error)
                busy = false
            }
        }
    }
}

// MARK: - Settings

/// Settings → «Ключ администратора»: set up, replace or turn off the token.
struct AdminKeySettings: View {
    @ObservedObject var model: AppModel

    @State private var tokens: [TokenInfo]?
    @State private var noDriver = false
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?
    /// Shown once after setup or on request; never stored.
    @State private var recoveryCode: String?
    @State private var changingPIN = false
    @State private var replacing = false
    @State private var confirmDisable = false
    @State private var keyName = ""

    private var state: AdminLockState { model.admin?.state ?? .off }

    var body: some View {
        Group {
            if let code = recoveryCode {
                RecoveryCodeView(code: code) { recoveryCode = nil }
            } else if changingPIN {
                ChangePINForm(model: model, knownOld: nil, intro: "Смена PIN на токене \(model.admin?.keyName ?? "Рутокен").") {
                    changingPIN = false
                } onSkip: { changingPIN = false }
            } else {
                main
            }
        }
        .frame(minHeight: 360)
        .task { await findTokens() }
    }

    private var main: some View {
        Form {
            Section {
                Text("С ключом администратора Монитор открывается только с вашим Рутокеном и PIN. Без токена окно и меню показывают только «Вставьте ваш токен», а уведомления приходят без подробностей. Если токен вынуть, всё сразу скрывается.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch state {
            case .off: setupSection(replace: false)
            case .locked: lockedSection
            case .unlocked:
                if replacing { setupSection(replace: true) } else { unlockedSection }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Отключить вход по ключу администратора?", isPresented: $confirmDisable) {
            Button("Отключить", role: .destructive) { run { try await $0.disable() } }
        } message: {
            Text("Монитор снова будет открываться без токена. Код восстановления перестанет действовать.")
        }
    }

    @ViewBuilder private func setupSection(replace: Bool) -> some View {
        Section(replace ? "Записать ключ на другой токен" : "Настройка") {
            if noDriver {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Не установлен драйвер Рутокен", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("1. Откройте в Safari rutoken.ru → «Поддержка» → «Центр загрузки» → «Драйверы для macOS».\n2. Скачайте модуль PKCS#11 для macOS и откройте файл .pkg.\n3. Нажимайте «Продолжить» и «Установить», введите пароль от Mac.\n4. Вставьте Рутокен и нажмите «Проверить снова».")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let tokens {
                if tokens.isEmpty {
                    Text("Вставьте Рутокен в USB-порт.").foregroundStyle(.secondary)
                } else if tokens.count > 1 {
                    Text("Вставлено несколько токенов, оставьте один.").foregroundStyle(.orange)
                } else if let t = tokens.first {
                    LabeledContent("Токен", value: [t.displayName, t.serial]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    SecureField("PIN токена", text: $pin, prompt: Text("заводской 12345678"))
                }
            }
            HStack {
                Button("Проверить снова") { Task { await findTokens() } }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if replace { Button("Отмена") { replacing = false; pin = "" }.disabled(busy) }
                Button(replace ? "Записать на этот токен" : "Записать ключ на токен", action: enroll)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || pin.isEmpty || tokens?.count != 1)
            }
        }
    }

    private var lockedSection: some View {
        Section("Состояние") {
            LabeledContent("Ключ", value: keyLine)
            HStack {
                Label("Заблокировано", systemImage: "lock.fill")
                Spacer()
                Text("Вставьте токен и введите PIN").foregroundStyle(.secondary)
            }
            Text("Заменить токен, сменить PIN или отключить ключ можно после разблокировки.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var unlockedSection: some View {
        Section("Состояние") {
            HStack {
                TextField("Название", text: $keyName, prompt: Text("например, Rutoken lite Mihail"))
                    .onSubmit(saveName)
                if keyName != (model.admin?.keyName ?? "") {
                    Button("Сохранить", action: saveName).disabled(busy || keyName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { keyName = model.admin?.keyName ?? "" }
            LabeledContent("Номер токена", value: model.admin?.keyID ?? "")
            HStack {
                Label(model.admin?.unlockedByRecovery == true ? "Открыто кодом восстановления" : "Разблокировано",
                      systemImage: "lock.open")
                Spacer()
                Button("Заблокировать") { model.lockNow() }
            }
            if model.admin?.unlockedByRecovery == true {
                Text("Запишите ключ на новый токен: старый код после этого лучше заменить.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.admin?.defaultPIN == true {
                HStack {
                    Label("На токене заводской PIN", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Сменить PIN…") { changingPIN = true }
                }
            }
        }
        Section("Действия") {
            Button("Сменить PIN токена…") { changingPIN = true }
                .disabled(model.admin?.unlockedByRecovery == true)
            Button("Новый код восстановления…") {
                run { lock in
                    let code = try await lock.newRecoveryCode()
                    await MainActor.run { recoveryCode = code }
                }
            }
            Button("Записать ключ на другой токен…") {
                replacing = true
                Task { await findTokens() }
            }
            Button("Отключить вход по ключу…", role: .destructive) { confirmDisable = true }
        }
    }

    private var keyLine: String {
        [model.admin?.keyName, model.admin?.keyID].compactMap { $0 }.joined(separator: " · ")
    }

    private func saveName() {
        let name = keyName
        run { try await $0.rename(name) }
    }

    private func findTokens() async {
        guard let lock = model.backend.adminLock else { return }
        do {
            tokens = try await lock.insertedTokens()
            noDriver = false
        } catch TokenError.noDriver {
            noDriver = true
            tokens = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    private func enroll() {
        run { lock in
            let r = try await lock.enroll(pin: pin)
            await MainActor.run {
                pin = ""
                replacing = false
                recoveryCode = r.recoveryCode
                // The code comes first; the PIN nag follows on the main view.
            }
        }
    }

    private func run(_ body: @escaping @Sendable (AdminLock) async throws -> Void) {
        guard let lock = model.backend.adminLock else { return }
        busy = true
        error = nil
        Task {
            do { try await body(lock) } catch { self.error = String(describing: error) }
            busy = false
        }
    }
}

/// The recovery code, once, with «Я записал».
private struct RecoveryCodeView: View {
    var code: String
    var note: String? = nil
    var onDone: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("Код восстановления").font(.title3.weight(.semibold))
            if let note {
                Text(note).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text(code)
                .font(.title2.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Запишите его на бумаге и храните отдельно от токена. Он открывает приложение, если токен потеряется или сломается. Приложение не хранит этот код и больше его не покажет.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(copied ? "Скопировано на минуту" : "Скопировать") {
                    SecretClipboard.copy(code)
                    copied = true
                }
                Button("Я записал", action: onDone).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
#endif
