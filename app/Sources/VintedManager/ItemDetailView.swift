import AppKit
import SwiftUI
import VintedCore


/// One item: photos on the left, the Vinted form on the right. The agent's open questions and
/// suggestions appear right at the field they are about.
struct ItemDetailView: View {
    @Environment(AppStore.self) private var store
    let item: Item
    /// Where a to-do sent us: scrolled to, highlighted and (for plain fields) opened for editing.
    var focus: ItemField?

    @State private var highlighted: ItemField?
    @State private var editing: ItemField?
    @State private var showsNotes = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        PhotoPane(item: item)
                            .frame(width: 400)
                            .id(ItemField.photos).highlight(highlighted == .photos)
                        details(proxy).frame(minWidth: 460, maxWidth: 680)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        PhotoPane(item: item)
                            .frame(maxWidth: 420)
                            .id(ItemField.photos).highlight(highlighted == .photos)
                        details(proxy)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: focus) {
                guard let focus else { return }
                try? await Task.sleep(for: .milliseconds(250))
                reveal(focus, proxy: proxy)
            }
        }
        .navigationTitle("Nº \(item.id)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.agents.preferredKind != nil {
                    Button { store.runAgent(.recheckPrice(itemID: item.id, title: item.title)) } label: {
                        Label("Re-check price with agent", systemImage: "sparkles")
                    }
                    .disabled(store.agents.preferredKind == nil || store.runningJob(for: item.id) != nil)
                }
                if let url = item.vintedURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open on Vinted", systemImage: "safari") }
                }
                Button { NSWorkspace.shared.open(item.listingURL) } label: {
                    Label("Open listing.md", systemImage: "doc.text")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
    }

    private func details(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VintedFields(item: item, highlighted: highlighted, editing: $editing)
            DescriptionCard(item: item)
                .id(ItemField.description)
                .highlight(highlighted == .description)
            StatusEditor(item: item).id(ItemField.price).highlight(highlighted == .price)
            if !item.priceResearch.isEmpty {
                DisclosureGroup("Price research") {
                    Text(item.priceResearch)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            if !item.notes.isEmpty {
                DisclosureGroup("Notes", isExpanded: $showsNotes) {
                    Text(item.notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .id(ItemField.notes)
                .highlight(highlighted == .notes)
            }
        }
    }

    private func reveal(_ field: ItemField, proxy: ScrollViewProxy) {
        if field == .notes { showsNotes = true }
        // Fields with an open question or suggestion show it inline instead of the editor.
        if field.key != nil, !item.todos.contains(where: { !$0.isDone && $0.isFromAgent && $0.field == field }) {
            editing = field
        }
        withAnimation { proxy.scrollTo(field, anchor: .center) }
        highlighted = field
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.6)) { if highlighted == field { highlighted = nil } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Nº \(item.id)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                if let status = item.status {
                    HStack(spacing: 5) {
                        Circle().fill(status.tint).frame(width: 7, height: 7)
                        Text(status.label)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(status.tint.opacity(0.16), in: Capsule())
                }
                Spacer()
                OwnerMenu(item: item)
            }
            Text(item.title).font(.largeTitle.weight(.bold)).textSelection(.enabled)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let dates = [("created", "Created"), ("listed_at", "Listed"), ("sold_at", "Sold")]
            .compactMap { key, label in item.text(key).isEmpty ? nil : "\(label) \(item.text(key))" }
        return (dates + ["\(item.photos.count) photo(s)"]).joined(separator: " · ")
    }
}

// MARK: - Photos

/// A large photo with a strip below. Photos can be dragged straight into Vinted's upload in the browser.
private struct PhotoPane: View {
    let item: Item
    @State private var index = 0

    var body: some View {
        let photos = item.photos
        let current = photos.isEmpty ? nil : photos[min(index, photos.count - 1)]
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(4 / 5, contentMode: .fit)
                .overlay {
                    if let current {
                        Photo(url: current, maxSize: 900)
                            .draggable(current)
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(current) }
                    } else {
                        Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
                .overlay(alignment: .bottom) {
                    if photos.count > 0 {
                        HStack(spacing: 12) {
                            Button { index = (index - 1 + photos.count) % photos.count } label: { Image(systemName: "chevron.left") }
                            Text("\(min(index, photos.count - 1) + 1) / \(photos.count)").monospacedDigit()
                            Button { index = (index + 1) % photos.count } label: { Image(systemName: "chevron.right") }
                            Divider().frame(height: 14)
                            Button("Select all in Finder") { NSWorkspace.shared.activateFileViewerSelecting(photos) }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .padding(12)
                    }
                }
                .help("Drag into Vinted's photo upload · double-click to open")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(photos.enumerated()), id: \.element) { offset, photo in
                        Thumbnail(url: photo, size: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor, lineWidth: offset == index ? 2.5 : 0)
                            )
                            .onTapGesture { index = offset }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(photo) }
                            .draggable(photo)
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.hidden)
            Text("Drag photos into the browser to upload them to Vinted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Description with copy button; an open description suggestion shows the proposed text below.
private struct DescriptionCard: View {
    @Environment(AppStore.self) private var store
    let item: Item
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        let suggestion = item.todos.first { todo in
            if !todo.isDone, case .suggestion("description", _) = todo.kind { return true }
            return false
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Beschreibung").font(.headline)
                Spacer()
                CopyButton(text: item.description, label: "Copy")
                Button {
                    draft = item.description
                    isEditing = true
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .help("Edit description")
            }
            if isEditing {
                TextEditor(text: $draft).frame(minHeight: 120)
                HStack {
                    Button("Save") {
                        Task {
                            await store.setField(item, key: "description", value: draft)
                            isEditing = false
                        }
                    }.disabled(store.isWorking)
                    Button("Cancel") { isEditing = false }
                }
            } else {
                Text(item.description.isEmpty ? "–" : item.description)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let suggestion {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Suggested description")
                        if !suggestion.displayText.isEmpty {
                            Text("· \(suggestion.displayText)").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                    Text(suggestion.proposedText).textSelection(.enabled)
                    SuggestionControls(todo: suggestion)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

extension View {
    /// Brief accent background when a to-do points at this part of the page.
    func highlight(_ isOn: Bool) -> some View {
        padding(isOn ? 6 : 0)
            .background(Color.accentColor.opacity(isOn ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 12))
            .padding(isOn ? -6 : 0)
    }
}

// MARK: - Status

private struct StatusEditor: View {
    @Environment(AppStore.self) private var store
    let item: Item

    @State private var status: ItemStatus = .planned
    @State private var price = ""
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status & price").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Status", selection: $status) {
                    ForEach(ItemStatus.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    TextField(priceLabel, text: $price)
                        .frame(width: 140)
                    TextField("Vinted link (optional)", text: $url)
                    Button("Save") {
                        Task { await store.setStatus(item, to: status, price: price, url: url) }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.isWorking || !hasChanges)
                }
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .onAppear(perform: resetFromItem)
        .onChange(of: status) { _, newStatus in price = defaultPrice(for: newStatus) }
    }

    private var priceLabel: String {
        status == .sold ? "Sold for (€)" : "Price (€)"
    }

    private var caption: String {
        let dates = [("created", "Created"), ("listed_at", "Listed"), ("sold_at", "Sold")]
            .compactMap { key, label in item.text(key).isEmpty ? nil : "\(label) \(item.text(key))" }
        let suggested = item.price("price_suggested").map { "Suggested \(Price.format($0))" }
        return (dates + [suggested].compactMap { $0 }).joined(separator: " · ")
    }

    private var hasChanges: Bool {
        status != item.status || Price.parse(price) != defaultPriceValue(for: status) || url != item.text("vinted_url")
    }

    private func resetFromItem() {
        status = item.status ?? .planned
        price = defaultPrice(for: status)
        url = item.text("vinted_url")
    }

    private func defaultPriceValue(for status: ItemStatus) -> Double? { item.defaultPrice(for: status) }

    private func defaultPrice(for status: ItemStatus) -> String {
        defaultPriceValue(for: status).map { $0.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "de_DE"))) } ?? ""
    }
}

// MARK: - Copyable (and editable) Vinted form fields

private struct VintedFields: View {
    let item: Item
    let highlighted: ItemField?
    @Binding var editing: ItemField?

    private var rows: [(ItemField, String)] {
        [(.price, item.currentPrice.map { Price.format($0) } ?? ""),
         (.title, item.title), (.category, item.text("category")), (.brand, item.text("brand")),
         (.size, item.text("size")), (.condition, item.text("condition")), (.colors, item.text("colors")),
         (.material, item.text("material"))]
    }

    var body: some View {
        let open = item.todos.filter { !$0.isDone && $0.isFromAgent && $0.field != .description }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
                let (field, value) = row
                let pending = open.filter { $0.field == field }
                if index > 0 { Divider().padding(.leading, 16) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(field == .price ? "Preis" : field.label).foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        if field == .price {
                            Text(value.isEmpty ? "–" : value).font(.title3.weight(.semibold)).monospacedDigit()
                            Spacer()
                        } else {
                            FieldValue(item: item, field: field, value: value, editing: $editing)
                        }
                    }
                    ForEach(pending) { todo in
                        InlineTodo(item: item, todo: todo).padding(.leading, 102)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(pending.isEmpty ? .clear : (pending.contains { if case .question = $0.kind { true } else { false } }
                                                        ? Color.blue : Color.purple).opacity(0.06))
                .id(field == .price ? nil : field)
                .highlight(highlighted == field)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// The agent's question or suggestion for one field, answerable in place.
private struct InlineTodo: View {
    let item: Item
    let todo: Todo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch todo.kind {
            case .question:
                Label(todo.displayText, systemImage: "questionmark.bubble")
                    .font(.callout.weight(.medium)).foregroundStyle(.blue)
                QuestionControls(todo: todo)
            case .suggestion(let key, let value):
                HStack(spacing: 8) {
                    Label("Agent suggests", systemImage: "sparkles").font(.callout.weight(.medium)).foregroundStyle(.purple)
                    SuggestedValue(key: key, value: value ?? "", current: item.text(key))
                }
                if !todo.displayText.isEmpty {
                    Text(todo.displayText).font(.caption).foregroundStyle(.secondary)
                }
                SuggestionControls(todo: todo)
            case .task:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Copy button plus a pencil that edits the frontmatter field through `vinted set`.
private struct FieldValue: View {
    @Environment(AppStore.self) private var store
    let item: Item
    let field: ItemField
    let value: String
    @Binding var editing: ItemField?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if let key = field.key, editing == field {
            HStack(spacing: 6) {
                TextField(field.label, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .focused($isFocused)
                    .onSubmit { save(key) }
                    .onExitCommand { editing = nil }
                Button("Save") { save(key) }
                    .disabled(store.isWorking || draft.trimmingCharacters(in: .whitespaces) == value)
                Button("Cancel") { editing = nil }
            }
            .controlSize(.small)
            .onAppear {
                draft = value
                isFocused = true
            }
        } else {
            HStack(spacing: 4) {
                CopyButton(text: value)
                Spacer(minLength: 0)
                if field.key != nil {
                    Button { editing = field } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Edit \(field.label.lowercased())")
                }
            }
        }
    }

    private func save(_ key: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await store.setField(item, key: key, value: text)
            editing = nil
        }
    }
}

private struct CopyButton: View {
    let text: String
    var label: String?
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(spacing: 6) {
                Text(label ?? (text.isEmpty ? "–" : text)).lineLimit(1)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
        }
        .buttonStyle(.borderless)
        .disabled(text.isEmpty)
    }
}
