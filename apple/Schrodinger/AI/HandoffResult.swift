import Foundation
import SwiftData

/// What the model hands back for a handed-off item: the deliverable, and the changes to make to the outline.
/// The model returns it by calling the `submit_result` tool once; `parse` reads that call's input.
struct HandoffResult: Equatable, Sendable {
    struct Child: Equatable, Sendable {
        var title: String
        var assignee: Assignee = .human
        var due: Date? = nil
        var notes: String = ""
    }
    /// One line saying what was done (the notification's text).
    var summary = ""
    /// The deliverable, as markdown. Shown on the item.
    var markdown = ""
    /// Nothing is left to do on the item.
    var done = false
    /// Follow-up steps, added under the item.
    var children: [Child] = []
    /// Text added to the item's notes.
    var notesAppend = ""
    /// Web addresses kept on the item as links.
    var links: [String] = []
    /// What the model needs from the owner before it can finish.
    var questions: [String] = []

    /// JSON Schema of the `submit_result` tool's input.
    static var schema: [String: Any] {
        func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
        let child: [String: Any] = [
            "type": "object",
            "properties": [
                "title": str("The step, as a short imperative"),
                "assignee": ["type": "string", "enum": ["human", "ai", "shared"], "description": "Who does it. human = the owner."],
                "due": str("Optional date, YYYY-MM-DD"),
                "notes": str("Optional detail the step needs"),
            ],
            "required": ["title", "assignee"],
        ]
        return [
            "type": "object",
            "properties": [
                "summary": str("One plain sentence saying what you did. Shown in a notification."),
                "result_markdown": str("The complete deliverable, as markdown"),
                "done": ["type": "boolean", "description": "True only when nothing is left to do on this item, by you or by the owner"],
                "child_items": ["type": "array", "items": child, "description": "Follow-up steps to add under the item. Only steps that are needed."],
                "notes_append": str("Optional short text to add to the item's notes: a fact worth keeping with the item"),
                "links": ["type": "array", "items": ["type": "string"], "description": "Web addresses worth keeping on the item"],
                "questions": ["type": "array", "items": ["type": "string"], "description": "What you need from the owner and could not find out yourself"],
            ],
            "required": ["summary", "result_markdown", "done"],
        ]
    }

    /// Reads a `submit_result` input. Unknown or malformed parts are dropped, never trusted.
    static func parse(_ input: [String: Any]) -> HandoffResult {
        func clean(_ v: Any?) -> String { (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var r = HandoffResult()
        r.summary = clean(input["summary"])
        r.markdown = clean(input["result_markdown"])
        r.done = input["done"] as? Bool ?? false
        r.notesAppend = clean(input["notes_append"])
        r.links = (input["links"] as? [Any] ?? []).map { clean($0) }.filter { !$0.isEmpty }
        r.questions = (input["questions"] as? [Any] ?? []).map { clean($0) }.filter { !$0.isEmpty }
        r.children = (input["child_items"] as? [[String: Any]] ?? []).compactMap { c in
            let title = clean(c["title"])
            if title.isEmpty { return nil }
            let who = Assignee(rawValue: clean(c["assignee"])) ?? .human
            return Child(title: title, assignee: who == .unassigned ? .human : who, due: day(clean(c["due"])), notes: clean(c["notes"]))
        }
        return r
    }

    /// A YYYY-MM-DD date as the start of that day here (an all-day date), or nil.
    static func day(_ text: String) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 1900, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// How a hand-off left its item.
enum HandoffOutcome: String, Sendable {
    /// Finished: nothing left on the item.
    case done
    /// The owner has something to do: review the result, answer questions, or do the follow-up steps.
    case needsYou
    /// A shared item: the AI's part is done, the owner finishes it.
    case yourTurn
}

extension Store {
    /// Text reduced to what makes two titles the same task: lowercase letters and digits, single spaces.
    static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Applies a hand-off's result to its item: the deliverable goes on the item, follow-up steps become its children,
    /// notes and links are added, and its status moves on. Every change is made as the AI and recorded in the item's
    /// activity, so History shows it and it can be undone. Nothing outside the app is touched.
    @discardableResult
    func applyHandoff(_ r: HandoffResult, to n: Node) -> HandoffOutcome {
        var made = 0
        var have = Set(children(of: n.id).map { Self.normalized($0.title) })
        for c in r.children.prefix(12) {
            let key = Self.normalized(c.title)
            if key.isEmpty || have.contains(key) { continue }
            have.insert(key)
            let child = create(title: c.title, parentID: n.id, assignee: c.assignee, due: c.due, actor: .ai)
            if !c.notes.isEmpty { child.notes = c.notes }
            made += 1
        }
        let known = Set(attachments(for: n.id).map(\.urlString))
        for l in r.links.prefix(10) {
            if let u = Attachment.normalizedURL(l), !known.contains(u.absoluteString) { addLink(l, to: n.id) }
        }
        var artifact = r.markdown
        if !r.questions.isEmpty {
            artifact += (artifact.isEmpty ? "" : "\n\n") + "## Needs from you\n" + r.questions.map { "- \($0)" }.joined(separator: "\n")
        }
        let finished = r.done && r.questions.isEmpty
        let outcome: HandoffOutcome = n.assignee == .shared ? .yourTurn : finished ? .done : .needsYou
        var detail: String = switch outcome {
        case .done: "done by the AI"
        case .needsYou: r.questions.isEmpty ? "result ready for you" : "the AI needs answers from you"
        case .yourTurn: "AI part done, your turn"
        }
        if made > 0 { detail += " (\(made) follow-up \(made == 1 ? "item" : "items") added)" }
        let add = r.notesAppend
        update(n, actor: .ai, detail: detail) { x in
            x.artifact = artifact.isEmpty ? x.artifact : artifact
            if !add.isEmpty {
                if x.isProject { x.goal = x.goal.isEmpty ? add : x.goal + "\n" + add } else { x.notes = x.notes.isEmpty ? add : x.notes + "\n" + add }
            }
            switch outcome {
            case .yourTurn: x.state = .in_progress; x.aiStatus = .done
            // Finished, but with follow-up steps under it: the item stays open until they are done.
            case .done: x.state = made > 0 ? .in_progress : .done
            case .needsYou: x.state = .review
            }
            if made > 0 { x.collapsed = false }
        }
        return outcome
    }

    // MARK: - Recommended tasks (shown in the outline as dimmed rows to keep or dismiss)

    /// The item a recommended task would be added under.
    func suggestionParent(of p: Proposal) -> UUID {
        (p.payload["parent_id"] as? String).flatMap(UUID.init(uuidString:)) ?? p.projectID
    }

    /// Files a recommended task under `parent`. Returns nil (and files nothing) when the outline already has that
    /// task under the same project, or it was recommended before: kept or dismissed, it is not raised again.
    @discardableResult
    func suggestTask(parent: Node, title: String, assignee: Assignee, reason: String, due: Date? = nil) -> Proposal? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalized(text)
        guard !key.isEmpty else { return nil }
        let root = project(of: parent)
        if ([root] + descendants(of: root.id)).contains(where: { Self.normalized($0.title) == key }) { return nil }
        let t = ProposalType.new_task.rawValue
        let before = (try? ctx.fetch(FetchDescriptor<Proposal>(predicate: #Predicate { $0.typeRaw == t }))) ?? []
        if before.contains(where: { Self.normalized($0.payload["title"] as? String ?? "") == key }) { return nil }
        var payload: [String: Any] = ["title": text, "assignee": assignee.rawValue, "parent_id": parent.id.uuidString, "reason": reason]
        if let due { payload["due"] = due.timeIntervalSince1970 }
        let p = Proposal(projectID: root.id, nodeID: nil, type: .new_task, summary: reason.isEmpty ? text : reason, payload: payload)
        ctx.insert(p)
        return p
    }

    /// Proposals of one kind, newest first, whatever became of them.
    func proposals(of type: ProposalType, limit: Int) -> [Proposal] {
        let t = type.rawValue
        var d = FetchDescriptor<Proposal>(predicate: #Predicate { $0.typeRaw == t }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = limit
        return (try? ctx.fetch(d)) ?? []
    }

    /// Recommended tasks waiting for an answer.
    func openSuggestions() -> [Proposal] { inbox().filter { $0.type == .new_task } }
}
