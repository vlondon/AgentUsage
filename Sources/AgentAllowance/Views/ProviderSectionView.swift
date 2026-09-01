import SwiftUI

struct ProviderSectionView: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: usage.provider.symbolName)
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(usage.provider.rawValue)
                    .font(.headline)
                Spacer()
                if usage.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if usage.windows.isEmpty && usage.error == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking allowance…")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.leading, 24)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 7) {
                        ForEach(usage.windows) { window in
                            AllowanceRow(window: window, now: context.date)
                        }
                    }
                }
            }

            if let error = usage.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
                    .accessibilityLabel("\(usage.provider.rawValue) error: \(error)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AllowanceRow: View {
    let window: AllowanceWindow
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(window.indicatorColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 0) {
                Text(window.label)
                    .lineLimit(1)
                if let scope = window.scope {
                    Text(scope)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 130, alignment: .leading)

            Spacer(minLength: 4)

            if let note = window.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(ResetTimeFormatter.string(until: window.resetAt, now: now))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)

                Text(percentText)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .padding(.leading, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var percentText: String {
        guard let percent = window.remainingPercent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private var accessibilityText: String {
        let scope = window.scope.map { "\($0), " } ?? ""
        if let note = window.note {
            return "\(scope)\(window.label), \(note)"
        }
        return "\(scope)\(window.label), \(percentText) remaining, resets in \(ResetTimeFormatter.string(until: window.resetAt, now: now))"
    }
}
