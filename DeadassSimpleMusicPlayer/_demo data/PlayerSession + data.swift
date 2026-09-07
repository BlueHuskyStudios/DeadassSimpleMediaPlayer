//
//  PlayerSession + data.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-07-14.
//

import Foundation



extension PlayerSession {
    #if DEBUG
    static var demo: PlayerSession {
        let demo = Self.init(persisting: false)
        demo.nowPlaying.queue = .demo
        demo.library.savedPlaylists = .demo
        demo.history.playbackHistory = .demo
        return demo
    }
    #else
    static var demo: PlayerSession { fatalError("Not available in release builds") }
    #endif
}
