import AppKit
import SwiftUI

struct UsagePopoverView: View {
    let store: UsageStore
    @State private var popoverWindow = WindowReference()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if store.usages.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.usages) { usage in
                            ProviderSectionView(usage: usage)
                            if usage.provider != store.usages.last?.provider {
                                Divider()
                                    .padding(.leading, 20)
                            }
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 410, height: 540)
        .task {
            await store.refreshIfNeeded()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No agents found")
                .font(.headline)
            Text("Install and sign in to Codex, Claude, Cursor, Devin, Grok, or Antigravity, then refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Usage remaining")
                    .font(.headline)
                Text("Allowance and time until reset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
            } else {
                Text("Not updated yet")
            }

            Spacer()

            Button {
                // The popover floats above normal windows, so close it rather than
                // leave it covering Settings. MenuBarExtra ignores `dismiss`.
                popoverWindow.window?.close()
                SettingsWindowController.shared.show(
                    settingsStore: store.settingsStore,
                    notificationService: store.notificationService
                )
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
            .help("Quit Agent Allowance")
            .accessibilityLabel("Quit")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(WindowReader { popoverWindow.window = $0 })
    }
}

private final class WindowReference {
    weak var window: NSWindow?
}

/// Reports the NSWindow hosting a SwiftUI view whenever the view moves to a window.
private struct WindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReaderView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        let onWindowChange: (NSWindow?) -> Void

        init(onWindowChange: @escaping (NSWindow?) -> Void) {
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange(window)
        }
    }
}
