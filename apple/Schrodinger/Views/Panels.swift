import SwiftUI
import SwiftData

struct DepsPicker: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    var body: some View {
        let s = Store(ctx)
        let candidates = s.descendants(of: s.project(of: node).id).filter { $0.id != node.id }
        DisclosureGroup("Depends on (\(node.deps.count))") {
            ForEach(candidates) { c in
                Toggle(c.title.isEmpty ? "(untitled)" : c.title, isOn: Binding(get: { node.deps.contains(c.id) }, set: { on in
                    s.update(node) { n in if on { n.deps.append(c.id) } else { n.deps.removeAll { $0 == c.id } } }; s.save()
                }))
            }
        }
    }
}

struct CalendarLinkPicker: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    @State private var calendars: [(id: String, title: String)] = []
    var body: some View {
        DisclosureGroup("Calendars that propose prep tasks (\(node.calendarIDs.count))") {
            ForEach(calendars, id: \.id) { c in
                Toggle(c.title, isOn: Binding(get: { node.calendarIDs.contains(c.id) }, set: { on in
                    Store(ctx).update(node) { n in if on { n.calendarIDs.append(c.id) } else { n.calendarIDs.removeAll { $0 == c.id } } }; Store(ctx).save()
                }))
            }
        }
        .task { if await CalendarService.shared.requestAccess() { calendars = await CalendarService.shared.calendars() } }
    }
}

struct ActivityLine: View {
    @Environment(\.modelContext) private var ctx
    let entry: ActivityEntry
    var body: some View {
        HStack(alignment: .top) {
            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text("\(entry.actorRaw) \(entry.action) \(entry.detail)").font(.caption)
            Spacer()
            if entry.undo != nil { Button("undo") { try? Store(ctx).applyUndo(entry); Store(ctx).save() }.font(.caption2) }
        }
    }
}

// MARK: - Batch by mode

struct BatchView: View {
    @Environment(\.modelContext) private var ctx
    var sel: Selection
    @Query private var all: [Node]   // observed so the view refreshes
    @State private var assignee: Assignee? = nil
    var body: some View {
        let groups = Store(ctx).byMode(assignee: assignee)
        List {
            if groups.isEmpty { Text("No open tasks match.").foregroundStyle(.secondary) }
            ForEach(groups, id: \.mode) { g in
                Section("\(Mode(rawValue: g.mode)?.emoji ?? "") \(g.mode.uppercased())  \(g.tasks.count)") {
                    ForEach(g.tasks, id: \.0.id) { t, project in
                        HStack {
                            Button { Store(ctx).update(t) { $0.state = $0.state == .done ? .todo : .done }; Store(ctx).save() } label: { Image(systemName: t.state == .done ? "checkmark.square.fill" : "square") }.buttonStyle(.plain)
                            VStack(alignment: .leading) { Text(t.title); Text(project.title).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Chip(text: t.assignee.label, color: t.assignee == .ai ? .blue : t.assignee == .shared ? .purple : .green)
                            if let d = t.due { Text(d.dayString).font(.caption).foregroundStyle(d < Date() ? .red : .secondary) }
                        }
                        .contentShape(Rectangle()).onTapGesture { sel.nodeID = t.id }
                    }
                }
            }
        }
        .navigationTitle("Batch by mode")
        .toolbar { Picker("Who", selection: $assignee) { Text("All").tag(Assignee?.none); Text("Mine").tag(Assignee?.some(.human)); Text("AI's").tag(Assignee?.some(.ai)) } }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @Environment(\.modelContext) private var ctx
    var sel: Selection
    @Query(filter: #Predicate<Proposal> { $0.statusRaw == "open" }, sort: [SortDescriptor(\Proposal.createdAt, order: .reverse)]) private var open: [Proposal]
    var body: some View {
        let s = Store(ctx)
        List {
            if open.isEmpty { Text("Nothing pending. The harness proposes structural changes here; nothing is applied until you accept.").foregroundStyle(.secondary) }
            ForEach(open) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(p.typeRaw.replacingOccurrences(of: "_", with: " ")) · \(s.node(p.projectID)?.title ?? "")").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(p.summary)
                    if p.type == .decompose, let subs = p.payload["subtasks"] as? [[String: Any]] {
                        Text(subs.map { "• \($0["title"] ?? "") (\($0["assignee"] ?? "ai"))" }.joined(separator: "\n")).font(.caption.monospaced())
                    }
                    if p.type == .new_task { Text("• \(p.payload["title"] ?? "") (\(p.payload["assignee"] ?? "ai"))").font(.caption.monospaced()) }
                    HStack {
                        Button(p.isInformational ? "Acknowledge" : "Accept") { try? s.accept(p); s.save() }.buttonStyle(.borderedProminent)
                        Button("Dismiss") { s.dismiss(p); s.save() }
                        if let id = p.nodeID { Button("Show task") { sel.open(id) } }
                    }
                }.padding(.vertical, 4)
            }
        }
        .navigationTitle("Inbox")
    }
}

// MARK: - Calendar

struct CalendarView: View {
    @Environment(\.modelContext) private var ctx
    var sel: Selection
    @Query private var all: [Node]
    @State private var events: [CalendarEvent] = []
    @State private var denied = false
    var body: some View {
        let dueSoon = all.filter { !$0.isProject && $0.state != .done && ($0.due.map { $0 < Date().addingTimeInterval(14 * 86400) } ?? false) }
        let items: [(Date, String, String, UUID?)] = (events.map { ($0.start, $0.allDay ? "all day" : $0.start.formatted(date: .omitted, time: .shortened), $0.title + ($0.location.isEmpty ? "" : " · " + $0.location), nil) }
            + dueSoon.map { ($0.due!, "due", $0.title, $0.id) }).sorted { $0.0 < $1.0 }
        List {
            if denied { Text("Calendar access denied. Enable it in Settings → Privacy → Calendars.").foregroundStyle(.red) }
            if items.isEmpty { Text("No events or due tasks in the next two weeks.").foregroundStyle(.secondary) }
            ForEach(Dictionary(grouping: items, by: { $0.0.dayString }).keys.sorted(), id: \.self) { day in
                Section(day) {
                    ForEach(Array(items.filter { $0.0.dayString == day }.enumerated()), id: \.offset) { _, it in
                        HStack { Text(it.1).font(.caption.weight(.semibold)).frame(width: 60, alignment: .leading); Text(it.2) }
                            .contentShape(Rectangle()).onTapGesture { if let id = it.3 { sel.open(id) } }
                    }
                }
            }
            Section { Text("Tasks with due dates can be added to your calendar from their details. Calendars linked to a project (in the project's details) generate prep-task proposals for upcoming events.").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Calendar")
        .task { denied = !(await CalendarService.shared.requestAccess()); events = await CalendarService.shared.events() }
        .refreshable { events = await CalendarService.shared.events() }
    }
}

// MARK: - Digest, Activity, Settings

struct DigestView: View {
    @Environment(\.modelContext) private var ctx
    var sel: Selection
    @Query(filter: #Predicate<Node> { $0.parentID == nil }, sort: [SortDescriptor(\Node.position)]) private var projects: [Node]
    var body: some View {
        let s = Store(ctx)
        List {
            ForEach(projects) { p in
                Section(p.title) {
                    if let d = s.digests(for: p.id).first { Text(d.body).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    else { Text("No digest yet — run the harness.").foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("Digest")
    }
}

struct ActivityView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: [SortDescriptor(\ActivityEntry.createdAt, order: .reverse)]) private var entries: [ActivityEntry]
    var body: some View {
        let s = Store(ctx)
        List(entries.prefix(200)) { a in
            VStack(alignment: .leading) { Text(s.node(a.nodeID)?.title ?? "(deleted)").font(.caption.weight(.semibold)); ActivityLine(entry: a) }
        }.navigationTitle("Activity")
    }
}

struct SettingsView: View {
    @Environment(HarnessEngine.self) private var harness
    @State private var settings = AppSettings.shared
    @State private var key: String = AppSettings.shared.anthropicKey
    var body: some View {
        Form {
            Section("Model (calls happen from this device)") {
                Picker("Provider", selection: $settings.provider) { ForEach(ProviderKind.allCases) { Text($0.label).tag($0) } }
                let av = AppleIntelligenceProvider.availability
                Text(av.available ? "Apple Intelligence is available on this device." : "Apple Intelligence unavailable: \(av.reason)").font(.caption).foregroundStyle(.secondary)
                if settings.provider == .claude {
                    SecureField("Anthropic API key (stored in this device's Keychain)", text: $key).onChange(of: key) { _, v in settings.anthropicKey = v }
                    TextField("Model", text: $settings.claudeModel)
                }
            }
            Section("Harness") {
                Stepper("Run every \(settings.harnessIntervalMinutes) min", value: $settings.harnessIntervalMinutes, in: 5...720, step: 5).onChange(of: settings.harnessIntervalMinutes) { harness.start() }
                Stepper("Max AI tasks per run: \(settings.maxTasksPerRun)", value: $settings.maxTasksPerRun, in: 1...10)
                Stepper("Stale after \(settings.staleDays) days", value: $settings.staleDays, in: 1...30)
                Stepper("Agent max turns: \(settings.agentMaxTurns)", value: $settings.agentMaxTurns, in: 2...30)
                if let last = harness.lastRun { Text("Last run \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            CalendarSyncSection()
            AppearanceSection()
            Section("Data") {
                Toggle("Sync between my devices via iCloud", isOn: $settings.iCloudSync)
                Text("All data is stored on this device. With iCloud sync on, it is also stored in your private iCloud database (Apple's CloudKit) and nowhere else. Changing this takes effect at next launch.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 420)
    }
}

/// Choose the calendar that calendared items are added to. Access is asked for here, when the user connects one.
struct CalendarSyncSection: View {
    @State private var settings = AppSettings.shared
    @State private var calendars: [(id: String, title: String)] = []
    @State private var connected = CalendarService.authorized
    @State private var denied = false
    var body: some View {
        Section("Calendar") {
            if connected {
                Picker("Add calendared items to", selection: $settings.syncCalendarID) {
                    Text("None").tag("")
                    ForEach(calendars, id: \.id) { Text($0.title).tag($0.id) }
                }
            } else {
                Button("Connect a calendar\u{2026}") {
                    Task { if await CalendarService.shared.requestAccess() { connected = true; calendars = await CalendarService.shared.writableCalendars() } else { denied = true } }
                }
                if denied { Text("Calendar access was not granted. Allow it in Settings \u{2192} Privacy \u{2192} Calendars.").font(.caption).foregroundStyle(.red) }
            }
            Text("An item you give a date (the calendar button in its field) is added to this calendar as an event and kept up to date. Nothing else in your calendar is changed.").font(.caption).foregroundStyle(.secondary)
        }
        .task { if connected { calendars = await CalendarService.shared.writableCalendars() } }
    }
}

/// Color scheme, typeface and outline sounds.
struct AppearanceSection: View {
    @State private var look = Appearance.shared
    var body: some View {
        Section("Appearance") {
            Picker("Colors", selection: $look.palette) { ForEach(PaletteKind.allCases) { Text($0.label).tag($0) } }
            swatches
            if look.palette == .custom {
                Menu("Start from preset") {
                    ForEach(PaletteKind.allCases.filter { $0 != .custom }) { k in Button(k.label) { look.copyToCustom(k) } }
                }
                ForEach(Array(Mode.allCases.enumerated()), id: \.element.id) { i, m in
                    ColorPicker(m.label, selection: modeBinding(i), supportsOpacity: false)
                }
                ForEach(0..<Palette.contextCount, id: \.self) { i in
                    ColorPicker("Project color \(i + 1)", selection: contextBinding(i), supportsOpacity: false)
                }
            }
            Picker("Font", selection: $look.font) {
                ForEach(AppFontFamily.allCases) { f in Text(f.label).font(f.font(.body)).tag(f) }
            }
            Text("The quick brown fox jumps over the lazy dog.").font(look.font.font(.body))
            Toggle("Xylophone sounds when moving items", isOn: $look.sounds)
            Text("Indent and outdent step along a major scale; moving up and down steps by semitones.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var swatches: some View {
        let p = look.current
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 1) { ForEach(0..<p.modes.count, id: \.self) { i in Rectangle().fill(p.modes[i]).frame(width: 16, height: 16) } }
            HStack(spacing: 1) { ForEach(0..<p.contexts.count, id: \.self) { i in Rectangle().fill(p.contexts[i]).frame(width: 16, height: 16) } }
        }
        .accessibilityHidden(true)
    }
    private func modeBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { Color(look.customModes[i]) }, set: { look.customModes[i] = $0.resolve(in: EnvironmentValues()) })
    }
    private func contextBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { Color(look.customContexts[i]) }, set: { look.customContexts[i] = $0.resolve(in: EnvironmentValues()) })
    }
}
