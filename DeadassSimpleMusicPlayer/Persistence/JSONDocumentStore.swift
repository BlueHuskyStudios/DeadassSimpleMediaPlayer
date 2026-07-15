//
//  JSONDocumentStore.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation



/// Reads and writes the app's `Codable` documents as JSON files in Application Support.
///
/// This is deliberately the thinnest possible storage layer: one value per file, atomic writes, no caching, no migrations, no queries. It exists as a seam — everything above it deals in plain `Codable` values, so swapping in a different store someday (an object store like SHELF, say) means reimplementing a handful of functions rather than rethinking any model.
///
/// Output is pretty-printed with sorted keys so a human poking around the app container can read — and diff — their own data.
public struct JSONDocumentStore: Sendable {
    
    /// The folder this store's documents live in
    public let directory: URL
    
    
    /// Opens the store rooted at `Application Support/<subfolder>`, creating that folder if it doesn't yet exist.
    ///
    /// - Parameter subfolder: Namespaces this store's documents apart from anything else in Application Support. May be a nested path (like `"Library/Playlists"`); intermediate folders are created as needed.
    /// - Throws: If Application Support can't be found or the subfolder can't be created — both of which mean persistence is impossible, so callers should treat this as "run without persistence", not "crash"
    public init(subfolder: String) throws {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        
        self.directory = applicationSupport.appending(path: subfolder, directoryHint: .isDirectory)
        
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}



public extension JSONDocumentStore {
    
    /// Reads and decodes the named document.
    ///
    /// - Returns: The decoded document, or `nil` if no document by that name exists (a normal condition: first launch, cleared data, etc.)
    /// - Throws: If the document exists but can't be read or decoded — a signal of corruption worth logging, distinct from mere absence
    func load<Document: Decodable>(_ documentType: Document.Type = Document.self, named name: String) throws -> Document? {
        let url = url(forDocumentNamed: name)
        
        let exists: Bool = FileManager.default.fileExists(at: url)
        guard exists else { return nil }
        
        return try Self.makeDecoder().decode(Document.self, from: Data(contentsOf: url))
    }
    
    
    /// Encodes and writes the named document, replacing any previous version.
    ///
    /// The write is atomic, so a crash mid-save leaves the previous version intact rather than a truncated file.
    func save<Document: Encodable>(_ document: Document, named name: String) throws {
        try Self.makeEncoder()
            .encode(document)
            .write(to: url(forDocumentNamed: name), options: .atomic)
    }
    
    
    /// Removes the named document. Removing a document that doesn't exist is a no-op, not an error.
    func delete(documentNamed name: String) throws {
        let url = url(forDocumentNamed: name)
        
        let exists: Bool = FileManager.default.fileExists(at: url)
        guard exists else { return }
        
        try FileManager.default.removeItem(at: url)
    }
    
    
    /// The names (without extensions) of every document currently in this store.
    ///
    /// This is how collections-of-documents (like saved playlists, one file each) are enumerated without this layer needing to know what a "collection" is.
    func allDocumentNames() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { Self.fileExtension == $0.pathExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}



private extension JSONDocumentStore {
    
    func url(forDocumentNamed name: String) -> URL {
        directory
            .appending(component: name, directoryHint: .notDirectory)
            .appendingPathExtension(Self.fileExtension)
    }
    
    
    /// Fresh per call because `JSONEncoder` isn't `Sendable`; construction is cheap and this keeps the store trivially safe to use from anywhere
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    
    
    /// Fresh per call because `JSONDecoder` isn't `Sendable`; construction is cheap and this keeps the store trivially safe to use from anywhere
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    
    
    static let fileExtension = "json"
}
