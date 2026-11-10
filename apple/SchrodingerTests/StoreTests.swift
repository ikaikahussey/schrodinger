import XCTest
import SwiftData
@testable import Schrodinger

@MainActor
final class StoreTests: XCTestCase {
    func makeContainer() throws -> ModelContainer {
        let schema = Schema([Node.self, Proposal.self, ActivityEntry.self, Digest.self, WorkspaceFile.self, HarnessRun.self])
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
        let sh = s.create(title: "Meet funder", parentID: p.id, assignee: .shared, mode: .meeting)
        let hum = s.create(title: "human thing", parentID: p.id, assignee: .human)
        s.save()
        let out = try await ProjectAgent(container: c, projectID: p.id, provider: MockProvider()).run()
        XCTAssertTrue(out.contains { $0.hasPrefix("drafted: first") })
        XCTAssertEqual(ai.state, .review)
        XCTAssertEqual(dep.state, .todo, "dependent task not picked up")
        XCTAssertEqual(hum.state, .todo)
        XCTAssertEqual(sh.state, .in_progress); XCTAssertEqual(sh.aiStatus, .done); XCTAssertTrue(sh.isYourTurn)
        XCTAssertTrue(s.byMode(assignee: .human).contains { $0.tasks.contains { $0.0.id == sh.id } })
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

    func testUndoAndPathJail() throws {
        let c = try makeContainer(); let s = Store(c.mainContext)
        let p = s.create(title: "P"); let t = s.create(title: "t", parentID: p.id, assignee: .ai)
        s.update(t, actor: .ai, detail: "draft") { $0.state = .review; $0.artifact = "x" }
        let a = try XCTUnwrap(s.activity(for: t.id).first)
        try s.applyUndo(a)
        XCTAssertEqual(t.state, .todo); XCTAssertNil(t.artifact)
        XCTAssertThrowsError(try AgentTools.safePathThrowing("../../etc/passwd"))
        XCTAssertThrowsError(try AgentTools.safePathThrowing("/tmp/x"))
        XCTAssertEqual(try AgentTools.safePathThrowing("notes/./a.md"), "notes/a.md")
    }
}
