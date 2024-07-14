//
//  FileManager + URL.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-07-14.
//

import Foundation



public extension FileManager {
    
    func fileExists(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory = ObjCBool(Bool())
        let exists = fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return (exists: exists, isDirectory: isDirectory.boolValue)
    }
    
    
    func fileExists(at url: URL) -> Bool {
        fileExists(at: url).exists
    }
    
    
    func isDirectory(at url: URL) -> Bool {
        fileExists(at: url).isDirectory
    }
}
