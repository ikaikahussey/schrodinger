import XCTest
import SwiftData
@testable import Schrodinger

/// Weaving an item and the items under it into one piece.
@MainActor
final class WeaveTests: XCTestCase {
    func makeContainer() throws -> ModelContainer {
        let schema = Schema([Node.self, Proposal.self, ActivityEntry.self, Digest.self, WorkspaceFile.self, HarnessRun.self, Attachment.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// The threads go to the model in outline order, numbered, each with the id its links use.
    func testThreadsAreGivenInOutlineOrder() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Essay")
        let a = s.create(title: "Opening", parentID: p.id); a.notes = "Start with the harbor."
        let b = s.create(title: "Middle", parentID: p.id); b.artifact = "Drafted middle."
        let b1 = s.create(title: "Detail", parentID: b.id)
        s.save()
        let m = WeaveBrief.material(root: p, store: s, budget: 120_000)
        XCTAssertEqual(m.count, 3)
        XCTAssertTrue(m.text.contains("1 [\(WeaveLinks.ref(a.id))] Opening\nNotes: Start with the harbor."))
        XCTAssertTrue(m.text.contains("2 [\(WeaveLinks.ref(b.id))] Middle\nResult:\nDrafted middle."))
        XCTAssertTrue(m.text.contains("2.1 [\(WeaveLinks.ref(b1.id))] Detail"))
        let order = ["Opening", "Middle", "Detail"].compactMap { m.text.range(of: $0)?.lowerBound }
        XCTAssertEqual(order, order.sorted())
        // Too much to read: what fits goes, and the rest is counted.
        let short = WeaveBrief.material(root: p, store: s, budget: 10)
        XCTAssertEqual(short.count, 1)
        XCTAssertTrue(short.text.contains("(2 more items were left out for length.)"))
        // Nothing under an item: nothing to weave.
        XCTAssertNil(WeaveBrief.make(nodeID: a.id, container: c))
        XCTAssertNotNil(WeaveBrief.make(nodeID: p.id, container: c))
    }

    /// The piece goes on the item with links to its threads; links to items that do not exist are taken out.
    func testPieceIsStoredWithLinksToItsThreads() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Essay")
        let a = s.create(title: "Opening", parentID: p.id)
        let b = s.create(title: "Middle", parentID: p.id)
        let b1 = s.create(title: "Detail", parentID: b.id)
        s.save()
        let state = p.stateRaw, holder = p.assigneeRaw
        let reply = "```markdown\n# Essay\n\nThe harbor opens it. [↗](item:\(WeaveLinks.ref(a.id)))\n\nA wrong one. [↗](item:DEADBEEF)\n\nSee [the middle](item:00000000) too.\n```"
        let piece = try XCTUnwrap(s.applyWeave(reply, to: p))
        XCTAssertEqual(p.artifact, piece)
        XCTAssertTrue(piece.hasPrefix("# Essay"))
        XCTAssertTrue(piece.contains("The harbor opens it. [↗](item:\(WeaveLinks.ref(a.id)))"))
        XCTAssertFalse(piece.contains("DEADBEEF"))
        XCTAssertTrue(piece.contains("A wrong one.\n"))
        XCTAssertTrue(piece.contains("See the middle too."))
        XCTAssertTrue(piece.contains("## Threads\n- [Opening](\(WeaveLinks.address(a.id)))\n- [Middle](\(WeaveLinks.address(b.id)))\n  - [Detail](\(WeaveLinks.address(b1.id)))"))
        XCTAssertEqual(p.stateRaw, state); XCTAssertEqual(p.assigneeRaw, holder)
        // Woven again: one list of threads, and the earlier text is kept for undo.
        let second = try XCTUnwrap(s.applyWeave("# Essay, again", to: p))
        XCTAssertEqual(second.components(separatedBy: WeaveLinks.listHeading).count, 2)
        XCTAssertTrue(s.activity(for: p.id).contains { $0.undo?["artifact"] as? String == piece })
        XCTAssertNil(s.applyWeave("  \n ", to: p))
        XCTAssertEqual(p.artifact, second)
    }

    /// A link in a piece leads to its item; other addresses are not item links.
    func testItemLinksResolve() throws {
        let a = UUID(), b = UUID()
        XCTAssertEqual(WeaveLinks.target(of: try XCTUnwrap(URL(string: WeaveLinks.address(a))), among: [b, a]), a)
        XCTAssertEqual(WeaveLinks.target(of: try XCTUnwrap(URL(string: WeaveLinks.address(a).lowercased())), among: [b, a]), a)
        XCTAssertNil(WeaveLinks.target(of: try XCTUnwrap(URL(string: "item:00000000")), among: [b, a]))
        XCTAssertNil(WeaveLinks.ref(in: try XCTUnwrap(URL(string: "https://example.org/item:12345678"))))
        XCTAssertEqual(WeaveLinks.clean("# T\n\nBody"), "# T\n\nBody")
        XCTAssertEqual(WeaveLinks.withoutThreadList("# T\n\nBody\n\n## Threads\n- [x](item:12345678)"), "# T\n\nBody")
    }

    /// The owner's comment and the earlier piece go into the next weave; the request has no tools.
    func testCommentGoesIntoTheNextWeave() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Essay"); p.goal = "For the newsletter, 800 words."
        _ = s.create(title: "Opening", parentID: p.id)
        s.applyWeave("# Essay\n\nFirst pass.", to: p)
        s.noteOnWeave(p, note: "Make it shorter")
        s.save()
        let brief = try XCTUnwrap(WeaveBrief.make(nodeID: p.id, container: c))
        XCTAssertTrue(brief.prompt.contains("For the newsletter, 800 words."))
        XCTAssertTrue(brief.prompt.contains("First pass."))
        XCTAssertTrue(brief.prompt.contains("Make it shorter"))
        XCTAssertFalse(brief.prompt.contains(WeaveLinks.listHeading))
        XCTAssertTrue(brief.system.contains("(item:ID)"))
        let body = ClaudeRequest.weaveBody(model: "m", system: brief.system, prompt: brief.prompt)
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["max_tokens"] as? Int, ClaudeRequest.weaveTokens)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(AgentJob(kind: .weave, nodeID: p.id, title: "Essay").failedLead, "The weave failed")
    }

    /// The owner edits the text directly: the edit is saved, a woven piece keeps its list of threads, and it can be undone.
    func testEditedTextIsSaved() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Essay")
        let a = s.create(title: "Opening", parentID: p.id)
        let first = try XCTUnwrap(s.applyWeave("# Essay\n\nFirst pass.", to: p))
        s.saveEditedResult(p, text: "# Essay\n\nMine now.\n")
        XCTAssertEqual(p.artifact, "# Essay\n\nMine now.\n\n## Threads\n- [Opening](\(WeaveLinks.address(a.id)))")
        XCTAssertTrue(s.activity(for: p.id).contains { $0.undo?["artifact"] as? String == first })
        s.saveEditedResult(p, text: "   ")
        XCTAssertTrue(p.artifact?.contains("Mine now.") ?? false, "an emptied text is not saved")
        // A result that is not a woven piece: the text as typed.
        a.artifact = "Old"
        s.saveEditedResult(a, text: "New")
        XCTAssertEqual(a.artifact, "New")
    }
}
