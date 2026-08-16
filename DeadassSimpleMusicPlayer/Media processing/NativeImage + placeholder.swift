//
//  NativeImage + placeholder.swift
//  Dead-Simple Media Player
//
//  Created by Ky directing Claude Opus 5 on 2026-08-14.
//

import CrossKitTypes



public extension NativeImage {
    
    /// The name of the app's stand-in cover art in the asset catalog.
    ///
    /// Kept as a constant so there's exactly one string to change if the asset is ever renamed.
    static let placeholderArtAssetName = "Placeholder artwork 2026-1"
    
    
    /// The app's own artwork, shown in place of cover art for media which carries none.
    ///
    /// `nil` when the asset isn't in the catalog, so every caller degrades to showing nothing rather than the app failing to build or crashing over a missing image. Deliberately not force-unwrapped for that reason.
    static let placeholderArt: NativeImage? = {
        #if canImport(UIKit)
        NativeImage(named: placeholderArtAssetName)
        #else
        NativeImage(named: NativeImage.Name(placeholderArtAssetName))
        #endif
    }()
}
