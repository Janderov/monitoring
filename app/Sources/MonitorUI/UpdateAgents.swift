#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// Updates the agent on the servers that need it, one after another, with the
/// version bundled in this app. The first server goes alone: only if it comes
/// back fine do the others follow, and the first error stops the rest. On the
/// server, an agent that does not start is put back to the previous version
/// by install.sh. Token and certificate stay the same, so polling goes on.
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
        /// Left alone because an earlier server failed.
        case held
    }

    @State private var states: [String: RowState] = [:]
    @State private var passwords: [String: String] = [:]
    @State private var running = false
    @State private var stopped: String?

    private var servers: [ServerConfig] {
        model.statuses.map(\.server).filter { model.can(.installAgent, $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Обновить агентов").font(.headline)
                Text("Сначала обновится один сервер, и только если он вернулся в строй, остальные по очереди. При первой ошибке обновление остановится. Агент, который не запустился, сам вернётся на прежнюю версию. Токен и сертификат не меняются.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let bundled = AgentBundle.version {
                    Text("Версия в приложении: \(bundled)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            List(servers) { s in row(s) }
                .listStyle(.inset)
                .frame(minHeight: CGFloat(max(servers.count, 2)) * 44)
            Divider()
            if let stopped {
                Label(stopped, systemImage: "pause.circle").foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 10)
            }
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(allDone ? "Готово" : "Закрыть") { dismiss() }
                    .keyboardShortcut(allDone ? .defaultAction : .cancelAction)
                    .disabled(running)
                if !allDone {
                    Button(started ? "Продолжить" : "Обновить") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || servers.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 520)
        .onAppear {
            for s in servers where !needsUpdate(s) { states[s.id] = .done("актуален") }
        }
    }

    /// Outdated, or not answering (its agent may be the problem).
    private func needsUpdate(_ s: ServerConfig) -> Bool {
        guard let snap = model.status(s.id)?.snapshot, model.status(s.id)?.error == nil else { return true }
        return AgentBundle.outdated(snap)
    }

    private var started: Bool {
        states.values.contains { if case .done = $0 { return false } else { return $0 != .waiting } }
    }

    private func current(_ s: ServerConfig) -> String? {
        guard let snap = model.status(s.id)?.snapshot else { return nil }
        return snap.agentVersion ?? "старая версия"
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
                Text(label(state, s)).font(.callout).foregroundStyle(color(state)).lineLimit(1)
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
        case .held: Image(systemName: "pause.circle").foregroundStyle(.tertiary)
        }
    }

    private func label(_ s: RowState, _ server: ServerConfig) -> String {
        switch s {
        case .held: return "не тронут"
        case .waiting: return current(server).map { "\($0) → новая" } ?? "ожидает"
        case .running(let step): return step
        case .done(let v): return v
        case .failed: return "не удалось"
        }
    }

    private func color(_ s: RowState) -> Color {
        if case .failed = s { return .orange }
        return .secondary
    }

    /// The servers still to do, the first one alone: the rest wait until it
    /// is back, and stop at the first error.
    private func start() {
        let list = servers.filter { s in
            switch states[s.id] ?? .waiting {
            case .done: return false
            default: return true
            }
        }
        stopped = nil
        Task {
            running = true
            for (i, s) in list.enumerated() {
                await run(s, alone: false)
                if case .failed = states[s.id] {
                    for rest in list.dropFirst(i + 1) { states[rest.id] = .held }
                    stopped = i == 0 && list.count > 1
                        ? "Первый сервер не обновился, остальные не тронуты."
                        : list.count > i + 1 ? "Остановлено на ошибке, остальные не тронуты." : nil
                    break
                }
            }
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
