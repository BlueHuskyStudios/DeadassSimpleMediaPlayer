//
//  PlayerSession.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation
import Observation

import CollectionTools
import SimpleLogging



/// The long-lived heart of playback, and the one object a view needs to hold.
///
/// This is a thin facade composing four parts, each of which a developer can reach for directly when that's the thing they need:
/// - ``engine`` — ``PlaybackEngine``: the live machinery for playing one item well. Owns the `AVPlayer`; knows nothing of queues. Exists only while something's loaded, persists nothing.
/// - ``nowPlaying`` — ``NowPlayingStore``: the queue and repeat mode, kept durable, and the engine's driver.
/// - ``history`` — ``HistoryStore``: what's been played, kept durable.
/// - ``library`` — ``PlaylistLibraryStore``: the saved playlists, kept durable.
///
/// The rule for what's where: if it's a `Store`, it's data with a lifecycle independent of any player, and it persists itself; if it's the `Engine`, it's live machinery that exists only while something is loaded, and it persists nothing.
///
/// What remains here is only what needs more than one part at once: session restore, the moments when playback events become history, saving the queue as a playlist and loading one back, and the app-wide loading message. The session is also the engine's delegate, so it's where "a file finished" turns into "advance the queue" and "a file has played enough" turns into "record it".
@MainActor
@Observable
public final class PlayerSession {
    
    /// A human-readable description of whatever's currently loading (restoring last session, importing a folder, ...), or `nil` when nothing is.
    ///
    /// Shared infrastructure: any long-running operation that should keep the "what's playing" screen from showing its empty state prematurely runs through ``withLoadingMessage(_:perform:)`` instead of setting this directly, so overlapping operations can't stomp on each other's message.
    public private(set) var loadingMessage: LocalizedStringResource? = nil
    
    /// The live machinery for playing whatever's current
    public let engine: PlaybackEngine
    
    /// The queue and its playback modes
    public let nowPlaying: NowPlayingStore
    
    /// What's been played
    public let history: HistoryStore
    
    /// The saved playlists
    public let library: PlaylistLibraryStore
    
    
    // MARK: Non-observable internals
    
    /// Which entry most recently earned a history recording, so arriving at the same entry only records once no matter how many times the threshold is reported
    @ObservationIgnored
    private var historyRecordedEntryID: PlaylistEntry.ID? = nil
    
    @ObservationIgnored
    private var hasRestored = false
    
    
    /// - Parameter persisting: Pass `false` in contexts where touching real on-disk state would be wrong (like SwiftUI previews, or a host app embedding ``MediaPlayerView`` for a single file). Defaults to `true`.
    public init(persisting: Bool = true) {
        var playerStore: JSONDocumentStore? = nil
        var playlistsStore: JSONDocumentStore? = nil
        
        if persisting {
            do {
                playerStore = try JSONDocumentStore(subfolder: "Player")
                playlistsStore = try JSONDocumentStore(subfolder: "Playlists")
            }
            catch {
                log(error: "Persistence is unavailable, so this session will run memory-only: \(error)")
                playerStore = nil
                playlistsStore = nil
            }
        }
        
        let engine = PlaybackEngine()
        self.engine = engine
        self.nowPlaying = NowPlayingStore(engine: engine, documentStore: playerStore)
        self.history = HistoryStore(documentStore: playerStore)
        self.library = PlaylistLibraryStore(documentStore: playlistsStore)
        
        engine.delegate = self
    }
}



// MARK: - Restoring the previous session

public extension PlayerSession {
    
    /// Rebuilds this session from whatever the previous one left behind: the queue (re-resolving every file), the play position, the repeat mode, the history, and all saved playlists.
    ///
    /// Safe to call any number of times; only the first call does anything.
    func loadIfNeeded() async {
        guard !hasRestored else { return }
        hasRestored = true
        
        loadingMessage = [
            // By people:
            "Reticulating splines…",
            "Gimme sec…",
            "Hang on…",
            "Uhhhhhhhh…",
            "Where did I leave the music…",
            "Where did I leave the movies…",
            "Where did I leave the shoes…",
            "Where did I leave the videos…",
            "Where did I leave the files…",
            "…",
            "Lemme get uhhhhh…",
            "𝔗𝔥𝔢…",
            "Preparing to load…",
            "Loading…",
            "Loading preparation…",
            "Hacking the planet…",
            "Curing cancer real quick…",
            "🥕…",
            "Wiping fingerprints off CD…",
            "Tuning stereo…",
            "Adjusting tracking…",
            "Flipping to Side B…",
            "Renoising…",
            "I'll be there in a sec…",
            "When was it due…",
            "Dusting records…",
            "Loading vocoder?…",
            "?…",
            "Honey, where are my pants…",
            "Daisy, Daisy…",
            "Recalculating route…",
            "Recalcitrating splines…",
            "Spilling popcorn…",
            "Blowing in cartridge…",
            "ignoring The Cloud…",
            "Waxing cylinders…",
            "Waxing poetic…",
            "I'll have two #9s…",
            "Animating hills…",
            "Pirating music…",
            "Pirating movies…",
            "Pirating shoes…",
            "Pirating anime…",
            "Pirating \"anime\"…",
            "Pirating Weird Al's \"Don't Download This Song\"…",
            "Pirating K-Pop…",
            "Pirating A-Pop…",
            "Loading slower…",
            "Loading faster…",
            "Normalizing oddities…",
            "Deciding what to display next…",
            "Loading loading messages…",
            "Messaging loading message loader…",
            "Counting songs…",
            "Discounting songs…",
            "Bypassing…",
            "Ranking music…",
            "Calling a librarian…",
            "Drawing a furry…",
            "Inventing genres…",
            "Pretending…",
            "Hear me out…",
            "Gesticulating mimes…",
            "[Loading, in Spanish…]",
            "Stirring genetic pool…",
            "Confounding an AI…",
            "Low ding…",
            "Obfuscating quigly matrix…",
            "Finishing random walk…",
            "Activating god mode…",
            "Becoming dumber…",
            "Searching for llamas…",
            "Looking for remote…",
            "Playing infrasound…",
            "Playing God…",
            "Playing Dog…",
            "Learning about filetypes…",
            "Losing keys…",
            "Defying gravity…",
            "Almost done…",
            "Almost Dunn…",
            "Lemme just scootch past ya…",
            "Eating cookies…",
            "Untangling AirPods…",
            "Sorting randomness…",
            "Switching…",
            "Dissociating…",
            "Integrating…",
            
            // By Claude:
            "Consulting elders…",
            "Downloading more RAM…",
            "Untangling headphones…",
            "Rolling for initiative…",
            "Doing crimes…",
            "Touching grass…",
            "Turning it off and on again…",
        ].randomElement() ?? "Loading..."
        defer { loadingMessage = nil }
        
        await nowPlaying.load()
        history.load()
        library.load()
    }
}



// MARK: - Loading indication

public extension PlayerSession {
    
    /// Runs `work` while ``loadingMessage`` reports `message`, restoring whatever ``loadingMessage`` was before (not necessarily `nil`) once `work` finishes.
    /// 
    /// The "restore the previous value" behavior (rather than unconditionally clearing) is what lets two loading operations overlap without one's completion silently erasing the other's still-in-progress message — e.g. a folder import that finishes quickly while session restore is still running.
    ///
    /// - Parameters:
    ///   - message: Shown to the user until `work`returns
    ///   - work:    Work to perform while the given loading messsage is on-screen
    ///
    /// - Returns: Whatever `work` returns
    func withLoadingMessage<T>(_ message: LocalizedStringResource, perform work: () async -> T) async -> T {
        let previousMessage = loadingMessage
        loadingMessage = message
        defer { loadingMessage = previousMessage }
        return await work()
    }
}



// MARK: - Playback events

extension PlayerSession: PlaybackEngineDelegate {
    
    /// How much of a file must play before it earns a place in history. Files shorter than this always earn their place by finishing.
    public static let historyThresholdSeconds = 1.0
    
    
    public func playbackEngine(_ engine: PlaybackEngine, playbackPositionDidChangeTo seconds: TimeInterval) {
        nowPlaying.notePlaybackPosition(seconds: seconds)
        
        if seconds >= Self.historyThresholdSeconds {
            recordCurrentEntryInHistoryIfNeeded()
        }
    }
    
    
    /// Also the safety net for the history threshold: a file too short to ever cross ``historyThresholdSeconds`` earns its history place by finishing instead.
    public func playbackEngine(_ engine: PlaybackEngine, didFinishPlaying item: MediaItem) {
        recordCurrentEntryInHistoryIfNeeded()
        nowPlaying.advanceAfterCurrentItemFinished()
    }
    
    
    /// Pausing is a moment the user implicitly expects their place to be remembered
    public func playbackEngineDidPause(_ engine: PlaybackEngine) {
        nowPlaying.saveSnapshotNow()
    }
    
    
    /// Puts the current entry into history — once per arrival at that entry, no matter how many times this is called.
    ///
    /// Callers decide when "played enough" has happened (crossing ``historyThresholdSeconds``, or finishing a file too short to cross it); this method makes repeated and overlapping reports harmless so those callers can stay naive.
    private func recordCurrentEntryInHistoryIfNeeded() {
        guard let entry = nowPlaying.queue.currentEntry,
              historyRecordedEntryID != entry.id
        else { return }
        
        historyRecordedEntryID = entry.id
        history.record(entry.reference, displayName: displayName(for: entry))
    }
}



// MARK: - Between the queue and the library

public extension PlayerSession {
    
    /// Saves the queue's user-specified order as a new named playlist
    @discardableResult
    func saveQueueAsPlaylist(named name: String) -> SavedPlaylist {
        let playlist = SavedPlaylist(name: name, savingQueue: nowPlaying.queue)
        library.upsert(playlist)
        return playlist
    }
    
    
    /// Imports an M3U/M3U8 playlist, best-effort, matching its entries against every file this session knows: saved playlists, the queue, and play history. See ``PlaylistLibraryStore/importPlaylist(fromM3U8:suggestedName:matchingAgainst:)``.
    ///
    /// - Parameters:
    ///   - data:          The playlist file's contents
    ///   - suggestedName: What to call the import — typically the file's own name
    ///
    /// - Returns: A saved playlist and the number of failed track-imports, or `nil` if the given data is an invalid playlist
    func importPlaylist(fromM3U8 data: Data, suggestedName: String) -> (SavedPlaylist, failedTrackImportCount: Int)? {
        library.importPlaylist(fromM3U8: data, suggestedName: suggestedName, matchingAgainst: allKnownReferencesByFilename())
    }
}



private extension PlayerSession {
    
    /// What to call an entry in history: the media's title when metadata has resolved by now, its filename otherwise
    func displayName(for entry: PlaylistEntry) -> String {
        if let metadata = entry.mediaItem?.metadata,
           let foundTitle = (try? metadata.get(.title).value) ?? nil,
           let title = foundTitle.nonEmptyOrNil
        {
            return title
        }
        
        return entry.reference.displayName
    }
    
    
    /// Every file this app knows a durable way back to, indexed by filename — the matching pool for best-effort M3U8 import.
    ///
    /// Later sources win filename collisions, ordered so the freshest wins: history, then saved playlists, then the live queue.
    func allKnownReferencesByFilename() -> [String: MediaReference] {
        var known: [String: MediaReference] = [:]
        
        let allReferences = history.entries.map(\.reference)
            + library.savedPlaylists.flatMap(\.items)
            + nowPlaying.queue.entries.map(\.reference)
        
        for reference in allReferences {
            known[reference.filename] = reference
        }
        
        return known
    }
}
