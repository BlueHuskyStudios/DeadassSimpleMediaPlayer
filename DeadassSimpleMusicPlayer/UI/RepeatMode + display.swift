//
//  RepeatMode + display.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky directing Claude Sonnet 5 on 2026-09-06.
//

import SwiftUI



public extension RepeatMode {
    
    /// The localized text shown to the user which represents this repeat mode
    var displayName: LocalizedStringKey {
        switch self {
        case .off:         "Don't loop"
        case .wholeQueue:  "Loop all"
        case .currentItem: "Loop one"
        }
    }
    
    
    /// The name of the system image (SF Symbol) which will represent this repeat mode next to its item in the expanded menu
    var systemImageName_menuItem: String {
        switch self {
        case .off:         "forward.end"
        case .wholeQueue:  "repeat"
        case .currentItem: "repeat.1"
        }
    }
    
    
    /// The name of the system image (SF Symbol) which will represent this repeat mode in the toolbar when it's selected.
    ///
    /// That is to say, when this repeat mode is selected, then what this returns will be rendered as an icon in the toolbar
    var systemImageName_preview: String {
        switch self {
        case .off:         "repeat"
        case .wholeQueue:  "repeat.circle.fill"
        case .currentItem: "repeat.1.circle.fill"
        }
    }
}
