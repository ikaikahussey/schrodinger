import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An item's AI result, filling the window: the Markdown drawn as a document, under a bar of breadcrumbs that lead
/// back to the outline (the item's parents, then the item, each by name). Under the document, a comment form: type
/// the edits the result needs and send it back to the AI, which redoes it with them. Opened from the result block in
/// an item's field.
struct ResultViewer: View {
    let nodeID: UUID
    var sel: Selection
    @Environment(\.modelContext) private var ctx
    private var store: Store { Store(ctx) }
    /// The edits the owner wants, as typed in the comment form.
    @State private var comment = ""
    @FocusState private var commenting: Bool

    var body: some View {
        let node = store.node(nodeID)
        let text = node?.artifact ?? ""
        VStack(spacing: 0) {
            bar(node, text: text)
            Divider()
            ScrollView {
                MarkdownView(blocks: Markdown.blocks(text))
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            if let node, !text.isEmpty { commentForm(node) }
        }
        .background(Color.canvas.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
        .onAppear { Self.endEditing(); if text.isEmpty { close() } }
    }

    /// The comment form, under the result: what needs to change, and a button that sends the item back to the AI
    /// with it. The AI redoes the result; the comment is kept on the item. Not while the AI is already working on it.
    private func commentForm(_ node: Node) -> some View {
        let working = JobQueue.shared.latest(for: node.id)?.live ?? false
        let empty = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let fill = PanelPalette.orange
        return VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(working ? "The AI is working on this\u{2026}" : "Edits needed\u{2026}", text: $comment, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(Appearance.shared.font.font(.body)).foregroundStyle(Color.ink).tint(Color.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(PanelPalette.field, in: RoundedRectangle(cornerRadius: 14))
                    .focused($commenting)
                    .disabled(working)
                    .accessibilityLabel("Edits needed")
                Button { sendEdits(node) } label: {
                    Image(systemName: NodeRow.sendToAISymbol).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PanelPalette.text(on: fill))
                        .frame(width: 36, height: 36)
                        .background { Circle().fill(fill) }
                        .contentShape(Circle())
                        .opacity(empty || working ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .disabled(empty || working)
                .help("Send back to the AI with these edits").accessibilityLabel("Send edits to the AI")
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
    }

    /// Records the comment on the item and hands it back to the AI, then returns to the item in the outline, where
    /// the AI's progress shows.
    private func sendEdits(_ node: Node) {
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        if JobQueue.shared.latest(for: node.id)?.kind == .weave {
            // A woven piece: woven again with the comment. The item's status and holder stay as they are.
            store.noteOnWeave(node, note: note); store.save()
            JobQueue.shared.weave(node.id)
        } else {
            store.requestEdits(node, note: note); store.save()
            JobQueue.shared.handOff([node.id])
        }
        comment = ""; commenting = false
        go(to: node.id)
    }

    private func close() { sel.resultID = nil }
    /// Back to the outline, at one item: the outline shows it and opens its field.
    private func go(to id: UUID) { sel.resultID = nil; sel.open(id) }

    /// The item's parents, outermost first, then the item.
    private func path(_ node: Node?) -> [Node] {
        var path: [Node] = []
        var p = node
        while let x = p, path.count < 64 { path.insert(x, at: 0); p = x.parentID.flatMap { store.node($0) } }
        return path
    }

    private func bar(_ node: Node?, text: String) -> some View {
        let crumbs = path(node)
        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    // The path to the item, by name; the last block is the item itself. Each leads to its place in the outline.
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, n in
                        let name = n.title.isEmpty ? "Untitled" : n.title
                        crumb(name.uppercased(), systemImage: i == 0 ? "chevron.left" : nil, fill: [PanelPalette.lavender, PanelPalette.periwinkle, PanelPalette.rose][i % 3]) { go(to: n.id) }
                            .accessibilityLabel("Back to \(name)")
                    }
                    // Where you are: not a button.
                    crumbLabel("RESULT", systemImage: nil, fill: PanelPalette.peach).accessibilityAddTraits(.isHeader)
                }
            }
            .defaultScrollAnchor(.trailing)
            if !text.isEmpty {
                ShareLink(item: ResultFile(title: node?.title ?? "", markdown: text), preview: SharePreview(ResultFile.filename(for: node?.title ?? ""))) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink.opacity(0.6))
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .help("Share or open in another app").accessibilityLabel("Share result")
            }
            Button { if let node { go(to: node.id) } else { close() } } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink.opacity(0.6))
                    .frame(width: 34, height: 34).contentShape(Rectangle())
            }
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)").accessibilityLabel("Close result")
        }
        .buttonStyle(.plain)
        .padding(.leading, StatusBar.margin).padding(.trailing, 8).padding(.vertical, 6)
        .background(Color.canvas)
    }

    private func crumb(_ title: String, systemImage: String? = nil, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { crumbLabel(title, systemImage: systemImage, fill: fill) }
    }

    private func crumbLabel(_ title: String, systemImage: String?, fill: Color) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .heavy)) }
            Text(title).font(PanelPalette.label(.caption)).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(PanelPalette.text(on: fill))
        .padding(.horizontal, 8).frame(maxWidth: 180).frame(height: 28)
        .background(fill)
        .contentShape(Rectangle())
    }

    /// Ends any typing in the outline underneath (and puts the keyboard away).
    private static func endEditing() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

/// Markdown blocks drawn as a document, in the app's font.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in row(block) }
        }
        .foregroundStyle(Color.ink)
        .textSelection(.enabled)
    }

    private func face(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font { Appearance.shared.font.font(style, weight: weight) }

    @ViewBuilder private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(face(level == 1 ? .title : level == 2 ? .title2 : level == 3 ? .title3 : .headline, weight: .bold))
                .padding(.top, level <= 2 ? 8 : 3)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Markdown.inline(text))
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                mark(marker).frame(minWidth: 18, alignment: .trailing)
                Text(Markdown.inline(text))
            }
            .padding(.leading, CGFloat(depth) * 20)
        case .quote(let text):
            Text(Markdown.inline(text)).foregroundStyle(Color.ink.opacity(0.7))
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.ink.opacity(0.25)).frame(width: 3) }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelPalette.field, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in Text(Markdown.inline(cell)).fontWeight(.semibold) }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in Text(Markdown.inline(cell)) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func mark(_ marker: MarkdownBlock.Marker) -> some View {
        switch marker {
        case .bullet: Text("\u{2022}")
        case .number(let n): Text(n + ".").monospacedDigit()
        case .task(let done): Image(systemName: done ? "checkmark.square" : "square").accessibilityLabel(done ? "Done" : "Not done")
        }
    }
}
