import SwiftUI
import VintedCore

/// Floating glass panel on the right: to-dos (including the agent's questions and
/// suggestions, answered whenever it suits you), agent runs and finished to-dos.
/// On an item page it shows only that item's to-dos.
struct SidebarPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Show", selection: $store.sidebarTab) {
                Text("To-dos").tag(SidebarTab.todos)
                if store.agents.preferredKind != nil || !store.agents.jobs.isEmpty {
                    Text("Agent runs").tag(SidebarTab.runs)
                }
                Text("Done").tag(SidebarTab.done)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            switch store.sidebarTab {
            case .todos: TodoInbox()
            case .runs: AgentJobsPanel()
            case .done: DoneList()
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        .padding([.trailing, .bottom], 12)
        .padding(.top, 4)
    }
}

/// Open to-dos: the agent's questions and suggestions first, then plain to-dos.
private struct TodoInbox: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let itemID = store.currentItemID
        let open = (itemID.flatMap(store.item)?.todos ?? store.todos).filter { !$0.isDone }
        let fromAgent = open.filter(\.isFromAgent)
        let tasks = open.filter { !$0.isFromAgent }
        VStack(spacing: 0) {
            if open.isEmpty {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text(itemID == nil
                                                         ? "Questions and suggestions from your agent show up here."
                                                         : "This item has no open to-dos."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !fromAgent.isEmpty {
                            SidebarHeading(title: "From your agent", systemImage: "sparkles", count: fromAgent.count)
                            ForEach(fromAgent) { AgentTodoCard(todo: $0, showsItem: itemID == nil) }
                        }
                        if !tasks.isEmpty {
                            SidebarHeading(title: "For you", systemImage: "checklist", count: tasks.count)
                                .padding(.top, fromAgent.isEmpty ? 0 : 8)
                            VStack(spacing: 0) {
                                ForEach(tasks) { TodoRow(todo: $0, showsItem: itemID == nil) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
            SidebarFooter(itemID: itemID)
        }
    }
}

/// Running agent work, and on an item page the button to work the answers into the listing.
private struct SidebarFooter: View {
    @Environment(AppStore.self) private var store
    let itemID: Item.ID?

    var body: some View {
        let running = store.agents.jobs.filter { $0.state == .running }
        VStack(spacing: 8) {
            if let job = itemID.flatMap(store.runningJob) ?? (itemID == nil ? running.first : nil) {
                Button { store.sidebarTab = .runs } label: {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.task.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(running.count > 1 && itemID == nil ? "\(running.count) runs · results appear here as to-dos"
                                                                    : "Results appear here as to-dos")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            if store.agents.preferredKind != nil, let itemID, let item = store.item(itemID), item.todos.contains(where: { $0.isFromAgent && $0.isDone }) {
                Button {
                    store.runAgent(.revise(itemID: item.id, title: item.title))
                } label: {
                    Label("Update listing with my answers", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(.purple)
                .disabled(store.agents.preferredKind == nil || store.runningJob(for: itemID) != nil)
                .help("Answers are saved to Notizen right away. This asks your agent to use them in the title and description now; otherwise it picks them up on its next run.")
            }
        }
        .padding(12)
    }
}

private struct SidebarHeading: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title.uppercased())
            Text("\(count)").monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

/// A question or suggestion from the agent, resolved right here via `vinted answer/accept/dismiss`.
private struct AgentTodoCard: View {
    @Environment(AppStore.self) private var store
    let todo: Todo
    let showsItem: Bool

    var body: some View {
        let item = store.item(todo.itemID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showsItem, let item {
                    Button { store.open(.item(item.id, focus: todo.field)) } label: {
                        HStack(spacing: 8) {
                            if let photo = item.photos.first { Thumbnail(url: photo, size: 26) }
                            Text("\(Text("Nº \(item.id)").fontWeight(.semibold)) \(Text("· \(item.title)").foregroundStyle(.secondary))")
                        }
                        .font(.caption)
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open the item at \(todo.field.label.lowercased())")
                } else {
                    Button { store.open(.item(todo.itemID, focus: todo.field)) } label: {
                        Text(todo.field == .notes ? "From your agent" : "About \(todo.field.label.lowercased())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                KindChip(todo: todo)
            }
            switch todo.kind {
            case .question:
                Text(todo.displayText).font(.callout)
                QuestionControls(todo: todo)
            case .suggestion(let key, let value):
                if let value {
                    SuggestedValue(key: key, value: value, current: item?.text(key) ?? "")
                    if !todo.displayText.isEmpty {
                        Text(todo.displayText).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if !todo.displayText.isEmpty { Text(todo.displayText).font(.callout) }
                    Text(todo.proposedText)
                        .font(.callout)
                        .lineLimit(6)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                SuggestionControls(todo: todo)
            case .task:
                EmptyView()
            }
        }
        .padding(12)
        .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct KindChip: View {
    let todo: Todo

    var body: some View {
        let (label, color): (String, Color) = switch todo.kind {
        case .question: ("Question", .blue)
        case .suggestion(let key, _):
            (ItemField(key: key).map { $0 == .price ? "Price" : $0.label } ?? key, .purple)
        case .task: ("To-do", .orange)
        }
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

/// `12,00 €  ~~10,00 €~~` for prices, `new ← old` for other fields.
struct SuggestedValue: View {
    let key: String
    let value: String
    let current: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(format(value)).font(.title3.weight(.semibold)).monospacedDigit()
            if !current.isEmpty && current != value {
                Text(format(current)).strikethrough().foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func format(_ text: String) -> String {
        key.hasPrefix("price") ? Price.format(Price.parse(text)) : text
    }
}

/// Quick answers, a text field and "Can't tell" for a question.
struct QuestionControls: View {
    @Environment(AppStore.self) private var store
    let todo: Todo
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .question(_, let options) = todo.kind, !options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button(option) { Task { await store.answer(todo, with: option) } }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                    }
                }
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                TextField("Answer", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Can't tell") { Task { await store.dismiss(todo) } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close the question without an answer")
            }
            .controlSize(.small)
        }
        .disabled(store.isWorking)
    }

    private func save() {
        let text = answer
        Task {
            await store.answer(todo, with: text)
            answer = ""
        }
    }
}

/// Accept (optionally edited) or dismiss a suggestion.
struct SuggestionControls: View {
    @Environment(AppStore.self) private var store
    let todo: Todo
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("Value", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(acceptDraft)
                Button("Save", action: acceptDraft).buttonStyle(.borderedProminent).tint(.purple)
                Button("Cancel") { isEditing = false }.buttonStyle(.borderless)
            } else {
                Button(isDescription ? "Apply" : "Accept") { Task { await store.accept(todo) } }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                if isDescription {
                    Button("Review") { store.open(.item(todo.itemID, focus: .description)) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Edit…") {
                        if case .suggestion(_, let value) = todo.kind { draft = value ?? "" }
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                }
                Button("Dismiss") { Task { await store.dismiss(todo) } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .disabled(store.isWorking)
    }

    private var isDescription: Bool {
        if case .suggestion(_, nil) = todo.kind { return true }
        return false
    }

    private func acceptDraft() {
        let value = draft
        Task {
            await store.accept(todo, value: value)
            isEditing = false
        }
    }
}

/// Finished to-dos, with the answer or outcome of the agent's ones.
private struct DoneList: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let itemID = store.currentItemID
        let done = (itemID.flatMap(store.item)?.todos ?? store.todos).filter(\.isDone)
        if done.isEmpty {
            ContentUnavailableView("Nothing done yet", systemImage: "checklist.checked")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(done) { TodoRow(todo: $0, showsItem: itemID == nil) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

struct TodoRow: View {
    @Environment(AppStore.self) private var store
    let todo: Todo
    /// Shows which item the to-do belongs to (off inside the item's own page).
    var showsItem = true
    /// Replaces the default "open the item at this field" action.
    var goTo: ((ItemField) -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if todo.isFromAgent {
                Image(systemName: "sparkles").foregroundStyle(.purple).help("From your agent")
            } else {
                Toggle(isOn: Binding(get: { todo.isDone }, set: { done in Task { await store.setTodo(todo, done: done) } })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(store.isWorking)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(todo.displayText)
                    .strikethrough(todo.isDone && !todo.isFromAgent)
                    .foregroundStyle(todo.isDone ? .secondary : .primary)
                    .lineLimit(3)
                if let outcome = todo.outcome {
                    Text(outcome).font(.caption.weight(.medium)).foregroundStyle(.purple)
                }
                if showsItem, let item = store.item(todo.itemID) {
                    Text("\(item.id) · \(item.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !todo.isDone {
                Button {
                    if let goTo { goTo(todo.field) } else { store.open(.item(todo.itemID, focus: todo.field)) }
                } label: {
                    Image(systemName: "arrow.right.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                .help("Go to \(todo.field.label.lowercased())")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
    }
}

extension ItemField {
    var label: String {
        switch self {
        case .photos: "Photos"
        case .title: "Title"
        case .category: "Category"
        case .brand: "Brand"
        case .size: "Size"
        case .condition: "Condition"
        case .colors: "Colours"
        case .material: "Material"
        case .price: "Price"
        case .description: "Description"
        case .notes: "Notes"
        }
    }
}
