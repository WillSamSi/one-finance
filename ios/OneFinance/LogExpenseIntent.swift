import AppIntents
import SwiftUI

/// Opens the + menu with "Or type it" ready, when a Shortcut (e.g. Back Tap) runs "Log expense".
@MainActor
final class QuickEntryRouter: ObservableObject {
    static let shared = QuickEntryRouter()
    @Published var openQuickType = false
}

/// "Log expense": Back Tap can only run a Shortcut, so the app offers this one.
/// Settings → Accessibility → Touch → Back Tap → Double Tap → Log expense.
struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log expense"
    static var description = IntentDescription("Open One Finance's quick expense entry.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickEntryRouter.shared.openQuickType = true
        return .result()
    }
}

struct OneFinanceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: ["Log expense in \(.applicationName)", "Add an expense in \(.applicationName)"],
            shortTitle: "Log expense",
            systemImageName: "plus.circle"
        )
    }
}
