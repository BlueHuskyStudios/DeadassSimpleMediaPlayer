//
//  AsyncLazy.swift
//
//  Created by Ky on 2024-07-14.
//  Available under the MIT license
//

//import Foundation
//
//import LazyContainers
//
//
//
//public typealias AsyncGenerator<Value> = () async -> Value
//public typealias SendableAsyncGenerator<Value> = @Sendable () async -> Value
//
//
//
///// A non-resettable lazy container, to guarantee lazy behavior across language versions
/////
///// - Attention: Because of the extra logic and memory required for this behavior, it's recommended that you use the
/////              language's built-in `lazy` instead wherever possible.
////@propertyWrapper
//public struct AsyncLazy<Value> {
//    
//    /// Privatizes the inner-workings of this functional lazy container
//    @LazyContainerValueReference
//    private var guts: AsyncLazyContainerValueHolder<Value>
//    
//    
//    /// Allows other initializers to have a shared point of initialization
//    private init(_guts: LazyContainerValueReference<AsyncLazyContainerValueHolder<Value>>) {
//        self._guts = _guts
//    }
//    
//    
//    /// Creates a non-resettable lazy container with the given value-initializer. That function will be called the very
//    /// first time a value is needed:
//    ///
//    ///   1. The first time `wrappedValue` is called, the result from `initializer` will be cached and returned
//    ///   2. Subsequent calls to get `wrappedValue` will return the cached value
//    ///
//    /// - Parameter initializer: The closure that will be called the very first time a value is needed
//    public init(initializer: @escaping AsyncGenerator<Value>) {
//        self.init(_guts: .init(wrappedValue: .unset(initializer: initializer)))
//    }
//    
//    
//    /// Creates a `Lazy` that already contains an initialized value.
//    ///
//    /// This is useful when you need a uniform API (for instance, when implementing a protocol that requires a `Lazy`),
//    /// but require it to already hold a value up-front
//    ///
//    /// - Parameter initialValue: The value to immediately store in this `Lazy` container
//    public static func preinitialized(_ initialValue: Value) -> Self {
//        self.init(_guts: .init(wrappedValue: .hasValue(value: initialValue)))
//    }
//    
//    
//    /// Returns the value held within this container.
//    /// If there is none, it is created using the initializer given when this struct was created. This process only
//    /// happens on the first call to `wrappedValue`; subsequent calls are guaranteed to return the cached value from
//    /// the first call.
//    public var wrappedValue: Value {
//        get async { await guts.wrappedValue }
//    }
//    
//    
//    public mutating func setWrappedValue(_ newValue: Value) {
//        guts.setWrappedValue(newValue)
//    }
//    
//    
//    /// Indicates whether the value has indeed been initialized
//    public var isInitialized: Bool { _guts.wrappedValue.hasValue }
//}
//
//
//
///// Takes care of keeping track of the state, value, and initializer of a lazy container, as needed
//private enum AsyncLazyContainerValueHolder<Value> {
//    
//    /// Indicates that a value has been cached, and contains that cached value
//    case hasValue(value: Value)
//    
//    /// Indicates that the value has not yet been created, and contains its initializer
//    /// - Parameter __initializer: The function which will initialize the value. This is set upon creating an ``AsyncLazy``. Passing a function of your own is undefined behavior.
//    case unset(__initializer: AsyncGenerator<Value>)
//    
//    /// Indicates that the value is currently being asynchronously loaded
//    /// - Parameter onValueReady: Call this to await the new value. Passing a function of your own is undefined behavior.
//    case loading(onValueReady: AsyncGenerator<Value>)
//    
//    
//    /// The value held inside this value holder.
//    /// - Attention: Reading this value may mutate the state in order to compute the value. The complexity of that read
//    ///              operation is equal to the complexity of the initializer.
//    public var wrappedValue: Value {
//        mutating get async {
//            switch self {
//            case .hasValue(let value):
//                return value
//                
//            case .unset(let initializer):
//                
//                // This lets us swap out the initializer with a simple function which just returns the value once we have it
//                var initializer = initializer
//                
//                // Create a function-variable we can swap out once the value is initialized
//                initializer = {
//                    // The inner initializer immediately starts generating the value
//                    async let value = await initializer()
//                    
//                    // The moment the value is initialized, swap out this function for one which just returns the value
//                    initializer = { await value }
//                    
//                    return await value
//                }
//                
//                
//                // Begin loading, and allow interested parties to await the loading with a function which can call that function-variable, including calling it once it's changed
//                self = .loading(onValueReady: {
//                    await initializer()
//                })
//                
//                let value = await initializer()
//                
//                self = .hasValue(value: value)
//                
//                return value
//                
//            case .loading(onValueReady: let onValueReady):
//                return await onValueReady()
//            }
//        }
//        
//        // 'set' accessor is not allowed on property with 'get' accessor that is 'async' or 'throws'
//    }
//    
//    
//    /// A way to change the current wrapped value.
//    ///
//    /// This has to be separate from ``wrappedValue`` because Swift doesn't currently (6.0) allow a setter in a computed property with an `async` getter
//    ///
//    /// - Parameter newValue: <#newValue description#>
//    public mutating func setWrappedValue(_ newValue: Value) {
//        self = .hasValue(value: newValue)
//    }
//    
//    
//    /// Indicates whether this holder actually holds a value.
//    /// This will be `true` after reading or writing `wrappedValue`.
//    public var hasValue: Bool {
//        switch self {
//        case .hasValue(value: _):                true
//        case .unset(__initializer: _), .loading: false
//        }
//    }
//}
//
//
//
///// Wraps the initialization duties of `AsyncLazy` in a wrapper for concurrent safety
//private final actor AsyncLazyInitializerWrapper<Value: Sendable> {
//    
//    /// The closure called every time a value is needed
//    private var initializer: AsyncGenerator<Value>
//    
//
//    /// Creates a non-resettable lazy container's guts with the given value-initializer. That function will be
//    /// called the very first time a value is needed.
//    init(initializer: @escaping AsyncGenerator<Value>) {
//        self.initializer = {
//            var value = await initializer()
////            self.initializer = { value }
//            await self.y(value)
////            await self.run {
////                self.initializer = { value }
////            }
//            return value
//        }
//    }
//    
//    private func run(_ body: () async -> Void) async {
//        await body()
//    }
//    
//    private nonisolated func y(_ value: Value) async {
//            await self.run {
//                await x(value)
//            }
//    }
//    
//    private func x(_ value: Value) {
//        self.initializer = { value }
//    }
//    
//
//    /// Returns the value held within this container.
//    /// If there is none, it is created using the initializer given when these guts were created. This process
//    /// only happens on the first call to `wrappedValue`; subsequent calls return the cached value from the first
//    /// call, or any value you've set this to.
//    var wrappedValue: Value {
//        get async { await initializer() }
////        set { initializer = { newValue } }
//    }
//}
//
////func f(x: Set<Int>) -> Set<Int> { x }
////func f(x: Array<Int>) -> Array<Int> { x }
//////func f(x: MySuperListWithBuilderProvider<Int>]) {}
////
////let x = f(x: [1, 2, 3]) // what should be choosen?
