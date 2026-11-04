import SwiftUI

/// Feature-owned content. The notch hosts views without creating another service or data store.
public struct NotchWidget: Identifiable {
    public let id: String
    private let titleProvider: () -> String
    public var title: String { titleProvider() }
    public let systemImage: String
    public let activity: @MainActor () -> String?
    /// Passive status (negative) yields to a timer; recording and other immediate activity use zero or above.
    public let activityPriority: Int
    public let compactContent: (@MainActor () -> AnyView)?
    public let content: @MainActor (@escaping @MainActor () -> Void) -> AnyView

    public init<Content: View>(id: String, title: @autoclosure @escaping () -> String, systemImage: String,
                              activity: @escaping @MainActor () -> String? = { nil },
                              activityPriority: Int = 0,
                              compactContent: (@MainActor () -> AnyView)? = nil,
                              @ViewBuilder content: @escaping @MainActor (@escaping @MainActor () -> Void) -> Content) {
        self.id = id
        self.titleProvider = title
        self.systemImage = systemImage
        self.activity = activity
        self.activityPriority = activityPriority
        self.compactContent = compactContent
        self.content = { dismiss in AnyView(content(dismiss)) }
    }
}
