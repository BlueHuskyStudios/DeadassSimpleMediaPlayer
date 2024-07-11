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
#else
extension AVAsset: @unchecked Sendable {}
extension AVMetadataItem: @unchecked Sendable {}
#endif
