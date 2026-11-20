import Foundation
import SwiftData
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Housekeeping over the outline, on a timer while the app is open (and on iOS background refresh): notices about
/// stale and blocked items, prep tasks for calendar events, and each project's digest. It calls no model. The AI's
/// own work (handed-off items, recommended tasks) is done by `JobQueue`.
@MainActor
@Observable
final class HarnessEngine {
    let container: ModelContainer
    private(set) var running = false
    private(set) var lastRun: Date? = nil
    private(set) var lastResults: [String] = []
    private var timer: Timer? = nil

    init(container: ModelContainer) { self.container = container }

    // MARK: Scheduling
    /// Runs one project's housekeeping and records the run.
    @MainActor
    static func runProject(container: ModelContainer, projectID: UUID, title: String) async -> String {
        let store = Store(container.mainContext)
        let run = store.startRun(projectID: projectID)
        do {
            let out = try await ProjectAgent(container: container, projectID: projectID, provider: MockProvider()).run()
            run.status = "ok"; run.log = out.joined(separator: "\n")
        } catch { run.status = "error"; run.log = error.localizedDescription }
        run.finishedAt = Date()
        store.save()
        return "\(title): \(run.status)\n\(run.log)"
    }

    func start() {
        timer?.invalidate()
        let minutes = max(5, AppSettings.shared.harnessIntervalMinutes)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in Task { @MainActor in _ = await self?.runOnce() } }
        #if os(iOS)
        scheduleBackgroundRefresh()
        #endif
    }
    func stop() { timer?.invalidate(); timer = nil }

    #if os(iOS)
    static let bgIdentifier = "org.schrodinger.harness"
    func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.bgIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: Double(max(15, AppSettings.shared.harnessIntervalMinutes)) * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
    #endif

    // MARK: Run
    @discardableResult
    func runOnce(projectID: UUID? = nil) async -> [String] {
        if running { return ["already running"] }
        running = true
        defer { running = false }
        let store = Store(container.mainContext)
        let ids = store.projects().filter { $0.projectStatus == .active && (projectID == nil || $0.id == projectID) }.map { ($0.id, $0.title) }
        var results: [String] = []
        for (pid, title) in ids { results.append(await HarnessEngine.runProject(container: container, projectID: pid, title: title)) }
        lastRun = Date(); lastResults = results
        // Recommendations ride along: about once a day, when they are on.
        JobQueue.shared.suggestIfDue()
        return results
    }
}

/// One project's housekeeping pass (notices, calendar prep tasks, the digest), and the in-app draft used when the
/// model runs in the app's own process. It never changes structure or the owner's tasks.
@MainActor
struct ProjectAgent {
    let container: ModelContainer
    let projectID: UUID
    let provider: any LanguageModelProvider

    /// The AI has something to do on this item now: an AI item not yet started, or the AI's part of a shared item.
    static func aiTurn(_ t: Node) -> Bool {
        (t.assignee == .ai && t.state.notStarted) || (t.assignee == .shared && t.aiStatus == .pending && (t.state.notStarted || t.state == .in_progress))
    }

    func run() async throws -> [String] {
        let s = Store(container.mainContext)
        let settings = AppSettings.shared
        var out: [String] = []
        guard let project = s.node(projectID), project.isProject else { throw StoreError.invalidMove }
        if project.projectStatus != .active { return ["skip: \(project.projectStatusRaw)"] }

        let tasks = s.descendants(of: projectID)
        let leaves = s.leaves(under: projectID)
        // 2. Blocked chains and AI work waiting on human tasks.
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var waitingOnHuman: [Node] = []
        for t in leaves where t.state != .done {
            let deps = t.deps.compactMap { byID[$0] }
            if deps.contains(where: { $0.state == .blocked }) {
                s.propose(projectID: projectID, nodeID: t.id, type: .blocked_chain, summary: "\"\(t.title)\" is blocked by a blocked dependency")
            }
            if (t.assignee == .ai || (t.assignee == .shared && t.aiStatus == .pending)) && deps.contains(where: { $0.assignee == .human && $0.state != .done }) { waitingOnHuman.append(t) }
        }

        // 3. Stale tasks.
        let cutoff = Date().addingTimeInterval(-Double(settings.staleDays) * 86400)
        for t in tasks where t.state != .done && t.lastActivityAt < cutoff {
            s.propose(projectID: projectID, nodeID: t.id, type: .stale, summary: "\"\(t.title)\" has had no activity for \(settings.staleDays)+ days")
        }

        // 4. An empty project, or one with nothing open and the goal not reached.
        let open = tasks.filter { $0.state != .done }
        let progress = s.progress(of: projectID)
        if tasks.isEmpty {
            s.propose(projectID: projectID, nodeID: nil, type: .new_task, summary: "Project has no tasks. Suggest: \"Define first milestone for \(project.title)\"", payload: ["title": "Define first milestone for \(project.title)", "assignee": "human"])
        } else if open.isEmpty && progress.pct < 100 {
            s.propose(projectID: projectID, nodeID: nil, type: .no_path, summary: "No open tasks but goal not complete — add tasks toward: \(project.goal.isEmpty ? project.title : project.goal)")
        }
        // 4b. Calendar-driven prep proposals (only calendars linked to this project).
        if !project.calendarIDs.isEmpty {
            let evs = await CalendarService.shared.events(days: 7, calendarIDs: project.calendarIDs)
            func norm(_ x: String) -> String { x.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            for e in evs {
                let key = norm(e.title)
                let covered = tasks.contains { norm($0.title).contains(key) || (!norm($0.title).isEmpty && key.contains(norm($0.title))) }
                if !covered && !key.isEmpty {
                    s.propose(projectID: projectID, nodeID: nil, type: .new_task, summary: "Calendar: \"\(e.title)\" on \(e.start.dayString) has no related task — add a prep task?",
                              payload: ["title": "Prepare for: \(e.title)", "assignee": "ai", "tags": ["meeting"], "due": e.start.timeIntervalSince1970])
                }
            }
        }

        // 5. Digest.
        let fresh = s.descendants(of: projectID)
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
        out.append("digest written")
        return out
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
        return try await provider.draft(DraftRequest(system: systemPrompt(project), prompt: lines.joined(separator: "\n\n"), tools: tools, maxTurns: AppSettings.shared.agentMaxTurns))
    }
}
