//
//  ArtworkThumbnailCache.swift
//  Dead-Simple Media Player
//
//  Created by Ky directing Claude Opus 5 on 2026-08-14.
//

import AVFoundation
import Foundation
import Observation

import CrossKitTypes
import SimpleLogging



/// Loads small cover-art renditions for list rows, remembering both what it found and what it didn't.
///
/// Rows ask for a thumbnail synchronously (getting `nil` the first time) and start the load in a `.task`; when it lands, Observation redraws the row.
///
/// Absence is cached as deliberately as presence. Files with no embedded art are common, and without remembering the misses, every one of them would redo the whole read every time its row scrolled back into view.
///
/// This type is `@MainActor` because its only job is feeding a view — but **nothing expensive happens here.** All of it belongs to ``ThumbnailRenderer``, and only a finished thumbnail crosses back.
@MainActor
@Observable
public final class ArtworkThumbnailCache {
    
    /// The art found so far, keyed by the file it came from
    private var thumbnails: [MediaReference: NativeImage] = [:]
    
    /// Files already looked at, whether or not they turned out to have art. This is what stops art-less files from being retried forever.
    private var alreadyAttempted: Set<MediaReference> = []
    
    /// Does all the reading and decoding, on its own executor
    private let renderer: ThumbnailRenderer
    
    
    /// - Parameter maxPixelSize: How large, in pixels, the longest side of a produced thumbnail may be.
    ///     Expressed in pixels rather than points on purpose: this type has no business reaching for the screen it'll be drawn on, and over-decoding slightly is harmless at this size.
    ///     The default covers a 44pt row on a 3× display, which is the largest current devices ask for.
    public init(maxPixelSize: Int = 44 * 3) {
        self.renderer = ThumbnailRenderer(maxPixelSize: maxPixelSize)
    }
    
    
    /// The already-loaded thumbnail for this file, or `nil` if there isn't one — either because none has been loaded yet, or because the file has no art.
    ///
    /// Safe and cheap to call from a view body; reading it is what subscribes the view to the eventual result.
    public func thumbnail(for reference: MediaReference) -> NativeImage? {
        thumbnails[reference]
    }
    
    
    /// Loads this file's cover art if it hasn't already been tried. Call from a row's `.task`.
    ///
    /// Claiming the file in `alreadyAttempted` *before* suspending is what makes concurrent calls for the same file collapse into one, so a list of rows all asking at once still reads each file only once.
    public func loadThumbnailIfNeeded(for reference: MediaReference) async {
        guard alreadyAttempted.insert(reference).inserted else { return }
        
        guard let thumbnail = await renderer.thumbnail(for: reference) else {
            // Cancellation gets its claim released; a genuine "no art here" keeps it, so the file is never opened twice
            if Task.isCancelled {
                alreadyAttempted.remove(reference)
            }
            return
        }
        
        thumbnails[reference] = thumbnail
    }
    
    
    /// Loads art for the first of the given files which has any.
    ///
    /// For an album, whose tracks share one cover, this avoids opening every track just to draw one row: it stops at the first that yields art, so a well-formed album resolves on its first track.
    public func loadFirstAvailableThumbnail(among references: some Sequence<MediaReference>) async {
        for reference in references {
            await loadThumbnailIfNeeded(for: reference)
            
            if nil != thumbnails[reference] {
                return
            }
        }
    }
    
    
    /// The first already-loaded thumbnail among the given files, if any
    public func firstThumbnail(among references: some Sequence<MediaReference>) -> NativeImage? {
        references.lazy.compactMap { self.thumbnails[$0] }.first
    }
}



/// Produces cover-art thumbnails, guaranteed to be away from the main actor.
///
/// Being an `actor` is the entire point: actor-isolated work runs on the actor's own executor no matter who calls it. `nonisolated async` would have been the lighter-looking choice, but its meaning is changing — under Swift 6.2's approachable-concurrency defaults, a `nonisolated async` function runs on its *caller's* actor, which would put every bit of this back on the main thread the day that setting is enabled, silently and with no diagnostic.
///
/// This deliberately reads the asset directly instead of going through ``MediaItem`` and ``AsyncMetadata``. That path is right for playback — it caches per key, republishes to SwiftUI, and holds a security scope for as long as the item lives — but every one of those services costs something here, and one of them, the main-actor ping it installs per search, is precisely what must not happen once per row.
private actor ThumbnailRenderer {
    
    /// The longest side, in pixels, of a thumbnail this renderer produces
    private let maxPixelSize: Int
    
    
    init(maxPixelSize: Int) {
        self.maxPixelSize = maxPixelSize
    }
    
    
    /// Reads the given file's embedded cover art and decodes it at thumbnail size.
    ///
    /// - Returns: The thumbnail, or `nil` if the file couldn't be reached, has no cover art, or has art which couldn't be decoded — all of which are ordinary, and none of which are worth distinguishing to a caller that would only draw a placeholder either way.
    func thumbnail(for reference: MediaReference) async -> NativeImage? {
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
        
        guard let assetMetadata = try? await AVURLAsset(url: url).load(.metadata) else {
            return nil
        }
        
        // The one place artwork identifiers are listed is the metadata key itself, so this can't drift from what the rest of the app considers cover art
        let artworkIdentifiers = AsyncMetadataKey.image.identifiers
        
        guard let artworkMetadata = assetMetadata.first(where: { item in
                  guard let identifier = item.identifier else { return false }
                  return artworkIdentifiers.contains(identifier)
              }),
              let data = try? await artworkMetadata.load(.dataValue)
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
