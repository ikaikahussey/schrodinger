import Foundation
import SwiftData

/// Builds the draft-only tool set for one project's sub-agent. Reads/writes go through a snapshot + a
/// MainActor-hopping writer so tools can run from any task.
enum AgentTools {
    nonisolated static func schema(_ props: [String: Any], required: [String] = []) -> String {
        var s: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { s["required"] = required }
        return JSONText.encode(s)
    }
    nonisolated static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    nonisolated static func json(_ v: Any) -> String { JSONText.encode(v) }

    nonisolated static func make(container: ModelContainer, projectID: UUID, taskID: UUID) -> [AgentToolSpec] {
        return [
            AgentToolSpec(name: "project_context", description: "Get the project goal, success criteria, constraints, and all tasks with state, assignee, mode, due date, notes and existing artifacts.", schemaJSON: schema([:])) { _ in
                return await MainActor.run {
                    let s = Store(container.mainContext)
                    guard let p = s.node(projectID) else { return "{}" }
                    let tasks = s.descendants(of: p.id).map { t -> [String: Any] in
                        var d: [String: Any] = ["id": t.id.uuidString, "title": t.title, "assignee": t.assigneeRaw, "state": t.stateRaw, "mode": t.modeRaw]
                        if let due = t.due { d["due"] = due.dayString }
                        if !t.acceptanceNote.isEmpty { d["acceptance_note"] = t.acceptanceNote }
                        if !t.notes.isEmpty { d["notes"] = t.notes }
                        if let a = t.artifact { d["artifact"] = String(a.prefix(1500)) }
                        if t.parentID != p.id { d["parent_id"] = t.parentID?.uuidString }
                        return d
                    }
                    return Self.json(["project": ["title": p.title, "goal": p.goal, "success_criteria": p.successCriteria, "constraints": p.constraints], "current_task_id": taskID.uuidString, "tasks": tasks])
                }
            },
            AgentToolSpec(name: "web_fetch", description: "Fetch a public http(s) URL and return its text (HTML stripped, truncated). Read-only.", schemaJSON: schema(["url": str("The URL")], required: ["url"])) { inputJSON in
                let input = JSONText.decode(inputJSON)
                guard let u = URL(string: input["url"] as? String ?? ""), ["http", "https"].contains(u.scheme ?? "") else { throw ToolError.badInput("http(s) URL required") }
                var req = URLRequest(url: u); req.timeoutInterval = 20
                req.setValue("schrodinger-agent/0.1", forHTTPHeaderField: "user-agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                var text = String(data: data, encoding: .utf8) ?? ""
                let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type") ?? ""
                if ct.contains("html") {
                    text = text.replacingOccurrences(of: "<script[\\s\\S]*?</script>|<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                        .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
                }
                return Self.json(["status": (resp as? HTTPURLResponse)?.statusCode ?? 0, "text": String(text.prefix(200_000))])
            },
            AgentToolSpec(name: "list_files", description: "List files in this project's workspace.", schemaJSON: schema(["subdir": str("Optional folder prefix")])) { inputJSON in
                let input = JSONText.decode(inputJSON)
                return await MainActor.run {
                    let s = Store(container.mainContext)
                    let pre = Self.safePath(input["subdir"] as? String ?? "", allowEmpty: true)
                    let files = s.files(for: projectID).filter { pre.isEmpty || $0.path.hasPrefix(pre + "/") || $0.path.hasPrefix(pre) }
                    return Self.json(["files": files.map { ["path": $0.path, "bytes": $0.content.utf8.count] }])
                }
            },
            AgentToolSpec(name: "read_file", description: "Read a text file from this project's workspace.", schemaJSON: schema(["path": str("Workspace-relative path")], required: ["path"])) { inputJSON in
                let input = JSONText.decode(inputJSON)
                let p = try Self.safePathThrowing(input["path"] as? String ?? "")
                return try await MainActor.run {
                    let s = Store(container.mainContext)
                    guard let f = s.file(projectID, p) else { throw ToolError.badInput("no such file") }
                    return Self.json(["path": p, "content": f.content])
                }
            },
            AgentToolSpec(name: "write_file", description: "Write a text file into this project's workspace (drafts, notes, data). Overwrites.", schemaJSON: schema(["path": str("Workspace-relative path"), "content": str("File content")], required: ["path", "content"])) { inputJSON in
                let input = JSONText.decode(inputJSON)
                let p = try Self.safePathThrowing(input["path"] as? String ?? "")
                let content = input["content"] as? String ?? ""
                guard content.utf8.count <= 500_000 else { throw ToolError.badInput("content too large") }
                return await MainActor.run {
                    let s = Store(container.mainContext); s.writeFile(projectID, p, content); s.save()
                    return Self.json(["path": p, "bytes": content.utf8.count])
                }
            },
            AgentToolSpec(name: "calendar_events", description: "List the owner's calendar events for the next 14 days (title, start, end, location). Read-only.", schemaJSON: schema([:])) { _ in
                let evs = await CalendarService.shared.events()
                let f = ISO8601DateFormatter()
                return Self.json(["events": evs.map { ["title": $0.title, "start": f.string(from: $0.start), "end": f.string(from: $0.end), "all_day": $0.allDay, "location": $0.location, "calendar": $0.calendarTitle] }])
            },
            AgentToolSpec(name: "finish", description: "Submit the final draft for human review. Call exactly once when done.", schemaJSON: schema(["artifact": str("The deliverable, markdown"), "needs_from_human": ["type": "array", "items": ["type": "string"]]], required: ["artifact"])) { inputJSON in
                ToolLoop.finishArtifact(JSONText.decode(inputJSON))
            },
        ]
    }

    nonisolated static func safePath(_ raw: String, allowEmpty: Bool = false) -> String {
        let p = raw.replacingOccurrences(of: "\\", with: "/")
        if p.hasPrefix("/") || p.split(separator: "/").contains("..") { return "" }
        return (p as NSString).standardizingPath
    }
    nonisolated static func safePathThrowing(_ raw: String) throws -> String {
        let p = safePath(raw)
        if p.isEmpty || p == "." { throw ToolError.badInput("path escapes project workspace") }
        return p
    }
}

enum ToolError: LocalizedError {
    case badInput(String)
    var errorDescription: String? { if case .badInput(let m) = self { return m }; return nil }
}
