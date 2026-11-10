import SwiftUI
import WidgetKit

/// Soundpost's widget extension (M22 §4D): a launcher, and on iOS 18 a Control Center
/// control. Both open the app on capture, idle — through the app's one capture door,
/// `CaptureRequests` → `CaptureLaunchRoute` — and neither shows any capsule content.
///
/// The control is iOS 18 only and the extension's deployment target is 17.0, so it sits
/// behind `if #available`; on iOS 17 the bundle offers the launcher alone. (Xcode's own
/// widget template lists the control unguarded, which does not compile at 17.0.)
@main
struct SoundpostWidgets: WidgetBundle {
    var body: some Widget {
        LauncherWidget()
        if #available(iOS 18.0, *) {
            NewCapsuleControl()
        }
    }
}
