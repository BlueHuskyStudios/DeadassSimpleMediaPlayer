//
//  NowPlayingStore.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude Fable 5.1 on 2026-09-06.
//

import Foundation
import Observation

import SimpleLogging



/// The now-playing queue, its playback modes, and the responsibility of keeping them durable — plus the job of telling the ``PlaybackEngine`` what to play.
///
/// A `Store` holds data whose lifecycle is independent of any player: the queue survives relaunch (via ``NowPlayingSnapshot``), and means something before anything's loaded. This store is also the engine's driver: whenever the queue's current entry changes, that entry is loaded into the engine. "Change the current entry" and "load it into the player" are one synchronous step here, which is why there's no parked "play this next" intent anywhere — the old one existed only because the session didn't own the player.
///
/// Persistence is reactive, with cadence matched to the data's nature:
/// - **Structural changes** (queue contents, current entry, modes) schedule a short-debounced snapshot write, via `didSet` — so even mutations arriving through SwiftUI bindings are caught without anyone remembering to save.
/// - **Playback position** updates arrive constantly, so their writes are throttled.
/// - **Moments of user expectation** (pausing, backgrounding) flush immediately via ``saveSnapshotNow()``.
@MainActor
@Observable
public final class NowPlayingStore {
    
    /// The now-playing queue. Mutate freely (including through SwiftUI bindings); persistence reacts automatically, and so does the engine when the current entry changes.
    ///
    /// A current-entry change loads the new entry *paused*. Operations which mean "and play it" (``play(entryWithID:)``, ``loadIntoQueue(_:andPlay:)``, advancing after a file finishes) follow up with ``PlaybackEngine/play()`` themselves. A queue edit which happens to move the current pointer (like removing the current entry) therefore doesn't start playing on its own — same as before this store existed.
    public var queue: Playlist = .empty {
        didSet {
            guard !isRestoring else { return }
            scheduleSnapshotSave(within: Self.structuralSaveDebounce)
            
            let previousItem = oldValue.currentEntry?.mediaItem
            let currentItem = queue.currentEntry?.mediaItem
            if previousItem != currentItem {
                engine.load(currentItem, autoplay: false)
            }
        }
    }
    
    /// What the player should do when the current file finishes. Persisted with the queue snapshot; never written into saved playlists.
    public var repeatMode: RepeatMode = .off {
        didSet {
            guard !isRestoring else { return }
            scheduleSnapshotSave(within: Self.structuralSaveDebounce)
        }
    }
    
    /// The engine this store feeds
    public let engine: PlaybackEngine
    
    
    // MARK: Non-observable internals
    
    /// Where playback currently is in the current entry's file, remembered so snapshots can include it. Only ever meaningful for the current entry.
    @ObservationIgnored
    private var playbackPositionSeconds: Double? = nil
    
    /// `true` only while restored state is being assigned, so `didSet`-driven saves and engine loads don't pointlessly redo what restore is doing explicitly
    @ObservationIgnored
    private var isRestoring = false
    
    @ObservationIgnored
    private var pendingSnapshotSave: Task<Void, Never>? = nil
    
    @ObservationIgnored
    private var pendingSnapshotSaveDeadline: ContinuousClock.Instant? = nil
    
    /// Holds the "Now Playing" document. `nil` means persistence is unavailable and the store runs memory-only.
    private let documentStore: JSONDocumentStore?
    
    
    /// - Parameters:
    ///   - engine:        The engine to load the current entry into
    ///   - documentStore: Where to keep the Now Playing snapshot, or `nil` to run memory-only (like in SwiftUI previews)
    public init(engine: PlaybackEngine, documentStore: JSONDocumentStore?) {
        self.engine = engine
        self.documentStore = documentStore
    }
}



// MARK: - Restoring the previous session

public extension NowPlayingStore {
    
    /// Rebuilds the queue from whatever the previous session left behind, re-resolving every file, and loads the restored current entry into the engine at the restored position — paused, waiting for the user.
    ///
    /// Does nothing if persistence is unavailable or nothing was saved.
    func load() async {
        guard let documentStore else { return }
        
        // All the slow, suspending work happens into locals first; assignment at the bottom is synchronous, so the `isRestoring` gate can't accidentally swallow a save for some unrelated mutation which interleaves with a suspension here
        
        var restoredQueue: Playlist? = nil
        var restoredRepeatMode: RepeatMode? = nil
        var restoredPositionSeconds: Double? = nil
        
        do {
            if let snapshot = try documentStore.load(NowPlayingSnapshot.self, named: Self.nowPlayingDocumentName) {
                restoredQueue = await snapshot.restoredPlaylist()
                restoredRepeatMode = snapshot.repeatMode
                restoredPositionSeconds = snapshot.playbackPositionSeconds
            }
        }
        catch {
            log(error: "The previous session's Now Playing snapshot exists but couldn't be read: \(error)")
        }
        
        
        isRestoring = true
        defer { isRestoring = false }
        
        if let restoredQueue {
            queue = restoredQueue
            playbackPositionSeconds = restoredPositionSeconds
            
            log(info: "Restored the previous session: \(restoredQueue.entries.count) queue entries, playback position \(restoredPositionSeconds.map { "\($0)s" } ?? "unknown")")
            
            // Loaded here rather than by the `queue` observer (gated off during restore), so the restored position can ride along with the load instead of being parked for someone else to claim
            engine.load(restoredQueue.currentEntry?.mediaItem, resumingAt: restoredPositionSeconds, autoplay: false)
        }
        
        if let restoredRepeatMode {
            repeatMode = restoredRepeatMode
        }
    }
}



// MARK: - Playback intent

public extension NowPlayingStore {
    
    /// Jumps the queue to the given entry and plays it.
    ///
    /// No-ops for unplayable entries. For the entry that's already current, just makes sure it's playing.
    func play(entryWithID id: PlaylistEntry.ID) {
        guard queue.entry(withID: id)?.isPlayable ?? false else { return }
        
        queue.currentEntryID = id // Loads it into the engine, paused
        engine.play()
    }
    
    
    /// Re-opens something from history: appends it to the queue (the queue is not disturbed beyond that) and plays it.
    ///
    /// A history entry is only a durable reference, so the file must be re-resolved — which can fail if it's moved or gone. Failure is logged and otherwise silent for now.
    func replay(_ historyEntry: PlaybackHistory.Entry) async {
        guard let item = await MediaItem(resolving: historyEntry.reference) else {
            log(error: "Couldn't reopen “\(historyEntry.displayName)” from history — the file may have moved or been deleted")
            return
        }
        
        let entry = PlaylistEntry(item)
        
        queue.append(entry, allowMovingToNewItem: false)
        queue.currentEntryID = entry.id
        engine.play()
    }
    
    
    /// Replaces the now-playing queue with the given saved playlist's contents, re-resolving every file.
    ///
    /// Files that can't be reached become unavailable slots (visible, skipped by playback) rather than vanishing — the playlist the user sees should be the playlist they saved.
    ///
    /// - Parameters:
    ///   - playlist: The saved playlist to load
    ///   - andPlay:  Whether loading should also start playing (the common reason anyone loads a playlist). Defaults to `true`.
    func loadIntoQueue(_ playlist: SavedPlaylist, andPlay: Bool = true) async {
        var entries: [PlaylistEntry] = []
        entries.reserveCapacity(playlist.items.count)
        
        for reference in playlist.items {
            entries.append(await .resolving(reference))
        }
        
        queue = Playlist(entries: entries)
        
        if andPlay,
           nil != queue.currentEntry?.mediaItem
        {
            engine.play()
        }
    }
    
    
    /// The current file played all the way to its end; what happens next is the repeat mode's call.
    ///
    /// Called by whoever hears the engine finish (``PlayerSession``). Advancing to another entry loads it paused (via the `queue` observer), so playing it is done here explicitly.
    func advanceAfterCurrentItemFinished() {
        switch repeatMode {
        case .currentItem:
            engine.replayFromStart()
            
        case .wholeQueue:
            if nil != queue.moveToNextEntry(wrapping: true) {
                engine.play()
            }
            else {
                // Wrapping with nowhere else to go (the queue's only playable entry is this one) still means "start over"
                engine.replayFromStart()
            }
            
        case .off:
            if nil != queue.moveToNextEntry(wrapping: false) {
                engine.play()
            }
            // Otherwise the queue is finished, and the player rests at the end of the final file
        }
    }
}



// MARK: - Saving

public extension NowPlayingStore {
    
    /// Notes where playback currently is, so session restore can pick up mid-file.
    ///
    /// Called frequently (from the engine's periodic time observer), so the resulting disk writes are throttled rather than immediate — a crash loses at most a few seconds of position, never any structure.
    func notePlaybackPosition(seconds: Double) {
        guard seconds.isFinite,
              seconds >= 0
        else { return }
        
        playbackPositionSeconds = seconds
        scheduleSnapshotSave(within: Self.positionSaveThrottle)
    }
    
    
    /// Writes the now-playing snapshot right now, superseding any scheduled write.
    ///
    /// For the moments a user implicitly expects their state to be safe: pausing, backgrounding, and anywhere else "if the app died right now" would be a reasonable thought.
    func saveSnapshotNow() {
        pendingSnapshotSave?.cancel()
        pendingSnapshotSave = nil
        pendingSnapshotSaveDeadline = nil
        
        guard let documentStore else { return }
        
        do {
            try documentStore.save(
                NowPlayingSnapshot(
                    of: queue,
                    playbackPositionSeconds: playbackPositionSeconds,
                    repeatMode: repeatMode),
                named: Self.nowPlayingDocumentName)
        }
        catch {
            log(error: "Couldn't save the Now Playing snapshot: \(error)")
        }
    }
}



private extension NowPlayingStore {
    
    static let nowPlayingDocumentName = "Now Playing"
    
    /// How long structural changes (queue, modes) wait before hitting disk, coalescing bursts (like a 200-file folder import) into one write
    static let structuralSaveDebounce = Duration.seconds(1)
    
    /// How long position-only changes wait before hitting disk. Position changes constantly during playback; a crash losing a few seconds of position is fine, so this trades staleness for not hammering storage.
    static let positionSaveThrottle = Duration.seconds(5)
    
    
    /// Coalesces save requests: a write already scheduled to happen at least this soon satisfies the request as-is; otherwise the schedule tightens to the sooner deadline. This is what lets rapid structural changes and slow positional ones share one pending write.
    func scheduleSnapshotSave(within delay: Duration) {
        let deadline = ContinuousClock.now + delay
        
        if nil != pendingSnapshotSave,
           let existingDeadline = pendingSnapshotSaveDeadline,
           existingDeadline <= deadline
        {
            return
        }
        
        pendingSnapshotSave?.cancel()
        pendingSnapshotSaveDeadline = deadline
        
        pendingSnapshotSave = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            }
            catch {
                return // Cancelled: a sooner schedule or an immediate save superseded this one
            }
            
            self?.saveSnapshotNow()
        }
    }
}
