//
//  HistoryStore.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude Fable 5.1 on 2026-09-06.
//

import Foundation
import Observation

import SimpleLogging



/// What's been played, and the responsibility of keeping that durable.
///
/// A `Store` holds data whose lifecycle is independent of any player: history means something with nothing loaded and the app freshly launched. Mutations go through this store's methods so each one lands on disk the moment it happens — rare events, so immediate writes are cheap.
///
/// This store doesn't know *when* something counts as played; that's a judgment about playback position, made by whoever holds both the queue and the engine (``PlayerSession``), which then calls ``record(_:displayName:)``.
@MainActor
@Observable
public final class HistoryStore {
    
    #if DEBUG
    public var playbackHistory = PlaybackHistory()
    #else
    /// What's been played. Read-only from outside; mutations go through store methods (like ``record(_:displayName:)``) so each one lands on disk the moment it happens.
    public private(set) var playbackHistory = PlaybackHistory()
    #endif
    
    /// What's been played, newest first. Sugar for ``playbackHistory``'s entries, so `session.history.entries` reads the way it should.
    public var entries: [PlaybackHistory.Entry] {
        playbackHistory.entries
    }
    
    /// How far back history is kept. Change it with ``setRetention(_:)`` so the change lands on disk.
    public var retention: PlaybackHistory.Retention {
        playbackHistory.retention
    }
    
    /// Holds the "History" document. `nil` means persistence is unavailable and the store runs memory-only.
    private let documentStore: JSONDocumentStore?
    
    
    /// - Parameter documentStore: Where to keep the history document, or `nil` to run memory-only (like in SwiftUI previews)
    public init(documentStore: JSONDocumentStore?) {
        self.documentStore = documentStore
    }
}



// MARK: - Restoring

public extension HistoryStore {
    
    /// Reads history back from disk, applying retention (time marched on while the app was closed). Does nothing if persistence is unavailable or nothing was saved.
    func load() {
        guard let documentStore else { return }
        
        do {
            if var restoredHistory = try documentStore.load(PlaybackHistory.self, named: Self.historyDocumentName) {
                restoredHistory.applyRetention()
                playbackHistory = restoredHistory
            }
        }
        catch {
            log(error: "The play history document exists but couldn't be read: \(error)")
        }
    }
}



// MARK: - Recording & management

public extension HistoryStore {
    
    /// Puts a file into history right now, and onto disk
    func record(_ reference: MediaReference, displayName: String) {
        playbackHistory.record(reference, displayName: displayName)
        saveNow()
    }
    
    
    /// Changes how far back history is kept, immediately discarding anything the new setting excludes
    func setRetention(_ retention: PlaybackHistory.Retention) {
        playbackHistory.retention = retention
        playbackHistory.applyRetention()
        saveNow()
    }
    
    
    /// Empties the history entirely
    func clear() {
        playbackHistory.clear()
        saveNow()
    }
}



private extension HistoryStore {
    
    static let historyDocumentName = "History"
    
    
    func saveNow() {
        guard let documentStore else { return }
        
        do {
            try documentStore.save(playbackHistory, named: Self.historyDocumentName)
        }
        catch {
            log(error: "Couldn't save the play history: \(error)")
        }
    }
}
