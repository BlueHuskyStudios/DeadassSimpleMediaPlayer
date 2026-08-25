//
//  Playlist.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-13.
//  Some notable changes by Claude 5 Fable since 2026-07-01.
//

import AsyncAlgorithms
import Foundation

import SimpleLogging
import UniformTypeIdentifiers



/// The queue of items to be played in a player.
///
/// Identity, not position, is the organizing principle here: the current item and the shuffle order both point at entry IDs rather than array indices, so appending, removing, and shuffling can never silently redirect a pointer at the wrong item — an ID either resolves or it doesn't.
///
/// Two orders coexist:
/// - ``entries`` is the user-specified order. It's what gets saved when the queue becomes a playlist, and it's never rewritten by playback conveniences.
/// - ``playbackOrder``, when present, is a shuffled permutation of entry IDs which playback (and queue UI) follow instead. Discarding it restores un-shuffled behavior instantly, because the user's order was never touched.
public struct Playlist: Sendable {
    
    /// The queue's slots, in the user-specified order
    public var entries: [Entry]
    
    /// Points at the entry currently being played (or paused or similar). `nil` means no entry has been explicitly chosen yet, in which case ``currentEntry`` falls back to the first entry in the effective order.
    public var currentEntryID: Entry.ID?
    
    /// The shuffled play order, as a permutation of entry IDs, or `nil` when playing in the user-specified order.
    ///
    /// Mutations which add or remove entries maintain this permutation automatically; that invariant is why this is only settable through this type's own methods (and its initializer).
    public private(set) var playbackOrder: [Entry.ID]?
    
    
    public init(entries: [Entry] = [], currentEntryID: Entry.ID? = nil, playbackOrder: [Entry.ID]? = nil) {
        self.entries = entries
        self.currentEntryID = currentEntryID
        self.playbackOrder = playbackOrder
    }
    
    
    
    public typealias Entry = PlaylistEntry
}



// MARK: - State inspection

public extension Playlist {
    
    /// The IDs of all entries, in the order playback (and queue UI) should present them: the shuffled order when shuffled, the user-specified order otherwise
    var effectiveOrder: [Entry.ID] {
        playbackOrder ?? entries.map(\.id)
    }
    
    
    /// Whether a shuffled play order is currently in effect
    var isShuffled: Bool {
        nil != playbackOrder
    }
    
    
    /// The entry currently being played (or paused or similar), or `nil` if the queue is empty.
    ///
    /// When no entry has been explicitly chosen (``currentEntryID`` is `nil`), this is the first entry in the effective order — matching the intuition that a queue with content is always "on" something.
    var currentEntry: Entry? {
        if let currentEntryID {
            entry(withID: currentEntryID)
        }
        else {
            effectiveOrder.first.flatMap(entry(withID:))
        }
    }
    
    
    /// The entry which ``moveToNextEntry(wrapping:)`` would land on, without moving to it, or `nil` if there is none
    var nextEntry: Entry? {
        nextPlayableEntryID(after: currentEntry?.id, wrapping: false)
            .flatMap(entry(withID:))
    }
    
    
    /// Finds the entry with the given ID, or `nil` if no entry has that ID
    func entry(withID id: Entry.ID) -> Entry? {
        entries.first { id == $0.id }
    }
}



// MARK: - Movement

public extension Playlist {
    
    /// Changes the current entry to be the next playable entry in the effective order.
    ///
    /// Slots whose files couldn't be reached this session are skipped, so playback flows around holes rather than falling into them. If no playable entry lies ahead (or anywhere, when wrapping), the current entry is left untouched.
    ///
    /// - Parameter wrapping: If `true`, reaching the end of the order continues from its start — how a whole-queue repeat mode expresses itself as movement. Defaults to `false`.
    /// - Returns: The new current entry, or `nil` if there was nowhere to move
    @discardableResult
    mutating func moveToNextEntry(wrapping: Bool = false) -> Entry? {
        move(toNeighborInDirection: +1, wrapping: wrapping)
    }
    
    
    /// Changes the current entry to be the previous playable entry in the effective order.
    ///
    /// Slots whose files couldn't be reached this session are skipped, so playback flows around holes rather than falling into them. If no playable entry lies behind (or anywhere, when wrapping), the current entry is left untouched.
    ///
    /// - Parameter wrapping: If `true`, reaching the start of the order continues from its end. Defaults to `false`.
    /// - Returns: The new current entry, or `nil` if there was nowhere to move
    @discardableResult
    mutating func moveToPreviousEntry(wrapping: Bool = false) -> Entry? {
        move(toNeighborInDirection: -1, wrapping: wrapping)
    }
}



private extension Playlist {
    
    /// Shared engine behind next/previous movement: walks the effective order in the given direction, skipping unplayable slots, moving the pointer only if a playable destination exists
    mutating func move(toNeighborInDirection direction: Int, wrapping: Bool) -> Entry? {
        guard let destinationID = nearestPlayableEntryID(inDirection: direction, from: currentEntry?.id, wrapping: wrapping),
              let destination = entry(withID: destinationID)
        else {
            return nil
        }
        
        currentEntryID = destinationID
        return destination
    }
    
    
    /// Finds the ID of the closest playable entry strictly after `id` in the effective order (`direction: +1`), or strictly before it (`direction: -1`).
    ///
    /// Visits each slot at most once even when wrapping, so a queue of entirely-unreachable files terminates instead of spinning.
    func nearestPlayableEntryID(inDirection direction: Int, from id: Entry.ID?, wrapping: Bool) -> Entry.ID? {
        let order = effectiveOrder
        guard !order.isEmpty else { return nil }
        
        var position: Int
        if let id,
           let startIndex = order.firstIndex(of: id)
        {
            position = startIndex
        }
        else {
            // No meaningful starting point: the first playable entry in the order is the natural destination regardless of direction
            return order.first { entry(withID: $0)?.isPlayable ?? false }
        }
        
        for _ in 1 ... order.count {
            position += direction
            
            if !order.indices.contains(position) {
                guard wrapping else { return nil }
                position = ((position % order.count) + order.count) % order.count
            }
            
            let candidateID = order[position]
            guard candidateID != id else { return nil } // Wrapped all the way around; the only playable slot is the one we started on
            
            if entry(withID: candidateID)?.isPlayable ?? false {
                return candidateID
            }
        }
        
        return nil
    }
    
    
    /// Like ``nearestPlayableEntryID(inDirection:from:wrapping:)``, fixed forward — named separately for readability at call sites that only ever peek ahead
    func nextPlayableEntryID(after id: Entry.ID?, wrapping: Bool) -> Entry.ID? {
        nearestPlayableEntryID(inDirection: +1, from: id, wrapping: wrapping)
    }
}



// MARK: - Modification

public extension Playlist {
    
    /// Appends pre-resolved entries to this queue and, optionally, points the current-entry pointer at the first playable newcomer when nothing playable was current before.
    ///
    /// Synchronous on purpose: with no suspension point, this mutation is safe to invoke on `@State`-backed storage from any actor-isolated context. Pair with ``entries(fromUrl:allowedContentTypes:allowRecursion:)`` when the entries originate from disk.
    ///
    /// When a shuffled order is in effect, newcomers are woven into random positions in the not-yet-played tail of that order, so "add while shuffled" behaves like the new files were part of the shuffle all along.
    ///
    /// - Parameters:
    ///   - newEntries:           The entries to append
    ///   - allowMovingToNewItem: If `true`, and nothing playable was current before this call, the current-entry pointer moves to the first playable entry being added. If `false`, the pointer never moves. Defaults to `true`.
    mutating func append(contentsOf newEntries: [Entry], allowMovingToNewItem: Bool = true) {
        guard !newEntries.isEmpty else { return }
        
        let hadPlayableCurrent = currentEntry?.isPlayable ?? false
        
        entries.append(contentsOf: newEntries)
        weaveIntoPlaybackOrder(newEntries.map(\.id))
        
        if allowMovingToNewItem,
           !hadPlayableCurrent,
           let firstPlayable = newEntries.first(where: \.isPlayable)
        {
            currentEntryID = firstPlayable.id
        }
    }
    
    
    /// Appends one pre-resolved entry to this queue. See ``append(contentsOf:allowMovingToNewItem:)`` for pointer-movement and shuffle behavior.
    mutating func append(_ newEntry: Entry, allowMovingToNewItem: Bool = true) {
        append(contentsOf: [newEntry], allowMovingToNewItem: allowMovingToNewItem)
    }
    
    
    /// Removes the entry with the given ID, keeping the current-entry pointer meaningful.
    ///
    /// If the removed entry was current, the pointer first tries to step forward, then backward, and only becomes `nil` when nothing playable remains — mirroring how a user expects "delete the thing that's playing" to feel: the queue moves on rather than resetting.
    mutating func remove(entryWithID id: Entry.ID) {
        if currentEntryID == id || (nil == currentEntryID && currentEntry?.id == id) {
            if nil == moveToNextEntry(wrapping: false),
               nil == moveToPreviousEntry(wrapping: false)
            {
                currentEntryID = nil
            }
        }
        
        entries.removeAll { id == $0.id }
        playbackOrder?.removeAll { id == $0 }
    }
    
    
    mutating func removeAll() {
        entries.removeAll()
        currentEntryID = nil
        playbackOrder = nil
    }
    
    
    /// Reorders the *presented* order, using the offset semantics SwiftUI's `onMove(perform:)` supplies.
    ///
    /// Which order that is depends on shuffle state, matching what the user is looking at when they drag: un-shuffled, this rearranges the user-specified ``entries`` order (durable, saved into playlists); shuffled, it rearranges only the ephemeral ``playbackOrder`` — dragging rows around a shuffled queue never rewrites the order the user curated.
    mutating func moveEntries(fromEffectiveOffsets source: IndexSet, toEffectiveOffset destination: Int) {
        if nil != playbackOrder {
            playbackOrder = playbackOrder.map { $0.moving(fromOffsets: source, toOffset: destination) }
        }
        else {
            entries = entries.moving(fromOffsets: source, toOffset: destination)
        }
    }
}



// MARK: - Shuffling

public extension Playlist {
    
    /// Temporary: Shuffles the playback order. Calling ``unshuffle()`` restores the user-specified playback order.
    ///
    /// The current entry is placed first in the new order (when there is one), matching the expectation that enabling shuffle mid-song shuffles what comes *next*, not what's playing. The user-specified order in ``entries`` is untouched, so ``unshuffle()`` is always a perfect undo.
    mutating func shuffle() {
        guard !entries.isEmpty else {
            playbackOrder = nil
            return
        }
        
        var order = entries.map(\.id).shuffled()
        
        if let currentID = currentEntry?.id,
           let currentPosition = order.firstIndex(of: currentID)
        {
            order.remove(at: currentPosition)
            order.insert(currentID, at: 0)
        }
        
        playbackOrder = order
    }
    
    
    /// Discards the shuffled play order, returning playback to the user-specified order. The current entry stays current.
    mutating func unshuffle() {
        playbackOrder = nil
    }
}



private extension Playlist {
    
    /// Maintains the shuffle-order invariant when entries are appended: each newcomer lands at a uniformly random position in the not-yet-played tail of the order. No-op when not shuffled.
    mutating func weaveIntoPlaybackOrder(_ ids: [Entry.ID]) {
        guard var order = playbackOrder else { return }
        
        let firstEligiblePosition = 1 + (currentEntryID.flatMap { order.firstIndex(of: $0) } ?? -1)
        
        for id in ids {
            order.insert(id, at: .random(in: firstEligiblePosition ... order.count))
        }
        
        playbackOrder = order
    }
}



private extension Array {
    
    
    /// Reimplements the semantics of SwiftUI's `move(fromOffsets:toOffset:)` — which, despite its documentation living under the standard library, is actually only available by importing SwiftUI. Reimplementing ~10 lines keeps this model layer free of a UI-framework dependency.
    ///
    /// Semantics: the elements at `source` offsets move, as a block preserving their relative order, to sit before the element which was at `destination` — both interpreted in the *pre-move* collection, exactly as `onMove(perform:)` supplies them.
    func moving(fromOffsets source: IndexSet, toOffset destination: Int) -> [Element] {
        let moved = source.compactMap { self.indices.contains($0) ? self[$0] : nil }
        
        var remaining: [Element] = []
        remaining.reserveCapacity(self.count)
        
        var insertionIndex = destination
        
        for (offset, element) in self.enumerated() {
            if source.contains(offset) {
                // Everything removed from before the destination shifts the insertion point down by one
                if offset < destination {
                    insertionIndex -= 1
                }
            }
            else {
                remaining.append(element)
            }
        }
        
        remaining.insert(contentsOf: moved, at: Swift.min(insertionIndex, remaining.count))
        return remaining
    }
}



// MARK: - Importing from disk

public extension Playlist {
    
    /// Builds queue entries from the media at the given URL: the file itself, or the contents of the folder it points to.
    ///
    /// This is the async half of adding media to a queue — all the file-system and metadata work happens here, producing plain values. Feed the result to the synchronous ``append(contentsOf:allowMovingToNewItem:)`` on whatever actor owns the queue. Splitting it this way is what lets the queue stay a value type in actor-isolated `@State` storage without `mutating async` conflicts.
    ///
    /// Currently, this only supports file URLs (`file://`).
    ///
    /// - Parameters:
    ///   - url:                 The URL containing the media to add, or a folder filled with media
    ///   - allowedContentTypes: What kinds of things are OK to add to a queue
    ///   - allowRecursion:      Whether to look inside sub-folders for more media.
    ///                          If `false`, this only looks at items directly in this folder, and not any deeper.
    ///                          If `true`, this endlessly looks deeper as long as there are more folders to explore. Be warned that this can cause a crash if there are recursive folders such as symlinks.
    ///                          Defaults to `false`.
    /// - Returns: One entry per successfully-opened media file, or an empty array if nothing could be opened
    static func entries(fromUrl url: URL, allowedContentTypes: Set<UTType> = defaultAllowedContentTypes, allowRecursion: Bool = false) async -> [Entry] {
        await url.accessSecurityScopedResource { (url) -> [Entry] in
            
            let fileManager = FileManager.default
            let (exists: exists, isDirectory: isDirectory) = fileManager.fileExists(at: url)
            
            guard exists else {
                log(warning: "I was asked to add media from a URL which doesn't point to any file: \(url)")
                return []
            }
            
            if isDirectory {
                guard allowedContentTypes.contains(where: { $0.conforms(to: .directory) }) else {
                    log(verbose: "I was asked to add media from a folder, but wasn't allowed to: \(url)")
                    return []
                }
                
                do {
                    let entries = try await fileManager
                        .contentsOfDirectory(at: url, contentTypes: allowedContentTypes, recursive: allowRecursion)
                        .async
                        .compactMap { url -> Entry? in
                            // Non-recursive listings include subfolders by contract; a folder must never become a
                            // "playable" queue entry
                            guard !fileManager.isDirectory(at: url) else { return nil }
                            return await MediaItem(url: url).map { Entry($0) }
                        }
                        .collect()
                    
                    let sortedEntries = await entries.autoSorted()
                    
                    log(info: "Built \(sortedEntries.count) queue entries from the folder \(url.lastPathComponent)")
                    return sortedEntries
                }
                catch {
                    log(error: error)
                    return []
                }
            }
            else {
                guard allowedContentTypes
                    .subtracting([.directory])
                    .contains(where: url.conforms),
                      let item = await MediaItem(url: url)
                else {
                    log(info: "I was asked to add media, but wasn't allowed to: \(url)")
                    return []
                }
                
                return [Entry(item)]
            }
        }
        onFailure: {
            log(error: "I couldn't get the necessary permissions to read from this URL: \(url)")
            return []
        }
    }
    
    
    static let defaultAllowedContentTypes: Set<UTType> = [.audiovisualContent, .directory, .folder]
}



// MARK: - Sorting a fresh folder import

private extension [Playlist.Entry] {
    
    /// Orders freshly-built entries the way opening an album's folder should read: by album, then track number, then file type, then how recently the file was created — so playback starts in the right order the instant the folder opens, with nothing to reorder later.
    ///
    /// Awaits every entry's album and track-number metadata before returning, on purpose: a folder import is a "load this now" action, not a background task the user might check on later, so the wait belongs here rather than being deferred and felt as playback starting in the wrong order.
    ///
    /// Missing keys always sort after present ones — a file with no album metadata reads as "comes after every real album," not as "first alphabetically" (which `nil` would otherwise do by accident).
    func autoSorted() async -> Self {
        var keyed: [(entry: Element, key: SortKey)] = []
        keyed.reserveCapacity(self.count)
        
        for entry in self {
            keyed.append((entry: entry, key: await SortKey(describing: entry)))
        }
        
        return keyed
            .sorted { $0.key < $1.key }
            .map(\.entry)
    }
    
    
    
    /// What a folder-imported entry sorts by, most significant first. Comparing two of these is the whole ordering policy for a folder import — see ``Optional/isOrderedBefore(_:)`` for how each field treats "unknown" as "last."
    struct SortKey: Comparable {
        var album: String?
        var discNumber: Int?
        var trackNumber: Int?
        var contentType: UTType
        var publishedDate: DateComponents?
        var fileName: String
        
        
        init(describing entry: Element) async {
            if let metadata = entry.mediaItem?.metadata {
                self.album = (try? await metadata.get(.album))?.nonEmptyOrNil
                self.discNumber = try? await metadata.get(.discNumber)
                self.trackNumber = try? await metadata.get(.trackNumber)
                self.publishedDate = try? await metadata.get(.publishedDate)
            }
            else {
                self.album = nil
                self.discNumber = nil
                self.trackNumber = nil
                self.publishedDate = nil
            }
            
            self.contentType = entry.mediaItem?.autoAccessSecurityScopedResourceUrl.contentType ?? .audiovisualContent
            
            self.fileName = entry.reference.filename
        }
        
        
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.album != rhs.album {
                lhs.album.isOrderedBefore(rhs.album) { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            else if lhs.discNumber != rhs.discNumber {
                lhs.discNumber.isOrderedBefore(rhs.discNumber, areInIncreasingOrder: <)
            }
            else if lhs.trackNumber != rhs.trackNumber {
                lhs.trackNumber.isOrderedBefore(rhs.trackNumber, areInIncreasingOrder: <)
            }
            else if lhs.contentType != rhs.contentType {
                lhs.contentType.identifier < rhs.contentType.identifier
            }
            else if lhs.publishedDate != rhs.publishedDate {
                lhs.publishedDate.isOrderedBefore(rhs.publishedDate, areInIncreasingOrder: <)
            }
            else {
                lhs.fileName < rhs.fileName
            }
        }
    }
}



private extension Optional where Wrapped: Equatable {
    
    /// Orders two optionals by `areInIncreasingOrder` when both have a value, treating `nil` as "comes after everything" rather than the default Comparable-adjacent behavior of sorting `nil` first.
    ///
    /// A missing album or track number should read as "at the end," not "first alphabetically."
    func isOrderedBefore(_ other: Self, areInIncreasingOrder: (Wrapped, Wrapped) -> Bool) -> Bool {
        switch (self, other) {
        case (nil, nil):                   false
        case (nil, .some):                 false
        case (.some, nil):                 true
        case (.some(let a), .some(let b)): areInIncreasingOrder(a, b)
        }
    }
}



// MARK: - Defaults

public extension Playlist {
    static let empty = Self()
}
