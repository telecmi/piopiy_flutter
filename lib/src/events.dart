// Event emitter with the same contract as the JS SDK's `on`/`off`/`emit` —
// apps porting from @telecmi/piopiy-native keep their event wiring verbatim.

typedef PiopiyListener = void Function(dynamic data);

class PiopiyEvents {
  final Map<String, List<PiopiyListener>> _listeners = {};

  /// Subscribe. Events mirror the JS SDK: 'login', 'loginFailed', 'logout',
  /// 'trying', 'ringing', 'answered', 'ended', 'hangup', 'inComingCall',
  /// 'mediaFailed', 'pushRegistered', 'error'.
  void on(String event, PiopiyListener listener) {
    _listeners.putIfAbsent(event, () => []).add(listener);
  }

  /// Unsubscribe one listener, or every listener of the event when
  /// [listener] is null.
  void off(String event, [PiopiyListener? listener]) {
    if (listener == null) {
      _listeners.remove(event);
      return;
    }
    _listeners[event]?.remove(listener);
  }

  void emit(String event, [dynamic data]) {
    final list = _listeners[event];
    if (list == null) return;
    // Copy: a listener may unsubscribe (itself) while we iterate.
    for (final l in List<PiopiyListener>.from(list)) {
      try {
        l(data);
      } catch (_) {
        // A listener's crash must never break the SDK's event loop.
      }
    }
  }
}
