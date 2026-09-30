import Foundation

/// UI request mapped to a task owned by `vinted agent run`.
public enum AgentTask: Sendable, Equatable {
    case clusterPhotos([String])
    case draftListing(group: String, photos: [String])
    case processInbox
    case recheckPrice(itemID: String, title: String)
    case revise(itemID: String, title: String)
    case instruction(String)

    /// The item the run works on, if it is about a single item.
    public var itemID: String? {
        switch self {
        case .recheckPrice(let id, _), .revise(let id, _): id
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .clusterPhotos(let photos): "Group \(photos.count) photos by item"
        case .draftListing(let group, _): "Draft listing: \(group)"
        case .processInbox: "Process inbox"
        case .recheckPrice(let id, _): "Re-check price: \(id)"
        case .revise(let id, _): "Update listing with answers: \(id)"
        case .instruction(let text): text.count > 60 ? String(text.prefix(57)) + "…" : text
        }
    }

    public var arguments: [String] {
        switch self {
        case .clusterPhotos(let photos): ["cluster"] + photos
        case .draftListing(let group, _): ["draft", group]
        case .processInbox: ["inbox"]
        case .recheckPrice(let id, _): ["price", id]
        case .revise(let id, _): ["revise", id]
        case .instruction(let text): ["instruction", text]
        }
    }
}
