import Foundation

/// A tool the agent may call. Draft-only by construction: no tool sends, posts, or contacts anyone.
struct AgentToolSpec: Sendable {
    let name: String
    let description: String
    let schemaJSON: String               // JSON Schema (as text) for Claude
    let run: @Sendable (String) async throws -> String   // input: JSON object text; returns text (JSON or markdown)

    var schema: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) as? [String: Any] ?? ["type": "object", "properties": [:]] }
    var propertyKeys: [String] { (schema["properties"] as? [String: Any])?.keys.sorted() ?? [] }
    func call(_ input: [String: Any]) async throws -> String { try await run(JSONText.encode(input)) }
}

enum JSONText {
    static func encode(_ v: Any) -> String { (try? String(data: JSONSerialization.data(withJSONObject: v), encoding: .utf8)) ?? "{}" }
    static func decode(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }
}

struct DraftRequest: Sendable {
    let system: String
    let prompt: String
    let tools: [AgentToolSpec]
    let maxTurns: Int
}

struct DraftResult: Sendable {
    let artifact: String
    let log: [String]
}

protocol LanguageModelProvider: Sendable {
    var name: String { get }
    func draft(_ req: DraftRequest) async throws -> DraftResult
    /// Free-form JSON-returning call used for analysis (proposals). Returns raw text; caller parses.
    func complete(system: String, prompt: String) async throws -> String
}

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case apple, claude, mock
    var id: String { rawValue }
    var label: String { switch self { case .apple: "Apple Intelligence (on device)"; case .claude: "Claude (Anthropic API)"; case .mock: "Mock (offline)" } }
}

enum ProviderError: LocalizedError {
    case noAPIKey, http(Int, String), unavailable(String), turnLimit
    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No API key. Add one in Settings."
        case .http(let c, let b): "API error \(c): \(b.prefix(300))"
        case .unavailable(let r): "Model unavailable: \(r)"
        case .turnLimit: "Agent hit the turn limit without finishing"
        }
    }
}

/// The agentic loop used by providers that support tool calling via JSON (Claude). Apple's framework runs its own loop.
enum ToolLoop {
    static func finishArtifact(_ input: [String: Any]) -> String {
        let a = input["artifact"] as? String ?? ""
        let needs = input["needs_from_human"] as? [String] ?? []
        return needs.isEmpty ? a : a + "\n\n## Needs from you\n" + needs.map { "- \($0)" }.joined(separator: "\n")
    }
}
