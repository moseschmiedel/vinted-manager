import AppKit
import SwiftUI
import VintedCore

// MARK: - Agent runs (a tab of the sidebar)

struct AgentJobsPanel: View {
    @Environment(AppStore.self) private var store
    @State private var instruction = ""

    var body: some View {
        let agents = store.agents
        VStack(alignment: .leading, spacing: 0) {
            composer.padding(.horizontal, 12)
            HStack {
                Spacer()
                Button("Clear finished") { agents.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(agents.jobs.allSatisfy { $0.state == .running })
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if agents.jobs.isEmpty {
                ContentUnavailableView("No agent runs yet", systemImage: "sparkles",
                                       description: Text("Ask your agent something above, or process the inbox."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(agents.jobs) { JobCard(job: $0) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask your agent, e.g. “item 4 sold for 4 €”", text: $instruction, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            HStack {
                AgentPicker()
                Spacer()
                Button("Run", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || store.agents.preferredKind == nil)
            }
        }
    }

    private func send() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.runAgent(.instruction(text))
        instruction = ""
    }
}

/// Title, current step and a stop button; click to open the transcript.
private struct JobCard: View {
    @Environment(AppStore.self) private var store
    let job: AgentJob
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.task.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text(job.currentStep)
                    .font(.caption.monospaced())
                    .foregroundStyle(job.state == .failed ? .orange : .secondary)
                    .lineLimit(2)
                Text("\(job.kind.displayName) · \(job.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if job.state == .running {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button { job.cancel() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop this run")
                }
            } else {
                JobStateIcon(state: job.state)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.6) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { isHovered = $0 }
        .onTapGesture { store.open(.job(job.id)) }
        .help("Open transcript")
    }
}

struct JobStateIcon: View {
    let state: AgentJob.State

    var body: some View {
        switch state {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

/// Picks the default agent; shows only installed + logged-in ones.
struct AgentPicker: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var agents = store.agents
        if agents.readyKinds.isEmpty {
            Label(agents.isChecking ? "Checking agents…" : "No agent ready — see Settings",
                  systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Agent", selection: $agents.defaultKind) {
                ForEach(agents.readyKinds) { Text($0.displayName).tag($0) }
            }
            .fixedSize()
        }
    }
}

// MARK: - Transcript (pushed on the dashboard)

struct AgentJobDetailView: View {
    let job: AgentJob

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(job.events.enumerated()), id: \.offset) { index, event in
                            EventView(event: event).id(index)
                        }
                        if job.state == .running {
                            HStack { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
                                .id("working")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: job.events.count) {
                    withAnimation { proxy.scrollTo(job.state == .running ? AnyHashable("working") : AnyHashable(job.events.count - 1), anchor: .bottom) }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.task.title).font(.title3.weight(.semibold))
                Text(details).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if job.state == .running {
                Button("Stop", role: .destructive) { job.cancel() }
            } else {
                JobStateIcon(state: job.state).font(.title2)
            }
        }
    }

    private var details: String {
        var parts = [job.kind.displayName]
        if let model = job.model { parts.append(model) }
        if let cost = job.costUSD { parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))) }
        if let end = job.finishedAt { parts.append(Duration.seconds(end.timeIntervalSince(job.startedAt)).formatted(.units(allowed: [.minutes, .seconds]))) }
        if let session = job.sessionID, !session.isEmpty { parts.append("session \(session.prefix(8))") }
        return parts.joined(separator: " · ")
    }
}

private struct EventView: View {
    let event: AgentEvent

    var body: some View {
        switch event {
        case .started:
            EmptyView()
        case .message(let text):
            Text(markdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name, let detail):
            Label {
                Text(detail.isEmpty ? name : "\(name)  \(detail)").lineLimit(2).font(.callout.monospaced())
            } icon: {
                Image(systemName: symbol(for: name))
            }
            .foregroundStyle(.secondary)
        case .finished(let summary, let isError, _):
            if isError {
                Label(summary ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
        case .notice(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func symbol(for tool: String) -> String {
        switch tool {
        case "Read": "doc.text.magnifyingglass"
        case "Write", "Edit", "MultiEdit": "pencil"
        case "Bash", "Shell": "terminal"
        case "WebSearch", "WebFetch": "globe"
        case "Glob", "Grep": "magnifyingglass"
        default: "wrench.and.screwdriver"
        }
    }
}

// MARK: - Settings › Agents

struct AgentSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var agents = store.agents
        Form {
            if store.repository == nil {
                Text("Create or open a library to configure optional AI assistance.")
            } else {
                Section {
                    Picker("Default agent", selection: $agents.defaultKind) {
                        ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text("AI assistance is optional. Install and log in to an assistant separately, then check again. Actions appear only when an assistant is ready. Runs use your own login and subscription and can change this library's files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(AgentKind.allCases) { kind in
                    AgentConfigSection(kind: kind)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button("Check again") { Task { await agents.refreshStatus() } }
                .disabled(agents.isChecking || store.repository == nil)
        }
        .frame(width: 560, height: 560)
    }
}

private struct AgentConfigSection: View {
    @Environment(AppStore.self) private var store
    let kind: AgentKind
    @State private var environmentText = ""

    var body: some View {
        @Bindable var agents = store.agents
        let config = Binding(get: { agents.config(kind) }, set: { agents.configs[kind] = $0 })
        Section(kind.displayName) {
            LabeledContent("Status") {
                if let status = agents.status(kind) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(status.detail, systemImage: status.isReady ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(status.isReady ? .green : .orange)
                        Text([status.version, status.executable?.path].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    if agents.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Not checked — click Check again").foregroundStyle(.secondary)
                    }
                }
            }
            TextField("Executable", text: config.binaryPath, prompt: Text("Found on PATH"))
            TextField("Model", text: config.model, prompt: Text(kind == .claude ? "Default, e.g. sonnet or opus" : "Default"))
            TextField("Environment", text: $environmentText, prompt: Text("KEY=value, one per line"), axis: .vertical)
                .lineLimit(1...4)
                .onAppear { environmentText = config.wrappedValue.environment.map { "\($0)=\($1)" }.sorted().joined(separator: "\n") }
                .onChange(of: config.wrappedValue.environment) {
                    environmentText = config.wrappedValue.environment.map { "\($0)=\($1)" }.sorted().joined(separator: "\n")
                }
                .onChange(of: environmentText) {
                    var environment: [String: String] = [:]
                    for line in environmentText.split(separator: "\n") {
                        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        if parts.count == 2, !parts[0].isEmpty { environment[parts[0]] = parts[1] }
                    }
                    config.wrappedValue.environment = environment
                }
        }
    }
}
