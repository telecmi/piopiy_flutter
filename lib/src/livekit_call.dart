// LiveKit inbound-call engine — the gateway way, identical to the React
// Native SDK: FreeSWITCH bridges the caller into a LiveKit room via LiveKit
// SIP, the VoIP push carries {uuid, room, token, url}, and the SDK simply
// joins the room when the user answers. The room waits server-side, so
// joining is retryable — no one-shot SIP INVITE to catch on a cold launch.

import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

import 'events.dart';

/// One pending/active inbound call delivered by push.
class InboundCall {
  InboundCall({
    required this.uuid,
    required this.room,
    required this.token,
    required this.url,
    required this.from,
    this.name = '',
    this.team = '',
  });

  final String uuid;
  final String room;
  final String token;
  final String url;
  final String from;
  final String name;
  final String team;

  static InboundCall? fromPayload(Map<String, dynamic> data) {
    final uuid = (data['uuid'] ?? data['call_id'] ?? '').toString();
    final room = (data['room'] ?? '').toString();
    final token = (data['token'] ?? '').toString();
    final url = (data['url'] ?? '').toString();
    if (uuid.isEmpty || room.isEmpty || token.isEmpty || url.isEmpty) {
      return null;
    }
    return InboundCall(
      uuid: uuid.toLowerCase(),
      room: room,
      token: token,
      url: url,
      from: (data['from'] ?? data['caller'] ?? 'Incoming call').toString(),
      name: (data['name'] ?? '').toString(),
      team: (data['team'] ?? '').toString(),
    );
  }
}

class LiveKitEngine {
  LiveKitEngine(this._events, {this.log});

  final PiopiyEvents _events;
  final void Function(String line)? log;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  InboundCall? _active;
  bool _connecting = false;
  bool _micMuted = false;

  void _dbg(String line) => log?.call('[livekit] $line');

  bool get isConnected =>
      _room != null && _room!.connectionState == ConnectionState.connected;

  String? get activeUuid => _active?.uuid;

  /// Join the held room — called when the user answers. Retryable by design:
  /// the room waits server-side.
  Future<bool> answer(InboundCall call) async {
    if (_connecting) return false;
    _connecting = true;
    _active = call;
    try {
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: false,
          dynacast: false,
          defaultAudioPublishOptions: AudioPublishOptions(dtx: true),
        ),
      );
      _room = room;
      _listener = room.createListener();
      _listener!
        ..on<RoomDisconnectedEvent>((e) {
          _dbg('room disconnected: ${e.reason}');
          _teardown(emitEnded: true);
        })
        ..on<ParticipantDisconnectedEvent>((e) {
          // Per-call room, 1 caller : 1 agent — the other side leaving means
          // the call is over (the server also deletes the room).
          _dbg('remote participant left: ${e.participant.identity}');
          _teardown(emitEnded: true);
        });

      _dbg('answer(): joining room ${call.room} at ${call.url}');
      await room.connect(call.url, call.token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      _micMuted = false;
      _connecting = false;
      _events.emit('answered', {'uuid': call.uuid, 'from': call.from});
      return true;
    } catch (e) {
      _connecting = false;
      _dbg('join failed: $e');
      _events.emit('error', {'code': 1009, 'status': 'call connect failed'});
      _teardown(emitEnded: true);
      return false;
    }
  }

  Future<void> hangup() async {
    _dbg('hangup()');
    await _teardown(emitEnded: true);
  }

  Future<void> setMuted(bool muted) async {
    _micMuted = muted;
    await _room?.localParticipant?.setMicrophoneEnabled(!muted);
    _events.emit(muted ? 'mute' : 'unMute', {'uuid': _active?.uuid});
  }

  bool get isMuted => _micMuted;

  Future<void> setSpeaker(bool on) async {
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(on);
      _events.emit('speaker', {'on': on});
    } catch (e) {
      _dbg('setSpeaker failed: $e');
    }
  }

  /// A cancel push (or native end) for [uuid] — ends the call if it is ours.
  Future<bool> endByUuid(String uuid) async {
    final id = uuid.toLowerCase();
    if (_active == null || _active!.uuid != id) return false;
    await _teardown(emitEnded: true);
    return true;
  }

  Future<void> _teardown({bool emitEnded = false}) async {
    final uuid = _active?.uuid;
    final hadCall = _active != null || _room != null;
    _active = null;
    try {
      await _listener?.dispose();
    } catch (_) {}
    _listener = null;
    final room = _room;
    _room = null;
    try {
      await room?.disconnect();
      await room?.dispose();
    } catch (_) {}
    if (emitEnded && hadCall) {
      _events.emit('ended', {'uuid': uuid});
    }
  }
}
