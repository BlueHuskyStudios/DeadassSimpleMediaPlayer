//
//  URL + UTType.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import Foundation
import UniformTypeIdentifiers



public extension URL {
    var typeIdentifier: UTType {
        UTType(filenameExtension: self.pathExtension) ?? .data
    }
    
    func conforms(to utType: UTType) -> Bool {
        typeIdentifier.conforms(to: utType)
    }
}
