import Foundation

/// Splits a migration file into single statements. PostgresNIO sends one
/// statement per query (extended protocol), while migration files hold many,
/// including function bodies in $$ … $$ that contain semicolons themselves.
public enum SQLScript {
    public static func statements(_ sql: String) -> [String] {
        let s = Array(sql.unicodeScalars)
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var i = 0

        func flush() {
            let text = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !isOnlyComments(text) { out.append(text) }
            current = String.UnicodeScalarView()
        }
        func peek(_ k: Int) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }

        while i < s.count {
            let c = s[i]
            // -- comment to the end of the line
            if c == "-" && peek(1) == "-" {
                while i < s.count && s[i] != "\n" { current.append(s[i]); i += 1 }
                continue
            }
            // /* block comment */ (PostgreSQL nests them)
            if c == "/" && peek(1) == "*" {
                var depth = 0
                while i < s.count {
                    if s[i] == "/" && peek(1) == "*" { depth += 1; current.append(s[i]); current.append(s[i + 1]); i += 2; continue }
                    if s[i] == "*" && peek(1) == "/" {
                        depth -= 1; current.append(s[i]); current.append(s[i + 1]); i += 2
                        if depth == 0 { break }
                        continue
                    }
                    current.append(s[i]); i += 1
                }
                continue
            }
            // 'string' and "identifier", with doubled quotes inside
            if c == "'" || c == "\"" {
                current.append(c); i += 1
                while i < s.count {
                    current.append(s[i])
                    if s[i] == c {
                        if peek(1) == c { current.append(s[i + 1]); i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }
            // $tag$ … $tag$
            if c == "$", let tag = dollarTag(s, at: i) {
                for t in tag.unicodeScalars { current.append(t) }
                i += tag.unicodeScalars.count
                let closing = Array(tag.unicodeScalars)
                while i < s.count {
                    if s[i] == "$" && i + closing.count <= s.count && Array(s[i..<(i + closing.count)]) == closing {
                        for t in closing { current.append(t) }
                        i += closing.count
                        break
                    }
                    current.append(s[i]); i += 1
                }
                continue
            }
            if c == ";" {
                current.append(c); i += 1
                flush()
                continue
            }
            current.append(c); i += 1
        }
        flush()
        return out
    }

    /// `$$` or `$name$` starting at `i`; not a positional parameter like `$1`.
    static func dollarTag(_ s: [Unicode.Scalar], at i: Int) -> String? {
        var j = i + 1
        var tag = "$"
        while j < s.count {
            let c = s[j]
            if c == "$" { return tag + "$" }
            let isStart = j == i + 1
            let ok = CharacterSet.letters.contains(c) || c == "_" || (!isStart && CharacterSet.decimalDigits.contains(c))
            guard ok else { return nil }
            tag.unicodeScalars.append(c)
            j += 1
        }
        return nil
    }

    static func isOnlyComments(_ text: String) -> Bool {
        statementsStrippingComments(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func statementsStrippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let t = line.drop { $0 == " " || $0 == "\t" }
                return t.hasPrefix("--") ? "" : line
            }
            .joined(separator: "\n")
    }
}
