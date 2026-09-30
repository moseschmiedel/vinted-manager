import AppKit
import SwiftUI
import VintedCore

/// Top of the dashboard: the inbox is also the drop zone for new photos.
struct InboxSection: View {
    @Environment(AppStore.self) private var store
    @State private var asOneItem = true
    @State private var itemName = ""
    @State private var isTargeted = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Inbox", count: store.inbox.isEmpty ? nil : store.inboxPhotoCount) {
                controls
            }
            if store.inbox.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop photos here to start new listings").font(.headline)
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.inbox) { InboxGroupCard(group: $0) }
                    }
                    .padding(.bottom, 4)
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary.opacity(0.4))
        )
        .dropDestination(for: URL.self) { urls, _ in
            importPhotos(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var controls: some View {
        @Bindable var store = store
        let busy = store.agents.preferredKind == nil || store.agents.isClustering
        return HStack(spacing: 10) {
            if store.agents.preferredKind != nil {
                Toggle("Group by item", isOn: $store.autoClusterOnImport)
                    .toggleStyle(.checkbox)
                    .help("Let your agent put photos of the same item into one inbox folder")
            }
            if !store.usesAutomaticGrouping {
                Toggle("Several photos = one item", isOn: $asOneItem).toggleStyle(.checkbox)
                if asOneItem {
                    TextField("Item name (optional)", text: $itemName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                }
            }
            Button("Choose Photos…", action: choosePhotos)
            if store.agents.preferredKind != nil && store.inbox.contains(where: { !$0.isFolder }) {
                Button("Group loose photos") { store.groupLoosePhotos() }
                    .disabled(busy)
            }
            if store.agents.preferredKind != nil {
                Button("Process inbox") { store.runAgent(.processInbox) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.inbox.isEmpty || busy)
                    .help("Your agent writes a listing for every inbox group and adds the items as “Planned”")
            }
        }
        .controlSize(.small)
    }

    private var hint: String {
        if store.agents.isClustering { return "Agent is grouping the new photos…" }
        if store.agents.lastClusteringJob?.state == .failed {
            return "Grouping failed; photos remain in the inbox. Open the run in Agent Jobs to see why."
        }
        if store.agents.preferredKind == nil { return "Import photos together for one item, then create a listing and fill in its details. Optional AI assistance can be enabled in Settings › Agents (⌘,)." }
        return store.autoClusterOnImport
            ? "Your agent groups new photos by item. Anything it can't see ends up as a to-do."
            : "Anything the agent can't see in the photos ends up as a to-do."
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        importPhotos(panel.urls)
    }

    private func importPhotos(_ urls: [URL]) {
        store.importPhotos(urls, asOneItem: asOneItem, name: itemName)
        itemName = ""
    }
}

private struct InboxGroupCard: View {
    @Environment(AppStore.self) private var store
    let group: InboxGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(group.photos.prefix(4), id: \.self) { photo in
                    Thumbnail(url: photo, size: 56)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(photo) }
                }
                if group.photos.count > 4 {
                    Text("+\(group.photos.count - 4)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Label(group.id, systemImage: group.isFolder ? "folder" : "photo")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Create listing") { store.createListing(for: group) }
                    .controlSize(.small)
                    .disabled(store.isWorking || store.agents.isClustering)
                if store.agents.preferredKind != nil {
                    Button("Draft with AI") { store.draftListing(for: group) }
                        .controlSize(.small)
                        .disabled(store.agents.preferredKind == nil || store.agents.isClustering)
                        .help(store.agents.preferredKind.map { "Let \($0.displayName) write the listing for these photos" }
                              ?? "No agent ready — see Settings › Agents")
                }
            }
        }
        .padding(10)
        .frame(minWidth: 220, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
