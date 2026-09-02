import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var settingsStore: SettingsStore
    let notificationService: NotificationService

    @State private var overallTestStatus: String?
    @State private var isOverallTesting = false
    @State private var overallTestIsSuccess = false

    @State private var macTestStatus: String?
    @State private var isMacTesting = false
    @State private var macTestIsSuccess = false

    @State private var iphoneTestStatus: String?
    @State private var isIphoneTesting = false
    @State private var iphoneTestIsSuccess = false
    @State private var isCopied = false

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
        .frame(width: 530, height: 700)
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
                VStack(alignment: .leading, spacing: 8) {
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

                        Spacer()

                        Button {
                            sendMacTest(delay: nil)
                        } label: {
                            if isMacTesting {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 12, height: 12)
                            } else {
                                Text("Test Mac")
                            }
                        }
                        .controlSize(.small)
                        .disabled(isMacTesting)

                        Button {
                            sendMacTest(delay: 10)
                        } label: {
                            Text("Test in 10s")
                        }
                        .controlSize(.small)
                        .disabled(isMacTesting)
                        .help("Fires notification in 10 seconds so you can close this window to test background delivery")
                    }

                    if let macTestStatus {
                        HStack(spacing: 5) {
                            Image(systemName: macTestIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(macTestIsSuccess ? Color.green : Color.red)
                            Text(macTestStatus)
                                .font(.caption2)
                                .foregroundStyle(macTestIsSuccess ? Color.primary : Color.red)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func openNotificationSettings() {
        if let modernUrl = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            let opened = NSWorkspace.shared.open(modernUrl)
            if !opened, let fallbackUrl = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(fallbackUrl)
            }
        }
    }

    private var iphoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settingsStore.settings.iphoneNotificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone Notifications")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Receive push notifications on iPhone via Pushover, Simplepush (Key only), or ntfy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settingsStore.settings.iphoneNotificationsEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Push Service:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $settingsStore.settings.iphoneService) {
                            Text("Pushover.net").tag(IPhonePushService.pushover)
                            Text("Simplepush (Key only)").tag(IPhonePushService.simplepush)
                            Text("ntfy.sh").tag(IPhonePushService.ntfy)
                        }
                        .pickerStyle(.segmented)
                    }

                    switch settingsStore.settings.iphoneService {
                    case .pushover:
                        pushoverControls
                    case .simplepush:
                        simplepushControls
                    case .ntfy:
                        ntfyControls
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private var pushoverControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pushover User Key")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                TextField("Your User Key (from pushover.net dashboard)", text: $settingsStore.settings.pushoverUserKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pushover Application / API Token")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Create App Token on pushover.net (10s)") {
                        if let url = URL(string: "https://pushover.net/apps/build") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.link)
                }
                TextField("Application Token (create in 1 click at pushover.net/apps/build)", text: $settingsStore.settings.pushoverApiToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Spacer()

                Button {
                    sendIphoneTest(delay: nil)
                } label: {
                    if isIphoneTesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Text("Test Pushover")
                    }
                }
                .controlSize(.small)
                .disabled(isIphoneTesting || !settingsStore.settings.isPushoverConfigured)

                Button {
                    sendIphoneTest(delay: 10)
                } label: {
                    Text("Test in 10s")
                }
                .controlSize(.small)
                .disabled(isIphoneTesting || !settingsStore.settings.isPushoverConfigured)
                .help("Sends a Pushover push scheduled to arrive in 10 seconds")
            }

            if let iphoneTestStatus {
                HStack(spacing: 5) {
                    Image(systemName: iphoneTestIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(iphoneTestIsSuccess ? Color.green : Color.red)
                    Text(iphoneTestStatus)
                        .font(.caption2)
                        .foregroundStyle(iphoneTestIsSuccess ? Color.primary : Color.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Pushover Setup (Why two keys?):")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("• Pushover requires a **User Key** (who receives it) and an **App Token** (what app sends it).\n• If you already have your User Key, click the link above to generate an App Token in 10 seconds (Name: 'Agent Allowance').\n• Alternatively, switch to **Simplepush** above to use a single key with no app token!")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
    }

    private var simplepushControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Simplepush Key (Single Key — No App Token)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                TextField("e.g. abc123xyz", text: $settingsStore.settings.simplepushKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Spacer()

                Button {
                    sendIphoneTest(delay: nil)
                } label: {
                    if isIphoneTesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Text("Test Simplepush")
                    }
                }
                .controlSize(.small)
                .disabled(isIphoneTesting || !settingsStore.settings.isSimplepushConfigured)

                Button {
                    sendIphoneTest(delay: 10)
                } label: {
                    Text("Test in 10s")
                }
                .controlSize(.small)
                .disabled(isIphoneTesting || !settingsStore.settings.isSimplepushConfigured)
                .help("Sends a Simplepush notification scheduled to arrive in 10 seconds")
            }

            if let iphoneTestStatus {
                HStack(spacing: 5) {
                    Image(systemName: iphoneTestIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(iphoneTestIsSuccess ? Color.green : Color.red)
                    Text(iphoneTestStatus)
                        .font(.caption2)
                        .foregroundStyle(iphoneTestIsSuccess ? Color.primary : Color.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Simplepush Setup:")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("1. Install the free **Simplepush** app on iPhone from App Store.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("2. Open the Simplepush app on iPhone — it shows your Key immediately.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("3. Paste that Key above — no registration, passwords, or API tokens needed!")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
    }

    private var ntfyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ntfy Topic")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("e.g. allowance-a1b2c3d4", text: $settingsStore.settings.ntfyTopic)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)

                Button {
                    settingsStore.settings.ntfyTopic = NotificationSettings.generateRandomTopic()
                } label: {
                    Image(systemName: "dice")
                }
                .help("Generate a random private topic name")

                Button {
                    copyTopicToClipboard()
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy topic to clipboard")

                Button {
                    sendIphoneTest(delay: nil)
                } label: {
                    if isIphoneTesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Text("Test ntfy")
                    }
                }
                .controlSize(.small)
                .disabled(isIphoneTesting || settingsStore.settings.trimmedNtfyTopic.isEmpty || !settingsStore.settings.isTopicValid)

                Button {
                    sendIphoneTest(delay: 10)
                } label: {
                    Text("Test in 10s")
                }
                .controlSize(.small)
                .disabled(isIphoneTesting || settingsStore.settings.trimmedNtfyTopic.isEmpty || !settingsStore.settings.isTopicValid)
                .help("Sends an iPhone push scheduled to arrive in 10 seconds")
            }

            if let iphoneTestStatus {
                HStack(spacing: 5) {
                    Image(systemName: iphoneTestIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(iphoneTestIsSuccess ? Color.green : Color.red)
                    Text(iphoneTestStatus)
                        .font(.caption2)
                        .foregroundStyle(iphoneTestIsSuccess ? Color.primary : Color.red)
                }
            }

            if !settingsStore.settings.ntfyTopic.isEmpty && !settingsStore.settings.isTopicValid {
                Text("Topic may only contain letters, numbers, hyphens, and underscores.")
                    .font(.caption2)
                    .foregroundStyle(Color.red)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("ntfy Setup:")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("1. Install the free **ntfy** app on iOS from the App Store.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("2. Open the ntfy app, tap **+**, and subscribe to topic: **\(settingsStore.settings.trimmedNtfyTopic.isEmpty ? "your-topic" : settingsStore.settings.trimmedNtfyTopic)**")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !settingsStore.settings.trimmedNtfyTopic.isEmpty {
                    Button("View Live Web Feed (\(settingsStore.settings.cleanedNtfyServer)/\(settingsStore.settings.trimmedNtfyTopic))") {
                        if let url = URL(string: "\(settingsStore.settings.cleanedNtfyServer)/\(settingsStore.settings.trimmedNtfyTopic)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.link)
                    .padding(.top, 2)
                }
            }
            .padding(10)
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
    }

    private func copyTopicToClipboard() {
        let topic = settingsStore.settings.trimmedNtfyTopic
        guard !topic.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topic, forType: .string)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notification Triggers & Schedule")
                .font(.subheadline)
                .fontWeight(.medium)

            Toggle("Notify when exhausted allowance resets (from 0%)", isOn: $settingsStore.settings.notifyOnReset)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Test Notifications")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 10) {
                Button {
                    sendOverallTest(delay: nil)
                } label: {
                    if isOverallTesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("Send Test Now")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isOverallTesting || !settingsStore.settings.isAnyNotificationEnabled)

                Button {
                    sendOverallTest(delay: 10)
                } label: {
                    Image(systemName: "timer")
                    Text("Schedule in 10s (Background Test)")
                }
                .buttonStyle(.bordered)
                .disabled(isOverallTesting || !settingsStore.settings.isAnyNotificationEnabled)
                .help("Schedules notification to fire in 10 seconds. Close popover to test background banner delivery!")

                Spacer()
            }

            if let overallTestStatus {
                HStack(spacing: 6) {
                    Image(systemName: overallTestIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(overallTestIsSuccess ? Color.green : Color.red)
                    Text(overallTestStatus)
                        .font(.caption)
                        .foregroundStyle(overallTestIsSuccess ? Color.primary : Color.red)
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

    private func sendMacTest(delay: TimeInterval?) {
        guard !isMacTesting else { return }
        isMacTesting = true
        macTestStatus = nil

        Task {
            let result = await notificationService.sendTestMacNotification(delaySeconds: delay)
            isMacTesting = false
            macTestIsSuccess = result.macSuccess == true
            let suffix = delay != nil ? " (will fire in \(Int(delay!))s)" : ""
            macTestStatus = result.macSuccess == true ? "Mac notification scheduled\(suffix)!" : (result.macError ?? "Failed to send Mac alert")
            macPermissionStatus = await notificationService.checkMacAuthorizationStatus()
        }
    }

    private func sendIphoneTest(delay: TimeInterval?) {
        guard !isIphoneTesting else { return }
        isIphoneTesting = true
        iphoneTestStatus = nil

        Task {
            let result = await notificationService.sendTestIphoneNotification(delaySeconds: delay, settings: settingsStore.settings)
            isIphoneTesting = false
            iphoneTestIsSuccess = result.iphoneSuccess == true
            let suffix = delay != nil ? " (will deliver in \(Int(delay!))s)" : ""
            iphoneTestStatus = result.iphoneSuccess == true ? "\(settingsStore.settings.iphoneService.rawValue) test push sent\(suffix)!" : (result.iphoneError ?? "Failed to send iPhone push")
        }
    }

    private func sendOverallTest(delay: TimeInterval?) {
        guard !isOverallTesting else { return }
        isOverallTesting = true
        overallTestStatus = nil

        Task {
            let result: NotificationDispatchResult
            if let delay {
                result = await notificationService.sendTestNotificationWithDelay(seconds: delay, settings: settingsStore.settings)
            } else {
                result = await notificationService.sendTestNotification(settings: settingsStore.settings)
            }
            isOverallTesting = false
            overallTestIsSuccess = result.isSuccess
            let delayNotice = delay != nil ? " (scheduled to fire in \(Int(delay!))s — you can switch windows/apps now!)" : ""
            overallTestStatus = result.summaryDescription + delayNotice
            macPermissionStatus = await notificationService.checkMacAuthorizationStatus()
        }
    }
}
