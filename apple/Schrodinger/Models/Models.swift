import Foundation
import SwiftData

// All data is stored on device (SwiftData). CloudKit sync between the user's own devices is optional (Settings).
// CloudKit constraints honored: every stored property has a default, no unique constraints, no relationships
// (the tree uses parentID; dependencies use an array of UUIDs).

enum Assignee: String, Codable, CaseIterable, Identifiable {
    case human, ai, shared, unassigned
    var id: String { rawValue }
    var label: String { switch self { case .human: "me"; case .ai: "ai"; case .shared: "both"; case .unassigned: "unassigned" } }
}

enum TaskState: String, Codable, CaseIterable, Identifiable {
    case todo, in_progress, blocked, review, done
    var id: String { rawValue }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ") }
}

enum ProjectStatus: String, Codable, CaseIterable, Identifiable {
    case active, paused, archived
    var id: String { rawValue }
}

enum Mode: String, Codable, CaseIterable, Identifiable {
    case call, errand, email, write, research, meeting, admin, other
    var id: String { rawValue }
}

enum AIStatus: String, Codable { case pending, done }

enum Actor: String, Codable { case human, ai, harness }

@Model
final class Node {
    var id: UUID = UUID()
    var parentID: UUID? = nil
    var title: String = ""
    var goal: String = ""              // projects
    var successCriteria: String = ""   // projects
    var constraints: String = ""       // projects
    var projectStatusRaw: String = ProjectStatus.active.rawValue
    var assigneeRaw: String = Assignee.human.rawValue
    var stateRaw: String = TaskState.todo.rawValue
    var modeRaw: String = ""
    var aiStatusRaw: String = AIStatus.pending.rawValue
    var due: Date? = nil
    var acceptanceNote: String = ""
    var artifact: String? = nil
    var deps: [UUID] = []
    var position: Int = 0
    var collapsed: Bool = false
    var calendarIDs: [String] = []     // projects: EventKit calendars that generate prep proposals
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastActivityAt: Date = Date()

    init(title: String = "", parentID: UUID? = nil, assignee: Assignee? = nil, mode: Mode? = nil, due: Date? = nil, position: Int = 0) {
        self.title = title
        self.parentID = parentID
        self.assigneeRaw = (assignee ?? (parentID == nil ? .unassigned : .human)).rawValue
        self.modeRaw = mode?.rawValue ?? ""
        self.due = due
        self.position = position
    }

    var isProject: Bool { parentID == nil }
    var projectStatus: ProjectStatus { get { ProjectStatus(rawValue: projectStatusRaw) ?? .active } set { projectStatusRaw = newValue.rawValue } }
    var assignee: Assignee { get { Assignee(rawValue: assigneeRaw) ?? .unassigned } set { assigneeRaw = newValue.rawValue } }
    var state: TaskState { get { TaskState(rawValue: stateRaw) ?? .todo } set { stateRaw = newValue.rawValue } }
    var mode: Mode? { get { Mode(rawValue: modeRaw) } set { modeRaw = newValue?.rawValue ?? "" } }
    var aiStatus: AIStatus { get { AIStatus(rawValue: aiStatusRaw) ?? .pending } set { aiStatusRaw = newValue.rawValue } }
    /// Shared task whose AI part is done and which the human still has to finish.
    var isYourTurn: Bool { assignee == .shared && aiStatus == .done && state != .done }
}

enum ProposalType: String, Codable { case new_task, decompose, reassign, stale, blocked_chain, no_path }
enum ProposalStatus: String, Codable { case open, accepted, dismissed }

@Model
final class Proposal {
    var id: UUID = UUID()
    var projectID: UUID = UUID()
    var nodeID: UUID? = nil
    var typeRaw: String = ProposalType.stale.rawValue
    var summary: String = ""
    var payloadJSON: String = "{}"
    var statusRaw: String = ProposalStatus.open.rawValue
    var createdAt: Date = Date()

    init(projectID: UUID, nodeID: UUID?, type: ProposalType, summary: String, payload: [String: Any]) {
        self.projectID = projectID
        self.nodeID = nodeID
        self.typeRaw = type.rawValue
        self.summary = summary
        self.payloadJSON = (try? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)) ?? "{}"
    }
    var type: ProposalType { ProposalType(rawValue: typeRaw) ?? .stale }
    var status: ProposalStatus { get { ProposalStatus(rawValue: statusRaw) ?? .open } set { statusRaw = newValue.rawValue } }
    var payload: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))) as? [String: Any] ?? [:] }
    var isInformational: Bool { [.stale, .blocked_chain, .no_path].contains(type) }
}

@Model
final class ActivityEntry {
    var id: UUID = UUID()
    var nodeID: UUID = UUID()
    var actorRaw: String = Actor.human.rawValue
    var action: String = ""
    var detail: String = ""
    var undoJSON: String? = nil
    var createdAt: Date = Date()
    init(nodeID: UUID, actor: Actor, action: String, detail: String, undo: [String: Any]? = nil) {
        self.nodeID = nodeID; self.actorRaw = actor.rawValue; self.action = action; self.detail = detail
        if let undo, let d = try? JSONSerialization.data(withJSONObject: undo) { undoJSON = String(data: d, encoding: .utf8) }
    }
    var actor: Actor { Actor(rawValue: actorRaw) ?? .human }
    var undo: [String: Any]? { undoJSON.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } }
}

@Model
final class Digest {
    var id: UUID = UUID()
    var projectID: UUID = UUID()
    var day: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    init(projectID: UUID, day: String, body: String) { self.projectID = projectID; self.day = day; self.body = body }
}

@Model
final class WorkspaceFile {
    var id: UUID = UUID()
    var projectID: UUID = UUID()
    var path: String = ""
    var content: String = ""
    var updatedAt: Date = Date()
    init(projectID: UUID, path: String, content: String) { self.projectID = projectID; self.path = path; self.content = content }
}

@Model
final class HarnessRun {
    var id: UUID = UUID()
    var projectID: UUID? = nil
    var startedAt: Date = Date()
    var finishedAt: Date? = nil
    var status: String = "running"
    var log: String = ""
    init(projectID: UUID?) { self.projectID = projectID }
}

extension Date {
    /// Local calendar day as YYYY-MM-DD.
    var dayString: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: self) }
}
