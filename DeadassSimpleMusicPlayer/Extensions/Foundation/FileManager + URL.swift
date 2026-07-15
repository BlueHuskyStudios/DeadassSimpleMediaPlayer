//
//  FileManager + URL.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import Foundation
import UniformTypeIdentifiers



public extension FileManager {
    
    func fileExists(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory = ObjCBool(Bool())
        let exists = fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return (exists: exists, isDirectory: isDirectory.boolValue)
    }
    
    
    func fileExists(at url: URL) -> Bool {
        fileExists(at: url).exists
    }
    
    
    func isDirectory(at url: URL) -> Bool {
        fileExists(at: url).isDirectory
    }
}



public extension FileManager {
    /// Performs a search of the specified directory and returns URLs for the contained items.
    ///
    /// - Parameters:
    ///   - url:          The URL of a directory whose contents to return
    ///   - contentTypes: _optional_ - Restricts content types to include. If excluded, all items are included. If `recursive` is `true`, then `.directory` is assumed.
    ///   - recursive:    _optional_ - If `true`, this does a complete, deep search of the given directory and all subdirectories, and then searches those too. In that case, the returned array contains all the non-directory items.
    ///                             If `false`, this does a shallow search, only looking within the given directory. In that case, the returned array contains only the items immediately within this directory, including subdirectories.
    ///
    /// - Returns: URLs pointing to all requested files
    /// - Throws: Whatever ``contentsOfDirectory(at:includingPropertiesForKeys:)`` would throw
    func contentsOfDirectory(at url: URL, contentTypes: Set<UTType>? = nil, recursive: Bool = false) throws -> [URL] {
        var rootUrls = try contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey])
        
        if let contentTypes,
           !contentTypes.isEmpty
        {
            // Conformance, not equality: `contentTypes` holds broad categories (.audiovisualContent, .directory), but
            // each item's own type is concrete (.mp3, .folder)
            rootUrls = rootUrls
                .filter { url in contentTypes.contains(where: { url.conforms(to: $0) }) }
        }
        
        if recursive {
            var urls = [URL]()
            for url in rootUrls {
                if isDirectory(at: url) {
                    urls.append(contentsOf: try contentsOfDirectory(
                        at: url,
                        contentTypes: contentTypes?.union([.directory]),
                        recursive: recursive))
                }
                else {
                    urls.append(url)
                }
            }
            
            return urls
        }
        else {
            return rootUrls
        }
    }
}
