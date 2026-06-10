import SwiftUI

/// Pick a future date to seal a capsule until. Honest about the "gentle seal".
struct SealSheet: View {
    let onSeal: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
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
                    Text("Soundpost will hide this capsule and notify you on \(date.formatted(date: .long, time: .omitted)). This is a gentle, honor-system seal kept on your device — not encryption.")
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
