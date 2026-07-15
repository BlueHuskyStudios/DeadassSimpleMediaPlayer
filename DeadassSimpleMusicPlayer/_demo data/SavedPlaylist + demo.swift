//
//  SavedPlaylist + demo.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2026-07-15.
//

import Foundation



extension [SavedPlaylist] {
    static let demo: Self = (1...3).map { index in
            .init(name: "Demo playlist #\(index)", items: .demo)
        }
}
