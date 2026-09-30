import AppKit
import SwiftUI
import Observation
import VintedCore

/// How the item board shows cards.
enum BoardStyle: String, CaseIterable, Identifiable {
    case gallery, compact
    var id: String { rawValue }
}

/// Tabs of the to-do sidebar.
enum SidebarTab: String, CaseIterable, Identifiable {
    case todos, runs, done
    var id: String { rawValue }
}

/// Pages pushed on top of the dashboard.
enum Route: Hashable {
    case item(Item.ID, focus: ItemField? = nil)
    case job(AgentJob.ID)
}

@MainActor
@Observable
final class AppStore {
    private(set) var repository: VintedRepository?
    private(set) var items: [Item] = []
    private(set) var inbox: [InboxGroup] = []
    private(set) var isWorking = false
    var autoClusterOnImport: Bool = UserDefaults.standard.object(forKey: "autoClusterOnImport") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoClusterOnImport, forKey: "autoClusterOnImport") }
    }
    var path: [Route] = []
    /// Wallet whose items the dashboard shows; nil shows everyone, "" the unassigned items.
    var ownerFilter: String? { didSet { if ownerFilter != oldValue { selection = [] } } }
    /// Kanban cards selected for a batch action (⌘-click).
    var selection: Set<Item.ID> = []
    /// People added in this session before any item was assigned to them.
    private var newPeople: Set<String> = []
    var showsSidebar: Bool = UserDefaults.standard.object(forKey: "showsSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: "showsSidebar") }
    }
    var sidebarTab: SidebarTab = .todos
    var boardStyle: BoardStyle = BoardStyle(rawValue: UserDefaults.standard.string(forKey: "boardStyle") ?? "") ?? .gallery {
        didSet { UserDefaults.standard.set(boardStyle.rawValue, forKey: "boardStyle") }
    }
    var errorMessage: String?

    var usesAutomaticGrouping: Bool { autoClusterOnImport && agents.preferredKind != nil }

    let agents = AgentStore()

    /// Kanban moves shown right away while `vinted status` is still writing them.
    private var pendingMoves: [Item.ID: [String: String]] = [:]
    private var watcher: DirectoryWatcher?
    private static let repositoryKey = "repositoryPath"

    init() {
        let candidates = [
            UserDefaults.standard.string(forKey: Self.repositoryKey).map { URL(fileURLWithPath: $0) },
            Bundle.main.bundleURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let repository = VintedRepository.locate(from: candidate) {
                open(repository)
                break
            }
        }
    }

    // MARK: Loading

    func open(_ repository: VintedRepository) {
        guard !isWorking, !agents.jobs.contains(where: { $0.state == .running }) else {
            errorMessage = "Wait for changes to finish and stop active agent runs before switching libraries."
            return
        }
        self.repository = repository
        path = []
        sidebarTab = .todos
        selection = []
        ownerFilter = nil
        newPeople = []
        agents.use(repository)
        UserDefaults.standard.set(repository.root.path, forKey: Self.repositoryKey)
        watcher = DirectoryWatcher(paths: [repository.itemsDirectory.path, repository.inboxDirectory.path]) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your selling library (the folder with items/, inbox/ and templates/)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let repository = VintedRepository.locate(from: url) {
            open(repository)
        } else {
            errorMessage = "\(url.path) isn't a selling library. Choose a library or create a new one."
        }
    }

    func createLibrary() {
        let panel = NSSavePanel()
        panel.title = "Create Selling Library"
        panel.nameFieldStringValue = "My Vinted Library"
        panel.message = "Choose where to keep your listings and photos. Use a new or empty folder."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let root = panel.url else { return }
        Task {
            do { open(try await VintedCLI.createLibrary(at: root)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func reload() {
        guard let repository else { return }
        do {
            items = try repository.loadItems().map { item in
                pendingMoves[item.id].map(item.updating) ?? item
            }
            inbox = repository.inboxGroups()
            selection.formIntersection(items.map(\.id))
            path.removeAll { route in
                if case .item(let id, _) = route { return !items.contains { $0.id == id } }
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Queries

    /// Items of the selected wallet (all items without a filter).
    var visibleItems: [Item] {
        guard let ownerFilter else { return items }
        return items.filter { $0.owner == ownerFilter }
    }

    func items(_ status: ItemStatus) -> [Item] { visibleItems.filter { $0.status == status } }

    var wallets: [Wallet] { Wallet.wallets(for: items) }

    /// Everyone who owns an item, alphabetical.
    var people: [String] {
        Set(items.map(\.owner).filter { !$0.isEmpty }).union(newPeople)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func item(_ id: Item.ID) -> Item? { items.first { $0.id == id } }

    var inboxPhotoCount: Int { inbox.reduce(0) { $0 + $1.photos.count } }

    /// To-dos of items that are still being sold (sold and withdrawn items are done with).
    var todos: [Todo] {
        visibleItems.filter { $0.status != .sold && $0.status != .withdrawn }.flatMap(\.todos)
    }

    /// Open to-dos of items still being sold; the sidebar's badge.
    var openTodoCount: Int { todos.filter { !$0.isDone }.count }

    /// The item page on screen, if any; the sidebar then shows only its to-dos.
    var currentItemID: Item.ID? {
        if case .item(let id, _) = path.last { return id }
        return nil
    }

    /// A running agent job that works on this item (price check, revising with answers).
    func runningJob(for itemID: Item.ID) -> AgentJob? {
        agents.jobs.first { $0.state == .running && $0.task.itemID == itemID }
    }

    func total(_ statuses: Set<ItemStatus>) -> Double {
        visibleItems.filter { $0.status.map(statuses.contains) ?? false }.compactMap(\.currentPrice).reduce(0, +)
    }

    // MARK: Actions

    func importPhotos(_ urls: [URL], asOneItem: Bool, name: String) {
        guard let repository else { return }
        do {
            let group = !usesAutomaticGrouping && asOneItem && urls.count > 1
                ? (name.isEmpty ? Self.defaultGroupName() : name) : nil
            let imported = try repository.importPhotos(urls, groupName: group)
            reload()
            if usesAutomaticGrouping && !imported.isEmpty {
                let photos = imported.map { "inbox/\($0.lastPathComponent)" }
                Task {
                    if agents.preferredKind == nil { await agents.refreshStatus() }
                    if agents.start(.clusterPhotos(photos), repository: repository) == nil {
                        errorMessage = "Photos were added individually. Automatic grouping needs a ready agent; check Settings › Agents."
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func groupLoosePhotos() {
        guard let repository else { return }
        let photos = inbox.filter { !$0.isFolder }.map { "inbox/\($0.id)" }
        guard !photos.isEmpty else { return }
        if agents.start(.clusterPhotos(photos), repository: repository) == nil {
            errorMessage = "Automatic grouping needs a ready agent; check Settings › Agents."
        }
    }

    func setStatus(_ item: Item, to status: ItemStatus, price: String, url: String) async {
        await write { try await $0.setStatus(itemID: item.id, to: status, price: price, url: url) }
    }

    /// Kanban drop: moves the cards immediately, then records status and a fitting price via the CLI.
    func move(_ itemIDs: [Item.ID], to status: ItemStatus) async {
        guard let repository else { return }
        var writes: [(Item.ID, String)] = []
        withAnimation(.snappy) {
            for id in itemIDs {
                guard let index = items.firstIndex(where: { $0.id == id }), items[index].status != status else { continue }
                let item = items[index]
                let price = status == .planned || status == .withdrawn ? "" : item.defaultPrice(for: status).map(Price.plain) ?? ""
                var change = ["status": status.rawValue]
                if !price.isEmpty { change[status == .sold ? "price_sold" : "price_listed"] = price }
                pendingMoves[id] = change
                items[index] = item.updating(change)
                writes.append((id, price))
            }
        }
        let cli = VintedCLI(repository: repository)
        for (id, price) in writes {
            do {
                try await cli.setStatus(itemID: id, to: status, price: price)
            } catch {
                errorMessage = error.localizedDescription
            }
            pendingMoves[id] = nil
        }
        withAnimation(.snappy) { reload() }
    }

    func move(_ itemID: Item.ID, to status: ItemStatus) async {
        await move([itemID], to: status)
    }

    func setTodo(_ todo: Todo, done: Bool) async {
        await write { try await $0.setTodo(todo, done: done) }
    }

    /// Answers an agent's question; `vinted answer` fills the field it names.
    func answer(_ todo: Todo, with answer: String) async {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        await write { try await $0.answer(todo, with: answer) }
    }

    /// Applies an agent's suggestion, optionally with an edited value.
    func accept(_ todo: Todo, value: String? = nil) async {
        await write { try await $0.accept(todo, value: value) }
    }

    func dismiss(_ todo: Todo) async {
        await write { try await $0.dismiss(todo) }
    }

    /// Assigns items to a person's wallet ("" removes the assignment), in one CLI call.
    func setOwner(_ items: [Item], to owner: String) async {
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = items.filter { $0.owner != owner }.map(\.id)
        guard !ids.isEmpty else { return }
        if !owner.isEmpty { newPeople.insert(owner) }
        await write { try await $0.set(itemIDs: ids, ["owner": owner]) }
    }

    func setOwner(_ item: Item, to owner: String) async {
        await setOwner([item], to: owner)
    }

    var selectedItems: [Item] { items.filter { selection.contains($0.id) } }

    func toggleSelection(_ id: Item.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// The items a card action applies to: the whole selection if the card is part of it.
    func targets(for item: Item) -> [Item] {
        selection.contains(item.id) ? selectedItems : [item]
    }

    func setField(_ item: Item, key: String, value: String) async {
        await write { try await $0.set(itemID: item.id, [key: value]) }
    }

    private func write(_ change: (VintedCLI) async throws -> Void) async {
        guard let repository else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await change(VintedCLI(repository: repository))
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ route: Route) {
        if path.last != route { path = [route] }
    }

    /// Starts an agent run in the repository and shows it in the Agent Jobs panel.
    func runAgent(_ task: AgentTask, kind: AgentKind? = nil) {
        guard let repository else { return }
        if agents.start(task, kind: kind, repository: repository) != nil {
            showsSidebar = true
            if task.itemID == nil { sidebarTab = .runs }
        } else {
            errorMessage = "No agent is ready. Install Claude Code or Codex and log in, then check Settings › Agents."
        }
    }

    func draftListing(for group: InboxGroup) {
        guard let repository else { return }
        let base = repository.inboxDirectory.standardizedFileURL.path + "/"
        let photos = group.photos.map { $0.standardizedFileURL.path.replacingOccurrences(of: base, with: "") }
        runAgent(.draftListing(group: group.id, photos: photos))
    }

    func createListing(for group: InboxGroup) {
        guard let repository, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let cli = VintedCLI(repository: repository)
                let output = try await cli.run(["new", VintedRepository.slug(group.id)] + group.photos.map(\.path))
                let listing = repository.root.appendingPathComponent(output)
                let id = listing.deletingLastPathComponent().lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
                try await cli.set(itemID: id, ["title": "Neuer Artikel"])
                try await cli.regenerateIndex()
                reload()
                open(.item(id))
            } catch { errorMessage = error.localizedDescription; reload() }
        }
    }

    static func defaultGroupName() -> String {
        "item-" + Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
    }
}
