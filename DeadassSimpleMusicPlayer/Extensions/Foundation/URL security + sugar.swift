//
//  URL security + sugar.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import Foundation



public extension URL {
    /// Assuming this URL was created by resolving bookmark data created within some security scope, this function allows you to access the resource referenced by the URL within the ``accessor`` callback
    ///
    /// This calls ``startAccessingSecurityScopedResource()`` and ``stopAccessingSecurityScopedResource()`` automatically as needed; you don't need to worry about calling those within the ``accessor`` block. In fact, calling those within the ``accessor`` block may cause problematic behavior.
    ///
    /// - Parameters:
    ///   - accessor:  Called when it's safe to access the resource at this URL
    ///    - self: The URL that's safe to access
    ///   - onFailure: Called if the request to access the resource at this URL failed
    /// - Returns: Whatever the callbacks return
    func accessSecurityScopedResource<Return>(_ accessor: (_ self: Self) -> Return, onFailure: () -> Return) -> Return {
        let didStart = startAccessingSecurityScopedResource()
        if didStart {
            defer { stopAccessingSecurityScopedResource() }
            return accessor(self)
        }
        else {
            return onFailure()
        }
    }
}
