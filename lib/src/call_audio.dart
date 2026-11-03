// Call audio session — the Flutter counterpart of the React Native SDK's
// InCallManager / LiveKit AudioSession handling. livekit_client owns the
// platform audio session for the whole process (it disables flutter_webrtc's
// own management), so both call paths go through it:
//
//   SIP (outbound)   — acquire/release the session exactly like a LiveKit room
//                      does on connect/disconnect (InCallManager.start/stop).
//   push (inbound)   — iOS: CallKit owns activation. LiveKit runs in
//                      externalCallSystem mode and the WebRTC engine is gated
//                      until CallKit's didActivate (the RN SDK's
//                      audioSessionDidActivate sync). Android: Telecom +
//                      LiveKit's normal session.
//
// Every call starts on the EARPIECE: LiveKit defaults to the loudspeaker
// (it targets video chat) — the RN 0.18.1 "calls answered on speaker" bug.

// AudioManager's session-management mode and engine availability are
// livekit_client's documented CallKit contract (2.9+), still marked
// experimental upstream.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io' show Platform;

import 'package:livekit_client/livekit_client.dart';
// ignore: implementation_imports
import 'package:livekit_client/src/track/audio_management.dart'
    show NativeAudioManagement;

class CallAudio {
  CallAudio({this.log});

  final void Function(String line)? log;

  bool _speakerOn = false;
  bool _sipActive = false;
  bool _inboundActive = false;

  /// iOS: CallKit's AVAudioSession is active (didActivate seen).
  bool callKitAudioActive = false;

  bool get speakerOn => _speakerOn;

  void _dbg(String line) => log?.call('[audio] $line');

  Future<void> _try(String what, Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      _dbg('$what failed: $e');
    }
  }

  // ---------------------------------------------------------------- SIP

  /// Outbound (SIP) call starting: acquire the session, earpiece route.
  Future<void> startSip() async {
    if (_sipActive) return;
    _sipActive = true;
    _speakerOn = false;
    if (Platform.isIOS) {
      // A SIP call is not CallKit-managed: LiveKit activates the session.
      await _try('management mode', () => AudioManager.instance
          .setAudioSessionManagementMode(AudioSessionManagementMode.automatic));
      await _try('engine availability', () => AudioManager.instance
          .setEngineAvailability(AudioEngineAvailability.defaultAvailability));
    }
    await _try('speaker preference',
        () => AudioManager.instance.setSpeakerOutputPreferred(false));
    await _try('session start', NativeAudioManagement.start);
    _dbg('SIP audio started (earpiece)');
  }

  Future<void> stopSip() async {
    if (!_sipActive) return;
    _sipActive = false;
    _speakerOn = false;
    await _try('session stop', NativeAudioManagement.stop);
    _dbg('SIP audio stopped');
  }

  // ------------------------------------------------------------ inbound

  /// Inbound (push) call about to join its room.
  Future<void> prepareInbound() async {
    _inboundActive = true;
    _speakerOn = false;
    await _try('speaker preference',
        () => AudioManager.instance.setSpeakerOutputPreferred(false));
    if (!Platform.isIOS) return;
    // CallKit owns activation; racing it leaves the call silent with the
    // route stuck. The engine waits for didActivate unless it already came.
    await _try('management mode', () => AudioManager.instance
        .setAudioSessionManagementMode(
            AudioSessionManagementMode.externalCallSystem));
    await _try(
        'engine availability',
        () => AudioManager.instance.setEngineAvailability(callKitAudioActive
            ? AudioEngineAvailability.defaultAvailability
            : AudioEngineAvailability.none));
    _dbg('inbound audio prepared — CallKit session '
        '${callKitAudioActive ? 'active' : 'pending'}');
  }

  /// CallKit activated the AVAudioSession: let the engine run.
  Future<void> onCallKitActivated() async {
    callKitAudioActive = true;
    if (!Platform.isIOS || !_inboundActive) return;
    await _try('engine availability', () => AudioManager.instance
        .setEngineAvailability(AudioEngineAvailability.defaultAvailability));
    _dbg('CallKit audio active → engine enabled');
  }

  /// CallKit deactivated the AVAudioSession: stop the engine.
  Future<void> onCallKitDeactivated() async {
    callKitAudioActive = false;
    if (!Platform.isIOS || !_inboundActive) return;
    await _try('engine availability', () => AudioManager.instance
        .setEngineAvailability(AudioEngineAvailability.none));
    _dbg('CallKit audio inactive → engine held');
  }

  /// iOS fallback (the RN 1.5 s rule): an answered call whose didActivate
  /// never arrived (delayed/dropped on a killed or locked launch) would stay
  /// connected but silent — let LiveKit activate the session itself.
  Future<void> forceInboundAudio() async {
    if (!Platform.isIOS || !_inboundActive || callKitAudioActive) return;
    _dbg('didActivate not seen → activating the session ourselves');
    await _try('management mode', () => AudioManager.instance
        .setAudioSessionManagementMode(AudioSessionManagementMode.automatic));
    await _try('engine availability', () => AudioManager.instance
        .setEngineAvailability(AudioEngineAvailability.defaultAvailability));
  }

  /// Inbound call finished: hand the session back to LiveKit's default
  /// management (outbound SIP calls rely on it).
  Future<void> releaseInbound() async {
    if (!_inboundActive) return;
    _inboundActive = false;
    _speakerOn = false;
    if (!Platform.isIOS) return;
    await _try('engine availability', () => AudioManager.instance
        .setEngineAvailability(AudioEngineAvailability.defaultAvailability));
    await _try('management mode', () => AudioManager.instance
        .setAudioSessionManagementMode(AudioSessionManagementMode.automatic));
  }

  // ------------------------------------------------------------ routing

  /// Loudspeaker (true) or earpiece/default route (false).
  Future<bool> setSpeaker(bool on) async {
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(on);
      _speakerOn = on;
      _dbg('speaker ${on ? 'ON (loudspeaker)' : 'off (default route)'}');
      return true;
    } catch (e) {
      _dbg('setSpeaker failed: $e');
      return false;
    }
  }

  /// The route changed outside the SDK (the native call screen's speaker
  /// button, a headset): mirror it so [speakerOn] — and the next LiveKit
  /// policy re-assert — agree with what the user hears.
  Future<void> syncSpeaker(bool on) async {
    if (_speakerOn == on) return;
    _dbg('route changed natively → speaker ${on ? 'ON' : 'off'}');
    await setSpeaker(on);
  }
}
