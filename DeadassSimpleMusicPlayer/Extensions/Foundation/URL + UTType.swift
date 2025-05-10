//
//  URL + UTType.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import Foundation
import UniformTypeIdentifiers



public extension URL {
    var contentType: UTType {
        UTType(filenameExtension: self.pathExtension) ?? .data
    }
    
    func conforms(to utType: UTType) -> Bool {
        contentType.conforms(to: utType)
    }
}
