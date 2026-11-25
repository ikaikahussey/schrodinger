import Foundation

/// Calls the Anthropic Messages API directly from the device. The key never leaves the device except to api.anthropic.com.
struct ClaudeProvider: LanguageModelProvider {
    let apiKey: String
    let model: String
    let name = "Claude"
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw ProviderError.noAPIKey }
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
                    do { out = try await tool.call(input) } catch { out = "error: \(error.localizedDescription)"; isError = true }
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

/// A Claude model the owner can choose in Settings.
struct ClaudeModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// The Claude models offered in Settings: the list the key can use, asked of the Anthropic Models API, and a
/// built-in list shown until that answer arrives or when it can't be had.
enum ClaudeModels {
    static let defaultID = "claude-sonnet-5-5"
    static let builtIn = [
        ClaudeModel(id: "claude-fable-5-2", name: "Claude Fable 5.2"),
        ClaudeModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
        ClaudeModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
        ClaudeModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
    ]
    static let endpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!

    /// The models in a Models API reply, in the order given (newest first). Deprecated and retired ones are left out.
    static func parse(_ json: [String: Any]) -> [ClaudeModel] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            if let life = m["lifecycle"] as? String, life != "active" { return nil }
            let name = (m["display_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return ClaudeModel(id: id, name: name.isEmpty ? id : name)
        }
    }

    /// The models this key can use.
    static func fetch(apiKey: String) async throws -> [ClaudeModel] {
        guard !apiKey.isEmpty else { throw ProviderError.noAPIKey }
        var req = URLRequest(url: endpoint)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            throw ProviderError.http(code, ClaudeRequest.errorMessage(json) ?? String(data: data, encoding: .utf8) ?? "")
        }
        return parse(json)
    }
}
