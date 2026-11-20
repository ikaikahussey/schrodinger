import Foundation

/// The Anthropic Messages API requests a job sends, and how its replies are read. A hand-off is one request: Claude
/// runs web search and web fetch on Anthropic's side (server tools), so the app does not have to stay awake to drive
/// each step, and it finishes by calling `submit_result`. Pure functions: no network here.
enum ClaudeRequest {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let submitResult = "submit_result"
    static let submitSuggestions = "submit_suggestions"
    static let webFetchBeta = "web-fetch-2025-09-10"

    static func urlRequest(apiKey: String, serverTools: Bool) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if serverTools { req.setValue(webFetchBeta, forHTTPHeaderField: "anthropic-beta") }
        // The reply arrives all at once when the work is done, which can take minutes.
        req.timeoutInterval = 900
        return req
    }

    static func handoffBody(model: String, system: String, prompt: String, serverTools: Bool) -> [String: Any] {
        var tools: [[String: Any]] = []
        if serverTools {
            tools.append(["type": "web_search_20250305", "name": "web_search", "max_uses": 6])
            tools.append(["type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 6])
        }
        tools.append(["name": submitResult,
                      "description": "Hand in the finished work and the changes to make to the owner's outline. Call exactly once, as your last step.",
                      "input_schema": HandoffResult.schema])
        return ["model": model, "max_tokens": 8000, "system": system, "tools": tools,
                "messages": [["role": "user", "content": prompt]]]
    }

    static func suggestBody(model: String, system: String, prompt: String) -> [String: Any] {
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "parent_id": ["type": "string", "description": "The id (the text in square brackets) of the item the new task goes under"],
                "title": ["type": "string", "description": "The task, as a short imperative"],
                "assignee": ["type": "string", "enum": ["human", "ai", "shared"], "description": "ai = you could do it alone (research, drafting); human = only the owner can; shared = you prepare, the owner finishes"],
                "reason": ["type": "string", "description": "One short plain sentence: why this is worth doing now"],
                "due": ["type": "string", "description": "Optional date, YYYY-MM-DD, only when the outline or calendar implies one"],
            ],
            "required": ["parent_id", "title", "assignee", "reason"],
        ]
        let tool: [String: Any] = [
            "name": submitSuggestions,
            "description": "Recommend new tasks for the owner's outline. Call exactly once. An empty list is a fine answer.",
            "input_schema": ["type": "object", "properties": ["suggestions": ["type": "array", "items": item]], "required": ["suggestions"]],
        ]
        return ["model": model, "max_tokens": 2000, "system": system, "tools": [tool],
                "tool_choice": ["type": "tool", "name": submitSuggestions],
                "messages": [["role": "user", "content": prompt]]]
    }

    /// The request asks for tools Anthropic runs (web search, web fetch).
    static func hasServerTools(_ body: [String: Any]) -> Bool {
        (body["tools"] as? [[String: Any]] ?? []).contains { $0["type"] != nil }
    }
    /// The same request without web search and web fetch, for a key or model that can't use them.
    static func withoutServerTools(_ body: [String: Any]) -> [String: Any] {
        var b = body
        b["tools"] = (body["tools"] as? [[String: Any]] ?? []).filter { $0["type"] == nil }
        return b
    }
    /// The request that continues a turn the API paused: the paused reply is sent back as it came.
    static func continued(_ body: [String: Any], assistantContent: [[String: Any]]) -> [String: Any] {
        var b = body
        var messages = body["messages"] as? [[String: Any]] ?? []
        messages.append(["role": "assistant", "content": assistantContent])
        b["messages"] = messages
        return b
    }

    enum Reply {
        /// Claude called one of the app's tools (`submit_result`, `submit_suggestions`).
        case tool(name: String, input: [String: Any])
        /// Claude answered in text without calling the tool.
        case text(String)
        /// The API paused a long turn; send `content` back to continue it.
        case paused([[String: Any]])
        case empty
    }

    static func interpret(_ json: [String: Any]) -> Reply {
        let content = json["content"] as? [[String: Any]] ?? []
        for block in content where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? ""
            if name == submitResult || name == submitSuggestions { return .tool(name: name, input: block["input"] as? [String: Any] ?? [:]) }
        }
        if json["stop_reason"] as? String == "pause_turn" { return .paused(content) }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .empty : .text(text)
    }

    /// The error message in an API error reply, if it has one.
    static func errorMessage(_ json: [String: Any]) -> String? {
        (json["error"] as? [String: Any])?["message"] as? String
    }
}
