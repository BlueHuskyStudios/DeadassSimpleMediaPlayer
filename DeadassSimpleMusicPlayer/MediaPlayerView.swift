//
//  MediaPlayerView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import Combine
import SwiftUI
import AVKit



struct MediaPlayerView: View {
    
    @State
    private var currentMediaUrl: URL? = nil
    
    @State
    private var showFileBrowser = false
    
    @State
    private var isPlaying = false
    
    @State
    private var player = AVPlayer()
    
    @State
    private var sinks: Set<AnyCancellable> = []
    
    
    var body: some View {
        VStack {
            VideoPlayer(player: player)
            
            HStack {
                Button("Browse") {
                    showFileBrowser = true
                }
                Button(isPlaying ? "Pause" : "Play") {
                    isPlaying ? player.pause() : player.play()
                }
            }
        }
        
        
        .onChange(of: currentMediaUrl) { oldUrl, newUrl in
            oldUrl?.stopAccessingSecurityScopedResource()
            
            guard let newUrl else {
                player.replaceCurrentItem(with: nil)
                return
            }
            
            guard newUrl.startAccessingSecurityScopedResource() else {
                print("oops can't")
                return
            }
            
            player.replaceCurrentItem(with: .init(url: newUrl))
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
        
        
        .onAppear {
            player.publisher(for: \.rate).sink { rate in
                isPlaying = rate > 0
            }
            .store(in: &sinks)
        }
    }
}



#Preview {
    MediaPlayerView()
}
