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
            if entry.undo != nil && entry.action != HistoryAction.delete { Button("undo") { try? Store(ctx).applyUndo(entry); Store(ctx).save() }.font(.caption2) }
        }
    }
}

// MARK: - Batch by tag

struct BatchView: View {
    @Environment(\.modelContext) private var ctx
    var sel: Selection
    @Query private var all: [Node]   // observed so the view refreshes
    @State private var assignee: Assignee? = nil
    var body: some View {
        let groups = Store(ctx).byTag(assignee: assignee)
        List {
            if groups.isEmpty { Text("No open tasks match.").foregroundStyle(.secondary) }
            ForEach(groups, id: \.tag) { g in
                Section("\(g.tag)  \(g.tasks.count)") {
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
        .navigationTitle("Batch by tag")
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
        // Recommended tasks are answered in the outline itself, where they would go; the Inbox holds the notices.
        let open = self.open.filter { $0.type != .new_task }
        List {
            if open.isEmpty { Text("Nothing pending. Notices about stale and blocked items appear here.").foregroundStyle(.secondary) }
            ForEach(open) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(p.typeRaw.replacingOccurrences(of: "_", with: " ")) · \(s.node(p.projectID)?.title ?? "")").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(p.summary)
                    if p.type == .decompose, let subs = p.payload["subtasks"] as? [[String: Any]] {
                        Text(subs.map { "• \($0["title"] ?? "") (\($0["assignee"] ?? "ai"))" }.joined(separator: "\n")).font(.caption.monospaced())
                    }
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
                    SecureField("Anthropic API key", text: $key).onChange(of: key) { _, v in settings.anthropicKey = v }
                    TextField("Model", text: $settings.claudeModel)
                    Text("The key is kept in the Keychain and, with iCloud Keychain on, is shared with your other devices: enter it once. An item handed to Claude is one request that finishes even with the app closed. Web search in hand-offs needs to be enabled for your organization in the Anthropic Console.").font(.caption).foregroundStyle(.secondary)
                } else if settings.provider == .apple {
                    Text("Apple Intelligence works on handed-off items only while the app is open.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Hand-offs") {
                Text("The AI acts only when you ask: it works on an item when you hand that item off, and recommends tasks only when you choose Recommend tasks in the menu.").font(.caption).foregroundStyle(.secondary)
                Stepper("Stale after \(settings.staleDays) days", value: $settings.staleDays, in: 1...30)
                Stepper("Check for stale and blocked items every \(settings.harnessIntervalMinutes) min", value: $settings.harnessIntervalMinutes, in: 5...720, step: 5).onChange(of: settings.harnessIntervalMinutes) { harness.start() }
                Stepper("On-device agent max turns: \(settings.agentMaxTurns)", value: $settings.agentMaxTurns, in: 2...30)
                if let last = harness.lastRun { Text("Last check \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            CalendarSyncSection()
            RemindersSection()
            AppearanceSection()
            Section("Data") {
                Toggle("Sync between my devices via iCloud", isOn: $settings.iCloudSync)
                Text("All data is stored on this device. With iCloud sync on, it is also stored in your private iCloud database (Apple's CloudKit) and nowhere else. Turn it on on each device. Changing this takes effect at next launch.").font(.caption).foregroundStyle(.secondary)
                SyncStatusView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 420)
    }
}

/// Whether iCloud sync is working on this device: the account, the last exchange each way, and the last error.
struct SyncStatusView: View {
    @State private var sync = CloudSync.shared
    @State private var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch sync.mode {
            case .off where settings.iCloudSync: line("Sync turns on at next launch.")
            case .off: EmptyView()
            case .failed(let why): line("Sync could not start; this device is using local data only. \(why)", bad: true)
            case .on:
                line(sync.account)
                line("Last sent: " + (sync.lastExport.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "not yet"))
                line("Last received: " + (sync.lastImport.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "not yet"))
                if let e = sync.lastError { line("Error: " + e, bad: true) }
            }
            if !settings.iCloudSync && sync.mode != .off { line("Sync turns off at next launch.") }
        }
        .task { if sync.mode == .on { await sync.refreshAccount() } }
    }
    private func line(_ s: String, bad: Bool = false) -> some View {
        Text(s).font(.caption).foregroundStyle(bad ? Color.red : .secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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

/// Notifications for dated items. Permission is asked for here, when the user turns them on.
struct RemindersSection: View {
    @State private var settings = AppSettings.shared
    @State private var denied = false
    var body: some View {
        Section("Notifications") {
            Toggle("Notify me when dated items are due", isOn: Binding(get: { settings.remindersOn }, set: { on in
                guard on else { settings.remindersOn = false; return }
                Task { @MainActor in if await Reminders.requestAccess() { settings.remindersOn = true; denied = false } else { denied = true } }
            }))
            if settings.remindersOn {
                Picker("Items with a time", selection: $settings.reminderLeadMinutes) {
                    Text("At the time").tag(0)
                    ForEach([5, 15, 30, 60, 120], id: \.self) { m in Text(m < 60 ? "\(m) min before" : "\(m / 60) hr before").tag(m) }
                }
                Picker("All-day items", selection: $settings.allDayReminderHour) {
                    ForEach(5...12, id: \.self) { h in Text(Self.hourLabel(h)).tag(h) }
                }
            }
            if denied { Text("Notifications are off for Schrodinger. Allow them in Settings \u{2192} Notifications.").font(.caption).foregroundStyle(.red) }
            Text("Each item with a date that isn't done notifies you once, with Done and Remind me in 1 hour. The app icon shows how many are due today or overdue.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private static func hourLabel(_ h: Int) -> String {
        (Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()).formatted(date: .omitted, time: .shortened)
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
                ForEach(0..<Palette.contextCount, id: \.self) { i in
                    ColorPicker("Level \(i + 1) color", selection: contextBinding(i), supportsOpacity: false)
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
            HStack(spacing: 1) { ForEach(0..<p.contexts.count, id: \.self) { i in Rectangle().fill(p.contexts[i]).frame(width: 16, height: 16) } }
        }
        .accessibilityHidden(true)
    }
    private func contextBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { Color(look.customContexts[i]) }, set: { look.customContexts[i] = $0.resolve(in: EnvironmentValues()) })
    }
}
