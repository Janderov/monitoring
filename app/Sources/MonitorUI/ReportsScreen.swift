#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import MonitorReports
import SwiftUI
import WebKit

/// «Отчёты»: a client's monthly report, made from this Mac's data until the
/// hub makes them by itself. The owner reads it, adds a comment, saves the
/// PDF and sends it by hand, then marks it sent. Nothing goes to a client
/// from here (Mihail's decision 2026-10-10: every report is checked first).
@MainActor
struct ReportsScreen: View {
    @ObservedObject var model: AppModel
    @State private var clientID: String?
    @State private var monthsBack = 1
    @State private var report: ClientReport?
    @State private var error: String?
    @State private var building = false
    @State private var comment = ""
    @State private var sentAt: Date?
    @AppStorage("report.signature") private var signature = "Михаил Дмитраков"
    @AppStorage("report.footer") private var footer = ""
    @StateObject private var web = ReportWeb()

    private var clients: [Client] { model.clientBook.current.filter { !$0.isInternal && $0.state != .ended } }
    private var client: Client? { clients.first { $0.id == clientID } }
    private var timeZone: TimeZone { client?.timezone.flatMap(TimeZone.init(identifier:)) ?? .current }
    private var period: ReportPeriod {
        let cal = Calendar.current
        let anchor = cal.date(byAdding: .month, value: 1 - monthsBack, to: Date()) ?? Date()
        return ReportPeriod.previousMonth(before: anchor, timeZone: timeZone)
    }
    private var key: String { "report.\(clientID ?? "")|\(period.start)" }

    var body: some View {
        HSplitView {
            List(selection: $clientID) {
                Section("Клиенты") {
                    ForEach(clients) { c in
                        HStack {
                            Text(c.name)
                            Spacer()
                            if sentMark(c.id) != nil {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    .help("Отчёт за этот месяц отправлен")
                            }
                        }
                        .tag(c.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)
            .overlay {
                if clients.isEmpty {
                    Text("Нет клиентов. Добавьте клиента в разделе «Клиенты», и здесь появится его отчёт.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }

            VStack(spacing: 0) {
                if client != nil {
                    controls
                    Divider()
                    preview
                } else {
                    Text("Выберите клиента слева").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520)
        }
        .navigationTitle("Отчёты")
        .onAppear { if clientID == nil { clientID = clients.first?.id } }
        .task(id: "\(clientID ?? "")|\(monthsBack)") { await build() }
        .onChange(of: comment) { _, new in
            UserDefaults.standard.set(new, forKey: key + ".comment")
            render()
        }
        .onChange(of: signature) { _, _ in Task { await build() } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Месяц", selection: $monthsBack) {
                    ForEach(1...12, id: \.self) { back in
                        Text(monthTitle(back)).tag(back)
                    }
                }
                .frame(width: 220)
                if building { ProgressView().controlSize(.small) }
                Spacer()
                Button("Обновить") { Task { await build() } }
                    .help("Собрать отчёт заново из данных этого Mac")
                Button("Открыть в Safari") { openInBrowser() }
                    .help("Страница отчёта в браузере: оттуда тоже можно сохранить PDF")
                    .disabled(report == nil)
                Button("Сохранить PDF…") { savePDF() }
                    .disabled(report == nil)
                if let sentAt {
                    Button("Отправлен \(sentAt.formatted(date: .abbreviated, time: .omitted))") { markSent(false) }
                        .help("Снять отметку")
                } else {
                    Button("Отметить отправленным") { markSent(true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(report == nil)
                        .help("Вы проверили отчёт и отправили его клиенту")
                }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("От администратора").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $comment)
                        .font(.body)
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Подпись").font(.caption).foregroundStyle(.secondary)
                    TextField("Имя", text: $signature).frame(width: 200)
                    Text("Подвал").font(.caption).foregroundStyle(.secondary)
                    TextField("Телефон, почта", text: $footer).frame(width: 200)
                        .onSubmit { Task { await build() } }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            } else {
                Text("Собран из данных этого Mac: проверки сайтов хранятся 30 дней, более ранние дни показаны серыми. «Предотвращено» появится, когда отчёты начнёт делать хаб.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var preview: some View {
        ReportWebView(web: web)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Building

    private func build() async {
        guard let client else { report = nil; return }
        let p = period
        comment = UserDefaults.standard.string(forKey: key + ".comment") ?? ""
        sentAt = UserDefaults.standard.object(forKey: key + ".sent") as? Date
        building = true
        defer { building = false }
        do {
            let objects = LocalReport.objects(client, book: model.clientBook, period: p,
                                              servers: model.statuses.map(\.server), sites: model.siteConfigs,
                                              hosting: model.hosting)
            var hourly: [String: [Store.Hourly]] = [:]
            // 30 days before the month too: the disk runway is fitted on the last two weeks.
            let from = p.from.addingTimeInterval(-30 * 86400)
            for s in objects.servers {
                hourly[s.id] = try await model.backend.hourly(s.id, from: from, to: p.to)
            }
            var samples: [String: [Store.SiteSample]] = [:]
            for s in objects.sites {
                samples[s.id] = try await model.backend.siteSamples(s.id, from: p.from, to: p.to)
            }
            var events: [Store.LoggedEvent] = []
            for id in objects.servers.map(\.id) + objects.sites.map({ SiteStatus.alertID($0.id) }) {
                events += try await model.backend.events(limit: 5000, serverID: id)
            }
            let now = Date()
            await model.soon.update(model)
            let soon = Forecasts.gather(model, now: now).soon.map { (object: $0.server, item: $0.item) }
            let sites = model.siteStatuses
            let source = LocalReport.Source(
                signature: signature, footer: footer, servers: model.statuses.map(\.server), sites: model.siteConfigs,
                hosting: model.hosting, hourly: hourly, siteSamples: samples, events: events,
                tlsExpiry: Dictionary(sites.compactMap { s in s.tlsExpiry.map { (s.site.id, $0) } }, uniquingKeysWith: min),
                domainExpiry: Dictionary(sites.compactMap { s in s.domainExpiry.map { (s.site.id, $0) } }, uniquingKeysWith: min),
                soon: soon)
            let input = LocalReport.input(client, book: model.clientBook, source: source, period: p)
            report = ReportBuilder.build(input, now: now)
            error = nil
        } catch {
            report = nil
            self.error = "Не удалось собрать отчёт: \(error.localizedDescription)"
        }
        render()
    }

    private func render() {
        guard let report else { web.load(""); return }
        web.load(ReportPage.html(report, comment: comment, mode: .web(pdfURL: nil), timeZone: timeZone))
    }

    private func monthTitle(_ back: Int) -> String {
        let anchor = Calendar.current.date(byAdding: .month, value: 1 - back, to: Date()) ?? Date()
        let p = ReportPeriod.previousMonth(before: anchor, timeZone: timeZone)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: p.from).capitalized
    }

    private func sentMark(_ id: String) -> Date? {
        UserDefaults.standard.object(forKey: "report.\(id)|\(period.start).sent") as? Date
    }

    private func markSent(_ on: Bool) {
        if on {
            let now = Date()
            UserDefaults.standard.set(now, forKey: key + ".sent")
            sentAt = now
        } else {
            UserDefaults.standard.removeObject(forKey: key + ".sent")
            sentAt = nil
        }
    }

    // MARK: - Files

    private var fileName: String {
        let name = (client?.name ?? "клиент").replacingOccurrences(of: "/", with: "-")
        return "Отчёт \(name) \(period.start.prefix(7))"
    }

    private func openInBrowser() {
        guard let report else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName + ".html")
        do {
            try ReportPage.html(report, comment: comment, mode: .pdf, timeZone: timeZone)
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            self.error = "Не удалось открыть: \(error.localizedDescription)"
        }
    }

    private func savePDF() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The PDF is one tall page, so it needs its own margins instead of @page ones.
        let html = ReportPage.html(report, comment: comment, mode: .pdf, timeZone: timeZone)
            .replacingOccurrences(of: "</style>", with: "body{padding:28px 32px}</style>")
        web.printPDF(html: html, to: url) { ok in
            if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { error = "PDF не сохранился" }
        }
    }
}

/// The preview and a hidden page that prints the A4 version.
@MainActor
final class ReportWeb: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView = {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.setValue(false, forKey: "drawsBackground")
        return v
    }()
    /// A4 width at 72 dpi, so the layout matches a printed page.
    private let printer = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
    private var pending: (url: URL, done: (Bool) -> Void)?
    private var shown = ""

    override init() {
        super.init()
        printer.navigationDelegate = self
    }

    func load(_ html: String) {
        guard html != shown else { return }
        shown = html
        view.loadHTMLString(html, baseURL: nil)
    }

    func printPDF(html: String, to url: URL, done: @escaping (Bool) -> Void) {
        pending = (url: url, done: done)
        printer.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard webView === printer, let job = pending else { return }
            pending = nil
            // One page as tall as the report: WebKit's PDF of what is laid out.
            // Safari («Открыть в Safari») prints the same page on A4 sheets.
            printer.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let height = max(800, (value as? NSNumber)?.doubleValue ?? 800)
                    self.printer.frame = NSRect(x: 0, y: 0, width: 595, height: height)
                    let config = WKPDFConfiguration()
                    config.rect = CGRect(x: 0, y: 0, width: 595, height: height)
                    self.printer.createPDF(configuration: config) { result in
                        MainActor.assumeIsolated {
                            switch result {
                            case .success(let data):
                                job.done((try? data.write(to: job.url)) != nil)
                            case .failure:
                                job.done(false)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReportWebView: NSViewRepresentable {
    @ObservedObject var web: ReportWeb
    func makeNSView(context: Context) -> WKWebView { web.view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
