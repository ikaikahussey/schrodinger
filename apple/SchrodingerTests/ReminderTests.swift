import XCTest
import SwiftData
@testable import Schrodinger

@MainActor
final class ReminderTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private func at(_ d: Int, _ h: Int = 0, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 12, day: d, hour: h, minute: m))!
    }
    private func item(_ title: String, _ due: Date) -> Reminders.Item { .init(id: UUID(), title: title, project: "P", due: due) }

    func testTimedItemsFireAtTimeMinusLeadAndAllDayAtMorningHour() {
        let now = at(10, 8)
        let timed = item("call", at(10, 15, 30))
        let allDay = item("errand", at(11))
        let plans = Reminders.plan([allDay, timed], now: now, leadMinutes: 15, allDayHour: 9, calendar: cal)
        XCTAssertEqual(plans.map(\.item.title), ["call", "errand"])
        XCTAssertEqual(plans[0].fire, at(10, 15, 15))
        XCTAssertEqual(plans[1].fire, at(11, 9))
        XCTAssertEqual(plans[1].body, "Due today")
    }

    func testPastMomentsAreSkippedAndLateLeadFallsBackToDueTime() {
        let now = at(10, 15, 20)
        let passed = item("passed", at(10, 9))          // timed, already past
        let today = item("today", at(10))               // all-day today, morning hour already past
        let soon = item("soon", at(10, 15, 30))         // 15-min lead would be 15:15, already past → fire at 15:30
        let plans = Reminders.plan([passed, today, soon], now: now, leadMinutes: 15, allDayHour: 9, calendar: cal)
        XCTAssertEqual(plans.map(\.item.title), ["soon"])
        XCTAssertEqual(plans[0].fire, at(10, 15, 30))
        XCTAssertTrue(plans[0].body.hasPrefix("Due now"))
    }

    func testBadgeCountsItemsDueByTheFiringDay() {
        let now = at(10, 8)
        let overdue = item("overdue", at(9))
        let later = item("later", at(12, 10))
        let plans = Reminders.plan([overdue, later], now: now, leadMinutes: 0, allDayHour: 9, calendar: cal)
        XCTAssertEqual(plans.map(\.badge), [2])                      // on the 12th both are due or overdue
        XCTAssertEqual(Reminders.badgeNow([overdue, later], now: now, calendar: cal), 1)
    }

    func testLimitKeepsSoonest() {
        let now = at(1)
        let many = (2...20).map { item("d\($0)", at($0, 10)) }
        let plans = Reminders.plan(many.reversed(), now: now, leadMinutes: 0, allDayHour: 9, calendar: cal, limit: 3)
        XCTAssertEqual(plans.map(\.item.title), ["d2", "d3", "d4"])
    }

    func testItemsSkipDoneUndatedAndProjectsAndCarryProjectTitle() throws {
        let schema = Schema([Node.self, Proposal.self, ActivityEntry.self, Digest.self, WorkspaceFile.self, HarnessRun.self, Attachment.self])
        let c = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let s = Store(c.mainContext)
        let p = s.create(title: "Home", due: at(5))
        let group = s.create(title: "Chores", parentID: p.id)
        let open = s.create(title: "Fix gate", parentID: group.id, due: at(6))
        let done = s.create(title: "Paint", parentID: group.id, due: at(6))
        s.update(done) { $0.state = .done }
        _ = s.create(title: "Someday", parentID: group.id)
        let items = Reminders.items(try c.mainContext.fetch(FetchDescriptor<Node>()))
        XCTAssertEqual(items.map(\.id), [open.id])
        XCTAssertEqual(items.first?.project, "Home")
    }
}
