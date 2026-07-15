//
//  ExportablePlaylistDocument.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-02.
//

import SwiftUI
import UniformTypeIdentifiers



/// A fully-rendered playlist export, in whatever format the user chose, ready to hand to SwiftUI's `fileExporter`.
///
/// Deliberately just a bag of bytes: the interesting work (rendering a `SavedPlaylist` into JSON or M3U8) happens before this exists, so this type never needs to know what a playlist is — and can carry any future export format unchanged.
struct ExportablePlaylistDocument: FileDocument {
    
    static let readableContentTypes: [UTType] = [.json, .m3uPlaylist]
    
    
    /// The rendered file contents, exactly as they'll land on disk
    var data: Data
    
    
    init(data: Data) {
        self.data = data
    }
    
    
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        self.data = contents
    }
    
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
