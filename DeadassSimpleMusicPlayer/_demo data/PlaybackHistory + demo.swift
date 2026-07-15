//
//  PlaybackHistory + demo.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2026-07-15.
//

import Foundation



extension PlaybackHistory {
    static var demo: PlaybackHistory {
        PlaybackHistory(entries: .demo)
    }
}



extension [PlaybackHistory.Entry] {
    static let demo: Self = [Playlist.Entry].demo.map { playlistEntry in
            .init(
                id: playlistEntry.id,
                reference: playlistEntry.reference,
                displayName: playlistEntry.reference.displayName,
                playedAt: Date.now.addingTimeInterval(.random(in: -1 ... 0) * 60 * 60 * 24 * 7))
        }
        .sorted(by: { $0.playedAt < $1.playedAt })
}
