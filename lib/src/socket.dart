// TeleCMI notify socket — the Flutter port of socket.js (SocketCMI). Opened
// with the REST auth token after login; carries call transfer, recording
// state and forced sign-out from the platform, and the transfer requests.

import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

const String kNotifyUrl = 'https://notify.telecmi.com';

class SocketCMI {
  SocketCMI(
    String token, {
    required this.onTransfer,
    required this.onRecord,
    required this.onForceLogout,
    required this.onNetChanged,
    this.log,
  }) {
    _socket = io.io(
      kNotifyUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setQuery({'token': token})
          // A fresh connection per login — the cached manager would keep the
          // previous session's token in its query.
          .enableForceNew()
          .enableReconnection()
          .build(),
    );

    _socket.onConnect((_) {
      readyTransfer = true;
      _dbg('connected');
      _socket.emit('wssip-agent-opt', {'join': true});
    });
    _socket.onDisconnect((reason) {
      readyTransfer = false;
      _dbg('disconnected: $reason');
      // The transport itself dropped (network change): tell the SIP layer
      // to reconnect instead of waiting for its own recovery timer.
      if (reason == 'transport close') onNetChanged();
    });
    _socket.onConnectError((e) {
      readyTransfer = false;
      _dbg('connect error: $e');
    });
    _socket.on('cmi_transfer', (data) => onTransfer(_asMap(data)));
    _socket.on('force_logout', (data) => onForceLogout(_asMap(data)));
    _socket.on('cmi_record', (data) => onRecord(_asMap(data)));
  }

  late final io.Socket _socket;

  final void Function(Map<String, dynamic> data) onTransfer;
  final void Function(Map<String, dynamic> data) onRecord;
  final void Function(Map<String, dynamic> data) onForceLogout;
  final void Function() onNetChanged;
  final void Function(String line)? log;

  /// True while the socket is connected (transfer requests can go out).
  bool readyTransfer = false;

  bool _disposed = false;

  void _dbg(String line) => log?.call('[notify] $line');

  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    return {'data': data};
  }

  /// Blind/attended transfer of the agent's live call to [to].
  Future<Map<String, dynamic>> transfer(String uuid, String to) =>
      _request('agent-call-transfer', {'uuid': uuid, 'to': to});

  /// Transfer the agent's live call to a team.
  Future<Map<String, dynamic>> teamTransfer(String uuid, String to) =>
      _request('team-call-transfer', {'uuid': uuid, 'to': to});

  void cancelTransfer(String uuid) {
    if (_socket.connected) {
      _socket.emit('agent-cancel-transfer', {'uuid': uuid});
    }
  }

  Future<Map<String, dynamic>> _request(String event, Map<String, dynamic> body) {
    if (!_socket.connected) {
      return Future.value({'error': 'Socket is not connected'});
    }
    final done = Completer<Map<String, dynamic>>();
    _socket.emitWithAck(event, body, ack: ([dynamic data]) {
      if (!done.isCompleted) done.complete(_asMap(data));
    });
    // The JS SDK waits forever; a Future that never completes is worse.
    return done.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => {'error': 'No response from the server'},
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    readyTransfer = false;
    try {
      _socket.dispose();
    } catch (_) {}
  }
}
