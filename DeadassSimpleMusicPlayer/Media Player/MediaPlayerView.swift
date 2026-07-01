//
//  MediaPlayerView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import AVKit
import Combine
import MediaPlayer
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

import CollectionTools
import SimpleLogging



/// An all-in-one media player for SwiftUI
struct MediaPlayerView: View {
    
    // MARK: API
    
    /// The URL pointing to the media currently being played
    @Binding
    var currentPlaylist: Playlist
    
    @State
    var currentPlaylistItemIndex: Int = 0
    
    
    // MARK: Private state
    
    @available(iOS, deprecated)
    @State
    private var previousMediaItem: MediaItem?
    
    @State
    private var currentMediaMetadata: AsyncMetadata? = nil
    
    @State
    private var isPlaying = false
    
    @State
    private var player = AVPlayer()
    
    @State
    private var sinks: Set<AnyCancellable> = []
    
    @State
    private var forceUpdateBodge = Bool()
    
    @State
    private var pipStatus = Player.PipStatus.undefined
    
    
    // MARK: `View`
    
    var body: some View {
        baseBodyAndChangeReactions
        
        .onAppear {
            player.publisher(for: \.rate).sink { rate in
                isPlaying = rate > 0
            }
            .store(in: &sinks)
            
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            
            
            NotificationCenter.default
                .publisher(for: AVAudioSession.interruptionNotification)
                .sink { notification in
                    guard let interruptTypeNum = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
                          let interruptType =  AVAudioSession.InterruptionType.init(rawValue: interruptTypeNum.uintValue)
                    else { return }
                    
                    switch interruptType {
                    case .began:
                        print("Interrupt began")
                        
                    case .ended:
                        print("Interrupt ended")
                        
                    @unknown default:
                        print("Fancy New Interrupt They Don't Want You To Know About", interruptType)
                    }
                 }
                .store(in: &sinks)
        }
        
        
        .onReceive(currentMediaMetadata?.onMetadataDidUpdate()) { _ in
            setupNowPlaying()
            log(info: "Metadata updated")
        }
        
        
        .onDisappear {
            UIApplication.shared.endReceivingRemoteControlEvents()
        }
    }
}



private extension MediaPlayerView {
    @inline(__always)
    var currentMediaItem: MediaItem? {
        currentPlaylist.currentEntry?.mediaItem
    }
}



// MARK: - Older-OS support

private extension MediaPlayerView {
    
    @ViewBuilder
    var baseBodyAndChangeReactions: some View {
        VStack {
            playerView
            metadataView
        }
        
        
        .onChange(of: currentMediaItem, initial: true) { old, new in
            prepareNewMedia(from: new)
        }
        
        
        .onChange(of: isPlaying) { oldValue, isPlaying in
            guard oldValue != isPlaying else { return }
            
            if isPlaying {
                player.play()
                
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
            else {
                player.pause()
            }
        }
    }
}


// MARK: - Subviews

private extension MediaPlayerView {
    
    var metadataView: some View {
        VStack(alignment: .leading, spacing: 0) {
//            Spacer(minLength: 0)
//                .layoutPriority(1)
//            
//            Rectangle()
//                .fill(Color.clear)
//                .aspectRatio(16/9, contentMode: .fit)
//                .layoutPriority(1)
            
            VStack(alignment: .leading, spacing: 0) {
                Text(titleText)
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(.primary) // not strictly necessary, but I wanted to explicitly call out the relationship to the next Text down
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text(creatorText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize()
                
                Spacer(minLength: 0)
                    .layoutPriority(1)
            }
            .padding(.horizontal)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
    }
    
    
    var playerView: some View {
        Player(player: player, pipStatus: $pipStatus)
            .aspectRatio(16/9, contentMode: .fit)
    }
}



// MARK: - Responding to the uesr

private extension MediaPlayerView {
    func prepareNewMedia(from newItem: MediaItem?) {
        
        currentMediaMetadata = newItem?.metadata
        
        guard let newItem else {
            player.replaceCurrentItem(with: nil)
            UIApplication.shared.endReceivingRemoteControlEvents()
            return
        }
        
        player.replaceCurrentItem(with: .init(newItem))
        player.seek(to: .zero)
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
        }
        catch {
            log(error: error)
        }
    }
}



// MARK: - Metadata

private extension MediaPlayerView {
    
    /// Returns the current state of searching for the given metadata, including the found metadata itself
    ///
    /// - Parameter key: Identifies the metadata you want
    func metadata<Value>(_ key: AsyncMetadataKey<Value>) -> MetadataSearchResult<Value>? {
        guard nil != currentMediaItem else { return nil }
        switch currentMediaMetadata?.get(key) {
        case .none:                return .none
        case .notStarted:          return .notStarted
        case .loading:             return .loading
        case .success(let value):  return .success(value)
        case .failure(let cause):  return .failure(cause)
        }
    }
    
    
    var titleText: LocalizedStringKey {
        switch metadata(.title) {
        case .none: nil == currentMediaItem ? "Pick something to play :3" : ""
        case .notStarted: "…"
        case .loading: "⋯"
        case .success(let value): "\(value)"
        case .failure(_): // If we ever add more possible error cases than NotFound, this needs updating
            (currentMediaItem?.autoAccessSecurityScopedResourceUrl.deletingPathExtension().lastPathComponent.nonEmptyOrNil).map { "\($0)" } ?? "Untitled"
        }
    }
    
    
    var creatorText: LocalizedStringKey {
        switch metadata(.creator) {
        case .none: ""
        case .notStarted: "⋯"
        case .loading: "…"
        case .success(let value): "\(value)"
        case .failure(_): ""
        }
    }
}



// MARK: - Control Center, Live Activites, Dynamic Island, etc.

private extension MediaPlayerView {
    func setupRemoteTransportControls() {
        // Get the shared MPRemoteCommandCenter
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Add handler for Play Command
        commandCenter.playCommand.addTarget { event in
            isPlaying = true
            
            return isPlaying
                ? .commandFailed
                : .success
        }
        
        // Add handler for Pause Command
        commandCenter.pauseCommand.addTarget { event in
            isPlaying = false
            
            return isPlaying
                ? .success
                : .commandFailed
        }
    }
    
    
    func setupNowPlaying() {
        // Define Now Playing Info
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata(.title)

        if let image = try? metadata(.image)?.value ?? nil { //??nil can't believe I still have to battle auto-double-optionals
            nowPlayingInfo[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            
            
        }
//        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playerItem.currentTime().seconds
//        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = playerItem.asset.duration.seconds
//        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate

        // Set the metadata
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        forceUpdateBodge.toggle()
    }
}



// MARK: - Previews

#Preview("Nothing playing") {
    NavigationStack {
        MediaPlayerView(currentPlaylist: .constant(.empty))
    }
}
