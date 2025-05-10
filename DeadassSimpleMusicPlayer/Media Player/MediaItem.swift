//
//  MediaItem.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import Foundation

import LazyContainers



public struct MediaItem: Sendable {
    public let url: URL
    
    @Lazy
    private var metadata: AsyncMetadata?
    
    init(url: URL) {
        self.url = url
        self.metadata = nil
        
        Task {
            self.metadata = .init(extractingMetadataFrom: url)
        }
    }
}
