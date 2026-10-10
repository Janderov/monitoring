import Foundation
import MonitorCore
import PostgresNIO

/// The Mac's clients.json (ClientBook) into inv.client and friends. The Mac
/// is the place clients are edited until the hub has its own screens, so an
/// import makes the hub's clients match the file: contacts and contracts the
/// file no longer has are removed, and the owners of every imported server,
/// site and VPN key are replaced by the file's rows. Objects nobody owns
/// belong to «Своё», as on the Mac.
enum ClientImport {
    static var day: DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func currency(_ symbol: String) -> String {
        TransferImport.currency(symbol) ?? "RUB"
    }

    /// Book client id → inv.client id. «Своё» maps onto the hub's internal
    /// client; a client the hub already has under the same name is reused.
    static func clients(_ db: Database, _ book: ClientBook, internalID: UUID) async throws -> [String: UUID] {
        var ids: [String: UUID] = [:]
        let d = day
        for c in book.clients {
            var id: UUID
            if c.isInternal {
                id = internalID
            } else if let u = UUID(uuidString: c.id),
                      try await db.scalar("SELECT true FROM inv.client WHERE id = \(u)", as: Bool.self) == true {
                id = u
            } else if let existing = try await db.scalar("SELECT id FROM inv.client WHERE name = \(c.name)", as: UUID.self) {
                id = existing
            } else {
                id = UUID(uuidString: c.id) ?? UUID()
                try await db.query("INSERT INTO inv.client (id, name, created_at) VALUES (\(id), \(c.name), \(c.createdAt))")
            }
            ids[c.id] = id
            try await db.transaction { conn in
                try await conn.query("""
                    UPDATE inv.client SET name = \(c.isInternal ? ClientBook.internalName : c.name), short_name = \(c.shortName),
                      kind = \(c.kind.rawValue), status = \(c.state.rawValue), is_internal = \(c.isInternal),
                      color = \(c.color.rawValue), legal_name = \(c.legalName), inn = \(c.inn),
                      timezone = coalesce(\(c.timezone), 'Europe/Moscow'), notes = coalesce(\(c.notes), ''),
                      archived_at = \(c.archivedAt), updated_at = now()
                    WHERE id = \(id)
                    """, logger: db.logger)

                let contactIDs = c.contacts.compactMap { UUID(uuidString: $0.id) }
                try await conn.query("DELETE FROM inv.client_contact WHERE client_id = \(id) AND NOT (id = ANY(\(contactIDs)))",
                                     logger: db.logger)
                for (i, p) in c.contacts.enumerated() {
                    let pid = UUID(uuidString: p.id) ?? UUID()
                    try await conn.query("""
                        INSERT INTO inv.client_contact (id, client_id, name, role, email, phone, telegram,
                                                        receives_report, receives_alerts, sort)
                        VALUES (\(pid), \(id), \(p.name), \(p.role.rawValue), \(p.email.nonEmpty)::citext, \(p.phone.nonEmpty),
                                \(p.telegram.nonEmpty), \(p.receivesReport), \(p.receivesAlerts), \(i))
                        ON CONFLICT (id) DO UPDATE SET client_id = EXCLUDED.client_id, name = EXCLUDED.name,
                          role = EXCLUDED.role, email = EXCLUDED.email, phone = EXCLUDED.phone,
                          telegram = EXCLUDED.telegram, receives_report = EXCLUDED.receives_report,
                          receives_alerts = EXCLUDED.receives_alerts, sort = EXCLUDED.sort
                        """, logger: db.logger)
                }

                let contractIDs = c.contracts.compactMap { UUID(uuidString: $0.id) }
                try await conn.query("DELETE FROM inv.client_contract WHERE client_id = \(id) AND NOT (id = ANY(\(contractIDs)))",
                                     logger: db.logger)
                for k in c.contracts {
                    let kid = UUID(uuidString: k.id) ?? UUID()
                    let started = d.string(from: k.startedOn)
                    // An end before the start would break the table's check.
                    let ended = k.endedOn.map { max(d.string(from: $0), started) }
                    let billing = k.billingDay.flatMap { (1...31).contains($0) ? Int64($0) : nil }
                    try await conn.query("""
                        INSERT INTO inv.client_contract (id, client_id, plan_name, monthly_price, currency, billing_day,
                                                         sla_uptime, started_on, ended_on)
                        VALUES (\(kid), \(id), \(k.planName), \(k.monthlyPrice)::numeric(12,2), \(currency(k.currency)),
                                \(billing)::smallint, \(k.slaUptime)::numeric(6,3), \(started)::date, \(ended)::date)
                        ON CONFLICT (id) DO UPDATE SET client_id = EXCLUDED.client_id, plan_name = EXCLUDED.plan_name,
                          monthly_price = EXCLUDED.monthly_price, currency = EXCLUDED.currency,
                          billing_day = EXCLUDED.billing_day, sla_uptime = EXCLUDED.sla_uptime,
                          started_on = EXCLUDED.started_on, ended_on = EXCLUDED.ended_on
                        """, logger: db.logger)
                }

                // The report goes out on the day the current contract names.
                if let reportDay = c.contract()?.reportDay {
                    let dom = Int64(min(max(reportDay, 1), 28))
                    try await conn.query("""
                        INSERT INTO rep.client_report_settings (client_id, day_of_month) VALUES (\(id), \(dom)::smallint)
                        ON CONFLICT (client_id) DO UPDATE SET day_of_month = EXCLUDED.day_of_month
                        """, logger: db.logger)
                }
            }
        }
        return ids
    }

    /// Replaces the owners of the imported objects with the book's rows.
    /// VPN keys are matched by public key on every server that has them; a
    /// key the hub has not seen yet is reported and gets its owner on the
    /// next import.
    static func assets(_ db: Database, _ book: ClientBook, clients: [String: UUID], internalID: UUID,
                       servers: [String: UUID], sites: [String: UUID], now: Date,
                       report: inout TransferImport.Report) async throws {
        let d = day
        var vpnKeys: [String: [UUID]] = [:]
        let rows = try await db.query("SELECT public_key, id FROM inv.vpn_key WHERE revoked_at IS NULL")
        for try await (key, id) in rows.decode((String, UUID).self) { vpnKeys[key, default: []].append(id) }

        func hubIDs(_ type: AssetType, _ id: String) -> [UUID] {
            switch type {
            case .server: return servers[id].map { [$0] } ?? []
            case .site: return sites[id].map { [$0] } ?? []
            case .vpnKey: return vpnKeys[id] ?? []
            }
        }

        var assigned = 0, missingKeys: Set<String> = []
        var owned: Set<String> = []  // "type/uuid" with an active owner now
        try await db.transaction { conn in
            let replaced = Array(servers.values) + Array(sites.values) + vpnKeys.values.flatMap { $0 }
            try await conn.query("""
                DELETE FROM inv.client_asset WHERE asset_type IN ('server','site','vpn_key') AND asset_id = ANY(\(replaced))
                """, logger: db.logger)
            for a in book.assets {
                guard let client = clients[a.clientID] else { continue }
                let targets = hubIDs(a.type, a.assetID)
                if targets.isEmpty {
                    if a.type == .vpnKey { missingKeys.insert(a.assetID) }
                    continue
                }
                let since = d.string(from: a.since)
                let until = a.until.map { max(d.string(from: $0), since) }
                let share = a.sharePercent.flatMap { $0 > 0 && $0 <= 100 ? $0 : nil }
                for t in targets {
                    try await conn.query("""
                        INSERT INTO inv.client_asset (client_id, asset_type, asset_id, share_pct, since, until)
                        VALUES (\(client), \(a.type.rawValue), \(t), \(share)::numeric(5,2), \(since)::date, \(until)::date)
                        ON CONFLICT (client_id, asset_type, asset_id, since)
                          DO UPDATE SET share_pct = EXCLUDED.share_pct, until = EXCLUDED.until
                        """, logger: db.logger)
                    assigned += 1
                    if a.active(at: now), book.client(a.clientID)?.archivedAt == nil {
                        owned.insert("\(a.type.rawValue)/\(t)")
                    }
                }
            }
            // Nobody's servers and sites are «Своё». VPN keys too, as on the Mac.
            let today = d.string(from: now)
            let all: [(String, UUID)] = servers.values.map { ("server", $0) } + sites.values.map { ("site", $0) }
                + vpnKeys.values.flatMap { $0 }.map { ("vpn_key", $0) }
            for (type, id) in all where !owned.contains("\(type)/\(id)") {
                try await conn.query("""
                    INSERT INTO inv.client_asset (client_id, asset_type, asset_id, since)
                    VALUES (\(internalID), \(type), \(id), \(today)::date) ON CONFLICT DO NOTHING
                    """, logger: db.logger)
            }
        }
        report.rows["clients"] = book.clients.count
        report.rows["client_assets"] = assigned
        if !missingKeys.isEmpty {
            report.skipped.append("ключей VPN без владельца на хабе (хаб их ещё не видел): \(missingKeys.count)")
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
