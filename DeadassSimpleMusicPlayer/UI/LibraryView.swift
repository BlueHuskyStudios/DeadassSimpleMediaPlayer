//
//  LibraryView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-02.
//

import SwiftUI
import TipKit
import UniformTypeIdentifiers

import CollectionTools
import CrossKitTypes
import SimpleLogging
import Howl



private let minimumRepeatModeCyclesBeforeShowingTip = RepeatMode.allCases.count * 4



/// The sheet behind the Library toolbar button: everything beyond bare playback, in one progressively-disclosed place.
///
/// The main screen stays a dead-simple player; anything queue-, playlist-, or history-shaped lives here instead, so complexity is opt-in — you only ever see it by asking for it.
struct LibraryView: View {
    
    // MARK: External state
    
    /// Bindable because the queue tab mutates the queue directly (reorder, remove) through bindings and callbacks
    @Bindable
    var session: PlayerSession
    
    @Environment(\.dismiss)
    private var dismiss
    
    
    // MARK: Internal state
    
    @State
    private var tab = SelectedTab.queue
    
    @State
    private var isNamingNewPlaylist = false
    
    @State
    private var newPlaylistName = ""
    
    @State
    private var isImportingPlaylist = false
    
    /// Shared by every row which shows cover art, so revisiting a tab doesn't reopen the same files.
    ///
    /// Owned by this sheet rather than by the session: it's a drawing convenience, not part of anyone's durable state, and letting it die with the sheet keeps decoded art from accumulating for a screen nobody's looking at. Rows await it and keep their own copy of the result; nothing reads it from a `body`.
    @State
    private var artworkCache = ArtworkThumbnailCache()
    
    /// A fully-prepared export awaiting the user's choice of destination; non-`nil` is what presents the exporter
    @State
    private var pendingExport: PendingExport? = nil
    
    
    // MARK: Error handling
    
    @State
    private var currentError: ToastError?
    
    
    
    
    
    
    // MARK: Tabs
    
    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                Tab("Now Playing", systemImage: "play.square.stack", value: SelectedTab.queue) {
                    queueTab
                }

                Tab("Playlists", systemImage: "music.note.list", value: SelectedTab.playlists) {
                    playlistsTab
                }
                
                Tab("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", value: SelectedTab.history) {
                    historyTab
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
                
                ToolbarItemGroup() {
                    switch tab {
                    case .queue:
                        shuffleToggle
                        
                        repeatModeMenu
                        
                        EditButton()
                        
                    case .playlists:
                        EmptyView()
                        
                    case .history:
                        retentionMenu
                        
                        ConfirmationGatedButton(
                            "Clear history", systemImage: "trash",
                            confirmationMessage: "Clear all play history?")
                        {
                            session.clearHistory()
                        }
                    }
                }
            }
        }
        
        .toast(error: $currentError)
    }
    
    
    
    /// The sheet's sections. All present from birth so new ones slot in without restructuring.
    enum SelectedTab: Hashable, CaseIterable {
        case queue
        case playlists
        case history
        
        var title: LocalizedStringKey {
            switch self {
            case .queue:     "Queue"
            case .playlists: "Playlists"
            case .history:   "History"
            }
        }
    }
}



// MARK: - Now Playing tab

private extension LibraryView {
    
    private static let repeatModeButtonAnchorId = "LoopButtonAnchor"
    
    
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
                Section {
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
                } header: {
                    TipView(RepeatButtonTip(), arrowEdge: .top, anchorID: Self.repeatModeButtonAnchorId)
                        .listRowBackground(EmptyView())
                } footer: {
                    if session.queue.isShuffled {
                        Text("Shuffling is temporary! You can reorder songs, but they'll be returned to the same unshuffled order when you unshuffle.")
                    }
                }
                .headerProminence(.increased)
                
                Section {
                    ConfirmationGatedButton("Clear queue", confirmationMessage: "Remove everything from the Now Playing queue?") {
                        session.queue.removeAll()
                    }
                } footer: {
                    VStack {
                        Spacer(minLength: 40)
                    }
                }
            }
        }
    }
    
    
    var shuffleToggle: some View {
        Toggle("Shuffle", systemImage: "shuffle", isOn: Binding(
            get: { session.queue.isShuffled },
            set: { shouldShuffle in
                if shouldShuffle {
                    session.queue.shuffle()
                }
                else {
                    session.queue.unshuffle()
                }
            })
        )
        .toggleStyle(.button)
    }
    
    
    var repeatModeMenu: some View {
        Menu {
            Picker("Repeat", selection: Binding(
                get: { session.repeatMode },
                set: { newMode in
                    session.repeatMode = newMode
                    RepeatButtonTip.didOpenRepeatMenu.sendDonation()
                }
            )) {
                ForEach(RepeatMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.systemImageName_menuItem)
                        .tag(mode)
                }
            }
        } label: {
            Image(systemName: session.repeatMode.systemImageName_preview)
                .tipAnchor(Self.repeatModeButtonAnchorId)
                
                // What follows ain't ideal by any means. I wanna style this like a toggle, where it looks like the
                // shuffle button does. However, I tired many possible approaches and none rendered correctly.
                // What follows ain't kosher and should be replaced ASAP, but for now it's the best possible solution I
                // could find.
                //
                // – Ky, 2026-07-14
                .foregroundStyle(
                    { () -> Color in
                        switch session.repeatMode {
                        case .off: Color.primary
                        case .currentItem, .wholeQueue: Color.accentColor
                        }
                    }()
                )
                .font(
                    { () -> Font? in
                        switch session.repeatMode {
                        case .off: nil
                        case .currentItem, .wholeQueue: .title
                        }
                    }()
                )
                .padding(
                    .horizontal,
                    { () -> CGFloat? in
                        switch session.repeatMode {
                        case .off: 6.5
                        case .currentItem, .wholeQueue: 0
                        }
                    }()
                )
        } primaryAction: {
            session.repeatMode.cycleNext()
            RepeatButtonTip.repeatModeCycles.sendDonation()
        }
    }
}



private struct RepeatButtonTip: Tip {
    
    static let repeatModeCycles: Event = Event(id: "repeatModeCycles", donationLimit: .init(maximumCount: minimumRepeatModeCyclesBeforeShowingTip))
    static let didOpenRepeatMenu: Event = Event(id: "didOpenRepeatMenu", donationLimit: .init(maximumCount: 1))
    
    // https://developer.apple.com/forums/thread/740849
    var id: String { "RepeatButtonTip" }
    
    
    var title: Text {
        Text("Press & hold")
    }
    
    var message: Text? {
        Text("""
            You can select a specific loop mode if you
            **press & hold** the \(Image(systemName: "repeat")) loop button
            """
        )
    }
    
    var rules: [Rule] {
        // Compiler error because `minimumRepeatModeCyclesBeforeShowingTip` isn't a literal
//        #Rule(Self.repeatModeCycles, Self.didOpenRepeatMenu) { repeatModeCycles, menuOpens in
//            repeatModeCycles.donations.count >= minimumRepeatModeCyclesBeforeShowingTip
//            && menuOpens.donations.isEmpty
//        }
        
        Tips.Rule(.conjunction, [
            Tips.Rule(Self.repeatModeCycles) { (repeatModeCycles) in
                PredicateExpressions.build_Comparison(
                    lhs: PredicateExpressions.build_KeyPath(
                        root: PredicateExpressions.build_KeyPath(
                            root: PredicateExpressions.build_Arg(repeatModeCycles),
                            keyPath: \.donations
                        ),
                        keyPath: \.count
                    ),
                    rhs: PredicateExpressions.build_Arg(minimumRepeatModeCyclesBeforeShowingTip),
                    op: .greaterThanOrEqual
                )
            },
            Tips.Rule(Self.didOpenRepeatMenu) { (menuOpens) in
                PredicateExpressions.build_Equal(
                    lhs: PredicateExpressions.build_KeyPath(
                        root: PredicateExpressions.build_KeyPath(
                            root: PredicateExpressions.build_Arg(menuOpens),
                            keyPath: \.donations
                        ),
                        keyPath: \.count
                    ),
                    rhs: PredicateExpressions.build_Arg(0)
                )
            }
        ])
    }
}




// MARK: - Playlists tab

private extension LibraryView {
    
    @ViewBuilder
    var playlistsTab: some View {
        List {
            Section {
                Button("Save Now Playing queue as playlist…", systemImage: "plus") {
                    isNamingNewPlaylist = true
                }
                .disabled(session.queue.entries.isEmpty)
                
                Button("Import a playlist…", systemImage: "square.and.arrow.down") {
                    isImportingPlaylist = true
                }
            }
            
            if !session.savedPlaylists.isEmpty {
                Section("Saved") {
                    ForEach(session.savedPlaylists) { playlist in
                        Button {
                            Task {
                                await session.loadIntoQueue(playlist)
                                dismiss() // Their goal (play that playlist) is accomplished; get out of the way
                            }
                        } label: {
                            SavedPlaylistRow(playlist: playlist, artworkCache: artworkCache)
                        }
                        .buttonStyle(.plain)
                        
                        .contextMenu {
                            Button("Export as M3U8", systemImage: "square.and.arrow.up") {
                                do {
                                    try export(playlist, as: .m3uPlaylist)
                                }
                                catch {
                                    currentError = ToastError(
                                        errorDescription: "m3u8 export failed",
                                        cause: error,
                                        systemImage: "square.and.arrow.up.trianglebadge.exclamationmark",
                                    )
                                }
                            }
                            
                            Button("Export as JSON", systemImage: "curlybraces") {
                                do {
                                    try export(playlist, as: .json)
                                }
                                catch {
                                    currentError = ToastError(
                                        errorDescription: "JSON export failed",
                                        cause: error,
                                        systemImage: "square.and.arrow.up.trianglebadge.exclamationmark",
                                    )
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        // IDs gathered before any removal, since each removal shifts the offsets they were gathered from
                        let ids = offsets.map { session.savedPlaylists[$0].id }
                        for id in ids {
                            do {
                                try session.delete(playlistWithID: id)
                            }
                            catch {
                                log(error: "Couldn't delete the saved playlist document “\(id)”: \(error)")
                                
                                currentError = ToastError(
                                    errorDescription: "Playlist not deleted",
                                    cause: error,
                                    systemImage: "trash.slash",
                                )
                            }
                        }
                    }
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
    
    
    /// Renders the playlist into the chosen format and stages it for the exporter sheet
    func export(_ playlist: SavedPlaylist, as contentType: UTType) throws {
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
    
    
    /// Reads a user-picked playlist file (under its security scope) and hands it to the session, routed by format: our JSON round-trips faithfully; M3U8 is a best-effort filename-match against files the app already knows
    func importPlaylist(at url: URL) {
        url.accessSecurityScopedResource { url in
            do {
                let data = try Data(contentsOf: url)
                
                if "json" == url.pathExtension.lowercased() {
                    session.importPlaylist(fromExportedJSON: data)
                }
                else {
                    guard let (_, failedTrackImportCount) = session.importPlaylist(fromM3U8: data, suggestedName: url.deletingPathExtension().lastPathComponent)
                    else {
                        currentError = ToastError(
                            errorDescription: "Import failed.",
                            recoverySuggestion: "Try again",
                            systemImage: "square.and.arrow.down.badge.xmark",
                        )
                        return
                    }
                    
                    if 0 < failedTrackImportCount {
                        currentError = ToastError(
                            errorDescription: "\(failedTrackImportCount) tracks weren't imported.",
                            recoverySuggestion: "You may need to import them separately.",
                        )
                    }
                }
            }
            catch {
                currentError = ToastError(
                    errorDescription: "Import failed",
                    cause: error,
                    systemImage: "square.and.arrow.down.badge.xmark",
                )
                log(error: "Couldn't read that playlist file: \(error)")
            }
        }
        onFailure: {
            currentError = ToastError(
                errorDescription: "Access denied",
                systemImage: "externaldrive.trianglebadge.exclamationmark",
            )
            log(error: "I couldn't get the necessary permissions to read from this URL: \(url)")
        }
    }
    
    
    
    /// A fully-prepared export awaiting the user's choice of destination
    struct PendingExport {
        var document: ExportablePlaylistDocument
        var contentType: UTType
        var defaultFilename: String
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
                            HistoryEntryArtwork(reference: historyEntry.reference, artworkCache: artworkCache)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(historyEntry.displayName)
                                    .lineLimit(1)
                                
                                Text(historyEntry.playedAt, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            TappableSpacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    
    /// Chooses how far back history is kept. Tightening the window prunes immediately.
    var retentionMenu: some View {
        Menu(currentRetentionTitle, systemImage: "timer") {
            Picker("Keep History", selection: Binding(
                get: { session.history.retention },
                set: { session.setHistoryRetention($0) })
            ) {
                ForEach(RetentionPreset.allCases, id: \.self) { preset in
                    Text(preset.title)
                        .tag(preset.retention)
                }
            }
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
            case .forever:           "Keep history forever"
            case .pastDay:           "Delete after a day"
            case .pastWeek:          "Delete after a week"
            case .pastYear:          "Delete after a year"
            case .hundredMostRecent: "Only remember 100 recent plays"
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
        HStack {
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
            
            TappableSpacer()
        }
        .opacity(entry.isPlayable ? 1 : 0.75)
        
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
/// A history row's cover art, or a neutral placeholder holding the same space while (or if) none arrives.
///
/// Always occupies its slot, art or not, so a scrolling list of history entries doesn't jitter as thumbnails resolve.
private struct HistoryEntryArtwork: View {
    
    let reference: MediaReference
    
    let artworkCache: ArtworkThumbnailCache
    
    /// This row's own copy of its art — see ``SavedPlaylistRow/artwork`` for why it's local rather than read from the cache
    @State
    private var artwork: NativeImage? = nil
    
    
    var body: some View {
        Group {
            if let artwork {
                Image(nativeImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(.rect(cornerRadius: 4))
        
        .task {
            artwork = await artworkCache.thumbnail(for: reference)
        }
    }
}



private struct SavedPlaylistRow: View {
    
    let playlist: SavedPlaylist
    
    let artworkCache: ArtworkThumbnailCache
    
    /// This row's own copy of its album art, so the row renders immediately with a placeholder and updates exactly once when art arrives.
    ///
    /// Deliberately local rather than read from the cache inside `body`: reading shared observable state here would subscribe every row to every other row's art, and one album finishing would re-render the whole list.
    @State
    private var artwork: NativeImage? = nil
    
    
    var body: some View {
        HStack {
            artworkOrIcon
                .frame(width: 24, height: 24)
            
            Text(playlist.name)
                .lineLimit(1)
            
            TappableSpacer(minLength: 0)
            
            Text("^[\(playlist.items.count) item](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        
        .task { @ArtworkLoadQueue in
            // Only albums show art; a hand-made playlist has no single cover to speak for it
            switch playlist.kind {
            case .userCreated: return
            case .album: break
            }
            
            let loadedArtowrk = await artworkCache.firstAvailableThumbnail(among: playlist.items)
                
            await MainActor.run {
                self.artwork = loadedArtowrk
            }
        }
    }
    
    
    @ViewBuilder
    private var artworkOrIcon: some View {
        if let artwork {
            Image(nativeImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(.rect(cornerRadius: 3))
        }
        else {
            Image(systemName: iconName)
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
        case .off:         "Don't loop"
        case .wholeQueue:  "Loop all"
        case .currentItem: "Loop one"
        }
    }
    
    
    var systemImageName_menuItem: String {
        switch self {
        case .off:         "forward.end"
        case .wholeQueue:  "repeat"
        case .currentItem: "repeat.1"
        }
    }
    
    
    var systemImageName_preview: String {
        switch self {
        case .off:         "repeat"
        case .wholeQueue:  "repeat.circle.fill"
        case .currentItem: "repeat.1.circle.fill"
        }
    }
}



// MARK: - Previews

#Preview("Populated") {
    LibraryView(session: PlayerSession.demo)
        .onAppear {
            Tips.showAllTipsForTesting()
        }
}

#Preview("Empty") {
    LibraryView(session: PlayerSession(persisting: false))
}
