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
    
    /// Whether this instance started (and so must stop) its URL's security scope, versus inheriting access from an already-active parent scope. See ``init(url:)``.
    private let ownsSecurityScope: Bool
    
    public let metadata: AsyncMetadata?
    
    
    /// Creates a live item from a URL freshly granted by the system file picker, or enumerated from within an already-opened folder.
    ///
    /// Fails only if the system can't create a bookmark for the file. Notably, `startAccessingSecurityScopedResource()` returning `false` is *not* failure: children enumerated from a folder whose scope is already active legitimately return `false` (they have no scope token of their own; the parent's covers them), so that result only decides whether this item must call the matching `stop` later. Bookmark failure is treated as item failure on purpose: it preserves the invariant that every live item is persistable, which keeps every layer above this one simpler than "persistable, usually".
    ///
    /// Items covered only by a parent folder's scope would stop being readable the moment that scope closes (it only lives as long as the import call) — so such items immediately trade up to standalone access by resolving their own just-created bookmark, which on iOS re-grants access in its own right.
    init?(url: URL) async {
        var url = url
        var ownsSecurityScope = url.startAccessingSecurityScopedResource()
        
        let reference: MediaReference
        do {
            reference = try MediaReference(bookmarking: url)
        }
        catch {
            log(error: error)
            if ownsSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            return nil
        }
        
        if !ownsSecurityScope {
            if let (standaloneUrl, _) = try? reference.resolve() {
                ownsSecurityScope = standaloneUrl.startAccessingSecurityScopedResource()
                url = standaloneUrl
            }
            else {
                log(warning: "Couldn't gain standalone access to \(reference.filename); it will only be playable while its folder's access lasts")
            }
        }
        
        self.reference = reference
        self.ownsSecurityScope = ownsSecurityScope
        self.autoAccessSecurityScopedResourceUrl = url
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
        
        // Not a guard: on iOS, resolving the bookmark is itself what re-grants access — the system can report `false` here even when the file is perfectly readable — so this result only decides whether this item must call the matching `stop` later. Resolution throwing (above) is the real access-failure signal.
        let ownsSecurityScope = url.startAccessingSecurityScopedResource()
        
        var bestReference = reference
        if isStale,
           let freshened = try? MediaReference(bookmarking: url)
        {
            bestReference = freshened
        }
        bestReference.filename = url.lastPathComponent // The file may have been renamed since we last saw it
        
        self.reference = bestReference
        self.ownsSecurityScope = ownsSecurityScope
        self.autoAccessSecurityScopedResourceUrl = url
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
