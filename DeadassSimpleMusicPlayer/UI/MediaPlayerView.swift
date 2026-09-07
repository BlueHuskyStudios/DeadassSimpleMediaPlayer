//
//  MediaPlayerView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import SwiftUI

import CollectionTools
import SimpleLogging



/// An all-in-one media player for SwiftUI.
///
/// Batteries included: put this in your app, point it at a file, and it plays that file properly — Control Center and Lock Screen controls, Now Playing info, background audio, picture-in-picture, the lot. Or hand it a ``PlayerSession`` you own, and it plays whatever that session's queue is on, with the session's history and library along for the ride.
///
/// The batteries aren't in this view: they're in the session's ``PlaybackEngine``, which this view merely displays. That's what lets this view stay a view — it owns no playback state, so anything else (a pinned metadata header, an always-visible transport bar) can read and drive the very same engine.
struct MediaPlayerView: View {
    
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    
    @Environment(\.verticalSizeClass)
    private var verticalSizeClass
    
    // MARK: API
    
    /// Everything this view shows and controls: the engine whose player is on screen, and the queue that feeds it.
    ///
    /// `@State` rather than `let` so that a session created by ``init(playing:autoplay:)`` survives this struct being re-initialized by its parent. For ``init(session:)`` the initial value is the caller's own object, and the caller keeps owning it.
    @State
    var session: PlayerSession
    
    /// Files the convenience initializers were handed, enqueued on first appearance. Empty for ``init(session:)``.
    private let filesToEnqueue: [URL]
    
    /// Whether to start playing once ``filesToEnqueue`` has been loaded
    private let autoplay: Bool
    
    
    // MARK: Private state
    
    @State
    private var pipStatus = Player.PipStatus.undefined
    
    @State
    private var hasEnqueuedFiles = false
    
    
    /// Plays whatever `session`'s queue is on, and displays it
    /// - Parameter session: Owns the engine this view displays, and everything durable around it
    init(session: PlayerSession) {
        self._session = State(initialValue: session)
        self.filesToEnqueue = []
        self.autoplay = false
    }
    
    
    /// Plays the given files, and displays them. Batteries included, nothing written to disk.
    ///
    /// Builds its own memory-only ``PlayerSession``: remote controls, Now Playing info, and picture-in-picture all work, but no history or library is kept — a host app that only wants a file played shouldn't find this view quietly writing to stores it never asked for. Folders are opened recursively.
    ///
    /// - Parameters:
    ///   - urls:     What to play, in order
    ///   - autoplay: Whether to start playing as soon as the files are loaded. Defaults to `true`.
    init(playing urls: [URL], autoplay: Bool = true) {
        self._session = State(initialValue: PlayerSession(persisting: false))
        self.filesToEnqueue = urls
        self.autoplay = autoplay
    }
    
    
    /// Plays the given file, and displays it. Batteries included, nothing written to disk. See ``init(playing:autoplay:)``.
    init(playing url: URL, autoplay: Bool = true) {
        self.init(playing: [url], autoplay: autoplay)
    }
    
    
    // MARK: `View`
    
    var body: some View {
        VStack {
            playerView
            
            if !useFullscreenUi {
                metadataView
            }
        }
        .background(Color(.secondarySystemBackground))
        .background(ignoresSafeAreaEdges: .all)
        
        
        .task {
            await enqueueFilesIfNeeded()
        }
    }
}



private extension MediaPlayerView {
    
    var engine: PlaybackEngine {
        session.engine
    }
    
    
    var useFullscreenUi: Bool {
        switch (width: horizontalSizeClass, height: verticalSizeClass) {
        case (width: _, height: .none),
            (width: _, height: .regular):
            false
            
        case (width: _, height: .compact):
            true
            
        @unknown default:
            false
        }
    }
    
    
    /// The convenience initializers' payload, loaded exactly once per view lifetime
    func enqueueFilesIfNeeded() async {
        guard !hasEnqueuedFiles,
              filesToEnqueue.isNotEmpty
        else { return }
        hasEnqueuedFiles = true
        
        var entries: [PlaylistEntry] = []
        
        for url in filesToEnqueue {
            entries.append(contentsOf: await Playlist.entries(fromUrl: url, allowRecursion: true))
        }
        
        session.nowPlaying.queue.append(contentsOf: entries)
        
        if autoplay {
            engine.play()
        }
    }
}



// MARK: - Subviews

private extension MediaPlayerView {
    
    var metadataView: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleView
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(.primary) // not strictly necessary, but I wanted to explicitly call out the relationship to the next Text down
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
//                .border(.red)
            
            Text(creatorText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize()
//                .border(.red)
            
            Spacer(minLength: 0)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
//        .border(.blue)
    }
    
    
    var playerView: some View {
        Player(player: engine.player, artwork: engine.artwork, pipStatus: $pipStatus)
            .aspectRatio(16/9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .layoutPriority(2)
            .ignoresSafeArea(.container, edges: useFullscreenUi ? .top : [])
    }
}



// MARK: - Metadata

private extension MediaPlayerView {
    
    @ViewBuilder
    var titleView: some View {
        if let loadingMessage = session.loadingMessage {
            HStack {
                ProgressView()
                Text(LocalizedStringKey(loadingMessage.key))
                    .foregroundStyle(.secondary)
            }
        }
        else {
            Text({
                switch engine.metadata(.title) {
                case .none: nil == engine.currentItem ? "Pick something to play :3" : ""
                case .notStarted: "…"
                case .loading: "⋯"
                case .success(let value): "\(value)"
                case .failure(_): // If we ever add more possible error cases than NotFound, this needs updating
                    (engine.currentItem?.autoAccessSecurityScopedResourceUrl.deletingPathExtension().lastPathComponent.nonEmptyOrNil).map { "\($0)" } ?? "Untitled"
                }
            }())
        }
    }
    
    
    var creatorText: LocalizedStringKey {
        guard nil == session.loadingMessage else { return "" }
        
        return switch engine.metadata(.creator) {
        case .none: ""
        case .notStarted: "⋯"
        case .loading: "…"
        case .success(let value): "\(value)"
        case .failure(_): ""
        }
    }
}



// MARK: - Previews

#Preview("Nothing playing") {
    NavigationStack {
        MediaPlayerView(session: PlayerSession(persisting: false))
    }
}
