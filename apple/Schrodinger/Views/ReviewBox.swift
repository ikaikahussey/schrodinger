import SwiftUI
import SwiftData

// Items in review: the AI returned its result and the owner has not approved it yet (the same set as the Review
// filter). They are listed in a box at the bottom of the outline, above the calendar box, and the box can be pushed
// off the bottom of the screen the same way. Approving an item (in its field) makes it done and takes it off the list.

/// The box at the bottom of the outline: results to review, newest first. Tap one to go to its item, where the
/// result is. Dragging its header down (or tapping the chevron) pushes the box off screen, where `ReviewTab` stands in.
struct ReviewBox: View {
    let items: [Node]
    /// Items whose result has not been opened yet on this device (marked "New").
    let fresh: Set<UUID>
    let onOpen: (UUID) -> Void
    let onPush: () -> Void
    private let rowHeight: CGFloat = 30
    /// How far the box has been dragged down.
    @GestureState private var pull: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: ReviewTab.symbol).font(.system(size: 11, weight: .semibold))
                Text("TO REVIEW").font(PanelPalette.label(.caption2))
                Text("\(items.count)").font(PanelPalette.label(.caption2)).opacity(0.6)
                Spacer(minLength: 0)
                FieldIcon(systemImage: "chevron.down", width: 34, action: onPush).help("Push off screen").accessibilityLabel("Hide results to review")
            }
            .foregroundStyle(Color.ink.opacity(0.55))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6)
                .updating($pull) { v, s, _ in s = max(0, v.translation.height) }
                .onEnded { v in if v.translation.height > 30 || v.predictedEndTranslation.height > 120 { onPush() } })
            // Up to three rows show; more scroll.
            ScrollView {
                VStack(spacing: 0) { ForEach(items) { row($0) } }
            }
            .frame(height: CGFloat(min(items.count, 3)) * rowHeight)
        }
        .padding(.leading, 14).padding(.trailing, 4).padding(.bottom, 8)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.canvas)
                RoundedRectangle(cornerRadius: 16).fill(PanelPalette.field)
            }
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .offset(y: pull)
        .animation(.snappy(duration: 0.22), value: pull == 0)
    }

    @ViewBuilder private func row(_ n: Node) -> some View {
        // Reading a deleted model traps; the box can render once more after an item is deleted.
        if n.isDeleted || n.modelContext == nil { EmptyView() } else {
            let new = fresh.contains(n.id)
            Button { onOpen(n.id) } label: {
                HStack(spacing: 10) {
                    Text(new ? "New" : "Review").font(Appearance.shared.font.font(.caption, weight: .semibold))
                        .foregroundStyle(Color.ink.opacity(0.6))
                        .frame(width: 84, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                    Text(n.title.isEmpty ? "New item" : n.title).font(Appearance.shared.font.font(.footnote))
                        .foregroundStyle(Color.ink).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: rowHeight)
                .padding(.trailing, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((new ? "New result to review: " : "To review: ") + (n.title.isEmpty ? "New item" : n.title))
        }
    }

    /// The items in review, newest first.
    @MainActor static func items(in all: [Node]) -> [Node] {
        all.filter { $0.state == .review }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}

/// What is left on screen once the review box has been pushed off: a small tab at the bottom edge with the number of
/// results to review. Tap it, or drag it up, to bring the box back.
struct ReviewTab: View {
    static let symbol = "sparkles"
    let count: Int
    let onPull: () -> Void

    var body: some View {
        Button(action: onPull) {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol).font(.system(size: 11, weight: .semibold))
                Text("\(count)").font(PanelPalette.label(.caption2))
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(PanelPalette.text(on: PanelPalette.orange))
            .padding(.horizontal, 12).frame(height: 30)
            .background { Capsule().fill(PanelPalette.orange).shadow(color: .black.opacity(0.12), radius: 4, y: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 6).onEnded { v in if v.translation.height < -12 { onPull() } })
        .padding(.leading, 12).padding(.bottom, 8)
        .help("Show results to review").accessibilityLabel("Show results to review, \(count)")
    }
}
