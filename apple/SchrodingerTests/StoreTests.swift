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

    func testSharedAndAIFlowWithMockProvider() async throws {
        AppSettings.shared.provider = .mock
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P"); p.goal = "ship"
        let ai = s.create(title: "first", parentID: p.id, assignee: .ai)
        let dep = s.create(title: "second", parentID: p.id, assignee: .ai); dep.deps = [ai.id]
        let sh = s.create(title: "Meet funder #meeting", parentID: p.id, assignee: .shared)
        let hum = s.create(title: "human thing", parentID: p.id, assignee: .human)
        s.save()
        let out = try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).run()
        XCTAssertTrue(out.contains { $0.hasPrefix("drafted: first") })
        XCTAssertEqual(ai.state, .review)
        XCTAssertEqual(dep.state, .unset, "dependent task not picked up")
        XCTAssertEqual(hum.state, .unset)
        XCTAssertEqual(sh.state, .in_progress); XCTAssertEqual(sh.aiStatus, .done); XCTAssertTrue(sh.isYourTurn)
        XCTAssertTrue(s.byTag(assignee: .human).contains { $0.tag == "#meeting" && $0.tasks.contains { $0.0.id == sh.id } })
        // reject with note → redraft includes note
        try s.reject(ai, note: "make it shorter")
        _ = try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).run()
        XCTAssertTrue(ai.artifact?.contains("make it shorter") ?? false)
        try s.approve(ai)
        _ = try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).run()
        XCTAssertEqual(dep.state, .review)
        // send shared back → AI redoes once
        try s.sendBackToAI(sh, note: "add parking")
        XCTAssertEqual(sh.aiStatus, .pending)
        _ = try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).run()
        XCTAssertEqual(sh.aiStatus, .done); XCTAssertTrue(sh.artifact?.contains("add parking") ?? false)
        XCTAssertFalse(s.digests(for: p.id).isEmpty)
    }

    func testProposalsOnlyApplyOnAccept() async throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "Grant")
        let big = s.create(title: "Research rules and draft budget", parentID: p.id, assignee: .ai)
        let empty = s.create(title: "Empty")
        s.save()
        _ = try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).run()
        _ = try await ProjectAgent(container: c, projectID: empty.id, provider: MockProvider()).run()
        let inbox = s.inbox()
        let dec = try XCTUnwrap(inbox.first { $0.type == .decompose && $0.nodeID == big.id })
        let nt = try XCTUnwrap(inbox.first { $0.type == .new_task && $0.projectID == empty.id })
        XCTAssertTrue(s.children(of: big.id).isEmpty)
        try s.accept(dec)
        XCTAssertEqual(s.children(of: big.id).map(\.title), ["Research rules", "draft budget"])
        s.dismiss(nt)
        _ = try await ProjectAgent(container: c, projectID: empty.id, provider: MockProvider()).run()
        XCTAssertFalse(s.inbox().contains { $0.type == .new_task && $0.projectID == empty.id }, "dismissed proposals are not re-raised")
    }

    /// An item's play button runs only that item's AI work.
    func testRunScopedToOneItem() async throws {
        AppSettings.shared.provider = .mock
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P"); p.goal = "ship"
        let a = s.create(title: "one", parentID: p.id, assignee: .ai)
        let b = s.create(title: "two", parentID: p.id, assignee: .ai)
        s.save()
        XCTAssertTrue(ProjectAgent.aiTurn(a)); XCTAssertTrue(ProjectAgent.aiTurn(b))
        _ = try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider(), only: [a.id]).run()
        XCTAssertEqual(a.state, .review, "the chosen item was drafted")
        XCTAssertEqual(b.state, .unset, "other AI items were left alone")
        XCTAssertFalse(ProjectAgent.aiTurn(a), "nothing left to run on a drafted item")
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
}
