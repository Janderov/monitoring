#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// Add or edit a client: name and colour, legal details, contacts, tariff.
struct ClientForm: View {
    @ObservedObject var model: AppModel
    var original: Client?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var shortName = ""
    @State private var kind = Client.Kind.company
    @State private var state = Client.State.active
    @State private var color = ClientColor.blue
    @State private var legalName = ""
    @State private var inn = ""
    @State private var timezone = ""
    @State private var notes = ""
    @State private var contacts: [ClientContact] = []
    @State private var plan = ""
    @State private var price = ""
    @State private var currency = "₽"
    @State private var billingDay = ""
    @State private var sla = ""
    @State private var reportDay = "1"
    @State private var busy = false
    @State private var error: String?
    @State private var confirmArchive = false

    private var isInternal: Bool { original?.isInternal == true }

    private var problem: String? {
        if !clean(price).isEmpty, number(price) == nil { return "Цена: число, например 4000" }
        if !clean(billingDay).isEmpty, day(billingDay) == nil { return "День оплаты: от 1 до 31" }
        if !clean(reportDay).isEmpty, day(reportDay) == nil { return "День отчёта: от 1 до 31" }
        if !clean(sla).isEmpty, number(sla).map({ (0...100).contains($0) }) != true { return "Доступность: процент, например 99,5" }
        if !clean(plan).isEmpty, number(price) == nil { return "Укажите цену тарифа" }
        if !clean(timezone).isEmpty, TimeZone(identifier: clean(timezone)) == nil { return "Часовой пояс вида Europe/Moscow" }
        let n = clean(name).lowercased()
        if model.clientBook.current.contains(where: { $0.id != original?.id && $0.name.lowercased() == n }) {
            return "Клиент с таким именем уже есть"
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Название", text: $name, prompt: Text("Студия Вектор"))
                        .disabled(isInternal)
                    TextField("Коротко", text: $shortName, prompt: Text("для карты и таблиц, необязательно"))
                    if !isInternal {
                        Picker("Кто", selection: $kind) {
                            Text("Компания или ИП").tag(Client.Kind.company)
                            Text("Частное лицо").tag(Client.Kind.person)
                        }
                        Picker("Состояние", selection: $state) {
                            Text("Обслуживается").tag(Client.State.active)
                            Text("Пауза").tag(Client.State.paused)
                            Text("Завершён").tag(Client.State.ended)
                        }
                    }
                    Picker("Цвет", selection: $color) {
                        ForEach(ClientColor.allCases, id: \.self) { c in
                            Text(c.title).tag(c)
                        }
                    }
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.orange) }
                    else if state == .paused { Text("На паузе клиент не получает отчёт и уведомления, проверки продолжаются.").font(.caption).foregroundStyle(.secondary) }
                }
                if !isInternal {
                    Section("Реквизиты") {
                        TextField("Юр. название", text: $legalName, prompt: Text("ООО «Вектор», необязательно"))
                        TextField("ИНН", text: $inn, prompt: Text("необязательно"))
                        TextField("Часовой пояс", text: $timezone, prompt: Text("Europe/Moscow"))
                    }
                    contactsSection
                    Section {
                        TextField("Тариф", text: $plan, prompt: Text("Базовый"))
                        HStack {
                            TextField("Цена в месяц", text: $price, prompt: Text("4000"))
                            Picker("", selection: $currency) {
                                Text("₽").tag("₽")
                                Text("€").tag("€")
                                Text("$").tag("$")
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        TextField("Оплата до какого числа", text: $billingDay, prompt: Text("5"))
                        TextField("Обещанная доступность, %", text: $sla, prompt: Text("99,5"))
                        TextField("Отчёт присылать числа", text: $reportDay, prompt: Text("1"))
                    } header: {
                        Text("Договор")
                    } footer: {
                        Text("Если поменять тариф или цену, старый тариф сохранится в истории: отчёты за прошлые месяцы не изменятся.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Заметки") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .formStyle(.grouped)
            FormButtons(primary: original == nil ? "Добавить" : "Сохранить",
                        enabled: !clean(name).isEmpty && problem == nil, busy: busy, action: save) {
                if original != nil, !isInternal {
                    Button("В архив…", role: .destructive) { confirmArchive = true }
                }
            }
        }
        .frame(width: 540)
        .frame(minHeight: 560)
        .onAppear(perform: load)
        .confirmationDialog("Отправить «\(original?.name ?? "")» в архив?", isPresented: $confirmArchive) {
            Button("В архив", role: .destructive, action: archive)
        } message: {
            Text("Клиент пропадёт из списков, его объекты вернутся к «Своё». История и прошлые отчёты сохранятся.")
        }
    }

    private var contactsSection: some View {
        Section {
            ForEach($contacts) { $c in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Имя", text: $c.name, prompt: Text("Анна Ковалёва"))
                        Picker("", selection: $c.role) {
                            ForEach(ClientContact.Role.allCases, id: \.self) { r in Text(r.title).tag(r) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            contacts.removeAll { $0.id == c.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Удалить контакт")
                    }
                    HStack {
                        TextField("Телефон", text: optionalText($c.phone), prompt: Text("телефон"))
                        TextField("Почта", text: optionalText($c.email), prompt: Text("почта"))
                        TextField("Telegram", text: optionalText($c.telegram), prompt: Text("@telegram"))
                    }
                    HStack(spacing: 16) {
                        Toggle("Получает отчёт", isOn: $c.receivesReport)
                        Toggle("Получает аварии", isOn: $c.receivesAlerts)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(.vertical, 2)
            }
            Button("Добавить контакт") { contacts.append(ClientContact(name: "")) }
        } header: {
            Text("Контакты")
        } footer: {
            Text("Кому слать отчёт и кому писать при аварии. Контакты хранятся только на этом Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func optionalText(_ b: Binding<String?>) -> Binding<String> {
        Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = optional($0) })
    }

    private func load() {
        guard let o = original else {
            color = nextColor()
            return
        }
        name = o.name; shortName = o.shortName ?? ""; kind = o.kind; state = o.state; color = o.color
        legalName = o.legalName ?? ""; inn = o.inn ?? ""; timezone = o.timezone ?? ""; notes = o.notes ?? ""
        contacts = o.contacts
        if let c = o.contract() {
            plan = c.planName
            price = String(format: "%g", c.monthlyPrice)
            currency = c.currency
            billingDay = c.billingDay.map(String.init) ?? ""
            sla = c.slaUptime.map { String(format: "%g", $0) } ?? ""
            reportDay = c.reportDay.map(String.init) ?? ""
        }
    }

    /// A colour no other client has yet, when there is one.
    private func nextColor() -> ClientColor {
        let used = Set(model.clientBook.current.map(\.color))
        return ClientColor.allCases.first { $0 != .gray && !used.contains($0) } ?? .blue
    }

    private func save() {
        var c = original ?? Client(name: "")
        c.name = clean(name)
        c.shortName = optional(shortName)
        c.kind = kind
        c.state = isInternal ? .active : state
        c.color = color
        c.legalName = optional(legalName)
        c.inn = optional(inn)
        c.timezone = optional(timezone)
        c.notes = optional(notes)
        c.contacts = contacts.filter { !clean($0.name).isEmpty }
        if !isInternal { c.contracts = contracts(of: c) }
        var book = model.clientBook
        book.upsert(c)
        run(book, detail: original == nil ? "добавлен клиент «\(c.name)»" : "изменён клиент «\(c.name)»")
    }

    /// The tariff history with the form's tariff in force from today. Only a
    /// new plan, price or currency starts a new entry; days and the promised
    /// availability are corrected in place.
    private func contracts(of c: Client) -> [ClientContract] {
        var list = c.contracts
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let current = c.contract(at: now)
        let index = current.flatMap { cur in list.firstIndex { $0.id == cur.id } }
        guard let price = number(price) else {
            // Tariff cleared: the current one ends today.
            if let index { list[index].endedOn = max(today, list[index].startedOn) }
            return list.filter { $0.endedOn != $0.startedOn }
        }
        var wanted = ClientContract(planName: optional(plan) ?? "Тариф", monthlyPrice: price, currency: currency,
                                    billingDay: day(billingDay), startedOn: today,
                                    slaUptime: number(sla), reportDay: day(reportDay))
        if let index {
            let cur = list[index]
            if cur.planName == wanted.planName, cur.monthlyPrice == wanted.monthlyPrice, cur.currency == wanted.currency {
                wanted.id = cur.id
                wanted.startedOn = cur.startedOn
                list[index] = wanted
                return list
            }
            if cur.startedOn >= today {
                // Started today: a correction, not a change of tariff.
                wanted.id = cur.id
                list[index] = wanted
                return list
            }
            list[index].endedOn = today
        }
        list.append(wanted)
        return list
    }

    private func archive() {
        guard let o = original else { return }
        var book = model.clientBook
        book.archive(o.id)
        run(book, detail: "клиент «\(o.name)» в архиве")
    }

    private func run(_ book: ClientBook, detail: String) {
        busy = true
        error = nil
        Task {
            do {
                try await model.saveClients(book, detail: detail)
                if original == nil, let added = book.clients.last { model.selectedClientID = added.id }
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            busy = false
        }
    }

    private func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func optional(_ s: String) -> String? {
        let t = clean(s)
        return t.isEmpty ? nil : t
    }

    private func number(_ s: String) -> Double? {
        Double(clean(s).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: ""))
    }

    private func day(_ s: String) -> Int? {
        guard let d = Int(clean(s)), (1...31).contains(d) else { return nil }
        return d
    }
}
#endif
