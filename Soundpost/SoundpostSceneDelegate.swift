import UIKit

/// Receives the Home Screen quick action (M20 §4F). Nothing else.
///
/// Soundpost uses the SwiftUI scene lifecycle, under which the app delegate's
/// `application(_:performActionFor:completionHandler:)` is never called — and the iOS
/// 27 SDK deprecates it in favour of the scene's entry points. So
/// `SoundpostAppDelegate.application(_:configurationForConnecting:options:)` supplies
/// this class as the scene's delegate, and SwiftUI forwards scene events to it while
/// `WindowGroup` goes on creating and rendering the window.
///
/// **It must not create or assign a `UIWindow`.** That is the one way this pattern can
/// launch to a black screen; `CaptureLaunchTests` reads this file for it.
final class SoundpostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// A cold launch from the quick action: the item arrives with the connection.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { handle(item) }
    }

    /// A warm launch from the quick action.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(handle(shortcutItem))
    }

    /// Sets the capture request and nothing else — the gallery presents it when it can.
    @discardableResult
    private func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == QuickAction.newCapsuleType else { return false }
        CaptureRequests.request()
        return true
    }
}
