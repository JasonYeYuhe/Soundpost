import SwiftUI
import SwiftData
import UIKit

/// The calm Settings hub (M12 §S7/§4E): privacy/support, notification + iCloud
/// state, the personalized-notifications toggle, the restore outcome, "Delete my
/// cloud data" (moved here from the gallery footer), and bulk export-your-data.
/// Secondary chrome — not an engagement surface.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(CloudSyncMonitor.self) private var syncMonitor
    @Environment(DeliveryRegistrar.self) private var registrar
    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(StoreService.self) private var store

    @AppStorage(NotificationPreferences.personalizedKey) private var personalizedNotifications = false
    @AppStorage(DeliveryPreferences.optedOutKey) private var cloudOptedOut = false

    @State private var showingPaywall = false
    @State private var confirmingCloudDelete = false
    @State private var cloudDeleteFailed = false
    @State private var restoreMessage: String?
    @State private var confirmingExport = false
    @State private var estimatedExportSize = ""
    @State private var isExporting = false
    @State private var exportFailed = false
    @State private var sharePayload: SharePayload?

    private let privacyURL = URL(string: "https://jasonyeyuhe.github.io/soundpost-site/privacy.html")!
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let supportURL = URL(string: "https://jasonyeyuhe.github.io/soundpost-site/")!

    var body: some View {
        NavigationStack {
            Form {
                notificationsSection
                dataSection
                iCloudSection
                proSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) { ProPaywallView() }
            .sheet(item: $sharePayload) { ShareSheet(items: $0.items) }
            .confirmationDialog("Export your data?", isPresented: $confirmingExport, titleVisibility: .visible) {
                Button("Export") { startExport() }
            } message: {
                Text("This bundles \(estimatedExportSize) of audio plus a manifest of your notes, moods, places and dates. It's your own data — nothing new leaves your device.")
            }
            .confirmationDialog("Delete my cloud data?", isPresented: $confirmingCloudDelete, titleVisibility: .visible) {
                Button("Delete my cloud data", role: .destructive, action: deleteCloudData)
            } message: {
                Text("This removes the reminder schedule and device tokens Soundpost keeps on its server. Your capsules stay on this device and in iCloud. Far-future reminders fall back to this device's local schedule.")
            }
            .alert("Couldn't delete cloud data", isPresented: $cloudDeleteFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Check your connection and try again. Your cloud data hasn't been changed.")
            }
            .alert("Couldn't prepare the export", isPresented: $exportFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please try again.")
            }
            .alert("Restore Purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(restoreMessage ?? "")
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle("Show your words on the lock screen", isOn: $personalizedNotifications)
            Button("Open iOS Settings") { openAppSettings() }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Off by default. When on, a capsule's one-line or place can appear in its resurface notification — your private words, shown on the lock screen. Turn notifications on or off for Soundpost in iOS Settings.")
        }
    }

    // MARK: - Your data (export)

    private var dataSection: some View {
        Section {
            Button { prepareExport() } label: {
                HStack {
                    Label("Export my data", systemImage: "square.and.arrow.up.on.square")
                    Spacer()
                    if isExporting { ProgressView() }
                }
            }
            .disabled(isExporting)
        } header: {
            Text("Your data")
        } footer: {
            Text("A copy of every capsule's audio and a manifest of your notes, moods, places and dates. Your own data — nothing new leaves your device.")
        }
    }

    // MARK: - iCloud / delivery

    private var iCloudSection: some View {
        Section {
            Label {
                Text(backupMessage)
            } icon: {
                Image(systemName: backupSymbol)
            }
            .labelStyle(.titleAndIcon)
            if syncMonitor.backup == .iCloud && !cloudOptedOut {
                Button("Delete my cloud data", role: .destructive) { confirmingCloudDelete = true }
            }
        } header: {
            Text("iCloud & delivery")
        }
    }

    // MARK: - Pro

    private var proSection: some View {
        Section {
            Button { showingPaywall = true } label: {
                HStack {
                    Label(store.isPro ? "Soundpost Pro is active" : "Soundpost Pro", systemImage: "waveform.badge.plus")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Button("Restore Purchases") { restore() }
        } header: {
            Text("Soundpost Pro")
        } footer: {
            Text("Soundpost is free — capture, seal, resurface, back up, and receive every memory. Pro adds richer ways to make and share them, and never locks a memory.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Link("Privacy Policy", destination: privacyURL)
            Link("Terms of Use", destination: termsURL)
            Link("Help & Support", destination: supportURL)
        } header: {
            Text("About")
        } footer: {
            Text(versionFooter)
        }
    }

    private var versionFooter: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Soundpost \(v) (\(b))"
    }

    // MARK: - Actions

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func prepareExport() {
        let bytes = CapsuleBulkExporter.estimatedBytes(in: modelContext)
        estimatedExportSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        confirmingExport = true
    }

    private func startExport() {
        isExporting = true
        let container = modelContext.container
        Task {
            let exporter = CapsuleBulkExporter(modelContainer: container)
            do {
                let url = try await exporter.export()
                sharePayload = SharePayload(items: [url])
            } catch {
                exportFailed = true
            }
            isExporting = false
        }
    }

    private func restore() {
        Task {
            switch await store.restorePurchases() {
            case .restored: restoreMessage = String(localized: "Your purchases were restored.")
            case .nothingToRestore: restoreMessage = String(localized: "No purchases were found to restore.")
            case .failed: restoreMessage = String(localized: "Couldn't restore purchases. Please check your connection and try again.")
            }
        }
    }

    /// Purge server-side tokens + jobs, then (only on success) opt out + clear each
    /// capsule's `serverJobSyncedAt` so the local planner re-arms, and re-sync.
    /// Moved here from the gallery footer (§S7).
    private func deleteCloudData() {
        Task {
            let purged = await notifications.sealDelivery?.deleteAllCloudData() ?? false
            await registrar.signOut()
            guard purged else { cloudDeleteFailed = true; return }
            cloudOptedOut = true
            let capsuleStore = CapsuleStore(context: modelContext)
            for capsule in (try? capsuleStore.all()) ?? [] where capsule.serverJobSyncedAt != nil {
                capsule.serverJobSyncedAt = nil
            }
            try? capsuleStore.save()
            await notifications.sync(capsules: (try? capsuleStore.all()) ?? [])
        }
    }

    // MARK: - iCloud copy (mirrors the gallery footer's honest durability state)

    private var backupMessage: LocalizedStringKey {
        switch syncMonitor.backup {
        case .iCloud:    "Backed up to your iCloud and synced across your devices."
        case .signedOut: "Only on this device — sign in to iCloud to back up your capsules."
        case .quotaFull: "Your iCloud storage is full, so new capsules stay on this device for now."
        case .localOnly: "Capsules live only on this device, so deleting the app erases them."
        }
    }

    private var backupSymbol: String {
        switch syncMonitor.backup {
        case .iCloud:    "checkmark.icloud"
        case .signedOut: "icloud.slash"
        case .quotaFull: "exclamationmark.icloud"
        case .localOnly: "internaldrive"
        }
    }
}
