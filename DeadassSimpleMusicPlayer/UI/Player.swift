//
//  Player.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-06-18.
//

import AVKit
import SwiftUI

import CrossKitTypes



/// A UIKit/SwiftUI translation layer between ``AVPlayer`` and ``MediaPlayerView``
struct Player: UIViewControllerRepresentable {
    
    /// The player to shim into this UI layer
    let player: AVPlayer
    
    /// Cover art to show where video would be, for media which has none of its own. `nil` shows nothing, leaving the system's default audio appearance visible.
    var artwork: NativeImage? = nil
    
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
    
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        syncArtwork(in: uiViewController)
    }
    
    
    /// Reconciles the cover-art image view inside the controller's content overlay: creates it when first needed, updates it when the art changes, removes it when there's none.
    ///
    /// `contentOverlayView` is the layer between the video content and the playback controls, so art placed here can never cover the transport controls nor intercept touches meant for them. The view is found by tag rather than stored, since this representable is a value type recreated on every update.
    private func syncArtwork(in playerViewController: AVPlayerViewController) {
        guard let overlay = playerViewController.contentOverlayView else { return }
        
        let existingImageView = overlay.viewWithTag(Self.artworkViewTag) as? UIImageView
        
        guard let artwork else {
            existingImageView?.removeFromSuperview()
            return
        }
        
        guard let imageView = existingImageView ?? makeArtworkView(in: overlay) else { return }
        
        if imageView.image !== artwork {
            imageView.image = artwork
        }
    }
    
    
    private func makeArtworkView(in overlay: UIView) -> UIImageView? {
        let imageView = UIImageView()
        imageView.tag = Self.artworkViewTag
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        overlay.addSubview(imageView)
        
        NSLayoutConstraint.activate([
            imageView.leadingAnchor .constraint(equalTo: overlay.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            imageView.topAnchor     .constraint(equalTo: overlay.topAnchor),
            imageView.bottomAnchor  .constraint(equalTo: overlay.bottomAnchor),
        ])
        
        return imageView
    }
    
    
    /// Identifies the cover-art image view among the overlay's subviews across updates, since a value-type representable can't hold a reference to it
    private static let artworkViewTag = 0xA27
    
    
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
