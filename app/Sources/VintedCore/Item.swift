import Foundation

public enum ItemStatus: String, CaseIterable, Sendable, Identifiable {
    case planned, listed, reserved, sold, withdrawn

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .planned: "Planned"
        case .listed: "Listed"
        case .reserved: "Reserved"
        case .sold: "Sold"
        case .withdrawn: "Withdrawn"
        }
    }
}

/// One folder under `items/`.
public struct Item: Identifiable, Hashable, Sendable {
    public let id: String
    public let folder: URL
    public private(set) var fields: [String: String]
    public let description: String
    public let priceResearch: String
    public let notes: String
    public let photos: [URL]

    public init(folder: URL, document: ListingDocument, photos: [URL]) {
        self.folder = folder
        self.fields = document.fields
        self.id = document.fields["id"] ?? String(folder.lastPathComponent.prefix(4))
        self.description = document.section("Beschreibung")
        self.priceResearch = document.section("Preisrecherche")
        self.notes = document.section("Notizen")
        self.photos = photos
    }

    /// A copy with some frontmatter fields replaced, e.g. to show a status change before the CLI has written it.
    public func updating(_ changes: [String: String]) -> Item {
        var copy = self
        copy.fields.merge(changes) { $1 }
        return copy
    }

    public var listingURL: URL { folder.appendingPathComponent("listing.md") }
    public var title: String { fields["title"].nonEmpty ?? folder.lastPathComponent }
    public var status: ItemStatus? { fields["status"].flatMap(ItemStatus.init(rawValue:)) }
    /// Person who gets the money for this item; empty if unassigned.
    public var owner: String { text("owner").trimmingCharacters(in: .whitespaces) }

    public func text(_ key: String) -> String { fields[key] ?? "" }
    public func price(_ key: String) -> Double? { fields[key].flatMap(Price.parse) }

    /// The price that matters for the item's current status.
    public var currentPrice: Double? {
        switch status {
        case .sold: price("price_sold") ?? price("price_listed")
        case .listed, .reserved: price("price_listed") ?? price("price_suggested")
        default: price("price_suggested")
        }
    }

    public var vintedURL: URL? { fields["vinted_url"].nonEmpty.flatMap(URL.init(string:)) }

    /// `- [ ]` / `- [x]` lines from the Notizen section, numbered like `vinted todo`,
    /// with the indented `> ` lines below each one (e.g. a proposed description).
    public var todos: [Todo] {
        var result: [Todo] = []
        var quote: [String] = []
        var inTodo = false
        func flush() {
            if !quote.isEmpty, let last = result.popLast() { result.append(last.with(quote: quote)) }
            quote = []
        }
        for rawLine in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inTodo, rawLine.first == " " || rawLine.first == "\t", line.hasPrefix(">") {
                let rest = line.dropFirst()
                quote.append(String(rest.hasPrefix(" ") ? rest.dropFirst() : rest))
                continue
            }
            flush()
            let done: Bool
            switch line.prefix(5) {
            case "- [ ]": done = false
            case "- [x]", "- [X]": done = true
            default: inTodo = false; continue
            }
            let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            result.append(Todo(itemID: id, number: result.count + 1, text: text, isDone: done))
            inTodo = true
        }
        flush()
        return result
    }

    /// Unchecked `- [ ]` lines from the Notizen section.
    public var openTodos: [String] { todos.filter { !$0.isDone }.map(\.text) }

    /// The price to record when the item moves to `status` (e.g. on the kanban board).
    public func defaultPrice(for status: ItemStatus) -> Double? {
        switch status {
        case .sold: price("price_sold") ?? price("price_listed")
        case .planned, .withdrawn: price("price_suggested")
        default: price("price_listed") ?? price("price_suggested")
        }
    }
}

/// Money per person: earned (sold), still on Vinted (listed/reserved) and not yet listed (planned).
public struct Wallet: Identifiable, Hashable, Sendable {
    /// Empty for items nobody is assigned to.
    public let owner: String
    public var soldCount = 0
    public var revenue = 0.0
    public var activeCount = 0
    public var asking = 0.0
    public var plannedCount = 0
    public var suggested = 0.0

    public var id: String { owner }

    public init(owner: String) { self.owner = owner }

    /// One wallet per owner, alphabetical, with unassigned items last.
    public static func wallets(for items: [Item]) -> [Wallet] {
        var wallets: [String: Wallet] = [:]
        for item in items {
            var wallet = wallets[item.owner] ?? Wallet(owner: item.owner)
            switch item.status {
            case .sold:
                wallet.soldCount += 1
                wallet.revenue += item.currentPrice ?? 0
            case .listed, .reserved:
                wallet.activeCount += 1
                wallet.asking += item.currentPrice ?? 0
            case .planned:
                wallet.plannedCount += 1
                wallet.suggested += item.currentPrice ?? 0
            case .withdrawn, nil:
                break
            }
            wallets[item.owner] = wallet
        }
        return wallets.values.sorted {
            ($0.owner.isEmpty ? 1 : 0, $0.owner.lowercased()) < ($1.owner.isEmpty ? 1 : 0, $1.owner.lowercased())
        }
    }
}

/// One checkbox line in an item's Notizen. Agents write questions and suggestions as
/// `QUESTION(field): …` and `SUGGEST(key=value): …` (see AGENTS.md); the user resolves them later.
public struct Todo: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case task
        /// `field` is the frontmatter key the answer fills; `options` are quick answers.
        case question(field: String?, options: [String])
        /// `value` is nil for a description suggestion, whose text is in `quote`.
        case suggestion(key: String, value: String?)
    }

    public let itemID: String
    /// 1-based position among the item's checkbox lines, as used by `vinted todo`.
    public let number: Int
    public let text: String
    public let isDone: Bool
    /// Indented `> ` lines below the checkbox, e.g. a proposed description.
    public private(set) var quote: [String] = []

    public init(itemID: String, number: Int, text: String, isDone: Bool) {
        self.itemID = itemID
        self.number = number
        self.text = text
        self.isDone = isDone
    }

    func with(quote: [String]) -> Todo {
        var copy = self
        copy.quote = quote
        return copy
    }

    public var id: String { "\(itemID)#\(number)" }

    public var kind: Kind { parsed.kind }

    /// The question, reason or task, without prefix, options and outcome.
    public var displayText: String { parsed.text }

    /// How a resolved question or suggestion ended (`Antwort: …`, `angenommen`, `abgelehnt`).
    public var outcome: String? {
        text.range(of: " → ").map { String(text[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
    }

    /// Proposed text of a description suggestion.
    public var proposedText: String { quote.joined(separator: "\n") }

    public var isFromAgent: Bool {
        if case .task = kind { return false }
        return true
    }

    private var parsed: (kind: Kind, text: String) {
        let line = text.components(separatedBy: " → ")[0].trimmingCharacters(in: .whitespaces)
        guard let colon = line.firstIndex(of: ":") else { return (.task, line) }
        let prefix = line[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        var name = prefix
        var argument: String?
        if let open = prefix.firstIndex(of: "("), prefix.hasSuffix(")") {
            name = String(prefix[..<open])
            argument = String(prefix[prefix.index(after: open)..<prefix.index(before: prefix.endIndex)])
                .trimmingCharacters(in: .whitespaces)
        }
        switch name {
        case "QUESTION":
            let parts = rest.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            return (.question(field: argument.flatMap { $0.isEmpty ? nil : $0 }, options: parts.dropFirst().filter { !$0.isEmpty }),
                    parts[0])
        case "SUGGEST":
            guard let argument, !argument.isEmpty else { return (.task, line) }
            let pair = argument.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return (.suggestion(key: pair[0], value: pair.count > 1 ? pair[1] : nil), rest)
        case "TODO":
            return (.task, rest)
        default:
            return (.task, line)
        }
    }

    /// Frontmatter key (or `description`) this to-do fills or changes, if it names one.
    public var key: String? {
        switch kind {
        case .task: nil
        case .question(let field, _): field
        case .suggestion(let key, _): key
        }
    }

    /// The part of the item the to-do is about: the named key, or a guess from its first keyword.
    public var field: ItemField {
        if let key, let field = ItemField(key: key) { return field }
        let lower = displayText.lowercased()
        let keywords: [(ItemField, [String])] = [
            (.size, ["größe", "groesse", "size", "kragenweite", "länge", "maße"]),
            (.material, ["material", "stoff", "pflege"]),
            (.brand, ["marke", "brand", "logo"]),
            (.colors, ["farbe", "color"]),
            (.condition, ["zustand", "fleck", "naht", "loch", "hygien"]),
            (.category, ["kategorie"]),
            (.price, ["preis", "price", "€"]),
            (.photos, ["foto", "bild"]),
            (.title, ["titel"]),
            (.description, ["beschreibung"]),
        ]
        let hits = keywords.compactMap { field, words in
            words.compactMap { lower.range(of: $0)?.lowerBound }.min().map { (field, $0) }
        }
        return hits.min { $0.1 < $1.1 }?.0 ?? .notes
    }
}

/// Sections of an item that a to-do can point to.
public enum ItemField: String, CaseIterable, Hashable, Sendable {
    case photos, title, category, brand, size, condition, colors, material, price, description, notes

    /// The field a to-do's key refers to (`price_suggested` and `price_listed` are the price).
    public init?(key: String) {
        switch key {
        case "price_suggested", "price_listed", "price_sold", "price": self = .price
        default: self.init(rawValue: key)
        }
    }

    /// Frontmatter key that `vinted set` edits, if the field is a plain value.
    public var key: String? {
        switch self {
        case .title, .category, .brand, .size, .condition, .colors, .material: rawValue
        case .photos, .price, .description, .notes: nil
        }
    }
}

public enum Price {
    /// Accepts `4`, `2.50` and German `2,50`.
    public static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// `4`, `2.5`: the form `vinted status --price` stores.
    public static func plain(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    public static func format(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE")))
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
