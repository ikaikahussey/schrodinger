import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device model via Apple's FoundationModels framework (iOS 26 / macOS 26). Nothing leaves the device.
/// The on-device model has a small context window (~4k tokens), so prompts and tool outputs are kept compact.
struct AppleIntelligenceProvider: LanguageModelProvider {
    let name = "Apple Intelligence"

    static var availability: (available: Bool, reason: String) {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return (true, "")
        case .unavailable(let reason): return (false, "\(reason)")
        }
        #else
        return (false, "FoundationModels not available on this OS")
        #endif
    }

    func complete(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        guard Self.availability.available else { throw ProviderError.unavailable(Self.availability.reason) }
        let session = LanguageModelSession(instructions: system)
        return try await session.respond(to: String(prompt.prefix(6000))).content
        #else
        throw ProviderError.unavailable("FoundationModels not available")
        #endif
    }

    func draft(_ req: DraftRequest) async throws -> DraftResult {
        #if canImport(FoundationModels)
        guard Self.availability.available else { throw ProviderError.unavailable(Self.availability.reason) }
        let collector = ToolLog()
        // Apple's framework runs the tool loop itself; we wrap each spec as a Tool. `finish` is replaced by the final response.
        let tools: [any Tool] = req.tools.filter { $0.name != "finish" }.map { BridgedTool(spec: $0, log: collector) }
        let session = LanguageModelSession(tools: tools, instructions: req.system + "\nKeep answers under 600 words. When done, reply with the final draft as markdown.")
        let prompt = String(req.prompt.prefix(3000))
        let response = try await session.respond(to: prompt)
        return DraftResult(artifact: response.content, log: await collector.entries)
        #else
        throw ProviderError.unavailable("FoundationModels not available")
        #endif
    }
}

actor ToolLog {
    var entries: [String] = []
    func add(_ s: String) { entries.append(s) }
}

#if canImport(FoundationModels)
/// Bridges an AgentToolSpec to FoundationModels' Tool protocol. Arguments are a single JSON string to keep
/// the bridge generic; the model is told the expected keys in the description.
struct BridgedTool: Tool {
    let spec: AgentToolSpec
    let log: ToolLog
    var name: String { spec.name }
    var description: String {
        let keys = (spec.schema["properties"] as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? ""
        return spec.description + (keys.isEmpty ? "" : " Provide `json` as a JSON object with keys: \(keys).")
    }

    @Generable
    struct Arguments {
        @Guide(description: "A JSON object with the tool's inputs, e.g. {\"path\":\"notes.md\"}. Use {} when no inputs are needed.")
        var json: String
    }

    func call(arguments: Arguments) async throws -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(arguments.json.utf8))) as? [String: Any] ?? [:]
        do {
            let out = try await spec.run(input)
            await log.add("\(spec.name) → ok")
            return String(out.prefix(3000))   // keep within the on-device context window
        } catch {
            await log.add("\(spec.name) → error")
            return "error: \(error.localizedDescription)"
        }
    }
}
#endif
