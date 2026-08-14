//
//  ArtworkThumbnailCache.swift
//  Dead-Simple Media Player
//
//  Created by Ky directing Claude Opus 5 on 2026-08-14.
//

import Foundation
import Observation

import CrossKitTypes
import SimpleLogging



/// Loads small cover-art renditions for list rows, remembering both what it found and what it didn't.
///
/// Getting cover art for a row is genuinely expensive — resolve a bookmark, enter a security scope, open the asset, search its metadata, decode an image — so it happens once per file and the answer is kept. Rows ask for a thumbnail synchronously (getting `nil` the first time) and kick off the load in a `.task`; when it lands, Observation redraws the row.
///
/// Absence is cached as deliberately as presence. Files with no embedded art are common, and without remembering the misses, every one of them would re-do that whole chain every time its row scrolled back into view.
@MainActor
@Observable
public final class ArtworkThumbnailCache {
    
    /// The art found so far, keyed by the file it came from
    private var thumbnails: [MediaReference: NativeImage] = [:]
    
    /// Files already looked at, whether or not they turned out to have art. This is what stops art-less files from being retried forever.
    private var alreadyAttempted: Set<MediaReference> = []
    
    /// How large, in pixels, the longest side of a produced thumbnail may be.
    ///
    /// Expressed in pixels rather than points on purpose: this type has no business reaching for the screen it'll be drawn on, and over-decoding slightly is harmless at this size. The default covers a 44pt row on a 3× display, which is the largest current devices ask for.
    private let maxPixelSize: Int
    
    
    public init(maxPixelSize: Int = 44 * 3) {
        self.maxPixelSize = maxPixelSize
    }
    
    
    /// The already-loaded thumbnail for this file, or `nil` if there isn't one — either because none has been loaded yet, or because the file has no art.
    ///
    /// Safe and cheap to call from a view body; reading it is what subscribes the view to the eventual result.
    public func thumbnail(for reference: MediaReference) -> NativeImage? {
        thumbnails[reference]
    }
    
    
    /// Loads this file's cover art if it hasn't already been tried. Call from a row's `.task`.
    ///
    /// Does nothing on a second call for the same file, so re-scrolling a list costs nothing.
    public func loadThumbnailIfNeeded(for reference: MediaReference) async {
        guard alreadyAttempted.insert(reference).inserted else { return }
        
        guard let item = await MediaItem(resolving: reference) else {
            return // The file moved or vanished; its row still shows, just without art
        }
        
        guard let metadata = item.metadata,
              let data = (try? await metadata.get(.imageData)) ?? nil
        else {
            return // No embedded art. Remembered as attempted, so this file won't be opened again.
        }
        
        guard let thumbnail = NativeImage.thumbnail(fromEncoded: data, maxPixelSize: maxPixelSize) else {
            log(warning: "Cover art found for “\(reference.filename)”, but it couldn't be decoded")
            return
        }
        
        thumbnails[reference] = thumbnail
    }
    
    
    /// The first thumbnail available among the given files, loading as needed.
    ///
    /// For an album, whose tracks share one cover, this avoids opening every track just to draw one row: it stops at the first track that yields art. Tracks are tried in order, so a well-formed album resolves on its first.
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
