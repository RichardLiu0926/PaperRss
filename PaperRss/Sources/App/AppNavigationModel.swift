import SwiftUI

@MainActor
final class AppNavigationModel: ObservableObject {
    var opensSettingsOnNextWindow = false

    enum Destination: Equatable {
        case unread
        case agent
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let destination: Destination
    }

    @Published private(set) var request: Request?

    func openUnread() {
        request = Request(destination: .unread)
    }

    func openAgent() {
        request = Request(destination: .agent)
    }
}
