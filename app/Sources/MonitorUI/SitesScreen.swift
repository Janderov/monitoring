#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

struct SitesTable: View {
    @ObservedObject var model: AppModel
    var sites: [SiteSummary]
    @Binding var selection: String?

    var body: some View {
        Table(sites, selection: $selection) {
            TableColumn("Сайт") { s in
                HStack(spacing: 7) { StatusDot(level: s.level()); Text(s.name) }
            }
            TableColumn("Код") { s in Text(s.statusCode.map(String.init) ?? "—").monospacedDigit() }.width(min: 40, ideal: 50)
            TableColumn("Ответ, среднее") { s in Text(s.averageLatency.map(Fmt.ms) ?? "—").monospacedDigit() }
            TableColumn("Откуда проверяется") { s in
                Text(s.origins.map { origin($0) }.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn("SSL") { s in
                let days = s.tlsExpiry.map { Fmt.days(until: $0) }
                Text(days.map { "\($0) д" } ?? "—").monospacedDigit()
                    .foregroundStyle((days ?? 99) <= 14 ? Color.orange : Color.primary)
            }
            .width(min: 40, ideal: 56)
        }
    }

    private func origin(_ o: SiteSummary.Origin) -> String {
        let name = Country.detect(o.server)?.code ?? o.server.name
        return o.check.ok ? name : "\(name) ✕"
    }
}

/// Sites: list on the left, the selected site on the right.
struct SitesScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sites = model.sites
        HSplitView {
            SitesTable(model: model, sites: sites, selection: $model.selectedSiteID)
                .frame(minWidth: 320, idealWidth: 420, maxWidth: 560)
            Group {
                if let id = model.selectedSiteID, let site = sites.first(where: { $0.id == id }) {
                    SiteDetail(site: site)
                } else if sites.isEmpty {
                    EmptyNote(title: "Сайтов пока нет",
                              detail: "Проверки сайтов задаются в конфиге агентов (targets). Проверки с Mac и сроки домена появятся в следующем обновлении ядра.")
                } else {
                    EmptyNote(title: "Выберите сайт")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .navigationTitle("Сайты")
        .navigationSubtitle("\(sites.count) · проверка раз в минуту с серверов")
    }
}

private struct SiteDetail: View {
    var site: SiteSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(site.name).font(.title2.weight(.semibold)).lineLimit(1)
                            StatusBadge(level: site.level())
                        }
                        Text(site.url).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if let url = URL(string: site.url) {
                        Button("Открыть в браузере") { NSWorkspace.shared.open(url) }
                    }
                }
                if let p = site.problem {
                    AlertStrip(level: site.level(), text: p, trailing: nil)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    Group {
                        Fact(title: "Отвечают", value: "\(site.origins.filter(\.check.ok).count) из \(site.origins.count)")
                        Fact(title: "Среднее время ответа", value: site.averageLatency.map(Fmt.ms) ?? "—")
                        Fact(title: "SSL до", value: site.tlsExpiry.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                        Fact(title: "Домен до", value: "появится с проверками RDAP")
                    }
                }
                GroupBox {
                    Table(site.origins) {
                        TableColumn("Откуда") { o in
                            HStack(spacing: 7) {
                                StatusDot(level: o.check.ok ? .ok : .critical)
                                Text(Country.detect(o.server)?.name ?? "—")
                                Text(o.server.name).foregroundStyle(.secondary)
                            }
                        }
                        TableColumn("Код") { o in Text(o.check.statusCode.map(String.init) ?? "—").monospacedDigit() }
                        TableColumn("Время ответа") { o in Text(o.check.ok ? Fmt.ms(o.check.latencyMs) : "—").monospacedDigit() }
                        TableColumn("Ошибка") { o in Text(o.check.error ?? "").foregroundStyle(.secondary) }
                    }
                    .frame(height: tableHeight(site.origins.count, max: 10))
                } label: {
                    Text("Доступность по странам").font(.callout.weight(.semibold))
                }
                Text("История доступности по часам и график времени ответа появятся, когда ядро начнёт хранить проверки сайтов.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
