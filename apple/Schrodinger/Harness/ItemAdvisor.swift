import Foundation
import SwiftData

/// Feedback on one item, on request (the lightbulb in the item field). The model's reply is never shown as chat:
/// each suggestion is filed as a proposal on the item, and the field shows it with Accept and Dismiss buttons.
@MainActor
enum ItemAdvisor {
    static let limit = 4

    /// Files the model's suggestions for the item. Returns how many were new (a suggestion made before, whether
    /// accepted or dismissed, is not raised again).
    static func advise(nodeID: UUID, container: ModelContainer, provider: any LanguageModelProvider) async throws -> Int {
        let s = Store(container.mainContext)
        guard let n = s.node(nodeID) else { return 0 }
        let project = s.project(of: n)
        let raw = parse(try await provider.complete(system: system(project), prompt: prompt(n, store: s)))
        // The item may have been deleted while the model was working.
        guard let node = s.node(nodeID), !node.isDeleted else { return 0 }
        var added = 0
        for item in raw.prefix(limit) {
            guard let (type, summary, payload) = validated(item, for: node) else { continue }
            if s.propose(projectID: project.id, nodeID: node.id, type: type, summary: summary, payload: payload) != nil { added += 1 }
        }
        s.save()
        return added
    }

    static func system(_ project: Node) -> String {
        """
        You help the owner of an outline think through their work. You give feedback on one item at a time.
        Project: "\(project.title)". Goal: \(project.goal.isEmpty ? "(none stated)" : project.goal)
        You never act and you never chat: you only return suggestions the owner can accept or dismiss with one tap.
        Be concrete and brief. Suggest only what clearly helps; an item that is fine needs nothing.
        """
    }

    static func prompt(_ n: Node, store s: Store) -> String {
        let kids = s.children(of: n.id)
        var lines = ["Item: \"\(n.title)\""]
        let notes = n.isProject ? n.goal : n.notes
        lines.append("Notes: \(notes.isEmpty ? "(none)" : notes)")
        if !n.isProject { lines.append("Responsible: \(n.assigneeRaw). Status: \(n.stateRaw).") }
        if let pid = n.parentID, let p = s.node(pid) { lines.append("Parent item: \"\(p.title)\"") }
        lines.append("Child items:\n" + (kids.isEmpty ? "(none)" : kids.map { "- \($0.title)" }.joined(separator: "\n")))
        lines.append("""
        Return ONLY a JSON array of at most \(limit) suggestions, most useful first. Each is {"type","summary","payload"}:
        - "decompose": payload {"subtasks":[{"title","assignee":"human"|"ai"|"shared"}]}. 2 to 6 concrete next steps that are not already child items.
        - "retitle": payload {"title"}. A clearer wording of the item's text.
        - "note": payload {"text"}. A short addition to the notes: a risk, what done looks like, a fact worth recording.
        - "reassign": payload {"assignee":"human"|"ai"|"shared"}. Only if someone else should hold the item.
        - "feedback": payload {}. An observation or a question for the owner to think about; the summary carries it.
        "summary" is one short plain sentence saying what the suggestion is and why. Return [] if the item is fine as it is.
        """)
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [[String: Any]] {
        guard let r = text.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression),
              let arr = (try? JSONSerialization.jsonObject(with: Data(text[r].utf8))) as? [[String: Any]] else { return [] }
        return arr
    }

    /// Checks one suggestion against the item and returns it in the form `Store.accept` applies, or nil to drop it.
    static func validated(_ item: [String: Any], for n: Node) -> (ProposalType, String, [String: Any])? {
        guard let type = (item["type"] as? String).flatMap(ProposalType.init(rawValue:)),
              let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        let pl = item["payload"] as? [String: Any] ?? [:]
        func clean(_ v: Any?) -> String { (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch type {
        case .decompose:
            let subs: [[String: Any]] = (pl["subtasks"] as? [[String: Any]] ?? []).compactMap { t in
                let title = clean(t["title"]); if title.isEmpty { return nil }
                let who = Assignee(rawValue: clean(t["assignee"])) ?? (n.isProject ? .human : n.assignee)
                return ["title": title, "assignee": who.rawValue]
            }
            return subs.isEmpty ? nil : (type, summary, ["subtasks": Array(subs.prefix(6))])
        case .retitle:
            let title = clean(pl["title"])
            return title.isEmpty || title == n.title ? nil : (type, summary, ["title": title])
        case .note:
            let text = clean(pl["text"])
            return text.isEmpty ? nil : (type, summary, ["text": text])
        case .reassign:
            guard !n.isProject, let who = Assignee(rawValue: clean(pl["assignee"])), who != n.assignee else { return nil }
            return (type, summary, ["assignee": who.rawValue])
        case .feedback:
            return (type, summary, [:])
        case .new_task, .stale, .blocked_chain, .no_path:
            return nil
        }
    }
}
