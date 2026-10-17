import SwiftUI

/// `@State` without the macro. In the macOS 27 SDK `@State` resolves to a macro whose plugin ships only
/// with Xcode, so a build with the Command Line Tools fails. This wraps the `State` property wrapper,
/// which SwiftUI handles as a nested dynamic property: same storage, same view identity rules.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private let state: State<Value>

    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
