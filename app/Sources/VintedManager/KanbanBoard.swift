import AppKit
import SwiftUI
import VintedCore

/// Items by status, as photo cards (gallery) or compact rows. Drag a card to another column
/// to change its status; ⌘-click cards to select several and act on them together.
struct KanbanBoard: View {
    @Environment(AppStore.self) private var store

    private var columns: [ItemStatus] {
        let main: [ItemStatus] = [.planned, .listed, .reserved, .sold]
        return store.items(.withdrawn).isEmpty ? main : main + [.withdrawn]
    }

    private var filterTitle: String {
        switch store.ownerFilter {
        case nil: "Items"
        case "": "Items · Unassigned"
        case let owner?: "Items · \(owner)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: filterTitle, count: store.visibleItems.count)
            WeightedHStack(spacing: 16) {
                ForEach(columns) { status in
                    KanbanColumn(status: status, cardsPerRow: cardsPerRow(status))
                        .layoutValue(key: ColumnWeight.self, value: CGFloat(cardsPerRow(status)))
                }
            }
        }
    }

    /// In the gallery, busy columns get more room (up to three cards side by side).
    private func cardsPerRow(_ status: ItemStatus) -> Int {
        guard store.boardStyle == .gallery else { return 1 }
        let count = store.items(status).count
        return min(3, max(1, Int((Double(count) / 3).rounded(.up))))
    }
}

private struct ColumnWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// Columns side by side, each as wide as its share of the weights.
private struct WeightedHStack: Layout {
    var spacing: CGFloat

    private func widths(_ total: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let weights = subviews.map { $0[ColumnWeight.self] }
        let free = max(0, total - spacing * CGFloat(max(0, subviews.count - 1)))
        let sum = max(1, weights.reduce(0, +))
        return weights.map { free * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let height = zip(subviews, widths(width, subviews))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }
}

private struct KanbanColumn: View {
    @Environment(AppStore.self) private var store
    let status: ItemStatus
    let cardsPerRow: Int
    @State private var isTargeted = false

    var body: some View {
        let items = store.items(status)
        let gallery = store.boardStyle == .gallery
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(status.tint).frame(width: 8, height: 8)
                Text(status.label).font(.headline)
                Text("\(items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if !store.selection.isEmpty && !items.isEmpty {
                    let allSelected = items.allSatisfy { store.selection.contains($0.id) }
                    Button(allSelected ? "Deselect all" : "Select all") { selectAll(items, !allSelected) }
                        .buttonStyle(.borderless).font(.caption)
                } else {
                    let total = items.compactMap(\.currentPrice).reduce(0, +)
                    if total > 0 {
                        Text(Price.format(total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 4)
            .contextMenu {
                Button("Select All \(status.label)") { selectAll(items, true) }.disabled(items.isEmpty)
            }
            if gallery {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cardsPerRow), spacing: 12) {
                    ForEach(items) { PhotoCard(item: $0) }
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items) { ItemCard(item: $0) }
                }
            }
            if items.isEmpty {
                Text(isTargeted ? "Drop to mark as \(status.label.lowercased())" : "Drop cards here")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: gallery ? 160 : 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                            .foregroundStyle(.secondary.opacity(0.5))
                    )
            }
        }
        .padding(gallery ? 0 : 8)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isTargeted ? status.tint.opacity(0.14) : gallery ? .clear : Color.primary.opacity(0.04))
                .padding(gallery ? -6 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isTargeted ? status.tint.opacity(0.6) : .clear, lineWidth: 2)
                .padding(gallery ? -6 : 0)
        )
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let item = store.item(id) else { return false }
            Task { await store.move(store.targets(for: item).map(\.id), to: status) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func selectAll(_ items: [Item], _ select: Bool) {
        let ids = Set(items.map(\.id))
        if select { store.selection.formUnion(ids) } else { store.selection.subtract(ids) }
    }
}

/// Gallery card: the photo is the card; title and price sit on a gradient, size and
/// open questions/suggestions float on top as small glass tags.
private struct PhotoCard: View {
    @Environment(AppStore.self) private var store
    let item: Item
    @State private var isHovered = false

    var body: some View {
        let isSelected = store.selection.contains(item.id)
        let job = store.runningJob(for: item.id)
        Color.clear
            .aspectRatio(4 / 5, contentMode: .fit)
            .overlay {
                if let photo = item.photos.first {
                    Photo(url: photo, maxSize: 280)
                        .saturation(item.status == .sold ? 0.4 : 1)
                } else {
                    Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").font(.title).foregroundStyle(.secondary))
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(Price.format(item.currentPrice)).font(.headline.monospacedDigit())
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .topLeading) { CardTags(item: item).padding(8) }
            .overlay(alignment: .topTrailing) {
                Group {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, Color.accentColor)
                    } else if !item.owner.isEmpty {
                        OwnerAvatar(owner: item.owner, size: 22).help("Belongs to \(item.owner)")
                    }
                }
                .padding(8)
            }
            .overlay {
                if item.status == .sold {
                    Text("SOLD")
                        .font(.callout.weight(.heavy)).kerning(2)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.blue.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(-12))
                        .offset(y: -16)
                }
            }
            .overlay(alignment: .bottom) {
                if let job {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(job.currentStep).lineLimit(1)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.horizontal, 8)
                    .padding(.bottom, 62)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : job != nil ? Color.purple : .white.opacity(isHovered ? 0.8 : 0),
                                  lineWidth: isSelected || job != nil ? 3 : 2)
            )
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.1), radius: isHovered ? 10 : 3, y: isHovered ? 5 : 1)
            .scaleEffect(isHovered ? 1.015 : 1)
            .animation(.snappy(duration: 0.18), value: isHovered)
            .modifier(CardInteractions(item: item, isHovered: $isHovered))
    }
}

/// Size, open questions, suggestions and to-dos of an item, as small glass capsules.
private struct CardTags: View {
    let item: Item

    var body: some View {
        let open = item.todos.filter { !$0.isDone }
        let questions = open.filter { if case .question = $0.kind { true } else { false } }.count
        let suggestions = open.filter { if case .suggestion = $0.kind { true } else { false } }.count
        let tasks = open.count - questions - suggestions
        let size = item.text("size")
        var tags: [(Text, String)] = []
        if !size.isEmpty { tags.append((Text("Gr. \(size)"), "Size")) }
        if suggestions > 0 {
            tags.append((Text("\(Image(systemName: "sparkles")) \(suggestions)").foregroundStyle(.purple),
                         "\(suggestions) suggestion(s) from your agent"))
        }
        if questions > 0 {
            tags.append((Text("\(Image(systemName: "questionmark.bubble")) \(questions)").foregroundStyle(.blue),
                         "\(questions) question(s) from your agent"))
        }
        if tasks > 0 {
            tags.append((Text("\(Image(systemName: "checklist")) \(tasks)").foregroundStyle(.orange), "\(tasks) open to-do(s)"))
        }
        // One row if it fits next to the avatar, otherwise stacked.
        return GlassEffectContainer(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { ForEach(tags.indices, id: \.self) { tag(tags[$0].0, help: tags[$0].1) } }
                VStack(alignment: .leading, spacing: 4) { ForEach(tags.indices, id: \.self) { tag(tags[$0].0, help: tags[$0].1) } }
            }
        }
        .padding(.trailing, 30)
    }

    private func tag(_ text: Text, help: String) -> some View {
        text
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
            .help(help)
    }
}

/// Compact card: thumbnail and text in a row.
private struct ItemCard: View {
    @Environment(AppStore.self) private var store
    let item: Item
    @State private var isHovered = false

    var body: some View {
        let isSelected = store.selection.contains(item.id)
        HStack(alignment: .top, spacing: 10) {
            if let photo = item.photos.first {
                Thumbnail(url: photo, size: 64)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 64, height: 64)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(3)
                Text(Price.format(item.currentPrice)).font(.callout.monospacedDigit())
                    .foregroundStyle(item.currentPrice == nil ? .secondary : .primary)
                HStack(spacing: 8) {
                    if !item.owner.isEmpty {
                        HStack(spacing: 3) {
                            OwnerAvatar(owner: item.owner, size: 14)
                            Text(item.owner).lineLimit(1)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Belongs to \(item.owner)")
                    }
                    if let url = item.vintedURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("Vinted", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help(url.absoluteString)
                    }
                    let open = item.openTodos.count
                    if open > 0 {
                        Label("\(open)", systemImage: item.todos.contains { !$0.isDone && $0.isFromAgent } ? "sparkles" : "checklist")
                            .font(.caption).foregroundStyle(.orange)
                            .help("\(open) open to-do(s)")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .background(Color.accentColor.opacity(isSelected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(5)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor
                              : store.runningJob(for: item.id) != nil ? Color.purple
                              : isHovered ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .modifier(CardInteractions(item: item, isHovered: $isHovered))
    }
}

/// Click to open, ⌘/⇧-click to select, drag to another column, right-click for more.
private struct CardInteractions: ViewModifier {
    @Environment(AppStore.self) private var store
    let item: Item
    @Binding var isHovered: Bool
    @State private var isAddingPerson = false

    func body(content: Content) -> some View {
        let isSelected = store.selection.contains(item.id)
        let targets = store.targets(for: item)
        content
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onHover { isHovered = $0 }
            .onTapGesture {
                // ⌘/⇧-click selects; while a selection exists, a plain click adds or removes too.
                let modifiers = NSEvent.modifierFlags
                if modifiers.contains(.command) || modifiers.contains(.shift) || !store.selection.isEmpty {
                    withAnimation(.snappy(duration: 0.15)) { store.toggleSelection(item.id) }
                } else {
                    store.open(.item(item.id))
                }
            }
            .draggable(item.id) {
                Text(targets.count == 1 ? item.title : "\(targets.count) items")
                    .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
            .contextMenu {
                if targets.count > 1 {
                    Text("\(targets.count) selected items")
                }
                Menu("Belongs to") {
                    OwnerMenuItems(items: targets) { isAddingPerson = true }
                }
                Menu("Move to") {
                    ForEach(ItemStatus.allCases.filter { status in targets.contains { $0.status != status } }) { status in
                        Button(status.label) { Task { await store.move(targets.map(\.id), to: status) } }
                    }
                }
                Button(isSelected ? "Deselect" : "Select") { store.toggleSelection(item.id) }
                if let url = item.vintedURL {
                    Button("Open on Vinted") { NSWorkspace.shared.open(url) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
            }
            .modifier(NewPersonAlert(items: targets, isPresented: $isAddingPerson))
            .help(store.selection.isEmpty
                  ? "\(item.id) · click to open, ⌘-click to select, drag to change status"
                  : "\(item.id) · click to select or deselect")
    }
}

/// Floating bar for the selected cards: assign them to a person or move them in one go.
struct SelectionBar: View {
    @Environment(AppStore.self) private var store
    @State private var isAddingPerson = false

    var body: some View {
        let items = store.selectedItems
        HStack(spacing: 12) {
            Text("\(items.count) selected").font(.headline.monospacedDigit())
            Text(Price.format(items.compactMap(\.currentPrice).reduce(0, +)))
                .monospacedDigit().foregroundStyle(.secondary)
            Divider().frame(height: 18)
            Menu {
                OwnerMenuItems(items: items) { isAddingPerson = true }
            } label: {
                Label("Assign to", systemImage: "person.crop.circle.badge.plus")
            }
            .fixedSize()
            Menu {
                ForEach(ItemStatus.allCases) { status in
                    Button(status.label) { Task { await store.move(items.map(\.id), to: status) } }
                        .disabled(items.allSatisfy { $0.status == status })
                }
            } label: {
                Label("Move to", systemImage: "arrow.right.square")
            }
            .fixedSize()
            Divider().frame(height: 18)
            Button("Done") { withAnimation(.snappy) { store.selection = [] } }
                .keyboardShortcut(.cancelAction)
                .help("Clear the selection (Esc)")
        }
        .disabled(store.isWorking)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.bottom, 16)
        .modifier(NewPersonAlert(items: items, isPresented: $isAddingPerson))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
