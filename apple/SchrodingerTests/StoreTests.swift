import XCTest
import SwiftData
@testable import Schrodinger

@MainActor
final class StoreTests: XCTestCase {
    func makeContainer() throws -> ModelContainer {
        let schema = Schema([Node.self, Proposal.self, ActivityEntry.self, Digest.self, WorkspaceFile.self, HarnessRun.self, Attachment.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    func testTreeProgressAndMoveGuard() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        let a = s.create(title: "A", parentID: p.id)
        let b = s.create(title: "B", parentID: p.id)
        let a1 = s.create(title: "A1", parentID: a.id)
        XCTAssertEqual(s.progress(of: p.id).total, 2)      // leaves: A1, B
        s.update(a1) { $0.state = .done }
        XCTAssertEqual(s.progress(of: p.id).pct, 50)
        try s.move(b, to: a.id, position: 0)
        XCTAssertEqual(s.children(of: a.id).map(\.title), ["B", "A1"])
        XCTAssertThrowsError(try s.move(a, to: a1.id, position: 0))
    }

    func testPruneDoneDatedRemovesOnlyOldCheckedLeaves() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        let due = Date()
        let oldDone = s.create(title: "old done", parentID: p.id, due: due)
        let newDone = s.create(title: "new done", parentID: p.id, due: due)
        let undated = s.create(title: "undated done", parentID: p.id)
        let open = s.create(title: "open dated", parentID: p.id, due: due)
        let parent = s.create(title: "dated parent", parentID: p.id, due: due)
        _ = s.create(title: "child", parentID: parent.id)
        for n in [oldDone, newDone, undated, parent] { s.update(n) { $0.state = .done } }
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86400)
        for n in [oldDone, undated, open, parent] { n.updatedAt = tenDaysAgo }
        XCTAssertEqual(s.pruneDoneDated(olderThan: 7), 1)
        XCTAssertEqual(Set(s.children(of: p.id).map(\.title)), ["new done", "undated done", "open dated", "dated parent"])
    }

    func testDeleteKeepingChildrenMovesThemUp() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        let a = s.create(title: "A", parentID: p.id, position: 0)
        _ = s.create(title: "A1", parentID: a.id, position: 0)
        let a2 = s.create(title: "A2", parentID: a.id, position: 1)
        _ = s.create(title: "A2x", parentID: a2.id)
        _ = s.create(title: "B", parentID: p.id, position: 1)
        s.delete(a, keepChildren: true)
        XCTAssertEqual(s.children(of: p.id).map(\.title), ["A1", "A2", "B"])
        XCTAssertEqual(s.children(of: a2.id).map(\.title), ["A2x"])
        let b = s.children(of: p.id).last!
        _ = s.create(title: "B1", parentID: b.id)
        s.delete(b, keepChildren: false)
        XCTAssertEqual(s.children(of: p.id).map(\.title), ["A1", "A2"])
        XCTAssertEqual(s.descendants(of: p.id).count, 3)
    }

    func testDeleteLeavesOneEntryPerDeletedItem() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        let a = s.create(title: "A", parentID: p.id)
        let a1 = s.create(title: "A1", parentID: a.id)
        s.update(a) { $0.title = "A renamed" }
        let ids = [a.id, a1.id]
        s.delete(a); s.save()
        for id in ids {
            let left = s.activity(for: id)
            XCTAssertEqual(left.map(\.action), [HistoryAction.delete])
        }
        XCTAssertEqual(s.activity(for: ids[0]).first?.detail, "A renamed")
        XCTAssertEqual(s.activity(for: ids[1]).first?.undo?["parent_id"] as? String, ids[0].uuidString)
        // Old entries are dropped after 90 days; recent ones stay.
        XCTAssertEqual(s.pruneHistory(olderThan: 90), 0)
        XCTAssertEqual(s.pruneHistory(olderThan: 90, now: Date().addingTimeInterval(91 * 86400)), 2)
    }

    func testReinstateBringsBackItemAndWhatWasDeletedWithIt() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        _ = s.create(title: "first", parentID: p.id)
        let a = s.create(title: "A", parentID: p.id)
        _ = s.create(title: "last", parentID: p.id)
        let early = s.create(title: "removed earlier", parentID: a.id)
        let a1 = s.create(title: "A1", parentID: a.id)
        let a1x = s.create(title: "A1x", parentID: a1.id)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        s.update(a) { $0.notes = "note"; $0.due = due; $0.state = .done; $0.assignee = .shared }
        let aID = a.id, a1ID = a1.id, a1xID = a1x.id, earlyID = early.id
        s.delete(early); s.save()
        // That one was removed a while before the rest.
        for e in s.activity(for: earlyID) { e.createdAt = Date().addingTimeInterval(-3600) }
        s.delete(a); s.save()
        XCTAssertEqual(s.children(of: p.id).map(\.title), ["first", "last"])
        // Deleted items show where they were, in order.
        let rows = s.history(since: Date().addingTimeInterval(-86400))
        XCTAssertEqual(rows.map(\.title), ["P", "first", "A", "removed earlier", "A1", "A1x", "last"])
        XCTAssertEqual(rows.first { $0.id == a1ID }?.parentID, aID)

        // Reinstating the child of a deleted item brings its parent back first, and what was under the child.
        let back = try XCTUnwrap(s.reinstate(a1ID)); s.save()
        XCTAssertEqual(back.id, a1ID)
        XCTAssertEqual(s.children(of: p.id).map(\.title), ["first", "A", "last"])
        let ra = try XCTUnwrap(s.node(aID))
        XCTAssertEqual(ra.notes, "note"); XCTAssertEqual(ra.due, due); XCTAssertEqual(ra.state, .done); XCTAssertEqual(ra.assignee, .shared)
        XCTAssertEqual(s.children(of: aID).map(\.title), ["A1"])
        XCTAssertEqual(s.children(of: a1ID).map(\.id), [a1xID])
        // The one removed earlier stays deleted, and can be brought back by itself.
        XCTAssertNil(s.node(earlyID))
        XCTAssertEqual(s.history(since: Date().addingTimeInterval(-86400)).filter(\.deleted).map(\.title), ["removed earlier"])
        XCTAssertNotNil(s.reinstate(earlyID)); s.save()
        XCTAssertEqual(s.children(of: aID).map(\.title), ["removed earlier", "A1"])
        XCTAssertTrue(s.history(since: Date().addingTimeInterval(-86400)).allSatisfy { !$0.deleted })
        XCTAssertNil(s.reinstate(UUID()))
    }

    func testHistoryMarksAddedDeletedRenamedCompleted() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let longAgo = Date().addingTimeInterval(-30 * 86400)
        let p = s.create(title: "P")
        let keep = s.create(title: "keep", parentID: p.id)
        let rename = s.create(title: "old name", parentID: p.id)
        let finish = s.create(title: "finish", parentID: p.id)
        let gone = s.create(title: "gone", parentID: p.id)
        let goneChild = s.create(title: "gone child", parentID: gone.id)
        let goneID = gone.id, goneChildID = goneChild.id
        // Everything so far happened a month ago.
        for n in [p, keep, rename, finish, gone, goneChild] { n.createdAt = longAgo }
        for e in s.recentActivity(limit: 1000) { e.createdAt = longAgo }
        s.save()
        let since = Date().addingTimeInterval(-86400)

        s.update(rename) { $0.title = "new name" }
        s.update(finish) { $0.state = .done }
        s.delete(gone)
        let fresh = s.create(title: "fresh", parentID: p.id)
        let blank = s.create(title: "", parentID: p.id)
        s.delete(blank)   // typed nothing, removed: leaves no trace
        s.save()

        let rows = s.history(since: since)
        XCTAssertEqual(rows.map(\.title), ["P", "keep", "new name", "finish", "gone", "gone child", "fresh"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 1, 1, 2, 1])
        func row(_ id: UUID) -> HistoryRow { rows.first { $0.id == id }! }
        XCTAssertTrue(row(p.id).changes.isEmpty)
        XCTAssertTrue(row(keep.id).changes.isEmpty)
        XCTAssertEqual(row(rename.id).changes, [.renamed]); XCTAssertEqual(row(rename.id).oldTitle, "old name")
        XCTAssertEqual(row(finish.id).changes, [.completed]); XCTAssertTrue(row(finish.id).done)
        XCTAssertEqual(row(goneID).changes, [.deleted]); XCTAssertTrue(row(goneID).deleted)
        XCTAssertTrue(row(goneChildID).deleted)
        XCTAssertEqual(row(fresh.id).changes, [.added])
        XCTAssertEqual(HistoryRow.summary(rows), "1 added · 2 deleted · 1 renamed · 1 completed")

        // Changes only: unchanged items go, except those holding a changed item.
        XCTAssertEqual(s.history(since: since, changesOnly: true).map(\.title), ["P", "new name", "finish", "gone", "gone child", "fresh"])
        // Nothing happened in the last minute of a period that starts in the future.
        XCTAssertTrue(s.history(since: Date().addingTimeInterval(60), changesOnly: true).isEmpty)
    }

    /// A handed-off item, with a model that runs in the app (the mock): the draft comes back for review; a shared
    /// item becomes the owner's turn; review notes go into the redo.
    func testInProcessHandoffWithMockProvider() async throws {
        AppSettings.shared.provider = .mock
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P"); p.goal = "ship"
        let ai = s.create(title: "first", parentID: p.id, assignee: .ai)
        let sh = s.create(title: "Meet funder #meeting", parentID: p.id, assignee: .shared)
        let hum = s.create(title: "human thing", parentID: p.id, assignee: .human)
        s.save()
        XCTAssertTrue(ProjectAgent.aiTurn(ai)); XCTAssertTrue(ProjectAgent.aiTurn(sh)); XCTAssertFalse(ProjectAgent.aiTurn(hum))
        let r = try await InProcessAgent.handoff(nodeID: ai.id, container: c, provider: MockProvider())
        XCTAssertFalse(r.done, "an in-app draft goes to the owner for review")
        XCTAssertEqual(s.applyHandoff(r, to: ai), .needsYou)
        XCTAssertEqual(ai.state, .review)
        XCTAssertFalse(ProjectAgent.aiTurn(ai), "nothing left to hand off on a drafted item")
        XCTAssertEqual(hum.state, .unset)
        let r2 = try await InProcessAgent.handoff(nodeID: sh.id, container: c, provider: MockProvider())
        XCTAssertEqual(s.applyHandoff(r2, to: sh), .yourTurn)
        XCTAssertEqual(sh.state, .in_progress); XCTAssertEqual(sh.aiStatus, .done); XCTAssertTrue(sh.isYourTurn)
        XCTAssertTrue(s.byTag(assignee: .human).contains { $0.tag == "#meeting" && $0.tasks.contains { $0.0.id == sh.id } })
        // reject with note → redo includes the note
        try s.reject(ai, note: "make it shorter")
        let r3 = try await InProcessAgent.handoff(nodeID: ai.id, container: c, provider: MockProvider())
        s.applyHandoff(r3, to: ai)
        XCTAssertTrue(ai.artifact?.contains("make it shorter") ?? false)
        try s.approve(ai)
        XCTAssertEqual(ai.state, .done)
        // send shared back → the AI's part is pending again
        try s.sendBackToAI(sh, note: "add parking")
        XCTAssertEqual(sh.aiStatus, .pending)
        let r4 = try await InProcessAgent.handoff(nodeID: sh.id, container: c, provider: MockProvider())
        s.applyHandoff(r4, to: sh)
        XCTAssertEqual(sh.aiStatus, .done); XCTAssertTrue(sh.artifact?.contains("add parking") ?? false)
        // Opening Digest writes the digest.
        try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).writeDigest()
        XCTAssertFalse(s.digests(for: p.id).isEmpty)
    }

    /// Nothing looks over the outline on its own: writing the digest files no notices and adds no items.
    func testDigestFilesNoNoticesOrTasks() async throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Quiet")
        let old = s.create(title: "Untouched for a month", parentID: p.id)
        old.lastActivityAt = Date().addingTimeInterval(-30 * 86400)
        s.save()
        try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).writeDigest()
        XCTAssertTrue(s.inbox().isEmpty)
        XCTAssertEqual(s.children(of: p.id).count, 1)
        // Notices filed by an earlier version are closed at launch; suggestions asked for on an item are kept.
        s.propose(projectID: p.id, nodeID: old.id, type: .stale, summary: "old notice")
        s.propose(projectID: p.id, nodeID: old.id, type: .note, summary: "Add", payload: ["text": "x"])
        s.dismissAutomaticNotices()
        XCTAssertEqual(s.inbox().map(\.type), [.note])
    }

    /// The line an item's row shows for its hand-off.
    func testJobStatusLine() {
        var j = AgentJob(kind: .handoff, title: "Find the deadline")
        XCTAssertTrue(j.statusLine.hasPrefix("Waiting for the AI"))
        j.status = .working; j.route = .inProcess
        XCTAssertEqual(j.statusLine, "The AI is working on this. Keep the app open.")
        j.route = .background
        XCTAssertEqual(j.statusLine, "The AI is working on this")
        j.continuations = 2
        XCTAssertTrue(j.statusLine.contains("still going"))
        j.status = .needsYou; j.summary = "Which year?"
        XCTAssertEqual(j.statusLine, "Needs you: Which year?")
        j.status = .done; j.summary = "Due March 3."
        XCTAssertEqual(j.statusLine, "AI: Due March 3.")
        j.status = .failed; j.error = "No API key. Add one in Settings."
        XCTAssertEqual(j.statusLine, "The hand-off failed: No API key. Add one in Settings.")
    }

    /// The local model server's wire format: its address, tool calls with text or object arguments, hidden reasoning.
    func testLocalProviderWireFormat() {
        XCTAssertEqual(LocalProvider.url("", "/models")?.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertEqual(LocalProvider.url("localhost:1234/", "/chat/completions")?.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(LocalProvider.url("http://127.0.0.1:8080/v1", "/models")?.absoluteString, "http://127.0.0.1:8080/v1/models")
        let reply = JSONText.decode(#"""
            {"choices": [{"message": {"role": "assistant", "content": "<think>hmm</think>\n Draft. ", "tool_calls": [
              {"id": "a1", "type": "function", "function": {"name": "web_fetch", "arguments": "{\"url\":\"https://example.org\"}"}},
              {"type": "function", "function": {"name": "finish", "arguments": {"artifact": "Done"}}},
              {"type": "function", "function": {"name": ""}}]}}]}
            """#)
        let msg = LocalProvider.message(of: reply)
        XCTAssertEqual(LocalProvider.text(of: msg), "Draft.")
        let calls = LocalProvider.toolCalls(of: msg)
        XCTAssertEqual(calls.map(\.name), ["web_fetch", "finish"])
        XCTAssertEqual(calls[0].input["url"] as? String, "https://example.org")
        XCTAssertEqual(calls[1].id, "call_1"); XCTAssertEqual(calls[1].input["artifact"] as? String, "Done")
        XCTAssertTrue(LocalProvider.toolCalls(of: [:]).isEmpty)
        #if os(macOS)
        XCTAssertTrue(ProviderKind.offered.contains(.local))
        #else
        XCTAssertFalse(ProviderKind.offered.contains(.local))
        #endif
    }

    /// What the model hands in is read defensively and applied to the item as in-app changes.
    func testHandoffResultIsParsedAndApplied() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Grant")
        let t = s.create(title: "Find the deadline", parentID: p.id, assignee: .ai)
        let r = HandoffResult.parse([
            "summary": " Found it. ", "result_markdown": "Due March 3.", "done": true,
            "child_items": [["title": "Email the program officer", "assignee": "human", "due": "2027-03-01", "notes": "Ask about page limits"],
                            ["title": "  ", "assignee": "ai"], ["title": "Draft the budget", "assignee": "nobody"]],
            "notes_append": "Deadline: March 3", "links": ["https://example.org/rfp", "not a link"], "questions": []])
        XCTAssertEqual(r.summary, "Found it.")
        XCTAssertEqual(r.children.map(\.title), ["Email the program officer", "Draft the budget"])
        XCTAssertEqual(r.children.map(\.assignee), [.human, .human])
        XCTAssertNotNil(r.children[0].due)
        XCTAssertNil(HandoffResult.day("soon"))
        XCTAssertEqual(s.applyHandoff(r, to: t), .done)
        XCTAssertEqual(t.artifact, "Due March 3.")
        XCTAssertEqual(t.notes, "Deadline: March 3")
        XCTAssertEqual(s.children(of: t.id).map(\.title), ["Email the program officer", "Draft the budget"])
        XCTAssertEqual(s.children(of: t.id).first?.notes, "Ask about page limits")
        XCTAssertEqual(s.attachments(for: t.id).map(\.urlString), ["https://example.org/rfp"])
        XCTAssertEqual(t.state, .in_progress, "finished, but with follow-up steps under it, the item stays open")
        // Applying the same result again adds nothing twice.
        s.applyHandoff(r, to: t)
        XCTAssertEqual(s.children(of: t.id).count, 2)
        XCTAssertEqual(s.attachments(for: t.id).count, 1)
        // Finished with nothing left: done. Questions: back to the owner, listed on the item.
        let plain = s.create(title: "Look up the address", parentID: p.id, assignee: .ai)
        XCTAssertEqual(s.applyHandoff(HandoffResult(summary: "ok", markdown: "1 Main St", done: true), to: plain), .done)
        XCTAssertEqual(plain.state, .done)
        let asks = s.create(title: "Book the room", parentID: p.id, assignee: .ai)
        XCTAssertEqual(s.applyHandoff(HandoffResult(markdown: "Options", done: true, questions: ["Which day?"]), to: asks), .needsYou)
        XCTAssertEqual(asks.state, .review)
        XCTAssertTrue(asks.artifact?.contains("Which day?") ?? false)
    }

    /// The reply to a hand-off request: the tool call is the result; a paused turn is continued; text is a fallback.
    func testClaudeRepliesAreRead() throws {
        let body = ClaudeRequest.handoffBody(model: "m", system: "s", prompt: "p", serverTools: true)
        XCTAssertTrue(ClaudeRequest.hasServerTools(body))
        let bare = ClaudeRequest.withoutServerTools(body)
        XCTAssertFalse(ClaudeRequest.hasServerTools(bare))
        XCTAssertEqual((bare["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, [ClaudeRequest.submitResult])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ClaudeRequest.suggestBody(model: "m", system: "s", prompt: "p")))

        let done: [String: Any] = ["stop_reason": "tool_use", "content": [["type": "text", "text": "Handing in."],
            ["type": "tool_use", "id": "t1", "name": ClaudeRequest.submitResult, "input": ["summary": "x", "result_markdown": "y", "done": true]]]]
        guard case .tool(let name, let input) = ClaudeRequest.interpret(done) else { return XCTFail("expected the tool call") }
        XCTAssertEqual(name, ClaudeRequest.submitResult)
        XCTAssertTrue(HandoffResult.parse(input).done)

        let paused: [String: Any] = ["stop_reason": "pause_turn", "content": [["type": "server_tool_use", "id": "s1", "name": "web_search", "input": ["query": "q"]]]]
        guard case .paused(let content) = ClaudeRequest.interpret(paused) else { return XCTFail("expected a paused turn") }
        let next = ClaudeRequest.continued(body, assistantContent: content)
        XCTAssertEqual((next["messages"] as? [[String: Any]])?.map { $0["role"] as? String }, ["user", "assistant"])

        guard case .text(let text) = ClaudeRequest.interpret(["stop_reason": "end_turn", "content": [["type": "text", "text": "Just "], ["type": "text", "text": "text."]]]) else { return XCTFail("expected text") }
        XCTAssertEqual(text, "Just text.")
        guard case .empty = ClaudeRequest.interpret([:]) else { return XCTFail("expected nothing") }
        XCTAssertEqual(ClaudeRequest.errorMessage(["error": ["message": "bad key"]]), "bad key")
    }

    /// Recommended tasks: filed under the item the model names, never twice, never a task the outline already has.
    func testRecommendedTasksAreFiledOnceAndAcceptAddsThem() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Grant"); p.goal = "Win the grant"
        let a = s.create(title: "Write narrative", parentID: p.id)
        s.save()
        let outline = SuggestBrief.outline(store: s)
        XCTAssertTrue(outline.contains("[\(a.id.uuidString.prefix(8))] Write narrative"))
        XCTAssertTrue(outline.contains("goal: Win the grant"))
        let pid = String(a.id.uuidString.prefix(8))
        let items: [[String: Any]] = [
            ["parent_id": pid, "title": "Collect letters of support", "assignee": "human", "reason": "The narrative cites them."],
            ["parent_id": "[\(pid.lowercased())]", "title": "collect letters of support!", "assignee": "ai", "reason": "again"],
            ["parent_id": pid, "title": "Write Narrative", "assignee": "ai", "reason": "already there"],
            ["parent_id": "00000000", "title": "Nowhere", "assignee": "ai", "reason": "no such item"]]
        XCTAssertEqual(SuggestBrief.file(items, store: s), 1)
        let g = try XCTUnwrap(s.openSuggestions().first)
        XCTAssertEqual(s.suggestionParent(of: g), a.id)
        XCTAssertTrue(s.children(of: a.id).isEmpty, "nothing is added until it is kept")
        try s.accept(g)
        XCTAssertEqual(s.children(of: a.id).map(\.title), ["Collect letters of support"])
        XCTAssertEqual(s.children(of: a.id).first?.assignee, .human)
        XCTAssertEqual(SuggestBrief.file(items, store: s), 0, "kept or dismissed, it is not recommended again")
        XCTAssertEqual(SuggestBrief.parse("Here: [{\"title\": \"x\"}] ok").count, 1)
    }

    func testTagsAreDetected() throws {
        XCTAssertEqual(Tags.hashtags(in: "Call the #Funder about #q3-budget, then #done."), ["funder", "q3-budget", "done"])
        XCTAssertEqual(Tags.hashtags(in: "no tags here # alone"), [])
        XCTAssertEqual(Tags.hashtags(in: "#a#b"), ["a", "b"])
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P #client"); p.goal = "ship #Q3"
        let t = s.create(title: "Draft letter #urgent #write", parentID: p.id); t.notes = "see #legal"
        XCTAssertEqual(p.tags, ["client", "q3"])
        XCTAssertEqual(t.tags, ["urgent", "legal", "write"])
    }

    func testAttachments() throws {
        XCTAssertEqual(Attachment.normalizedURL(" example.com/page ")?.absoluteString, "https://example.com/page")
        XCTAssertEqual(Attachment.normalizedURL("http://www.capitol.hawaii.gov/x?y=1")?.absoluteString, "http://www.capitol.hawaii.gov/x?y=1")
        XCTAssertNil(Attachment.normalizedURL("not a link"))
        XCTAssertNil(Attachment.normalizedURL("localhost"))
        XCTAssertNil(Attachment.normalizedURL("ftp://example.com/file"))
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P"); let t = s.create(title: "t", parentID: p.id)
        XCTAssertNil(s.addLink("nope", to: t.id))
        let link = try XCTUnwrap(s.addLink("www.example.org/a", to: t.id))
        XCTAssertEqual(link.displayTitle, "example.org")
        s.addPhoto(Data([1, 2, 3]), to: t.id)
        s.save()
        XCTAssertEqual(s.attachments(for: t.id).map(\.kind), [.link, .photo])
        s.delete(p); s.save()   // deleting an item removes the attachments of everything under it
        XCTAssertTrue(s.attachments(for: t.id).isEmpty)
    }

    func testItemLinks() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        let a = s.create(title: "a", parentID: p.id), b = s.create(title: "b", parentID: p.id), x = s.create(title: "x", parentID: p.id)
        XCTAssertNil(s.link(a.id, a.id))            // not to itself
        XCTAssertNil(s.link(a.id, UUID()))          // not to an item that does not exist
        let l = try XCTUnwrap(s.link(a.id, b.id))
        XCTAssertEqual(s.link(b.id, a.id)?.id, l.id)   // already linked, from either side: no second link
        s.link(x.id, a.id); s.save()
        XCTAssertEqual(s.linkedItems(of: a.id).map(\.title), ["b", "x"])
        XCTAssertEqual(s.linkedItems(of: b.id).map(\.title), ["a"])   // seen from both items
        XCTAssertTrue(s.attachments(for: a.id).isEmpty)                // links are not photos or web links
        s.unlink(b.id, a.id); s.save()
        XCTAssertEqual(s.linkedItems(of: a.id).map(\.title), ["x"])
        XCTAssertTrue(s.linkedItems(of: b.id).isEmpty)
        s.delete(x); s.save()   // deleting an item removes its links, whichever side made them
        XCTAssertTrue(s.itemLinks(of: a.id).isEmpty)
    }

    func testUndoAndPathJail() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P"); let t = s.create(title: "t", parentID: p.id, assignee: .ai)
        s.update(t, actor: .ai, detail: "draft") { $0.state = .review; $0.artifact = "x" }
        let a = try XCTUnwrap(s.activity(for: t.id).first)
        try s.applyUndo(a)
        XCTAssertEqual(t.state, .unset); XCTAssertNil(t.artifact)
        XCTAssertThrowsError(try AgentTools.safePathThrowing("../../etc/passwd"))
        XCTAssertThrowsError(try AgentTools.safePathThrowing("/tmp/x"))
        XCTAssertEqual(try AgentTools.safePathThrowing("notes/./a.md"), "notes/a.md")
    }

    func testListLinesBecomeItems() {
        XCTAssertEqual(ListText.item("- call the lab"), .init(indent: 0, title: "call the lab"))
        XCTAssertEqual(ListText.item("  2) [x] order film"), .init(indent: 2, title: "order film", done: true))
        XCTAssertNil(ListText.item("-5 degrees"))
        XCTAssertNil(ListText.item("3.5 hours"))
        XCTAssertNil(ListText.item("- "))
        // The line still being typed stays; finished list lines come out; other text stays.
        let live = ListText.extract(from: "thoughts\n- one\n* two\n- thr", includeLastLine: false)
        XCTAssertEqual(live.items.map(\.title), ["one", "two"])
        XCTAssertEqual(live.rest, "thoughts\n- thr")
        // Lines that were already in the notes are not taken.
        let kept = ListText.extract(from: "- old\n- new\n", includeLastLine: false, keeping: ["- old"])
        XCTAssertEqual(kept.items.map(\.title), ["new"])
        XCTAssertEqual(kept.rest, "- old\n")
    }

    func testLinksComeOutOfText() {
        let r = LinkText.extract(from: "Read https://example.org/a?b=1, then update README.md and www.example.com.")
        XCTAssertEqual(r.links, ["https://example.org/a?b=1", "www.example.com"])
        XCTAssertEqual(r.rest, "Read then update README.md and")
        XCTAssertEqual(LinkText.extract(from: "no links here").rest, "no links here")
    }

    func testImportTextNestsListsUnderLines() throws {
        let note = """
        Campaign plan
        # Goals
        How do we get there
        - knock doors
          - Kailua
          ◦ Kaneohe
        - [x] file papers
        ## Principles
        Listen first
        """
        let e = Importer.parse(text: note)
        XCTAssertEqual(e.map(\.title), ["Campaign plan", "Goals", "How do we get there", "knock doors", "Kailua", "Kaneohe", "file papers", "Principles", "Listen first"])
        XCTAssertEqual(e.map(\.depth), [0, 0, 1, 2, 3, 3, 2, 1, 2])
        XCTAssertTrue(e[6].done)

        let c = try makeContainer(); let s = Store(c.mainContext)
        let top = Importer.importNote("Trip\n- pack\n  - socks\n- book", under: nil, store: s)
        XCTAssertEqual(s.node(top)?.title, "Trip")
        let kids = s.children(of: top)
        XCTAssertEqual(kids.map(\.title), ["pack", "book"])
        XCTAssertEqual(s.children(of: kids[0].id).map(\.title), ["socks"])
    }

    func testExportRoundTrips() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let top = s.create(title: "Shoot")
        s.update(top) { $0.notes = "film, \"lights\"" }
        let a = s.create(title: "Buy film", parentID: top.id, due: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        s.update(a) { $0.state = .done; $0.notes = "400 speed" }
        _ = s.create(title: "Kodak", parentID: a.id)
        s.save()
        for viaCSV in [false, true] {
            let id = viaCSV
                ? Importer.insert(Importer.parse(csv: Exporter.csv(top.id, store: s)), title: "copy", under: nil, store: s)
                : Importer.importNote(Exporter.text(top.id, store: s), under: nil, store: s)
            // CSV rows include the exported item itself (depth 0), under the new "copy" item.
            let root = viaCSV ? s.children(of: id)[0] : s.node(id)!
            XCTAssertEqual(root.title, "Shoot")
            XCTAssertEqual(root.notes, "film, \"lights\"")
            let kid = s.children(of: root.id)[0]
            XCTAssertEqual(kid.title, "Buy film")
            XCTAssertEqual(kid.notes, "400 speed")
            XCTAssertEqual(kid.state, .done)
            XCTAssertEqual(kid.due, a.due)
            XCTAssertEqual(s.children(of: kid.id).map(\.title), ["Kodak"])
        }
    }

    func testOutlineFileRoundTripsAndReplaces() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let top = s.create(title: "Shoot")
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1))
        let a = s.create(title: "Buy film", parentID: top.id, assignee: .ai, due: due)
        s.update(a) { $0.state = .review; $0.notes = "400 speed #errand"; $0.artifact = "Found three shops."; $0.collapsed = true }
        let a1 = s.create(title: "Kodak", parentID: a.id)
        let b = s.create(title: "Scout", parentID: top.id)
        s.update(b) { $0.deps = [a.id] }
        let other = s.create(title: "Taxes")
        s.addLink("example.com/film", to: a.id)
        s.addPhoto(Data([1, 2, 3]), to: a1.id)
        s.link(b.id, other.id)
        s.save()

        let file = OutlineFile.snapshot(s)
        XCTAssertEqual(file.items.map(\.title), ["Shoot", "Buy film", "Kodak", "Scout", "Taxes"])   // outline order
        let read = try OutlineFile.read(file.data())
        XCTAssertEqual(read, file)

        // Into a store that holds a different outline: that one goes, this one comes in as it was.
        let c2 = try makeContainer(); let s2 = Store(c2.mainContext)
        let gone = s2.create(title: "Old")
        s2.create(title: "Old child", parentID: gone.id)
        s2.addLink("example.com/old", to: gone.id)
        s2.save()
        XCTAssertEqual(read.load(into: s2), 5)
        XCTAssertEqual(s2.children(of: nil).map(\.title), ["Shoot", "Taxes"])
        XCTAssertEqual(s2.allNodes().count, 5)
        XCTAssertEqual(s2.children(of: top.id).map(\.title), ["Buy film", "Scout"])
        let a2 = try XCTUnwrap(s2.node(a.id))
        XCTAssertEqual(a2.state, .review)
        XCTAssertEqual(a2.assignee, .ai)
        XCTAssertEqual(a2.due, due)
        XCTAssertEqual(a2.notes, "400 speed #errand")
        XCTAssertEqual(a2.artifact, "Found three shops.")
        XCTAssertTrue(a2.collapsed)
        XCTAssertEqual(s2.children(of: a.id).map(\.title), ["Kodak"])
        XCTAssertEqual(s2.node(b.id)?.deps, [a.id])
        XCTAssertEqual(s2.attachments(for: a.id).map(\.urlString), ["https://example.com/film"])
        XCTAssertEqual(s2.attachments(for: a1.id).first?.data, Data([1, 2, 3]))
        XCTAssertEqual(s2.linkedItems(of: b.id).map(\.title), ["Taxes"])
        XCTAssertTrue(s2.attachments(for: gone.id).isEmpty)
        XCTAssertTrue(s2.recentActivity().isEmpty)
        // Saving what was loaded gives the same outline; loading it over itself changes nothing.
        XCTAssertEqual(OutlineFile.snapshot(s2).items, file.items)
        read.load(into: s2)
        XCTAssertEqual(OutlineFile.snapshot(s2).items, file.items)
        XCTAssertEqual(OutlineFile.snapshot(s2).attachments.count, 3)
    }

    func testOutlineFileReadsShortFilesAndRefusesOthers() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = UUID(), k = UUID()
        // Written by hand: titles and parents only. A parent that is missing or comes later leaves the item top-level.
        let json = """
        {"format": "schrodinger-outline", "items": [
          {"id": "\(p.uuidString)", "title": "Trip"},
          {"id": "\(k.uuidString)", "parentID": "\(p.uuidString)", "title": "Book flights", "state": "done"},
          {"parentID": "\(p.uuidString)", "title": "Pack"},
          {"parentID": "\(UUID().uuidString)", "title": "Stray"}
        ]}
        """
        let file = try OutlineFile.read(Data(json.utf8))
        XCTAssertEqual(file.load(into: s), 4)
        XCTAssertEqual(s.children(of: nil).map(\.title), ["Trip", "Stray"])
        XCTAssertEqual(s.children(of: p).map(\.title), ["Book flights", "Pack"])
        XCTAssertEqual(s.node(k)?.state, .done)

        XCTAssertThrowsError(try OutlineFile.read(Data("{\"items\": []}".utf8)))
        XCTAssertThrowsError(try OutlineFile.read(Data("Title,Notes\nA,B\n".utf8)))
        XCTAssertThrowsError(try OutlineFile.read(Data("{\"format\": \"schrodinger-outline\", \"version\": 99, \"items\": []}".utf8))) {
            XCTAssertEqual($0.localizedDescription, OutlineFile.Failure.newer.localizedDescription)
        }
    }

    func testModesBecomeTags() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        let a = s.create(title: "Call the lab", parentID: p.id); a.modeRaw = "call"
        let b = s.create(title: "Write it", parentID: p.id); b.notes = "draft"; b.modeRaw = "write"
        s.save()
        s.migrateModesToTags()
        XCTAssertEqual(a.notes, "#call"); XCTAssertEqual(a.modeRaw, "")
        XCTAssertEqual(b.notes, "draft\n#write")
        XCTAssertEqual(a.tags, ["call"])
    }

    func testImportCSV() {
        let csv = "Title,Notes,Due,Done,Parent\nShoot,\"film, lights\",2026-12-01,,\nBuy film,\"say \"\"400\"\"\",,yes,Shoot\n"
        let e = Importer.parse(csv: csv)
        XCTAssertEqual(e.map(\.title), ["Shoot", "Buy film"])
        XCTAssertEqual(e.map(\.depth), [0, 1])
        XCTAssertEqual(e[0].notes, "film, lights")
        XCTAssertEqual(e[1].notes, "say \"400\"")
        XCTAssertNotNil(e[0].due)
        XCTAssertTrue(e[1].done)
        // No header: first column title, second notes.
        XCTAssertEqual(Importer.parse(csv: "a,x\nb,y").map(\.notes), ["x", "y"])
    }

    func testItemAdvisorFilesSuggestionsAndAcceptApplies() async throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        let t = s.create(title: "Book the studio and order film", parentID: p.id, assignee: .human)
        let added = try await ItemAdvisor.advise(nodeID: t.id, container: c, provider: MockProvider())
        XCTAssertGreaterThan(added, 0)
        let split = try XCTUnwrap(s.inbox().first { $0.type == .decompose && $0.nodeID == t.id })
        try s.accept(split)
        XCTAssertEqual(s.children(of: t.id).map(\.title), ["Book the studio", "order film"])
        // Asking again raises nothing that was already raised.
        let again = try await ItemAdvisor.advise(nodeID: t.id, container: c, provider: MockProvider())
        XCTAssertEqual(again, 0)
        // Model output is checked before it is filed; accepting applies it.
        let (type, summary, payload) = try XCTUnwrap(ItemAdvisor.validated(["type": "retitle", "summary": "Clearer", "payload": ["title": "Book studio"]], for: t))
        let r = try XCTUnwrap(s.propose(projectID: p.id, nodeID: t.id, type: type, summary: summary, payload: payload))
        try s.accept(r)
        XCTAssertEqual(t.title, "Book studio")
        XCTAssertNil(ItemAdvisor.validated(["type": "retitle", "summary": "Same", "payload": ["title": "Book studio"]], for: t))
        let note = try XCTUnwrap(s.propose(projectID: p.id, nodeID: t.id, type: .note, summary: "Add", payload: ["text": "Done = confirmed booking"]))
        try s.accept(note)
        XCTAssertEqual(t.notes, "Done = confirmed booking")
    }

    func testSavedViewsSaveReplaceRenameDelete() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P")
        XCTAssertTrue(s.savedViews().isEmpty)
        XCTAssertNil(s.saveView(name: "  ", search: "x", filter: "all", tag: nil, zoomID: nil))
        let calls = try XCTUnwrap(s.saveView(name: "Calls", search: " #call  bob ", filter: "mine", tag: nil, zoomID: p.id))
        let week = try XCTUnwrap(s.saveView(name: "Week", search: "", filter: "week", tag: "errand", zoomID: nil))
        s.save()
        XCTAssertEqual(s.savedViews().map(\.name), ["Calls", "Week"])
        XCTAssertEqual(s.savedViews()[0], SavedView(id: calls.id, name: "Calls", search: "#call  bob", filter: "mine", zoomID: p.id, position: 0))
        // Same name, any case: replaced in place.
        let again = try XCTUnwrap(s.saveView(name: "calls", search: "alice", filter: "all", tag: nil, zoomID: nil))
        s.save()
        XCTAssertEqual(again.id, calls.id)
        XCTAssertEqual(s.savedViews().map(\.name), ["calls", "Week"])
        XCTAssertEqual(s.savedViews()[0].search, "alice")
        XCTAssertNil(s.savedViews()[0].zoomID)
        // Rename: not to blank, not to a name in use.
        XCTAssertFalse(s.renameView(week.id, to: "CALLS"))
        XCTAssertFalse(s.renameView(week.id, to: " "))
        XCTAssertTrue(s.renameView(week.id, to: "This week"))
        s.save()
        XCTAssertEqual(s.savedViews().map(\.name), ["calls", "This week"])
        s.deleteView(calls.id); s.save()
        XCTAssertEqual(s.savedViews().map(\.id), [week.id])
        // Saved views are not project files, and project files are not saved views.
        s.writeFile(p.id, "views/notes.json", "{}"); s.save()
        XCTAssertEqual(s.savedViews().count, 1)
        XCTAssertEqual(s.files(for: p.id).count, 1)
    }

    func testSavedViewMatchingNamingAndDecoding() throws {
        let z = UUID()
        let v = SavedView(name: "V", search: "Bob  #Call", filter: "mine", tag: "x", zoomID: z)
        XCTAssertTrue(v.matches(search: " bob #call ", filter: "mine", tag: "x", zoomID: z))
        XCTAssertFalse(v.matches(search: "bob", filter: "mine", tag: "x", zoomID: z))
        XCTAssertFalse(v.matches(search: "bob #call", filter: "all", tag: "x", zoomID: z))
        XCTAssertFalse(v.matches(search: "bob #call", filter: "mine", tag: "x", zoomID: nil))
        XCTAssertTrue(SavedView.isPlain(search: " # ", filter: "all", tag: nil, zoomID: nil))
        XCTAssertFalse(SavedView.isPlain(search: "", filter: "all", tag: nil, zoomID: z))
        XCTAssertEqual(SavedView.suggestedName(search: " bob  #call ", filterLabel: "Mine", tag: "x", zoomTitle: "Campaign"), "Campaign \u{00B7} Mine \u{00B7} #x \u{00B7} bob #call")
        XCTAssertEqual(SavedView.suggestedName(search: "", filterLabel: nil, tag: nil, zoomTitle: nil), "")
        XCTAssertEqual(SavedView(json: v.json), v)
        // Keys missing from an older or newer build's record take defaults.
        let partial = try XCTUnwrap(SavedView(json: "{\"name\":\"N\",\"search\":\"q\"}"))
        XCTAssertEqual(partial.filter, "all")
        XCTAssertNil(partial.zoomID)
        XCTAssertNil(SavedView(json: "not json"))
    }
}

/// The glyphs in an item's mark (date, notes, links, photos): which ones an item has, and which fit.
final class MarkIndicatorTests: XCTestCase {
    func testPresentListsWhatTheItemHasInOrder() {
        XCTAssertEqual(MarkIndicator.present(hasDate: false, hasNotes: false, webLinks: 0, itemLinks: 0, photos: 0, checkable: false), [])
        XCTAssertEqual(MarkIndicator.present(hasDate: true, hasNotes: true, webLinks: 2, itemLinks: 1, photos: 3, checkable: false),
                       [.date, .note, .link, .itemLink, .photo])
        // The check box already says "dated": no date glyph beside it.
        XCTAssertEqual(MarkIndicator.present(hasDate: true, hasNotes: true, webLinks: 0, itemLinks: 1, photos: 0, checkable: true), [.note, .itemLink])
    }

    func testOnlyAsManyAsFitAreDrawn() {
        let all = MarkIndicator.allCases
        func fit(_ depth: Int, check: Bool = false, ai: Bool = false) -> [MarkIndicator] {
            MarkIndicator.fitting(all, width: Double(16 * (depth + 1)), cell: 16, checkable: check, aiGlyph: ai)
        }
        XCTAssertEqual(fit(0), [])                             // a circle is too short for a glyph
        XCTAssertEqual(fit(0, check: true), [])
        XCTAssertEqual(fit(0, ai: true), [])
        XCTAssertEqual(fit(1), [.date, .note])
        XCTAssertEqual(fit(1, check: true), [.date])
        XCTAssertEqual(fit(1, check: true, ai: true), [])
        XCTAssertEqual(fit(2), [.date, .note])                 // never more than two, however long the mark
        XCTAssertEqual(fit(2, check: true, ai: true), [.date])
        XCTAssertEqual(fit(4), [.date, .note])
        // The outline's mark is 40 wide.
        XCTAssertEqual(MarkIndicator.fitting(all, width: 40, cell: 16, checkable: false, aiGlyph: false), [.date, .note])
        XCTAssertEqual(MarkIndicator.fitting(all, width: 40, cell: 16, checkable: true, aiGlyph: false), [.date])
        XCTAssertEqual(MarkIndicator.fitting(all, width: 40, cell: 16, checkable: true, aiGlyph: true), [])
    }
}

final class DueLabelTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Pacific/Honolulu")!; return c }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testOverdue() {
        let now = at(2026, 11, 22, 15)
        XCTAssertTrue(at(2026, 11, 18).isOverdue(now: now, calendar: cal))
        XCTAssertFalse(at(2026, 11, 22).isOverdue(now: now, calendar: cal))        // all day today: not late until tomorrow
        XCTAssertFalse(at(2026, 11, 23).isOverdue(now: now, calendar: cal))
    }

    func testLabels() {
        let now = at(2026, 11, 22, 15)
        XCTAssertEqual(at(2026, 11, 18).dueLabel(now: now, calendar: cal), "4d late")
        XCTAssertEqual(at(2026, 11, 21).dueLabel(now: now, calendar: cal), "1d late")
        XCTAssertEqual(at(2026, 11, 22).dueLabel(now: now, calendar: cal), "Today")
        XCTAssertEqual(at(2026, 11, 23).dueLabel(now: now, calendar: cal), "Tomorrow")
    }

    func testResultFileNameAndContents() throws {
        XCTAssertEqual(ResultFile.filename(for: "Draft: memo to A/B\nteam"), "Draft memo to A B team.md")
        XCTAssertEqual(ResultFile.filename(for: "  "), "Result.md")
        XCTAssertEqual(ResultFile.filename(for: "..hidden"), "hidden.md")
        XCTAssertEqual(ResultFile.filename(for: String(repeating: "x", count: 200)).count, 83)
        let url = try ResultFile(title: "Plan", markdown: "# Plan\n\n- one").write()
        XCTAssertEqual(url.lastPathComponent, "Plan.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Plan\n\n- one")
    }
}
