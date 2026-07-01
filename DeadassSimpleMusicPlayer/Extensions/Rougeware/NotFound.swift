//
//  NotFound.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-06-23.
//

import Foundation



/// A simple error indicating that something wasn't found
public struct NotFound {
    init() {}
}



extension NotFound: LocalizedError {
    public var errorDescription: String? {
        "Not found"
    }
}



public extension NotFound {
    
    /// Just returns an instance of this type
    @inline(__always)
    static var notFound: Self { .init() }
}



extension NotFound: Equatable {
    @inline(__always)
    public static func == (lhs: Self, rhs: Self) -> Bool {
        true
    }
    
    
    @inline(__always)
    public static func ~= (lhs: Self, rhs: Self) -> Bool {
        true
    }
}
