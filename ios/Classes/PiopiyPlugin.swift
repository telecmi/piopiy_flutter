import Flutter
import UIKit

/// Flutter bridge to PiopiyCallCore — the native PushKit + CallKit layer that
/// starts at app launch, before any Flutter engine exists. Dart talks to it
/// through MethodChannel 'com.telecmi.piopiy/call'; native events reach Dart
/// through EventChannel 'com.telecmi.piopiy/events' (queued until Dart
/// attaches, then replayed).
public class PiopiyPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let core = PiopiyCallCore.shared

    public static func register(with registrar: FlutterPluginRegistrar) {
        // Normally already started at launch (PiopiyLaunch.m); idempotent.
        PiopiyCallCore.shared.start()
        let instance = PiopiyPlugin()
        let channel = FlutterMethodChannel(
            name: "com.telecmi.piopiy/call", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        let events = FlutterEventChannel(
            name: "com.telecmi.piopiy/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let uuid = args["uuid"] as? String
        switch call.method {
        case "setup":
            core.applySettings(args)
            result(nil)
        case "displayIncomingCall":
            // iOS rings from the PushKit callback — nothing to do here.
            result(nil)
        case "backgroundPush":
            // Android-only (FCM background isolate).
            result(false)
        case "answerCall":
            if let uuid = uuid { core.answerCall(uuid) }
            result(nil)
        case "setCallActive":
            // CallKit marks the call live when the answer action fulfills.
            result(nil)
        case "endCall":
            if let uuid = uuid { core.endCall(uuid, reason: args["reason"] as? Int ?? 2) }
            result(nil)
        case "setMuted":
            if let uuid = uuid { core.setMuted(uuid, args["muted"] as? Bool ?? false) }
            result(nil)
        case "setAudioRoute":
            // The media engine's AVAudioSession override routes the call;
            // CallKit's screen follows the session route.
            result(nil)
        case "setSignedOut":
            core.setSignedOut(args["signedOut"] as? Bool ?? false)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink sink: @escaping FlutterEventSink)
        -> FlutterError? {
        core.attach(owner: self) { event in sink(event) }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        core.detach(owner: self)
        return nil
    }
}
