import SwiftUI
import SwiftData

/// Everything about one item, shown in the outline under its action strip when its squares are tapped:
/// the AI's draft (approve / redo), the shared "your turn" step, context, due date, project brief,
/// dependencies and activity. Replaces the separate Review screen.
struct ItemInfo: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    /// Called before the node is deleted (clears selection / open info).
    var onDelete: () -> Void = {}
    @State private var feedback = ""
    @State private var calendarMessage: String? = nil
    private var store: Store { Store(ctx) }
    private var font: AppFontFamily { Appearance.shared.font }

    var body: some View {
        // Reading a deleted model traps; this view can render once more after Delete.
        if node.isDeleted || node.modelContext == nil { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if node.state == .review || (node.artifact.map { !$0.isEmpty } ?? false) { draftSection }
            if node.isYourTurn { yourTurnSection }
            if node.isProject { projectSection } else { taskSection }
            DisclosureGroup("Activity") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.activity(for: node.id)) { a in ActivityLine(entry: a) }
                }
            }
            .font(font.font(.footnote, weight: .medium))
            Button(role: .destructive) { onDelete(); store.delete(node); store.save() } label: { Label("Delete", systemImage: "trash") }
                .font(font.font(.footnote))
        }
        .font(font.font(.callout))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Draft (AI output) — approve or send back with a note

    @ViewBuilder private var draftSection: some View {
        section(node.state == .review ? "Draft for your review" : "Draft") {
            if let a = node.artifact, !a.isEmpty {
                ScrollView {
                    Text(a).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(8)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.12)))
            } else {
                Text("No draft text yet.").foregroundStyle(Color.ink.opacity(0.5))
            }
            if node.state == .review {
                noteField("Note for the AI (what to change)")
                HStack(spacing: 10) {
                    Button("Approve") { try? store.approve(node); store.save() }.buttonStyle(.borderedProminent)
                    Button("Redo") { try? store.reject(node, note: feedback); store.save(); feedback = "" }.buttonStyle(.bordered)
                    Spacer()
                    if let a = node.artifact, !a.isEmpty { copyButton(a) }
                }
            } else if let a = node.artifact, !a.isEmpty {
                HStack { Spacer(); copyButton(a) }
            }
        }
    }

    // MARK: Shared task: AI part done, the human finishes

    @ViewBuilder private var yourTurnSection: some View {
        section("Your turn — the AI part is done") {
            noteField("Note for the AI (if sending back)")
            HStack(spacing: 10) {
                Button("Done") { store.update(node) { $0.state = .done }; store.save() }.buttonStyle(.borderedProminent)
                Button("Send back to AI") { try? store.sendBackToAI(node, note: feedback); store.save(); feedback = "" }.buttonStyle(.bordered)
            }
        }
    }

    // MARK: Task details

    @ViewBuilder private var taskSection: some View {
        section("Context") {
            InfoText(placeholder: "Background, links, anything the AI should know", value: node.notes) { v in store.update(node) { $0.notes = v }; store.save() }
        }
        section("Due") {
            HStack {
                Toggle("Due date", isOn: Binding(get: { node.due != nil }, set: { on in store.update(node) { $0.due = on ? Date() : nil }; store.save() }))
                    .labelsHidden()
                if node.due != nil {
                    DatePicker("", selection: Binding(get: { node.due ?? Date() }, set: { v in store.update(node) { $0.due = v }; store.save() }), displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                    Button("Add to calendar") { addToCalendar() }.font(font.font(.footnote))
                } else {
                    Text("None").foregroundStyle(Color.ink.opacity(0.5))
                }
            }
            if let m = calendarMessage { Text(m).font(font.font(.caption)).foregroundStyle(Color.ink.opacity(0.6)) }
        }
        if !node.acceptanceNote.isEmpty {
            section("Review feedback") {
                InfoText(placeholder: "", value: node.acceptanceNote) { v in store.update(node) { $0.acceptanceNote = v }; store.save() }
            }
        }
        DepsPicker(node: node).font(font.font(.footnote, weight: .medium))
    }

    // MARK: Project brief (what the project's agent works from)

    @ViewBuilder private var projectSection: some View {
        section("Goal") {
            InfoText(placeholder: "What done looks like", value: node.goal) { v in store.update(node) { $0.goal = v }; store.save() }
        }
        section("Success criteria") {
            InfoText(placeholder: "Checkable criteria", value: node.successCriteria) { v in store.update(node) { $0.successCriteria = v }; store.save() }
        }
        section("Constraints for the AI") {
            InfoText(placeholder: "What the AI must or must not do", value: node.constraints) { v in store.update(node) { $0.constraints = v }; store.save() }
        }
        section("Project") {
            Picker("Status", selection: Binding(get: { node.projectStatus }, set: { v in store.update(node) { $0.projectStatus = v }; store.save() })) {
                ForEach(ProjectStatus.allCases) { Text($0.rawValue).tag($0) }
            }
            CalendarLinkPicker(node: node)
        }
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(font.font(.caption2, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.55))
            rows()
        }
    }

    private func noteField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $feedback, axis: .vertical)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.12)))
    }

    private func copyButton(_ s: String) -> some View {
        Button { copy(s) } label: { Label("Copy", systemImage: "doc.on.doc") }.font(font.font(.footnote))
    }

    private func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }

    private func addToCalendar() {
        guard let due = node.due else { return }
        let title = node.title, project = store.project(of: node).title
        Task {
            do { _ = try await CalendarService.shared.addTask(title: title, due: due, notes: "Schrodinger · \(project)"); calendarMessage = "Added to your calendar." }
            catch { calendarMessage = error.localizedDescription }
        }
    }
}

/// Multi-line text that saves when editing ends (Return, focus leaves, or the view goes away) rather than on every
/// keystroke, so one edit is one undo step and one activity entry.
struct InfoText: View {
    let placeholder: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(8)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(focused ? 0.35 : 0.12)))
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
            .onChange(of: focused) { _, f in if !f { save() } }
            .onSubmit { save() }
            .onDisappear { save() }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != value { commit(t) }
    }
}
