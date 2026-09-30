import Foundation

public let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png", "webp"]

/// Photos waiting in `inbox/`: a subfolder is one item, a loose photo is its own group.
public struct InboxGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let isFolder: Bool
    public let photos: [URL]
}

/// The selling repository on disk (the folder containing `items/`, `inbox/` and the `vinted` CLI launcher).
public struct VintedRepository: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var itemsDirectory: URL { root.appendingPathComponent("items") }
    public var inboxDirectory: URL { root.appendingPathComponent("inbox") }
    /// Installed apps always use their matching CLI, including for older libraries.
    public var cli: URL {
        Self.bundledCLI ?? root.appendingPathComponent("vinted")
    }

    public static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vinted")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public static func isRepository(_ url: URL) -> Bool {
        let fm = FileManager.default
        return ["items", "inbox", "templates"].allSatisfy {
            (try? url.appendingPathComponent($0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } && fm.fileExists(atPath: url.appendingPathComponent("templates/listing.md").path)
            && (bundledCLI != nil || fm.isExecutableFile(atPath: url.appendingPathComponent("vinted").path))
    }

    /// Walks up from `start` to the first folder that looks like the repository.
    public static func locate(from start: URL) -> VintedRepository? {
        var url = start.standardizedFileURL
        while true {
            if isRepository(url) { return VintedRepository(root: url) }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    public func loadItems() throws -> [Item] {
        let fm = FileManager.default
        let folders = try fm.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        return folders
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("listing.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { folder in
                guard let text = try? String(contentsOf: folder.appendingPathComponent("listing.md"), encoding: .utf8)
                else { return nil }
                return Item(folder: folder, document: .parse(text),
                            photos: images(in: folder.appendingPathComponent("photos")))
            }
    }

    public func inboxGroups() -> [InboxGroup] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: inboxDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var groups: [InboxGroup] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let photos = images(in: entry, recursive: true)
                if !photos.isEmpty { groups.append(InboxGroup(id: entry.lastPathComponent, isFolder: true, photos: photos)) }
            } else if Self.isImage(entry) {
                groups.append(InboxGroup(id: entry.lastPathComponent, isFolder: false, photos: [entry]))
            }
        }
        return groups
    }

    /// Copies photos into `inbox/`, or into `inbox/<groupName>/` so they become one item.
    @discardableResult
    public func importPhotos(_ urls: [URL], groupName: String? = nil) throws -> [URL] {
        let fm = FileManager.default
        var target = inboxDirectory
        if let groupName = groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !groupName.isEmpty {
            target = uniqueURL(inboxDirectory.appendingPathComponent(Self.slug(groupName)))
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        return try urls.filter(Self.isImage).map { source in
            let destination = uniqueURL(target.appendingPathComponent(source.lastPathComponent))
            try fm.copyItem(at: source, to: destination)
            return destination
        }
    }

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    public static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = text.lowercased().unicodeScalars.split { !allowed.contains($0) }
        let slug = parts.map { String(String.UnicodeScalarView($0)) }.joined(separator: "-")
        return slug.isEmpty ? "item" : slug
    }

    private func images(in folder: URL, recursive: Bool = false) -> [URL] {
        let fm = FileManager.default
        let urls: [URL]
        if recursive {
            urls = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        } else {
            urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        return urls.filter(Self.isImage).sorted { $0.path < $1.path }
    }

    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2... {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
