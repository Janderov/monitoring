#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// Moving to another Mac: one file with the servers, sites, passwords and
/// history, encrypted with a password. On the new Mac the app is installed
/// and the file imported; the agents keep working as they are.
struct TransferSettings: View {
    @ObservedObject var model: AppModel
    @State private var sheet: Mode?

    enum Mode: Identifiable {
        case export
        case importing(URL)
        var id: String { if case .importing(let u) = self { return u.path }; return "export" }
    }

    var body: some View {
        LabeledContent("Перенос на другой Мак") {
            HStack {
                Button("Экспорт…") { sheet = .export }
                Button("Импорт…") { chooseFile() }
            }
            .disabled(!model.can(.transfer))
        }
        .sheet(item: $sheet) { mode in
            TransferSheet(model: model, mode: mode)
        }
        Text("Один файл с серверами, сайтами, паролями и историей, зашифрованный вашим паролем. На новом Маке установите приложение и нажмите «Импорт…».")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Transfer.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { sheet = .importing(url) }
    }
}

private struct TransferSheet: View {
    @ObservedObject var model: AppModel
    let mode: TransferSettings.Mode
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var repeated = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmImport = false
    @State private var imported: ServersFile?

    private var isExport: Bool { if case .export = mode { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isExport ? "Экспорт для переноса" : "Импорт с другого Мака").font(.headline)
            if let imported {
                Label("Перенесено: серверов \(imported.servers.count), сайтов \(imported.sites?.count ?? 0).",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Чтобы подхватить историю, приложение перезапустится.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(isExport
                     ? "Придумайте пароль: без него файл не открыть. В файле токены агентов и пароли, храните его как пароль."
                     : "Введите пароль, с которым файл сохраняли. Серверы, сайты и история на этом Маке заменятся данными из файла.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Пароль", text: $password).textFieldStyle(.roundedBorder)
                if isExport {
                    SecureField("Пароль ещё раз", text: $repeated).textFieldStyle(.roundedBorder)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if imported != nil {
                    Button("Перезапустить") { relaunch() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(isExport ? "Сохранить файл…" : "Импортировать") {
                        if isExport { Task { await export() } } else { confirmImport = true }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !ready)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .confirmationDialog("Заменить серверы, сайты и историю на этом Маке?", isPresented: $confirmImport) {
            Button("Заменить", role: .destructive) { Task { await runImport() } }
        } message: {
            Text("Нынешняя база сохранится в папке данных, в Previous.")
        }
    }

    private var ready: Bool {
        guard password.count >= Transfer.minPasswordLength else { return false }
        return !isExport || password == repeated
    }

    private func export() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let backend = model.backend, password = password
            let data = try await backend.audited(.transfer, on: .app, detail: "экспорт") {
                try await backend.exportTransfer(password: password)
            }
            let panel = NSSavePanel()
            let day = Date().formatted(.iso8601.year().month().day())
            panel.nameFieldStringValue = "Монитор-перенос-\(day).\(Transfer.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dismiss()
        } catch {
            self.error = Self.text(error)
        }
    }

    private func runImport() async {
        guard case .importing(let url) = mode else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            let file = try Data(contentsOf: url)
            let backend = model.backend, password = password
            imported = try await backend.audited(.transfer, on: .app, detail: "импорт из \(url.lastPathComponent)") {
                try await backend.importTransfer(file, password: password)
            }
            password = ""
        } catch {
            self.error = Self.text(error)
        }
    }

    private static func text(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func relaunch() {
        do {
            try AppUpdater.scheduleRelaunch()
            NSApp.terminate(nil)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
