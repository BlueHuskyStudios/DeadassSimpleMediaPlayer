//
//  FileManager + concurrency.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2026-07-15.
//

import Foundation



// According to the official `FileManager` documentation:
// > The methods of the shared ``FileManager`` object can be called from multiple threads safely
extension FileManager: @retroactive @unchecked Sendable {}
