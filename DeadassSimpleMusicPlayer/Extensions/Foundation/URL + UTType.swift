//
//  URL + UTType.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import Foundation
import UniformTypeIdentifiers



public extension URL {
    /// The file system's own answer when available (which correctly types extensionless items, like folders); otherwise guessed from the path extension
    var contentType: UTType {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: self.pathExtension)
            ?? .data
    }
    
    func conforms(to utType: UTType) -> Bool {
        contentType.conforms(to: utType)
    }
}
