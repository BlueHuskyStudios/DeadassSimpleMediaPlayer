//
//  ArtworkThumbnailCache.swift
//  Dead-Simple Media Player
//
//  Created by Ky directing Claude Opus 5 on 2026-08-14.
//

import AVFoundation
import Foundation

import CrossKitTypes
import SimpleLogging



/// Loads small cover-art renditions for list rows, remembering both what it found and what it didn't.
///
/// Deliberately **not** `@Observable`, and deliberately not read from any view's `body`. Rows keep their own copy of whatever this hands them, so that one row's art arriving can't invalidate every other row that happens to share this cache. An earlier version got that wrong, and the re-render storm it caused was far more expensive than the loading it was meant to coordinate.
///
/// Being an `actor` also settles where the work happens: actor-isolated code runs on the actor's own executor no matter who calls it. `nonisolated async` would have looked lighter, but its meaning is changing — under Swift 6.2's approachable-concurrency defaults, a `nonisolated async` function runs on its *caller's* actor, which would silently put all of this back on the main thread the day that setting is enabled.
///
/// Absence is remembered as deliberately as presence. Files with no embedded art are common, and without remembering the misses, every one of them would be reopened each time its row came back into view.
public actor ArtworkThumbnailCache {
    
    /// The art found so far, keyed by the file it came from
    private var thumbnails: [MediaReference: NativeImage] = [:]
    
    /// Files already looked at, whether or not they turned out to have art. This is what stops art-less files from being retried forever.
    private var alreadyAttempted: Set<MediaReference> = []
    
    /// The longest side, in pixels, of a thumbnail this cache produces.
    ///
    /// Expressed in pixels rather than points on purpose: this type has no business reaching for the screen it'll be drawn on, and over-decoding slightly is harmless at this size.
    private let maxPixelSize: Int
    
    
    public init(maxPixelSize: Int = ArtworkThumbnailCache.defaultMaxPixelSize) {
        self.maxPixelSize = maxPixelSize
    }
    
    
    /// The height of one standard list row, in points. Thumbnails never need to be larger than the row they sit in.
    private static let standardRowHeightInPoints = 44
    
    /// The most pixels current devices pack into a point. Decoding for the densest screen means the same thumbnail stays sharp on every screen.
    private static let densestDisplayScale = 3
    
    /// Large enough for a standard row on the densest display available, which is the largest any current device asks for.
    public static let defaultMaxPixelSize = standardRowHeightInPoints * densestDisplayScale
    
    
    /// This file's cover art at thumbnail size, reading it only if it hasn't been read before.
    ///
    /// - Returns: The thumbnail, or `nil` if the file couldn't be reached, has no cover art, or has art which couldn't be decoded — none of which a caller drawing a placeholder needs told apart.
    public func thumbnail(for reference: MediaReference) async -> NativeImage? {
        if let alreadyLoaded = thumbnails[reference] {
            return alreadyLoaded
        }
        
        guard !alreadyAttempted.contains(reference) else {
            return nil // Looked at before and found nothing
        }
        
        // Safe to check and then insert as two steps rather than one: there's no `await` between them, so actor isolation guarantees no other call can slip in and claim this same file partway through
        alreadyAttempted.insert(reference)
        
        guard let thumbnail = await read(reference) else {
            // Cancellation releases its claim; a genuine "no art here" keeps it, so a file is never opened twice
            if Task.isCancelled {
                alreadyAttempted.remove(reference)
            }
            return nil
        }
        
        thumbnails[reference] = thumbnail
        return thumbnail
    }
    
    
    /// The cover art of the first of these files which has any.
    ///
    /// For an album, whose tracks share one cover, this avoids opening every track just to draw one row: it stops at the first that yields art, so a well-formed album resolves on its first track.
    public func firstAvailableThumbnail(among references: some Sequence<MediaReference> & Sendable) async -> NativeImage? {
        for reference in references {
            if let thumbnail = await thumbnail(for: reference) {
                return thumbnail
            }
            
            if Task.isCancelled {
                return nil // The row went away; don't keep opening this album's remaining tracks
            }
        }
        
        return nil
    }
    
    
    /// Reads the given file's embedded cover art and decodes it at thumbnail size.
    ///
    /// This reads the asset directly instead of going through ``MediaItem`` and ``AsyncMetadata``. That path is right for playback — it caches per key, republishes to SwiftUI, and holds a security scope for as long as the item lives — but every one of those services is a cost here, and one of them, the main-actor ping installed per search, is exactly what must not happen once per row.
    private func read(_ reference: MediaReference) async -> NativeImage? {
        guard let (url: url, isStale: _) = try? reference.resolve() else {
            return nil // The file moved or vanished; its row still shows, just without art
        }
        
        // Held only for this read, unlike `MediaItem`, which keeps its scope for as long as the item lives
        let ownsSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if ownsSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let assetMetadata = try? await AVURLAsset(url: url).load(.metadata, isolation: ArtworkLoadQueue.shared) else {
            return nil
        }
        
        // The one place artwork identifiers are listed is the metadata key itself, so this can't drift from what the rest of the app considers cover art
        let artworkIdentifiers = AsyncMetadataKey.image.identifiers
        
        guard let artworkMetadata = assetMetadata.first(where: { item in
                  guard let identifier = item.identifier else { return false }
                  return artworkIdentifiers.contains(identifier)
              }),
              let data = try? await artworkMetadata.load(.dataValue, isolation: ArtworkLoadQueue.shared)
        else {
            return nil // No embedded art
        }
        
        guard let thumbnail = NativeImage.thumbnail(fromEncoded: data, maxPixelSize: maxPixelSize) else {
            log(warning: "Cover art found for “\(reference.filename)”, but it couldn't be decoded")
            return nil
        }
        
        return thumbnail
    }
}



/// The executor that cover-art loading runs on.
///
/// Exists because SwiftUI's `.task { }` inherits main-actor isolation from `View.body`, so work started there runs on the main thread unless something explicitly says otherwise. Annotating a task with this global actor is that "otherwise": it moves bookmark resolution, asset reading, and image decoding off the main thread, where a `dispatchPrecondition(condition: .notOnQueue(.main))` inside the load confirms they land.
///
/// Being a single serial actor also caps how much of this work happens at once, which matters because decoding several full-size covers concurrently costs far more memory than doing them one after another.
@globalActor
internal final actor ArtworkLoadQueue: GlobalActor {
    public static let shared = ActorType()
    
    public typealias ActorType = ArtworkLoadQueue
}
