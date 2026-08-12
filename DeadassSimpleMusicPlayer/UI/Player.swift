//
//  Player.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-06-18.
//

import AVKit
import SwiftUI



/// A UIKit/SwiftUI translation layer between ``AVPlayer`` and ``MediaPlayerView``
struct Player: UIViewControllerRepresentable {
    
    /// The player to shim into this UI layer
    let player: AVPlayer
    
    /// The current picture-in-picture status of this player
    @Binding
    var pipStatus: PipStatus
    
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        
        // Left on, this publishes its own Now Playing info whenever playback state changes, clobbering ours — the user sees the real metadata blink out to just the app name on every pause and scrub, then blink back when we rewrite it. This app publishes richer info (artist, album, track number) than AVKit can derive on its own, so ours wins and we own the matching remote commands.
        vc.updatesNowPlayingInfoCenter = false
        
        return vc
    }
    
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) { }
    
    
    func makeCoordinator() -> Coordinator {
        Coordinator(pipStatus: $pipStatus)
    }
    
    
    
    /// Coordinates the status of the player between UIKit/AVKit and SwiftUI
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        
        @Binding
        var pipStatus: PipStatus
        
        init(pipStatus: Binding<PipStatus>) {
            self._pipStatus = pipStatus
        }
        
        func playerViewControllerWillStartPictureInPicture(_: AVPlayerViewController) { pipStatus = .willStart }
        func playerViewControllerDidStartPictureInPicture(_: AVPlayerViewController) { pipStatus = .inPip }
        func playerViewControllerWillStopPictureInPicture(_: AVPlayerViewController) { pipStatus = .willStop }
        func playerViewControllerDidStopPictureInPicture(_: AVPlayerViewController) { pipStatus = .notInPip }
    }
    
    
    
    /// Statuses of a plaayer's picture-in-picture mode
    enum PipStatus {
        
        /// PIP status isn't known
        case undefined
        
        /// About to start transitioning from embedded player to PIP player
        case willStart
        
        /// Already started playing within PIP player
        case inPip
        
        /// About to start transitioning from PIP player to embedded player (or background player)
        case willStop
        
        /// Playing via embedded player (or background player)
        case notInPip
    }
}
