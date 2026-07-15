//
//  AVKit + Sendable.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-07-01.
//

import AVKit



#if compiler(>=6)
extension AVAsset: @unchecked @retroactive Sendable {}
extension AVMetadataItem: @unchecked @retroactive Sendable {}

/// Crossing concurrency domains here is confined to: created on main, mutated on main, KVO-observed with handlers that immediately hop back to main. AVFoundation itself is internally thread-safe for these types' documented operations.
extension AVPlayer: @unchecked @retroactive Sendable {}
extension AVPlayerItem: @unchecked @retroactive Sendable {}
#else
extension AVAsset: @unchecked Sendable {}
extension AVMetadataItem: @unchecked Sendable {}
extension AVPlayer: @unchecked Sendable {}
extension AVPlayerItem: @unchecked Sendable {}
#endif
