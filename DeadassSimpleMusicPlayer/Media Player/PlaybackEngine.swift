//
//  PlaybackEngine.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude Fable 5.1 on 2026-09-06.
//

import AVFoundation
import Combine
import MediaPlayer
import Observation

#if canImport(UIKit)
import UIKit
#endif

import CollectionTools
import CrossKitTypes
import SimpleLogging



/// What a ``PlaybackEngine`` reports to whoever composed it.
///
/// The engine knows how to play one item and nothing about what should happen next; these are the moments where something with more context (a queue, a history) gets to decide. All calls arrive on the main actor.
@MainActor
public protocol PlaybackEngineDelegate: AnyObject {
    
    /// The loaded item played all the way to its end. The engine now rests at the end of that item; nothing plays until told to.
    func playbackEngine(_ engine: PlaybackEngine, didFinishPlaying item: MediaItem)
    
    /// Where playback currently is in the loaded item. Called about twice a second while an item is loaded, whether or not it's playing.
    func playbackEngine(_ engine: PlaybackEngine, playbackPositionDidChangeTo seconds: TimeInterval)
    
    /// Playback went from moving to stopped — by the user, a remote command, an interruption, or reaching the end. A moment the user implicitly expects their place to be remembered.
    func playbackEngineDidPause(_ engine: PlaybackEngine)
}



/// The live machinery for playing exactly one media item well.
///
/// Owns one `AVPlayer`, and everything that item needs to behave like a real citizen of the platform without anyone else lifting a finger: remote transport commands (Control Center, Lock Screen, headphone buttons), Now Playing info, background audio, restored playback positions, cover art where video isn't. This is what makes ``MediaPlayerView`` a batteries-included drop-in — and because it lives here rather than in a view, the batteries keep working no matter which view (if any) is on screen.
///
/// It knows nothing about playlists, queues, or repeat modes. When an item finishes, the engine simply reports it through its ``delegate`` and rests; whatever holds the queue decides what plays next and calls ``load(_:resumingAt:autoplay:)`` again.
///
/// **State flows one way.** Every observable fact here (``isPlaying``, ``currentTime``, ``duration``, …) is written only by the engine's own observers of the `AVPlayer`. To *change* playback, call a method — ``play()``, ``pause()``, ``seek(to:)`` — which drives the player, and the fact updates when the player actually changes. Nothing outside this type writes `isPlaying`, so it can never disagree with what the player is doing.
///
/// Expected to be a singleton per process in practice: the remote command center and Now Playing info center are process-wide, so two engines would fight over them.
@MainActor
@Observable
public final class PlaybackEngine {
    
    // MARK: Facts
    
    /// What's loaded right now, or `nil` when nothing is
    public private(set) var currentItem: MediaItem? = nil
    
    /// Whether playback is moving. Mirrors the player's rate; written nowhere but the rate observer.
    public private(set) var isPlaying = false
    
    /// Where playback is in the current item, in seconds. Updated about twice a second while an item is loaded, and immediately after a seek.
    public private(set) var currentTime: TimeInterval = 0
    
    /// The current item's duration once it's known, or `nil` while it's still being determined (or when nothing is loaded).
    ///
    /// Loaded explicitly rather than read from `AVPlayerItem.duration`, which reports `.indefinite` until the item becomes ready — publishing that to remote controls is what produces a track with no progress bar.
    public private(set) var duration: TimeInterval? = nil
    
    /// Cover art to show where video would be. Only ever non-`nil` for media which has no video of its own; video always wins the screen.
    public private(set) var artwork: NativeImage? = nil
    
    /// Whether the current item carries its own video. Assumed `true` until inspection proves otherwise, so cover art can never flash over the opening frames of an actual video.
    public private(set) var hasVideoTrack = true
    
    /// Bumped every time the current item's metadata resolves another field. Read by ``metadata(_:)`` so that any `body` calling it re-renders when the answer changes — `AsyncMetadata`'s own lookups aren't tracked by Observation.
    private var metadataRevision: UInt = 0
    
    
    // MARK: Machinery
    
    /// The player itself. Exposed so a view can put its video on screen; drive playback through this engine's methods rather than the player directly, so the engine's facts stay true.
    public let player = AVPlayer()
    
    /// Who to tell when something happens that this engine can't decide about on its own
    @ObservationIgnored
    public weak var delegate: (any PlaybackEngineDelegate)? = nil
    
    /// Subscriptions that live as long as this engine does
    @ObservationIgnored
    private var sinks: Set<AnyCancellable> = []
    
    /// Republishes the current item's metadata updates into ``metadataRevision`` and Now Playing info. Replaced whenever the item is.
    @ObservationIgnored
    private var metadataSink: AnyCancellable? = nil
    
    /// Watches the current `AVPlayerItem` for playing to its end, so the delegate can advance a queue. Replaced whenever the item is; dropping the old sink is what unsubscribes it.
    @ObservationIgnored
    private var itemEndSink: AnyCancellable? = nil
    
    /// Watches the current `AVPlayerItem` for its time changing discontinuously (a seek), so remote controls can be told where the playhead actually landed. Replaced whenever the item is; dropping the old sink is what unsubscribes it.
    ///
    /// The system extrapolates elapsed time from the last-published value and the playback rate, and a seek changes elapsed time *without* changing the rate — so a seek is invisible to that extrapolation until something republishes.
    @ObservationIgnored
    private var itemTimeJumpSink: AnyCancellable? = nil
    
    /// Waits for the current `AVPlayerItem` to become ready, so a restored playback position can be applied at a moment the item will actually honor it (seeks issued earlier are ignored or rejected outright).
    ///
    /// Direct KVO rather than Combine's KVO publisher: this is the canonical, battle-tested readiness pattern, chosen after the publisher approach failed to restore positions in practice. Must be retained for its lifetime; invalidated & replaced whenever the item is.
    @ObservationIgnored
    private var itemReadinessObservation: NSKeyValueObservation? = nil
    
    /// Opaque token for the player's periodic time observer, held for the engine's lifetime
    @ObservationIgnored
    private var periodicTimeObserverToken: Any? = nil
    
    
    /// Creates an engine with nothing loaded, and installs everything process-wide that playback needs: remote command handlers, the periodic time observer, background-playback policy, and the interruption observer.
    public init() {
        installRateObserver()
        installPeriodicTimeObserver()
        installInterruptionObserver()
        installRemoteTransportControls()
        
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }
}



// MARK: - Commands

public extension PlaybackEngine {
    
    /// Loads an item into the player, replacing whatever was there.
    ///
    /// Everything the previous item established is cleared first — duration, art, video-track knowledge, and the per-item observers — so nothing from the last track can bleed into this one's Now Playing info.
    ///
    /// - Parameters:
    ///   - item:      What to load, or `nil` to unload the player entirely
    ///   - seconds:   Where to start from, in seconds. Applied only once the item is ready to honor it; `nil` starts from the beginning.
    ///   - autoplay:  Whether to start playing as soon as the item is loaded
    func load(_ item: MediaItem?, resumingAt seconds: TimeInterval? = nil, autoplay: Bool) {
        currentItem = item
        duration = nil // The previous track's duration must not survive into this one's Now Playing info
        artwork = nil // Likewise the previous track's cover art
        hasVideoTrack = true // Assumed until proven otherwise, so art can't flash over a video's first frames
        currentTime = 0
        
        itemEndSink = nil
        itemTimeJumpSink = nil
        metadataSink = nil
        itemReadinessObservation?.invalidate()
        itemReadinessObservation = nil
        
        guard let item else {
            player.replaceCurrentItem(with: nil)
            publishNowPlayingInfo()
            UIApplication.shared.endReceivingRemoteControlEvents()
            return
        }
        
        let playerItem = AVPlayerItem(item)
        
        // Subscribed per-item (with the item as the notification's object) so finishing can never be misattributed to whatever item happens to be current when the notification lands
        itemEndSink = NotificationCenter.default
            .publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem)
            .map { _ in } // Reduced to Void before crossing queues: the payload isn't needed, and Void is trivially Sendable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                delegate?.playbackEngine(self, didFinishPlaying: item)
            }
        
        // Scoped to this item for the same reason, so a seek is never attributed to a track which has since been replaced
        itemTimeJumpSink = NotificationCenter.default
            .publisher(for: AVPlayerItem.timeJumpedNotification, object: playerItem)
            .map { _ in }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                currentTime = player.currentTime().seconds
                updateNowPlayingPlaybackPosition()
            }
        
        // Each resolved metadata field refreshes both what views can read and what the system shows
        metadataSink = item.metadata?.onMetadataDidUpdate()
            .sink { [weak self] in
                guard let self else { return }
                metadataRevision &+= 1
                publishNowPlayingInfo()
                refreshArtwork()
                log(info: "Metadata updated")
            }
        
        player.replaceCurrentItem(with: playerItem)
        
        if let seconds {
            log(info: "Holding a restored playback position of \(seconds)s until the item becomes ready")
            
            let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
            
            itemReadinessObservation = playerItem.observe(\.status, options: [.initial, .new]) { [player] item, _ in
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
        
        if autoplay {
            player.play()
        }
        
        // Published immediately with whatever's known so far, so remote controls never sit on the previous track's info (or their own "Unknown Artist" placeholders) while metadata resolves. Each metadata update pings this again to fill in the rest.
        publishNowPlayingInfo()
        
        Task { [self] in
            guard let duration = try? await playerItem.asset.load(.duration),
                  duration.seconds.isFinite,
                  playerItem === player.currentItem // The queue may have moved on while this loaded
            else { return }
            
            self.duration = duration.seconds
            publishNowPlayingInfo()
        }
        
        // Cover art belongs only where video doesn't, so the asset's tracks decide whether art is allowed through at all
        Task { [self] in
            let videoTracks = (try? await playerItem.asset.loadTracks(withMediaType: .video)) ?? []
            
            guard playerItem === player.currentItem else { return }
            
            hasVideoTrack = videoTracks.isNotEmpty
            refreshArtwork()
        }
    }
    
    
    /// Starts (or resumes) playback of the loaded item. Does nothing if nothing is loaded.
    func play() {
        player.play()
    }
    
    
    /// Pauses playback, leaving the playhead where it is
    func pause() {
        player.pause()
    }
    
    
    /// Pauses if playing, plays if paused — what headphone buttons and most car head units send
    func togglePlayPause() {
        if 0 == player.rate {
            player.play()
        }
        else {
            player.pause()
        }
    }
    
    
    /// Moves the playhead. The resulting time jump republishes the new position to remote controls on its own.
    /// - Parameter seconds: Where to go, in seconds from the start of the item
    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    
    
    /// Rewinds the loaded item to its beginning and plays it
    func replayFromStart() {
        player.seek(to: .zero)
        player.play()
    }
}



// MARK: - Metadata

public extension PlaybackEngine {
    
    /// Returns the current state of searching for the given metadata of the loaded item, including the found metadata itself.
    ///
    /// Reading this from a view's `body` is enough to re-render that view when the answer changes.
    ///
    /// - Parameter key: Identifies the metadata you want
    /// - Returns: The search's state, or `nil` if nothing is loaded
    func metadata<Value>(_ key: AsyncMetadataKey<Value>) -> MetadataSearchResult<Value>? {
        _ = metadataRevision // Registers the Observation dependency; see the property's doc
        
        guard let currentItem else { return nil }
        switch currentItem.metadata?.get(key) {
        case .none:                return .none
        case .notStarted:          return .notStarted
        case .loading:             return .loading
        case .success(let value):  return .success(value)
        case .failure(let cause):  return .failure(cause)
        }
    }
}



// MARK: - Observing the player

private extension PlaybackEngine {
    
    /// The one and only writer of ``isPlaying``. Also where the side effects of a play/pause transition live, regardless of who caused it (an in-app tap, a remote command, an interruption, the end of the file).
    func installRateObserver() {
        player.publisher(for: \.rate)
            .sink { [weak self] rate in
                guard let self else { return }
                
                let wasPlaying = isPlaying
                isPlaying = rate > 0
                
                guard wasPlaying != isPlaying else { return }
                
                if isPlaying {
                    UIApplication.shared.beginReceivingRemoteControlEvents()
                }
                else {
                    delegate?.playbackEngineDidPause(self)
                }
                
                // The published rate is what the system extrapolates elapsed time from, so it has to change when playback does or the remote progress bar keeps advancing through a paused track
                updateNowPlayingPlaybackPosition()
            }
            .store(in: &sinks)
    }
    
    
    /// Reports where playback is, both as ``currentTime`` and to the delegate — which is how a queue knows where to snapshot, and how history knows when a file has been played enough to count.
    func installPeriodicTimeObserver() {
        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            
            MainActor.assumeIsolated {
                self.currentTime = time.seconds
                self.delegate?.playbackEngine(self, playbackPositionDidChangeTo: time.seconds)
            }
        }
    }
    
    
    func installInterruptionObserver() {
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
    
    
    /// Pulls the current media's cover art out of its metadata, but only for media with no video of its own.
    ///
    /// Media with no embedded art falls back to the app's own placeholder, so the player region always has something deliberate in it — which is also what lets that region be drawn opaque, hiding `AVPlayerViewController`'s default audio placeholder underneath.
    ///
    /// Called both when the video-track inspection finishes and whenever metadata updates, since either can be the last to arrive.
    func refreshArtwork() {
        guard !hasVideoTrack else {
            artwork = nil // Video fills this region itself; nothing should be drawn over it
            return
        }
        
        artwork = (try? metadata(.image)?.value)
            ?? .placeholderArt
    }
}



// MARK: - Control Center, Live Activites, Dynamic Island, etc.

private extension PlaybackEngine {
    
    func installRemoteTransportControls() {
        // Get the shared MPRemoteCommandCenter
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Cleared first: the command center is a long-lived shared singleton, so re-running this would otherwise stack duplicate handlers on top of the old ones
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        // These capture `player` rather than this engine's `isPlaying`, because the handlers outlive any given value of that fact, and because driving the player directly lets the rate observer sync `isPlaying` back the same way an in-app tap would
        
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
    
    
    func publishNowPlayingInfo() {
        guard let currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        // Built fresh rather than read-modify-written from the existing dictionary: inheriting the previous track's entries means any key *this* track lacks silently keeps showing the last track's value
        var nowPlayingInfo = [String : Any]()
        
        if let title = ((try? metadata(.title)?.value) ?? nil)
            ?? currentItem.autoAccessSecurityScopedResourceUrl.deletingPathExtension().lastPathComponent.nonEmptyOrNil
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
            // `@Sendable` is load-bearing, per Apple DTS: MPMediaItemArtwork retains this closure and calls it on an arbitrary thread, so without it the closure inherits this engine's MainActor isolation and traps when the system asks for the image.
            nowPlayingInfo[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
        }
        
        if let duration {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        
        addPlaybackPositionInfo(to: &nowPlayingInfo)
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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
