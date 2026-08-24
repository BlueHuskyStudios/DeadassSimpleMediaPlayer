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
        syncArtwork(in: uiViewController, coordinator: context.coordinator)
    }
    
    
    /// Reconciles the cover-art image view inside the controller's content overlay: creates it when first needed, updates it when the art changes, removes it when there's none.
    ///
    /// `contentOverlayView` is the layer between the video content and the playback controls, so art placed here can never cover the transport controls nor intercept touches meant for them.
    ///
    /// The view is held by the coordinator rather than found among the overlay's subviews. This representable is a value type rebuilt on every update, so it can't hold the reference itself — but the coordinator survives across updates, which is exactly what it's for.
    private func syncArtwork(in playerViewController: AVPlayerViewController, coordinator: Coordinator) {
        guard let overlay = playerViewController.contentOverlayView else { return }
        
        guard let artwork else {
            coordinator.artworkImageView?.removeFromSuperview()
            coordinator.artworkImageView = nil
            return
        }
        
        let imageView = coordinator.artworkImageView ?? makeArtworkView(in: overlay, coordinator: coordinator)
        
        if imageView.image !== artwork {
            imageView.image = artwork
        }
    }
    
    
    private func makeArtworkView(in overlay: UIView, coordinator: Coordinator) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        // Opaque on purpose: the image view spans the whole overlay but its art is fitted inside, so without a fill, AVKit's own audio placeholder shows through the letterbox on either side. This matches the background the rest of the player screen already uses.
        imageView.backgroundColor = .secondarySystemBackground
        
        overlay.addSubview(imageView)
        
        NSLayoutConstraint.activate([
            imageView.leadingAnchor .constraint(equalTo: overlay.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            imageView.topAnchor     .constraint(equalTo: overlay.topAnchor),
            imageView.bottomAnchor  .constraint(equalTo: overlay.bottomAnchor),
        ])
        
        coordinator.artworkImageView = imageView
        
        return imageView
    }
    
    
    func makeCoordinator() -> Coordinator {
        Coordinator(pipStatus: $pipStatus)
    }
    
    
    
    /// Coordinates the status of the player between UIKit/AVKit and SwiftUI, and holds onto the views this representable can't
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        
        @Binding
        var pipStatus: PipStatus
        
        /// The cover-art view added to the player's content overlay, if there is one right now.
        ///
        /// Lives here because `Player` is a value type recreated on every update and can't keep a reference of its own, while this coordinator persists for as long as the player view does.
        var artworkImageView: UIImageView?
        
        init(pipStatus: Binding<PipStatus>) {
            self._pipStatus = pipStatus
        }
        
        func playerViewControllerWillStartPictureInPicture(_: AVPlayerViewController) { pipStatus = .willStart }
        func playerViewControllerDidStartPictureInPicture(_: AVPlayerViewController) { pipStatus = .inPip }
        func playerViewControllerWillStopPictureInPicture(_: AVPlayerViewController) { pipStatus = .willStop }
        func playerViewControllerDidStopPictureInPicture(_: AVPlayerViewController) { pipStatus = .notInPip }
    }
    
    
    
    /// Statuses of a player's picture-in-picture mode
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
