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
            VideoPlayer(player: player) /*{
                Button("Test") { print("success") }
            }*/
            
            ZStack {
                HStack {
                    Button {
                        showFileBrowser = true
                    } label: {
                        Label("Open", systemImage: "folder")
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                
                Button {
                    isPlaying ? player.pause() : player.play()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.extraLarge)
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
            player.seek(to: .zero)
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
            
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            
        }
    }
}



#Preview {
    MediaPlayerView()
}
