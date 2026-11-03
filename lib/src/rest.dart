// TeleCMI REST — login token + device push-token registration.
// Same endpoints, payloads and result codes as the JS/React Native SDKs
// (rest.js): getToken → {code: 200, token} or {code: 407}; push calls → the
// server's JSON on HTTP 200, {code: <status>} otherwise, {code: 500} on a
// network error or unparsable body, {code: 408} on timeout.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const String kDefaultApiBase = 'https://rest.telecmi.com/v2';

class PiopiyRest {
  PiopiyRest({String? apiBase})
      : apiBase = (apiBase == null || apiBase.trim().isEmpty)
            ? kDefaultApiBase
            : apiBase.trim().replaceAll(RegExp(r'/+$'), '');

  final String apiBase;

  void Function(String line)? log;

  void _log(String line) => log?.call('[rest] $line');

  static String _snip(String body, int max) =>
      body.length > max ? body.substring(0, max) : body;

  Future<http.Response> _send(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
  }) {
    return http
        .post(
          Uri.parse('$apiBase$path'),
          headers: {
            'Content-Type': 'application/json;charset=UTF-8',
            if (bearer != null) 'Authorization': 'Bearer $bearer',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 5));
  }

  /// POST /user/login — exchanges agent credentials for the REST auth token
  /// (the bearer the push registration endpoints require, also exposed to
  /// apps via Piopiy.getAuthToken()).
  Future<Map<String, dynamic>> getToken(String userId, String password) async {
    _log('POST $apiBase/user/login (auth token for push registration)');
    try {
      final res =
          await _send('/user/login', {'id': userId, 'password': password});
      _log('HTTP ${res.statusCode} ← /user/login body=${_snip(res.body, 200)}');
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['code'] == 200 && decoded['token'] is String) {
          return {'code': 200, 'token': decoded['token']};
        }
      }
    } on TimeoutException {
      _log('TIMEOUT ← /user/login');
    } catch (e) {
      _log('error ← /user/login: $e');
    }
    return {'code': 407};
  }

  /// POST /push/register — registers the device push token so this device is
  /// woken for incoming calls.
  Future<Map<String, dynamic>> registerPush(
    String authToken, {
    required String token,
    required String provider, // 'apns' | 'fcm'
    String? platform, // 'ios' | 'android'
    required String sbc,
  }) {
    return _pushCall('/push/register', authToken, {
      'token': token,
      'provider': provider,
      'platform': ?platform,
      'sbc': sbc,
    });
  }

  /// POST /push/unregister — stops push wake-ups (sign-out / DND).
  Future<Map<String, dynamic>> unregisterPush(
    String authToken, {
    required String token,
  }) {
    return _pushCall('/push/unregister', authToken, {'token': token});
  }

  Future<Map<String, dynamic>> _pushCall(
    String path,
    String? authToken,
    Map<String, dynamic> body,
  ) async {
    final masked = Map<String, dynamic>.from(body);
    final t = masked['token'];
    if (t is String) masked['token'] = '${t.substring(0, t.length > 10 ? 10 : t.length)}…';
    _log('POST $apiBase$path auth=${authToken != null ? 'yes' : 'NO'} body=${jsonEncode(masked)}');
    try {
      final res = await _send(path, body, bearer: authToken);
      _log('HTTP ${res.statusCode} ← $path body=${_snip(res.body, 300)}');
      if (res.statusCode != 200) return {'code': res.statusCode};
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return {'code': 500};
    } on TimeoutException {
      _log('TIMEOUT ← $path');
      return {'code': 408};
    } catch (e) {
      _log('NETWORK ERROR ← $path ($e) — is the host reachable from the device?');
      return {'code': 500};
    }
  }
}
