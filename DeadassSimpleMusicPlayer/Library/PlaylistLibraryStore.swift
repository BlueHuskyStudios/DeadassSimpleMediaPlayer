//
//  PlaylistLibraryStore.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude Fable 5.1 on 2026-09-06.
//

import Foundation
import Observation

import CollectionTools
import SimpleLogging



/// Every playlist the user has saved, and the responsibility of keeping them durable.
///
/// A `Store` holds data whose lifecycle is independent of any player: the library is the library whether or not anything's playing. Mutations go through this store's methods so memory and disk never disagree.
///
/// Knows nothing about the now-playing queue. "Save the queue as a playlist" and "load a playlist into the queue" are ``PlayerSession``'s to arrange, since only it holds both sides.
@MainActor
@Observable
public final class PlaylistLibraryStore {
    
    #if DEBUG
    public var savedPlaylists: [SavedPlaylist] = []
    #else
    /// Every saved playlist, sorted by name. Read-only from outside; mutations go through store methods (like ``upsert(_:)``) so memory and disk never disagree.
    public private(set) var savedPlaylists: [SavedPlaylist] = []
    #endif
    
    /// Holds one document per saved playlist, named by the playlist's ID. `nil` means persistence is unavailable and the store runs memory-only.
    private let documentStore: JSONDocumentStore?
    
    
    /// - Parameter documentStore: Where to keep playlist documents, or `nil` to run memory-only (like in SwiftUI previews)
    public init(documentStore: JSONDocumentStore?) {
        self.documentStore = documentStore
    }
}



// MARK: - Restoring

public extension PlaylistLibraryStore {
    
    /// Reads every saved playlist back from disk, skipping (but leaving on disk) any that can't be read. Does nothing if persistence is unavailable.
    func load() {
        guard let documentStore else { return }
        
        do {
            savedPlaylists = try documentStore
                .allDocumentNames()
                .compactMap { name in
                    do {
                        return try documentStore.load(SavedPlaylist.self, named: name)
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
        }
    }
}



// MARK: - Editing

public extension PlaylistLibraryStore {
    
    /// Adds a new saved playlist, or updates the existing one with the same ID — in memory and on disk together, so the two never disagree
    func upsert(_ playlist: SavedPlaylist) {
        if let existingIndex = savedPlaylists.firstIndex(where: { playlist.id == $0.id }) {
            savedPlaylists[existingIndex] = playlist
        }
        else {
            savedPlaylists.append(playlist)
        }
        
        savedPlaylists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        guard let documentStore else { return }
        
        do {
            try documentStore.save(playlist, named: playlist.id.uuidString)
        }
        catch {
            log(error: "Couldn't save the playlist “\(playlist.name)”: \(error)")
        }
    }
    
    
    /// Removes a saved playlist — from memory and disk together, so the two never disagree
    /// - Parameter id: The ID of the playlist to delete
    /// - Throws: An error if the playlist couldn't be deleted
    func delete(playlistWithID id: SavedPlaylist.ID) throws {
        savedPlaylists.removeAll { id == $0.id }
        
        guard let documentStore else { return }
        
        try documentStore.delete(documentNamed: id.uuidString)
    }
}



// MARK: - Importing

public extension PlaylistLibraryStore {
    
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
    /// Sandboxing means bare filenames can't grant access to files this app has never been handed — so each entry is matched, by filename, against `knownReferences`: every file the app *already* knows. Matches become the imported playlist; strangers are counted and skipped, with the outcome logged. Perfect-someday: prompting the user to locate unmatched files.
    ///
    /// - Parameters:
    ///   - data:            The playlist file's contents
    ///   - suggestedName:   What to call the import — typically the file's own name
    ///   - knownReferences: Every file the app has a durable way back to, indexed by filename. This store only knows its own playlists' files; ``PlayerSession`` assembles the full pool from the queue and history too.
    ///
    /// - Returns: A saved playlist and the number of failed track-imports, or `nil` if the given data is an invalid playlist
    func importPlaylist(fromM3U8 data: Data, suggestedName: String, matchingAgainst knownReferences: [String: MediaReference]) -> (SavedPlaylist, failedTrackImportCount: Int)? {
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
        
        let failedTrackImportCount = entryLines.count - matchedItems.count
        
        if failedTrackImportCount > 0 {
            log(warning: "Imported \(matchedItems.count) of \(entryLines.count) M3U8 entries; the rest named files this app has never been granted access to")
        }
        
        let playlist = SavedPlaylist(name: suggestedName, items: matchedItems)
        upsert(playlist)
        return (playlist, failedTrackImportCount: failedTrackImportCount)
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
}
