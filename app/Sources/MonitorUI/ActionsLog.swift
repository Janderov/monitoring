#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// The Journal's second tab: who did what, for every person using the app.
/// Today it is only the owner; once other admins or VPN operators sign in,
/// their changes land here too, and "Кто" narrows the list to one person.
struct ActionsLog: View {
    @ObservedObject var model: AppModel
    @State private var records: [AuditRecord] = []
    @State private var person = ""
    @State private var action = ""
    @State private var onlyProblems = false

    var body: some View {
        let shown = filtered
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Кто", selection: $person) {
                    Text("Все").tag("")
                    ForEach(people, id: \.id) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Picker("Действие", selection: $action) {
                    Text("Все").tag("")
                    ForEach(UserAction.allCases.filter { $0 != .view }, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .fixedSize()
                Toggle("Только ошибки и отказы", isOn: $onlyProblems)
                Spacer()
                Text("\(shown.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if shown.isEmpty {
                EmptyNote(title: records.isEmpty ? "Пока ничего не менялось" : "Ничего не найдено",
                          detail: records.isEmpty ? "Здесь появятся изменения серверов и сайтов, ключи VPN, входы по SSH и обновления." : nil)
            } else {
                Table(shown) {
                    TableColumn("Время") { r in Text(Fmt.time(r.time)).monospacedDigit() }.width(min: 90, ideal: 120)
                    TableColumn("Кто") { r in Text(r.actor.name).lineLimit(1) }.width(min: 80, ideal: 130)
                    TableColumn("Действие") { r in Text(r.action.title).lineLimit(1) }.width(min: 100, ideal: 150)
                    TableColumn("Объект") { r in Text(r.object.name).lineLimit(1) }.width(min: 80, ideal: 150)
                    TableColumn("Подробности") { r in Text(r.detail).lineLimit(1).help(r.detail) }
                    TableColumn("Итог") { r in result(r) }.width(min: 90, ideal: 160)
                }
            }
        }
        .task(id: model.lastRound) {
            records = (try? await model.backend.auditLog(limit: 2000, objectID: nil)) ?? []
        }
    }

    private var filtered: [AuditRecord] {
        records.filter { r in
            (person.isEmpty || r.actor.id == person)
                && (action.isEmpty || r.action.rawValue == action)
                && (!onlyProblems || r.result != .done)
        }
    }

    /// Everyone found in the log, in order of first appearance.
    private var people: [AppUser] {
        var seen = Set<String>()
        return records.compactMap { seen.insert($0.actor.id).inserted ? $0.actor : nil }
    }

    private func result(_ r: AuditRecord) -> some View {
        HStack(spacing: 6) {
            switch r.result {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            Text(label(r)).lineLimit(1)
        }
        .help(r.error ?? "")
    }

    private func label(_ r: AuditRecord) -> String {
        switch r.result {
        case .done: return "выполнено"
        case .failed: return r.error.map { "ошибка: \($0)" } ?? "ошибка"
        case .denied: return "нет прав"
        }
    }
}
#endif
