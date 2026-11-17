import Foundation
import SwiftData
import EventKit

/// Keeps one calendar event per calendared item (an item with a date) in the calendar chosen in Settings.
/// Off until a calendar is chosen. Only events this app made are ever changed or removed.
@MainActor
enum CalendarSync {
    /// What the sync depends on, as one string: when it changes, the calendar needs another pass.
    static func signature(_ nodes: [Node]) -> String {
        nodes.filter { $0.due != nil || !$0.calendarEventID.isEmpty }
            .map { "\($0.id.uuidString):\($0.due?.timeIntervalSince1970 ?? 0):\($0.title):\($0.notes.hashValue)" }
            .sorted().joined(separator: "|")
    }

    /// Brings the chosen calendar in line with the items: a dated item gets an event (or its event is updated),
    /// an item whose date was removed loses its event.
    static func syncAll(container: ModelContainer) async {
        let calendarID = AppSettings.shared.syncCalendarID
        guard !calendarID.isEmpty, CalendarService.authorized else { return }
        let ctx = container.mainContext
        let nodes = ((try? ctx.fetch(FetchDescriptor<Node>())) ?? []).filter { $0.due != nil || !$0.calendarEventID.isEmpty }
        var changed = false
        for n in nodes {
            let id = n.id, eventID = n.calendarEventID
            if let due = n.due {
                let title = n.title.isEmpty ? "(untitled)" : n.title
                guard let newID = try? await CalendarService.shared.upsert(eventID: eventID, calendarID: calendarID, title: title, notes: n.notes, date: due, allDay: !due.hasTime),
                      newID != eventID else { continue }
                // The item may have been deleted while the calendar was being written.
                if let live = Store(ctx).node(id), !live.isDeleted { live.calendarEventID = newID; changed = true }
            } else {
                await CalendarService.shared.remove(eventIDs: [eventID])
                if let live = Store(ctx).node(id), !live.isDeleted { live.calendarEventID = ""; changed = true }
            }
        }
        if changed { try? ctx.save() }
    }
}

extension Date {
    /// A date with a time of day (anything but midnight). A date without one is an all-day entry.
    var hasTime: Bool { self != Calendar.current.startOfDay(for: self) }
    /// Short label for the calendared-items box: "Today", "Tomorrow" or "Nov 18", plus the time if there is one.
    var agendaLabel: String {
        let cal = Calendar.current
        let day = cal.isDateInToday(self) ? "Today" : cal.isDateInTomorrow(self) ? "Tomorrow" : formatted(.dateTime.month(.abbreviated).day())
        return hasTime ? day + " " + formatted(date: .omitted, time: .shortened) : day
    }
}
