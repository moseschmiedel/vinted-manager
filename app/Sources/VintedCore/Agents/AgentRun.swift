import Foundation

/// Streams one `vinted agent run --json` process into the app.
public final class AgentRun: @unchecked Sendable {
    public let kind: AgentKind
    public let task: AgentTask
    public let repository: VintedRepository
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init(kind: AgentKind, task: AgentTask, repository: VintedRepository) {
        self.kind = kind
        self.task = task
        self.repository = repository
    }

    public static func arguments(kind: AgentKind, task: AgentTask) -> [String] {
        ["agent", "run"] + task.arguments + ["--provider", kind.rawValue, "--json"]
    }

    public func events() -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            process.executableURL = repository.cli
            process.arguments = Self.arguments(kind: kind, task: task)
            process.currentDirectoryURL = repository.root
            process.standardInput = FileHandle.nullDevice
            process.environment = VintedCLI.environment(repository: repository)
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let errorReader = PipeReader(stderr)
            let reader = Task {
                var finished = false
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        if let event = AgentEvent.parse(line: line) {
                            if case .finished = event { finished = true }
                            continuation.yield(event)
                        }
                    }
                } catch {
                    continuation.yield(.notice("Reading agent output failed: \(error.localizedDescription)"))
                }
                process.waitUntilExit()
                let errorText = await errorReader.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !finished || process.terminationStatus != 0 {
                    let summary = self.isCancelled ? "Cancelled" :
                        (errorText.isEmpty ? "Agent exited with status \(process.terminationStatus)" : String(errorText.suffix(2000)))
                    continuation.yield(.finished(summary: summary, isError: true, costUSD: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
            do {
                try process.run()
                if isCancelled { process.terminate() }
            } catch {
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                reader.cancel()
                continuation.yield(.finished(summary: error.localizedDescription, isError: true, costUSD: nil))
                continuation.finish()
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
}
