import Foundation
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// Small helper for new assistant strings that need a format argument. The
/// existing `I18N.shared.localized(_:_:)` already handles plain strings; this
/// keeps English format templates readable without adding a second catalog.
@MainActor
enum AgentL10n {
    static func format(_ chinese: String, _ english: String, _ arguments: [CVarArg]) -> String {
        let template = I18N.shared.isEnglish ? english : chinese
        return String(format: template, arguments: arguments)
    }
}
