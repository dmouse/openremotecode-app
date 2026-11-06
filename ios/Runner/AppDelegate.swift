import Flutter
import UIKit
import CryptoKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var voicePlayer: AVAudioPlayer?
  private func stopVoicePlayback() {
    voicePlayer?.stop()
    voicePlayer = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
  override func applicationWillResignActive(_ application: UIApplication) {
    stopVoicePlayback()
    super.applicationWillResignActive(application)
  }
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let audioRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "OpenRemoteCodeVoicePlayback")!
    let audioChannel = FlutterMethodChannel(name: "openremotecode/voice-playback", binaryMessenger: audioRegistrar.messenger())
    NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
      self?.stopVoicePlayback()
    }
    audioChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      do {
        switch call.method {
        case "play":
          self.stopVoicePlayback()
          guard UIApplication.shared.applicationState == .active else { throw NSError(domain: "voice-playback", code: 3) }
          guard let bytes = call.arguments as? FlutterStandardTypedData,
                !bytes.data.isEmpty, bytes.data.count <= 1920000, bytes.data.count % 2 == 0 else {
            throw NSError(domain: "voice-playback", code: 1)
          }
          // Construct a bounded PCM WAV in memory; never create a temporary file.
          var wav = Data("RIFF".utf8)
          func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
          func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
          u32(UInt32(bytes.data.count + 36)); wav.append(Data("WAVEfmt ".utf8))
          u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
          wav.append(Data("data".utf8)); u32(UInt32(bytes.data.count)); wav.append(bytes.data)
          try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
          try AVAudioSession.sharedInstance().setActive(true)
          self.voicePlayer = try AVAudioPlayer(data: wav)
          guard self.voicePlayer?.play() == true else { throw NSError(domain: "voice-playback", code: 2) }
          result(nil)
        case "pause": self.voicePlayer?.pause(); result(nil)
        case "resume":
          guard UIApplication.shared.applicationState == .active else { throw NSError(domain: "voice-playback", code: 3) }
          self.voicePlayer?.play(); result(nil)
        case "stop": self.stopVoicePlayback(); result(nil)
        case "state":
          let milliseconds = Int((self.voicePlayer?.currentTime ?? 0) * 1000)
          let playing = self.voicePlayer?.isPlaying ?? false
          if let player = self.voicePlayer, !playing, player.currentTime >= player.duration - 0.01 { self.stopVoicePlayback() }
          result(["milliseconds": milliseconds, "playing": playing])
        default: result(FlutterMethodNotImplemented)
        }
      } catch {
        self.stopVoicePlayback()
        result(FlutterError(code: "playback_failed", message: "Audio playback is unavailable", details: nil))
      }
    }
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
