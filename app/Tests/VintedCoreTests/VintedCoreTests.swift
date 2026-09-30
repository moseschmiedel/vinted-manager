import Foundation
import Testing
@testable import VintedCore

private let sample = """
---
id: 0003
status: listed          # planned | listed | reserved | sold | withdrawn
title: SMOG Hemd Slim Fit grau Gr. M  # Vinted title, max ~60 chars
brand: SMOG
material:
price_suggested: 3  # EUR
price_listed: 2,50
vinted_url: https://www.vinted.de/items/1234567890
---

# SMOG Hemd Slim Fit grau Gr. M

![Foto 1](photos/01.jpg)

## Beschreibung

Langarmhemd von SMOG, Größe M.

#herrenhemd #smog

## Preisrecherche

<!-- Comparable Vinted listings used for the suggested price. -->
Median 3 €.

## Notizen

- [x] Material: Baumwolle
- [ ] Foto vom Etikett ergänzen
"""

@Test func parsesFrontmatterAndStripsComments() {
    let doc = ListingDocument.parse(sample)
    #expect(doc.fields["status"] == "listed")
    #expect(doc.fields["title"] == "SMOG Hemd Slim Fit grau Gr. M")
    #expect(doc.fields["material"] == "")
    #expect(doc.body.hasPrefix("\n# SMOG") || doc.body.hasPrefix("# SMOG"))
}

@Test func keepsHashtagsInSections() {
    let doc = ListingDocument.parse(sample)
    #expect(doc.section("Beschreibung") == "Langarmhemd von SMOG, Größe M.\n\n#herrenhemd #smog")
    #expect(doc.section("Preisrecherche") == "Median 3 €.")
}

@Test func itemExposesStatusPricesAndTodos() {
    let item = Item(folder: URL(fileURLWithPath: "/tmp/items/0003-smog"), document: .parse(sample), photos: [])
    #expect(item.id == "0003")
    #expect(item.status == .listed)
    #expect(item.currentPrice == 2.5)
    #expect(item.vintedURL?.absoluteString == "https://www.vinted.de/items/1234567890")
    #expect(item.openTodos == ["Foto vom Etikett ergänzen"])
}

@Test func documentWithoutFrontmatterIsAllBody() {
    let doc = ListingDocument.parse("# Just text")
    #expect(doc.fields.isEmpty)
    #expect(doc.body == "# Just text")
}

@Test func slugifiesGroupNames() {
    #expect(VintedRepository.slug("Blaue Jacke, Gr. M") == "blaue-jacke-gr-m")
    #expect(VintedRepository.slug("!!!") == "item")
}

@Test func loadsItemsFromARepository() throws {
    let repo = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let items = try repo.loadItems()
    #expect(items.count == 2)
    #expect(items.allSatisfy { !$0.title.isEmpty && !$0.photos.isEmpty })
}

// MARK: - Writing (on a temporary repository with two sample items)

private func temporaryRepository() throws -> VintedRepository {
    let real = try #require(VintedRepository.locate(from: URL(fileURLWithPath: #filePath)))
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("vinted-test-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for part in ["vinted", "templates", "inbox"] {
        try fm.copyItem(at: real.root.appendingPathComponent(part), to: root.appendingPathComponent(part))
    }
    // Share the real Rust crate (and its build cache) instead of copying cli/target.
    try fm.createSymbolicLink(at: root.appendingPathComponent("cli"), withDestinationURL: real.root.appendingPathComponent("cli"))
    for (id, slug, title) in [("0001", "blaue-jacke", "Blaue Jacke Gr. M"), ("0002", "graue-hose", "Graue Hose Gr. L")] {
        let folder = root.appendingPathComponent("items/\(id)-\(slug)")
        try fm.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folder.appendingPathComponent("photos/01.jpg"))
        try """
        ---
        id: \(id)
        status: planned
        title: \(title)
        size:
        price_suggested: 5
        ---

        # \(title)

        ## Notizen

        - [ ] TODO: Etikett fotografieren
        """.write(to: folder.appendingPathComponent("listing.md"), atomically: true, encoding: .utf8)
    }
    return VintedRepository(root: root)
}

@Test func importsPhotosIntoGroupFolder() throws {
    let repo = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let photo = try #require(try repo.loadItems().first?.photos.first)

    try repo.importPhotos([photo, photo], groupName: "Blaue Jacke")
    let groups = repo.inboxGroups()
    #expect(groups.first(where: { $0.id == "blaue-jacke" })?.photos.count == 2)
}

@Test func setsStatusThroughTheCLI() async throws {
    let repo = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let item = try #require(try repo.loadItems().first)

    try await VintedCLI(repository: repo).setStatus(itemID: item.id, to: .sold, price: "3,50")
    let updated = try #require(try repo.loadItems().first)
    #expect(updated.status == .sold)
    #expect(updated.price("price_sold") == 3.5)
    #expect(!updated.text("sold_at").isEmpty)
    #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("INVENTORY.md").path))
}

@Test func numbersTodosLikeTheCLIAndGuessesTheirField() {
    let item = Item(folder: URL(fileURLWithPath: "/tmp/items/0003-smog"), document: .parse(sample), photos: [])
    #expect(item.todos.map(\.number) == [1, 2])
    #expect(item.todos.map(\.isDone) == [true, false])
    #expect(item.todos[0].field == .material)
    #expect(item.todos[1].field == .photos)
    let size = Todo(itemID: "1", number: 1, text: "TODO: Größe am Etikett prüfen.", isDone: false)
    #expect(size.displayText == "Größe am Etikett prüfen.")
    #expect(size.field == .size)
    #expect(Todo(itemID: "1", number: 1, text: "Tipp: Bündelrabatt aktivieren", isDone: false).field == .notes)
}

@Test func parsesQuestionsAndSuggestionsFromTheAgent() {
    let notes = """
    ---
    id: 0016
    ---

    ## Notizen

    - [ ] QUESTION(material): Welches Material? | Wolle | Polyester
    - [x] QUESTION: Gürtel abnehmbar? → Antwort: ja
    - [ ] SUGGEST(price_listed=5): kaum Favoriten
    - [ ] SUGGEST(description): kürzer
      > Neu.
      >
      > #mantel
    - [ ] TODO: abbürsten
    """
    let todos = Item(folder: URL(fileURLWithPath: "/tmp/items/0016-mantel"), document: .parse(notes), photos: []).todos
    #expect(todos.map(\.number) == [1, 2, 3, 4, 5])
    #expect(todos[0].kind == .question(field: "material", options: ["Wolle", "Polyester"]))
    #expect(todos[0].displayText == "Welches Material?")
    #expect(todos[0].field == .material)
    #expect(todos[1].kind == .question(field: nil, options: []))
    #expect(todos[1].outcome == "Antwort: ja")
    #expect(todos[2].kind == .suggestion(key: "price_listed", value: "5"))
    #expect(todos[2].field == .price)
    #expect(todos[3].kind == .suggestion(key: "description", value: nil))
    #expect(todos[3].proposedText == "Neu.\n\n#mantel")
    #expect(todos[4].kind == .task && !todos[4].isFromAgent)
}

@Test func resolvesAgentTodosThroughTheCLI() async throws {
    let repo = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let cli = VintedCLI(repository: repo)
    var item = try #require(try repo.loadItems().first)
    try await cli.run(["todo", item.id, "--add", "QUESTION(material): Welches Material?"])
    try await cli.run(["todo", item.id, "--add", "SUGGEST(price_suggested=7): Vergleichsangebote"])
    item = try #require(try repo.loadItems().first)
    let question = try #require(item.todos.first { $0.key == "material" })
    try await cli.answer(question, with: "Baumwolle")
    item = try #require(try repo.loadItems().first)
    #expect(item.text("material") == "Baumwolle")
    let suggestion = try #require(item.todos.first { $0.key == "price_suggested" })
    try await cli.accept(suggestion, value: "6")
    item = try #require(try repo.loadItems().first)
    #expect(item.price("price_suggested") == 6)
    let resolved = item.todos.filter(\.isFromAgent).allSatisfy(\.isDone)
    #expect(resolved)
}

@Test func togglesTodosThroughTheCLI() async throws {
    let repo = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    var item = try #require(try repo.loadItems().first)
    let cli = VintedCLI(repository: repo)
    try await cli.set(itemID: item.id, ["size": "M"])
    item = try #require(try repo.loadItems().first)
    #expect(item.text("size") == "M")
    guard let todo = item.todos.first else { return }
    try await cli.setTodo(todo, done: !todo.isDone)
    #expect(try repo.loadItems().first?.todos.first?.isDone == !todo.isDone)
}

@Test func sumsWalletsPerOwner() {
    func item(_ id: String, _ meta: String) -> Item {
        Item(folder: URL(fileURLWithPath: "/tmp/items/\(id)-x"), document: .parse("---\nid: \(id)\n\(meta)\n---\n"), photos: [])
    }
    let wallets = Wallet.wallets(for: [
        item("0001", "status: sold\nowner: Anna\nprice_sold: 4"),
        item("0002", "status: sold\nowner: Anna\nprice_sold: 2,50"),
        item("0003", "status: listed\nowner: ben\nprice_listed: 6"),
        item("0004", "status: planned\nprice_suggested: 3"),
    ])
    #expect(wallets.map(\.owner) == ["Anna", "ben", ""])
    #expect(wallets[0].revenue == 6.5 && wallets[0].soldCount == 2)
    #expect(wallets[1].asking == 6 && wallets[1].activeCount == 1)
    #expect(wallets[2].suggested == 3 && wallets[2].plannedCount == 1)
}

@Test func assignsSeveralItemsInOneCall() async throws {
    let repo = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let ids = try repo.loadItems().map(\.id)
    #expect(ids.count == 2)
    try await VintedCLI(repository: repo).set(itemIDs: ids, ["owner": "Anna"])
    #expect(try repo.loadItems().allSatisfy { $0.owner == "Anna" })
    let inventory = try String(contentsOf: repo.root.appendingPathComponent("INVENTORY.md"), encoding: .utf8)
    #expect(inventory.contains("| Anna |"))
}
