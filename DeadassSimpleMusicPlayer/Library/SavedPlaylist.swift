//
//  SavedPlaylist.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation



/// A named, ordered list of media files, stored durably so it can be played again in any future session.
///
/// This is user data in the truest sense, so it holds only what the user curated: a name, an order, and the files themselves. Playback conveniences like shuffle and repeat belong to the now-playing queue and are never written here — shuffling a queue must never rewrite the order someone curated.
public struct SavedPlaylist: Codable, Identifiable, Hashable, Sendable {
    
    public var id: UUID
    
    /// What the user (or the album auto-grouper) calls this playlist
    public var name: String
    
    /// How this playlist came to exist, which UI can use to present albums differently from hand-made playlists
    public var kind: Kind
    
    /// The files, in the user-specified order
    public var items: [MediaReference]
    
    
    public init(id: UUID = UUID(), name: String, kind: Kind = .userCreated, items: [MediaReference]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.items = items
    }
    
    
    
    /// How a playlist came to exist
    public enum Kind: String, Codable, Sendable {
        
        /// Built by a person: created by hand, saved from the queue, or imported
        case userCreated = "user-created"
        
        /// Built automatically from files sharing album metadata at import time
        case album
    }
}



public extension SavedPlaylist {
    
    /// Captures the user-visible order of the given queue as a new saved playlist.
    ///
    /// Uses the queue's user-specified order, not its shuffled playback order: saving a shuffled queue saves the *queue*, not the shuffle.
    init(name: String, savingQueue queue: Playlist) {
        self.init(name: name, items: queue.entries.map(\.reference))
    }
}



// MARK: - Export

public extension SavedPlaylist {
    
    /// This playlist serialized as Extended M3U — the lingua franca of playlist files — for handing to other apps and devices.
    ///
    /// Entries are written as bare filenames rather than paths: sandbox paths are meaningless outside this app anyway, and a filename gives other software (and humans) the best chance of matching each entry to a real file. Durations are written as `-1` (unknown) since durations aren't stored in the playlist itself.
    var m3u8Text: String {
        var lines = ["#EXTM3U"]
        lines.reserveCapacity(items.count * 2 + 1)
        
        for item in items {
            lines.append("#EXTINF:-1,\(item.displayName)")
            lines.append(item.filename)
        }
        
        return lines.joined(separator: "\n") + "\n"
    }
    
    
    /// ``m3u8Text``, rendered to the bytes an exported file should contain
    var exportedM3U8Data: Data {
        Data(m3u8Text.utf8)
    }
    
    
    /// This playlist rendered as the app's native JSON — pretty-printed and key-sorted, same as on-disk storage, so exports are diffable against (and interchangeable with) what the app itself writes.
    ///
    /// Includes each item's bookmark data, so re-importing on the same device usually regains file access outright. On any other device the bookmarks are inert noise, and the M3U8 export is the better interchange format.
    func exportedJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
