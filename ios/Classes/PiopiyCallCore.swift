import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

/// The native call layer — owns PushKit AND CallKit for the whole app
/// process, independent of any Flutter engine. Started at app launch
/// (PiopiyLaunch.m) — in React Native this lived in every app's
/// AppDelegate; here apps write zero native code.
///
/// Why at launch and not from Dart: a VoIP push can launch the app in the
/// background with no UI scene, and with the UIScene lifecycle no Flutter
/// engine runs then. iOS still requires the push to be reported to CallKit —
/// a registry created later (from Dart) misses it, and iOS stops delivering
/// VoIP pushes to apps that fail to report.
///
/// Rules carried over from the React Native/callkeep work:
///  - iOS 13+: the CallKit call is reported synchronously inside the PushKit
///    callback, for EVERY VoIP push (cancels included).
///  - Answer/end CXActions are fulfilled immediately (delayed fulfillment
///    left a lingering ring banner and raced the multi-device cancel).
///  - Events are queued until Dart attaches and replayed then — killed-state
///    answers arrive before Flutter boots.
///  - CallKit owns the audio session: 'audioActivated' / 'audioDeactivated'
///    tell Dart when the WebRTC engine may run.
///  - A native ring-timeout backstop (ringTime + 5 s): iOS parks Dart after a
///    background wake, so only a native timer is guaranteed to fire.
@objc(PiopiyCallCore)
public final class PiopiyCallCore: NSObject {

    @objc public static let shared = PiopiyCallCore()

    /// Called from PiopiyLaunch.m at UIApplicationDidFinishLaunching.
    @objc public static func startAtLaunch() {
        shared.start()
    }

    private var started = false
    private var provider: CXProvider?
    private let callController = CXCallController()
    private var pushRegistry: PKPushRegistry?

    // Event funnel (queued until Dart attaches).
    private var sink: ((Any?) -> Void)?
    private weak var sinkOwner: AnyObject?
    private var pendingEvents: [[String: Any]] = []

    // Per-call state, keyed by lowercased uuid.
    private var payloads: [String: [String: Any]] = [:]
    private var payloadOrder: [String] = []
    private var answered: Set<String> = []
    private var localEnds: Set<String> = []
    private var muted: [String: Bool] = [:]
    private var expectedMute: [String: Bool] = [:]
    private var ringTimers: [String: DispatchWorkItem] = [:]
    private var lastRoute: String?

    private let defaults = UserDefaults.standard
    private enum Key {
        static let appName = "piopiy.appName"
        static let imageName = "piopiy.imageName"
        static let ringtone = "piopiy.ringtoneSound"
        static let recents = "piopiy.includesCallsInRecents"
        static let ringTime = "piopiy.ringTime"
        static let autoPush = "piopiy.autoPushToken"
        static let signedOut = "piopiy.signedOut"
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        setupProvider()
        if defaults.object(forKey: Key.autoPush) as? Bool ?? true {
            registerForVoipPush()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// Dart's setup(): persist (a killed-state launch reads these before
    /// Dart runs) and apply.
    func applySettings(_ args: [String: Any]) {
        start()
        let ios = args["ios"] as? [String: Any] ?? [:]
        if let name = (ios["appName"] as? String) ?? (args["appName"] as? String), !name.isEmpty {
            defaults.set(name, forKey: Key.appName)
        } else {
            defaults.removeObject(forKey: Key.appName)
        }
        defaults.set(ios["imageName"] as? String, forKey: Key.imageName)
        defaults.set(ios["ringtoneSound"] as? String, forKey: Key.ringtone)
        defaults.set(ios["includesCallsInRecents"] as? Bool ?? true, forKey: Key.recents)
        if let ringTime = args["ringTime"] as? Int { defaults.set(ringTime, forKey: Key.ringTime) }
        let autoPush = args["autoPushToken"] as? Bool ?? true
        defaults.set(autoPush, forKey: Key.autoPush)

        provider?.configuration = makeConfiguration()
        if autoPush {
            registerForVoipPush()
        } else if let registry = pushRegistry {
            // The app owns PushKit itself.
            registry.desiredPushTypes = []
            pushRegistry = nil
        }
    }

    func setSignedOut(_ signedOut: Bool) {
        defaults.set(signedOut, forKey: Key.signedOut)
    }

    private func makeConfiguration() -> CXProviderConfiguration {
        let config: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            // iOS 14+ always shows the app's own name.
            config = CXProviderConfiguration()
        } else {
            let fallback = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "PIOPIY"
            config = CXProviderConfiguration(localizedName: defaults.string(forKey: Key.appName) ?? fallback)
        }
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.includesCallsInRecents = defaults.object(forKey: Key.recents) as? Bool ?? true
        if let image = defaults.string(forKey: Key.imageName), let img = UIImage(named: image) {
            config.iconTemplateImageData = img.pngData()
        }
        if let ringtone = defaults.string(forKey: Key.ringtone), !ringtone.isEmpty {
            config.ringtoneSound = ringtone
        }
        return config
    }

    private func setupProvider() {
        guard provider == nil else { return }
        let p = CXProvider(configuration: makeConfiguration())
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

    // MARK: - Event funnel

    func attach(owner: AnyObject, sink: @escaping (Any?) -> Void) {
        sinkOwner = owner
        self.sink = sink
        // Replay everything that happened before Dart attached (cold start).
        for e in pendingEvents { sink(e) }
        pendingEvents.removeAll()
        for key in payloadOrder {
            if let p = payloads[key] { sink(["event": "push", "payload": p]) }
        }
    }

    func detach(owner: AnyObject) {
        if sinkOwner === owner || sinkOwner == nil {
            sink = nil
            sinkOwner = nil
        }
    }

    private func emit(_ event: [String: Any]) {
        let send = {
            if let sink = self.sink {
                sink(event)
            } else {
                self.pendingEvents.append(event)
                if self.pendingEvents.count > 30 { self.pendingEvents.removeFirst() }
            }
        }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    private func storePayload(_ key: String, _ data: [String: Any]) {
        payloads[key] = data
        payloadOrder.removeAll { $0 == key }
        payloadOrder.append(key)
        if payloadOrder.count > 10 {
            let drop = payloadOrder.removeFirst()
            payloads.removeValue(forKey: drop)
        }
    }

    private func forget(_ key: String) {
        payloads.removeValue(forKey: key)
        payloadOrder.removeAll { $0 == key }
        ringTimers.removeValue(forKey: key)?.cancel()
        muted.removeValue(forKey: key)
        expectedMute.removeValue(forKey: key)
    }

    // MARK: - Calls from Dart

    func answerCall(_ raw: String) {
        guard let uuid = UUID(uuidString: raw) else { return }
        let key = uuid.uuidString.lowercased()
        guard !answered.contains(key) else { return }
        callController.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { _ in }
    }

    /// [reason]: 1 local, 2 remote, 3 missed/unanswered, 6 declined here.
    func endCall(_ raw: String, reason: Int) {
        guard let uuid = UUID(uuidString: raw) else { return }
        let key = uuid.uuidString.lowercased()
        forget(key)
        if reason == 1 || reason == 6 {
            // Ended on this device: an end action, so CallKit records it as
            // the user's. No 'end' echo back to Dart.
            localEnds.insert(key)
            callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
                if error != nil {
                    // Unknown to CallKit (already gone) — make sure it is.
                    DispatchQueue.main.async {
                        self?.localEnds.remove(key)
                        self?.provider?.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
                    }
                }
            }
        } else {
            // reportCall works for ringing calls without a user action and
            // never loops back into the delegate.
            provider?.reportCall(with: uuid, endedAt: nil,
                                 reason: reason == 3 ? .unanswered : .remoteEnded)
        }
        answered.remove(key)
    }

    /// Keep the CallKit mute button in sync with an app-initiated mute.
    func setMuted(_ raw: String, _ value: Bool) {
        guard let uuid = UUID(uuidString: raw) else { return }
        let key = uuid.uuidString.lowercased()
        if muted[key] == value { return }
        expectedMute[key] = value
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: value))) { _ in }
    }

    // MARK: - Audio route

    @objc private func onRouteChange(_ note: Notification) {
        DispatchQueue.main.async {
            guard !self.answered.isEmpty else { return }
            let output = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
            guard let port = output?.rawValue, port != self.lastRoute else { return }
            self.lastRoute = port
            self.emit(["event": "audioRoute", "output": port,
                       "speaker": output == .builtInSpeaker])
        }
    }

    // MARK: - Reporting

    private static func display(_ data: [String: Any], from: String) -> String {
        let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        var team = (data["team"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if team.isEmpty {
            team = (data["team_name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let primary = name.isEmpty ? from : name
        return team.isEmpty ? primary : "\(primary) — \(team)"
    }

    private func reportIncoming(uuid: UUID, from: String, display: String,
                                done: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: from)
        update.localizedCallerName = display
        update.hasVideo = false
        // Hold / keypad / add-call need platform call control on inbound
        // calls (as on React Native) — don't offer buttons that do nothing.
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        guard let provider = provider else { done(nil); return }
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            DispatchQueue.main.async { done(error) }
        }
    }

    /// Apple requires a reported call for EVERY VoIP push: report a throwaway
    /// and end it at once.
    private func reportAndDiscard(from: String, completion: @escaping () -> Void) {
        let dummy = UUID()
        reportIncoming(uuid: dummy, from: from, display: from) { [weak self] _ in
            self?.provider?.reportCall(with: dummy, endedAt: nil, reason: .remoteEnded)
            completion()
        }
    }
}

// MARK: - PushKit

extension PiopiyCallCore: PKPushRegistryDelegate {

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
        start()
        let data = payload.dictionaryPayload as? [String: Any] ?? [:]
        let kind = (data["type"] as? String) ?? "incoming_call"
        let from = (data["from"] as? String) ?? (data["caller"] as? String) ?? "Incoming call"
        let rawUuid = (data["uuid"] as? String) ?? (data["call_id"] as? String) ?? ""

        if kind == "cancel_call" {
            // The caller hung up while ringing (same uuid as the invite) —
            // unless this device answered (multi-device dismissal echo).
            reportAndDiscard(from: from) { [weak self] in
                if let self = self, let uuid = UUID(uuidString: rawUuid) {
                    let key = uuid.uuidString.lowercased()
                    if !self.answered.contains(key) {
                        self.forget(key)
                        self.provider?.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
                    }
                }
                completion()
            }
            emit(["event": "push", "payload": data])
            return
        }

        if kind != "incoming_call" {
            // Not a voice call (e.g. the app's own VoIP payloads) — Dart
            // routes it to 'otherPush'.
            reportAndDiscard(from: from, completion: completion)
            emit(["event": "push", "payload": data])
            return
        }

        let uuid = UUID(uuidString: rawUuid) ?? UUID()
        let key = uuid.uuidString.lowercased()

        if defaults.bool(forKey: Key.signedOut) {
            // Signed out: a payload alone could join the call — refuse it.
            reportAndDiscard(from: from, completion: completion)
            return
        }

        var stored = data
        stored["uuid"] = key
        storePayload(key, stored)
        reportIncoming(uuid: uuid, from: from, display: PiopiyCallCore.display(data, from: from)) { [weak self] error in
            if let error = error as? CXErrorCodeIncomingCallError, error.code != .callUUIDAlreadyExists {
                // Do-Not-Disturb, block list, ... — the call can't ring.
                self?.forget(key)
                self?.emit(["event": "end", "uuid": key, "reason": "failed"])
            }
            completion()
        }
        emit(["event": "push", "payload": stored])

        // Native ring-timeout backstop, a few seconds above the Dart ringTime.
        let ringTime = (defaults.object(forKey: Key.ringTime) as? Int) ?? 40
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, !self.answered.contains(key) else { return }
            self.forget(key)
            self.provider?.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
            self.emit(["event": "end", "uuid": key, "reason": "ring_timeout", "from": from])
        }
        ringTimers[key]?.cancel()
        ringTimers[key] = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(ringTime + 5), execute: timer)
    }
}

// MARK: - CallKit actions

extension PiopiyCallCore: CXProviderDelegate {

    public func providerDidReset(_ provider: CXProvider) {
        for (_, timer) in ringTimers { timer.cancel() }
        ringTimers.removeAll()
        payloads.removeAll()
        payloadOrder.removeAll()
        answered.removeAll()
        localEnds.removeAll()
        muted.removeAll()
        expectedMute.removeAll()
        emit(["event": "reset"])
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let key = action.callUUID.uuidString.lowercased()
        answered.insert(key)
        ringTimers.removeValue(forKey: key)?.cancel()
        emit(["event": "answer", "uuid": key])
        action.fulfill() // immediately — delayed fulfillment breaks the UI
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let key = action.callUUID.uuidString.lowercased()
        forget(key)
        answered.remove(key)
        if localEnds.remove(key) == nil {
            emit(["event": "end", "uuid": key, "reason": "user"])
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let key = action.callUUID.uuidString.lowercased()
        muted[key] = action.isMuted
        if let expected = expectedMute.removeValue(forKey: key), expected == action.isMuted {
            // Our own sync of an app-initiated mute — Dart already knows.
        } else {
            emit(["event": "mute", "uuid": key, "muted": action.isMuted])
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        let key = action.callUUID.uuidString.lowercased()
        emit(["event": "hold", "uuid": key, "hold": action.isOnHold])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        let key = action.callUUID.uuidString.lowercased()
        emit(["event": "dtmf", "uuid": key, "digits": action.digits])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        emit(["event": "audioActivated"])
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        emit(["event": "audioDeactivated"])
    }
}
