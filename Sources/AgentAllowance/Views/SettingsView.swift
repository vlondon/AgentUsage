import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var settingsStore: SettingsStore
    let notificationService: NotificationService

    @State private var testStatus: String?
    @State private var isTesting = false
    @State private var testIsSuccess = false
    @State private var macPermissionStatus: UNAuthorizationStatus = .notDetermined
    @Environment(\.dismiss) private var dismiss

    init(
        settingsStore: SettingsStore,
        notificationService: NotificationService = NotificationService()
    ) {
        self.settingsStore = settingsStore
        self.notificationService = notificationService
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    macSection
                    Divider()
                    iphoneSection
                    Divider()
                    triggersSection
                    Divider()
                    testSection
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 460, height: 560)
        .onAppear {
            refreshPermissionStatus()
        }
        .task {
            refreshPermissionStatus()
        }
    }

    private func refreshPermissionStatus() {
        Task {
            macPermissionStatus = await notificationService.checkMacAuthorizationStatus()
        }
    }

    private var header: some View {
        HStack {
            Label("Settings", systemImage: "gearshape")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settingsStore.settings.macNotificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Notifications")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Show local macOS alerts when an agent allowance refreshes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: settingsStore.settings.macNotificationsEnabled) { _, newValue in
                if newValue {
                    Task {
                        _ = await notificationService.requestMacAuthorization()
                        macPermissionStatus = await notificationService.checkMacAuthorizationStatus()
                    }
                }
            }

            if settingsStore.settings.macNotificationsEnabled {
                HStack(spacing: 8) {
                    Circle()
                        .fill(macPermissionStatus == .authorized ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)

                    if macPermissionStatus == .authorized {
                        Text("Permission granted")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if macPermissionStatus == .denied {
                        Text("Permission denied in System Settings")
                            .font(.caption2)
                            .foregroundStyle(Color.red)

                        Button("Open System Settings") {
                            openNotificationSettings()
                        }
                        .font(.caption2)
                        .buttonStyle(.link)
                    } else {
                        Text("Permission not determined")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func openNotificationSettings() {
        if let modernUrl = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(modernUrl)
        } else if let fallbackUrl = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(fallbackUrl)
        }
    }

    private var iphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settingsStore.settings.iphoneNotificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone Notifications (via ntfy)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Receive push notifications on iPhone using the free, open-source ntfy app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: settingsStore.settings.iphoneNotificationsEnabled) { _, newValue in
                if newValue && settingsStore.settings.trimmedNtfyTopic.isEmpty {
                    settingsStore.settings.ntfyTopic = NotificationSettings.generateRandomTopic()
                }
            }

            if settingsStore.settings.iphoneNotificationsEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ntfy Topic")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField("e.g. allowance-a1b2c3d4", text: $settingsStore.settings.ntfyTopic)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)

                        Button {
                            settingsStore.settings.ntfyTopic = NotificationSettings.generateRandomTopic()
                        } label: {
                            Image(systemName: "dice")
                        }
                        .help("Generate a random private topic name")
                    }

                    if !settingsStore.settings.ntfyTopic.isEmpty && !settingsStore.settings.isTopicValid {
                        Text("Topic may only contain letters, numbers, hyphens, and underscores.")
                            .font(.caption2)
                            .foregroundStyle(Color.red)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Setup steps:")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("1. Install the free **ntfy** app on iOS from App Store.\n2. Subscribe to the same topic name as above.\n3. Keep your topic name unique/private to keep alerts secure.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)

                    DisclosureGroup("Advanced: Custom Server") {
                        TextField("https://ntfy.sh", text: $settingsStore.settings.ntfyServer)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .padding(.top, 4)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .padding(.leading, 24)
            }
        }
    }

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notification Triggers & Schedule")
                .font(.subheadline)
                .fontWeight(.medium)

            Toggle("Notify when allowance resets", isOn: $settingsStore.settings.notifyOnReset)
                .font(.callout)

            Toggle("Notify when allowance is low (<= \(settingsStore.settings.lowAllowanceThreshold)%)", isOn: $settingsStore.settings.notifyOnLowAllowance)
                .font(.callout)

            if settingsStore.settings.notifyOnLowAllowance {
                HStack {
                    Text("Threshold:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settingsStore.settings.lowAllowanceThreshold) {
                        Text("5%").tag(5)
                        Text("10%").tag(10)
                        Text("15%").tag(15)
                        Text("20%").tag(20)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                .padding(.leading, 24)
            }

            if settingsStore.settings.isAnyNotificationEnabled {
                HStack {
                    Text("Background check interval:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settingsStore.settings.backgroundRefreshIntervalMinutes) {
                        Text("2 min").tag(2)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                    }
                    .frame(width: 110)
                }
                .padding(.leading, 24)
            }
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    sendTest()
                } label: {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "paperplane")
                    }
                    Text("Send Test Notification")
                }
                .disabled(isTesting || !settingsStore.settings.isAnyNotificationEnabled)

                Spacer()
            }

            if let testStatus {
                HStack(spacing: 6) {
                    Image(systemName: testIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(testIsSuccess ? Color.green : Color.red)
                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(testIsSuccess ? Color.primary : Color.red)
                }
            } else if !settingsStore.settings.isAnyNotificationEnabled {
                Text("Enable Mac or iPhone notifications above to test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                SettingsWindowController.shared.close()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func sendTest() {
        guard !isTesting else { return }
        isTesting = true
        testStatus = nil

        Task {
            let result = await notificationService.sendTestNotification(settings: settingsStore.settings)
            isTesting = false
            testIsSuccess = result.isSuccess
            testStatus = result.summaryDescription
            macPermissionStatus = await notificationService.checkMacAuthorizationStatus()
        }
    }
}
