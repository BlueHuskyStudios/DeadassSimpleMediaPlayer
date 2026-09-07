//
//  RepeatMode + display.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude Sonnet 5 on 2026-09-06.
//

import SwiftUI



public extension RepeatMode {
    
    var displayName: LocalizedStringKey {
        switch self {
        case .off:         "Don't loop"
        case .wholeQueue:  "Loop all"
        case .currentItem: "Loop one"
        }
    }
    
    
    var systemImageName_menuItem: String {
        switch self {
        case .off:         "forward.end"
        case .wholeQueue:  "repeat"
        case .currentItem: "repeat.1"
        }
    }
    
    
    var systemImageName_preview: String {
        switch self {
        case .off:         "repeat"
        case .wholeQueue:  "repeat.circle.fill"
        case .currentItem: "repeat.1.circle.fill"
        }
    }
}
