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
import UIKit

import SimpleLogging



/// An all-in-one media player for SwiftUI
struct MediaPlayerView: View {
    
    // MARK: API
    
    /// The URL pointing to the media currently being played
    @Binding
    var currentMediaUrl: URL?
    
    
    // MARK: Private state
    
    @available(iOS, deprecated: 17)
    @State
    private var previousMediaUrl: URL?
    
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
    private var pipStatus = AVMediaPlayer.PipStatus.undefined
    
    
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



// MARK: - Older-OS support

private extension MediaPlayerView {
    
    @ViewBuilder
    var baseBodyAndChangeReactions: some View {
        if #available(iOS 17.0, *) {
            ZStack {
                metadataView
                
                playerView
            }
            
            
            .onChange(of: currentMediaUrl) { oldUrl, newUrl in
                oldUrl?.stopAccessingSecurityScopedResource()
                prepareNewMedia(from: newUrl)
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
        else {
            ZStack {
                metadataView
                
                playerView
            }
            
            
            .onChange(of: currentMediaUrl) { newUrl in
                previousMediaUrl?.stopAccessingSecurityScopedResource()
                defer { previousMediaUrl = newUrl }
                prepareNewMedia(from: newUrl)
            }
            
            
            .onChange(of: isPlaying) { isPlaying in
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
}


// MARK: - Subviews

private extension MediaPlayerView {
    
    var metadataView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
                .layoutPriority(1)
            
            Rectangle()
                .fill(Color.clear)
                .aspectRatio(16/9, contentMode: .fit)
                .layoutPriority(1)
            
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
        AVMediaPlayer(player: player, pipStatus: $pipStatus)
            .aspectRatio(16/9, contentMode: .fit)
    }
}



// MARK: - Responding to the uesr

private extension MediaPlayerView {
    func prepareNewMedia(from newUrl: URL?) {
        
        currentMediaMetadata = nil
        
        guard let newUrl else {
            player.replaceCurrentItem(with: nil)
            UIApplication.shared.endReceivingRemoteControlEvents()
            return
        }
        
        guard newUrl.startAccessingSecurityScopedResource() else {
            print("oops can't")
            return
        }
        
        player.replaceCurrentItem(with: .init(url: newUrl))
        player.seek(to: .zero)
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
        }
        catch {
            log(error: error)
        }
        
        
        Task { [self] in
            guard let asset = self.player.currentItem?.asset else { return }
            do {
                let metadata = try await asset.asyncMetadata()
                self.currentMediaMetadata = metadata
                metadata.onMetadataDidUpdate().sink {
                    forceUpdateBodge.toggle()
                }
                .store(in: &sinks)
            }
            catch {
                log(error: error)
            }
        }
    }
}



// MARK: - Metadata

private extension MediaPlayerView {
    
    /// Returns the current state of searching for the given metadata, including the found metadata itself
    ///
    /// - Parameter key: Identifies the metadata you want
    func metadata<Value>(_ key: AsyncMetadataKey<Value>) -> MetadataSearchResult<Value>? {
        guard nil != currentMediaUrl else { return nil }
        switch currentMediaMetadata?.get(key) {
        case nil, .stillSearching: return .stillSearching
        case .found(let value):    return .found(value: value)
        case .notFound:            return .notFound
        }
    }
    
    
    var titleText: LocalizedStringKey {
        switch metadata(.title) {
        case .stillSearching: "..."
        case .found(value: let value): "\(value)"
        case .none: nil == currentMediaUrl ? "Pick something to play :3" : ""
        case .notFound:
            if let currentMediaUrl {
                "\(currentMediaUrl.deletingPathExtension().lastPathComponent)"
            }
            else {
                "Untitled"
            }
        }
    }
    
    
    var creatorText: LocalizedStringKey {
        switch metadata(.creator) {
        case .stillSearching: "..."
        case .found(let value): "\(value)"
        case .notFound: ""
        case nil: ""
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

        if let image = metadata(.image)?.value ?? nil {
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

#Preview {
    NavigationStack {
        MediaPlayerView(currentMediaUrl: .constant(nil))
    }
}
