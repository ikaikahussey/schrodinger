import AppIntents
import SwiftData

/// "Add to Schrodinger": a Shortcuts action that takes text (a note from Notes, say) and adds it as a new item, its
/// first line the title and its lines and lists the children. To use it from the share sheet in Notes, make a
/// shortcut with this action and turn on "Show in Share Sheet".
struct AddToSchrodinger: AppIntent {
    static let title: LocalizedStringResource = "Add to Schrodinger"
    static let description = IntentDescription("Adds text as a new item: the first line is its title, and the other lines and lists become its children.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to Schrodinger") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(dialog: "There was no text to add.") }
        let ctx = AppData.container.mainContext
        let store = Store(ctx)
        let id = Importer.importNote(trimmed, under: nil, store: store)
        let count = store.children(of: id).count
        return .result(dialog: count == 0 ? "Added to Schrodinger." : "Added to Schrodinger with \(count) item\(count == 1 ? "" : "s") under it.")
    }
}

struct SchrodingerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddToSchrodinger(), phrases: ["Add to \(.applicationName)"], shortTitle: "Add to Schrodinger", systemImageName: "square.and.arrow.down")
    }
}
