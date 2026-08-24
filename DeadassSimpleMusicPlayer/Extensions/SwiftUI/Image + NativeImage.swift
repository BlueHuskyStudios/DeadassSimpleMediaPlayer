//
//  Image + NativeImage.swift
//  Dead-Simple Media Player
//
//  Created by Ky directing Claude Opus 5 on 2026-08-14.
//

import SwiftUI

import CrossKitTypes



public extension Image {
    
    /// Creates a SwiftUI image from whichever image type this platform calls native.
    ///
    /// SwiftUI offers `init(uiImage:)` and `init(nsImage:)` but nothing spanning both, so this is the one place that has to know which platform it's on.
    init(nativeImage: NativeImage) {
        #if canImport(UIKit)
        self.init(uiImage: nativeImage)
        #else
        self.init(nsImage: nativeImage)
        #endif
    }
}
