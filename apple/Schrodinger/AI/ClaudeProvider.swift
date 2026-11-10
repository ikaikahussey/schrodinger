import Foundation

/// Calls the Anthropic Messages API directly from the device. The key never leaves the device except to api.anthropic.com.
struct ClaudeProvider: LanguageModelProvider {
    let apiKey: String
    let model: String
    let name = "Claude"
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func complete(system: String, prompt: String) async throws -> String {
        let r = try await post(["model": model, "max_tokens": 1500, "system": system, "messages": [["role": "user", "content": prompt]]])
        return Self.text(of: r)
    }

    func draft(_ req: DraftRequest) async throws -> DraftResult {
        let tools: [[String: Any]] = req.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
        var messages: [[String: Any]] = [["role": "user", "content": req.prompt]]
        var log: [String] = []
        for _ in 0..<req.maxTurns {
            let r = try await post(["model": model, "max_tokens": 4000, "system": req.system, "tools": tools, "messages": messages])
            let content = r["content"] as? [[String: Any]] ?? []
            messages.append(["role": "assistant", "content": content])
            let uses = content.filter { $0["type"] as? String == "tool_use" }
            if uses.isEmpty { return DraftResult(artifact: Self.text(of: r).isEmpty ? "(agent returned no draft)" : Self.text(of: r), log: log) }
            var results: [[String: Any]] = []
            for u in uses {
                let name = u["name"] as? String ?? ""
                let input = u["input"] as? [String: Any] ?? [:]
                let id = u["id"] as? String ?? ""
                if name == "finish" { log.append("finish"); return DraftResult(artifact: ToolLoop.finishArtifact(input), log: log) }
                var out = "", isError = false
                if let tool = req.tools.first(where: { $0.name == name }) {
                    do { out = try await tool.run(input) } catch { out = "error: \(error.localizedDescription)"; isError = true }
                } else { out = "error: unknown tool \(name)"; isError = true }
                log.append("\(name) → \(isError ? "error" : "ok")")
                results.append(["type": "tool_result", "tool_use_id": id, "content": String(out.prefix(60_000)), "is_error": isError])
            }
            messages.append(["role": "user", "content": results])
        }
        throw ProviderError.turnLimit
    }

    private static func text(of r: [String: Any]) -> String {
        (r["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Deterministic offline provider that exercises the same tool loop.
struct MockProvider: LanguageModelProvider {
    let name = "Mock"
    func complete(system: String, prompt: String) async throws -> String { "[]" }
    func draft(_ req: DraftRequest) async throws -> DraftResult {
        var log: [String] = []
        if let ctx = req.tools.first(where: { $0.name == "project_context" }) { _ = try? await ctx.run([:]); log.append("project_context → ok") }
        if let w = req.tools.first(where: { $0.name == "write_file" }) { _ = try? await w.run(["path": "notes/mock.md", "content": "# Notes\n\(req.prompt.prefix(200))"]); log.append("write_file → ok") }
        log.append("finish")
        let title = req.prompt.split(separator: "\n").first.map(String.init) ?? "task"
        let notes = req.prompt.contains("Prior review notes") ? "\n\n## Revisions addressing review notes\n" + (req.prompt.components(separatedBy: "Prior review notes from the owner (address these):\n").last?.components(separatedBy: "\n\n").first ?? "") : ""
        return DraftResult(artifact: "# Draft: \(title.replacingOccurrences(of: "Task: ", with: ""))\n\n## Content\n1. Scope the work.\n2. Identify inputs and owners.\n3. Produce the deliverable.\(notes)\n\n## Needs from you\n- Confirm scope.\n\n_(mock draft — choose a model in Settings for real output)_", log: log)
    }
}
