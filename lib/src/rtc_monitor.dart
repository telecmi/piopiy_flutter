// Media-path monitor for SIP calls — the Flutter port of RTCPeer.js +
// stats.js: ICE-state handling with the 0.26.5 restart grace, the `RTC`
// connectivity events, and per-second `RTCStats`.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'events.dart';

/// How long the ICE connection may stay 'disconnected' before an ICE restart
/// is requested. A short media pause on the switch (every attended-transfer
/// step, and hold) reports 'disconnected' and recovers by itself; restarting
/// ICE at that moment renegotiates a connection that is about to come back,
/// and on FreeSWITCH 1.10 a restarted ICE session often never carries media
/// again. 'failed' is final and is restarted at once.
const Duration kIceDisconnectedGrace = Duration(seconds: 5);

class RtcMonitor {
  RtcMonitor(this._events, {required this.restartIce, this.log});

  final PiopiyEvents _events;

  /// Renegotiates the session with an ICE restart.
  final void Function() restartIce;
  final void Function(String line)? log;

  RTCPeerConnection? _pc;
  Timer? _grace;
  Timer? _stats;
  bool _disposed = false;

  void _dbg(String line) => log?.call('[rtc] $line');

  /// Start watching [pc]. sip_ua owns `onIceConnectionState` already (it
  /// terminates the call on 'failed'), so its handler is chained, not
  /// replaced.
  void attach(RTCPeerConnection pc) {
    if (_disposed || identical(_pc, pc)) return;
    _pc = pc;
    final previous = pc.onIceConnectionState;
    pc.onIceConnectionState = (RTCIceConnectionState state) {
      previous?.call(state);
      _onIceState(state);
    };
  }

  void _onIceState(RTCIceConnectionState state) {
    if (_disposed) return;
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        // Transient: restart only if it has not recovered within the grace.
        _clearGrace();
        _grace = Timer(kIceDisconnectedGrace, () {
          _grace = null;
          final now = _pc?.iceConnectionState;
          if (now == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
              now == RTCIceConnectionState.RTCIceConnectionStateFailed) {
            _restart();
          }
        });
        _events.emit('RTC', {'state': 'disconnected', 'msg': 'CMI_NET'});
        break;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _clearGrace();
        _restart();
        _events.emit('RTC', {'state': 'disconnected', 'msg': 'CMI_NET'});
        break;
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
        _clearGrace();
        _startStats();
        _events.emit('RTC', {'state': 'connected', 'msg': 'CMI_NET'});
        break;
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        // 'completed' follows 'connected' on the same connection: no second
        // 'connected' event and no new stats collection.
        _clearGrace();
        break;
      default:
        break;
    }
  }

  void _restart() {
    _stopStats();
    _dbg('ICE restart');
    try {
      restartIce();
    } catch (e) {
      _dbg('ICE restart failed: $e');
    }
  }

  void _clearGrace() {
    _grace?.cancel();
    _grace = null;
  }

  void _startStats() {
    _stopStats();
    final pc = _pc;
    if (pc == null) return;
    var lastTimestamp = DateTime.now();
    num lastPacketsLost = 0;
    final stats = <String, dynamic>{};
    var polling = false;

    _stats = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_disposed || !identical(_pc, pc)) {
        timer.cancel();
        return;
      }
      final cs = pc.connectionState;
      if (cs != null && cs != RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        timer.cancel();
        return;
      }
      if (polling) return; // a slow getStats() must not stack polls
      polling = true;
      try {
        final reports = await pc.getStats();
        for (final report in reports) {
          final v = report.values;
          switch (report.type) {
            case 'candidate-pair':
              if (v['nominated'] == true) {
                stats['delay'] = v['currentRoundTripTime'];
              }
              break;
            case 'inbound-rtp':
              final lost = v['packetsLost'];
              if (lost is num) {
                final now = DateTime.now();
                final elapsed =
                    now.difference(lastTimestamp).inMilliseconds / 1000;
                if (elapsed > 0) {
                  stats['packetLostRate'] = (lost - lastPacketsLost) / elapsed;
                }
                lastPacketsLost = lost;
                lastTimestamp = now;
              }
              break;
            case 'remote-inbound-rtp':
              stats['totalPacketLost'] = v['packetsLost'];
              stats['fractionLost'] = v['fractionLost'];
              stats['jitter'] = v['jitter'];
              stats['rountTrip'] = v['totalRoundTripTime'];
              break;
            case 'codec':
              stats['codec'] = v['mimeType'];
              break;
            case 'local-candidate':
              stats['network'] = v['networkType'];
              break;
          }
        }
        if (!_disposed) {
          _events.emit('RTCStats', Map<String, dynamic>.from(stats));
        }
      } catch (_) {
        // getStats on a closing connection — the next tick stops the timer.
      } finally {
        polling = false;
      }
    });
  }

  void _stopStats() {
    _stats?.cancel();
    _stats = null;
  }

  void dispose() {
    _disposed = true;
    _clearGrace();
    _stopStats();
    _pc = null;
  }
}
