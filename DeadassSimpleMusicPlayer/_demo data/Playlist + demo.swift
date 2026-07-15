//
//  Playlist + demo.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-07-14.
//

import Foundation

import ConcurrencyTools



extension Playlist {
    static var demo: Self {
        Self.init(entries: .demo, currentEntryID: .preview)
    }
}



extension [Playlist.Entry] {
    static let demo: Self = [
            .init(id: .preview, reference: .init(bookmarkData: Data(), filename: "Whatever is currently playing.mp3"),
                  state: .ready(resync { await .init(url: .null)! })),
            
            .init(reference: .init(bookmarkData: Data(), filename: "Old lost music.midi"),
                  state: .unavailable),
        ]
        + [MediaReference].demo.map { reference in
                .init(reference: reference,
                      state: .ready(resync { await .init(url: .null)! }))
        }
}



extension [MediaReference] {
    static let demo: Self = (1...20).map { index in
            .init(bookmarkData: Data(), filename: "Demo track \(index).m4a")
        }
}



extension UUID {
    /// An ID suitable for use in temporary previews
    static let preview = Self()
}
