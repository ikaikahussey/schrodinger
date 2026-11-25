import Foundation
import SwiftData

/// What the model is told for a hand-off: everything it needs about the item and its surroundings, in one message,
/// because the whole job is a single request (there is no later turn in which it could ask the app for more).
@MainActor
enum HandoffBrief {
    struct Text: Sendable { let system: String; let prompt: String }

    static func make(nodeID: UUID, container: ModelContainer) async -> Text? {
        // Calendar first: it is the only part that waits, and the item is read after it, as it is then.
        let events = CalendarService.authorized ? await CalendarService.shared.events(days: 14) : []
        let s = Store(container.mainContext)
        guard let task = s.node(nodeID), !task.isDeleted else { return nil }
        return Text(system: system(project: s.project(of: task)), prompt: prompt(task: task, store: s, events: events))
    }

    static func system(project: Node) -> String {
        """
        You complete tasks handed off from the owner's to-do outline. Do the work now, in this one turn: there is no later turn and no one to ask.
        Project: "\(project.title)"
        Goal: \(project.goal.isEmpty ? "(none stated)" : project.goal)
        Success criteria: \(project.successCriteria.isEmpty ? "(none stated)" : project.successCriteria)
        Constraints: \(project.constraints.isEmpty ? "(none)" : project.constraints)

        You can search the web and fetch pages for anything factual you are not sure of, write the deliverable, and change the outline through submit_result: add follow-up items under the task, add a note, add links, set dates.
        You cannot send email, post, buy, book, call or contact anyone, and nothing you write leaves the app. When the task needs one of those, prepare everything (the exact wording, numbers, links) and add a follow-up item assigned to "human" for the last step.

        Finish by calling submit_result exactly once:
        - result_markdown: the complete deliverable. Concrete and brief, no preamble, sources as links where you used them.
        - done: true only when nothing is left on this task for you or the owner. False when the owner has to act, decide or review.
        - child_items: follow-up steps, only when they are needed. Never restate the task or pad the list.
        - questions: only what you could not find out and need from the owner. The owner answers in the task's notes and hands it off again.
        """
    }

    static func prompt(task: Node, store s: Store, events: [CalendarEvent] = [], now: Date = Date()) -> String {
        let project = s.project(of: task)
        var lines = ["Today is \(now.dayString) (\(now.formatted(.dateTime.weekday(.wide))))."]
        lines.append("Task: \"\(task.title)\"")
        var path: [String] = []
        var cur = task
        while let pid = cur.parentID, let up = s.node(pid), path.count < 12 { path.insert(up.title, at: 0); cur = up }
        if !path.isEmpty { lines.append("Where it sits in the outline: " + path.joined(separator: " > ")) }
        if !task.notes.isEmpty { lines.append("Notes on the task:\n\(task.notes)") }
        if let d = task.due { lines.append("Due: \(d.dayString)") }
        if !task.tags.isEmpty { lines.append("Tags: " + task.tags.sorted().map { "#" + $0 }.joined(separator: " ")) }
        let links = s.attachments(for: task.id).filter { $0.kind == .link }.map(\.urlString)
        if !links.isEmpty { lines.append("Links on the task:\n" + links.map { "- \($0)" }.joined(separator: "\n")) }
        let kids = s.children(of: task.id)
        if !kids.isEmpty { lines.append("Items already under the task:\n" + kids.prefix(40).map { "- \($0.title) (\($0.state.label), \($0.assignee.label))" }.joined(separator: "\n")) }
        let others = s.descendants(of: project.id).filter { $0.id != task.id && $0.parentID != task.id && $0.state != .done }
        if !others.isEmpty {
            lines.append("Other open items in the project, for context only (do not do them):\n" + others.prefix(60).map { "- \($0.title)" }.joined(separator: "\n"))
        }
        if let a = task.artifact, !a.isEmpty { lines.append("Your earlier result, to revise:\n\(a.prefix(6000))") }
        if !task.acceptanceNote.isEmpty { lines.append("The owner's notes on the earlier result (address these):\n\(task.acceptanceNote)") }
        if task.assignee == .shared {
            lines.append("This task is shared: you do the preparation (research, drafting, checklists, materials) and the owner finishes it in person. Produce everything the owner needs for their part and say what remains for them.")
        }
        if !events.isEmpty {
            lines.append("The owner's calendar, next 14 days:\n" + events.prefix(25).map { "- \($0.start.dayString)\($0.allDay ? "" : " " + $0.start.formatted(date: .omitted, time: .shortened)): \($0.title)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }
}

/// What the model is told when asked to recommend new tasks: the whole outline, with an id on each item so a
/// recommendation can say where it goes.
@MainActor
enum SuggestBrief {
    static let limit = 5

    static func make(container: ModelContainer, budget: Int = 48_000) async -> HandoffBrief.Text? {
        let events = CalendarService.authorized ? await CalendarService.shared.events(days: 7) : []
        let s = Store(container.mainContext)
        let text = outline(store: s, budget: budget)
        guard !text.isEmpty else { return nil }
        return HandoffBrief.Text(system: system, prompt: prompt(outline: text, store: s, events: events))
    }

    static var system: String {
        """
        You look over the owner's whole to-do outline and recommend tasks that are missing from it. The owner sees each recommendation as a dimmed line in the outline, with your one-sentence reason, and keeps or dismisses it with one tap.
        Recommend only what clearly helps: the next concrete step toward a stated goal, something a date or calendar event makes necessary, a gap between what was just finished and what is open. Never restate, reword or split an item that is already there. Never recommend generic habits or planning rituals.
        At most \(limit) recommendations; fewer is better, and none is a fine answer. Call submit_suggestions exactly once.
        """
    }

    static func prompt(outline: String, store s: Store, events: [CalendarEvent], now: Date = Date()) -> String {
        var lines = ["Today is \(now.dayString) (\(now.formatted(.dateTime.weekday(.wide))))."]
        lines.append("The outline. Each line: [id] title (status, who holds it, due date). Indentation shows what is under what. Top-level lines are projects; their goal follows when there is one.\n\(outline)")
        if !events.isEmpty {
            lines.append("The owner's calendar, next 7 days:\n" + events.prefix(25).map { "- \($0.start.dayString): \($0.title)" }.joined(separator: "\n"))
        }
        let asked = s.proposals(of: .new_task, limit: 40).compactMap { $0.payload["title"] as? String }
        if !asked.isEmpty { lines.append("Already recommended before (kept or dismissed); do not recommend these again:\n" + asked.map { "- \($0)" }.joined(separator: "\n")) }
        return lines.joined(separator: "\n\n")
    }

    /// The outline of active projects as indented text, cut off at `budget` characters. Done items are left out
    /// unless they were finished in the last week (what was just finished says what comes next).
    static func outline(store s: Store, budget: Int = 48_000) -> String {
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var out: [String] = []
        var used = 0
        func walk(_ n: Node, _ depth: Int) -> Bool {
            if n.state == .done && !n.isProject && n.updatedAt < weekAgo { return true }
            var line = String(repeating: "  ", count: depth) + "[\(n.id.uuidString.prefix(8))] " + (n.title.isEmpty ? "(untitled)" : n.title)
            if n.isProject {
                if !n.goal.isEmpty { line += " | goal: " + String(n.goal.replacingOccurrences(of: "\n", with: " ").prefix(240)) }
            } else {
                var facts = [n.state.label, n.assignee.label]
                if let d = n.due { facts.append("due " + d.dayString) }
                line += " (" + facts.joined(separator: ", ") + ")"
                if !n.notes.isEmpty { line += " | " + String(n.notes.replacingOccurrences(of: "\n", with: " ").prefix(160)) }
            }
            if used + line.count > budget { return false }
            used += line.count + 1
            out.append(line)
            for c in s.children(of: n.id) { if !walk(c, depth + 1) { return false } }
            return true
        }
        for p in s.projects() where p.projectStatus == .active { if !walk(p, 0) { break } }
        return out.joined(separator: "\n")
    }

    /// Files what the model recommended. Each entry names its parent by the id shown in the outline. Returns how
    /// many were new.
    @discardableResult
    static func file(_ items: [[String: Any]], store s: Store) -> Int {
        func clean(_ v: Any?) -> String { (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let nodes = s.allNodes()
        var added = 0
        for item in items.prefix(limit) {
            let pid = clean(item["parent_id"]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).uppercased()
            guard pid.count >= 8, let parent = nodes.first(where: { $0.id.uuidString.hasPrefix(pid) }) else { continue }
            let who = Assignee(rawValue: clean(item["assignee"])) ?? .human
            if s.suggestTask(parent: parent, title: clean(item["title"]), assignee: who == .unassigned ? .human : who,
                             reason: clean(item["reason"]), due: HandoffResult.day(clean(item["due"]))) != nil { added += 1 }
        }
        return added
    }

    /// A model without tool calling answers in text: the JSON array in it, if any.
    static func parse(_ text: String) -> [[String: Any]] {
        guard let r = text.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression),
              let arr = (try? JSONSerialization.jsonObject(with: Data(text[r].utf8))) as? [[String: Any]] else { return [] }
        return arr
    }
}

/// Work done in the app's own process, for models that are called that way (Apple Intelligence on device, a
/// local model server). It runs only while the app is open.
@MainActor
enum InProcessAgent {
    /// Drafts the item with the model's own tool loop. The draft goes to the owner for review.
    static func handoff(nodeID: UUID, container: ModelContainer, provider: any LanguageModelProvider) async throws -> HandoffResult {
        let s = Store(container.mainContext)
        guard let task = s.node(nodeID), !task.isDeleted else { throw JobError.itemGone }
        let project = s.project(of: task)
        let agent = ProjectAgent(container: container, projectID: project.id, provider: provider)
        let draft = try await agent.draft(project: project, task: task)
        return HandoffResult(summary: "Draft ready for you to review.", markdown: draft.artifact, done: false)
    }

    static func suggest(container: ModelContainer, provider: any LanguageModelProvider) async throws -> [[String: Any]] {
        // The on-device model reads a few thousand characters: a short outline, and the answer as plain JSON.
        guard let brief = await SuggestBrief.make(container: container, budget: 3_000) else { return [] }
        let ask = brief.prompt + "\n\nReturn ONLY a JSON array, at most \(SuggestBrief.limit) entries, each {\"parent_id\",\"title\",\"assignee\":\"human\"|\"ai\"|\"shared\",\"reason\"}. Return [] if nothing is missing."
        return SuggestBrief.parse(try await provider.complete(system: brief.system, prompt: ask))
    }
}

enum JobError: LocalizedError {
    case itemGone
    var errorDescription: String? { "The item no longer exists." }
}
