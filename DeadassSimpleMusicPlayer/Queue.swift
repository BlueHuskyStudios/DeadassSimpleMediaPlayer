//
//  Queue.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-13.
//

import Foundation

//import SafeCollectionAccess
//
//
//
//public struct TransparentResettableQueue<Element> {
//    fileprivate var storage: Storage
//    fileprivate var currentposition: Storage.Index
//    
//    
//    
//    fileprivate typealias Storage = [Element]
//}
//
//
//
//public extension Queue {
//    
//    @inlinable
//    mutating func append(_ newElement: Element) {
//        storage.append(newElement)
//    }
//}
//
//
//
//// MARK: - `Sequence`
//
//extension Queue: Sequence {
//    public typealias Iterator = Self
//}
//
//
//
//extension Queue: IteratorProtocol {
//    public mutating func next() -> Element? {
//        defer { currentposition = storage.index(after: currentposition) }
//        return storage[orNil: currentposition]
//    }
//}
