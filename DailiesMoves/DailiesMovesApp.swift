import SwiftUI
import UIKit

@main
struct DailiesMovesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        LocationTracker.shared.handleAppBecameActive()
                    }
                }
        }
    }
}

/// Ensures CoreLocation hardware monitors re-attach immediately on silent background location relaunches.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchedForLocation = launchOptions?[.location] != nil
        Task { @MainActor in
            LocationTracker.shared.restoreIfNeeded(launchedForLocation: launchedForLocation)
        }
        return true
    }
}
