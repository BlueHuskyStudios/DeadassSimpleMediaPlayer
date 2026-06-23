//
//  Playlist.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-13.
//

import AsyncAlgorithms
import Foundation

import BasicMathTools
import SafeCollectionAccess
import SimpleLogging
import UniformTypeIdentifiers



/// For building a list of items to be played in a player
public struct Playlist: Sendable {
    
    /// The items in the playlist
    public var items: Items
    
    /// Points to the item in ``items`` which is currently being played (or paused or similar)
    public var currentItemIndex: Items.Index?
    
    
    
    public typealias Item = MediaItem
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
    
    // MARK: State Inspection
    
    /// Returns the expected next item to be played in this playlist,  or `nil` if there is no next item
    var peekNextItem: Item? {
        guard let nextIndex = peekNextItemIndex else { return nil }
        return items[orNil: nextIndex]
    }
    
    
    // MARK: Modification
    
    /// Adds the media at the given URL to this playlist.
    ///
    /// Currently, this only supports file URLs (`file://`).
    ///
    /// - Parameters:
    ///   - url:                  The URL containing the media to add, or a folder filled with them
    ///
    ///   - allowedContentTypes:  What kinds of things that are OK to add to this playlist. ``.audiocisualContent`` is always assumed to be OK
    ///
    ///   - allowMovingToNewItem: If `true`, then adding the item(s) can result in the ``currentItemIndex`` being moved to point to the first one this adds.
    ///                           If `false`, then this function will not change the ``currentItemIndex`` at all.
    ///                           Even if `true`, the index might not move (for example, if the current index is already pointing at a valid media item
    ///                           Defaults to `true`.
    ///
    ///   - allowRecursion:       Whether to allow this function to look inside sub-folders for more media to add.
    ///                           If `false`, this will only look at items directly in this folder, and not any deeper.
    ///                           If `true`, this will endlessly look deeper and deeper as long as there are more folders to expore. Be warned that this can cause a crash if there are recursive folders such as symlinks.
    ///                           Defaults to `false`.
    mutating func _add(fromUrl url: URL, allowedContentTypes: Set<UTType> = [.audiovisualContent, .directory], allowMovingToNewItem: Bool = true, allowRecursion: Bool = false)
    async
    {
        let fileManager = FileManager.default
        
        await url.accessSecurityScopedResource { (url) -> Void in
            
            let (exists: exists, isDirectory: isDirectory) = fileManager.fileExists(at: url)
            
            guard exists else {
                log(warning: "I was asked to add media from a URL which doesn't point to any file: \(url)")
                return
            }
            
            let itemsToAdd: Items
            
            if isDirectory {
                guard allowedContentTypes.contains(where: { $0.conforms(to: .directory) }) else {
                    log(verbose: "I was asked to add media from a folder, but wasn't allowed to: \(url)")
                    return
                }
                
                do {
                    itemsToAdd = try await fileManager
                        .contentsOfDirectory(at: url, contentTypes: allowedContentTypes, recursive: allowRecursion)
                        .async
                        .compactMap { url in
                            await Item(url: url)
                        }
//                        .sorted(by: { left, right in
//                            let  leftMetadata = left.metadata
//                            let rightMetadata = right.metadata
//                            leftMetadata?.get(.)
//                        })
                        .collect()
                }
                catch {
                    log(error: error)
                    return
                }
            }
            else {
                guard allowedContentTypes
                    .subtracting([.directory])
                    .contains(where: url.conforms),
                      let item = await Item(url: url)
                else {
                    log(info: "I was asked to add mediaa, but wasn't allowed to: \(url)")
                    return
                }
                
                itemsToAdd = [item]
            }
            
            let newCurrentIndex: Items.Index? =
                if !itemsToAdd.isEmpty,                      //     If we're adding new iems,
                    allowMovingToNewItem,                    // and if this function allows us to move the current-item pointer to them upon adding them,
                    let currentItemIndex,                    // and if there is a current index at all,
                    !items.contains(index: currentItemIndex) // and if the current index doesn't point to any playlist item,,
                {
                    items.endIndex                           // then set the new index to the old just-past-the-end index
                }
                else {
                    nil                                      // Otherwise, just leave the current index in the same position as before adding these items
                }
            
            items.append(contentsOf: itemsToAdd)
            
            if let newCurrentIndex {
                currentItemIndex = newCurrentIndex
            }
        }
        onFailure: {
            log(error: "I couldn't get the necessary permissions to read from this URL: \(url)")
        }
    }
    
    
    /// Appends pre-resolved items to this playlist and, optionally, advances
    /// the current-item pointer onto the first newly-appended item when the
    /// previous pointer was dangling.
    ///
    /// Synchronous on purpose: with no suspension point, this mutation is
    /// safe to invoke on `@State`-backed storage from any actor-isolated
    /// context. Pair with ``items(fromUrl:allowedContentTypes:allowRecursion:)``
    /// when the items originate from disk.
    mutating func append(
        contentsOf newItems: Items,
        allowMovingToNewItem: Bool = true
    ) {
        guard !newItems.isEmpty else { return }
        
        let shouldMovePointer =
        allowMovingToNewItem
        && currentItemIndex.map { !items.contains(index: $0) } ?? false
        
        if shouldMovePointer {
            currentItemIndex = items.endIndex
        }
        items.append(contentsOf: newItems)
    }
    
    
    mutating func append(
        _ newItem: Element,
        allowMovingToNewItem: Bool = true
    ) {
        let shouldMovePointer =
        allowMovingToNewItem
        && currentItemIndex.map { !items.contains(index: $0) } ?? false
        
        if shouldMovePointer {
            currentItemIndex = items.endIndex
        }
        items.append(newItem)
    }
    
    
    // MARK: Movement
    
    /// Changes the current item to be the next item
    ///
    /// - Returns: The new current item, or `nil` if there is no current item
    @discardableResult
    mutating func moveToNextItem() -> Element? {
        guard let nextIndex = peekNextItemIndex else { return nil }
        defer { currentItemIndex = nextIndex }
        return items[orNil: nextIndex]
    }
    
    
    
    static let defaultAllowedContentTypes: Set<UTType> = [.audiovisualContent, .directory, .folder]
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
