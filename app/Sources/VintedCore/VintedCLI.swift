import Foundation

public struct CLIError: LocalizedError, Sendable {
    public let command: String
    public let output: String
    public var errorDescription: String? { "`\(command)` failed:\n\(output)" }
}

/// Runs `./vinted` (the Rust CLI), so the app changes files exactly like the terminal and agents do.
public struct VintedCLI: Sendable {
    public let repository: VintedRepository

    public init(repository: VintedRepository) { self.repository = repository }

    /// Explicitly select the data root: the bundled executable is outside the library.
    public static func environment(repository: VintedRepository) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:\(home)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["VINTED_REPO"] = repository.root.path
        if let binary = VintedRepository.bundledCLI {
            environment["VINTED_CLI_BINARY"] = binary.path
            environment["VINTED_IMAGE_CONVERTER"] = binary.deletingLastPathComponent().appendingPathComponent("VintedPhotoConverter").path
        }
        return environment
    }

    /// Bootstrap using the app's runtime, or the source checkout during development.
    public static func createLibrary(at root: URL) async throws -> VintedRepository {
        let bootstrap = VintedRepository.bundledCLI.map { _ in VintedRepository(root: root.deletingLastPathComponent()) }
            ?? VintedRepository.locate(from: Bundle.main.bundleURL)
            ?? VintedRepository.locate(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        guard let bootstrap else {
            throw CLIError(command: "vinted init", output: "The bundled CLI is missing. Rebuild Vinted Manager.")
        }
        _ = try await VintedCLI(repository: bootstrap).run(["init", root.path])
        return VintedRepository(root: root)
    }

    /// `vinted status` also stamps dates and regenerates INVENTORY.md.
    @discardableResult
    public func setStatus(itemID: String, to status: ItemStatus, price: String? = nil, url: String? = nil) async throws -> String {
        var args = ["status", itemID, status.rawValue]
        if let price = price?.trimmingCharacters(in: .whitespaces), !price.isEmpty {
            args += ["--price", price.replacingOccurrences(of: ",", with: ".")]
        }
        if let url = url?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
            args += ["--url", url]
        }
        return try await run(args)
    }

    /// `vinted set`: frontmatter fields such as size or material.
    @discardableResult
    public func set(itemID: String, _ fields: [String: String]) async throws -> String {
        try await set(itemIDs: [itemID], fields)
    }

    /// `vinted set 3,5,7 …`: the same fields on several items, with one INVENTORY.md rebuild.
    @discardableResult
    public func set(itemIDs: [String], _ fields: [String: String]) async throws -> String {
        try await run(["set", itemIDs.joined(separator: ",")] + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
    }

    /// `vinted todo`: checks (or unchecks) a to-do in Notizen.
    @discardableResult
    public func setTodo(_ todo: Todo, done: Bool) async throws -> String {
        try await run(["todo", todo.itemID, String(todo.number)] + (done ? [] : ["--open"]))
    }

    /// `vinted answer`: answers a QUESTION to-do and fills the field it names.
    @discardableResult
    public func answer(_ todo: Todo, with answer: String) async throws -> String {
        try await run(["answer", todo.itemID, String(todo.number), answer])
    }

    /// `vinted accept`: applies a SUGGEST to-do, optionally with a changed value.
    @discardableResult
    public func accept(_ todo: Todo, value: String? = nil) async throws -> String {
        try await run(["accept", todo.itemID, String(todo.number)] + (value.map { ["--value", $0] } ?? []))
    }

    /// `vinted dismiss`: closes a QUESTION or SUGGEST to-do without applying it.
    @discardableResult
    public func dismiss(_ todo: Todo) async throws -> String {
        try await run(["dismiss", todo.itemID, String(todo.number)])
    }

    @discardableResult
    public func regenerateIndex() async throws -> String {
        try await run(["index"])
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = repository.cli
        process.arguments = arguments
        process.currentDirectoryURL = repository.root

        process.environment = Self.environment(repository: repository)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            // Drain both pipes while running: long descriptions and build output can
            // fill a pipe and prevent the child from ever reaching its termination handler.
            let outputReader = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let errorReader = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            process.terminationHandler = { process in
                let status = process.terminationStatus
                Task {
                    let output = String(decoding: await outputReader.value, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let errorText = String(decoding: await errorReader.value, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if status == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: CLIError(command: "vinted " + arguments.joined(separator: " "),
                                                              output: [output, errorText].filter { !$0.isEmpty }.joined(separator: "\n")))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }
}
