import SwiftUI

/// SwiftUI's `@State` is a macro in the macOS 27 SDK, and its plugin ships only with Xcode. Naming the
/// property wrapper through a type alias keeps the package building with the Command Line Tools alone.
public typealias ViewState = SwiftUI.State
