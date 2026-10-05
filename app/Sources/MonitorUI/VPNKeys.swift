#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import CoreImage.CIFilterBuiltins
import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// Issues an AmneziaWG key: name it, then show the config as a QR code and a
/// .conf file. The private key exists only in this config; the app does not
/// keep it, so the sheet says to save it before closing.
struct NewVPNKeySheet: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    var container: String
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var needsPassword = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: AWGNewClient?
    /// Which QR the result shows: the AmneziaVPN link or the .conf text.
    @State private var qrForApp = true

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            if let result { done(result) } else { form }
            Divider()
            buttons
        }
        .frame(width: result?.amneziaLink == nil ? 460 : 600)
        .onDisappear { if let r = result { cleanup(r) } }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Имя", text: $name, prompt: Text("например, iPhone Миши"))
                LabeledContent("Сервер", value: "\(server.name) · \(container)")
            } footer: {
                Text("Ключ создаётся на сервере по SSH, как в приложении AmneziaVPN.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if needsPassword {
                Section {
                    SecureField("Пароль SSH", text: $password)
                } footer: {
                    Text("Нужен, если на сервер входят по паролю. Используется только сейчас.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    if !needsPassword {
                        Button("Ввести пароль SSH") { needsPassword = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 240)
    }

    private func done(_ r: AWGNewClient) -> some View {
        VStack(spacing: 14) {
            Text("Ключ «\(r.client.name)» создан").font(.headline)
            if r.amneziaLink != nil {
                Picker("QR", selection: $qrForApp) {
                    Text("QR для AmneziaVPN").tag(true)
                    Text("QR файла .conf").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            let showLink = qrForApp && r.amneziaLink != nil
            // The vpn:// link is a few KB, so its QR is denser: low error
            // correction and a bigger picture keep it scannable.
            if let qr = showLink ? QRCode.image(r.amneziaLink ?? "", correction: "L") : QRCode.image(r.config) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: showLink ? 320 : 240, height: showLink ? 320 : 240)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
            }
            Text(showLink
                 ? "В приложении AmneziaVPN: Добавить сервер → Вставить ключ (или отсканируйте QR)."
                 : "Отсканируйте в AmneziaVPN или AmneziaWG на телефоне, или сохраните файл .conf и импортируйте его.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let a = r.client.address {
                Text("Адрес в VPN: \(a)").font(.caption).foregroundStyle(.secondary)
            }
            AlertStrip(level: .warning, text: "Приложение не хранит этот ключ. После закрытия окна показать его снова нельзя.", trailing: nil)
        }
        .padding(20)
    }

    private var buttons: some View {
        HStack {
            if let r = result {
                Button("Сохранить .conf…") { save(r) }
                ShareLink(item: tempFile(r), preview: SharePreview(r.fileName)) {
                    Label("Отправить", systemImage: "square.and.arrow.up")
                }
                if let link = r.amneziaLink {
                    Button("Скопировать ссылку vpn://") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                }
                Button(r.amneziaLink == nil ? "Скопировать" : "Скопировать .conf") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(r.config, forType: .string)
                }
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Создать", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanName.isEmpty || busy)
            }
        }
        .padding(16)
    }

    private func create() {
        busy = true
        error = nil
        let pass = needsPassword && !password.isEmpty ? password : nil
        Task {
            do {
                result = try await model.backend.createVPNKey(server: server, container: container,
                                                              name: cleanName, password: pass)
                password = ""
            } catch {
                self.error = String(describing: error)
            }
            busy = false
        }
    }

    private func save(_ r: AWGNewClient) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = r.fileName
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Data(r.config.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Owner-only copy for the share menu, removed when the sheet closes.
    private func tempFile(_ r: AWGNewClient) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vpn-keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(r.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(r.config.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        return url
    }

    private func cleanup(_ r: AWGNewClient) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-keys").appendingPathComponent(r.fileName))
    }
}

enum QRCode {
    /// A crisp QR image; scale up with `.interpolation(.none)`.
    static func image(_ text: String, correction: String = "M") -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
#endif
