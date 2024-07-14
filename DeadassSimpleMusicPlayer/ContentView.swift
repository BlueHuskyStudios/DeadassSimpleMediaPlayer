//
//  ContentView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import SwiftUI

import SimpleLogging



struct ContentView: View {
    
    @State
    private var showFileBrowser = false
    
    @State
    private var currentPlaylist: Playlist = .empty
    
    var body: some View {
        NavigationStack {
            MediaPlayerView(currentPlaylist: $currentPlaylist)
            
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
            
            
                .fileImporter(isPresented: $showFileBrowser, allowedContentTypes: .init(Playlist.defaultAllowedContentTypes)) { result in
                    switch result {
                    case .success(let openedUrl):
                        currentPlaylist.add(fromUrl: openedUrl)
                        
                    case .failure(let failure):
                        log(error: failure)
                    }
                }
        }
    }
}



#Preview {
    ContentView()
}
