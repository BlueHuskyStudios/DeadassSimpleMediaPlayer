//
//  AVMediaPlayer.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2024-06-18.
//

import AVKit
import SwiftUI



struct AVMediaPlayer: UIViewControllerRepresentable {
    
    let player: AVPlayer
    
    @Binding
    var pipStatus: PipStatus
    
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) { }
    
    
    func makeCoordinator() -> Coordinator {
        Coordinator(pipStatus: $pipStatus)
    }
    
    
    
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        
        @Binding
        var pipStatus: PipStatus
        
        init(pipStatus: Binding<PipStatus>) {
            self._pipStatus = pipStatus
        }
        
        func playerViewControllerWillStartPictureInPicture(_: AVPlayerViewController) { pipStatus = .willStart }
        func playerViewControllerDidStartPictureInPicture(_: AVPlayerViewController) { pipStatus = .didStart }
        func playerViewControllerWillStopPictureInPicture(_: AVPlayerViewController) { pipStatus = .willStop }
        func playerViewControllerDidStopPictureInPicture(_: AVPlayerViewController) { pipStatus = .didStop }
    }
    
    
    
    enum PipStatus {
        case undefined
        case willStart
        case didStart
        case willStop
        case didStop
    }
}
