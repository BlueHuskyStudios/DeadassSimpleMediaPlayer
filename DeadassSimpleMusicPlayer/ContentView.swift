//
//  ContentView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import SwiftUI

import SimpleLogging



struct ContentView: View {
    
    @Environment(\.scenePhase)
    private var scenePhase
    
    @State
    private var showFileBrowser = false
    
    /// Owns all durable playback state (the queue, modes, history, saved playlists) and its persistence
    @State
    private var session = PlayerSession()
    
    var body: some View {
        @Bindable var session = session
        
        NavigationStack {
            MediaPlayerView(currentPlaylist: $session.queue, session: session)
            
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
                        Task {
                            let newEntries = await Playlist.entries(fromUrl: openedUrl)
                            session.queue.append(contentsOf: newEntries)
                        }
                        
                    case .failure(let failure):
                        log(error: failure)
                    }
                }
        }
        
        
        .task {
            await session.restoreIfNeeded()
        }
        
        
        // Backgrounding is the canonical "the user might never come back" moment, so whatever's pending gets flushed here
        .onChange(of: scenePhase) { _, newPhase in
            if .active != newPhase {
                session.saveNowPlayingSnapshotNow()
            }
        }
    }
}



#Preview {
    ContentView()
}
