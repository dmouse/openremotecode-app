import Flutter
import UIKit
import CryptoKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OpenRemoteCodeHPKE")!
    let channel = FlutterMethodChannel(name: "openremotecode/hpke", binaryMessenger: registrar.messenger())
    let queue = DispatchQueue(label: "openremotecode.hpke")
    let slots = DispatchSemaphore(value: 8)
    channel.setMethodCallHandler { call, result in
      guard call.method == "seal" || call.method == "open" else {
        result(FlutterMethodNotImplemented); return
      }
      guard #available(iOS 17.0, *) else {
        result(FlutterError(code: "unsupported_os", message: "Encrypted chats require iOS 17 or newer", details: nil)); return
      }
      guard slots.wait(timeout: .now()) == .success else {
        result(FlutterError(code: "crypto_busy", message: "Encryption is busy", details: nil)); return
      }
      queue.async {
        defer { slots.signal() }
        do {
          guard let args = call.arguments as? [String: Any] else { throw NSError(domain: "openremotecode.hpke", code: 1) }
          func bytes(_ name: String, _ max: Int) throws -> Data {
            guard let value = args[name] as? FlutterStandardTypedData,
                  !value.data.isEmpty, value.data.count <= max else { throw NSError(domain: "openremotecode.hpke", code: 1) }
            return value.data
          }
          let own = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes("privateKey", 32))
          let peer = try P256.KeyAgreement.PublicKey(x963Representation: bytes("peerKey", 65))
          let aad = try bytes("aad", 2048)
          let content = try bytes("content", 1_500_000)
          let info = Data("opencode-remote/relay/v1".utf8)
          let output: Any
          if call.method == "seal" {
            var sender = try HPKE.Sender(recipientKey: peer, ciphersuite: .P256_SHA256_AES_GCM_256,
                                         info: info, authenticatedBy: own)
            output = ["enc": FlutterStandardTypedData(bytes: sender.encapsulatedKey),
                      "ciphertext": FlutterStandardTypedData(bytes: try sender.seal(content, authenticating: aad))]
          } else {
            var recipient = try HPKE.Recipient(privateKey: own, ciphersuite: .P256_SHA256_AES_GCM_256,
                                               info: info, encapsulatedKey: bytes("enc", 65), authenticatedBy: peer)
            output = FlutterStandardTypedData(bytes: try recipient.open(content, authenticating: aad))
          }
          DispatchQueue.main.async { result(output) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "crypto_failed", message: "Encrypted message could not be processed", details: nil)) }
        }
      }
    }
  }
}
