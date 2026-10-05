#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// Reinstalls the agent on every server in one go, one after another, with
/// the version bundled in this app. Token and certificate stay the same
/// (the installer keeps them on an upgrade), so polling goes on as before.
/// A server whose saved SSH password is missing or wrong asks for it in its
/// own row and can be retried alone.
struct UpdateAgentsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum RowState: Equatable {
        case waiting
        case running(String)
        case done(String)
        case failed(String)
    }

    @State private var states: [String: RowState] = [:]
    @State private var passwords: [String: String] = [:]
    @State private var running = false

    private var servers: [ServerConfig] {
        model.statuses.map(\.server).filter { model.can(.installAgent, $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Обновить агентов").font(.headline)
                Text("Агент на каждом сервере переустановится по SSH версией из этого приложения. Токен и сертификат не меняются.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            List(servers) { s in row(s) }
                .listStyle(.inset)
                .frame(minHeight: CGFloat(max(servers.count, 2)) * 44)
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(allDone ? "Готово" : "Закрыть") { dismiss() }
                    .keyboardShortcut(allDone ? .defaultAction : .cancelAction)
                    .disabled(running)
                if !allDone {
                    Button(states.isEmpty ? "Обновить всех" : "Повторить с ошибкой") { start(failedOnly: !states.isEmpty) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || servers.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    private var allDone: Bool {
        !servers.isEmpty && servers.allSatisfy { if case .done = states[$0.id] { return true } else { return false } }
    }

    private func row(_ s: ServerConfig) -> some View {
        let state = states[s.id] ?? .waiting
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon(state).frame(width: 16)
                Text(s.name).lineLimit(1)
                Spacer(minLength: 8)
                Text(label(state)).font(.callout).foregroundStyle(color(state)).lineLimit(1)
            }
            if case .failed(let why) = state {
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Пароль SSH, если сервер его просит", text: binding(s.id))
                        .textFieldStyle(.roundedBorder)
                    Button("Повторить") { Task { await run(s, alone: true) } }.disabled(running)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { passwords[id, default: ""] }, set: { passwords[id] = $0 })
    }

    @ViewBuilder private func icon(_ s: RowState) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func label(_ s: RowState) -> String {
        switch s {
        case .waiting: return "ожидает"
        case .running(let step): return step
        case .done(let v): return v
        case .failed: return "не удалось"
        }
    }

    private func color(_ s: RowState) -> Color {
        if case .failed = s { return .orange }
        return .secondary
    }

    private func start(failedOnly: Bool) {
        let list = servers.filter { s in
            guard failedOnly else { return true }
            if case .failed = states[s.id] { return true } else { return false }
        }
        Task {
            running = true
            for s in list { await run(s, alone: false) }
            running = false
        }
    }

    private func run(_ s: ServerConfig, alone: Bool) async {
        if alone { running = true }
        defer { if alone { running = false } }
        let target = s.ssh ?? SSHTarget(host: s.host, user: "root")
        let typed = passwords[s.id, default: ""]
        let pass = typed.isEmpty ? model.backend.savedPassword(serverID: s.id) : typed
        let (updates, sink) = AsyncStream<InstallStep>.makeStream()
        let id = s.id
        Task { for await step in updates { states[id] = .running(step.title.lowercased() + "…") } }
        states[id] = .running("подключение…")
        do {
            let result = try await model.backend.installAgent(target, password: pass, agentPort: s.port) { step, state in
                if state == .running { sink.yield(step) }
            }
            sink.finish()
            if result.token != s.token || result.fingerprint != s.fingerprint {
                var updated = s
                updated.token = result.token
                updated.fingerprint = result.fingerprint
                try await model.save(server: updated)
            }
            states[id] = result.verified
                ? .done(result.version.isEmpty ? "обновлён" : "версия \(result.version)")
                : .failed("Агент поставлен, но Mac до него не достучался на порт \(result.port). Обычно это файрвол хостинга.")
            passwords[id] = nil
        } catch {
            sink.finish()
            states[id] = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
#endif
