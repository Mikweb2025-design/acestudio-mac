import SwiftUI

// MARK: - Design tokens

/// Signature gradient used for the app mark and the primary action.
let brandGradient = LinearGradient(
    colors: [Color(red: 0.42, green: 0.29, blue: 0.96), Color(red: 0.87, green: 0.27, blue: 0.55)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

// MARK: - Root

struct ContentView: View {
    @Environment(Store.self) var store
    @State private var showInspector = !CommandLine.arguments.contains("--no-inspector")

    var body: some View {
        // The player bar lives OUTSIDE the split view: inside a split column its changing
        // content re-triggered the column min-size computation and crashed AppKit.
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar()
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            } detail: {
                // Plain side panel instead of `.inspector`: the inspector's split controller
                // re-computed its min size on every playback tick and crashed AppKit.
                HStack(spacing: 0) {
                    Group {
                        switch store.section {
                        case .create: CreateView()
                        case .library: LibraryView(likedOnly: false)
                        case .liked: LibraryView(likedOnly: true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        Divider()
                        TrackInspector()
                            .frame(width: 340)
                            .frame(maxHeight: .infinity)
                            .background(.background)
                    }
                }
                .frame(minWidth: 1000, maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInspector.toggle() } label: {
                            Label("Track details", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide track details")
                    }
                }
            }
            if store.nowPlaying != nil {
                PlayerBar()
                    .frame(height: 64)
                    .transition(.move(edge: .bottom))
            }
        }
    }
}

struct Sidebar: View {
    @Environment(Store.self) var store

    var body: some View {
        List(selection: Binding(get: { store.section }, set: { if let s = $0 { store.section = s } })) {
            Section {
                Label("Create", systemImage: "wand.and.stars").tag(Store.Section.create)
                    .badge(store.jobs.count)
            }
            Section("Library") {
                Label("All songs", systemImage: "music.note.list").tag(Store.Section.library)
                    .badge(store.tracks.count)
                Label("Liked", systemImage: "heart").tag(Store.Section.liked)
                    .badge(store.tracks.filter(\.isLiked).count)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { BrandHeader() }
        .safeAreaInset(edge: .bottom) { StatusPanel().padding(10) }
    }
}

/// App mark + tagline at the top of the sidebar.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(brandGradient)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 0) {
                Text("ACE Studio").font(.headline)
                Text("Local AI songs").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

struct StatusPanel: View {
    @Environment(Store.self) var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(dotColor.opacity(0.22)).frame(width: 18, height: 18)
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("ACE-Step 1.5").font(.caption.weight(.semibold))
                    Text(engineText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if case .error = store.engineState {
                    Button("Retry") { Task { await store.ensureEngine() } }.controlSize(.mini)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "memorychip").font(.caption2)
                    Text("Free memory").font(.caption2)
                    Spacer()
                    Text(String(format: "%4.1f GB", store.memory.availableGB)).font(.caption2.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .foregroundStyle(.secondary)
                Gauge(value: min(store.memory.availableGB / store.memory.totalGB, 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(store.memory.availableGB < 3 ? .orange : .green)
            }
            if !store.stoppedServices.isEmpty {
                Label("Qwen TTS and Jarvis paused", systemImage: "pause.circle.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Paused to free RAM; they restart when you quit ACE Studio")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var dotColor: Color {
        switch store.engineState {
        case .ready: .green
        case .starting: .yellow
        case .stopped: .gray
        case .error: .red
        }
    }

    var engineText: String {
        switch store.engineState {
        case .ready: "Ready · up to 3 min"
        case .starting: "Starting engine…"
        case .stopped: "Stopped"
        case .error(let m): m
        }
    }
}

// MARK: - Create

enum CreateOptions {
    static let inspirations = [
        "a melancholic pop ballad about rain in Milan",
        "a summer reggaeton hit about love on the beach",
        "energetic rock for a morning run",
        "relaxing lo-fi to study to, instrumental",
        "hip hop about the outskirts and big dreams",
        "late-night jazz with sax and a soft female voice",
        "80s synthwave about a night drive",
        "a fun, upbeat birthday song",
    ]
    static let styles = ["pop", "rock", "hip hop", "trap", "lo-fi", "jazz", "house", "techno", "reggaeton",
                         "singer-songwriter", "ballad", "funk", "acoustic", "orchestral", "synthwave",
                         "r&b", "country", "piano", "electric guitar", "upbeat", "melancholic", "dreamy"]
    static let tags = ["[Intro]", "[Verse]", "[Pre-Chorus]", "[Chorus]", "[Bridge]", "[Solo]", "[Outro]"]
    static let languages = [("auto", "Auto (from your description)"), ("it", "Italian"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
                            ("de", "German"), ("pt", "Portuguese"), ("ja", "Japanese"), ("zh", "Chinese")]
    static let keys = ["", "C major", "G major", "D major", "A major", "E major", "F major", "Bb major", "Eb major",
                       "A minor", "E minor", "D minor", "B minor", "C minor", "G minor", "F# minor"]
}

struct CreateView: View {
    @Environment(Store.self) var store

    var body: some View {
        @Bindable var store = store
        // Plain HStack, not HSplitView: the split view's min-size feedback with the wrapping
        // chips caused an AppKit "update constraints" loop that crashed the app.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("Mode", selection: $store.mode) {
                    Text("Simple").tag(Mode.simple)
                    Text("Custom").tag(Mode.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)

                Form {
                    if store.mode == .simple { SimpleComposer() } else { CustomComposer() }
                    CommonOptions()
                }
                .formStyle(.grouped)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { CreateBar() }
            .frame(width: 470)

            Divider()

            Feed()
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("Create")
        .navigationSubtitle(store.mode == .simple ? "Describe the song and the AI writes lyrics and style" : "Write the style and lyrics yourself")
    }
}

struct SimpleComposer: View {
    @Environment(Store.self) var store

    var body: some View {
        @Bindable var store = store
        Section {
            PlaceholderEditor(text: $store.draft.description,
                              placeholder: "What is it about and how does it sound? E.g. a melancholic pop ballad about rain in Milan, female vocals, piano",
                              minHeight: 110)
            FlowChips(items: CreateOptions.inspirations, icon: "lightbulb") { store.draft.description = $0 }
        } header: {
            Label("Song description", systemImage: "text.bubble")
        } footer: {
            Text("The AI writes title, lyrics and style around the genre and theme you describe; then the track renders on its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CustomComposer: View {
    @Environment(Store.self) var store

    var body: some View {
        @Bindable var store = store
        Section {
            TextField("Title", text: $store.draft.title, prompt: Text("Automatic if empty"))
        }
        Section {
            PlaceholderEditor(text: $store.draft.style,
                              placeholder: "e.g. italian pop, upbeat, female vocals, acoustic guitar, synth, 120 bpm",
                              minHeight: 60)
            FlowChips(items: CreateOptions.styles, icon: nil) { s in
                let cur = store.draft.style.trimmingCharacters(in: .whitespaces)
                store.draft.style = cur.isEmpty ? s : cur + ", " + s
            }
        } header: {
            Label("Music style", systemImage: "slider.horizontal.3")
        }
        Section {
            if !store.draft.instrumental {
                PlaceholderEditor(text: $store.draft.lyrics,
                                  placeholder: "[Verse]\nWrite your lyrics here…\n\n[Chorus]\n…",
                                  minHeight: 220, monospaced: true)
                FlowChips(items: CreateOptions.tags, icon: nil) {
                    store.draft.lyrics += (store.draft.lyrics.isEmpty ? "" : "\n\n") + $0 + "\n"
                }
                HStack {
                    Button {
                        store.writeLyrics()
                    } label: {
                        if store.writing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("The AI is writing…") }
                        } else {
                            Label(store.draft.lyrics.isEmpty ? "Write lyrics with AI" : "Rewrite with AI", systemImage: "sparkles")
                        }
                    }
                    .disabled(store.writing)
                    .help("Generate lyrics from your title, style and voice")
                    Spacer()
                    Text("\(store.draft.lyrics.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("[") && !$0.isEmpty }.count) lines")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let err = store.writeError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Label("Lyrics", systemImage: "text.quote")
        }
    }
}

struct CommonOptions: View {
    @Environment(Store.self) var store

    var body: some View {
        @Bindable var store = store
        Section {
            Toggle(isOn: $store.draft.instrumental) { Label("Instrumental", systemImage: "pianokeys") }
            if !store.draft.instrumental {
                Picker(selection: $store.draft.voice) {
                    ForEach(Voice.allCases) { Text($0.label).tag($0) }
                } label: { Label("Voice", systemImage: "person.wave.2") }
                Picker(selection: $store.draft.language) {
                    ForEach(CreateOptions.languages, id: \.0) { Text($0.1).tag($0.0) }
                } label: { Label("Language", systemImage: "globe") }
            }
            LabeledContent {
                HStack {
                    Slider(value: $store.draft.duration, in: 30...Store.maxSongSeconds, step: 5)
                    Text(mmss(store.draft.duration)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            } label: { Label("Duration", systemImage: "timer") }
            Toggle(isOn: $store.draft.planning) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("AI planning", systemImage: "brain")
                    Text("ACE's LLM sketches melody and vocal parts before generating: cleaner vocals, +30–60 s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup {
                Stepper(value: $store.draft.bpm, in: 0...220, step: 5) {
                    LabeledContent("BPM", value: store.draft.bpm == 0 ? "Auto" : "\(store.draft.bpm)")
                }
                Picker("Key", selection: $store.draft.key) {
                    ForEach(CreateOptions.keys, id: \.self) { Text($0.isEmpty ? "Auto" : $0).tag($0) }
                }
                TextField("Seed", text: $store.draft.seed, prompt: Text("Random"))
                Stepper(value: $store.draft.steps, in: 4...20) {
                    LabeledContent("Quality (steps)", value: "\(store.draft.steps)")
                }
            } label: { Label("Advanced", systemImage: "gearshape") }
        }
    }
}

struct CreateBar: View {
    @Environment(Store.self) var store

    var body: some View {
        VStack(spacing: 6) {
            Button { store.create() } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Create")
                    Text("· \(mmss(store.draft.duration))").foregroundStyle(.white.opacity(0.75))
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(brandGradient)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!store.canCreate)
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    var hint: String {
        if store.engineState != .ready { return "Starts as soon as the engine is ready" }
        let est = Store.estimate(store.draft, writing: store.mode == .simple)
        return "Estimated ~\(Int((est / 60).rounded(.up))) min · ⌘↩"
    }
}

// MARK: - Feed (right side of Create)

struct Feed: View {
    @Environment(Store.self) var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selected) {
            if !store.jobs.isEmpty {
                Section("In progress") {
                    ForEach(store.jobs) { JobRow(job: $0).selectionDisabled() }
                }
            }
            if !store.failed.isEmpty {
                Section("Failed") {
                    ForEach(store.failed.prefix(3)) { job in
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 52)
                            VStack(alignment: .leading) {
                                Text(job.title).fontWeight(.medium)
                                Text(job.error ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Dismiss") { store.dismissFailed(job) }.controlSize(.small)
                        }
                        .selectionDisabled()
                    }
                }
            }
            Section("Your songs") {
                if store.tracks.isEmpty {
                    ContentUnavailableView("No songs yet", systemImage: "music.note",
                                           description: Text("Describe a song on the left and press Create."))
                }
                ForEach(store.tracks) { TrackRow(track: $0).tag($0.id) }
            }
        }
        .listStyle(.inset)
    }
}

struct JobRow: View {
    @Environment(Store.self) var store
    let job: Job

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary)
                    if let start = job.started {
                        ProgressRing(value: overall(ctx.date.timeIntervalSince(start)))
                            .padding(10)
                    } else {
                        Image(systemName: "hourglass").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(job.title).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        if job.started == nil {
                            Button { store.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from queue")
                        }
                    }
                    if let start = job.started {
                        let elapsed = ctx.date.timeIntervalSince(start)
                        HStack(spacing: 6) {
                            Image(systemName: phaseIcon).symbolEffect(.pulse)
                            Text(phaseText)
                        }
                        .font(.caption).foregroundStyle(.tint)
                        Text("\(mmss(elapsed)) elapsed · ~\(mmss(max(job.estimatedSeconds - elapsed, 0))) left · song \(mmss(job.draft.duration))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text(store.engineState == .ready ? "Queued · song \(mmss(job.draft.duration))" : "Waiting for engine")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    var phaseIcon: String {
        switch job.phase {
        case "Writing lyrics & style": "text.word.spacing"
        case "Planning melody & vocals": "brain"
        case "Composing": "waveform"
        case "Decoding audio", "Saving": "square.and.arrow.down"
        default: "gearshape.2"
        }
    }

    var phaseText: String {
        if let f = job.fraction, job.phase == "Composing" { return "Composing \(Int(f * 100))%" }
        return job.phase
    }

    func overall(_ elapsed: Double) -> Double {
        let byTime = min(elapsed / job.estimatedSeconds, 0.97)
        switch job.phase {
        case "Composing": return max(byTime, 0.3 + 0.55 * (job.fraction ?? 0))
        case "Decoding audio": return max(byTime, 0.88)
        case "Saving": return 0.98
        default: return byTime
        }
    }
}

struct ProgressRing: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 4)
            Circle().trim(from: 0, to: value)
                .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: value)
            Text("\(Int(value * 100))").font(.system(size: 9, weight: .bold).monospacedDigit())
        }
    }
}

struct TrackRow: View {
    @Environment(Store.self) var store
    let track: Track
    @State private var hover = false

    var body: some View {
        let isCurrent = store.nowPlaying?.id == track.id
        HStack(spacing: 12) {
            ZStack {
                Artwork(seed: track.id, style: track.style, cornerRadius: 9, showGlyph: false, cover: track.coverURL, loading: store.coversInProgress.contains(track.id))
                if hover || isCurrent {
                    Color.black.opacity(0.35).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Image(systemName: isCurrent && store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 52, height: 52)
            .onTapGesture { store.toggle(track) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.title).fontWeight(.semibold).lineLimit(1)
                    if isCurrent && store.isPlaying {
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(.tint)
                    }
                }
                Text(track.style).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(mmss(track.duration))
                    if let b = track.song?.bpm, b > 0 { Text("\(b) BPM") }
                    if let k = track.song?.key, !k.isEmpty { Text(k) }
                    if track.lyrics.isEmpty { Text("Instrumental") }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { store.toggleLike(track) } label: {
                Image(systemName: track.isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(track.isLiked ? .pink : .secondary)
            }
            .buttonStyle(.borderless)
            TrackMenu(track: track)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .draggable(track.url)
        .contextMenu { TrackMenuItems(track: track) }
    }
}

struct TrackMenu: View {
    let track: Track
    var body: some View {
        Menu { TrackMenuItems(track: track) } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

struct TrackMenuItems: View {
    @Environment(Store.self) var store
    let track: Track
    @State private var renaming = false

    var body: some View {
        Button("Create a variation", systemImage: "arrow.triangle.branch") { store.variation(of: track) }
        Button("Reuse settings", systemImage: "arrow.uturn.left") { store.reuse(track) }
        if store.hasIonosKey {
            Button(track.coverURL == nil ? "Generate AI cover" : "Regenerate AI cover", systemImage: "photo.badge.plus") {
                store.makeCover(for: track)
            }
        }
        Button(track.isLiked ? "Remove from Liked" : "Add to Liked", systemImage: "heart") { store.toggleLike(track) }
        Button("Reveal in Finder", systemImage: "folder") { store.reveal(track) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { store.delete(track) }
    }
}

// MARK: - Library

struct LibraryView: View {
    @Environment(Store.self) var store
    let likedOnly: Bool
    @State private var search = ""
    @State private var sort = 0

    var body: some View {
        @Bindable var store = store
        let items = store.tracks
            .filter { !likedOnly || $0.isLiked }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.style.localizedCaseInsensitiveContains(search) || $0.lyrics.localizedCaseInsensitiveContains(search) }
            .sorted { sort == 0 ? $0.created > $1.created : $0.title.localizedCompare($1.title) == .orderedAscending }
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView(likedOnly ? "No liked songs" : "Library is empty",
                                       systemImage: likedOnly ? "heart" : "music.note.list",
                                       description: Text(likedOnly ? "Tap the heart on a song to save it here." : "The songs you create appear here."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 20)], spacing: 24) {
                ForEach(items) { LibraryCard(track: $0) }
            }
            .padding(20)
        }
        .searchable(text: $search, prompt: "Search title, style or lyrics")
        .navigationTitle(likedOnly ? "Liked" : "Library")
        .navigationSubtitle("\(items.count) songs")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    Text("Newest").tag(0)
                    Text("Title").tag(1)
                }
                .pickerStyle(.menu)
            }
            if store.hasIonosKey && store.tracks.contains(where: { $0.coverURL == nil }) {
                ToolbarItem {
                    Button("Generate missing covers", systemImage: "photo.stack") { store.makeMissingCovers() }
                        .help("Create covers with FLUX.1-schnell (IONOS) for tracks that have none")
                }
            }
            ToolbarItem {
                Button("Open folder", systemImage: "folder") { NSWorkspace.shared.open(Paths.library) }
            }
        }
    }
}

struct LibraryCard: View {
    @Environment(Store.self) var store
    let track: Track
    @State private var hover = false

    var body: some View {
        let isCurrent = store.nowPlaying?.id == track.id
        let selected = store.selected == track.id
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(seed: track.id, style: track.style, cornerRadius: 14, cover: track.coverURL, loading: store.coversInProgress.contains(track.id))
                    .shadow(color: .black.opacity(hover ? 0.3 : 0.15), radius: hover ? 12 : 6, y: 4)
                    .scaleEffect(hover ? 1.02 : 1)
                if hover || isCurrent {
                    Button { store.toggle(track) } label: {
                        Image(systemName: isCurrent && store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(.ultraThickMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(track.title).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if track.isLiked { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
                }
                Text(track.style).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(mmss(track.duration)) · \(track.created.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.spring(duration: 0.25), value: hover)
        .onHover { hover = $0 }
        .onTapGesture { store.selected = track.id }
        .onTapGesture(count: 2) { store.toggle(track) }
        .draggable(track.url)
        .contextMenu { TrackMenuItems(track: track) }
    }
}

// MARK: - Inspector

struct TrackInspector: View {
    @Environment(Store.self) var store
    @State private var editingTitle = ""

    var body: some View {
        if let t = store.selectedTrack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Artwork(seed: t.id, style: t.style, cornerRadius: 18, cover: t.coverURL, loading: store.coversInProgress.contains(t.id))
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                    TextField("Title", text: Binding(get: { t.title }, set: { store.rename(t, to: $0) }))
                        .font(.title2.weight(.bold))
                        .textFieldStyle(.plain)
                    HStack(spacing: 10) {
                        Button { store.toggle(t) } label: {
                            Label(store.nowPlaying?.id == t.id && store.isPlaying ? "Pause" : "Play",
                                  systemImage: store.nowPlaying?.id == t.id && store.isPlaying ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(brandGradient)
                        Button { store.toggleLike(t) } label: {
                            Image(systemName: t.isLiked ? "heart.fill" : "heart").foregroundStyle(t.isLiked ? .pink : .primary)
                        }
                        TrackMenu(track: t)
                    }
                    .controlSize(.large)
                    WaveformView(url: t.url,
                                 progress: store.nowPlaying?.id == t.id ? store.position / max(store.length, 0.1) : 0) { f in
                        if store.nowPlaying?.id != t.id { store.toggle(t) }
                        store.seek(f * store.length)
                    }
                    .frame(height: 44)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        meta("Duration", mmss(t.duration))
                        if let b = t.song?.bpm, b > 0 { meta("BPM", "\(b)") }
                        if let k = t.song?.key, !k.isEmpty { meta("Key", k) }
                        if let v = t.song?.voice, v != .auto, !(t.song?.instrumental ?? false) { meta("Voice", v.label) }
                        if !t.seed.isEmpty { meta("Seed", t.seed) }
                        meta("Created", t.created.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.callout)

                    HStack {
                        Button("Variation", systemImage: "arrow.triangle.branch") { store.variation(of: t) }
                        Button("Reuse", systemImage: "arrow.uturn.left") { store.reuse(t) }
                    }
                    .controlSize(.regular)

                    if let d = t.song?.description, !d.isEmpty {
                        GroupBox { Text(d).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            label: { Label("Prompt", systemImage: "text.bubble") }
                    }
                    GroupBox {
                        Text(t.style).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    } label: { Label("Style", systemImage: "slider.horizontal.3") }
                    GroupBox {
                        Text(t.lyrics.isEmpty ? "Instrumental" : LyricsFormatter.attributed(t.lyrics))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    } label: { Label("Lyrics", systemImage: "text.quote") }
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView("No track selected", systemImage: "music.note",
                                   description: Text("Select a song to see its cover, lyrics and details."))
        }
    }

    @ViewBuilder func meta(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
        }
    }
}

enum LyricsFormatter {
    /// Section tags ([Chorus]…) in bold accent colour, lyrics in body text.
    static func attributed(_ lyrics: String) -> AttributedString {
        var out = AttributedString()
        for (i, line) in lyrics.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out += AttributedString("\n") }
            var a = AttributedString(String(line))
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                a.font = .caption.weight(.bold)
                a.foregroundColor = .accentColor
            }
            out += a
        }
        return out
    }
}

// MARK: - Player

struct PlayerBar: View {
    @Environment(Store.self) var store

    var body: some View {
        @Bindable var store = store
        if let t = store.nowPlaying {
            HStack(spacing: 14) {
                Artwork(seed: t.id, style: t.style, cornerRadius: 7, showGlyph: false, cover: t.coverURL, loading: store.coversInProgress.contains(t.id))
                    .frame(width: 44, height: 44)
                    .onTapGesture { store.selected = t.id }
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).fontWeight(.semibold).lineLimit(1)
                    Text(t.style).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 180, alignment: .leading)
                HStack(spacing: 4) {
                    Button { store.playAdjacent(-1) } label: { Image(systemName: "backward.fill") }
                    Button { store.toggle(t) } label: {
                        Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 32))
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button { store.playAdjacent(1) } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.plain)
                Text(mmss(store.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                WaveformView(url: t.url, progress: store.position / max(store.length, 0.1)) { store.seek($0 * store.length) }
                    .frame(height: 30)
                Text(mmss(store.length)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).font(.caption)
                Slider(value: $store.volume, in: 0...1).frame(width: 80).controlSize(.small)
                Button { store.toggleLike(t) } label: {
                    Image(systemName: (store.tracks.first { $0.id == t.id }?.isLiked ?? false) ? "heart.fill" : "heart")
                }
                .buttonStyle(.borderless)
                Button { store.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(Store.self) var store
    @AppStorage("stopEngineOnQuit") var stopEngine = true
    @AppStorage("restoreServicesOnQuit") var restoreServices = true
    @AppStorage("lyricsEngine") var lyricsEngine = "ionos"
    @State private var keyField = ""
    @State private var providers = ProviderStore.load()
    @State private var showAdd = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label(store.hasIonosKey ? "Key stored in Keychain" : "No key",
                          systemImage: store.hasIonosKey ? "checkmark.seal.fill" : "key")
                        .foregroundStyle(store.hasIonosKey ? .green : .secondary)
                }
                SecureField("Paste your IONOS key", text: $keyField)
                HStack {
                    Button("Save") { store.setIonosKey(keyField); keyField = "" }.disabled(keyField.isEmpty)
                    Button("Import from file…") {
                        let panel = NSOpenPanel()
                        panel.directoryURL = Paths.home.appendingPathComponent("Downloads")
                        panel.allowedContentTypes = [.plainText]
                        if panel.runModal() == .OK, let u = panel.url { store.importIonosKey(from: u) }
                    }
                    if store.hasIonosKey { Button("Remove", role: .destructive) { store.setIonosKey("") } }
                }
                if let e = store.coverError { Text(e).font(.caption).foregroundStyle(.orange) }
            } header: {
                Text("AI covers · IONOS AI Model Hub (FLUX.1-schnell)")
            } footer: {
                Text("The title, style and two lines of the chorus are sent to IONOS to create the cover (~3 s).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Lyrics and style writer", selection: $lyricsEngine) {
                    Text("IONOS · Qwen3.5-397B (built-in)").tag("ionos")
                    ForEach(providers) { p in Text(p.label).tag(p.id.uuidString) }
                    Text("ACE-Step built-in LLM (local)").tag("ace")
                }
                ForEach(providers) { p in
                    HStack {
                        Image(systemName: lyricsEngine == p.id.uuidString ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(lyricsEngine == p.id.uuidString ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(p.label).lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) { remove(p) }.controlSize(.small)
                    }
                }
                Button("Add model…", systemImage: "plus.circle") { showAdd = true }
                if let e = Store.lastWriterError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Add Claude, Grok, OpenRouter (free models), Groq, Gemini, Mistral, DeepSeek, OpenAI or any OpenAI-compatible server. If the chosen model fails, IONOS and then ACE's local LLM write the song.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory") {
                Toggle("Stop the ACE-Step engine on quit (frees ~4 GB)", isOn: $stopEngine)
                Toggle("Restart Qwen TTS and Jarvis on quit", isOn: $restoreServices)
            }
            Section("Paths") {
                LabeledContent("Library", value: Paths.library.path)
                LabeledContent("Engine log", value: Paths.serverLog.path)
                LabeledContent("Music", value: "ACE-Step 1.5 turbo (local)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
        .sheet(isPresented: $showAdd) {
            AddModelSheet { p in
                providers.append(p)
                ProviderStore.save(providers)
                lyricsEngine = p.id.uuidString
            }
        }
    }

    private func remove(_ p: LLMProvider) {
        providers.removeAll { $0.id == p.id }
        ProviderStore.save(providers)
        SecretStore.save(p.keyAccount, "")
        if lyricsEngine == p.id.uuidString { lyricsEngine = "ionos" }
    }
}

/// Adds an LLM as lyrics writer: service, API key, model (loaded from the service), quick test.
struct AddModelSheet: View {
    let onSave: (LLMProvider) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ProviderKind = .anthropic
    @State private var baseURL = ProviderKind.anthropic.baseURL
    @State private var apiKey = ""
    @State private var model = "claude-opus-5-5"
    @State private var models: [String] = ProviderKind.anthropic.presetModels
    @State private var freeOnly = true
    @State private var status: String?
    @State private var busy = false
    private let id = UUID()

    private var draft: LLMProvider { LLMProvider(id: id, kind: kind, baseURL: baseURL, model: model) }
    private var shownModels: [String] { kind == .openrouter && freeOnly ? models.filter { $0.hasSuffix(":free") } : models }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Service", selection: $kind) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: kind) { _, k in
                    baseURL = k.baseURL
                    models = k.presetModels
                    model = k.presetModels.first ?? ""
                    status = nil
                }
                TextField("Base URL", text: $baseURL).disabled(kind != .custom)
                HStack {
                    SecureField(kind.needsKey ? "API key" : "API key (optional)", text: $apiKey)
                    if let u = kind.keyURL { Link("Get a key", destination: u).font(.caption) }
                }
                HStack {
                    if shownModels.isEmpty {
                        TextField("Model", text: $model, prompt: Text("Load the models or type an id"))
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(shownModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button("Load models") { Task { await load() } }
                        .disabled(busy || (kind.needsKey && apiKey.isEmpty))
                }
                if kind == .openrouter { Toggle("Only free models", isOn: $freeOnly) }
                Text(kind.note).font(.caption).foregroundStyle(.secondary)
                if let status { Text(status).font(.caption).foregroundStyle(status.hasPrefix("✓") ? .green : .orange) }
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Test") { Task { await test() } }
                    .disabled(busy || model.isEmpty || (kind.needsKey && apiKey.isEmpty))
                Button("Save") {
                    SecretStore.save(draft.keyAccount, apiKey)
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isEmpty || (kind.needsKey && apiKey.isEmpty))
            }
            .padding()
        }
        .frame(width: 520)
    }

    private func load() async {
        busy = true; defer { busy = false }
        do {
            let list = try await LLMClient.listModels(draft, key: apiKey)
            models = list.isEmpty ? kind.presetModels : list
            if !shownModels.contains(model) { model = shownModels.first ?? model }
            status = "✓ \(list.count) models" + (kind == .openrouter ? " (\(list.filter { $0.hasSuffix(":free") }.count) free)" : "")
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() async {
        busy = true; defer { busy = false }
        let t0 = Date()
        do {
            let reply = try await LLMClient.complete(draft, key: apiKey, system: "Reply with JSON only.",
                                                     user: "Write a two-line rhyming couplet about rain as {\"lyrics\": \"...\"}")
            status = "✓ \(String(format: "%.1f", Date().timeIntervalSince(t0))) s · \(reply.replacingOccurrences(of: "\n", with: " ").prefix(90))"
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Helpers

struct PlaceholderEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 60
    var monospaced = false

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .body.monospaced() : .body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(monospaced ? .body.monospaced() : .body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Single scrolling row of capsule buttons (fixed height: a wrapping layout inside
/// a Form made the row height oscillate with the scrollbar and crashed AppKit).
struct FlowChips: View {
    let items: [String]
    let icon: String?
    let tap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Button { tap(item) } label: {
                        HStack(spacing: 4) {
                            if let icon { Image(systemName: icon).font(.caption2) }
                            Text(item).lineLimit(1)
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 28)
    }
}

func mmss(_ s: Double) -> String {
    guard s.isFinite else { return "0:00" }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}
