//
//  NativeImage + thumbnail.swift
//  Dead-Simple Media Player
//
//  Created by Ky directing Claude Opus 5 on 2026-08-14.
//

import CoreGraphics
import Foundation
import ImageIO

import CrossKitTypes
import SimpleLogging



public extension NativeImage {
    
    /// Decodes the given encoded image bytes directly at thumbnail size.
    ///
    /// This never materializes the full-size bitmap: ImageIO reads the encoded data and produces a rendition no larger than `maxPixelSize` on its longest side. That distinction matters a great deal for cover art, which is routinely 3000×3000 — decoding one at full size costs tens of megabytes, and a list of them costs hundreds.
    ///
    /// - Parameters:
    ///   - data:         The still-encoded bytes of an image (JPEG, PNG, whatever ImageIO recognizes)
    ///   - maxPixelSize: The largest the result may be along its longest side, in *pixels* — so callers displaying at a point size should multiply by the screen's scale
    /// - Returns: The downsampled image, or `nil` if the bytes couldn't be read as an image
    static func thumbnail(fromEncoded data: Data, maxPixelSize: Int) -> NativeImage? {
        // `kCGImageSourceShouldCache: false` because the full-size decode is exactly what we're avoiding; nothing should be cached at that size on our behalf
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, // Embedded thumbnails, where present, are often too small or absent entirely
            kCGImageSourceCreateThumbnailWithTransform: true, // Honor the source's orientation rather than handing back a sideways cover
            kCGImageSourceShouldCacheImmediately: true, // Decode now, on this background call, rather than lazily during a scroll
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize, // Load-bearing: without it, ImageIO produces a thumbnail the size of the full image, which is the whole thing we're avoiding
        ] as CFDictionary
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        
        return .fromCoreGraphics(cgImage)
    }
}



private extension NativeImage {
    
    /// Bridges a `CGImage` into whichever image type this platform calls native.
    ///
    /// Deliberately *not* named `init(cgImage:)`: `UIImage` already declares exactly that, so an extension of the same name would call itself rather than the platform's.
    static func fromCoreGraphics(_ cgImage: CGImage) -> NativeImage {
        #if canImport(UIKit)
        NativeImage(cgImage: cgImage)
        #else
        NativeImage(cgImage: cgImage, size: .init(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
