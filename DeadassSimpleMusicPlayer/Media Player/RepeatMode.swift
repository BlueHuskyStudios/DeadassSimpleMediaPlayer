//
//  RepeatMode.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude 5 Fable on 2026-07-01.
//

import Foundation



/// What the player does when the current file finishes playing.
///
/// This belongs to the now-playing queue alone — it's a playback convenience, not user data, so it's never written into a saved playlist. It *is* part of the persisted queue snapshot, though, so quitting and relaunching doesn't forget that you were looping.
public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    
    /// Play through the queue once, then stop
    case off
    
    /// After the last item in the queue, continue from the first
    case wholeQueue
    
    /// Replay the current file until told otherwise
    case currentItem
}
