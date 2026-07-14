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



/// The long-lived heart of playback: the now-playing queue, its playback modes, the play history, the saved playlists — and the responsibility of keeping all of that durable.
///
/// The division of labor: views own the `AVPlayer` and its mechanics (observers, seeking, resuming); this session owns policy and state. Views report playback events here; this type decides what those events mean and makes sure nothing is lost when the app dies.
///
/// Persistence is reactive, with cadence matched to the data's nature:
/// - **Structural changes** (queue contents, current entry, modes) schedule a short-debounced snapshot write, via `didSet` — so even mutations arriving through SwiftUI bindings are caught without anyone remembering to save.
/// - **Playback position** updates arrive constantly, so their writes are throttled.
/// - **Rare events** (history recordings, playlist edits) write immediately.
/// - **Moments of user expectation** (pausing, backgrounding) flush immediately via ``saveNowPlayingSnapshotNow()``.
@MainActor
@Observable
public final class PlayerSession {
    
    /// The now-playing queue. Mutate freely (including through SwiftUI bindings); persistence reacts automatically.
    public var queue: Playlist = .empty {
        didSet {
            guard !isRestoring else { return }
            scheduleNowPlayingSnapshotSave(within: Self.structuralSaveDebounce)
        }
    }
    
    /// What the player should do when the current file finishes. Persisted with the queue snapshot; never written into saved playlists.
    public var repeatMode: RepeatMode = .off {
        didSet {
            guard !isRestoring else { return }
            scheduleNowPlayingSnapshotSave(within: Self.structuralSaveDebounce)
        }
    }
    
    /// What's been played. Read-only from outside; mutations go through session methods (like ``recordCurrentEntryInHistoryIfNeeded()``) so each one lands on disk the moment it happens.
    public private(set) var history = PlaybackHistory()
    
    /// Every saved playlist, sorted by name. Read-only from outside; mutations go through session methods (like ``upsert(_:)``) so memory and disk never disagree.
    public private(set) var savedPlaylists: [SavedPlaylist] = []
    
    
    // MARK: Non-observable internals
    
    /// Where playback currently is in the current entry's file, remembered so snapshots can include it. Only ever meaningful for the current entry.
    @ObservationIgnored
    private var playbackPositionSeconds: Double? = nil
    
    /// The seek the previous session left for us, waiting to be claimed by whoever loads that entry into a player. See ``takePendingRestoredSeek(forEntryWithID:)``.
    @ObservationIgnored
    private var pendingRestoredSeek: (entryID: PlaylistEntry.ID, seconds: Double)? = nil
    
    /// Which entry most recently earned a history recording, so arriving at the same entry only records once no matter how many times the threshold is reported
    @ObservationIgnored
    private var historyRecordedEntryID: PlaylistEntry.ID? = nil
    
    /// Whether whatever loads next should begin playing immediately. See ``requestPlaybackOnNextLoad()``.
    @ObservationIgnored
    private var pendingPlaybackIntent = false
    
    @ObservationIgnored
    private var hasRestored = false
    
    /// `true` only while restored state is being assigned, so `didSet`-driven saves don't pointlessly write back what was just read
    @ObservationIgnored
    private var isRestoring = false
    
    @ObservationIgnored
    private var pendingSnapshotSave: Task<Void, Never>? = nil
    
    @ObservationIgnored
    private var pendingSnapshotSaveDeadline: ContinuousClock.Instant? = nil
    
    /// Holds "Now Playing" and "History" documents. `nil` means persistence is unavailable and the session runs memory-only.
    private let playerStore: JSONDocumentStore?
    
    /// Holds one document per saved playlist, named by the playlist's ID. `nil` means persistence is unavailable and the session runs memory-only.
    private let playlistsStore: JSONDocumentStore?
    
    
    /// - Parameter persisting: Pass `false` in contexts where touching real on-disk state would be wrong (like SwiftUI previews). Defaults to `true`.
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
        
        self.playerStore = playerStore
        self.playlistsStore = playlistsStore
    }
}



// MARK: - Restoring the previous session

public extension PlayerSession {
    
    /// Rebuilds this session from whatever the previous one left behind: the queue (re-resolving every file), the play position, the repeat mode, the history, and all saved playlists.
    ///
    /// Safe to call any number of times; only the first call does anything. The restored play position isn't applied here — the session doesn't own a player — it's held for the player-owning view to claim via ``takePendingRestoredSeek(forEntryWithID:)``.
    func loadIfNeeded() async {
        guard !hasRestored else { return }
        hasRestored = true
        
        guard let playerStore else { return }
        
        // All the slow, suspending work happens into locals first; assignment at the bottom is synchronous, so the `isRestoring` gate can't accidentally swallow a save for some unrelated mutation which interleaves with a suspension here
        
        var restoredQueue: Playlist? = nil
        var restoredRepeatMode: RepeatMode? = nil
        var restoredPositionSeconds: Double? = nil
        
        do {
            if let snapshot = try playerStore.load(NowPlayingSnapshot.self, named: Self.nowPlayingDocumentName) {
                restoredQueue = await snapshot.restoredPlaylist()
                restoredRepeatMode = snapshot.repeatMode
                restoredPositionSeconds = snapshot.playbackPositionSeconds
            }
        }
        catch {
            log(error: "The previous session's Now Playing snapshot exists but couldn't be read: \(error)")
        }
        
        var restoredHistory: PlaybackHistory? = nil
        
        do {
            restoredHistory = try playerStore.load(PlaybackHistory.self, named: Self.historyDocumentName)
        }
        catch {
            log(error: "The play history document exists but couldn't be read: \(error)")
        }
        
        let restoredPlaylists = loadAllSavedPlaylists()
        
        
        isRestoring = true
        defer { isRestoring = false }
        
        if let restoredQueue {
            queue = restoredQueue
            playbackPositionSeconds = restoredPositionSeconds
            
            pendingRestoredSeek = restoredQueue.currentEntry.flatMap { entry in
                restoredPositionSeconds.map { (entryID: entry.id, seconds: $0) }
            }
            
            log(info: "Restored the previous session: \(restoredQueue.entries.count) queue entries, playback position \(restoredPositionSeconds.map { "\($0)s" } ?? "unknown")")
        }
        
        if let restoredRepeatMode {
            repeatMode = restoredRepeatMode
        }
        
        if let restoredHistory {
            history = restoredHistory
            history.applyRetention() // Time marched on while the app was closed
        }
        
        savedPlaylists = restoredPlaylists
    }
    
    
    /// Claims the playback position the previous session left off at — but only for the entry it belongs to.
    ///
    /// One-shot on purpose: whatever loads first after restore settles the question. If that load is the restored entry, it gets its seek; if the user raced the restore by opening something new, the stale seek is discarded rather than misapplied to the wrong file.
    ///
    /// - Parameter id: The entry the caller is about to load into a player
    /// - Returns: Where to seek to, or `nil` if no restored position is waiting for that entry
    func takePendingRestoredSeek(forEntryWithID id: PlaylistEntry.ID?) -> Double? {
        guard let pending = pendingRestoredSeek else { return nil }
        pendingRestoredSeek = nil
        
        guard pending.entryID == id else {
            log(info: "Discarding the restored playback position: it belonged to a different entry than the one now loading")
            return nil
        }
        
        return pending.seconds
    }
}



// MARK: - Playback events

public extension PlayerSession {
    
    /// How much of a file must play before it earns a place in history. Files shorter than this always earn their place by finishing.
    static let historyThresholdSeconds = 1.0
    
    
    /// Notes where playback currently is, so session restore can pick up mid-file.
    ///
    /// Called frequently (from the player's periodic time observer), so the resulting disk writes are throttled rather than immediate — a crash loses at most a few seconds of position, never any structure.
    func notePlaybackPosition(seconds: Double) {
        guard seconds.isFinite,
              seconds >= 0
        else { return }
        
        playbackPositionSeconds = seconds
        scheduleNowPlayingSnapshotSave(within: Self.positionSaveThrottle)
    }
    
    
    /// Puts the current entry into history — once per arrival at that entry, no matter how many times this is called.
    ///
    /// Callers decide when "played enough" has happened (crossing ``historyThresholdSeconds``, or finishing a file too short to cross it); this method makes repeated and overlapping reports harmless so those callers can stay naive.
    func recordCurrentEntryInHistoryIfNeeded() {
        guard let entry = queue.currentEntry,
              historyRecordedEntryID != entry.id
        else { return }
        
        historyRecordedEntryID = entry.id
        history.record(entry.reference, displayName: displayName(for: entry))
        saveHistoryNow()
    }
}



// MARK: - Playback intent

public extension PlayerSession {
    
    /// Declares that whatever media loads next should begin playing immediately.
    ///
    /// "Change the current entry" and "load it into a player" are separated by a SwiftUI state round-trip, and the session doesn't own the player — so intent to keep playing is parked here by whoever changes the entry (queue advance on finish, tap-to-jump, loading a playlist) and claimed by whoever performs the load, via ``takePlaybackIntent()``.
    func requestPlaybackOnNextLoad() {
        pendingPlaybackIntent = true
    }
    
    
    /// Claims any pending intent to play. One-shot: claiming it clears it, so a load without intent stays paused.
    func takePlaybackIntent() -> Bool {
        defer { pendingPlaybackIntent = false }
        return pendingPlaybackIntent
    }
    
    
    /// Jumps the queue to the given entry with intent to play it.
    ///
    /// No-ops for unplayable entries, and for the entry that's already current — the latter because no load would follow, which would strand the intent to be claimed by some unrelated later load.
    func play(entryWithID id: PlaylistEntry.ID) {
        guard id != queue.currentEntry?.id,
              queue.entry(withID: id)?.isPlayable ?? false
        else { return }
        
        requestPlaybackOnNextLoad()
        queue.currentEntryID = id
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
        
        requestPlaybackOnNextLoad()
        queue.append(entry, allowMovingToNewItem: false)
        queue.currentEntryID = entry.id
    }
}



// MARK: - History management

public extension PlayerSession {
    
    /// Changes how far back history is kept, immediately discarding anything the new setting excludes
    func setHistoryRetention(_ retention: PlaybackHistory.Retention) {
        history.retention = retention
        history.applyRetention()
        saveHistoryNow()
    }
    
    
    /// Empties the history entirely
    func clearHistory() {
        history.clear()
        saveHistoryNow()
    }
}



// MARK: - Saved playlists

public extension PlayerSession {
    
    /// Saves the queue's user-specified order as a new named playlist
    @discardableResult
    func saveQueueAsPlaylist(named name: String) -> SavedPlaylist {
        let playlist = SavedPlaylist(name: name, savingQueue: queue)
        upsert(playlist)
        return playlist
    }
    
    
    /// Adds a new saved playlist, or updates the existing one with the same ID — in memory and on disk together, so the two never disagree
    func upsert(_ playlist: SavedPlaylist) {
        if let existingIndex = savedPlaylists.firstIndex(where: { playlist.id == $0.id }) {
            savedPlaylists[existingIndex] = playlist
        }
        else {
            savedPlaylists.append(playlist)
        }
        
        savedPlaylists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        guard let playlistsStore else { return }
        
        do {
            try playlistsStore.save(playlist, named: playlist.id.uuidString)
        }
        catch {
            log(error: "Couldn't save the playlist “\(playlist.name)”: \(error)")
        }
    }
    
    
    /// Removes a saved playlist — from memory and disk together, so the two never disagree
    func delete(playlistWithID id: SavedPlaylist.ID) {
        savedPlaylists.removeAll { id == $0.id }
        
        guard let playlistsStore else { return }
        
        do {
            try playlistsStore.delete(documentNamed: id.uuidString)
        }
        catch {
            log(error: "Couldn't delete the saved playlist document “\(id)”: \(error)")
        }
    }
    
    
    /// Imports a playlist previously exported as this app's raw JSON.
    ///
    /// The import receives a fresh identity, so importing can never silently overwrite an existing playlist that happens to share its ID (like re-importing your own export). Bookmark data survives the JSON round-trip, so on the same device an imported playlist's files usually resolve immediately.
    @discardableResult
    func importPlaylist(fromExportedJSON data: Data) -> SavedPlaylist? {
        do {
            var playlist = try JSONDecoder().decode(SavedPlaylist.self, from: data)
            playlist.id = UUID()
            
            upsert(playlist)
            return playlist
        }
        catch {
            log(error: "Couldn't import that file as a playlist: \(error)")
            return nil
        }
    }
    
    
    /// Imports an M3U/M3U8 playlist, best-effort.
    ///
    /// Sandboxing means bare filenames can't grant access to files this app has never been handed — so each entry is matched, by filename, against every file the app *already* knows (saved playlists, the queue, play history). Matches become the imported playlist; strangers are counted and skipped, with the outcome logged. Perfect-someday: prompting the user to locate unmatched files.
    ///
    /// - Parameters:
    ///   - data:          The playlist file's contents
    ///   - suggestedName: What to call the import — typically the file's own name
    ///
    /// - Returns: A saved playlist, or `nil` if the given data is an invalid playlist
    @discardableResult
    func importPlaylist(fromM3U8 data: Data, suggestedName: String) -> SavedPlaylist? {
        guard let text = String(data: data, encoding: .utf8) else {
            log(error: "That M3U8 file isn't UTF-8 text, so I can't read it")
            return nil
        }
        
        // The M3U format: one entry per line; lines starting with # are directives/comments, everything else names media
        let entryLines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        
        guard !entryLines.isEmpty else {
            log(error: "No entries found in that M3U8 file")
            return nil
        }
        
        let knownReferences = allKnownReferencesByFilename()
        
        let matchedItems = entryLines.compactMap { line -> MediaReference? in
            // Tolerate other apps' path-style entries by matching on just the final component
            let bareFilename = line
                .split(whereSeparator: { "/" == $0 || "\\" == $0 })
                .last
                .map(String.init)
                ?? line
            
            return knownReferences[bareFilename]
        }
        
        guard !matchedItems.isEmpty else {
            log(error: "None of the \(entryLines.count) entries in that M3U8 matched a file this app has been granted access to, so there's nothing to import. (An M3U8 can only re-assemble files you've already opened here.)")
            return nil
        }
        
        if matchedItems.count < entryLines.count {
            log(warning: "Imported \(matchedItems.count) of \(entryLines.count) M3U8 entries; the rest named files this app has never been granted access to")
        }
        
        let playlist = SavedPlaylist(name: suggestedName, items: matchedItems)
        upsert(playlist)
        return playlist
    }
    
    
    /// Groups freshly-imported entries into album playlists, by their album metadata.
    ///
    /// Files sharing an album name — two or more of them, so a lone single isn't an "album" — become a `SavedPlaylist` of kind `.album` named after it, or merge into the existing one. Awaits each file's metadata search, so call this *after* the entries are already appended and playing; grouping is a quiet background courtesy, never a gate.
    ///
    /// Merging dedups by filename (bookmark data isn't byte-stable for the same file, so it can't be the identity here) — re-importing an album doesn't double its tracks. Track order is import order for now; sorting by track-number metadata is a future refinement.
    func autoGroupAlbums(from entries: [PlaylistEntry]) async {
        var albumNamesInImportOrder: [String] = []
        var referencesByAlbum: [String: [MediaReference]] = [:]
        
        for entry in entries {
            guard let metadata = entry.mediaItem?.metadata,
                  let albumName = ((try? await metadata.get(.album)) ?? nil)?.nonEmptyOrNil
            else { continue }
            
            if nil == referencesByAlbum[albumName] {
                albumNamesInImportOrder.append(albumName)
            }
            
            referencesByAlbum[albumName, default: []].append(entry.reference)
        }
        
        for albumName in albumNamesInImportOrder {
            guard let references = referencesByAlbum[albumName],
                  references.count >= 2
            else { continue }
            
            if var existingAlbum = savedPlaylists.first(where: { .album == $0.kind && albumName == $0.name }) {
                let existingFilenames = Set(existingAlbum.items.map(\.filename))
                let genuinelyNewItems = references.filter { !existingFilenames.contains($0.filename) }
                
                guard !genuinelyNewItems.isEmpty else { continue }
                
                existingAlbum.items.append(contentsOf: genuinelyNewItems)
                upsert(existingAlbum)
                log(info: "Merged \(genuinelyNewItems.count) new track(s) into the album “\(albumName)”")
            }
            else {
                upsert(SavedPlaylist(name: albumName, kind: .album, items: references))
                log(info: "Auto-grouped \(references.count) tracks into a new album: “\(albumName)”")
            }
        }
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
        
        if andPlay,
           entries.contains(where: \.isPlayable)
        {
            requestPlaybackOnNextLoad() // Before the queue assignment below, which is what triggers the load that claims this
        }
        
        queue = Playlist(entries: entries)
    }
}



// MARK: - Saving

public extension PlayerSession {
    
    /// Writes the now-playing snapshot right now, superseding any scheduled write.
    ///
    /// For the moments a user implicitly expects their state to be safe: pausing, backgrounding, and anywhere else "if the app died right now" would be a reasonable thought.
    func saveNowPlayingSnapshotNow() {
        pendingSnapshotSave?.cancel()
        pendingSnapshotSave = nil
        pendingSnapshotSaveDeadline = nil
        
        guard let playerStore else { return }
        
        do {
            try playerStore.save(
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



private extension PlayerSession {
    
    static let nowPlayingDocumentName = "Now Playing"
    static let historyDocumentName = "History"
    
    /// How long structural changes (queue, modes) wait before hitting disk, coalescing bursts (like a 200-file folder import) into one write
    static let structuralSaveDebounce = Duration.seconds(1)
    
    /// How long position-only changes wait before hitting disk. Position changes constantly during playback; a crash losing a few seconds of position is fine, so this trades staleness for not hammering storage.
    static let positionSaveThrottle = Duration.seconds(5)
    
    
    /// Coalesces save requests: a write already scheduled to happen at least this soon satisfies the request as-is; otherwise the schedule tightens to the sooner deadline. This is what lets rapid structural changes and slow positional ones share one pending write.
    func scheduleNowPlayingSnapshotSave(within delay: Duration) {
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
            
            self?.saveNowPlayingSnapshotNow()
        }
    }
    
    
    func saveHistoryNow() {
        guard let playerStore else { return }
        
        do {
            try playerStore.save(history, named: Self.historyDocumentName)
        }
        catch {
            log(error: "Couldn't save the play history: \(error)")
        }
    }
    
    
    func loadAllSavedPlaylists() -> [SavedPlaylist] {
        guard let playlistsStore else { return [] }
        
        do {
            return try playlistsStore
                .allDocumentNames()
                .compactMap { name in
                    do {
                        return try playlistsStore.load(SavedPlaylist.self, named: name)
                    }
                    catch {
                        log(error: "Couldn't read the saved playlist document “\(name)”; skipping it (but leaving it on disk): \(error)")
                        return nil
                    }
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        catch {
            log(error: "Couldn't list the saved playlist documents: \(error)")
            return []
        }
    }
    
    
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
            + savedPlaylists.flatMap(\.items)
            + queue.entries.map(\.reference)
        
        for reference in allReferences {
            known[reference.filename] = reference
        }
        
        return known
    }
}
