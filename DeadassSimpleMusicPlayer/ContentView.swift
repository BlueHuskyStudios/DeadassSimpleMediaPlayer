//
//  ContentView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import SwiftUI



struct ContentView: View {
    
    @State
    private var showFileBrowser = false
    
    @State
    private var currentMediaUrl: URL? = nil
    
    var body: some View {
        NavigationStack {
            MediaPlayerView(currentMediaUrl: $currentMediaUrl)
            
                .toolbar {
                    ToolbarItem {
                        Button {
                            showFileBrowser = true
                        } label: {
                            Label("Open", systemImage: "folder")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
            
            
                .fileImporter(isPresented: $showFileBrowser, allowedContentTypes: [.audiovisualContent]) { result in
                    switch result {
                    case .success(let openedUrl):
                        currentMediaUrl = openedUrl
                        
                    case .failure(let failure):
                        currentMediaUrl = nil
                        print(failure)
                    }
                }
        }
    }
}



#Preview {
    ContentView()
}
