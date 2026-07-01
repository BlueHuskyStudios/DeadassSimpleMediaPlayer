//
//  NowPlayingSnapshot.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation



/// Everything needed to reconstruct the now-playing queue in a later app session: which files, in which user order, under which shuffle order, pointing at which entry, how far into it, and what repeat behavior was chosen.
///
/// The play position is only meaningful for the current entry's file — per-file positions are deliberately not kept for anything else.
public struct NowPlayingSnapshot: Codable, Sendable {
    
    /// The queue's slots in the user-specified order, reduced to what must survive relaunch
    public var entries: [Entry]
    
    /// The shuffled play order (as entry IDs), or `nil` if the queue was playing in the user-specified order
    public var playbackOrder: [UUID]?
    
    /// The entry that was current when this snapshot was taken
    public var currentEntryID: UUID?
    
    /// How far into the current entry's file playback had reached, in seconds
    public var playbackPositionSeconds: Double?
    
    /// The repeat behavior that was in effect
    public var repeatMode: RepeatMode
    
    
    
    /// One queue slot, reduced to what must survive relaunch: which slot it is, and which file it holds
    public struct Entry: Codable, Sendable {
        public var id: UUID
        public var reference: MediaReference
    }
}



public extension NowPlayingSnapshot {
    
    /// Captures the given queue as it stands right now.
    ///
    /// - Parameters:
    ///   - playlist:                The queue to capture
    ///   - playbackPositionSeconds: How far into the current entry playback has reached. Pass `nil` when nothing is loaded.
    ///   - repeatMode:              The repeat behavior in effect
    init(of playlist: Playlist, playbackPositionSeconds: Double?, repeatMode: RepeatMode) {
        self.entries = playlist.entries.map { Entry(id: $0.id, reference: $0.reference) }
        self.playbackOrder = playlist.playbackOrder
        self.currentEntryID = playlist.currentEntryID
        self.playbackPositionSeconds = playbackPositionSeconds
        self.repeatMode = repeatMode
    }
    
    
    /// Rebuilds the live queue this snapshot describes, re-resolving every file reference.
    ///
    /// Files that can't be reached anymore become `unavailable` slots rather than disappearing, so the restored queue always looks like the queue the user left. Slot IDs are preserved through the restore, which is what keeps ``playbackOrder`` and ``currentEntryID`` pointing at the right slots.
    ///
    /// This is also a trust boundary: snapshots live on disk, where truncation or hand-editing can corrupt them, so the shuffle order and current pointer are validated against the restored slot IDs instead of being trusted blindly.
    func restoredPlaylist() async -> Playlist {
        var restored: [PlaylistEntry] = []
        restored.reserveCapacity(entries.count)
        
        for entry in entries {
            restored.append(await .resolving(id: entry.id, entry.reference))
        }
        
        let validIDs = Set(restored.map(\.id))
        
        // Validation: keep only IDs which name real slots, drop duplicates, and append any slots the order is missing (so every entry remains reachable even after corruption)
        let validatedOrder: [UUID]? = playbackOrder.map { order in
            var seen = Set<UUID>()
            var validated = order.filter { validIDs.contains($0) && seen.insert($0).inserted }
            
            for entry in restored where !seen.contains(entry.id) {
                validated.append(entry.id)
                seen.insert(entry.id)
            }
            
            return validated
        }
        
        return Playlist(
            entries: restored,
            currentEntryID: currentEntryID.flatMap { validIDs.contains($0) ? $0 : nil },
            playbackOrder: validatedOrder)
    }
}
