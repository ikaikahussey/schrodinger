import Foundation
import SwiftData
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Master harness: runs one sub-agent per active project, concurrently, entirely on device.
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
        running = true; defer { running = false }
        let store = Store(container.mainContext)
        let projects = store.projects().filter { $0.projectStatus == .active && (projectID == nil || $0.id == projectID) }
        let provider = AppSettings.shared.makeProvider()
        var results: [String] = []
        await withTaskGroup(of: String.self) { group in
            for p in projects {
                let pid = p.id, title = p.title
                group.addTask { @MainActor in
                    let run = Store(self.container.mainContext).startRun(projectID: pid)
                    do {
                        let out = try await ProjectAgent(container: self.container, projectID: pid, provider: provider).run()
                        run.status = "ok"; run.log = out.joined(separator: "\n")
                    } catch { run.status = "error"; run.log = error.localizedDescription }
                    run.finishedAt = Date()
                    Store(self.container.mainContext).save()
                    return "\(title): \(run.status)\n\(run.log)"
                }
            }
            for await r in group { results.append(r) }
        }
        lastRun = Date(); lastResults = results
        return results
    }
}

/// One project's sub-agent. Allowed to: execute its AI tasks (and the AI part of shared tasks), file proposals,
/// write the digest. Never changes structure or human tasks.
@MainActor
struct ProjectAgent {
    let container: ModelContainer
    let projectID: UUID
    let provider: any LanguageModelProvider

    func run() async throws -> [String] {
        let s = Store(container.mainContext)
        let settings = AppSettings.shared
        var out: [String] = []
        guard let project = s.node(projectID), project.isProject else { throw StoreError.invalidMove }
        if project.projectStatus != .active { return ["skip: \(project.projectStatusRaw)"] }

        let tasks = s.descendants(of: projectID)
        let leaves = s.leaves(under: projectID)

        // 1. Execute ready AI work.
        func aiTurn(_ t: Node) -> Bool {
            (t.assignee == .ai && t.state == .todo) || (t.assignee == .shared && t.aiStatus == .pending && [.todo, .in_progress].contains(t.state))
        }
        let ready = leaves.filter { aiTurn($0) && s.depsSatisfied($0) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(settings.maxTasksPerRun)
        for t in ready {
            let originalState = t.state
            s.update(t, actor: .ai, detail: "picked up by sub-agent") { $0.state = .in_progress }
            s.save()
            do {
                let result = try await draft(project: project, task: t, siblings: tasks.filter { $0.id != t.id })
                if t.assignee == .shared {
                    s.update(t, actor: .ai, detail: "AI part done — your turn (\(result.log.count) tool calls)") { $0.state = .in_progress; $0.aiStatus = .done; $0.artifact = result.artifact }
                } else {
                    s.update(t, actor: .ai, detail: "draft ready for review (\(result.log.count) tool calls)") { $0.state = .review; $0.artifact = result.artifact }
                }
                out.append("drafted: \(t.title)")
            } catch {
                s.update(t, actor: .ai, detail: "draft failed: \(error.localizedDescription)") { $0.state = t.assignee == .shared ? originalState : .todo }
                out.append("failed: \(t.title): \(error.localizedDescription)")
            }
            s.save()
        }

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

        // 4. Structural proposals (heuristics + model).
        let open = tasks.filter { $0.state != .done }
        let progress = s.progress(of: projectID)
        if tasks.isEmpty {
            s.propose(projectID: projectID, nodeID: nil, type: .new_task, summary: "Project has no tasks. Suggest: \"Define first milestone for \(project.title)\"", payload: ["title": "Define first milestone for \(project.title)", "assignee": "human"])
        } else if open.isEmpty && progress.pct < 100 {
            s.propose(projectID: projectID, nodeID: nil, type: .no_path, summary: "No open tasks but goal not complete — add tasks toward: \(project.goal.isEmpty ? project.title : project.goal)")
        }
        let parents = Set(tasks.compactMap(\.parentID))
        for t in open where !parents.contains(t.id) && t.assignee == .ai && t.state == .todo && (t.title.count > 70 || t.title.range(of: "\\band\\b", options: [.regularExpression, .caseInsensitive]) != nil) {
            let parts = t.title.components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let subs = (parts.count > 1 ? parts : [t.title + " — part 1", t.title + " — part 2"]).map { ["title": $0, "assignee": "ai"] }
            s.propose(projectID: projectID, nodeID: t.id, type: .decompose, summary: "\"\(t.title)\" looks like more than one step — split it?", payload: ["subtasks": subs])
        }
        await modelProposals(project: project, open: open, progress: progress, store: s)

        // 4b. Calendar-driven prep proposals (only calendars linked to this project).
        if !project.calendarIDs.isEmpty {
            let evs = await CalendarService.shared.events(days: 7, calendarIDs: project.calendarIDs)
            func norm(_ x: String) -> String { x.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            for e in evs {
                let key = norm(e.title)
                let covered = tasks.contains { norm($0.title).contains(key) || (!norm($0.title).isEmpty && key.contains(norm($0.title))) }
                if !covered && !key.isEmpty {
                    s.propose(projectID: projectID, nodeID: nil, type: .new_task, summary: "Calendar: \"\(e.title)\" on \(e.start.dayString) has no related task — add a prep task?",
                              payload: ["title": "Prepare for: \(e.title)", "assignee": "ai", "mode": "meeting", "due": e.start.timeIntervalSince1970])
                }
            }
        }

        // 5. Digest.
        let fresh = s.descendants(of: projectID)
        let day = Date().dayString
        func grp(_ st: TaskState) -> String { let l = fresh.filter { $0.state == st }.map { "- \($0.title)" }; return l.isEmpty ? "- none" : l.joined(separator: "\n") }
        var needs: [String] = fresh.filter { $0.state == .review }.map { "- review: \($0.title)" }
        needs += fresh.filter { $0.isYourTurn }.map { "- your part: \($0.title)" }
        needs += fresh.filter { $0.assignee == .human && $0.state == .todo && ($0.due.map { $0 < Date() } ?? false) }.map { "- overdue: \($0.title) (\($0.due!.dayString))" }
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

    private func draft(project: Node, task: Node, siblings: [Node]) async throws -> DraftResult {
        let tools = AgentTools.make(container: container, projectID: projectID, taskID: task.id)
        var lines = ["Task: \(task.title)"]
        if let m = task.mode { lines.append("Mode: \(m.rawValue)") }
        if let d = task.due { lines.append("Due: \(d.dayString)") }
        if !task.acceptanceNote.isEmpty { lines.append("Prior review notes from the owner (address these):\n\(task.acceptanceNote)") }
        if task.assignee == .shared { lines.append("This task is SHARED: you do the preparatory part (research, drafting, checklists, materials) and the owner finishes it in person. Produce everything the owner needs to complete their part, and state clearly what remains for them.") }
        lines.append("Use project_context first. Use web_fetch for anything factual you are not sure of. Save working notes with write_file. When the deliverable is ready, call finish with the full draft (or, if you have no finish tool, reply with the full draft). If the task needs information only the owner has, draft what you can and list the questions under \"Needs from you\".")
        return try await provider.draft(DraftRequest(system: systemPrompt(project), prompt: lines.joined(separator: "\n\n"), tools: tools, maxTurns: AppSettings.shared.agentMaxTurns))
    }

    private func modelProposals(project: Node, open: [Node], progress: Store.Progress, store s: Store) async {
        if provider is MockProvider { return }
        let list = open.map { "- [\($0.id.uuidString.prefix(8))] \($0.title) (\($0.assigneeRaw), \($0.stateRaw))" }.joined(separator: "\n")
        let prompt = """
        Open tasks:\n\(list)\nProgress: \(progress.done)/\(progress.total) leaf tasks done.
        Return ONLY a JSON array. Each item: {"type":"decompose"|"new_task"|"reassign","node_prefix":string|null,"summary":string,"payload":object}.
        decompose payload {"subtasks":[{"title","assignee":"ai"|"human"|"shared"}]}; new_task payload {"title","assignee"}; reassign payload {"assignee"}. Return [] if nothing is needed. Max 5 items.
        """
        guard let text = try? await provider.complete(system: systemPrompt(project), prompt: prompt),
              let r = text.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression),
              let arr = (try? JSONSerialization.jsonObject(with: Data(text[r].utf8))) as? [[String: Any]] else { return }
        for item in arr.prefix(5) {
            guard let typeRaw = item["type"] as? String, let type = ProposalType(rawValue: typeRaw), let summary = item["summary"] as? String else { continue }
            let prefix = item["node_prefix"] as? String
            let node = prefix.flatMap { pf in open.first { $0.id.uuidString.hasPrefix(pf) } }
            s.propose(projectID: projectID, nodeID: node?.id, type: type, summary: summary, payload: item["payload"] as? [String: Any] ?? [:])
        }
    }
}
