import AppKit
import SwiftUI

struct UsagePopoverView: View {
    let store: UsageStore

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
        HStack {
            if let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
            } else {
                Text("Not updated yet")
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
