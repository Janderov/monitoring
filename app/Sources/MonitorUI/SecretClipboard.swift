#if canImport(AppKit)
import AppKit

/// Copies a secret (recovery code, VPN config) so it leaks as little as the
/// clipboard allows: it stays on this Mac (no Universal Clipboard to the
/// iPhone), clipboard managers are asked not to record it, and it is wiped
/// after a minute unless something else was copied since.
enum SecretClipboard {
    static let lifetime: TimeInterval = 60

    /// Markers clipboard managers honour (nspasteboard.org).
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @MainActor
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        _ = pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(text, forType: .string)
        pb.setString("", forType: concealed)
        pb.setString("", forType: transient)
        let mine = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            let pb = NSPasteboard.general
            if pb.changeCount == mine { pb.clearContents() }
        }
    }
}
#endif
