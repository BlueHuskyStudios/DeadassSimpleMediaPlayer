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
    
    /// Artwork to show where video would appear, for media that has no video of its own. `nil` shows nothing, letting the system's default audio glyph show through.
    ///
    /// Hosted in the player controller's `contentOverlayView` — the layer between the video content and the playback controls — so the art never obscures (nor intercepts touches meant for) the transport controls.
    var artwork: UIImage? = nil
    
    /// The current picture-in-picture status of this player
    @Binding
    var pipStatus: PipStatus
    
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }
    
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        syncArtwork(in: uiViewController)
    }
    
    
    /// Idempotently reconciles the artwork image view inside the controller's content overlay: creates it on first need, updates it on change, removes it when there's nothing to show
    private func syncArtwork(in playerViewController: AVPlayerViewController) {
        guard let overlay = playerViewController.contentOverlayView else { return }
        
        let existingImageView = overlay.viewWithTag(Self.artworkViewTag) as? UIImageView
        
        guard let artwork else {
            existingImageView?.removeFromSuperview()
            return
        }
        
        let imageView: UIImageView
        
        if let existingImageView {
            imageView = existingImageView
        }
        else {
            imageView = UIImageView()
            imageView.tag = Self.artworkViewTag
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black // Cover the system audio glyph even where fitted art doesn't reach
            imageView.translatesAutoresizingMaskIntoConstraints = false
            
            overlay.addSubview(imageView)
            
            NSLayoutConstraint.activate([
                imageView.leadingAnchor .constraint(equalTo: overlay.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                imageView.topAnchor     .constraint(equalTo: overlay.topAnchor),
                imageView.bottomAnchor  .constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        
        if imageView.image !== artwork {
            imageView.image = artwork
        }
    }
    
    
    /// Identifies the artwork image view among the overlay's subviews across updates, so reconciliation never needs stored state in a value-type representable
    private static let artworkViewTag = 0xA47
    
    
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
