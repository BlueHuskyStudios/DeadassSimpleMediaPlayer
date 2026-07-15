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
        demo.queue = .demo
        demo.savedPlaylists = .demo
        demo.history = .demo
        return demo
    }
    #else
    static var demo: PlayerSession { fatalError("Not available in release builds") }
    #endif
}
