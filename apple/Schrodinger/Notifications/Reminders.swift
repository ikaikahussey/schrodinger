import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// Local notifications for time-sensitive items: every item with a date that isn't done gets one notification —
/// timed items at their time (or a chosen lead time before it), all-day items on the morning of their day. The app
/// icon's badge counts items due today or overdue. Off until turned on in Settings (which asks for permission).
/// Nothing leaves the device: these are local notifications scheduled on it.
@MainActor
enum Reminders {
    static let category = "item"
    static let doneAction = "done"
    static let snoozeAction = "snooze"
    /// iOS keeps at most 64 pending notifications per app; leave room for snoozes.
    static let limit = 60
    private static let scheduledKey = "reminderIDs"

    /// One dated, open item, reduced to what scheduling needs (so the plan can be tested without SwiftData).
    struct Item: Equatable {
        let id: UUID
        let title: String
        let project: String
        let due: Date
    }

    struct Plan: Equatable {
        let item: Item
        let fire: Date
        let body: String
        /// Items due today or overdue at the moment this one fires: the badge it sets.
        let badge: Int
        var identifier: String { "item.\(item.id.uuidString)" }
    }

    // MARK: - Planning (pure)

    static func items(_ nodes: [Node]) -> [Item] {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func project(_ n: Node) -> String {
            var cur = n, hops = 0
            while let p = cur.parentID, let up = byID[p], hops < 64 { cur = up; hops += 1 }
            return cur.id == n.id ? "" : cur.title
        }
        return nodes.compactMap { n in
            guard !n.isDeleted, !n.isProject, n.state != .done, let due = n.due else { return nil }
            return Item(id: n.id, title: n.title.isEmpty ? "(untitled)" : n.title, project: project(n), due: due)
        }
    }

    /// When each item's notification goes off, soonest first, at most `limit`. Items whose moment has passed get none.
    static func plan(_ items: [Item], now: Date, leadMinutes: Int, allDayHour: Int, calendar cal: Calendar = .current, limit: Int = Reminders.limit) -> [Plan] {
        let starts = items.map { cal.startOfDay(for: $0.due) }
        func dueBy(_ t: Date) -> Int { starts.filter { $0 <= t }.count }
        var out: [Plan] = []
        for it in items {
            let fire: Date, body: String
            if it.due.hasTime {
                let early = it.due.addingTimeInterval(-Double(leadMinutes) * 60)
                // Too late for the lead time but not for the item itself: notify at its time.
                fire = early > now ? early : it.due
                let time = it.due.formatted(date: .omitted, time: .shortened)
                body = fire == it.due ? "Due now (\(time))" : "Due at \(time)"
            } else {
                fire = cal.date(bySettingHour: allDayHour, minute: 0, second: 0, of: it.due) ?? it.due
                body = "Due today"
            }
            guard fire > now else { continue }
            out.append(Plan(item: it, fire: fire, body: body, badge: dueBy(fire)))
        }
        return Array(out.sorted { ($0.fire, $0.item.title) < ($1.fire, $1.item.title) }.prefix(limit))
    }

    /// Items due today or overdue right now.
    static func badgeNow(_ items: [Item], now: Date, calendar cal: Calendar = .current) -> Int {
        items.filter { cal.startOfDay(for: $0.due) <= now }.count
    }

    /// What scheduling depends on, as one string: when it changes, notifications are rescheduled.
    static func signature(_ nodes: [Node]) -> String {
        let s = AppSettings.shared
        return "\(s.remindersOn):\(s.reminderLeadMinutes):\(s.allDayReminderHour)|" + nodes.filter { $0.due != nil }
            .map { "\($0.id.uuidString):\($0.due?.timeIntervalSince1970 ?? 0):\($0.stateRaw):\($0.title):\($0.parentID?.uuidString ?? "")" }
            .sorted().joined(separator: "|")
    }

    // MARK: - Scheduling

    static func requestAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Registers the Done / Remind-me-later actions and the tap handler. Call once at launch.
    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ReminderDelegate.shared
        let done = UNNotificationAction(identifier: doneAction, title: "Done", options: [])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Remind me in 1 hour", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [done, snooze], intentIdentifiers: [], options: [])])
    }

    /// Replaces this app's scheduled item notifications with the current plan and updates the badge.
    static func syncAll(container: ModelContainer) async {
        let center = UNUserNotificationCenter.current()
        let d = UserDefaults.standard
        let old = d.stringArray(forKey: scheduledKey) ?? []
        let settings = AppSettings.shared
        guard settings.remindersOn else {
            if !old.isEmpty { center.removePendingNotificationRequests(withIdentifiers: old); d.removeObject(forKey: scheduledKey) }
            try? await center.setBadgeCount(0)
            return
        }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let nodes = (try? container.mainContext.fetch(FetchDescriptor<Node>())) ?? []
        let list = items(nodes), now = Date()
        let plans = plan(list, now: now, leadMinutes: settings.reminderLeadMinutes, allDayHour: settings.allDayReminderHour)
        center.removePendingNotificationRequests(withIdentifiers: old)
        for p in plans {
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: p.fire), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: p.identifier, content: content(p.item, body: p.body, badge: p.badge), trigger: trigger))
        }
        d.set(plans.map(\.identifier), forKey: scheduledKey)
        try? await center.setBadgeCount(badgeNow(list, now: now))
    }

    static func content(_ it: Item, body: String, badge: Int?) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = it.title
        c.subtitle = it.project
        c.body = body
        c.sound = .default
        c.categoryIdentifier = category
        c.threadIdentifier = it.project
        c.userInfo = ["node": it.id.uuidString]
        // Breaks through Focus once the Time Sensitive Notifications capability is enabled for the app;
        // until then the system delivers it as an ordinary (active) notification.
        c.interruptionLevel = .timeSensitive
        if let badge { c.badge = NSNumber(value: badge) }
        return c
    }

    // MARK: - Responses

    static func handle(action: String, id: UUID) async {
        let container = AppData.container
        let store = Store(container.mainContext)
        guard let n = store.node(id), !n.isDeleted else { return }
        switch action {
        case doneAction:
            store.update(n, detail: "checked off from a notification") { $0.state = .done }
            store.save()
            await syncAll(container: container)
        case snoozeAction:
            let all = (try? container.mainContext.fetch(FetchDescriptor<Node>())) ?? []
            guard let full = items(all).first(where: { $0.id == id }) else { return }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "snooze.\(id.uuidString).\(Int(Date().timeIntervalSince1970))", content: content(full, body: "Reminder: due \(full.due.agendaLabel)", badge: nil), trigger: trigger))
        default:
            ReminderRouter.shared.openID = id
        }
    }
}

/// Notifications for the AI's finished work: one when a handed-off item comes back (done, needing the owner, or
/// failed). Tapping it opens the item. Local notifications, like the rest.
@MainActor
enum ResultNotifier {
    /// Asks for permission to notify, once, the first time something is handed off.
    static func prepare() async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined { _ = await Reminders.requestAccess() }
    }

    static func post(title: String, body: String, nodeID: UUID) async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.threadIdentifier = "results"
        c.userInfo = ["node": nodeID.uuidString]
        try? await center.add(UNNotificationRequest(identifier: "result.\(nodeID.uuidString)", content: c, trigger: nil))
    }
}

/// Carries a tapped notification's item to the outline, which opens it.
@MainActor
@Observable
final class ReminderRouter {
    static let shared = ReminderRouter()
    var openID: UUID? = nil
}

final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderDelegate()

    /// Shown even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let s = response.notification.request.content.userInfo["node"] as? String, let id = UUID(uuidString: s) else { return }
        await Reminders.handle(action: action, id: id)
    }
}
