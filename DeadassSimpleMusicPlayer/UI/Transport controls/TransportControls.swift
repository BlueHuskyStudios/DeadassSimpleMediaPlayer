//
//  TransportControls.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-09-06.
//

import SwiftUI



// MARK: - API

public extension View {
    func withTransportControlOverlay(onTransport: @escaping (TransportAction) -> Void) -> some View {
        overlay(VStack {
            Spacer(minLength: 144).allowsHitTesting(false)
                .layoutPriority(2)
            
            TransportControls(onTransport: onTransport)
                .frame(minHeight: 292)
                .layoutPriority(0)
                .materialShadow(.z24, lightFrom: .degrees(180))
        })
    }
}



// MARK: - implementation

private struct TransportControls: View {
    
    private let onTransport: (TransportAction) -> Void
    
    
    init(onTransport: @escaping (TransportAction) -> Void) {
        self.onTransport = onTransport
    }
    
    
    var body: some View {
        ZStack {
            background
            controls
        }
    }
}



// MARK: - controls

extension TransportControls {
    var controls: some View {
        HStack(spacing: 16) {
//            backButton
            playPauseButton
//            forwardButton
        }
    }
    
    
    var playPauseButton: some View {
        Button(action: {
            onTransport(.play)
        }) {
            Image(.TransportControls.play)
                .resizable()
                .frame(width: 78, height: 78)
        }
    }
}



// MARK: - background

extension TransportControls {
    var background: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Color.brand
                .opacity(0.03)
        }
        .ignoresSafeArea()
    }
}



// MARK: - TransportAction

public enum TransportAction {
    case play
    case pause
    case next
    case previous
    case seek(to: TimeInterval)
}



// MARK: - previews

#Preview {
    Color.pink.withTransportControlOverlay { _ in
        
    }
}
