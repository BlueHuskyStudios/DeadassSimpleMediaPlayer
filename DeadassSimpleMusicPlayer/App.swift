//
//  App.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import SwiftUI
import TipKit

import SimpleLogging



@main
struct App: SwiftUI.App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    do {
                        #if DEBUG
//                        Tips.showAllTipsForTesting()
                        try Tips.resetDatastore()
                        #endif
                        try Tips.configure([.displayFrequency(.monthly)])
                    }
                    catch {
                        log(error: error, "Error initializing TipKit")
                    }
                }
        }
    }
}
