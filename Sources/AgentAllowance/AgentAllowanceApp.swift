import SwiftUI

@main
struct AgentAllowanceApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra("Agent Allowance", systemImage: "gauge.with.dots.needle.50percent") {
            UsagePopoverView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
