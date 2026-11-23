import Foundation

/// A model running on this Mac, reached through a local model server that speaks the OpenAI chat-completions API
/// (Ollama, LM Studio, llama.cpp's server). Nothing leaves the computer and nothing is billed. Like Apple
/// Intelligence it runs in the app's process, so a hand-off needs the app open; the draft goes to the owner for review.
struct LocalProvider: LanguageModelProvider {
    let baseURL: String
    let model: String
    let name = "Local model"

    static let defaultBaseURL = "http://localhost:11434/v1"   // Ollama; LM Studio is http://localhost:1234/v1

    /// The server's address with a path added. Accepts the address with or without the trailing /v1.
    static func url(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.isEmpty { b = defaultBaseURL }
        if !b.contains("://") { b = "http://" + b }
        if !b.hasSuffix("/v1") { b += "/v1" }
        guard let u = URL(string: b + path), ["http", "https"].contains(u.scheme ?? ""), u.host != nil else { return nil }
        return u
    }

    /// The models the server has, by name. Throws when no server answers at the address.
    static func models(baseURL: String) async throws -> [String] {
        guard let u = url(baseURL, "/models") else { throw ProviderError.unavailable("the server address is not a valid URL") }
        var req = URLRequest(url: u); req.timeoutInterval = 5
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw ProviderError.unavailable("no model server answered at \(u.host ?? "")\(u.port.map { ":\($0)" } ?? ""). Start Ollama or LM Studio on this Mac.") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw ProviderError.unavailable("no local model chosen. Pick one in Settings.") }
        guard let u = Self.url(baseURL, "/chat/completions") else { throw ProviderError.unavailable("the server address is not a valid URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 900   // a local model can take minutes on a long draft
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(e.code) {
            throw ProviderError.unavailable("no model server answered at \(u.host ?? ""). Start Ollama or LM Studio on this Mac.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func complete(system: String, prompt: String) async throws -> String {
        let r = try await post(["model": model, "stream": false, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]])
        return Self.text(of: Self.message(of: r))
    }

    func draft(_ req: DraftRequest) async throws -> DraftResult {
        var messages: [[String: Any]] = [["role": "system", "content": req.system], ["role": "user", "content": req.prompt]]
        var log: [String] = []
        var tools = Self.toolsJSON(req.tools)
        for _ in 0..<req.maxTurns {
            var body: [String: Any] = ["model": model, "stream": false, "messages": messages]
            if !tools.isEmpty { body["tools"] = tools }
            let r: [String: Any]
            do { r = try await post(body) }
            catch ProviderError.http(let code, _) where code == 400 && !tools.isEmpty {
                // The chosen model has no tool calling: ask once more for the draft alone.
                tools = []; log.append("model without tools: drafting from the item only")
                messages.append(["role": "user", "content": "You have no tools. Reply with the full draft now, from what is given above."])
                continue
            }
            let msg = Self.message(of: r)
            let calls = Self.toolCalls(of: msg)
            if calls.isEmpty {
                let t = Self.text(of: msg)
                return DraftResult(artifact: t.isEmpty ? "(the model returned no draft)" : t, log: log)
            }
            messages.append(msg)
            for c in calls {
                if c.name == "finish" { log.append("finish"); return DraftResult(artifact: ToolLoop.finishArtifact(c.input), log: log) }
                var out = "", isError = false
                if let tool = req.tools.first(where: { $0.name == c.name }) {
                    do { out = try await tool.call(c.input) } catch { out = "error: \(error.localizedDescription)"; isError = true }
                } else { out = "error: unknown tool \(c.name)"; isError = true }
                log.append("\(c.name) → \(isError ? "error" : "ok")")
                // A local model's window is small: keep what a tool returns short.
                messages.append(["role": "tool", "tool_call_id": c.id, "content": String(out.prefix(12_000))])
            }
        }
        throw ProviderError.turnLimit
    }

    // MARK: Wire format (OpenAI chat completions)

    struct Call { let id: String; let name: String; let input: [String: Any] }

    static func toolsJSON(_ tools: [AgentToolSpec]) -> [[String: Any]] {
        tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
    }

    static func message(of reply: [String: Any]) -> [String: Any] {
        (reply["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] ?? [:]
    }

    /// The reply's text, without the reasoning some local models print between <think> tags.
    static func text(of message: [String: Any]) -> String {
        (message["content"] as? String ?? "")
            .replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tool calls in the reply. Servers send the arguments as JSON text; some send an object.
    static func toolCalls(of message: [String: Any]) -> [Call] {
        (message["tool_calls"] as? [[String: Any]] ?? []).enumerated().compactMap { (i, c) -> Call? in
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String, !name.isEmpty else { return nil }
            let input = (f["arguments"] as? [String: Any]) ?? JSONText.decode(f["arguments"] as? String ?? "{}")
            return Call(id: c["id"] as? String ?? "call_\(i)", name: name, input: input)
        }
    }
}
