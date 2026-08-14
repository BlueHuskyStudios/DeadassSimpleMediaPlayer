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
import CrossKitTypes
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
    
    /// Watches the current `AVPlayerItem` for its time changing discontinuously (a seek), so remote controls can be told where the playhead actually landed. Replaced whenever the item is; dropping the old sink is what unsubscribes it.
    ///
    /// The system extrapolates elapsed time from the last-published value and the playback rate, and a seek changes elapsed time *without* changing the rate — so a seek is invisible to that extrapolation until something republishes.
    @State
    private var itemTimeJumpSink: AnyCancellable? = nil
    
    /// The current item's duration once it's known, or `nil` while it's still being determined.
    ///
    /// Loaded explicitly rather than read from `AVPlayerItem.duration`, which reports `.indefinite` until the item becomes ready — publishing that to remote controls is what produces a track with no progress bar.
    @State
    private var currentItemDuration: TimeInterval? = nil
    
    /// Cover art to show where video would be. Only ever non-`nil` for media which has no video of its own; video always wins the screen.
    @State
    private var currentArtwork: NativeImage? = nil
    
    /// Whether the current item carries its own video. Assumed `true` until inspection proves otherwise, so cover art can never flash over the opening frames of an actual video.
    @State
    private var currentItemHasVideoTrack = true
    
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
            setupRemoteTransportControls()
            
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
            refreshArtwork()
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
            
            // The published rate is what the system extrapolates elapsed time from, so it has to change when playback does or the remote progress bar keeps advancing through a paused track
            updateNowPlayingPlaybackPosition()
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
        Player(player: player, artwork: currentArtwork, pipStatus: $pipStatus)
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
        currentItemDuration = nil // The previous track's duration must not survive into this one's Now Playing info
        currentArtwork = nil // Likewise the previous track's cover art
        currentItemHasVideoTrack = true // Assumed until proven otherwise, so art can't flash over a video's first frames
        
        let shouldResumePlayback = session.takePlaybackIntent()
        
        guard let newItem else {
            itemEndSink = nil
            itemTimeJumpSink = nil
            itemReadinessObservation?.invalidate()
            itemReadinessObservation = nil
            player.replaceCurrentItem(with: nil)
            setupNowPlaying()
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
        
        // Scoped to this item for the same reason, so a seek is never attributed to a track which has since been replaced
        itemTimeJumpSink = NotificationCenter.default
            .publisher(for: AVPlayerItem.timeJumpedNotification, object: playerItem)
            .map { _ in }
            .receive(on: DispatchQueue.main)
            .sink {
                updateNowPlayingPlaybackPosition()
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
        
        // Published immediately with whatever's known so far, so remote controls never sit on the previous track's info (or their own "Unknown Artist" placeholders) while metadata resolves. Each metadata update pings this again to fill in the rest.
        setupNowPlaying()
        
        Task {
            guard let duration = try? await playerItem.asset.load(.duration),
                  duration.seconds.isFinite,
                  playerItem === player.currentItem // The queue may have moved on while this loaded
            else { return }
            
            currentItemDuration = duration.seconds
            setupNowPlaying()
        }
        
        // Cover art belongs only where video doesn't, so the asset's tracks decide whether art is allowed through at all
        Task {
            let videoTracks = (try? await playerItem.asset.loadTracks(withMediaType: .video)) ?? []
            
            guard playerItem === player.currentItem else { return }
            
            currentItemHasVideoTrack = !videoTracks.isEmpty
            refreshArtwork()
        }
    }
    
    
    /// Pulls the current media's cover art out of its metadata, but only for media with no video of its own.
    ///
    /// Media with no embedded art falls back to the app's own placeholder, so the player region always has something deliberate in it — which is also what lets that region be drawn opaque, hiding `AVPlayerViewController`'s default audio placeholder underneath.
    ///
    /// Called both when the video-track inspection finishes and whenever metadata updates, since either can be the last to arrive.
    func refreshArtwork() {
        guard !currentItemHasVideoTrack else {
            currentArtwork = nil // Video fills this region itself; nothing should be drawn over it
            return
        }
        
        currentArtwork = ((try? metadata(.image)?.value) ?? nil)
            ?? .placeholderArt
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
        
        // Cleared first: the command center is a long-lived shared singleton, so re-running this would otherwise stack duplicate handlers on top of the old ones
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        // These capture `player` rather than this view's `isPlaying`, because the handlers outlive any given value of this struct, and because driving the player directly lets the existing `rate` observer sync `isPlaying` back the same way an in-app tap would
        
        // Add handler for Play Command
        commandCenter.playCommand.addTarget { [player] event in
            guard 0 == player.rate else { return .commandFailed } // Already playing
            player.play()
            return .success
        }
        
        // Add handler for Pause Command
        commandCenter.pauseCommand.addTarget { [player] event in
            guard 0 != player.rate else { return .commandFailed } // Already paused
            player.pause()
            return .success
        }
        
        // Add handler for Toggle Play/Pause Command, which is what headphone buttons and many car head units send instead of the discrete commands above
        commandCenter.togglePlayPauseCommand.addTarget { [player] event in
            if 0 == player.rate {
                player.play()
            }
            else {
                player.pause()
            }
            return .success
        }
        
        // Add handler for scrubbing from Control Center, the Lock Screen, or the Dynamic Island. This app publishes its own Now Playing info (see `Player.updatesNowPlayingInfoCenter`), so it owns the commands that go with it — without this, the remote scrubber would move and then snap back. The resulting seek fires `timeJumpedNotification`, which republishes the new position.
        commandCenter.changePlaybackPositionCommand.addTarget { [player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            
            player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
            return .success
        }
    }
    
    
    func setupNowPlaying() {
        guard let currentMediaItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        // Built fresh rather than read-modify-written from the existing dictionary: inheriting the previous track's entries means any key *this* track lacks silently keeps showing the last track's value
        var nowPlayingInfo = [String : Any]()
        
        if let title = ((try? metadata(.title)?.value) ?? nil)
            ?? currentMediaItem.autoAccessSecurityScopedResourceUrl.deletingPathExtension().lastPathComponent.nonEmptyOrNil
        {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }
        
        if let artist = (try? metadata(.creator)?.value) ?? nil {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }
        
        if let album = (try? metadata(.album)?.value) ?? nil {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }
        
        if let trackNumber = (try? metadata(.trackNumber)?.value) ?? nil {
            nowPlayingInfo[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
        }

        // Unlike the player, this falls back to the placeholder even for video: Control Center and the Lock Screen have no video to show in that slot, so the app's own art beats an empty square
        if let image = ((try? metadata(.image)?.value) ?? nil) ?? .placeholderArt {
            // `@Sendable` is load-bearing, per Apple DTS: MPMediaItemArtwork retains this closure and calls it on an arbitrary thread, so without it the closure inherits this view's MainActor isolation and traps when the system asks for the image.
            nowPlayingInfo[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            
            
        }
        
        if let currentItemDuration {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = currentItemDuration
        }
        
        addPlaybackPositionInfo(to: &nowPlayingInfo)

        // Set the metadata
        Task { @MainActor in
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            
            forceUpdateBodge.toggle()
        }
    }
    
    
    /// Republishes only where playback currently is, leaving already-published metadata untouched.
    ///
    /// Seeking and pausing don't change the title, artist, or album — and rewriting those unchanged values is actively harmful rather than merely wasteful: iOS throttles Now Playing *metadata* updates (logging "Application exceeded audio metadata throttle limit"), and a throttled title write is **dropped**, not deferred. Republishing the whole dictionary on every seek is what makes the title and artist visibly blank out and reappear while scrubbing from Control Center.
    func updateNowPlayingPlaybackPosition() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return // Nothing published yet, so there's no position to correct — a full publish will happen when media loads
        }
        
        addPlaybackPositionInfo(to: &nowPlayingInfo)
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    
    /// Writes where playback is and how fast it's moving. Shared so a full publish and a position-only update can never disagree about what "current position" means.
    func addPlaybackPositionInfo(to nowPlayingInfo: inout [String : Any]) {
        // The system extrapolates elapsed time from the last-published value and the rate, so these two are what make a progress bar appear and move at all. Published on load, on play/pause, and on seek — deliberately *not* on a timer, since frequent writes get throttled during long background playback and go stale without warning.
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        else {
            nowPlayingInfo.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
    }
}



// MARK: - Previews

#Preview("Nothing playing") {
    NavigationStack {
        MediaPlayerView(currentPlaylist: .constant(.empty), session: PlayerSession(persisting: false))
    }
}
