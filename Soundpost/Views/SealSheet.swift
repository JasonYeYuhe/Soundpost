import SwiftUI

/// Pick a future date to seal a capsule until. Honest about the "gentle seal".
struct SealSheet: View {
    let onSeal: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Read for one sentence only: whether a dated reminder is still something this
    /// app can promise (M17 §S4). The seal itself does not depend on it — a sealed
    /// capsule reappears in the gallery on its date whatever notifications are doing.
    @Environment(NotificationCoordinator.self) private var notifications
    @State private var date: Date = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now

    private var earliest: Date { Date.now.addingTimeInterval(60) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Open on") {
                    DatePicker(
                        "Resurface date",
                        selection: $date,
                        in: earliest...,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                }

                Section("Quick pick") {
                    presetButton("In 1 month", months: 1)
                    presetButton("In 6 months", months: 6)
                    presetButton("In 1 year", months: 12)
                }

                Section {
                    // Say what will actually happen. With notifications denied the
                    // old sentence promised an alert the OS has already refused —
                    // and the app would only admit it *after* the seal was made, in
                    // the "Sealed — but reminders are off" alert. `notDetermined` is
                    // deliberately still a promise: sealing asks for permission as
                    // part of the flow.
                    Text(sealPromise)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Seal to the future")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Seal") { onSeal(date); dismiss() }
                }
            }
        }
    }

    private var sealPromise: LocalizedStringKey {
        let day = date.formatted(date: .long, time: .omitted)
        if notifications.canPromiseAReminder {
            return "Soundpost will hide this capsule and notify you on \(day). This is a gentle, honor-system seal kept on your device — not encryption."
        }
        return "Soundpost will hide this capsule until \(day). Notifications are off, so nothing will alert you — it reappears here on its date. This is a gentle, honor-system seal kept on your device — not encryption."
    }

    // LocalizedStringKey (not String) so the call-site literals localize — the
    // documented gotcha: SwiftUI only localizes string *literals*/keys.
    private func presetButton(_ title: LocalizedStringKey, months: Int) -> some View {
        Button(title) {
            if let next = Calendar.current.date(byAdding: .month, value: months, to: .now) {
                date = next
            }
        }
    }
}
