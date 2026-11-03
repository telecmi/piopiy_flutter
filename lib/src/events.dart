// Event emitter with the same contract as the JS SDK's on/off/once/emit —
// apps porting from @telecmi/piopiy-native keep their event wiring verbatim.
// Event names and payload shapes are the React Native SDK's (index.d.ts):
//
//   connection   connected · disconnected · login · loginFailed · logout ·
//                sbc_logout · net_changed
//   call         inComingCall · trying · ringing · answered · hold · unhold ·
//                ended · hangup · missedCall · error
//   media        callStream · mediaFailed · dtmf · NETStats · RTC · RTCStats
//   push         pushRegistered · pushUnregistered · otherPush · callkeepCancel
//   server       transfer · record
//   Flutter-only log (every internal SDK line, for diagnostics)

typedef PiopiyListener = void Function(dynamic data);

class PiopiyEvents {
  final Map<String, List<PiopiyListener>> _listeners = {};
  // once() wraps the listener; off(event, original) must find the wrapper.
  final Map<PiopiyListener, PiopiyListener> _onceWrappers = {};

  /// Subscribe to [event]. See the event table at the top of this file.
  void on(String event, PiopiyListener listener) {
    _listeners.putIfAbsent(event, () => []).add(listener);
  }

  /// Subscribe for a single delivery of [event].
  void once(String event, PiopiyListener listener) {
    late final PiopiyListener wrapper;
    wrapper = (data) {
      off(event, listener);
      listener(data);
    };
    _onceWrappers[listener] = wrapper;
    on(event, wrapper);
  }

  /// Unsubscribe one listener, or every listener of the event when
  /// [listener] is null.
  void off(String event, [PiopiyListener? listener]) {
    if (listener == null) {
      _listeners.remove(event);
      return;
    }
    final wrapper = _onceWrappers.remove(listener);
    final list = _listeners[event];
    if (list == null) return;
    list.remove(wrapper ?? listener);
    if (list.isEmpty) _listeners.remove(event);
  }

  /// Remove every listener of [event], or of all events when null.
  void removeAllListeners([String? event]) {
    if (event == null) {
      _listeners.clear();
      _onceWrappers.clear();
    } else {
      _listeners.remove(event);
    }
  }

  int listenerCount(String event) => _listeners[event]?.length ?? 0;

  /// Returns true when at least one listener received the event (the JS
  /// EventEmitter contract).
  bool emit(String event, [dynamic data]) {
    final list = _listeners[event];
    if (list == null || list.isEmpty) return false;
    // Copy: a listener may unsubscribe (itself) while we iterate.
    for (final l in List<PiopiyListener>.from(list)) {
      try {
        l(data);
      } catch (_) {
        // A listener's crash must never break the SDK's event loop.
      }
    }
    return true;
  }
}
