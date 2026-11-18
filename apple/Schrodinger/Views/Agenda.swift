import SwiftUI
import SwiftData

// Calendaring: an item is calendared when it has a date (the calendar button in its field). Calendared items are
// listed in a box at the bottom of the outline, and mirrored to a calendar if one is chosen in Settings.

/// The box at the bottom of the outline: calendared items, soonest first. Tap one to go to it. Dragging its header
/// down (or tapping the chevron) pushes the box off the bottom of the screen, where `AgendaTab` stands in for it.
struct AgendaBox: View {
    let items: [Node]
    let onOpen: (UUID) -> Void
    let onPush: () -> Void
    private let rowHeight: CGFloat = 30
    /// How far the box has been dragged down.
    @GestureState private var pull: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                Text("CALENDAR").font(PanelPalette.label(.caption2))
                Text("\(items.count)").font(PanelPalette.label(.caption2)).opacity(0.6)
                Spacer(minLength: 0)
                FieldIcon(systemImage: "chevron.down", width: 34, action: onPush).help("Push off screen").accessibilityLabel("Hide calendar box")
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
        if n.isDeleted || n.modelContext == nil || n.due == nil { EmptyView() } else {
            let due = n.due!
            let late = due < (due.hasTime ? Date() : Calendar.current.startOfDay(for: Date()))
            Button { onOpen(n.id) } label: {
                HStack(spacing: 10) {
                    Text(due.agendaLabel).font(Appearance.shared.font.font(.caption, weight: .semibold))
                        .foregroundStyle(late ? Color.red : Color.ink.opacity(0.6))
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
        }
    }
}

/// What is left on screen once the calendar box has been pushed off: a small tab at the bottom edge with the number
/// of calendared items. Tap it, or drag it up, to bring the box back.
struct AgendaTab: View {
    let count: Int
    let onPull: () -> Void

    var body: some View {
        Button(action: onPull) {
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                Text("\(count)").font(PanelPalette.label(.caption2))
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(Color.ink.opacity(0.6))
            .padding(.horizontal, 12).frame(height: 30)
            .background {
                ZStack { Capsule().fill(Color.canvas); Capsule().fill(PanelPalette.field) }
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 6).onEnded { v in if v.translation.height < -12 { onPull() } })
        .padding(.leading, 12).padding(.bottom, 8)
        .help("Show calendared items").accessibilityLabel("Show calendared items, \(count)")
    }
}

/// Pick the item's date, and a time if it has one. "Remove Date" (shown when the item has one) clears it and takes the
/// item off the calendar.
struct DateSheet: View {
    let onSet: (Date?) -> Void
    private let had: Bool
    @State private var day: Date
    @State private var timed: Bool
    @Environment(\.dismiss) private var dismiss

    init(date: Date?, onSet: @escaping (Date?) -> Void) {
        self.onSet = onSet
        had = date != nil
        _day = State(initialValue: date ?? Calendar.current.startOfDay(for: Date()))
        _timed = State(initialValue: date?.hasTime ?? false)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                DatePicker("Date", selection: $day, displayedComponents: .date).datePickerStyle(.graphical)
                Toggle("Time", isOn: $timed.animation(.snappy(duration: 0.2)))
                if timed { DatePicker("At", selection: $day, displayedComponents: .hourAndMinute) }
                if had {
                    Button(role: .destructive) { onSet(nil); dismiss() } label: {
                        Label("Remove Date", systemImage: "calendar.badge.minus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 12)
                    .accessibilityHint("Clears the item's date")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSet(timed ? day : Calendar.current.startOfDay(for: day)); dismiss() }.fontWeight(.semibold)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .presentationDetents([.fraction(0.7), .large])
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 420)
        #endif
    }
}
