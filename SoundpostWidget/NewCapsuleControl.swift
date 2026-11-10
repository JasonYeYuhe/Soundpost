import AppIntents
import SwiftUI
import WidgetKit

/// "New capsule" in Control Center, on the Lock Screen's control slots and on the Action
/// Button (iOS 18+, M22 §4D). Its action is `NewCapsuleControlIntent`, an `OpenIntent`
/// compiled into the app as well, so the system runs it in the app: it sets the capture
/// request and capture opens idle. Pulled down over a take in progress, it leaves the take
/// alone (`CaptureLaunchRoute` answers `.alreadyOpen`).
@available(iOS 18.0, *)
struct NewCapsuleControl: ControlWidget {
    /// Never change it once shipped: a placed control is bound to its kind.
    static let kind = "com.soundpost.Soundpost.control.newCapsule"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: NewCapsuleControlIntent()) {
                Label("New capsule", systemImage: "waveform")
            }
        }
        .displayName("New capsule")
        .description("Opens Soundpost ready to record. Nothing records until you tap the record button.")
    }
}
