import Foundation
import Testing
@testable import VintedCore

@Test func parsesSharedAgentEvents() {
    let lines = [
        #"{"type":"started","session_id":"s1","model":"sonnet"}"#,
        #"{"type":"tool","name":"Read","detail":"listing.md"}"#,
        #"{"type":"message","text":"Hallo"}"#,
        #"{"type":"finished","summary":"Hallo","is_error":false,"cost_usd":0.01544}"#,
    ]
    #expect(lines.compactMap(AgentEvent.parse) == [
        .started(sessionID: "s1", model: "sonnet"),
        .tool(name: "Read", detail: "listing.md"),
        .message("Hallo"),
        .finished(summary: "Hallo", isError: false, costUSD: 0.01544),
    ])
}

@Test func buildsAgentCLICommands() {
    #expect(AgentRun.arguments(kind: .claude, task: .clusterPhotos(["inbox/front.HEIC", "inbox/back.HEIC"])) ==
            ["agent", "run", "cluster", "inbox/front.HEIC", "inbox/back.HEIC", "--provider", "claude", "--json"])
    #expect(AgentRun.arguments(kind: .claude, task: .processInbox) ==
            ["agent", "run", "inbox", "--provider", "claude", "--json"])
    #expect(AgentRun.arguments(kind: .codex, task: .recheckPrice(itemID: "0004", title: "Cargohose")) ==
            ["agent", "run", "price", "0004", "--provider", "codex", "--json"])
    #expect(AgentRun.arguments(kind: .codex, task: .draftListing(group: "jacke", photos: [])) ==
            ["agent", "run", "draft", "jacke", "--provider", "codex", "--json"])
}
