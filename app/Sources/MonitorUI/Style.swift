#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

// One vocabulary for status across the app (docs/design-context.md):
// color always comes with a symbol or a word, never alone.

extension ServerStatus.Level {
    public var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .gray
        }
    }

    /// Text color that stays readable on a light background.
    public var textColor: Color {
        switch self {
        case .warning: return .orange
        case .critical: return .red
        case .ok: return .green
        case .unknown: return .secondary
        }
    }

    public var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    public var label: String {
        switch self {
        case .ok: return "В норме"
        case .warning: return "Предупреждение"
        case .critical: return "Критично"
        case .unknown: return "Нет данных"
        }
    }
}

extension Severity {
    var level: ServerStatus.Level { self == .critical ? .critical : .warning }
}

/// Small colored dot with an accessibility label.
struct StatusDot: View {
    var level: ServerStatus.Level
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: size, height: size)
            .accessibilityLabel(level.label)
    }
}

/// "● Предупреждение" next to a title.
struct StatusBadge: View {
    var level: ServerStatus.Level

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(level: level)
            Text(level.label).font(.callout.weight(.medium)).foregroundStyle(level.textColor)
        }
    }
}

/// A one-line warning or error strip under a header.
struct AlertStrip: View {
    var level: ServerStatus.Level
    var text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: level.symbol).foregroundStyle(level.textColor)
            Text(text)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(level.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(level.color.opacity(0.35)))
    }
}

/// Label above a value, as in the header facts row.
struct Fact: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// Shown instead of a table when there is nothing to show, with the reason.
struct EmptyNote: View {
    var title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
    }
}

enum Fmt {
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static func bytes(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .binary)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec.isFinite ? max(0, bytesPerSec) : 0), countStyle: .binary) + "/с"
    }

    static func ms(_ v: Double) -> String { String(format: "%.0f мс", v) }

    /// "12 д 4 ч", "3 ч 10 мин", "4 мин".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d) д \(h) ч" : "\(d) д" }
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return "\(m) мин" }
        return "\(s) с"
    }

    static func since(_ date: Date, now: Date = Date()) -> String { duration(now.timeIntervalSince(date)) }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    static func days(until date: Date) -> Int {
        Int((date.timeIntervalSinceNow / 86400).rounded(.down))
    }
}

extension ServerStatus {
    /// The number shown next to the name in compact lists.
    var keyFigure: String {
        if let a = alerts.max(by: { $0.severity < $1.severity }) { return a.message }
        guard let s = snapshot else { return error == nil ? "ждём данные" : "нет ответа" }
        if s.vpnActiveClients > 0 { return "VPN \(s.vpnActiveClients) · CPU \(Fmt.percent(s.cpu.usagePercent))" }
        return "CPU \(Fmt.percent(s.cpu.usagePercent))"
    }

    var country: Country? { Country.detect(server) }
}
#endif
