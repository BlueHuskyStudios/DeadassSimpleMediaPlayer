//
//  ConfirmationGatedButton.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2026-07-15.
//

import SwiftUI



struct ConfirmationGatedButton: View {
    
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let role: ButtonRole
    private let confirmationMessage: LocalizedStringKey
    private let confirmationButtonTitle: LocalizedStringKey
    private let action: () -> Void
    
    
    @State
    private var isConfirming = false
    
    
    init(_ title: LocalizedStringKey,
         systemImage: String? = nil,
         role: ButtonRole = .destructive,
         confirmationMessage: LocalizedStringKey = "Are you sure?",
         confirmationButtonTitle: LocalizedStringKey? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.confirmationMessage = confirmationMessage
        self.confirmationButtonTitle = confirmationButtonTitle ?? title
        self.action = action
        self.isConfirming = isConfirming
    }
    
    
    var body: some View {
        rootButton
            .confirmationDialog(confirmationMessage, isPresented: $isConfirming, titleVisibility: .visible) {
                Button(confirmationButtonTitle, role: role) {
                    action()
                }
            }
    }
    
    
    @ViewBuilder
    private var rootButton: some View {
        if let systemImage {
            Button(title, systemImage: systemImage, role: role) {
                isConfirming = true
            }
        }
        else {
            Button(title, role: role) {
                isConfirming = true
            }
        }
    }
}



#Preview("Customized") {
    ConfirmationGatedButton("Feel regret", systemImage: "bird.fill", role: .confirm, confirmationMessage: "Woah there", confirmationButtonTitle: "I know what I'm doing", action: {})
}



#Preview("Minimal") {
    ConfirmationGatedButton("Destroy it", action: {})
}
