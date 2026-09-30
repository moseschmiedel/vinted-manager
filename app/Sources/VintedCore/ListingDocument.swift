import Foundation

/// A parsed `listing.md`: flat `key: value` frontmatter plus a Markdown body.
///
/// Mirrors `listing::parse` in the Rust CLI (`cli/src/listing.rs`) so both sides agree on the format.
public struct ListingDocument: Sendable, Equatable {
    public var fields: [String: String]
    public var body: String

    public init(fields: [String: String] = [:], body: String = "") {
        self.fields = fields
        self.body = body
    }

    public static func parse(_ text: String) -> ListingDocument {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") else { return ListingDocument(body: text) }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return ListingDocument(body: text) }

        var fields: [String: String] = [:]
        for rawLine in rest[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip trailing `# comments`, like the Python parser does.
            var line = String(rawLine)
            if let comment = line.range(of: " #") { line = String(line[..<comment.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            fields[key] = value
        }

        var body = rest[end.upperBound...]
        if body.hasPrefix("\n") { body = body.dropFirst() }
        return ListingDocument(fields: fields, body: String(body))
    }

    /// Text under `## heading` up to the next `## ` heading, without HTML comments.
    public func section(_ heading: String) -> String {
        var collecting = false
        var lines: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if collecting { break }
                collecting = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading
                continue
            }
            if collecting { lines.append(line) }
        }
        let text = lines.joined(separator: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
