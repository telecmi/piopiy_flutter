import CallKit
import Flutter
import PushKit
import UIKit

/// PIOPIY voice plugin — owns PushKit AND CallKit, so apps write ZERO native
/// code (in React Native this lived in every app's AppDelegate.mm).
///
/// Rules carried over from the React Native/callkeep work:
///  - iOS 13+: a CallKit call MUST be reported synchronously inside the
///    PushKit callback — done here, before Dart is involved at all.
///  - Answer/end CXActions are fulfilled immediately (delayed fulfillment
///    left a lingering ring banner and auto-disconnects).
///  - Events are queued until Dart attaches and replayed then — killed-state
///    answers arrive before Flutter boots.
///  - The audio session is CallKit-driven: 'audioActivated' tells Dart when
///    WebRTC audio may start (manual-audio pattern).
public class PiopiyPlugin: NSObject, FlutterPlugin {

    private static var shared: PiopiyPlugin?

    private var eventSink: FlutterEventSink?
    private var pendingEvents: [[String: Any]] = []
    private var payloads: [String: [String: Any]] = [:]  // uuid -> push payload
    private var answered: Set<String> = []

    private var provider: CXProvider?
    private let callController = CXCallController()
    private var pushRegistry: PKPushRegistry?
    private var appName = "PIOPIY"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PiopiyPlugin()
        shared = instance
        let channel = FlutterMethodChannel(
            name: "com.telecmi.piopiy/call", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        let events = FlutterEventChannel(
            name: "com.telecmi.piopiy/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    // MARK: - Event funnel (queued until Dart attaches)

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async {
            if let sink = self.eventSink {
                sink(event)
            } else {
                self.pendingEvents.append(event)
                if self.pendingEvents.count > 20 { self.pendingEvents.removeFirst() }
            }
        }
    }

    // MARK: - Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "setup":
            if let name = args["appName"] as? String, !name.isEmpty { appName = name }
            setupProvider()
            registerForVoipPush()
            result(nil)
        case "displayIncomingCall":
            // iOS rings from the PushKit callback — nothing to do here.
            result(nil)
        case "answerCall":
            if let uuid = (args["uuid"] as? String).flatMap({ UUID(uuidString: $0) }) {
                answered.insert(uuid.uuidString.lowercased())
                let action = CXAnswerCallAction(call: uuid)
                callController.request(CXTransaction(action: action)) { _ in }
            }
            result(nil)
        case "setCallActive":
            // CallKit marks the call live when the answer action fulfills.
            result(nil)
        case "endCall":
            if let raw = args["uuid"] as? String, let uuid = UUID(uuidString: raw) {
                payloads.removeValue(forKey: raw.lowercased())
                let reason = args["reason"] as? Int ?? 2
                // Prefer reportCall(ended): works for ringing calls without a
                // user action and never loops back into the delegate.
                let cxReason: CXCallEndedReason = reason == 3 ? .unanswered : .remoteEnded
                provider?.reportCall(with: uuid, endedAt: nil, reason: cxReason)
            }
            result(nil)
        case "setMuted":
            if let raw = args["uuid"] as? String, let uuid = UUID(uuidString: raw) {
                let muted = args["muted"] as? Bool ?? false
                let action = CXSetMutedCallAction(call: uuid, muted: muted)
                callController.request(CXTransaction(action: action)) { _ in }
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func setupProvider() {
        guard provider == nil else { return }
        let config = CXProviderConfiguration(localizedName: appName)
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        let p = CXProvider(configuration: config)
        p.setDelegate(self, queue: nil)
        provider = p
    }

    private func registerForVoipPush() {
        guard pushRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
    }
}

// MARK: - FlutterStreamHandler

extension PiopiyPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink sink: @escaping FlutterEventSink)
        -> FlutterError? {
        eventSink = sink
        // Replay everything that happened before Dart attached (cold start).
        for e in pendingEvents { sink(e) }
        pendingEvents.removeAll()
        for (_, payload) in payloads {
            sink(["event": "push", "payload": payload])
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

// MARK: - PushKit

extension PiopiyPlugin: PKPushRegistryDelegate {

    public func pushRegistry(_ registry: PKPushRegistry,
                             didUpdate credentials: PKPushCredentials,
                             for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        emit(["event": "pushToken", "token": token])
    }

    public func pushRegistry(_ registry: PKPushRegistry,
                             didReceiveIncomingPushWith payload: PKPushPayload,
                             for type: PKPushType,
                             completion: @escaping () -> Void) {
        setupProvider()
        let data = payload.dictionaryPayload as? [String: Any] ?? [:]
        let rawUuid = (data["uuid"] as? String) ?? (data["call_id"] as? String) ?? UUID().uuidString
        let uuid = UUID(uuidString: rawUuid) ?? UUID()
        let key = uuid.uuidString.lowercased()
        let from = (data["from"] as? String) ?? "Incoming call"
        let name = (data["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? from
        let kind = (data["type"] as? String) ?? "incoming_call"

        if kind == "cancel_call" {
            // Apple still requires reporting a call for EVERY VoIP push —
            // report a throwaway and end it, then end the real ringing call
            // (unless this device already answered: multi-device dismissal).
            let dummy = UUID()
            reportIncoming(uuid: dummy, from: from, name: name) { [weak self] in
                self?.provider?.reportCall(with: dummy, endedAt: nil, reason: .remoteEnded)
                if self?.answered.contains(key) != true {
                    self?.provider?.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
                }
                completion()
            }
            emit(["event": "push", "payload": data])
            return
        }

        payloads[key] = data
        reportIncoming(uuid: uuid, from: from, name: name) {
            completion()
        }
        emit(["event": "push", "payload": data])

        // Native ring-timeout backstop (the JS thread can be parked after a
        // background wake) — just above the server's 35 s no-answer cancel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self = self, self.answered.contains(key) == false else { return }
            self.provider?.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
        }
    }

    private func reportIncoming(uuid: UUID, from: String, name: String,
                                done: @escaping () -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: from)
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider?.reportNewIncomingCall(with: uuid, update: update) { _ in done() }
    }
}

// MARK: - CallKit actions

extension PiopiyPlugin: CXProviderDelegate {

    public func providerDidReset(_ provider: CXProvider) {
        emit(["event": "end", "uuid": ""])
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let key = action.callUUID.uuidString.lowercased()
        answered.insert(key)
        emit(["event": "answer", "uuid": key])
        action.fulfill() // immediately — delayed fulfillment breaks the UI
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let key = action.callUUID.uuidString.lowercased()
        payloads.removeValue(forKey: key)
        emit(["event": "end", "uuid": key])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        emit(["event": "audioActivated"])
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Media engine owns the session config; nothing to restore.
    }
}
