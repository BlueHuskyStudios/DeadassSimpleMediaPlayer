//
//  ToastError + SwiftUI.swift
//  Dead-Simple Media Player
//
//  Created by Ky on 2026-07-15.
//

import SwiftUI

import Howl



public extension ToastError {
    
    /// The icon to put on the toast itself
    var icon: Image {
        Image(systemName: systemImage)
    }
}



public extension View {
    func toast(error: Binding<ToastError?>) -> some View {
        modifier(ShowToastWithItemShim(item: error) { error in
            ToastConfiguration(
                text: error.textForToast,
                duration: .importantText,
                icon: error.icon,
            )
        })
    }
}



// MARK: - Shim

/// Delete after this issue is complete: https://github.com/BlueHuskyStudios/Howl/issues/36
private struct ShowToastWithItemShim<Item: Identifiable>: ViewModifier {
    
    @Binding
    var item: Item?
    
    let transformer: Transformer
    
    
    @State
    private var showToast = false
    
    
    init(item: Binding<Item?>, transformer: @escaping Transformer) {
        self._item = item
        self.transformer = transformer
    }
    
    
    func body(content: Content) -> some View {
        content
            .toast(
                isPresented: $showToast,
                configuration: item.map { transformer($0) } ?? .placeholder,
            )
            .onChange(of: item?.id) { oldValue, newValue in
                guard oldValue != newValue else { return }
                
                // Hide whatever is currently showing, and show the new one after a cycle
                showToast = false
                if nil != newValue {
                    Task {
                        showToast = true
                    }
                }
            }
            .onChange(of: showToast) { oldValue, newShowToast in
                guard oldValue != newShowToast else { return }
                
                if false == newShowToast {
                    self.item = nil
                }
            }
    }
    
    
    
    typealias Transformer = (Item) -> ToastConfiguration
}



private extension ToastConfiguration {
    static var placeholder: Self {
        .init(text: "errr")
    }
}



public extension View {
    func toast<Item: Identifiable>(
        item: Binding<Item?>,
        transformer: @escaping (Item) -> ToastConfiguration,
    ) -> some View {
        modifier(ShowToastWithItemShim(item: item, transformer: transformer))
    }
}
