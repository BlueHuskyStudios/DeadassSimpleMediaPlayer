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



/// Encapsulates a media item: its URL, automatic security-scoped access, and metadata
public final actor MediaItem: Sendable {
    private nonisolated let id = UUID()
    
    public let autoAccessSecurityScopedResourceUrl: URL
    
    public let metadata: AsyncMetadata?
    
    init?(url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            log(error: "Failed to access the media item as a security-scoped resource: \(url)")
            return nil
        }
        self.autoAccessSecurityScopedResourceUrl = url
        
        do {
            self.metadata = try await .init(extractingMetadataFrom: url)
        }
        catch {
            self.metadata = nil
            log(error: error)
        }
    }
    
    
    deinit {
        autoAccessSecurityScopedResourceUrl.stopAccessingSecurityScopedResource()
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
