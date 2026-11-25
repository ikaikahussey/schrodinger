import Foundation
import SwiftData
import Observation

/// One piece of work given to the AI: an item handed off, an item woven into one piece from the items under it, or a
/// pass over the outline to recommend tasks.
/// Jobs belong to the device that started them (the request in flight is this device's), so they are kept in a file
/// here and not in the synced store. What a job produces is written to the outline, which does sync.
struct AgentJob: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case handoff, suggest, weave }
    enum Status: String, Codable, Sendable { case queued, working, needsYou, done, failed }
    /// `background`: one request carried by the system, which finishes with the app closed (Claude).
    /// `inProcess`: run by the app itself while it is open (Apple Intelligence, a local model).
    enum Route: String, Codable, Sendable { case background, inProcess }

    var id = UUID()
    var kind: Kind
    var nodeID: UUID? = nil
    var title = ""
    var status: Status = .queued
    var route: Route = .inProcess
    /// The item's status before it was handed off; put back if the job fails.
    var priorState = ""
    /// What came of it, in a line.
    var summary = ""
    var error = ""
    /// Times a paused turn was continued.
    var continuations = 0
    var createdAt = Date()
    var finishedAt: Date? = nil

    /// Stands for "needs you" wherever the app says so: the AI has returned and the owner has something to do.
    static let needsYouMark = "🚦"

    /// Still to be done or under way.
    var live: Bool { status == .queued || status == .working }

    /// Where the job stands, in a line. Shown on the item's own row in the outline.
    var statusLine: String {
        switch status {
        case .queued: "Waiting for the AI: another item is ahead of this one"
        case .working:
            kind == .weave
                ? (route == .background ? "Weaving the items under this into one piece" : "Weaving the items under this into one piece. Keep the app open.")
                : route == .background
                ? (continuations > 0 ? "The AI is working on this (a long one, still going)" : "The AI is working on this")
                : "The AI is working on this. Keep the app open."
        case .needsYou: summary.isEmpty ? AgentJob.needsYouMark : "\(AgentJob.needsYouMark) \(summary)"
        case .done: summary.isEmpty ? "Done by the AI" : "AI: \(summary)"
        case .failed: error.isEmpty ? failedLead : "\(failedLead): \(error)"
        }
    }
    /// What went wrong, in three words.
    var failedLead: String { kind == .weave ? "The weave failed" : "The hand-off failed" }
}

/// The AI's work queue. Nothing enters it unless the owner asks. Handing an item off makes a job and starts it at once; jobs run side by side and do not
/// wait for each other. When a job finishes, its result is applied to the outline, the item is marked as having an
/// unseen result, and a notification is posted.
@MainActor
@Observable
final class JobQueue {
    static let shared = JobQueue()

    /// Newest first.
    private(set) var jobs: [AgentJob] = []
    /// Items with a result the owner has not opened yet (this device).
    private(set) var unseen: Set<UUID> = []

    @ObservationIgnored private var resumed = false
    @ObservationIgnored private var inProcessBusy = false
    private var container: ModelContainer { AppData.container }

    private init() {}

    // MARK: Reading

    func job(_ id: UUID) -> AgentJob? { jobs.first { $0.id == id } }
    /// The item's most recent job.
    func latest(for nodeID: UUID) -> AgentJob? { jobs.first { $0.nodeID == nodeID } }
    func isLive(_ nodeID: UUID) -> Bool { jobs.contains { $0.nodeID == nodeID && $0.live } }
    /// The item's last job failed (and it has not been retried or dismissed).
    func failure(for nodeID: UUID) -> AgentJob? { latest(for: nodeID).flatMap { $0.status == .failed ? $0 : nil } }
    var suggesting: Bool { jobs.contains { $0.kind == .suggest && $0.live } }
    var working: Int { jobs.filter(\.live).count }

    // MARK: Starting work

    /// Hands items to the AI. Each becomes a job that starts now. An item held by the owner becomes the AI's.
    func handOff(_ ids: [UUID]) {
        resume()
        let s = Store(container.mainContext)
        var any = false
        for id in ids {
            guard let n = s.node(id), !n.isDeleted, !n.isProject, !isLive(id) else { continue }
            jobs.removeAll { $0.nodeID == id && $0.status == .failed }
            var job = AgentJob(kind: .handoff, nodeID: id, title: n.title)
            job.priorState = n.stateRaw
            s.update(n, actor: .ai, detail: "handed off to the AI") { x in
                if x.assignee == .human || x.assignee == .unassigned { x.assignee = .ai }
                if x.assignee == .shared { x.aiStatus = .pending }
                x.state = .in_progress
            }
            jobs.insert(job, at: 0)
            any = true
        }
        guard any else { return }
        s.save()
        trim(); persist(); pump()
        Task { await ResultNotifier.prepare() }
    }

    /// Asks the AI to look over the outline and recommend tasks. Only ever called from the menu command: the AI
    /// does not do this on its own.
    func suggest() {
        resume()
        guard !suggesting else { return }
        jobs.insert(AgentJob(kind: .suggest, title: "Recommend tasks"), at: 0)
        trim(); persist(); pump()
    }

    /// Weaves an item and everything under it into one piece of writing, which is put on the item as its result.
    /// Only for an item that has items under it. The item's status and holder are left as they are.
    func weave(_ id: UUID) {
        resume()
        let s = Store(container.mainContext)
        guard let n = s.node(id), !n.isDeleted, !isLive(id), !s.children(of: id).isEmpty else { return }
        jobs.removeAll { $0.nodeID == id && $0.status == .failed }
        jobs.insert(AgentJob(kind: .weave, nodeID: id, title: n.title), at: 0)
        trim(); persist(); pump()
        Task { await ResultNotifier.prepare() }
    }

    /// Runs a failed item again.
    func retry(_ nodeID: UUID) { if latest(for: nodeID)?.kind == .weave { weave(nodeID) } else { handOff([nodeID]) } }
    /// Forgets the item's failed job (its warning goes away).
    func dismissFailure(_ nodeID: UUID) { jobs.removeAll { $0.nodeID == nodeID && $0.status == .failed }; persist() }
    func markSeen(_ nodeID: UUID) { if unseen.remove(nodeID) != nil { persist() } }
    func clearFinished() { jobs.removeAll { !$0.live }; unseen = []; persist() }

    /// Stops a job that is under way and puts its item back as it was.
    func cancel(_ id: UUID) {
        guard let job = job(id), job.live else { return }
        if job.route == .background { Task { await BackgroundTransport.shared.cancel(jobID: id) } }
        restoreItem(job)
        jobs.removeAll { $0.id == id }
        removeBody(id); persist()
    }

    // MARK: Launch

    /// Call at launch (and when iOS wakes the app for a finished transfer): loads the queue, lets replies that
    /// arrived while the app was not running come in, and restarts what was interrupted.
    func resume() {
        guard !resumed else { return }
        resumed = true
        load()
        BackgroundTransport.shared.wake()
        // Work the app was doing itself stopped when it closed: start it again.
        for i in jobs.indices where jobs[i].live && jobs[i].route == .inProcess { jobs[i].status = .queued }
        pump()
        Task { @MainActor in
            // Give finished transfers a moment to report. A job still marked working with no request in flight after
            // that lost its request (the app was force-quit, say): send it again.
            try? await Task.sleep(for: .seconds(8))
            let active = await BackgroundTransport.shared.activeJobIDs()
            for job in self.jobs where job.status == .working && job.route == .background && !active.contains(job.id) {
                if let body = self.storedBody(job.id) { self.post(job.id, body: body) } else { await self.sendFirst(job.id) }
            }
        }
    }

    // MARK: Running

    private func pump() {
        let settings = AppSettings.shared
        let useClaude = settings.provider == .claude && !settings.anthropicKey.isEmpty
        for i in jobs.indices where jobs[i].status == .queued {
            let id = jobs[i].id
            if useClaude {
                jobs[i].route = .background; jobs[i].status = .working
                Task { await self.sendFirst(id) }
            } else if !inProcessBusy {
                inProcessBusy = true
                jobs[i].route = .inProcess; jobs[i].status = .working
                Task { await self.runInProcess(id) }
            }
        }
        persist()
    }

    /// Builds the job's request and sends it.
    private func sendFirst(_ id: UUID) async {
        guard let job = job(id), job.live else { return }
        let model = AppSettings.shared.claudeModel
        switch job.kind {
        case .handoff:
            guard let nodeID = job.nodeID, let brief = await HandoffBrief.make(nodeID: nodeID, container: container) else { fail(id, "The item no longer exists."); return }
            post(id, body: ClaudeRequest.handoffBody(model: model, system: brief.system, prompt: brief.prompt, serverTools: true))
        case .suggest:
            guard let brief = await SuggestBrief.make(container: container) else { finish(id, .done, summary: "Nothing in the outline yet."); return }
            post(id, body: ClaudeRequest.suggestBody(model: model, system: brief.system, prompt: brief.prompt))
        case .weave:
            guard let nodeID = job.nodeID, let brief = WeaveBrief.make(nodeID: nodeID, container: container) else { fail(id, "There is nothing under the item to weave."); return }
            post(id, body: ClaudeRequest.weaveBody(model: model, system: brief.system, prompt: brief.prompt))
        }
    }

    private func post(_ id: UUID, body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { fail(id, "The request could not be built."); return }
        try? data.write(to: bodyURL(id), options: .atomic)
        let request = ClaudeRequest.urlRequest(apiKey: AppSettings.shared.anthropicKey, serverTools: ClaudeRequest.hasServerTools(body))
        BackgroundTransport.shared.send(jobID: id, request: request, body: data)
    }

    /// A background request finished: `status` and `data` are the HTTP reply, `error` a transport failure.
    func received(jobID: UUID, status: Int, data: Data?, error: String?) {
        resume()
        guard let job = job(jobID), job.live else { return }
        if let error { fail(jobID, error); return }
        let json = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            // Web search or web fetch is not available to this key or model: do the job without them.
            if status == 400 || status == 403, let body = storedBody(jobID), ClaudeRequest.hasServerTools(body) {
                post(jobID, body: ClaudeRequest.withoutServerTools(body)); return
            }
            // The chosen model writes less at a time than a weave asks for: ask for what it can give.
            if status == 400, job.kind == .weave, var body = storedBody(jobID), (body["max_tokens"] as? Int ?? 0) > ClaudeRequest.weaveFallbackTokens {
                body["max_tokens"] = ClaudeRequest.weaveFallbackTokens
                post(jobID, body: body); return
            }
            fail(jobID, ClaudeRequest.errorMessage(json) ?? "The model service answered with an error (\(status)).")
            return
        }
        switch ClaudeRequest.interpret(json) {
        case .tool(let name, let input):
            if job.kind == .handoff, name == ClaudeRequest.submitResult { complete(jobID, HandoffResult.parse(input)) }
            else if job.kind == .suggest { recommended(jobID, input["suggestions"] as? [[String: Any]] ?? []) }
            else { fail(jobID, "The model answered in a form the app does not read.") }
        case .text(let text):
            // Answered without handing in through the tool: the text is the result, for the owner to look over.
            switch job.kind {
            case .handoff: complete(jobID, HandoffResult(summary: "Result ready for you to review.", markdown: text, done: false))
            case .weave: woven(jobID, text, cut: json["stop_reason"] as? String == "max_tokens")
            case .suggest: recommended(jobID, SuggestBrief.parse(text))
            }
        case .paused(let content):
            guard job.continuations < 6, let body = storedBody(jobID) else { fail(jobID, "The work took too long to finish."); return }
            if let i = jobs.firstIndex(where: { $0.id == jobID }) { jobs[i].continuations += 1 }
            persist()
            post(jobID, body: ClaudeRequest.continued(body, assistantContent: content))
        case .empty:
            fail(jobID, "The model returned nothing.")
        }
    }

    private func runInProcess(_ id: UUID) async {
        defer { inProcessBusy = false; pump() }
        guard let job = job(id), job.live else { return }
        let provider = AppSettings.shared.makeProvider()
        do {
            switch job.kind {
            case .handoff:
                guard let nodeID = job.nodeID else { fail(id, "The item no longer exists."); return }
                let result = try await InProcessAgent.handoff(nodeID: nodeID, container: container, provider: provider)
                complete(id, result)
            case .suggest:
                let items = try await InProcessAgent.suggest(container: container, provider: provider)
                recommended(id, items)
            case .weave:
                // A model on the device reads far less than Claude: it gets as many threads as fit.
                let budget = AppSettings.shared.provider == .apple ? 5_000 : 24_000
                guard let nodeID = job.nodeID, let brief = WeaveBrief.make(nodeID: nodeID, container: container, budget: budget) else { fail(id, "There is nothing under the item to weave."); return }
                let text = try await provider.complete(system: brief.system, prompt: brief.prompt)
                woven(id, text)
            }
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    // MARK: Finishing

    /// Applies a hand-off's result to its item and tells the owner.
    private func complete(_ id: UUID, _ result: HandoffResult) {
        guard let job = job(id), job.live, let nodeID = job.nodeID else { return }
        let s = Store(container.mainContext)
        guard let n = s.node(nodeID), !n.isDeleted else { finish(id, .done, summary: "The item was deleted before the work came back."); return }
        let outcome = s.applyHandoff(result, to: n)
        s.save()
        unseen.insert(nodeID)
        let line = result.summary.isEmpty ? (outcome == .done ? "Done." : "Result ready.") : result.summary
        finish(id, outcome == .done ? .done : .needsYou, summary: line)
        let title = n.title.isEmpty ? "(untitled)" : n.title
        let heading = switch outcome {
        case .done: "Ready for review: \(title)"
        case .needsYou: "\(AgentJob.needsYouMark) \(title)"
        case .yourTurn: "Your turn: \(title)"
        }
        Task { await ResultNotifier.post(title: heading, body: line, nodeID: nodeID) }
    }

    /// Puts a woven piece on its item and tells the owner. `cut`: the model ran out of room before the end.
    private func woven(_ id: UUID, _ text: String, cut: Bool = false) {
        guard let job = job(id), job.live, let nodeID = job.nodeID else { return }
        let s = Store(container.mainContext)
        guard let n = s.node(nodeID), !n.isDeleted else { finish(id, .done, summary: "The item was deleted before the piece came back."); return }
        guard let piece = s.applyWeave(text, to: n) else { fail(id, "The model returned nothing."); return }
        s.save()
        unseen.insert(nodeID)
        let threads = s.descendants(of: nodeID).count
        let words = WeaveLinks.withoutThreadList(piece).split(whereSeparator: { $0.isWhitespace }).count
        var line = "Woven from \(threads) \(threads == 1 ? "item" : "items"): \(words) words."
        if cut { line += " It was cut off at the model's length limit." }
        finish(id, .done, summary: line)
        let title = n.title.isEmpty ? "(untitled)" : n.title
        Task { await ResultNotifier.post(title: "Woven: \(title)", body: line, nodeID: nodeID) }
    }

    private func recommended(_ id: UUID, _ items: [[String: Any]]) {
        let s = Store(container.mainContext)
        let added = SuggestBrief.file(items, store: s)
        s.save()
        finish(id, .done, summary: added == 0 ? "Nothing new to recommend." : added == 1 ? "1 task recommended." : "\(added) tasks recommended.")
    }

    private func finish(_ id: UUID, _ status: AgentJob.Status, summary: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = status
        jobs[i].summary = summary
        jobs[i].finishedAt = Date()
        removeBody(id); persist()
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].live else { return }
        jobs[i].status = .failed
        jobs[i].error = message
        jobs[i].finishedAt = Date()
        let job = jobs[i]
        restoreItem(job)
        removeBody(id); persist()
        if job.kind != .suggest, let nodeID = job.nodeID {
            Task { await ResultNotifier.post(title: "Could not finish: \(job.title)", body: message, nodeID: nodeID) }
        }
    }

    /// Puts a handed-off item's status back to what it was before the job took it.
    private func restoreItem(_ job: AgentJob) {
        guard job.kind == .handoff, let nodeID = job.nodeID else { return }
        let s = Store(container.mainContext)
        guard let n = s.node(nodeID), !n.isDeleted, n.state == .in_progress, let was = TaskState(rawValue: job.priorState), was != .in_progress else { return }
        s.update(n, actor: .ai, detail: "hand-off did not finish") { $0.state = was }
        s.save()
    }

    // MARK: Storage (this device)

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func bodyURL(_ id: UUID) -> URL { Self.folder.appendingPathComponent("\(id.uuidString).request.json") }
    private func storedBody(_ id: UUID) -> [String: Any]? {
        guard let d = try? Data(contentsOf: bodyURL(id)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    private func removeBody(_ id: UUID) { try? FileManager.default.removeItem(at: bodyURL(id)) }

    private struct Saved: Codable { var jobs: [AgentJob]; var unseen: [UUID] }

    private func load() {
        guard let d = try? Data(contentsOf: Self.folder.appendingPathComponent("queue.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        jobs = saved.jobs
        unseen = Set(saved.unseen)
    }
    private func persist() {
        guard let d = try? JSONEncoder().encode(Saved(jobs: jobs, unseen: Array(unseen))) else { return }
        try? d.write(to: Self.folder.appendingPathComponent("queue.json"), options: .atomic)
    }
    /// Finished jobs are kept for a month, sixty at most.
    private func trim() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        jobs.removeAll { !$0.live && ($0.finishedAt ?? $0.createdAt) < cutoff }
        while jobs.count > 60, let i = jobs.lastIndex(where: { !$0.live }) { jobs.remove(at: i) }
    }
}
