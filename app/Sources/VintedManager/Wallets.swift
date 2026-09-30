import SwiftUI
import VintedCore

/// Money per person. Clicking a wallet shows only that person's items and to-dos.
struct WalletsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let wallets = store.wallets
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Wallets") {
                if store.ownerFilter != nil {
                    Button("Show everyone") { withAnimation(.snappy) { store.ownerFilter = nil } }
                        .controlSize(.small)
                }
            }
            if store.people.isEmpty {
                Text("Assign items to people — on the item page or via right-click › Belongs to — to see who earned how much.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(wallets) { wallet in
                            WalletCard(wallet: wallet, isSelected: store.ownerFilter == wallet.owner) {
                                withAnimation(.snappy) {
                                    store.ownerFilter = store.ownerFilter == wallet.owner ? nil : wallet.owner
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

private struct WalletCard: View {
    let wallet: Wallet
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                OwnerAvatar(owner: wallet.owner, size: 20)
                Text(wallet.owner.isEmpty ? "Unassigned" : wallet.owner).font(.headline).lineLimit(1)
            }
            Text(Price.format(wallet.revenue))
                .font(.title2.weight(.semibold).monospacedDigit())
                .help("Revenue from \(wallet.soldCount) sold item(s)")
            Text("\(wallet.soldCount) sold")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 12) {
                figure("On Vinted", Price.format(wallet.asking), count: wallet.activeCount)
                figure("Planned", Price.format(wallet.suggested), count: wallet.plannedCount)
            }
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : isHovered ? Color.accentColor.opacity(0.5) : .clear,
                              lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .help(isSelected ? "Show everyone's items" : "Show only these items")
    }

    private func figure(_ label: String, _ value: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.monospacedDigit())
            Text("\(label) · \(count)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Initial in a coloured circle; the colour stays the same for a name.
struct OwnerAvatar: View {
    let owner: String
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(owner.isEmpty ? Color.secondary.opacity(0.3) : Self.color(for: owner))
            if owner.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
            } else {
                Text(owner.prefix(1).uppercased())
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    static func color(for owner: String) -> Color {
        let hash = owner.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}

/// Picks the person an item belongs to, or adds a new one.
struct OwnerMenu: View {
    @Environment(AppStore.self) private var store
    let item: Item
    @State private var isAdding = false

    var body: some View {
        HStack(spacing: 6) {
            OwnerAvatar(owner: item.owner, size: 20)
            Menu(item.owner.isEmpty ? "Assign to…" : item.owner) {
                OwnerMenuItems(items: [item]) { isAdding = true }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .help("Whose wallet the money goes to")
        .modifier(NewPersonAlert(items: [item], isPresented: $isAdding))
    }
}

/// Menu entries shared by the item page, the card context menu and the selection bar.
struct OwnerMenuItems: View {
    @Environment(AppStore.self) private var store
    let items: [Item]
    let addPerson: () -> Void

    var body: some View {
        ForEach(store.people, id: \.self) { person in
            Button {
                Task { await store.setOwner(items, to: person) }
            } label: {
                if items.allSatisfy({ $0.owner == person }) { Label(person, systemImage: "checkmark") } else { Text(person) }
            }
        }
        if !store.people.isEmpty { Divider() }
        Button("New Person…", action: addPerson)
        if items.contains(where: { !$0.owner.isEmpty }) {
            Button("Nobody") { Task { await store.setOwner(items, to: "") } }
        }
    }
}

struct NewPersonAlert: ViewModifier {
    @Environment(AppStore.self) private var store
    let items: [Item]
    @Binding var isPresented: Bool
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("New person", isPresented: $isPresented) {
            TextField("Name", text: $name)
            Button("Assign") {
                let person = name
                name = ""
                Task { await store.setOwner(items, to: person) }
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { name = "" }
        } message: {
            Text(items.count == 1
                 ? "“\(items[0].title)” will count towards this person's wallet."
                 : "\(items.count) items will count towards this person's wallet.")
        }
    }
}
