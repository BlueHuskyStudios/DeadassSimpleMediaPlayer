//
//  MediaPlayerView.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2024-06-08.
//

import Combine
import SwiftUI
@preconcurrency import AVKit

import SimpleLogging



struct MediaPlayerView: View {
    
    @Binding
    var currentMediaUrl: URL?
    
    @State
    private var currentMediaMetadata: AsyncMetadata? = nil
    
    @State
    private var isPlaying = false
    
    @State
    private var player = AVPlayer()
    
    @State
    private var sinks: Set<AnyCancellable> = []
    
    @State
    private var forceUpdateBodge = Bool()
    
    
    var body: some View {
        ZStack {
            metadataView
            
            playerView
        }
        
        
        .onChange(of: currentMediaUrl) { oldUrl, newUrl in
            oldUrl?.stopAccessingSecurityScopedResource()
            currentMediaMetadata = nil
            
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
            
            
            Task { [self] in
                guard let asset = self.player.currentItem?.asset else { return }
                do {
                    let metadata = try await asset.asyncMetadata()
                    self.currentMediaMetadata = metadata
                    metadata.onMetadataDidUpdate().sink {
                        forceUpdateBodge.toggle()
                    }
                    .store(in: &sinks)
                }
                catch {
                    log(error: error)
                }
            }
        }
        
        
        .onChange(of: currentMediaMetadata) { oldValue, newValue in
            // ?
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



private extension MediaPlayerView {
    
    var metadataView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
                .layoutPriority(1)
            
            Rectangle()
                .fill(Color.clear)
                .aspectRatio(16/9, contentMode: .fit)
                .layoutPriority(1)
            
            VStack(alignment: .leading, spacing: 0) {
                Text(titleText)
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(.primary) // not strictly necessary, but I wanted to explicitly call out the relationship to the next Text down
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text(creatorText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize()
                
                Spacer(minLength: 0)
                    .layoutPriority(1)
            }
            .padding(.horizontal)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
    }
    
    
    var playerView: some View {
//        VStack {
//            Spacer()
            VideoPlayer(player: player)
//                .frame(minWidth: /*@START_MENU_TOKEN@*/0/*@END_MENU_TOKEN@*/, idealWidth: /*@START_MENU_TOKEN@*/100/*@END_MENU_TOKEN@*/)
                .aspectRatio(16/9, contentMode: .fit)
//            Spacer()
//        }
    }
}



private extension MediaPlayerView {
    
    func metadata<Value>(_ key: AsyncMetadataKey<Value>) -> MetadataSearchResult<Value>? {
        guard nil != currentMediaUrl else { return nil }
        switch currentMediaMetadata?.get(key) {
        case nil, .stillSearching: return .stillSearching
        case .found(let value):    return .found(value: value)
        case .notFound:            return .notFound
        }
    }
    
    
    var titleText: LocalizedStringKey {
        switch metadata(.title) {
        case .stillSearching: "..."
        case .found(value: let value): "\(value)"
        case .none: nil == currentMediaUrl ? "Pick something to play :3" : ""
        case .notFound:
            if let currentMediaUrl {
                "\(currentMediaUrl.deletingPathExtension().lastPathComponent)"
            }
            else {
                "Untitled"
            }
        }
    }
    
    
    var creatorText: LocalizedStringKey {
        switch metadata(.creator) {
        case .stillSearching: "..."
        case .found(let value): "\(value)"
        case .notFound: ""
        case nil: ""
        }
    }
}



#Preview {
    NavigationStack {
        MediaPlayerView(currentMediaUrl: .constant(nil))
    }
}
