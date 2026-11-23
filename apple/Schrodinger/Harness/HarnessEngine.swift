import Foundation
import SwiftData

/// One project's digest (written when the owner opens Digest; no model call) and the in-app draft used when the
/// model runs in the app's own process. Nothing here runs on a timer or in the background: the AI works only on
/// an item the owner hands off (see `JobQueue`), and no pass over the outline files notices on its own.
@MainActor
struct ProjectAgent {
    let container: ModelContainer
    let projectID: UUID
    let provider: any LanguageModelProvider

    /// The AI has something to do on this item now: an AI item not yet started, or the AI's part of a shared item.
    static func aiTurn(_ t: Node) -> Bool {
        (t.assignee == .ai && t.state.notStarted) || (t.assignee == .shared && t.aiStatus == .pending && (t.state.notStarted || t.state == .in_progress))
    }

    /// Writes today's digest for the project. Called when the owner opens the Digest panel.
    func writeDigest() async throws {
        let s = Store(container.mainContext)
        guard let project = s.node(projectID), project.isProject else { throw StoreError.invalidMove }
        if project.projectStatus != .active { return }

        // AI work waiting on the owner's tasks.
        let tasks = s.descendants(of: projectID)
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let waitingOnHuman = s.leaves(under: projectID).filter { t in
            t.state != .done && (t.assignee == .ai || (t.assignee == .shared && t.aiStatus == .pending))
                && t.deps.compactMap { byID[$0] }.contains { $0.assignee == .human && $0.state != .done }
        }

        let fresh = tasks
        let day = Date().dayString
        func grp(_ st: TaskState) -> String { let l = fresh.filter { $0.state == st }.map { "- \($0.title)" }; return l.isEmpty ? "- none" : l.joined(separator: "\n") }
        var needs: [String] = fresh.filter { $0.state == .review }.map { "- review: \($0.title)" }
        needs += fresh.filter { $0.isYourTurn }.map { "- your part: \($0.title)" }
        needs += fresh.filter { $0.assignee == .human && $0.state.notStarted && ($0.due.map { $0 < Date() } ?? false) }.map { "- overdue: \($0.title) (\($0.due!.dayString))" }
        needs += waitingOnHuman.map { "- AI waiting on your task before: \($0.title)" }
        let todayEvents = await CalendarService.shared.events(days: 1).map { e -> String in
            let t = e.allDay ? "all day" : e.start.formatted(date: .omitted, time: .shortened)
            return "- \(t): \(e.title)"
        }
        let p2 = s.progress(of: projectID)
        var body = "# \(project.title) — \(day)\nProgress: \(p2.done)/\(p2.total) (\(p2.pct)%)\n\n## Done\n\(grp(.done))\n\n## In progress\n\(grp(.in_progress))\n\n## Blocked\n\(grp(.blocked))\n\n## Needs you\n\(needs.isEmpty ? "- nothing" : needs.joined(separator: "\n"))"
        if !todayEvents.isEmpty { body += "\n\n## Today's calendar\n" + todayEvents.joined(separator: "\n") }
        s.saveDigest(projectID: projectID, day: day, body: body)
        s.save()
    }

    private func systemPrompt(_ project: Node) -> String {
        """
        You are the sub-agent for the project "\(project.title)".
        Goal: \(project.goal.isEmpty ? "(none stated)" : project.goal)
        Success criteria: \(project.successCriteria.isEmpty ? "(none stated)" : project.successCriteria)
        Constraints: \(project.constraints.isEmpty ? "(none)" : project.constraints)
        Rules: You produce drafts only. You never send email, post, commit, or contact anyone.
        Everything you write is reviewed by the human owner before it is used. Be concise and concrete.
        """
    }

    func draft(project: Node, task: Node) async throws -> DraftResult {
        let tools = AgentTools.make(container: container, projectID: projectID, taskID: task.id)
        var lines = ["Task: \(task.title)"]
        if !task.tags.isEmpty { lines.append("Tags: " + task.tags.sorted().map { "#" + $0 }.joined(separator: " ")) }
        if let d = task.due { lines.append("Due: \(d.dayString)") }
        if !task.notes.isEmpty { lines.append("Notes:\n\(task.notes)") }
        if !task.acceptanceNote.isEmpty { lines.append("Prior review notes from the owner (address these):\n\(task.acceptanceNote)") }
        if task.assignee == .shared { lines.append("This task is SHARED: you do the preparatory part (research, drafting, checklists, materials) and the owner finishes it in person. Produce everything the owner needs to complete their part, and state clearly what remains for them.") }
        lines.append("Use project_context first. Use web_fetch for anything factual you are not sure of. Save working notes with write_file. When the deliverable is ready, call finish with the full draft (or, if you have no finish tool, reply with the full draft). If the task needs information only the owner has, draft what you can and list the questions under \"Needs from you\".")
        return try await provider.draft(DraftRequest(system: systemPrompt(project), prompt: lines.joined(separator: "\n\n"), tools: tools, maxTurns: AppSettings.agentMaxTurns))
    }
}
