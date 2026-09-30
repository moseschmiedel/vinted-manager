import SwiftUI
import VintedCore

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.repository == nil {
                ContentUnavailableView {
                    Label("Your selling library", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a library to keep your listings and photos, or open an existing one. AI assistance is optional.")
                } actions: {
                    Button("New Library…") { store.createLibrary() }
                        .buttonStyle(.borderedProminent)
                    Button("Open Library…") { store.chooseRepository() }
                }
            } else {
                NavigationStack(path: $store.path) {
                    DashboardView()
                        .navigationDestination(for: Route.self) { route in
                            destination(route)
                        }
                }
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if store.showsSidebar {
                        SidebarPanel()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: 0.3), value: store.showsSidebar)
            }
        }
        .toolbar {
            if store.repository != nil {
                ToolbarItem { OwnerFilter() }
                ToolbarSpacer(.fixed)
                if store.path.isEmpty {
                    ToolbarItem {
                        Picker("Board", selection: $store.boardStyle) {
                            Label("Gallery", systemImage: "square.grid.2x2").tag(BoardStyle.gallery)
                            Label("Compact", systemImage: "list.bullet").tag(BoardStyle.compact)
                        }
                        .pickerStyle(.segmented)
                        .help("Photo cards or compact rows")
                    }
                    ToolbarSpacer(.fixed)
                }
                ToolbarItem { SummaryView() }
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button { store.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                }
                ToolbarItem {
                    Button { store.showsSidebar.toggle() } label: {
                        Label("To-dos", systemImage: "checklist")
                    }
                    .badge(store.openTodoCount)
                    .help(store.showsSidebar ? "Hide to-dos and agent runs" : "Show to-dos and agent runs")
                }
            }
        }
        .alert("Something went wrong", isPresented: .constant(store.errorMessage != nil)) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .item(let id, let focus):
            if let item = store.item(id) {
                ItemDetailView(item: item, focus: focus)
            } else {
                ContentUnavailableView("Item not found", systemImage: "tshirt")
            }
        case .job(let id):
            if let job = store.agents.job(id) {
                AgentJobDetailView(job: job)
            } else {
                ContentUnavailableView("Run was cleared", systemImage: "sparkles")
            }
        }
    }
}

/// Inbox, the item board and the wallets on one page; to-dos live in the sidebar.
struct DashboardView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                InboxSection()
                KanbanBoard()
                WalletsSection()
            }
            .padding(20)
        }
        .overlay(alignment: .bottom) {
            if !store.selection.isEmpty { SelectionBar() }
        }
        .animation(.snappy, value: store.selection.isEmpty)
        .navigationTitle("Vinted Manager")
    }
}

/// Everyone, one person, or the unassigned items.
private struct OwnerFilter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let people = store.people
        let hasUnassigned = store.items.contains { $0.owner.isEmpty }
        if people.count <= 4 {
            Picker("Person", selection: $store.ownerFilter) {
                Text("Everyone").tag(String?.none)
                ForEach(people, id: \.self) { Text($0).tag(String?.some($0)) }
                if hasUnassigned && !people.isEmpty { Text("Unassigned").tag(String?.some("")) }
            }
            .pickerStyle(.segmented)
            .help("Show everyone's items or one person's")
        } else {
            Picker("Person", selection: $store.ownerFilter) {
                Label("Everyone", systemImage: "person.2").tag(String?.none)
                Divider()
                ForEach(people, id: \.self) { Text($0).tag(String?.some($0)) }
                if hasUnassigned { Text("Unassigned").tag(String?.some("")) }
            }
            .pickerStyle(.menu)
        }
    }
}

/// Section heading used on the dashboard.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let count {
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

private struct SummaryView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            Label(Price.format(store.total([.listed, .reserved])), systemImage: "tag")
                .help("Asking price of listed and reserved items")
            Label(Price.format(store.total([.sold])), systemImage: "eurosign.circle")
                .help("Revenue from sold items")
        }
        .labelStyle(.titleAndIcon)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

extension ItemStatus {
    var symbol: String {
        switch self {
        case .planned: "square.and.pencil"
        case .listed: "tag"
        case .reserved: "clock"
        case .sold: "checkmark.seal"
        case .withdrawn: "xmark.bin"
        }
    }

    var tint: Color {
        switch self {
        case .planned: .orange
        case .listed: .green
        case .reserved: .yellow
        case .sold: .blue
        case .withdrawn: .gray
        }
    }
}
