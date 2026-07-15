//
//  PlaybackHistory.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation



/// The record of what's been played, newest first, so the user can find their way back to something they forgot they were playing.
///
/// A file earns its place here once one second of it has played (or immediately, for files shorter than a second) — that threshold is enforced by the player, not this type; this type just keeps the list.
public struct PlaybackHistory: Codable, Sendable {
    
    /// What's been played, newest first
    public private(set) var entries: [Entry]
    
    /// How much history to keep. Applied automatically on every ``record(_:displayName:at:)``; apply manually (via ``applyRetention(asOf:)``) after changing this.
    public var retention: Retention
    
    
    public init(entries: [Entry] = [], retention: Retention = .forever) {
        self.entries = entries
        self.retention = retention
    }
    
    
    
    /// One remembered playback
    public struct Entry: Codable, Identifiable, Sendable {
        
        public var id: UUID
        
        /// The file that was played, durable enough to be re-opened from history in a later session
        public var reference: MediaReference
        
        /// What to call this entry in a list — the media's title when metadata had resolved by recording time, its filename otherwise. Captured here because history must remain readable even after the file itself becomes unreachable.
        public var displayName: String
        
        /// When this playback happened (most recent playback, when consecutive replays collapse into one entry)
        public var playedAt: Date
    }
    
    
    
    /// How far back history is kept.
    ///
    /// Time windows are rolling (e.g. `.within(days: 1)` means "the last 24 hours"), which keeps the rule simple and calendar-math-free; the UI can still label presets in friendly terms.
    public enum Retention: Codable, Hashable, Sendable {
        
        /// Keep everything, forever. The default.
        case forever
        
        /// Keep only this many of the most recent entries
        case mostRecent(count: UInt)
        
        /// Keep only entries from the last this-many days (rolling window)
        case within(days: UInt)
    }
}



public extension PlaybackHistory {
    
    /// Notes that the given file was played.
    ///
    /// Consecutive replays of the same file collapse into one entry (its timestamp refreshes) so a looping short file doesn't flood the list — history answers "what was I playing?", and a thousand identical rows answer it no better than one.
    ///
    /// - Parameters:
    ///   - reference:   The file that played
    ///   - displayName: What to call it in the list — see ``Entry/displayName``
    ///   - date:        When it played. Defaults to now.
    mutating func record(_ reference: MediaReference, displayName: String, at date: Date = .init()) {
        if let mostRecent = entries.first,
           mostRecent.reference == reference
        {
            entries[0].playedAt = date
            entries[0].displayName = displayName
        }
        else {
            entries.insert(
                Entry(id: UUID(), reference: reference, displayName: displayName, playedAt: date),
                at: 0)
        }
        
        applyRetention(asOf: date)
    }
    
    
    /// Discards whatever ``retention`` says to discard. Called automatically on every recording; call directly after the user tightens the retention setting.
    mutating func applyRetention(asOf date: Date = .init()) {
        switch retention {
        case .forever:
            return
            
        case .mostRecent(count: let count):
            entries = Array(entries.prefix(Int(count)))
            
        case .within(days: let days):
            let cutoff = date.addingTimeInterval(-(TimeInterval(days) * 86_400))
            entries.removeAll { $0.playedAt < cutoff }
        }
    }
    
    
    /// Empties the history entirely, regardless of retention setting
    mutating func clear() {
        entries = []
    }
}
