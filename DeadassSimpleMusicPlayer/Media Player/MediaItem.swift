//
//  MediaItem.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import AVFoundation
import Foundation

import ConcurrencyTools
@preconcurrency import LazyContainers
import SimpleLogging



/// Encapsulates a live media item: its URL, automatic security-scoped access, its durable reference, and metadata
public final actor MediaItem: Sendable {
    private nonisolated let id = UUID()
    
    /// The durable pointer to this file, suitable for writing to disk.
    ///
    /// Every `MediaItem` carries one so that anything holding a live item (the queue, history) can be persisted at any moment without asking the item to do more work. If this item was resolved from an older reference which the system flagged as stale, this is the freshened replacement — persist this one.
    public let reference: MediaReference
    
    public let autoAccessSecurityScopedResourceUrl: URL
    
    /// Whether this instance is the one that started (and must stop) the security scope, versus inheriting it from an already-active parent scope. See ``init(url:)``.
    private let ownsSecurityScope: Bool
    
    public let metadata: AsyncMetadata?
    
    
    /// Creates a live item from a URL freshly granted by the system file picker — or from a URL enumerated as a child of a folder whose own security scope is already active.
    ///
    /// Only the *top-level* URL the system hands you (from a picker, or a resolved bookmark) is independently security-scoped; calling `startAccessingSecurityScopedResource()` on a child URL discovered via `contentsOfDirectory` legitimately returns `false` even though the file is perfectly readable under its parent's still-active scope. So `false` here isn't treated as failure — only as "this instance doesn't own its own scope token, so it won't call the matching stop." The real test of access is what happens next: creating a bookmark, which requires the file to actually be reachable.
    init?(url: URL) async {
        let didStartOwnSecurityScope = url.startAccessingSecurityScopedResource()
        
        do {
            self.reference = try MediaReference(bookmarking: url)
        }
        catch {
            log(error: error)
            if didStartOwnSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            return nil
        }
        
        self.autoAccessSecurityScopedResourceUrl = url
        self.ownsSecurityScope = didStartOwnSecurityScope
        self.metadata = await Self.extractMetadata(from: url)
    }
    
    
    /// Re-creates a live item from a reference persisted in an earlier app session.
    ///
    /// Fails if the file can't be found (moved, deleted, provider offline) or its security scope can't be re-entered. A stale bookmark is freshened here, while we hold the scope, so the ``reference`` this item exposes is always the best-known version to persist.
    init?(resolving reference: MediaReference) async {
        let url: URL
        let isStale: Bool
        do {
            (url: url, isStale: isStale) = try reference.resolve()
        }
        catch {
            log(error: "Couldn't resolve the reference to “\(reference.filename)”: \(error)")
            return nil
        }
        
        guard url.startAccessingSecurityScopedResource() else {
            log(error: "Failed to access the media item as a security-scoped resource: \(url)")
            return nil
        }
        
        var bestReference = reference
        if isStale,
           let freshened = try? MediaReference(bookmarking: url)
        {
            bestReference = freshened
        }
        bestReference.filename = url.lastPathComponent // The file may have been renamed since we last saw it
        
        self.reference = bestReference
        self.autoAccessSecurityScopedResourceUrl = url
        self.ownsSecurityScope = true
        self.metadata = await Self.extractMetadata(from: url)
    }
    
    
    deinit {
        guard ownsSecurityScope else { return }
        autoAccessSecurityScopedResourceUrl.stopAccessingSecurityScopedResource()
    }
    
    
    /// Shared by both initializers so a metadata failure degrades the same way (item still usable, metadata absent) no matter how the item came to be
    private static func extractMetadata(from url: URL) async -> AsyncMetadata? {
        do {
            return try await .init(extractingMetadataFrom: url)
        }
        catch {
            log(error: error)
            return nil
        }
    }
}



extension MediaItem: Equatable {
    
    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}



// MARK: - Sugar

public extension AVPlayerItem {
    convenience init(_ mediaItem: MediaItem) {
        self.init(url: mediaItem.autoAccessSecurityScopedResourceUrl)
    }
}
