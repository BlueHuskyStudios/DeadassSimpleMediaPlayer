//
//  LibraryView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-02.
//

import SwiftUI
import UniformTypeIdentifiers

import CollectionTools
import SimpleLogging



/// The sheet behind the Library toolbar button: everything beyond bare playback, in one progressively-disclosed place.
///
/// The main screen stays a dead-simple player; anything queue-, playlist-, or history-shaped lives here instead, so complexity is opt-in — you only ever see it by asking for it.
struct LibraryView: View {
    
    /// Bindable because the queue tab mutates the queue directly (reorder, remove) through bindings and callbacks
    @Bindable
    var session: PlayerSession
    
    @Environment(\.dismiss)
    private var dismiss
    
    @State
    private var tab = SelectedTab.queue
    
    @State
    private var isNamingNewPlaylist = false
    
    @State
    private var newPlaylistName = ""
    
    @State
    private var isImportingPlaylist = false
    
    /// A fully-prepared export awaiting the user's choice of destination; non-`nil` is what presents the exporter
    @State
    private var pendingExport: PendingExport? = nil
    
    
    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                Tab(value: SelectedTab.queue) {
                    queueTab
                } label: {
                    Label("Queue", systemImage: "list.bullet.below.rectangle")
                }

                Tab(value: SelectedTab.playlists) {
                    playlistsTab
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
                
                Tab(value: SelectedTab.albums) {
                    albumsTab
                } label: {
                    Label("Albums", systemImage: "opticaldisc")
                }
                
                Tab(value: SelectedTab.history) {
                    historyTab
                } label: {
                    Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            
            .toolbar {
                
                ToolbarItem(placement: .navigation) {
                    Button("Done", systemImage: "xmark") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    
    
    /// The sheet's sections. All present from birth so new ones slot in without restructuring.
    enum SelectedTab: Hashable, CaseIterable {
        case queue
        case playlists
        case albums
        case history
        
        var title: LocalizedStringKey {
            switch self {
            case .queue:     "Queue"
            case .playlists: "Playlists"
            case .albums:    "Albums"
            case .history:   "History"
            }
        }
    }
}



// MARK: - Queue tab

private extension LibraryView {
    
    /// The now-playing queue, in the order the user is actually hearing it: the shuffled order while shuffled, the user-specified order otherwise
    var orderedEntries: [PlaylistEntry] {
        session.queue.effectiveOrder.compactMap(session.queue.entry(withID:))
    }
    
    
    @ViewBuilder
    var queueTab: some View {
        if session.queue.entries.isEmpty {
            ContentUnavailableView(
                "Nothing queued",
                systemImage: "music.note.list",
                description: Text("Open a file to start playing, or load a playlist"))
        }
        else {
            List {
                ForEach(orderedEntries) { entry in
                    Button {
                        session.play(entryWithID: entry.id) // Harmlessly no-ops for the already-current entry
                    } label: {
                        QueueEntryRow(entry: entry, isCurrent: entry.id == session.queue.currentEntry?.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isPlayable)
                }
                .onMove { source, destination in
                    session.queue.moveEntries(fromEffectiveOffsets: source, toEffectiveOffset: destination)
                }
                .onDelete { offsets in
                    // IDs gathered before any removal, since each removal shifts the offsets they were gathered from
                    let ids = offsets.map { orderedEntries[$0].id }
                    for id in ids {
                        session.queue.remove(entryWithID: id)
                    }
                }
            }
            
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    shuffleToggle
                    
                    Spacer()
                    
                    repeatModeMenu
                    
                    Spacer()
                    
                    ClearQueueButton(session: session)
                    
                    Spacer()
                    
                    EditButton()
                }
            }
        }
    }
    
    
    var shuffleToggle: some View {
        Toggle(isOn: Binding(
            get: { session.queue.isShuffled },
            set: { shouldShuffle in
                if shouldShuffle {
                    session.queue.shuffle()
                }
                else {
                    session.queue.unshuffle()
                }
            })
        ) {
            Label("Shuffle", systemImage: "shuffle")
        }
        .toggleStyle(.button)
    }
    
    
    var repeatModeMenu: some View {
        Menu {
            Picker("Repeat", selection: $session.repeatMode) {
                ForEach(RepeatMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.systemImageName)
                        .tag(mode)
                }
            }
        } label: {
            Label(session.repeatMode.displayName, systemImage: session.repeatMode.systemImageName)
        }
    }
}



// MARK: - Playlists tab

private extension LibraryView {
    
    @ViewBuilder
    var playlistsTab: some View {
        List {
            Section {
                Button {
                    isNamingNewPlaylist = true
                } label: {
                    Label("Save Queue as Playlist…", systemImage: "plus")
                }
                .disabled(session.queue.entries.isEmpty)
                
                Button {
                    isImportingPlaylist = true
                } label: {
                    Label("Import Playlist…", systemImage: "square.and.arrow.down")
                }
            }
            
            let userPlaylists = session.savedPlaylists.filter { .userCreated == $0.kind }
            
            if !userPlaylists.isEmpty {
                Section("Saved") {
                    savedPlaylistRows(userPlaylists)
                }
            }
        }
        
        .alert("Name this playlist", isPresented: $isNamingNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            
            Button("Save") {
                session.saveQueueAsPlaylist(named: newPlaylistName.nonEmptyOrNil ?? "Untitled Playlist")
                newPlaylistName = ""
            }
            
            Button("Cancel", role: .cancel) {
                newPlaylistName = ""
            }
        }
        
        .fileExporter(
            isPresented: Binding(
                get: { nil != pendingExport },
                set: { stillPresented in
                    if !stillPresented {
                        pendingExport = nil
                    }
                }),
            document: pendingExport?.document,
            contentType: pendingExport?.contentType ?? .json,
            defaultFilename: pendingExport?.defaultFilename
        ) { result in
            switch result {
            case .success(let url):
                log(info: "Exported playlist to \(url)")
                
            case .failure(let error):
                log(error: error)
            }
        }
        
        .fileImporter(isPresented: $isImportingPlaylist, allowedContentTypes: [.json, .m3uPlaylist]) { result in
            switch result {
            case .success(let url):
                importPlaylist(at: url)
                
            case .failure(let error):
                log(error: error)
            }
        }
    }
    
    
    /// One tappable/exportable/deletable row per given playlist. Shared between the Playlists and Albums tabs so the two never drift apart in behavior.
    ///
    /// Deletion maps offsets within the *given* (possibly filtered) list — never within `session.savedPlaylists` directly — so filtering can't misdirect a delete.
    @ViewBuilder
    func savedPlaylistRows(_ playlists: [SavedPlaylist]) -> some View {
        ForEach(playlists) { playlist in
            Button {
                Task {
                    await session.loadIntoQueue(playlist)
                    dismiss() // Their goal (play that playlist) is accomplished; get out of the way
                }
            } label: {
                SavedPlaylistRow(playlist: playlist)
            }
            .buttonStyle(.plain)
            
            .contextMenu {
                Button {
                    export(playlist, as: .m3uPlaylist)
                } label: {
                    Label("Export as M3U8", systemImage: "square.and.arrow.up")
                }
                
                Button {
                    export(playlist, as: .json)
                } label: {
                    Label("Export as JSON", systemImage: "curlybraces")
                }
            }
        }
        .onDelete { offsets in
            // IDs gathered before any removal, since each removal shifts the offsets they were gathered from
            let ids = offsets.map { playlists[$0].id }
            for id in ids {
                session.delete(playlistWithID: id)
            }
        }
    }
    
    
    /// Renders the playlist into the chosen format and stages it for the exporter sheet
    func export(_ playlist: SavedPlaylist, as contentType: UTType) {
        do {
            let data: Data = if .json == contentType {
                try playlist.exportedJSONData()
            }
            else {
                playlist.exportedM3U8Data
            }
            
            pendingExport = PendingExport(
                document: ExportablePlaylistDocument(data: data),
                contentType: contentType,
                defaultFilename: playlist.name)
        }
        catch {
            log(error: "Couldn't render “\(playlist.name)” for export: \(error)")
        }
    }
    
    
    /// Reads a user-picked playlist file (under its security scope) and hands it to the session, routed by format: our JSON round-trips faithfully; M3U8 is a best-effort filename-match against files the app already knows
    func importPlaylist(at url: URL) {
        url.accessSecurityScopedResource { url in
            do {
                let data = try Data(contentsOf: url)
                
                if "json" == url.pathExtension.lowercased() {
                    session.importPlaylist(fromExportedJSON: data)
                }
                else {
                    session.importPlaylist(fromM3U8: data, suggestedName: url.deletingPathExtension().lastPathComponent)
                }
            }
            catch {
                log(error: "Couldn't read that playlist file: \(error)")
            }
        }
        onFailure: {
            _ = log(error: "I couldn't get the necessary permissions to read from this URL: \(url)")
        }
    }
    
    
    
    /// A fully-prepared export awaiting the user's choice of destination
    struct PendingExport {
        var document: ExportablePlaylistDocument
        var contentType: UTType
        var defaultFilename: String
    }
}



// MARK: - Albums tab

private extension LibraryView {
    
    @ViewBuilder
    var albumsTab: some View {
        let albums = session.savedPlaylists.filter { .album == $0.kind }
        
        if albums.isEmpty {
            ContentUnavailableView(
                "No albums yet",
                systemImage: "opticaldisc",
                description: Text("Open files that share album metadata, and they'll gather here on their own"))
        }
        else {
            List {
                savedPlaylistRows(albums)
            }
        }
    }
}



// MARK: - History tab

private extension LibraryView {
    
    @ViewBuilder
    var historyTab: some View {
        if session.history.entries.isEmpty {
            ContentUnavailableView(
                "Nothing played yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Go ahead and play something!\nI'll remember in case you want to replay it later.")
            )
        }
        else {
            List {
                ForEach(session.history.entries) { historyEntry in
                    Button {
                        Task {
                            await session.replay(historyEntry)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(historyEntry.displayName)
                                    .lineLimit(1)
                                
                                Text(historyEntry.playedAt, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Rectangle()
                                .fill(Color(.systemGroupedBackground).opacity(0.001))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    retentionMenu
                    
                    Spacer()
                    
                    ClearHistoryButton(session: session)
                }
            }
        }
    }
    
    
    /// Chooses how far back history is kept. Tightening the window prunes immediately.
    var retentionMenu: some View {
        Menu {
            Picker("Keep History", selection: Binding(
                get: { session.history.retention },
                set: { session.setHistoryRetention($0) })
            ) {
                ForEach(RetentionPreset.allCases, id: \.self) { preset in
                    Text(preset.title)
                        .tag(preset.retention)
                }
            }
        } label: {
            Label(currentRetentionTitle, systemImage: "clock.arrow.circlepath")
        }
    }
    
    
    var currentRetentionTitle: LocalizedStringKey {
        RetentionPreset.allCases
            .first { $0.retention == session.history.retention }?
            .title
            ?? "Custom"
    }
    
    
    
    /// The retention choices offered in UI — friendly names over the model's raw dials
    enum RetentionPreset: CaseIterable {
        case forever
        case pastDay
        case pastWeek
        case pastYear
        case hundredMostRecent
        
        
        var retention: PlaybackHistory.Retention {
            switch self {
            case .forever:           .forever
            case .pastDay:           .within(days: 1)
            case .pastWeek:          .within(days: 7)
            case .pastYear:          .within(days: 365)
            case .hundredMostRecent: .mostRecent(count: 100)
            }
        }
        
        
        var title: LocalizedStringKey {
            switch self {
            case .forever:           "Keep Forever"
            case .pastDay:           "Keep Past Day"
            case .pastWeek:          "Keep Past Week"
            case .pastYear:          "Keep Past Year"
            case .hundredMostRecent: "Keep 100 Most Recent"
            }
        }
    }
}



/// The confirmation-gated "Clear Queue" control, in its own type so its dialog state stays local.
///
/// Icon-only in the bar (the queue toolbar is crowded), destructive-tinted, and always one confirmation away from emptying the queue — clearing is cheap to redo, but never so cheap it happens by accident.
private struct ClearQueueButton: View {
    
    let session: PlayerSession
    
    @State
    private var isConfirming = false
    
    
    var body: some View {
        Button("Clear Queue", systemImage: "trash", role: .destructive) {
            isConfirming = true
        }
        .labelStyle(.iconOnly)
        .confirmationDialog("Clear the queue?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Clear Queue", role: .destructive) {
                session.clearQueue()
            }
        } message: {
            Text("This stops playback and empties the queue. Saved playlists and history aren't affected.")
        }
    }
}



/// The confirmation-gated "Clear History" control, in its own type so its dialog state stays local
private struct ClearHistoryButton: View {
    
    let session: PlayerSession
    
    @State
    private var isConfirming = false
    
    
    var body: some View {
        Button("Clear History", role: .destructive) {
            isConfirming = true
        }
        .confirmationDialog("Clear all play history?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                session.clearHistory()
            }
        }
    }
}



// MARK: - Rows

/// One queue slot: a now-playing indicator, the media's best-known name, and (when relevant) why it can't play.
///
/// The name upgrades live: it starts as the filename, then becomes the media's title if/when the metadata search resolves one — driven by the metadata's own update publisher, so rows never poll.
private struct QueueEntryRow: View {
    
    let entry: PlaylistEntry
    
    let isCurrent: Bool
    
    /// The metadata title once one resolves; `nil` falls back to the filename
    @State
    private var resolvedTitle: String? = nil
    
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedTitle ?? entry.reference.displayName)
                    .lineLimit(1)
                
                if !entry.isPlayable {
                    Text("File unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer(minLength: 0)
        }
        .opacity(entry.isPlayable ? 1 : 0.5)
        
        .onAppear(perform: refreshTitle)
        
        .onReceive(entry.mediaItem?.metadata?.onMetadataDidUpdate()) { _ in
            refreshTitle()
        }
    }
    
    
    private func refreshTitle() {
        resolvedTitle = entry.mediaItem?.metadata
            .flatMap { (try? $0.get(.title).value) ?? nil }?
            .nonEmptyOrNil
    }
}



/// One saved playlist: a kind-appropriate icon, its name, and how much is in it
private struct SavedPlaylistRow: View {
    
    let playlist: SavedPlaylist
    
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            
            Text(playlist.name)
                .lineLimit(1)
            
            Spacer(minLength: 0)
            
            Text("^[\(playlist.items.count) item](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    
    private var iconName: String {
        switch playlist.kind {
        case .userCreated: "music.note.list"
        case .album:       "opticaldisc"
        }
    }
}



// MARK: - Sugar

private extension RepeatMode {
    
    var displayName: LocalizedStringKey {
        switch self {
        case .off:         "Don't Repeat"
        case .wholeQueue:  "Repeat All"
        case .currentItem: "Repeat One"
        }
    }
    
    
    var systemImageName: String {
        switch self {
        case .off:         "repeat"
        case .wholeQueue:  "repeat"
        case .currentItem: "repeat.1"
        }
    }
}



// MARK: - Previews

#Preview {
    LibraryView(session: PlayerSession(persisting: false))
}
