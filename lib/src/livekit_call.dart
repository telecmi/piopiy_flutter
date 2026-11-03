// Inbound-call engine — the Flutter port of livekitCall.native.js, the
// gateway way: FreeSWITCH bridges the caller into a LiveKit room via LiveKit
// SIP, the push carries {uuid, room, token, url}, and the SDK joins the room
// when the user answers. The room waits server-side, so joining is retryable —
// no one-shot SIP INVITE to catch on a cold launch.

import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

import 'call_audio.dart';
import 'events.dart';

/// One pending/active inbound call delivered by push.
class InboundCall {
  InboundCall({
    required this.uuid,
    required this.room,
    required this.token,
    required this.url,
    required this.from,
    this.name,
    this.team,
    this.transfer = false,
    this.transferFrom,
  });

  final String uuid;
  final String room;
  final String token;
  final String? url;

  /// Caller's number. FCM delivers it as `caller` — `from` is an
  /// FCM-reserved data key.
  final String from;

  /// Caller's resolved display name, when the platform provides one.
  final String? name;

  /// Team/queue that routed the call.
  final String? team;
  final bool transfer;
  final String? transferFrom;

  /// What the native call screen shows: "Priya Sharma — support3",
  /// "+91… — support3", or just the number.
  String get display {
    final primary = (name != null && name!.isNotEmpty) ? name! : from;
    return (team != null && team!.isNotEmpty) ? '$primary — $team' : primary;
  }

  /// Parses an invite push. Requires uuid, room and token (url may come from
  /// the `livekitUrl` option).
  static InboundCall? fromPayload(Map<String, dynamic> data, {String? fallbackUrl}) {
    String str(String key) => (data[key] ?? '').toString().trim();
    final uuid = str('uuid').isNotEmpty ? str('uuid') : str('call_id');
    final room = str('room');
    final token = str('token');
    if (uuid.isEmpty || room.isEmpty || token.isEmpty) return null;
    final url = str('url');
    final from = str('from').isNotEmpty
        ? str('from')
        : (str('caller').isNotEmpty ? str('caller') : 'Incoming call');
    final transferRaw = data['transfer'];
    return InboundCall(
      uuid: uuid.toLowerCase(),
      room: room,
      token: token,
      url: url.isNotEmpty ? url : fallbackUrl,
      from: from,
      name: str('name').isNotEmpty ? str('name') : null,
      team: str('team').isNotEmpty
          ? str('team')
          : (str('team_name').isNotEmpty ? str('team_name') : null),
      transfer: transferRaw == true ||
          RegExp(r'^(true|1|yes)$', caseSensitive: false)
              .hasMatch((transferRaw ?? '').toString()),
      transferFrom: str('transfer_from').isNotEmpty ? str('transfer_from') : null,
    );
  }
}

/// Native call-UI actions the engine needs (implemented by the facade).
abstract class InboundCallHost {
  /// The ringing call ended without being answered — dismiss the native UI.
  /// [reason]: 'caller cancelled' | 'ring timeout' | 'rejected' | ...
  void dismissRinging(String uuid, String reason);

  /// The connected call ended — end the native call.
  void endConnected(String uuid, {required bool remote});
}

class LiveKitEngine {
  LiveKitEngine(this._events, this._audio, this._host,
      {required this.ringTime, this.fallbackUrl, this.log});

  final PiopiyEvents _events;
  final CallAudio _audio;
  final InboundCallHost _host;
  final int ringTime;
  final String? fallbackUrl;
  final void Function(String line)? log;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  InboundCall? _pending; // ringing
  InboundCall? _active; // answered (connecting or connected)
  Timer? _ringTimer;
  Timer? _audioFallback;
  bool _muted = false;

  void _dbg(String line) => log?.call('[livekit] $line');

  bool hasPending() => _pending != null;
  InboundCall? get pending => _pending;
  InboundCall? get active => _active;

  /// Is [uuid] (or, with null, any call) ours?
  bool isCall([String? uuid]) {
    final u = uuid?.toLowerCase();
    if (_pending != null && (u == null || _pending!.uuid == u)) return true;
    if (_active != null && (u == null || _active!.uuid == u)) return true;
    return false;
  }

  bool get isMuted => _muted;
  bool get isConnected =>
      _room != null && _room!.connectionState == ConnectionState.connected;

  /// An invite push. Emits 'inComingCall'; returns false when the payload is
  /// unusable. Dedupes the same uuid (it can arrive by more than one path).
  bool setPending(InboundCall call) {
    if (_pending?.uuid == call.uuid || _active?.uuid == call.uuid) {
      _dbg('setPending — already have ${call.uuid}, ignoring duplicate');
      return true;
    }
    if (_active != null) {
      // One call at a time: a second inbound call while one is live.
      _dbg('setPending — busy with ${_active!.uuid}, dismissing ${call.uuid}');
      _host.dismissRinging(call.uuid, 'busy');
      return false;
    }
    _pending = call;
    _dbg('pending inbound call — from ${call.from} | room ${call.room} | uuid ${call.uuid}');
    // Ring timeout: if the device loses its connection right after the push,
    // the server's cancel push can never arrive — without a local bound the
    // call screen rings forever.
    _ringTimer?.cancel();
    _ringTimer = Timer(Duration(seconds: ringTime), () {
      _ringTimer = null;
      if (_pending != null && _pending!.uuid == call.uuid) {
        _dbg('ring timeout — no answer after ${ringTime}s, ending pending call');
        end('ring timeout');
      }
    });
    _events.emit('inComingCall', {
      'from': call.from,
      if (call.name != null) 'name': call.name,
      if (call.team != null) 'team_name': call.team,
      'call_id': call.uuid,
      if (call.transferFrom != null) 'transfer_from': call.transferFrom,
      'transfer': call.transfer,
      'transport': 'push',
    });
    return true;
  }

  /// Join the held room. Called when the user answers (natively or in-app).
  Future<bool> answer() async {
    final call = _pending;
    if (call == null) {
      _dbg('answer(): no pending call');
      return false;
    }
    final url = call.url;
    if (url == null || url.isEmpty) {
      _dbg('answer(): no media URL in the push and no livekitUrl option');
      _events.emit('error', {'code': 1009, 'status': 'call connection URL missing'});
      end('no url');
      return false;
    }
    _pending = null;
    _active = call;
    _ringTimer?.cancel();
    _ringTimer = null;
    _dbg('answer(): joining room ${call.room} at $url');

    // answer() awaits several times. A cancel or hangup can land BETWEEN those
    // awaits — its teardown clears _active. Without re-checking after every
    // await the in-flight answer resurrects the dead call: it emits 'answered'
    // after the app already saw 'hangup' (phantom in-call screen, corrupted
    // next call). Teardown always wins.
    bool aborted() => !identical(_active, call);

    await _audio.prepareInbound();
    if (aborted()) {
      _dbg('answer aborted — call ended while preparing audio');
      return false;
    }

    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: false,
        dynacast: false,
        defaultAudioPublishOptions: AudioPublishOptions(dtx: true),
      ),
    );
    _room = room;
    final listener = room.createListener();
    _listener = listener;
    listener.on<RoomDisconnectedEvent>((e) {
      // Ignore a room this engine no longer owns (one abandoned after losing
      // the answer/cancel race).
      if (!identical(_room, room)) return;
      _dbg('room disconnected — ${e.reason ?? 'no reason'}');
      _teardown('ended');
    });

    try {
      await room.connect(url, call.token); // autoSubscribe defaults to true
      if (aborted()) {
        _dbg('answer aborted — call cancelled during connect; leaving room');
        await _abandon(room, listener);
        return false;
      }
      _dbg('room CONNECTED — enabling microphone');
      try {
        await room.localParticipant?.setMicrophoneEnabled(true);
      } catch (e) {
        _dbg('setMicrophoneEnabled failed: $e');
      }
      if (aborted()) {
        _dbg('answer aborted — call cancelled just after connect; leaving room');
        await _abandon(room, listener);
        return false;
      }
      _muted = false;
      _events.emit('answered', {'code': 200, 'status': 'answered', 'transport': 'push'});
      _armAudioFallback(call);
      return true;
    } catch (e) {
      if (aborted()) {
        // The teardown that beat us already emitted the end events.
        _dbg('room.connect failed after cancel — already torn down: $e');
        return false;
      }
      _dbg('room.connect FAILED — $e');
      _events.emit('error', {'code': 1010, 'status': 'call connection failed: $e'});
      _teardown('ended');
      return false;
    }
  }

  // iOS: CallKit normally activates the audio session right after the answer
  // and the engine starts then. On a killed/locked cold launch that event can
  // be delayed or dropped — give it 1.5 s, then start audio ourselves.
  void _armAudioFallback(InboundCall call) {
    _audioFallback?.cancel();
    _audioFallback = Timer(const Duration(milliseconds: 1500), () {
      _audioFallback = null;
      if (identical(_active, call)) _audio.forceInboundAudio();
    });
  }

  Future<void> _abandon(Room room, EventsListener<RoomEvent> listener) async {
    if (identical(_room, room)) _room = null;
    if (identical(_listener, listener)) _listener = null;
    try {
      await listener.dispose();
    } catch (_) {}
    try {
      await room.disconnect();
      await room.dispose();
    } catch (_) {}
  }

  /// Mute/unmute the microphone (the published track is disabled; the room
  /// stays connected).
  Future<bool> setMuted(bool muted) async {
    final participant = _room?.localParticipant;
    if (participant == null) {
      _dbg('setMuted ignored — no connected room');
      return false;
    }
    try {
      await participant.setMicrophoneEnabled(!muted);
      _muted = muted;
      _dbg('microphone ${muted ? 'MUTED' : 'unmuted'}');
      return true;
    } catch (e) {
      _dbg('setMuted failed: $e');
      return false;
    }
  }

  /// Hang up / decline. Safe in any state. A ringing call that ends without
  /// the user acting on it ('caller cancelled' / 'ring timeout') is a missed
  /// call.
  bool end(String reason) {
    final ringing = _pending;
    final live = _active;
    if (ringing == null && live == null && _room == null) return false;
    _dbg('end() — $reason');
    if (live != null || _room != null) {
      _teardown('hangup', remote: false);
      return true;
    }
    final call = ringing!;
    _teardown(null);
    // Dismiss the native ring, and tell an app that renders its own ringing
    // UI (on 'inComingCall') to hide it.
    _host.dismissRinging(call.uuid, reason);
    _events.emit('callkeepCancel', {'uuid': call.uuid, 'reason': reason});
    _events.emit('ended', {
      'code': 200,
      'status': 'call ended',
      'reason': reason,
      'transport': 'push',
    });
    if (reason == 'caller cancelled' || reason == 'ring timeout') {
      _events.emit('missedCall', {
        'uuid': call.uuid,
        'from': call.from,
        'reason': reason == 'ring timeout' ? 'ring_timeout' : 'cancelled',
        'transport': 'push',
      });
    }
    return true;
  }

  void _teardown(String? emitEvent, {bool remote = true}) {
    final call = _active ?? _pending;
    final hadCall = _room != null || _active != null || _pending != null;
    final wasConnected = _active != null;
    final room = _room;
    final listener = _listener;
    _room = null;
    _listener = null;
    _pending = null;
    _active = null;
    _muted = false;
    _ringTimer?.cancel();
    _ringTimer = null;
    _audioFallback?.cancel();
    _audioFallback = null;
    if (listener != null || room != null) {
      () async {
        try {
          await listener?.dispose();
        } catch (_) {}
        try {
          await room?.disconnect();
          await room?.dispose();
        } catch (_) {}
      }();
    }
    _audio.releaseInbound();
    if (wasConnected && call != null) {
      _host.endConnected(call.uuid, remote: remote);
    }
    if (hadCall && emitEvent != null) {
      _events.emit(emitEvent, {
        'code': 200,
        'status': emitEvent == 'hangup' ? 'call hangup' : 'call ended',
        'transport': 'push',
      });
    }
  }
}
