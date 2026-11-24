import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The panels behind "Open outline…" and "Save outline…" in the header menu (see `OutlineFile`). Opening a file
/// replaces the outline on screen, so it asks first unless the outline is empty. Kept on a view of its own:
/// several file panels on one view get in each other's way.
struct OutlineFilePanels: View {
    @Environment(\.modelContext) private var ctx
    @Binding var opening: Bool
    @Binding var saving: Bool
    /// Called after another outline has been put in place.
    var onLoad: () -> Void
    /// The file that was picked, read and waiting for the go-ahead; and its name.
    @State private var pending: OutlineFile?
    @State private var pendingName = ""
    @State private var failure: String?

    private var store: Store { Store(ctx) }

    var body: some View {
        Color.clear
            .fileImporter(isPresented: $opening, allowedContentTypes: [.json]) { result in
                switch result {
                case .failure(let e): failure = e.localizedDescription
                case .success(let url):
                    do {
                        let file = try OutlineFile.read(url)
                        pendingName = url.deletingPathExtension().lastPathComponent
                        if store.allNodes().isEmpty { load(file) } else { pending = file }
                    } catch { failure = "\(url.lastPathComponent): \(error.localizedDescription)" }
                }
            }
            .fileExporter(isPresented: $saving, item: OutlineFileExport(data: saving ? ((try? OutlineFile.snapshot(store).data()) ?? Data()) : Data()),
                          contentTypes: [.json], defaultFilename: OutlineFile.defaultFilename) { result in
                if case .failure(let e) = result { failure = e.localizedDescription }
            }
            .alert("Replace the current outline?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { file in
                Button("Replace", role: .destructive) { load(file) }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { file in
                Text("\u{201C}\(pendingName)\u{201D} (\(file.items.count) items) will take the place of everything in the outline now. To keep the current outline, cancel and choose Save outline first.")
            }
            .alert("Could not open or save the outline", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") {} } message: { Text(failure ?? "") }
    }

    private func load(_ file: OutlineFile) {
        pending = nil
        file.load(into: store)
        onLoad()
    }
}
