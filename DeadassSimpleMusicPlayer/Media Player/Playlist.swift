//
//  Playlist.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-13.
//

import Foundation

import BasicMathTools
import SafeCollectionAccess



/// For building a list of items to be played in a player
public struct Playlist: Sendable {
    
    /// The items in the playlist
    public var items: Items
    
    /// Points to the item in ``items`` which is currently being played (or paused or similar)
    public var currentItemIndex: Items.Index?
    
    
    
    public typealias Item = URL
    public typealias Items = [Item]
}



public extension Playlist {
    /// The currently-playing (or paused or similar) item in this playlist,  or `nil` if there is no current item
    var currentItem: Item? {
        items[orNil: currentItemIndex_orDefault]
    }
}



// MARK: - Queue behavior

public extension Playlist {
    /// Returns the expected next item to be played in this playlist,  or `nil` if there is no next item
    var peekNextItem: Item? {
        guard let nextIndex = peekNextItemIndex else { return nil }
        return items[orNil: nextIndex]
    }
    
    
    /// Changes the current item to be the next item
    ///
    /// - Returns: The new current item, or `nil` if there is no current item
    @discardableResult
    mutating func moveToNextItem() -> Element? {
        guard let nextIndex = peekNextItemIndex else { return nil }
        defer { currentItemIndex = nextIndex }
        return items[orNil: nextIndex]
    }
}



private extension Playlist {
    /// Returns the expected next index of an item to be played in this playlist
    var peekNextItemIndex: Items.Index? {
        if let currentItemIndex {
            if items.contains(index: currentItemIndex) {
                return items.index(after: currentItemIndex)
            }
            else {
                return nil
            }
        }
        else {
            return items.startIndex
        }
    }
    
    
    var currentItemIndex_orDefault: Items.Index {
        currentItemIndex ?? items.startIndex
    }
}



// MARK: - `Sequence`

extension Playlist: Sequence {
//    public typealias Iterator = Self
    public typealias Element = Item
}



extension Playlist: IteratorProtocol {
    @available(*, deprecated, renamed: "moveToNextItem", message: "To make the difference clear between moving the current index and just vieweing the next item, use the semantic version of this instead")
    @inline(__always)
    public mutating func next() -> Element? {
        moveToNextItem()
    }
}



// MARK: - Defaults

public extension Playlist {
    static let empty = Self(items: [])
}
