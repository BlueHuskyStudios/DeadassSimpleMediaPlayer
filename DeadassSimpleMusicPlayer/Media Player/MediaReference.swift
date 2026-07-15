//
//  MediaReference.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation

import SimpleLogging



/// A durable, storable pointer to a media file the user granted us access to.
///
/// Security-scoped URLs from the system file picker die with the app session, so anything that must survive a relaunch (the now-playing queue, saved playlists, play history) stores one of these instead of a URL.
///
/// Create one while the file's security scope is active (the system embeds the access grant into the bookmark at creation time); resolve it in a later session to regain both the file's location and the right to read it.
public struct MediaReference: Codable, Hashable, Sendable {
    
    /// System-issued bookmark data which re-grants sandbox access to the file in later app sessions
    public var bookmarkData: Data
    
    /// The file's name as of the last time we could actually see the file.
    ///
    /// Kept alongside the bookmark so the file can still be named in UI and text exports (like M3U8) even when the bookmark no longer resolves.
    public var filename: String
}



// MARK: - Creation & resolution

public extension MediaReference {
    
    /// Creates a reference to the file at the given URL.
    ///
    /// Only call this while the URL's security scope is active (e.g. after a successful `startAccessingSecurityScopedResource()`, or within `accessSecurityScopedResource`); the system embeds the access grant into the bookmark at creation time, so a bookmark created outside the scope won't re-grant access later.
    ///
    /// - Parameter url: The security-scope-active URL to remember
    /// - Throws: Whatever `URL.bookmarkData(options:includingResourceValuesForKeys:relativeTo:)` throws
    init(bookmarking url: URL) throws {
        self.bookmarkData = try url.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        self.filename = url.lastPathComponent
    }
    
    
    /// Turns this reference back into a usable URL.
    ///
    /// The returned URL's security scope has **not** been started; the caller decides when to start (and how long to hold) access. When `isStale` is `true`, the system wants the bookmark re-created — do that with ``init(bookmarking:)`` while holding the resolved URL's security scope, and persist the fresh reference in place of this one.
    ///
    /// - Returns: The file's current location, and whether the system asked for this bookmark to be re-created
    /// - Throws: Whatever `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` throws (typically: the file no longer exists or its provider is unreachable)
    func resolve() throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        return (url: url, isStale: isStale)
    }
}



// MARK: - Display sugar

public extension MediaReference {
    
    /// The filename with its final extension removed, for display contexts where ".mp3" is noise
    var displayName: String {
        let base = (filename as NSString).deletingPathExtension
        return base.isEmpty ? filename : base
    }
}



// MARK: - Platform differences

private extension MediaReference {
    
    /// Security scope is implicit in iOS bookmarks, but macOS requires opting in at creation time. Both this and ``bookmarkResolutionOptions`` isolate that platform difference to this one type, so nothing above this layer needs to care which OS it's on.
    static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
    
    
    /// Security scope is implicit in iOS bookmarks, but macOS requires opting in at creation time. Both this and ``bookmarkCreationOptions`` isolate that platform difference to this one type, so nothing above this layer needs to care which OS it's on.
    static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
}
