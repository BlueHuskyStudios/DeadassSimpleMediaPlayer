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
    
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    
    @Environment(\.verticalSizeClass)
    private var verticalSizeClass
    
    // MARK: API
    
    /// The URL pointing to the media currently being played
    @Binding
    var currentPlaylist: Playlist
    
    /// Owns playback policy & durable state: repeat behavior, play history, and session persistence. This view reports playback events to it and consults it for what finishing a file means.
    let session: PlayerSession
    
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
    
    /// Watches the current `AVPlayerItem` for playing to its end, so the queue can advance. Replaced whenever the item is; dropping the old sink is what unsubscribes it.
    @State
    private var itemEndSink: AnyCancellable? = nil
    
    /// Waits for the current `AVPlayerItem` to become ready, so a restored playback position can be applied at a moment the item will actually honor it (seeks issued earlier are ignored or rejected outright).
    ///
    /// Direct KVO rather than Combine's KVO publisher: this is the canonical, battle-tested readiness pattern, chosen after the publisher approach failed to restore positions in practice. Must be retained for its lifetime; invalidated & replaced whenever the item is.
    @State
    private var itemReadinessObservation: NSKeyValueObservation? = nil
    
    /// Opaque token for the player's periodic time observer, held only so registration happens exactly once
    @State
    private var periodicTimeObserverToken: Any? = nil
    
    
    // MARK: `View`
    
    var body: some View {
        baseBodyAndChangeReactions
        
        .onAppear {
            player.publisher(for: \.rate).sink { rate in
                isPlaying = rate > 0
            }
            .store(in: &sinks)
            
            // One observer serves two jobs: reporting position (for session restore) and noticing when the history threshold is crossed. `onAppear` can fire more than once in a view's life, so registration is guarded to happen exactly once.
            if nil == periodicTimeObserverToken {
                periodicTimeObserverToken = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                    queue: .main
                ) { [session] time in
                    MainActor.assumeIsolated {
                        session.notePlaybackPosition(seconds: time.seconds)
                        
                        if time.seconds >= PlayerSession.historyThresholdSeconds {
                            session.recordCurrentEntryInHistoryIfNeeded()
                        }
                    }
                }
            }
            
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
            
            if !useFullscreenUi {
                metadataView
            }
        }
        .background(Color(.systemGray6))
        .background(ignoresSafeAreaEdges: .all)
        
        
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
                
                // Pausing is a moment the user implicitly expects their place to be remembered
                session.saveNowPlayingSnapshotNow()
            }
        }
    }
    
    
    private var useFullscreenUi: Bool {
        switch (width: horizontalSizeClass, height: verticalSizeClass) {
        case (width: _, height: .none),
            (width: _, height: .regular):
            false
            
        case (width: _, height: .compact):
            true
            
        @unknown default:
            false
        }
    }
}


// MARK: - Subviews

private extension MediaPlayerView {
    
    var metadataView: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleView
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(.primary) // not strictly necessary, but I wanted to explicitly call out the relationship to the next Text down
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
//                .border(.red)
            
            Text(creatorText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize()
//                .border(.red)
            
            Spacer(minLength: 0)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
//        .border(.blue)
    }
    
    
    var playerView: some View {
        Player(player: player, pipStatus: $pipStatus)
            .aspectRatio(16/9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .layoutPriority(2)
            .ignoresSafeArea(.container, edges: useFullscreenUi ? .top : [])
    }
}



// MARK: - Responding to the uesr

private extension MediaPlayerView {
    func prepareNewMedia(from newItem: MediaItem?) {
        
        currentMediaMetadata = newItem?.metadata
        
        let shouldResumePlayback = session.takePlaybackIntent()
        
        guard let newItem else {
            itemEndSink = nil
            itemReadinessObservation?.invalidate()
            itemReadinessObservation = nil
            player.replaceCurrentItem(with: nil)
            UIApplication.shared.endReceivingRemoteControlEvents()
            return
        }
        
        let playerItem = AVPlayerItem(newItem)
        
        // Subscribed per-item (with the item as the notification's object) so finishing can never be misattributed to whatever item happens to be current when the notification lands
        itemEndSink = NotificationCenter.default
            .publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem)
            .map { _ in } // Reduced to Void before crossing queues: the payload isn't needed, and Void is trivially Sendable
            .receive(on: DispatchQueue.main)
            .sink {
                currentItemDidFinishPlaying()
            }
        
        player.replaceCurrentItem(with: playerItem)
        
        itemReadinessObservation?.invalidate()
        itemReadinessObservation = nil
        
        if let restoredSeconds = session.takePendingRestoredSeek(forEntryWithID: currentPlaylist.currentEntry?.id) {
            log(info: "Holding a restored playback position of \(restoredSeconds)s until the item becomes ready")
            
            let targetTime = CMTime(seconds: restoredSeconds, preferredTimescale: 600)
            
            itemReadinessObservation = playerItem.observe(\.status, options: [.initial, .new]) { item, _ in
                guard .readyToPlay == item.status else { return }
                
                Task { @MainActor in
                    log(info: "Item is ready; applying the restored playback position")
                    let seekFinished = await player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    log(info: "Restored-position seek \(seekFinished ? "completed" : "was interrupted by another seek")")
                }
            }
        }
        else {
            player.seek(to: .zero)
        }
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
        }
        catch {
            log(error: error)
        }
        
        if shouldResumePlayback {
            player.play()
        }
    }
    
    
    /// The current file played all the way to its end; what happens next is the repeat mode's call.
    ///
    /// Also the safety net for the history threshold: a file too short to ever cross ``PlayerSession/historyThresholdSeconds`` earns its history place by finishing instead.
    func currentItemDidFinishPlaying() {
        session.recordCurrentEntryInHistoryIfNeeded()
        
        switch session.repeatMode {
        case .currentItem:
            replayCurrentItemFromStart()
            
        case .wholeQueue:
            if nil != currentPlaylist.moveToNextEntry(wrapping: true) {
                session.requestPlaybackOnNextLoad()
            }
            else {
                // Wrapping with nowhere else to go (the queue's only playable entry is this one) still means "start over"
                replayCurrentItemFromStart()
            }
            
        case .off:
            if nil != currentPlaylist.moveToNextEntry(wrapping: false) {
                session.requestPlaybackOnNextLoad()
            }
            // Otherwise the queue is finished, and the player rests at the end of the final file
        }
    }
    
    
    func replayCurrentItemFromStart() {
        player.seek(to: .zero)
        player.play()
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
    
    
    @ViewBuilder
    var titleView: some View {
        if let loadingMessage = session.loadingMessage {
            HStack {
                ProgressView()
                Text(LocalizedStringKey(loadingMessage.key))
                    .foregroundStyle(.secondary)
            }
        }
        else {
            Text({
                switch metadata(.title) {
                case .none: nil == currentMediaItem ? "Pick something to play :3" : ""
                case .notStarted: "…"
                case .loading: "⋯"
                case .success(let value): "\(value)"
                case .failure(_): // If we ever add more possible error cases than NotFound, this needs updating
                    (currentMediaItem?.autoAccessSecurityScopedResourceUrl.deletingPathExtension().lastPathComponent.nonEmptyOrNil).map { "\($0)" } ?? "Untitled"
                }
            }())
        }
    }
    
    
    var creatorText: LocalizedStringKey {
        guard nil == session.loadingMessage else { return "" }
        
        return switch metadata(.creator) {
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
        
        if let title = ((try? metadata(.title)?.value) ?? nil)
            ?? currentMediaItem?.autoAccessSecurityScopedResourceUrl.deletingPathExtension().lastPathComponent.nonEmptyOrNil
        {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }
        else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyTitle)
        }

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
        MediaPlayerView(currentPlaylist: .constant(.empty), session: PlayerSession(persisting: false))
    }
}
