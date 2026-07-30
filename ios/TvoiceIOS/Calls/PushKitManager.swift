import Foundation
import PushKit
import UIKit

final class PushKitManager: NSObject, PKPushRegistryDelegate {
    private var registry: PKPushRegistry?

    func start() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "tvoice.voipPushToken")
        // The token registration endpoint is activated after APNs credentials
        // and the Apple Team ID are configured on the Tvoice backend.
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        UserDefaults.standard.removeObject(forKey: "tvoice.voipPushToken")
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        NotificationCenter.default.post(
            name: .tvoiceVoIPPush,
            object: nil,
            userInfo: payload.dictionaryPayload
        )
        completion()
    }
}

extension Notification.Name {
    static let tvoiceVoIPPush = Notification.Name("tj.tvoice.ios.voipPush")
}
