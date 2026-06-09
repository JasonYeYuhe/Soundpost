import SwiftUI
import SwiftData

/// Placeholder shell for M1 so the app launches in the simulator and proves the
/// SwiftData stack is wired up. The real capture flow (M3) and gallery (M4)
/// replace this.
struct ContentView: View {
    @Query(sort: \Capsule.createdAt, order: .reverse) private var capsules: [Capsule]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                Text("Soundpost")
                    .font(.largeTitle.bold())
                Text("Milestone 1 · foundation")
                    .foregroundStyle(.secondary)
                Text("\(capsules.count) capsule\(capsules.count == 1 ? "" : "s") stored")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Soundpost")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Capsule.self, inMemory: true)
}
