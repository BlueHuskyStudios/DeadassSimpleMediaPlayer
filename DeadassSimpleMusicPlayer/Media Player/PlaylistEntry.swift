//
//  PlaylistEntry.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation



/// One slot in a playback queue.
///
/// Pairs the durable identity of a media file (its ``reference``) with this session's attempt to make it playable (its ``state``). Keeping unplayable slots around — rather than silently dropping files whose bookmarks no longer resolve — means a restored queue always looks like the queue the user left, and their data is never destroyed just because a file is temporarily unreachable.
public struct PlaylistEntry: Identifiable, Equatable, Sendable {
    
    /// Distinguishes this slot from every other slot, even another slot holding the same file.
    ///
    /// Stable across app sessions (it's persisted in queue snapshots), so shuffle orders and the current-item pointer can survive relaunch by pointing at IDs instead of at positions.
    public let id: UUID
    
    /// The durable pointer to this slot's media file. This is what gets written to disk when the queue or a playlist is saved.
    public let reference: MediaReference
    
    /// Whether this session managed to regain access to the file, and the live item if so
    public let state: State
    
    
    public init(id: UUID = UUID(), reference: MediaReference, state: State) {
        self.id = id
        self.reference = reference
        self.state = state
    }
    
    
    /// Wraps a freshly-created live item in a new slot
    public init(_ item: MediaItem) {
        self.init(reference: item.reference, state: .ready(item))
    }
    
    
    
    /// This session's relationship to the slot's file
    public enum State: Equatable, Sendable {
        
        /// The file resolved and is ready to play
        case ready(MediaItem)
        
        /// The file couldn't be reached this session (moved, deleted, or its provider is offline). The slot remains visible so the user can see what's missing; playback skips over it.
        case unavailable
    }
}



public extension PlaylistEntry {
    
    /// The live, playable item, or `nil` if the file couldn't be reached this session
    var mediaItem: MediaItem? {
        switch state {
        case .ready(let item): item
        case .unavailable:     nil
        }
    }
    
    
    /// Whether playback can land on this slot. Movement operations skip slots where this is `false`.
    var isPlayable: Bool {
        nil != mediaItem
    }
    
    
    /// Builds a slot by attempting to resolve a persisted reference.
    ///
    /// Never fails: an unresolvable file becomes an ``State/unavailable`` slot instead of vanishing. Pass the slot's persisted `id` so pointers into the queue (current item, shuffle order) remain valid across the restore.
    static func resolving(id: UUID = UUID(), _ reference: MediaReference) async -> Self {
        if let item = await MediaItem(resolving: reference) {
            Self(id: id, reference: item.reference, state: .ready(item))
        }
        else {
            Self(id: id, reference: reference, state: .unavailable)
        }
    }
}
