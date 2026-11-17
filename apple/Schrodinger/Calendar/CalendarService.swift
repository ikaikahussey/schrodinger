import Foundation
import EventKit

/// Calendar hooks via EventKit: read upcoming events (for the agenda, agents, and prep proposals) and
/// add tasks to the user's calendar. Replaces the web app's ICS subscriptions with the device's own calendars.
struct CalendarEvent: Sendable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String
    let calendarID: String
    let calendarTitle: String
}

actor CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }   // never prompt under the test runner
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Full calendar access has been granted (asking is done from Settings, never from a sync).
    nonisolated static var authorized: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Calendars events can be added to.
    func writableCalendars() -> [(id: String, title: String)] {
        store.calendars(for: .event).filter(\.allowsContentModifications).map { ($0.calendarIdentifier, $0.title) }.sorted { $0.title < $1.title }
    }

    /// Creates the item's event, or brings its existing one up to date. Returns the event's identifier.
    /// A dated item with no time is an all-day event; with a time it lasts one hour.
    func upsert(eventID: String, calendarID: String, title: String, notes: String, date: Date, allDay: Bool) throws -> String {
        guard let cal = store.calendar(withIdentifier: calendarID), cal.allowsContentModifications else { throw CalendarError.denied }
        let existing = eventID.isEmpty ? nil : store.event(withIdentifier: eventID)
        let e = existing ?? EKEvent(eventStore: store)
        let start = allDay ? Calendar.current.startOfDay(for: date) : date
        let end = allDay ? start : start.addingTimeInterval(3600)
        if existing != nil, e.title == title, (e.notes ?? "") == notes, e.isAllDay == allDay, e.startDate == start, e.endDate == end,
           e.calendar.calendarIdentifier == calendarID { return eventID }
        e.title = title; e.notes = notes.isEmpty ? nil : notes; e.isAllDay = allDay; e.startDate = start; e.endDate = end; e.calendar = cal
        try store.save(e, span: .thisEvent, commit: true)
        return e.eventIdentifier
    }

    /// Removes events this app made (an item was deleted, or its date was taken off).
    func remove(eventIDs: [String]) {
        guard Self.authorized else { return }
        for id in eventIDs where !id.isEmpty {
            if let e = store.event(withIdentifier: id) { try? store.remove(e, span: .thisEvent, commit: true) }
        }
    }

    func calendars() -> [(id: String, title: String)] {
        store.calendars(for: .event).map { ($0.calendarIdentifier, $0.title) }.sorted { $0.title < $1.title }
    }

    func events(from: Date = Date(), days: Int = 14, calendarIDs: [String]? = nil) async -> [CalendarEvent] {
        guard await requestAccess() else { return [] }
        let cals = calendarIDs.map { ids in store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } }
        if let cals, cals.isEmpty { return [] }
        let pred = store.predicateForEvents(withStart: from, end: Calendar.current.date(byAdding: .day, value: days, to: from)!, calendars: cals)
        return store.events(matching: pred).sorted { $0.startDate < $1.startDate }.map {
            CalendarEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "(untitled)", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                          location: $0.location ?? "", calendarID: $0.calendar.calendarIdentifier, calendarTitle: $0.calendar.title)
        }
    }

    /// Add a due-dated task as an all-day event in the default calendar. Returns the event identifier.
    func addTask(title: String, due: Date, notes: String) async throws -> String {
        guard await requestAccess() else { throw CalendarError.denied }
        let e = EKEvent(eventStore: store)
        e.title = title; e.notes = notes; e.isAllDay = true
        e.startDate = Calendar.current.startOfDay(for: due)
        e.endDate = e.startDate
        e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
        return e.eventIdentifier
    }
}

enum CalendarError: LocalizedError {
    case denied
    var errorDescription: String? { "Calendar access was not granted. Enable it in System Settings → Privacy → Calendars." }
}
