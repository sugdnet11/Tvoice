import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let pushKit = PushKitManager()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        pushKit.start()
        return true
    }
}

@main
struct TvoiceIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.api)
                .task { await model.restoreSession() }
        }
    }
}
