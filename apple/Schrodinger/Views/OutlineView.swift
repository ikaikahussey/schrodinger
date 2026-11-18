import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// One continuous outline. Depth is shown by black bars at the left (one per level). The item's own bar carries
/// its status and who holds it; tapping the bars opens the item's menu. Everything else stays out of the
/// way of the text. Top-level items are projects (the harness runs one agent per top-level item).
struct OutlineView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var sel: Selection
    @Query(sort: [SortDescriptor(\Node.position), SortDescriptor(\Node.createdAt)]) private var all: [Node]
    /// AI proposals waiting in the Inbox (shown as a count in the header menu).
    @Query(filter: #Predicate<Proposal> { $0.statusRaw == "open" }) private var openProposals: [Proposal]
    /// Photos and links on items, oldest first; grouped by item in `body`.
    @Query(sort: [SortDescriptor(\Attachment.createdAt)]) private var attachments: [Attachment]
    @State private var filter: Filter = .all
    /// Show only items with this tag (nil: any).
    @State private var tagFilter: String? = nil
    @State private var showLegend = false
    /// Header search: words match an item's text; `#tag` words match its tags.
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// The on-screen keyboard is showing (iPhone/iPad).
    @State private var keyboardUp = false
    /// Import: the file picker is up; and what went wrong with the last import, if anything.
    @State private var importing = false
    @State private var exportingCSV = false
    @State private var importFailure: String?
    @FocusState private var focused: UUID?
    /// Row that should switch to its text field and take focus. Focus can't be set on a field that isn't on screen yet,
    /// so the row shows its field first, then claims focus (see NodeRow.claimEdit).
    @State private var editRequest: UUID?
    @State private var drag = OutlineDrag()
    /// Item the outline is zoomed into (shown at the top with its children), or nil for the whole outline.
    @State private var zoomID: UUID? = nil
    @State private var zoomingIn = true
    /// The calendar box at the bottom has been pushed off screen (its tab stays, to bring it back).
    @AppStorage("agendaPushed") private var agendaPushed = false

    enum Filter: String, CaseIterable, Identifiable { case all, mine, ai, review, blocked, week; var id: String { rawValue }
        var label: String { switch self { case .all: "All"; case .mine: "Mine"; case .ai: "AI"; case .review: "Review"; case .blocked: "Blocked"; case .week: "This week" } } }

    private var store: Store { Store(ctx) }
    private var look: Appearance { Appearance.shared }
    /// Items with a date that are not done, soonest first.
    private var calendared: [Node] { all.filter { $0.due != nil && $0.state != .done }.sorted { $0.due! < $1.due! } }
    /// The box shows while there are calendared items and it has not been pushed off screen.
    private var agendaShown: Bool { !calendared.isEmpty && !agendaPushed }
    private var childrenMap: [UUID?: [Node]] { Dictionary(grouping: all, by: { $0.parentID }).mapValues { $0.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) } } }

    var body: some View {
        let kids = childrenMap
        let roots = kids[nil] ?? []
        let files = Dictionary(grouping: attachments, by: \.nodeID)
        // The AI's open suggestions, by the item they are about (shown in that item's field).
        let advice = Dictionary(grouping: openProposals.filter { $0.nodeID != nil }.sorted { $0.createdAt < $1.createdAt }, by: { $0.nodeID! })
        let zoomed = zoomID.flatMap { store.node($0) }
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let z = zoomed {
                        // Zoomed in: the item keeps its real depth and its ancestors' squares, so its place in the hierarchy
                        // reads the same as in the full outline.
                        let context = look.contextColor(rootIndex(z, roots: roots))
                        nodeTree(z, depth: depthOf(z), kids: kids, files: files, advice: advice, trail: ancestorColors(z, context: context), context: context, active: store.project(of: z).projectStatus == .active)
                    } else {
                        ForEach(Array(roots.enumerated()), id: \.element.id) { i, p in nodeTree(p, depth: 0, kids: kids, files: files, advice: advice, trail: [], context: look.contextColor(i), active: p.projectStatus == .active) }
                    }
                }
                .id(zoomID)
                .transition(.asymmetric(
                    insertion: .scale(scale: zoomingIn ? 0.94 : 1.06, anchor: .top).combined(with: .opacity),
                    removal: .opacity))
                if showLegend { BarLegend().padding(.top, 24) }
            }
            // Squares start at the first pixel on the left; text keeps its margin on the right.
            .padding(.trailing, 16).padding(.top, 8)
            .coordinateSpace(name: "outline")
            .onPreferenceChange(RowFrameKey.self) { v in Task { @MainActor in drag.frames = v } }
            .overlay(alignment: .topLeading) {
                if let t = drag.target, drag.id != nil {
                    Rectangle().fill(Color.ink).frame(height: 2)
                        .padding(.leading, StatusBar.textStart(t.depth)).padding(.trailing, 16)
                        .offset(y: t.y - 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .scrollDisabled(drag.id != nil)   // the list holds still while an item is lifted
        // Always present, fixed height: the outline's top edge does not move when zooming in or out.
        .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { breadcrumbBar(zoomed); tagBar } }
        // Dragging the list also puts the keyboard away (which ends editing).
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        #endif
        // Bottom right, over the list: "+ NEW ITEM"; while searching it becomes "DONE", which puts the keyboard away.
        // An open item has its own Done (the check in its field), so there is no second one here.
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
            // The calendar box pushed off screen: its tab, at the bottom left, brings it back.
            if !keyboardUp && agendaPushed && !calendared.isEmpty {
                AgendaTab(count: calendared.count) { withAnimation(.snappy(duration: 0.22)) { agendaPushed = false } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if keyboardUp && searchFocused {
                cornerButton("DONE", systemImage: "checkmark", fill: PanelPalette.peach, help: "Finish editing") { finishTyping() }
            } else if focused == nil && editRequest == nil && !searchFocused {
                newItemButton {
                    let n = zoomed.map { store.create(parentID: $0.id, position: (kids[$0.id] ?? []).count) } ?? store.create()
                    store.save(); beginEdit(n.id)
                    // The new item goes at the end of the list: bring it into view.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(n.id, anchor: .center) }
                    }
                }
            }
            }
            // Calendared items, soonest first, in a box that can be pushed off the bottom of the screen. Not while
            // typing (the keyboard needs the room).
            if !keyboardUp && agendaShown {
                AgendaBox(items: calendared, onOpen: { sel.open($0) }, onPush: { withAnimation(.snappy(duration: 0.22)) { agendaPushed = true } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            }
            .animation(.snappy(duration: 0.22), value: agendaShown)
            .animation(.snappy(duration: 0.22), value: calendared.count)
        }
        // Calendared items are mirrored to the calendar chosen in Settings (if any) whenever one of them changes.
        .task(id: CalendarSync.signature(all) + AppSettings.shared.syncCalendarID) { await CalendarSync.syncAll(container: ctx.container) }
        // Zoomed in: a quick swipe right anywhere on the page goes back to the whole outline.
        #if os(iOS)
        .gesture(HorizontalPanGesture(onChanged: { _ in }, onEnded: { t, vx in
            if zoomID != nil && drag.id == nil && OutlineView.isBackSwipe(dx: t.width, dy: t.height, vx: vx) { zoom(to: nil) }
        }))
        #else
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { v in
            if zoomID != nil && drag.id == nil && OutlineView.isBackSwipe(v) { zoom(to: nil) }
        })
        #endif
        .background(Color.canvas)
        .navigationTitle("")
        .fileImporter(isPresented: $importing, allowedContentTypes: Importer.fileTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .failure(let e): importFailure = e.localizedDescription
            case .success(let urls):
                var last: UUID?
                for url in urls {
                    do { last = try Importer.importFile(url, under: zoomID, store: store) }
                    catch { importFailure = "\(url.lastPathComponent): \(error.localizedDescription)" }
                }
                if let last { sel.open(last) }
            }
        }
        .fileExporter(isPresented: $exportingCSV, item: CSVExport(text: exportingCSV ? Exporter.csv(zoomID, store: store) : ""),
                      contentTypes: [.commaSeparatedText], defaultFilename: exportName) { result in
            if case .failure(let e) = result { importFailure = e.localizedDescription }
        }
        .alert("Import failed", isPresented: Binding(get: { importFailure != nil }, set: { if !$0 { importFailure = nil } })) { Button("OK") {} } message: { Text(importFailure ?? "") }
        #if os(iOS)
        // The breadcrumb bar is the header (logo, path, filter): the system navigation bar is not shown.
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            // Only while typing, on the Mac: Done (Escape). On iPhone/iPad the check in the item's field is the Done.
            #if os(macOS)
            if focused != nil || editRequest != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { endEdit() }.fontWeight(.semibold).keyboardShortcut(.escape, modifiers: [])
                }
            }
            #endif
        }
        // Another screen (Inbox, Calendar) asked to show an item: make it visible and scroll to it.
        .onChange(of: sel.revealID) { _, id in reveal(id, proxy) }
        }
    }

    private func reveal(_ id: UUID?, _ proxy: ScrollViewProxy) {
        guard let id, let n = store.node(id) else { return }
        sel.revealID = nil
        if let z = zoomID, !isInSubtree(id, of: z) { withAnimation(.snappy(duration: 0.32)) { zoomID = nil } }
        if !matches(n) { filter = .all; tagFilter = nil }
        var p = n.parentID
        while let pid = p, let x = store.node(pid) { if x.collapsed { store.update(x) { $0.collapsed = false } }; p = x.parentID }
        store.save()
        sel.nodeID = id; sel.infoID = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
        }
    }

    /// Name for an export: the zoomed item's title, or the app's name for everything.
    private var exportName: String { zoomID.flatMap { store.node($0)?.title }.flatMap { $0.isEmpty ? nil : $0 } ?? "Schrodinger" }
    private var filtering: Bool { filter != .all || tagFilter != nil }

    /// Filters, in a menu in the navigation bar. The icon fills in while a filter is on.
    private static let headerHeight: CGFloat = 28
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: Binding(get: { filter }, set: { v in withAnimation(.snappy(duration: 0.25)) { filter = v } })) {
                ForEach(Filter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            // Tags in use (typed as #tag in an item's text or notes).
            if !allTags.isEmpty {
                Picker("Tag", selection: Binding(get: { tagFilter }, set: { v in withAnimation(.snappy(duration: 0.25)) { tagFilter = v } })) {
                    Text("Any tag").tag(String?.none)
                    ForEach(allTags, id: \.self) { Text("#" + $0).tag(String?.some($0)) }
                }
                .pickerStyle(.inline)
            }
            if filtering {
                Divider()
                Button(role: .destructive) { withAnimation(.snappy(duration: 0.25)) { filter = .all; tagFilter = nil } } label: { Label("Clear filters", systemImage: "xmark") }
            }
            Divider()
            // Import a CSV, text or Markdown file (a note exported from Notes, say): it becomes a new item, with the
            // file's lines as its children. Zoomed in, it goes under the zoomed item.
            Button { finishTyping(); importing = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
            // Export everything (or, zoomed in, the zoomed item): as text, to share to Notes or anywhere; or as a CSV file.
            Menu {
                ShareLink(item: OutlineText(rootID: zoomID), preview: SharePreview(exportName)) { Label("Share as text (Notes…)", systemImage: "note.text") }
                Button { finishTyping(); exportingCSV = true } label: { Label("Save as CSV…", systemImage: "tablecells") }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Toggle("Show square legend", isOn: Binding(get: { showLegend }, set: { v in withAnimation(.snappy(duration: 0.2)) { showLegend = v } }))
            #if os(iOS)
            // The rest of the app (there is no tab bar): each opens as a sheet over the outline.
            Divider()
            Button { finishTyping(); sel.panel = .inbox } label: {
                Label(openProposals.isEmpty ? "Inbox" : "Inbox (\(openProposals.count))", systemImage: "tray")
            }
            Button { finishTyping(); sel.panel = .settings } label: { Label("Settings", systemImage: "gear") }
            #endif
        } label: {
            // The header's right end: a circle (like the + button). It takes the "on" color while a filter is on.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .heavy)).foregroundStyle(PanelPalette.text(on: filtering ? PanelPalette.peach : PanelPalette.orange))
                .frame(width: Self.headerHeight + 4, height: Self.headerHeight + 4)
                .background { Circle().fill(filtering ? PanelPalette.peach : PanelPalette.orange).panelBlink(31) }
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(filtering ? "Filters (on)" : "Filters")
        .accessibilityLabel(filtering ? "Filters, on" : "Filters")
    }

    /// A quick, mostly horizontal swipe to the right: the "go back" gesture. Distinct from the slower row pull that indents.
    nonisolated static func isBackSwipe(_ v: DragGesture.Value) -> Bool {
        let dx = v.translation.width, dy = v.translation.height
        return dx > 60 && abs(dy) < max(50, dx * 0.5) && v.predictedEndTranslation.width - dx > 80
    }
    /// Same test from a translation and horizontal velocity (points/s), for the UIKit pan on iPhone/iPad.
    nonisolated static func isBackSwipe(dx: CGFloat, dy: CGFloat, vx: CGFloat) -> Bool {
        dx > 60 && abs(dy) < max(50, dx * 0.5) && vx > 300
    }

    /// Zoom into an item (nil = whole outline), animated.
    private func zoom(to id: UUID?) {
        endEdit()
        zoomingIn = id.map { target in zoomID.map { isInSubtree(target, of: $0) && target != $0 } ?? true } ?? false
        withAnimation(.snappy(duration: 0.32)) { zoomID = id; sel.nodeID = nil; sel.infoID = nil }
    }
    /// The square colors of `n`'s ancestors, outermost first (what its children would inherit as their trail).
    private func ancestorColors(_ n: Node, context: Color) -> [Color] {
        var path: [Node] = []
        var p = n.parentID
        while let id = p, let x = store.node(id) { path.insert(x, at: 0); p = x.parentID }
        return path.enumerated().map { i, a in look.itemColor(depth: i, state: a.isProject ? .todo : a.state, assignee: a.isProject ? .human : a.assignee) }
    }
    private func rootIndex(_ n: Node, roots: [Node]) -> Int {
        var r = n; while let pid = r.parentID, let p = store.node(pid) { r = p }
        return roots.firstIndex { $0.id == r.id } ?? 0
    }
    /// New item: a circle with a plus.
    private func newItemButton(_ action: @escaping () -> Void) -> some View {
        cornerButton("NEW ITEM", systemImage: "plus", fill: PanelPalette.orange, help: "New item at the end of the list", action: action)
    }

    /// Ends whatever is being typed and puts the keyboard away.
    private func finishTyping() {
        endEdit(); searchFocused = false
        #if os(iOS)
        // Also covers fields this view does not track (an item's notes).
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// The bottom-right button: a plain filled circle with one glyph.
    private func cornerButton(_ title: String, systemImage: String, fill: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(PanelPalette.text(on: fill))
                .frame(width: 54, height: 54)
                .background { Circle().fill(fill).panelBlink(32) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .padding(.trailing, 16).padding(.bottom, 12)
        .help(help)
        .accessibilityLabel(title.capitalized)
    }

    /// The header: logo (tap = all items), the path down to the zoomed item as flat color blocks (tap one to go
    /// there), and the filter menu at the right end. Always shown, at a fixed height.
    private func breadcrumbBar(_ z: Node?) -> some View {
        var path: [Node] = []
        var p = z
        while let x = p { path.insert(x, at: 0); p = x.parentID.flatMap { store.node($0) } }
        let shown = Array(path.suffix(3))            // deepest three levels; earlier ones fold into "…"
        let h = Self.headerHeight
        return HStack(spacing: 3) {
            // The search field comes first and runs to the screen's left edge; the logo sits inside it.
            searchField(z)
            if path.count > shown.count {
                Text("\u{2026}").font(PanelPalette.label(.caption)).foregroundStyle(PanelPalette.text(on: PanelPalette.rose))
                    .padding(.horizontal, 8).frame(height: h).background { PanelPalette.rose.panelBlink(12) }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                let current = a.id == z?.id
                let fill = current ? PanelPalette.peach : [PanelPalette.lavender, PanelPalette.periwinkle, PanelPalette.rose][i % 3]
                Button { zoom(to: a.id) } label: {
                    Text((a.title.isEmpty ? "Untitled" : a.title).uppercased())
                        .font(PanelPalette.label(.caption)).foregroundStyle(PanelPalette.text(on: fill))
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 8).frame(maxWidth: current ? 180 : 110).frame(height: h)
                        .fixedSize(horizontal: !current, vertical: false)
                        // Only the block's color pulses; its label stays steady and readable.
                        .background { fill.panelBlink(13 + i) }
                }
                .allowsHitTesting(!current)
                .layoutPriority(current ? 1 : 0)
            }
            filterMenu.padding(.leading, 14)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.canvas)
        .animation(.snappy(duration: 0.25), value: zoomID)
    }

    /// Search, the header's first block, flush with the left edge. The logo sits at its start (tap it to leave a
    /// zoom). Type words to match text; tap a tag button (or type #tag) to match tags. No color: a neutral fill.
    private static let searchHeight: CGFloat = 44
    private func searchField(_ z: Node?) -> some View {
        let h = Self.searchHeight
        let fill = Color.primary.opacity(searching || searchFocused ? 0.12 : 0.07)
        let ink = Color.primary
        return HStack(spacing: 8) {
            // Branding: the logo. It is also "all items": tap it to leave a zoom.
            Button { zoom(to: nil) } label: {
                CatLogo().frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .keyboardShortcut("[", modifiers: .command)
            .allowsHitTesting(z != nil)
            .accessibilityLabel(z == nil ? "Schrodinger" : "Schrodinger. All items")
            .accessibilityAddTraits(.isHeader)
            TextField("", text: $search)
                .textFieldStyle(.plain)
                .font(PanelPalette.label(.subheadline)).foregroundStyle(ink).tint(ink)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !search.isEmpty || searchFocused {
                Button { withAnimation(.snappy(duration: 0.25)) { search = "" }; searchFocused = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(ink.opacity(0.7))
                        .frame(width: 24, height: h).contentShape(Rectangle())
                }
                .accessibilityLabel("Clear search")
            } else {
                // Idle: a magnifying glass at the bar's right end stands for search (no word).
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .heavy)).foregroundStyle(ink.opacity(0.5))
                    .frame(width: 24, height: h).padding(.trailing, 8)
                    .accessibilityHidden(true)
            }
        }
        // The logo's ink starts where the top-level circles start, less the drawing's own margin (whisker tips at
        // x = 10 of its 64-unit box).
        .padding(.leading, StatusBar.margin - 30 * 10 / 64).padding(.trailing, 2)
        .frame(minWidth: 60, maxWidth: .infinity).frame(height: h)
        .background { UnevenRoundedRectangle(bottomTrailingRadius: h / 2, topTrailingRadius: h / 2).fill(fill).panelBlink(33) }
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .accessibilityLabel("Search")
    }

    /// Tag buttons, shown under the header while searching. Tap one to add or remove it from the search.
    @ViewBuilder private var tagBar: some View {
        let tags = allTags
        if (searchFocused || searching) && !tags.isEmpty {
            let active = Set(searchTerms.filter { $0.hasPrefix("#") }.map { String($0.dropFirst()) })
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(tags, id: \.self) { t in
                        let on = active.contains(t)
                        let fill = on ? PanelPalette.peach : PanelPalette.color(for: t)
                        Button { toggleTag(t) } label: {
                            // A selected tag also gets a check: in a two-color scheme the fill alone may not differ.
                            Text((on ? "\u{2713} #" : "#") + t.uppercased())
                                .font(PanelPalette.label(.caption)).foregroundStyle(PanelPalette.text(on: fill))
                                .padding(.horizontal, 9).frame(height: 24)
                                .background { fill.panelBlink(40 + t.count) }
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .background(Color.canvas)
            .transition(.opacity)
        }
    }
    /// Open an item with the keyboard in its text.
    private func beginEdit(_ id: UUID) { sel.nodeID = id; sel.infoID = id; editRequest = id }
    /// Done: put the keyboard away and close the open item.
    private func endEdit() { editRequest = nil; focused = nil; sel.infoID = nil; sel.nodeID = nil }

    /// Search terms: lowercase words; a leading # means "has this tag".
    private var searchTerms: [String] { search.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0 != "#" } }
    private var searching: Bool { !searchTerms.isEmpty }
    private func searchMatches(_ n: Node) -> Bool {
        let terms = searchTerms
        if terms.isEmpty { return true }
        let text = (n.title + "\n" + n.notes + "\n" + n.goal).lowercased()
        let tags = n.tags
        return terms.allSatisfy { t in t.hasPrefix("#") ? tags.contains(String(t.dropFirst())) : text.contains(t) }
    }
    /// Tags in use across the outline, most used first.
    private var allTags: [String] {
        var count: [String: Int] = [:]
        for n in all { for t in n.tags { count[t, default: 0] += 1 } }
        return count.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }
    private func toggleTag(_ tag: String) {
        var terms = search.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let i = terms.firstIndex(where: { $0.lowercased() == "#" + tag }) { terms.remove(at: i) } else { terms.append("#" + tag) }
        withAnimation(.snappy(duration: 0.25)) { search = terms.joined(separator: " ") }
    }

    private func matches(_ n: Node) -> Bool {
        if !searchMatches(n) { return false }
        if n.isProject { return true }
        if let t = tagFilter, !n.tags.contains(t) { return false }
        switch filter {
        case .all: return tagFilter == nil || n.state != .done
        case .mine: return (n.assignee == .human || n.isYourTurn) && n.state != .done
        case .ai: return (n.assignee == .ai || (n.assignee == .shared && n.aiStatus == .pending)) && n.state != .done
        case .review: return n.state == .review || n.isYourTurn
        case .blocked: return n.state == .blocked
        case .week: return n.due.map { $0 < Date().addingTimeInterval(7 * 86400) } ?? false && n.state != .done
        }
    }
    private func subtreeMatches(_ n: Node, kids: [UUID?: [Node]]) -> Bool { matches(n) || (kids[n.id] ?? []).contains { subtreeMatches($0, kids: kids) } }

    /// Items under `n` (or `n` itself) the AI can work on right now. Empty = nothing to run, no play button.
    private func runnable(_ n: Node, kids: [UUID?: [Node]]) -> [UUID] {
        let c = kids[n.id] ?? []
        if c.isEmpty { return !n.isProject && ProjectAgent.aiTurn(n) && store.depsSatisfied(n) ? [n.id] : [] }
        return c.flatMap { runnable($0, kids: kids) }
    }

    /// `active`: the item's project is active (paused and archived projects don't run).
    private func nodeTree(_ n: Node, depth: Int, kids: [UUID?: [Node]], files: [UUID: [Attachment]], advice: [UUID: [Proposal]], trail: [Color], context: Color, active: Bool) -> AnyView {
        let children = kids[n.id] ?? []
        // Own color: hue by level (the same in every project), strength by status, darkness by holder (Appearance.itemColor).
        let own = look.itemColor(depth: depth, state: n.isProject ? .todo : n.state, assignee: n.isProject ? .human : n.assignee)
        // Filters hide non-matching items below the top level; a search hides non-matching top-level items too.
        let hidden = ((filter != .all || tagFilter != nil) && depth > 0 && n.id != zoomID || searching) && !subtreeMatches(n, kids: kids)
        if hidden { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            NodeRow(node: n, depth: depth, trail: trail, color: own, hasChildren: !children.isEmpty, leafCount: leafCount(n, kids: kids), sel: sel, focused: $focused, editRequest: $editRequest, drag: drag,
                    onKey: { key in handleKey(key, n, kids: kids) },
                    onDragChanged: { dx, dy in updateDropTarget(n, dx: dx, dy: dy) },
                    onDrop: { performDrop(n) },
                    onZoom: { zoom(to: n.id == zoomID ? n.parentID : n.id) },
                    onPinch: { spread in
                        // Spread two fingers on an item: zoom into it. Pinch in: back out one level.
                        if spread { if n.id != zoomID { zoom(to: n.id) } }
                        else if let z = zoomID { zoom(to: store.node(z)?.parentID) }
                    },
                    swipeBack: zoomID != nil,
                    runnable: active ? runnable(n, kids: kids) : [],
                    childrenShown: !n.collapsed || n.id == zoomID || searching,
                    attachments: files[n.id] ?? [],
                    suggestions: advice[n.id] ?? [])
                .id(n.id)   // scroll target for reveal()
            if !n.collapsed || n.id == zoomID || searching {   // a search looks inside collapsed items
                ForEach(children) { c in nodeTree(c, depth: depth + 1, kids: kids, files: files, advice: advice, trail: trail + [own], context: context, active: active) }
            }
        })
    }

    private func leafCount(_ n: Node, kids: [UUID?: [Node]]) -> (done: Int, total: Int) {
        let c = kids[n.id] ?? []
        if c.isEmpty { return (n.state == .done ? 1 : 0, 1) }
        return c.map { leafCount($0, kids: kids) }.reduce((0, 0)) { ($0.0 + $1.done, $0.1 + $1.total) }
    }

    // MARK: Drag anywhere

    private func depthOf(_ n: Node) -> Int { var d = 0; var p = n.parentID; while let id = p, let x = store.node(id) { d += 1; p = x.parentID }; return d }
    private func isInSubtree(_ id: UUID, of root: UUID) -> Bool { var p: UUID? = id; while let x = p { if x == root { return true }; p = store.node(x)?.parentID }; return false }

    /// Rows currently laid out, top to bottom, excluding the dragged item and its descendants.
    private func visibleOrder(excluding root: UUID) -> [(node: Node, frame: CGRect, depth: Int)] {
        drag.frames.compactMap { id, f in store.node(id).map { ($0, f, 0) } }
            .filter { !isInSubtree($0.0.id, of: root) }
            .sorted { $0.1.minY < $1.1.minY }
            .map { ($0.0, $0.1, depthOf($0.0)) }
    }

    private func updateDropTarget(_ n: Node, dx: CGFloat, dy: CGFloat) {
        if n.id == zoomID { drag.target = nil; return }   // the zoomed item stays put
        guard let own = drag.origin ?? drag.frames[n.id] else { return }
        // Reference point: the item's own line, not the middle of the row (an open action strip makes the row taller).
        let y = own.minY + min(own.height, 40) / 2 + dy
        let rows = visibleOrder(excluding: n.id)
        // Insertion point: before the first row whose middle is below the finger.
        var idx = rows.firstIndex { $0.frame.minY + min($0.frame.height, 40) / 2 > y } ?? rows.count
        if zoomID != nil { idx = max(idx, 1) }   // zoomed: nothing can go above the zoomed item
        let above = idx > 0 && idx <= rows.count ? rows[idx - 1] : nil
        let below = idx < rows.count ? rows[idx] : nil
        let lineY = above.map { $0.frame.maxY } ?? below.map { $0.frame.minY } ?? own.minY
        let maxD = (above?.depth ?? -1) + 1
        let minD = below?.depth ?? 0
        let want = (above?.depth ?? 0) + Int((dx / 44).rounded())
        var depth = max(min(minD, maxD), min(maxD, want))
        if let z = zoomID.flatMap({ store.node($0) }) { depth = max(depth, depthOf(z) + 1) }
        let target = OutlineDrag.Target(y: lineY, depth: depth, aboveID: above?.node.id)
        if let old = drag.target {
            if old.depth != depth { Xylophone.shared.play(OutlinePitch.depth(depth)) }
            else if old.aboveID != target.aboveID { Xylophone.shared.play(OutlinePitch.row(idx)) }
        }
        drag.target = target
    }

    private func performDrop(_ n: Node) {
        defer { drag.target = nil; drag.id = nil; drag.origin = nil }
        guard let t = drag.target else { return }
        let s = store
        guard let aboveID = t.aboveID, let above = s.node(aboveID) else { try? s.move(n, to: nil, position: 0); s.save(); return }
        let aboveDepth = depthOf(above)
        if t.depth > aboveDepth {
            try? s.move(n, to: above.id, position: 0)
            if above.collapsed { s.update(above) { $0.collapsed = false } }
        } else {
            var anc = above
            for _ in 0..<(aboveDepth - t.depth) { guard let pid = anc.parentID, let p = s.node(pid) else { break }; anc = p }
            let sibs = s.children(of: anc.parentID).filter { $0.id != n.id }
            let idx = (sibs.firstIndex(where: { $0.id == anc.id }) ?? (sibs.count - 1)) + 1
            try? s.move(n, to: anc.parentID, position: idx)
        }
        s.save()
    }

    enum Key { case enter, child, tab, shiftTab, backspaceEmpty, altUp, altDown }
    private func handleKey(_ key: Key, _ n: Node, kids: [UUID?: [Node]]) {
        let s = store
        // Moves keep editing only if the item was being edited (strip buttons move without opening the keyboard).
        let wasEditing = focused == n.id || editRequest == n.id
        func keep() { if wasEditing { beginEdit(n.id) } }
        switch key {
        case .enter:
            let created: Node
            if n.id == zoomID || (!(kids[n.id] ?? []).isEmpty && !n.collapsed) { created = s.create(parentID: n.id, position: 0) }
            else { created = s.create(parentID: n.parentID, assignee: n.isProject ? nil : n.assignee, position: n.position + 1) }
            s.save(); beginEdit(created.id)
        case .child:
            // New child at the end of this item's children, ready to type.
            let created = s.create(parentID: n.id, assignee: n.isProject ? nil : n.assignee)
            if n.collapsed { s.update(n) { $0.collapsed = false } }
            s.save(); beginEdit(created.id)
        case .tab:
            let siblings = kids[n.parentID] ?? []
            guard let idx = siblings.firstIndex(where: { $0.id == n.id }), idx > 0 else { return }
            try? s.move(n, to: siblings[idx - 1].id, position: 999); s.save(); keep()
            Xylophone.shared.play(OutlinePitch.depth(depthOf(n)))
        case .shiftTab:
            guard let pid = n.parentID, let parent = s.node(pid) else { return }
            try? s.move(n, to: parent.parentID, position: parent.position + 1); s.save(); keep()
            Xylophone.shared.play(OutlinePitch.depth(depthOf(n)))
        case .backspaceEmpty:
            guard (kids[n.id] ?? []).isEmpty else { return }
            let siblings = kids[n.parentID] ?? []
            let idx = siblings.firstIndex(where: { $0.id == n.id }) ?? 0
            editRequest = nil; focused = nil
            if sel.nodeID == n.id { sel.nodeID = nil }
            if sel.infoID == n.id { sel.infoID = nil }
            s.delete(n); s.save()
            if idx > 0 { beginEdit(siblings[idx - 1].id) }
        case .altUp, .altDown:
            let siblings = kids[n.parentID] ?? []
            guard let idx = siblings.firstIndex(where: { $0.id == n.id }) else { return }
            let to = key == .altUp ? idx - 1 : idx + 1
            guard to >= 0, to < siblings.count else { return }
            // Target index among the on-screen siblings (stored positions can have gaps or duplicates).
            try? s.move(n, to: n.parentID, position: to); s.save(); keep()
            Xylophone.shared.play(OutlinePitch.position(to, depth: depthOf(n)))
        }
    }
}

@Observable @MainActor final class OutlineDrag {
    struct Target: Equatable { var y: CGFloat; var depth: Int; var aboveID: UUID? }
    var id: UUID? = nil
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var frames: [UUID: CGRect] = [:]
    /// The lifted row's frame at the moment it was lifted. Its live frame includes the drag offset, so it can't be used.
    var origin: CGRect? = nil
    var target: Target? = nil
}

struct RowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Hairline progress under a top-level item.
struct ProjectLine: View {
    let node: Node
    let progress: Store.Progress
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.ink.opacity(0.08))
                Rectangle().fill(Color.ink).frame(width: g.size.width * CGFloat(progress.pct) / 100)
            }
        }
        .frame(height: 1.5)
        .padding(.leading, StatusBar.textStart(0)).padding(.trailing, 4).padding(.bottom, 4)
        .opacity(progress.total == 0 ? 0 : 1)
    }
}

// MARK: - Squares

/// The item's own mark: the rightmost one in the row, a circle the size of the squares.
/// Every item's mark has this same shape. Color: see Appearance.itemColor.
///   who holds it: mine or unassigned = blank · AI = sparkles glyph · both = a single sparkle
///   state:        todo/in progress/done = solid · review = hollow · blocked = dashed outline
struct StatusBar: View {
    let state: TaskState
    let assignee: Assignee
    let isProject: Bool
    var color: Color = .ink
    /// Indent level: 0 is a circle; deeper, the mark is a rounded bar (depth + 1) diameters long.
    var depth: Int = 0
    /// The item has notes: a small dot at the mark's left end.
    var hasNotes = false
    /// Side of each square.
    static let h: CGFloat = 16
    static let w: CGFloat = 16
    /// Marks start `margin` from the left edge. A top-level mark is a circle; each level down it is one diameter
    /// longer (2×, 3×…). The row's text starts `gap` after the mark.
    static let margin: CGFloat = 12
    static let gap: CGFloat = 12
    static var ownShape: Capsule { Capsule() }
    /// Width of the mark at `depth`: (depth + 1) diameters.
    static func width(_ depth: Int) -> CGFloat { w * CGFloat(max(depth, 0) + 1) }
    /// Where the text of a row at `depth` starts.
    static func textStart(_ depth: Int) -> CGFloat { margin + width(depth) + gap }

    /// The square is filled (glyph is drawn in the background color) rather than outlined (glyph in the square's color).
    private var solid: Bool { isProject || (state != .review && state != .blocked) }

    var body: some View {
        let shape = Self.ownShape
        ZStack {
            if isProject {
                shape.fill(color)
            } else {
                switch state {
                case .review:  shape.strokeBorder(color, lineWidth: 2)
                case .blocked: shape.strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                default:       shape.fill(color)
                }
                // AI involvement is a glyph in the mark's round end (next to the text); the mark never changes shape.
                if let glyph = assignee.squareGlyph {
                    Image(systemName: glyph)
                        .font(.system(size: assignee == .ai ? 9.5 : 8, weight: .heavy))
                        .foregroundStyle(solid ? Color.canvas : color)
                        .frame(width: Self.w, height: Self.h)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Notes: a dot in the mark's left end (on a circle, its middle unless the AI glyph is there).
            if hasNotes && !(depth == 0 && assignee.squareGlyph != nil) {
                Circle().fill(solid ? Color.canvas : color).frame(width: 5, height: 5)
                    .frame(width: Self.w, height: Self.h)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width(depth), height: Self.h)
        .clipShape(shape)
    }
}

/// The row's mark: a circle for a top-level item; deeper, a rounded bar from the left margin, one diameter longer per
/// level. Tap = actions.
struct DepthBars: View {
    let node: Node
    let depth: Int
    let hasChildren: Bool
    var trail: [Color] = []
    var color: Color = .ink
    /// The item is open: its mark turns down a quarter turn about its left (round) end, hanging beside the field.
    var open = false
    /// The item has children that are hidden: a second oval peeks out below the mark, like a stack. Tap to show them.
    var childrenHidden = false
    /// Each item blinks on its own timing (stable for the item, different from its neighbours).
    private var seed: Int { Int(node.id.uuid.0) + Int(node.id.uuid.15) * 3 }
    var body: some View {
        // No blink here: the mark's strength carries the status, so it holds still.
        StatusBar(state: node.state, assignee: node.assignee, isProject: node.isProject, color: color, depth: depth, hasNotes: !node.notes.isEmpty)
            .background(alignment: .leading) {
                if childrenHidden {
                    StatusBar.ownShape.fill(color.opacity(0.45))
                        .frame(width: StatusBar.width(depth), height: StatusBar.h)
                        .offset(x: 3, y: 4)
                }
            }
            .animation(.snappy(duration: 0.22), value: childrenHidden)
            .rotationEffect(.degrees(open ? 90 : 0), anchor: UnitPoint(x: StatusBar.w / 2 / StatusBar.width(depth), y: 0.5))
            .animation(.snappy(duration: 0.25), value: open)
            .padding(.leading, StatusBar.margin)
            .frame(width: StatusBar.textStart(depth), alignment: .leading)
            .contentShape(Rectangle())
    }
}

extension VerticalAlignment {
    /// Row alignment: middle of the bars = middle of the first line of text.
    private enum RowLine: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] } }
    static var rowLine: VerticalAlignment { VerticalAlignment(RowLine.self) }
}

extension Assignee {
    /// Glyph drawn inside the item's square: sparkles when the AI holds it, one sparkle when it is shared, nothing
    /// when it is mine or unassigned.
    var squareGlyph: String? {
        switch self { case .ai: "sparkles"; case .shared: "sparkle"; case .human, .unassigned: nil }
    }
    /// Strip icon for who holds the item.
    var icon: String {
        switch self { case .human: "person.fill"; case .ai: "sparkles"; case .shared: "person.2.fill"; case .unassigned: "person.slash" }
    }
}

extension TaskState {
    /// Strip icon for the item's status.
    var icon: String {
        switch self {
        case .unset: "circle.dashed"; case .todo: "circle"; case .in_progress: "circle.lefthalf.filled"; case .blocked: "exclamationmark.octagon"
        case .review: "eye"; case .done: "checkmark.circle.fill"
        }
    }
}

struct BarLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Marks").font(.caption.weight(.semibold)).foregroundStyle(Color.ink.opacity(0.6))
            Text("Color is the level, the same in every project:").font(.caption2).foregroundStyle(Color.ink.opacity(0.5))
            ForEach(0..<3, id: \.self) { d in row(mark(d, .todo, .human), "level \(d + 1)") }
            Text("Strength is the status; a darker shade is the AI's:").font(.caption2).foregroundStyle(Color.ink.opacity(0.5)).padding(.top, 4)
            row(mark(1, .unset, .human), "no status yet")
            row(mark(1, .todo, .human), "to-do, in progress")
            row(mark(1, .done, .human), "done")
            row(mark(1, .todo, .ai), "AI")
            row(mark(1, .todo, .shared), "both")
            row(mark(1, .review, .human), "review")
            row(mark(1, .blocked, .human), "blocked")
            row(StatusBar(state: .todo, assignee: .human, isProject: false, color: Appearance.shared.itemColor(depth: 1, state: .todo, assignee: .human), depth: 1, hasNotes: true), "has notes")
        }
        .padding(.leading, 16)
    }
    private func mark(_ depth: Int, _ state: TaskState, _ who: Assignee) -> StatusBar {
        StatusBar(state: state, assignee: who, isProject: false, color: Appearance.shared.itemColor(depth: depth, state: state, assignee: who), depth: depth)
    }
    private func row(_ bar: StatusBar, _ label: String) -> some View {
        HStack(spacing: 10) { bar; Text(label).font(.caption2).foregroundStyle(Color.ink.opacity(0.6)) }
    }
}

// MARK: - Row

struct NodeRow: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    let depth: Int
    var trail: [Color] = []
    var color: Color = .ink
    let hasChildren: Bool
    let leafCount: (done: Int, total: Int)
    var sel: Selection
    var focused: FocusState<UUID?>.Binding
    @Binding var editRequest: UUID?
    let drag: OutlineDrag
    let onKey: (OutlineView.Key) -> Void
    let onDragChanged: (CGFloat, CGFloat) -> Void
    let onDrop: () -> Void
    var onZoom: () -> Void = {}
    /// Two-finger pinch on the row ended: true = fingers spread (zoom in), false = pinched in (zoom out).
    var onPinch: (Bool) -> Void = { _ in }
    /// The page handles a quick right swipe as "back" (zoomed in), so the row must not also indent on it.
    var swipeBack = false
    /// Items the AI can work on now, in this item or under it. Non-empty = show the play button.
    var runnable: [UUID] = []
    /// The item's children are on screen (it is expanded, or it is the item zoomed into).
    var childrenShown = true
    /// The item's photos and links.
    var attachments: [Attachment] = []
    /// The AI's open suggestions about this item, shown in its field with Accept and Dismiss buttons.
    var suggestions: [Proposal] = []
    @Environment(\.openURL) private var openURL
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCalendar = false
    @State private var viewing: Attachment? = nil
    /// The AI is working on suggestions for this item (the lightbulb was tapped).
    /// One line under the suggestions: nothing new came back, or why the request failed.
    @State private var adviceNote: String? = nil
    /// Children made from list lines typed in this field, innermost last, so an indented line nests under the one above.
    @State private var listTrail: [(indent: Int, id: UUID)] = []
    @Environment(HarnessEngine.self) private var harness
    @State private var runFailure: String? = nil
    @State private var title: String = ""
    @State private var pull: CGFloat = 0
    /// A long press lifted this item during the current touch; the tap that its release completes must not zoom.
    @State private var holdFired = false
    /// The current hold began on the text (true) or on the squares (false).
    @State private var heldText = false
    @GestureState private var handleActive = false
    private var lifting: Bool { drag.id == node.id }
    @State private var note: String = ""
    @State private var showNote = false
    @FocusState private var noteFocused: Bool
    /// Return was just pressed in the notes: the focus it takes away is put back instead of ending the edit.
    @State private var noteContinuing = false
    private let pullThreshold: CGFloat = 56

    private var store: Store { Store(ctx) }
    /// One size and weight for every item's text, top level or not, title or notes.
    private var titleFont: Font { Appearance.shared.font.font(.body) }
    private var isLeafTask: Bool { !node.isProject && !hasChildren }
    /// Tap on an unselected row selects it (action strip appears); tap on the selected row deselects it (strip hides).
    private func toggleSelect() {
        withAnimation(.easeOut(duration: 0.15)) {
            if sel.nodeID == node.id { sel.nodeID = nil; if infoOpen { sel.infoID = nil } } else { sel.nodeID = node.id }
        }
    }
    private var done: Bool { node.state == .done && isLeafTask }
    private var editing: Bool { focused.wrappedValue == node.id || editRequest == node.id }
    /// Open the item with the keyboard in its text.
    private func startEdit() {
        commit(); sel.nodeID = node.id; sel.infoID = node.id
        editRequest = node.id; claimEdit()   // if the field is not on screen yet, its onAppear claims focus
    }
    /// Called once the text field is on screen: move focus into it (retry once in case the field isn't focusable yet).
    private func claimEdit() {
        let id = node.id
        Task { @MainActor in
            await Task.yield()
            focused.wrappedValue = id
            try? await Task.sleep(for: .milliseconds(150))
            if editRequest == id && focused.wrappedValue != id { focused.wrappedValue = id }
        }
    }
    private func endEdit() { editRequest = nil; focused.wrappedValue = nil }
    /// A pinch ended at `scale` (1 = no change). Clear spreads zoom in, clear pinches zoom out; small ones do nothing.
    private func pinched(_ scale: CGFloat) {
        guard drag.id == nil else { return }
        if scale > 1.25 { commit(); onPinch(true) } else if scale < 0.8 { commit(); onPinch(false) }
    }
    private var infoOpen: Bool { sel.infoID == node.id }
    /// The item is open: its row is the item field (text, notes, and the controls along the field's bottom edge).
    private var open: Bool { infoOpen || editing }

    /// This row's work is part of the run in progress.
    private var runningHere: Bool {
        guard harness.running else { return false }
        guard let scope = harness.runningScope else { return true }
        return runnable.contains { scope.contains($0) }
    }
    /// Play: have the AI do its work on this item (for a parent, on the ready items under it). Shown only when
    /// there is something to run.
    @ViewBuilder private var runButton: some View {
        if runningHere {
            ProgressView().controlSize(.small).frame(width: 28, height: 22).accessibilityLabel("Running")
        } else {
            Button { run() } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(.plain)
            .disabled(harness.running)
            .opacity(harness.running ? 0.3 : 1)
            .help(runnable.count == 1 ? "Run: have the AI work on this" : "Run: have the AI work on \(runnable.count) items here")
            .accessibilityLabel(runnable.count == 1 ? "Run" : "Run \(runnable.count) items")
        }
    }
    private func run() {
        commit()
        let ids = Set(runnable), project = store.project(of: node).id
        Task { @MainActor in
            let out = await harness.runOnce(projectID: project, only: ids)
            let bad = out.flatMap { $0.components(separatedBy: "\n") }.filter { $0.hasPrefix("failed:") || $0.contains(": error") }
            if !bad.isEmpty { runFailure = bad.joined(separator: "\n") }
        }
    }
    /// A tap on the item, on its text or on its squares, opens it: the item field and the children are shown.
    private func openItem() {
        withAnimation(.snappy(duration: 0.22)) {
            sel.nodeID = node.id; sel.infoID = node.id
            if hasChildren && node.collapsed { toggleChildren() }
        }
    }
    /// A tap on an open item's squares closes it: the field goes away and the children are hidden.
    private func closeItem() {
        endEdit(); noteFocused = false
        withAnimation(.snappy(duration: 0.22)) {
            sel.infoID = nil; if sel.nodeID == node.id { sel.nodeID = nil }
            if hasChildren && !node.collapsed { toggleChildren() }
        }
    }
    private func toggleInfo() { if open { closeItem() } else { openItem() } }
    /// The field's Done: save what was typed and close the field. The children stay as they are.
    private func doneItem() {
        commit(); commitNote()
        endEdit(); noteFocused = false
        withAnimation(.snappy(duration: 0.22)) { sel.infoID = nil; if sel.nodeID == node.id { sel.nodeID = nil } }
    }
    private func toggleChildren() { store.update(node) { $0.collapsed.toggle() }; store.save() }

    /// SwiftData traps when a deleted model's attributes are read, and a row can be re-rendered once more after its node
    /// is deleted (before @Query drops it). Render nothing for a deleted node.
    private var gone: Bool { node.isDeleted || node.modelContext == nil }

    var body: some View {
        if gone { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .rowLine, spacing: 0) {
            DepthBars(node: node, depth: depth, hasChildren: hasChildren, trail: trail, color: color, open: open, childrenHidden: hasChildren && !childrenShown)
                .padding(.vertical, 4)   // wider grab area (the circle and the space left of it are a touch target)
                .contentShape(Rectangle())
                // Tap: open the item (again: close it). Hold: zoom in (on the zoomed item: zoom out). Hold and
                // move: drag.
                .onTapGesture { squareTapped() }
                #if os(iOS)
                .gesture(holdDrag(onText: false))
                #else
                .simultaneousGesture(handleGesture(onText: false))
                #endif
                .alignmentGuide(.rowLine) { _ in 4 + StatusBar.h / 2 }   // middle of the bars
                .help(summary + (open ? " · tap to close" : hasChildren && childrenShown ? " · tap to hide children" : " · tap to open") + " · hold to zoom in · hold and drag to move")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
                .accessibilityHint(open ? "Closes the item" : hasChildren && childrenShown ? "Hides its children" : "Opens the item")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { commit(); toggleInfo() }
                .accessibilityAction(named: "Zoom in") { commit(); onZoom() }

            VStack(alignment: .leading, spacing: 2) {
            // Closed: plain text. Tap: open the item. Hold: open it with the keyboard up. Hold and move: drag.
            // Open: the text is a field, inside the item field.
            if !open {
                Text(title.isEmpty ? "New item" : title)
                    .font(titleFont)
                    .strikethrough(done)
                    .foregroundStyle(title.isEmpty ? Color.ink.opacity(0.3) : done ? Color.ink.opacity(0.4) : Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { tapped() }
                    // iPhone/iPad: a UIKit long press (see TouchGestures.swift); SwiftUI drag gestures here stop the list from
                    // scrolling on iOS 18+. A swipe fails the hold and scrolls; once lifted, scrolling is disabled.
                    #if os(iOS)
                    .gesture(holdDrag(onText: true))
                    #else
                    .simultaneousGesture(handleGesture(onText: true))
                    #endif
            } else {
            // Open: the title, with the item's controls on the same line, at its right end.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(titleFont)
                .fixedSize(horizontal: false, vertical: true)   // wraps to as many lines as it needs beside the controls
                .strikethrough(done)
                .foregroundStyle(done ? Color.ink.opacity(0.4) : Color.ink)
                .focused(focused, equals: node.id)
                .onAppear { if editRequest == node.id { claimEdit() } }
                .onChange(of: editRequest) { _, r in if r == node.id { claimEdit() } }
                // Return always makes a new item (the field is multi-line, so a typed newline is caught here too).
                // Text with a list under its first line (pasted, usually): the list lines become children instead.
                .onChange(of: title) { _, v in
                    guard v.contains("\n") else { return }
                    let lines = v.components(separatedBy: "\n")
                    let (rest, items) = ListText.extract(from: lines.dropFirst().joined(separator: "\n"), includeLastLine: true)
                    if items.isEmpty { title = v.replacingOccurrences(of: "\n", with: " "); commit(); onKey(.enter); return }
                    let head = ListText.item(lines[0])?.title ?? lines[0]
                    title = ([head] + rest.components(separatedBy: "\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                    commit(); addListChildren(items)
                }
                .onSubmit { commit(); onKey(.enter) }
                #if os(macOS)
                .onKeyPress(.tab) { commit(); onKey(.tab); return .handled }
                .onKeyPress(.tab, phases: .down) { press in if press.modifiers.contains(.shift) { commit(); onKey(.shiftTab); return .handled }; return .ignored }
                .onKeyPress(.delete) { if title.isEmpty { onKey(.backspaceEmpty); return .handled }; return .ignored }
                .onKeyPress(.upArrow, phases: .down) { p in if p.modifiers.contains(.option) { commit(); onKey(.altUp); return .handled }; return .ignored }
                .onKeyPress(.downArrow, phases: .down) { p in if p.modifiers.contains(.option) { commit(); onKey(.altDown); return .handled }; return .ignored }
                .onKeyPress(.return, phases: .down) { p in if p.modifiers.contains(.shift) { commit(); openNote(); return .handled }; return .ignored }
                #endif
                controlRow
            }
            }
            // The item's notes, read and edited here in the row, only while the item is open. Closed, a row is just
            // its title.
            if open {
                TextField("Notes", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(titleFont)
                    .foregroundStyle(Color.ink)   // same as the title
                    .focused($noteFocused)
                    // A list started here turns into child items, line by line as each is finished.
                    .onChange(of: note) { _, v in
                        guard noteFocused else { return }
                        let (rest, items) = ListText.extract(from: v, includeLastLine: false, keeping: Set(noteSource.components(separatedBy: "\n")))
                        if !items.isEmpty { note = rest.hasPrefix("\n") ? String(rest.drop { $0 == "\n" }) : rest; addListChildren(items) }
                    }
                    // Return ends the field's editing (a text field's rule); here it means "next line", so typing goes on.
                    .onChange(of: noteFocused) { _, f in
                        // Typing in the notes of a closed item opens it, so the controls are there with the text.
                        if f { if !infoOpen { withAnimation(.snappy(duration: 0.22)) { sel.nodeID = node.id; sel.infoID = node.id } }; return }
                        if noteContinuing { noteContinuing = false; noteFocused = true } else { commitNote() }
                    }
                    .onSubmit { noteReturn() }
            }
            if open && !attachments.isEmpty {
                AttachmentStrip(items: attachments, editing: open,
                                onOpen: { a in if a.kind == .photo { viewing = a } else if let u = a.url { openURL(u) } },
                                onDelete: { a in store.deleteAttachment(a); store.save() })
            }
            if open {
                ItemSheetBody(node: node)   // the AI's draft, when there is one
                suggestionList
            }
            }
            // Open: the column is the item field, one rounded block holding the text and, along its bottom edge, the
            // controls. It reaches left by its own inset so the text stays where it was.
            .padding(.horizontal, open ? ItemField.inset : 0)
            .padding(.top, open ? ItemField.top : 0)
            .padding(.bottom, open ? ItemField.top : 0)
            .background(open ? PanelPalette.field : .clear, in: RoundedRectangle(cornerRadius: 12))
            .padding(.leading, open ? -ItemField.inset : 0)
            // Middle of the first line of text lines up with the middle of the bars.
            .alignmentGuide(.rowLine) { d in let top = open ? ItemField.top : 0; return (d[.firstTextBaseline] - top) * 0.65 + top }
            Spacer(minLength: 6)
            marker.alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            if !runnable.isEmpty { runButton.alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] } }
        }
        .padding(.vertical, 6)
        .onAppear { title = node.title; note = noteSource; showNote = !noteSource.isEmpty }
        .onChange(of: node.title) { _, v in if v != title { title = v } }
        .onChange(of: infoOpen) { _, open in if !open { commitNote(); adviceNote = nil; listTrail = [] } }   // closing the item saves notes being typed
        .onChange(of: noteSource) { _, v in if v != note && !noteFocused { note = v; showNote = !v.isEmpty } }
        .onChange(of: handleActive) { _, active in if !active { finishDrag() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: lifting) { _, now in now }
        .sheet(isPresented: $showCalendar) {
            DateSheet(date: node.due) { d in store.update(node) { $0.due = d }; store.save() }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickedPhotos, maxSelectionCount: 6, matching: .images)
        .onChange(of: pickedPhotos) { _, items in importPhotos(items) }
        .sheet(item: $viewing) { a in
            AttachmentViewer(attachment: a) { viewing = nil; store.deleteAttachment(a); store.save() }
        }
        .alert("Run failed", isPresented: Binding(get: { runFailure != nil }, set: { if !$0 { runFailure = nil } })) { Button("OK") {} } message: { Text(runFailure ?? "") }
        .onChange(of: focused.wrappedValue) { old, new in
            if new == node.id { sel.nodeID = node.id; sel.infoID = node.id; if editRequest == node.id { editRequest = nil } }
            if old == node.id && new != node.id {
                commit()
                // Left with no text at all: the item is removed (this is how an item is deleted on a touch screen).
                // Not while its photo picker is up (it takes the keyboard away), nor once it holds a file or a child.
                if !gone && title.trimmingCharacters(in: .whitespaces).isEmpty && !hasChildren && noteSource.isEmpty && node.artifact == nil
                    && attachments.isEmpty && !showPhotos && !showCalendar && node.due == nil && store.children(of: node.id).isEmpty { deleteItem() }
            }
        }
        }
        .background(sel.nodeID == node.id && !open ? Color.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .background(GeometryReader { g in Color.clear.preference(key: RowFrameKey.self, value: [node.id: g.frame(in: .named("outline"))]) })
        .offset(x: pull + (lifting ? drag.dx * 0.3 : 0), y: lifting ? drag.dy : 0)
        .background(Color.canvas.opacity(lifting ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(lifting ? 0.18 : 0), radius: lifting ? 8 : 0, y: 2)
        .opacity(lifting ? 0.92 : 1)
        .zIndex(lifting ? 1 : 0)
        // Arrows sit at fixed edges: ← outdent on the left, → indent on the right. Pull toward an arrow to use it.
        .overlay(alignment: .leading) { pullArrow("arrow.left", active: pull < -pullThreshold, show: pull < -8).offset(x: 4) }
        .overlay(alignment: .trailing) { pullArrow("arrow.right", active: pull > pullThreshold, show: pull > 8).offset(x: 4) }
        #if os(iOS)
        .gesture(HorizontalPanGesture(onChanged: { t in pullChanged(t) }, onEnded: { t, vx in
            pullEnded(isBack: swipeBack && OutlineView.isBackSwipe(dx: t.width, dy: t.height, vx: vx))
        }))
        .gesture(PinchGesture { scale in pinched(scale) })
        #else
        .simultaneousGesture(MagnifyGesture().onEnded { v in pinched(v.magnification) })
        .simultaneousGesture(pullGesture)
        #endif
        #if os(macOS)
        // Right-click menu on the Mac. On iPhone/iPad a long-press context menu would take over the touch and cancel
        // the hold-and-drag on the bars (and the long press that opens the action strip), so the strip is used there.
        .contextMenu { menu }
        #endif
    }

    /// Pull to move: drag the row left to outdent (←), right to indent (→). The text moves the way it will land.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { v in pullChanged(v.translation) }
            .onEnded { v in pullEnded(isBack: swipeBack && OutlineView.isBackSwipe(v)) }
    }
    private func pullChanged(_ t: CGSize) {
        guard drag.id == nil, abs(t.width) > abs(t.height) * 1.2 else { return }
        var x = t.width
        if node.isProject && x < 0 { x = 0 }
        pull = max(-pullThreshold * 1.6, min(pullThreshold * 1.6, x * 0.6))
    }
    /// `isBack`: the swipe was the page's "go back" gesture, so it must not also indent.
    private func pullEnded(isBack: Bool) {
        let p = pull
        withAnimation(.snappy(duration: 0.22)) { pull = 0 }
        if isBack { return }
        if p < -pullThreshold { commit(); onKey(.shiftTab) }
        else if p > pullThreshold { commit(); onKey(.tab) }
    }

    #if os(iOS)
    /// Hold 0.25 s to lift (release without moving = edit on the text, zoom on the squares), then move to drag.
    private func holdDrag(onText: Bool) -> HoldDragGesture {
        HoldDragGesture(onBegan: { lift(onText: onText) }, onChanged: { t in
            guard drag.id == node.id else { return }
            drag.dx = t.width; drag.dy = t.height
            onDragChanged(drag.dx, drag.dy)
        }, onEnded: { finishDrag() })
    }
    #endif
    /// `onText`: the hold began on the item's text (release without moving = edit) rather than on its squares
    /// (release without moving = zoom).
    private func lift(onText: Bool) {
        guard drag.id == nil else { return }
        holdFired = true; heldText = onText
        pull = 0; commit(); drag.origin = drag.frames[node.id]; drag.id = node.id; drag.dx = 0; drag.dy = 0
    }
    /// Single tap on the text opens the item; on an item with no text it also brings up the keyboard.
    /// Releasing a long press also completes a tap; that tap is ignored.
    private func tapped() {
        if holdFired { holdFired = false; return }
        // An item with no text yet ("New item"): a tap starts typing.
        if title.trimmingCharacters(in: .whitespaces).isEmpty { startEdit(); return }
        commit(); openItem()
    }
    /// Tap on the squares: open the item, or close it if it is open. Same hold guard as `tapped()`.
    /// Tap on the oval: open the item (its notes and controls) and show its children. Tap again: close it and hide
    /// them. A closed item whose children are showing just hides them, so folding it up is one tap.
    private func squareTapped() {
        if holdFired { holdFired = false; return }
        commit()
        if !open && hasChildren && childrenShown { withAnimation(.snappy(duration: 0.22)) { toggleChildren() } } else { toggleInfo() }
    }

    /// The bars are the handle: press and hold (0.25 s), then drag to move the item anywhere in the outline; horizontal
    /// position while dragging picks the depth at the drop point. The hold keeps ordinary swipes scrolling the list, and
    /// movement is measured in global coordinates so the lifted row's own offset doesn't feed back into the drag.
    private func handleGesture(onText: Bool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($handleActive) { v, active, _ in if case .second(true, _) = v { active = true } }
            .onChanged { v in
                guard case .second(true, let d) = v else { return }
                lift(onText: onText)
                guard let d else { return }
                drag.dx = d.translation.width; drag.dy = d.translation.height
                onDragChanged(drag.dx, drag.dy)
            }
    }
    /// Ends a lift whether the gesture finished or was cancelled (GestureState resets in both cases; onEnded does not
    /// run on cancel, which used to leave the row stuck lifted).
    private func finishDrag() {
        guard drag.id == node.id else { return }
        // Held and released without moving: on the text this edits it; on the squares it zooms into the item.
        let still = abs(drag.dx) < 6 && abs(drag.dy) < 6
        drag.dx = 0; drag.dy = 0
        // The release's tap (if any) arrives about now; stop ignoring taps shortly after.
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); holdFired = false }
        if still {
            drag.target = nil; onDrop()
            if heldText { startEdit() } else { onZoom() }
            return
        }
        withAnimation(.snappy(duration: 0.22)) { onDrop() }
    }

    private func pullArrow(_ name: String, active: Bool, show: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: active ? .bold : .regular))
            .foregroundStyle(active ? Color.ink : Color.ink.opacity(0.35))
            .padding(6)
            .background(Color.canvas.opacity(0.9), in: Circle())
            .opacity(show ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var summary: String {
        if node.isProject { return "Project" }
        var parts = [node.state.label, node.assignee.label]
        parts += node.tags.sorted().map { "#" + $0 }
        if node.isYourTurn { parts.append("your turn") }
        return parts.joined(separator: " · ")
    }

    /// Right edge: due date and "your turn" for a single item. Parents show nothing here. The bars carry everything else.
    @ViewBuilder private var marker: some View {
        if !hasChildren && !node.isProject {
            HStack(spacing: 8) {
                if let due = node.due, node.state != .done {
                    Text(due.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(due < Date() ? Color.red : Color.ink.opacity(0.45))
                }
                if node.isYourTurn && node.state != .done { Dot(label: "your turn", filled: true) }
            }
        }
    }

    /// The item field's controls, as bare glyphs along its bottom edge: who holds the item (tap to change), add
    /// photos, calendar (give the item a date), ask the AI for suggestions. At the right: show/hide children (only
    /// when there are some), new child, and Done. Approve / Redo join them at the right while an AI draft awaits
    /// review. Links have no button: a web address typed in the text is shown apart from it as a chip.
    @ViewBuilder private var controlRow: some View {
        let empty = title.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 0) {
            if !node.isProject {
                FieldIcon(systemImage: node.assignee.icon, on: true, width: ItemField.compact) { cycleAssignee() }
                    .help("Responsible: " + node.assignee.label + " (tap to change)")
                    .accessibilityLabel("Responsible: " + node.assignee.label).accessibilityHint("Changes who is responsible")
            }
            FieldIcon(systemImage: "photo", width: ItemField.compact) { showPhotos = true }.help("Add photos").accessibilityLabel("Add photos")
            FieldIcon(systemImage: node.due == nil ? "calendar" : "calendar.badge.checkmark", on: node.due != nil, width: ItemField.compact) { commit(); showCalendar = true }
                .help(node.due.map { "Calendared: " + $0.agendaLabel } ?? "Put on the calendar")
                .accessibilityLabel(node.due.map { "Calendared: " + $0.agendaLabel } ?? "Put on the calendar")
            if node.state == .review {
                // An AI draft is waiting: approve it, or send it back to be redone.
                FieldIcon(systemImage: "arrow.counterclockwise", width: ItemField.compact) { try? store.reject(node, note: ""); store.save() }.help("Have the AI redo the draft").accessibilityLabel("Redo draft")
                FieldIcon(systemImage: "checkmark.seal.fill", on: true, width: ItemField.compact) { try? store.approve(node); store.save() }.help("Approve the draft").accessibilityLabel("Approve draft")
            }
            // New child (down-right arrow) and new sibling (+), filled circles like the corner + button. An item with
            // no text is removed when the keyboard leaves it, so it can't take a child or a sibling yet.
            FieldCircle(systemImage: "arrow.turn.down.right", fill: PanelPalette.orange, compact: true) { commit(); onKey(.child) }
                .disabled(empty)
                .help("New child item").accessibilityLabel("New child item")
            FieldCircle(systemImage: "plus", fill: PanelPalette.orange, compact: true) { commit(); onKey(.enter) }
                .disabled(empty)
                .help("New item below").accessibilityLabel("New item below")
            // Done: close the item's field.
            FieldIcon(systemImage: "checkmark", on: true, width: ItemField.compact) { doneItem() }.help("Done").accessibilityLabel("Done")
        }
        .fixedSize()
        // The last glyph's right edge sits near the field's right edge.
        .padding(.trailing, -(ItemField.compact - 18) / 2)
    }
    /// Who holds the item: me, then the AI, then both, then me again.
    private func cycleAssignee() {
        let next: Assignee = switch node.assignee { case .human, .unassigned: .ai; case .ai: .shared; case .shared: .human }
        store.update(node) { $0.assignee = next }; store.save()
    }

    /// Stores the picked photos on the item, downscaled.
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let id = node.id
        pickedPhotos = []
        Task { @MainActor in
            for item in items {
                if let raw = try? await item.loadTransferable(type: Data.self), let jpeg = AttachmentImage.downscaled(raw) {
                    store.addPhoto(jpeg, to: id)
                }
            }
            store.save()
        }
    }
    /// The AI's feedback on the item, inside its field: each suggestion with a button to accept it and one to
    /// dismiss it. There is no chat; a suggestion is acted on by tapping.
    @ViewBuilder private var suggestionList: some View {
        if !suggestions.isEmpty || adviceNote != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(suggestions) { p in
                    SuggestionRow(proposal: p,
                                  onAccept: { withAnimation(.snappy(duration: 0.22)) { accept(p) } },
                                  onDismiss: { withAnimation(.snappy(duration: 0.22)) { store.dismiss(p); store.save() } })
                }
                if let m = adviceNote {
                    Text(m).font(Appearance.shared.font.font(.body)).foregroundStyle(Color.ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
    }
    private func accept(_ p: Proposal) {
        try? store.accept(p)
        if p.type == .decompose && node.collapsed { store.update(node) { $0.collapsed = false } }   // show the new children
        store.save()
    }
    /// List lines typed in the field become children of the item, in order; an indented line goes under the line above it.
    private func addListChildren(_ items: [ListText.Item]) {
        guard !gone, !items.isEmpty else { return }
        for item in items {
            while let last = listTrail.last, last.indent >= item.indent || store.node(last.id) == nil { listTrail.removeLast() }
            let child = store.create(title: item.title, parentID: listTrail.last?.id ?? node.id, assignee: node.isProject ? nil : node.assignee)
            if item.done { store.update(child) { $0.state = .done } }
            listTrail.append((item.indent, child.id))
        }
        if node.collapsed { store.update(node) { $0.collapsed = false } }
        store.save()
    }
    /// Web addresses typed in the text are taken out of it and kept on the item as links (shown as chips under the text).
    private func popLinks(from text: String) -> String {
        let (rest, links) = LinkText.extract(from: text)
        var kept = rest
        for link in links {
            if let a = store.addLink(link, to: node.id) {
                // Text that was nothing but a link: the site's name stands in for it.
                if kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text == title { kept = a.displayTitle }
            } else { kept += (kept.isEmpty ? "" : " ") + link }
        }
        return kept
    }
    // Bindings for the strip pickers; they write through the store so undo and save work.
    private var assigneeBinding: Binding<Assignee> { Binding(get: { node.assignee }, set: { v in store.update(node) { $0.assignee = v }; store.save() }) }
    private var stateBinding: Binding<TaskState> { Binding(get: { node.state }, set: { v in store.update(node) { $0.state = v }; store.save() }) }

    @ViewBuilder private var menu: some View {
        // This item and everything under it, as text: to Notes, Messages, Mail…
        ShareLink(item: OutlineText(rootID: node.id), preview: SharePreview(node.title.isEmpty ? "Item" : node.title)) { Label("Share…", systemImage: "square.and.arrow.up") }
        Divider()
        if !node.isProject {
            Section("Responsible") {
                ForEach(Assignee.allCases) { a in
                    Button { store.update(node) { $0.assignee = a }; store.save() } label: { if node.assignee == a { Label(a.label, systemImage: "checkmark") } else { Text(a.label) } }
                }
            }
            Menu("Status") {
                ForEach(TaskState.allCases) { st in
                    Button { store.update(node) { $0.state = st }; store.save() } label: { if node.state == st { Label(st.label, systemImage: "checkmark") } else { Text(st.label) } }
                }
            }
            Divider()
        }
        Button { startEdit() } label: { Label("Edit text", systemImage: "pencil") }
        if hasChildren { Button(node.collapsed ? "Show children" : "Hide children") { toggleChildren() } }
        if !node.isProject {
            ControlGroup {
                Button { onKey(.shiftTab) } label: { Label("Outdent", systemImage: "arrow.left") }
                Button { onKey(.tab) } label: { Label("Indent", systemImage: "arrow.right") }
            }
        }
        Button("Move up") { onKey(.altUp) }
        Button("Move down") { onKey(.altDown) }
        Button("Add item below") { onKey(.enter) }
        Button(showNote ? "Edit notes" : "Add notes") { openNote() }
        Divider()
        Button(infoOpen ? "Hide info" : "Info") { toggleInfo() }
        Button("Delete", role: .destructive) { deleteItem() }
    }

    /// Return in the notes: start a new line and keep typing. A list line just finished becomes a child item.
    private func noteReturn() {
        // The field may already have put the line break in (and the list line may already be gone as a child).
        var text = note
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        let (rest, items) = ListText.extract(from: text, includeLastLine: false, keeping: Set(noteSource.components(separatedBy: "\n")))
        addListChildren(items)
        // Lines that left as children leave no blank lines behind.
        var kept = rest
        if !items.isEmpty {
            while kept.hasPrefix("\n") { kept.removeFirst() }
            while kept.hasSuffix("\n\n") { kept.removeLast() }
        }
        note = kept
        noteContinuing = true; noteFocused = true
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); noteContinuing = false }
    }
    private func openNote() { showNote = true; DispatchQueue.main.async { noteFocused = true } }
    /// Clear focus and selection first so nothing reads the node after it is gone, then delete.
    private func deleteItem() {
        endEdit(); noteFocused = false
        if sel.nodeID == node.id { sel.nodeID = nil }
        if sel.infoID == node.id { sel.infoID = nil }
        store.delete(node); store.save()
    }
    /// Where the row's notes are stored: a task's notes; for a top-level item, the text its agent works toward.
    private var noteSource: String { node.isProject ? node.goal : node.notes }
    private func commitNote() {
        guard !gone else { return }
        var n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if n != noteSource {
            // Leaving the notes: a list line still at the end becomes a child too, and links go to the item's chips.
            let (rest, items) = ListText.extract(from: n, includeLastLine: true, keeping: Set(noteSource.components(separatedBy: "\n")))
            addListChildren(items)
            n = popLinks(from: rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if n != noteSource { store.update(node) { if $0.isProject { $0.goal = n } else { $0.notes = n } }; store.save() }
        note = n
        showNote = !n.isEmpty
    }

    private func commit() {
        guard !gone else { return }
        var t = title.trimmingCharacters(in: .whitespaces)
        var assignee: Assignee? = nil, state: TaskState? = nil
        if let r = t.range(of: "\\s*@(ai|me|human|both|shared|none)\\b", options: [.regularExpression, .caseInsensitive]) {
            let tag = t[r].trimmingCharacters(in: .whitespaces).dropFirst().lowercased()
            assignee = ["ai": .ai, "me": .human, "human": .human, "both": .shared, "shared": .shared, "none": .unassigned][String(tag)]
            t.removeSubrange(r)
        }
        // Tags that act: a status (#done #doing #blocked #todo) is applied and removed from the text. Any other #tag
        // stays in the text: it is the item's tag, searchable and filterable.
        for tag in Tags.hashtags(in: t) {
            guard let st = Tags.status[tag] else { continue }
            state = st
            if let r = t.range(of: "\\s*#" + tag + "(?![\\p{L}\\p{N}_-])", options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        if t != node.title { t = popLinks(from: t).trimmingCharacters(in: .whitespaces) }
        if t != node.title || assignee != nil || state != nil {
            store.update(node) { n in
                n.title = t
                if let a = assignee, !n.isProject { n.assignee = a }
                if let st = state, !n.isProject { n.state = st }
            }
            store.save(); title = t
        }
    }
}

struct Dot: View {
    let label: String
    let filled: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle().strokeBorder(Color.ink, lineWidth: 1).background(Circle().fill(filled ? Color.ink : .clear)).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(Color.ink.opacity(0.6))
        }
    }
}

/// Capsule look shared by on-screen actions and menus: optional symbol, optional text; `on` = filled.
struct PillLabel: View {
    var systemImage: String? = nil
    var title: String? = nil
    var on = false
    var chevron = false
    @Environment(\.panelStyle) private var panelStyle
    var body: some View {
        HStack(spacing: 4) {
            if let i = systemImage { Image(systemName: i).font(.system(size: panelStyle ? 13 : 11, weight: panelStyle ? .bold : .semibold)) }
            if let t = title { Text(t).font(.caption.weight(.medium)).lineLimit(1) }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5) }
        }
        .padding(.horizontal, panelStyle ? 14 : (title == nil ? 8 : 10)).padding(.vertical, 6)
        .frame(minWidth: panelStyle ? 46 : 30, minHeight: panelStyle ? 32 : 28)
        .background { Capsule().fill(fill).panelBlink(50 + (title?.count ?? 0)) }
        .foregroundStyle(panelStyle ? PanelPalette.text(on: fill) : (on ? Color.canvas : Color.ink.opacity(0.8)))
        .contentShape(Capsule())
    }
    /// In the item sheet: flat colored capsules (peach when on); elsewhere: ink on canvas.
    private var fill: Color {
        if panelStyle { return on ? PanelPalette.peach : PanelPalette.color(for: (systemImage ?? "") + (title ?? "")) }
        return on ? Color.ink : Color.ink.opacity(0.06)
    }
}

/// Small on-screen action: text or symbol (or both); `on` = filled.
struct Pill: View {
    var text: String? = nil
    var systemImage: String? = nil
    var on = false
    let action: () -> Void
    init(_ text: String, on: Bool = false, action: @escaping () -> Void) { self.text = text; self.on = on; self.action = action }
    init(systemImage: String, title: String? = nil, on: Bool = false, action: @escaping () -> Void) { self.systemImage = systemImage; self.text = title; self.on = on; self.action = action }
    var body: some View {
        Button(action: action) { PillLabel(systemImage: systemImage, title: text, on: on) }
            .buttonStyle(.plain)
    }
}

/// A pill that opens a menu of related choices.
struct PillMenu<Content: View>: View {
    var systemImage: String?
    var title: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu { content() } label: { PillLabel(systemImage: systemImage, title: title) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// The app's mark: a cat head, left half solid with an open eye, right half outline with a closed eye.
/// Drawn from the same 64×64 geometry as public/logo.svg; follows light/dark appearance.
struct CatLogo: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 64
            ctx.translateBy(x: (size.width - 64 * k) / 2, y: (size.height - 64 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            let ink = GraphicsContext.Shading.color(Color.primary)
            let paper = GraphicsContext.Shading.color(Color.canvas)
            let head = Self.head
            let left = Path(CGRect(x: 0, y: 0, width: 32, height: 64)), right = Path(CGRect(x: 32, y: 0, width: 32, height: 64))
            var l = ctx; l.clip(to: left)
            l.fill(head, with: ink)
            l.fill(Path(ellipseIn: CGRect(x: 19.8, y: 34, width: 6.4, height: 8)), with: paper)
            l.fill(Path(ellipseIn: CGRect(x: 21.7, y: 36.7, width: 2.6, height: 2.6)), with: ink)
            l.fill(Self.nose, with: paper)
            var r = ctx; r.clip(to: right)
            r.stroke(head, with: ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            r.fill(Self.nose, with: ink)
            var eye = Path(); eye.move(to: CGPoint(x: 37, y: 38)); eye.addQuadCurve(to: CGPoint(x: 45, y: 38), control: CGPoint(x: 41, y: 41))
            ctx.stroke(eye, with: ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            var wl = Path(); wl.move(to: CGPoint(x: 22, y: 47)); wl.addLine(to: CGPoint(x: 10, y: 45)); wl.move(to: CGPoint(x: 22, y: 50)); wl.addLine(to: CGPoint(x: 11, y: 52))
            ctx.stroke(wl, with: paper, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            var wr = Path(); wr.move(to: CGPoint(x: 42, y: 47)); wr.addLine(to: CGPoint(x: 54, y: 45)); wr.move(to: CGPoint(x: 42, y: 50)); wr.addLine(to: CGPoint(x: 53, y: 52))
            ctx.stroke(wr, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
    private static var head: Path {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 30))
        p.addLine(to: CGPoint(x: 12, y: 10)); p.addLine(to: CGPoint(x: 26, y: 20)); p.addLine(to: CGPoint(x: 38, y: 20))
        p.addLine(to: CGPoint(x: 52, y: 10)); p.addLine(to: CGPoint(x: 50, y: 30))
        p.addQuadCurve(to: CGPoint(x: 50, y: 50), control: CGPoint(x: 56, y: 40))
        p.addQuadCurve(to: CGPoint(x: 32, y: 60), control: CGPoint(x: 40, y: 60))
        p.addQuadCurve(to: CGPoint(x: 14, y: 50), control: CGPoint(x: 24, y: 60))
        p.addQuadCurve(to: CGPoint(x: 14, y: 30), control: CGPoint(x: 8, y: 40))
        p.closeSubpath()
        return p
    }
    private static var nose: Path {
        var p = Path(); p.move(to: CGPoint(x: 30, y: 46)); p.addLine(to: CGPoint(x: 34, y: 46)); p.addLine(to: CGPoint(x: 32, y: 49)); p.closeSubpath(); return p
    }
}

/// Kept for other views that still show a compact chip.
struct Chip: View {
    let text: String
    let color: Color
    var faded = false
    var dashed = false
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.ink.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.ink.opacity(dashed ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .foregroundStyle(Color.ink.opacity(faded ? 0.4 : 0.8))
    }
}

extension Color {
    /// Ink and canvas follow the system appearance: black on white in light mode, white on black in dark mode.
    static var ink: Color { .primary }
    #if os(macOS)
    static var canvas: Color { Color(nsColor: .textBackgroundColor) }
    #else
    static var canvas: Color { Color(uiColor: .systemBackground) }
    #endif
}
