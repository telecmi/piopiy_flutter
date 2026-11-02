// TeleCMI REST — login token + device push-token registration.
// Same endpoints and payloads as the JS/React Native SDKs (rest.js).

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

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
  }) async {
    final url = Uri.parse('$apiBase$path');
    _log('POST $url');
    try {
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json;charset=UTF-8',
              if (bearer != null) 'Authorization': 'Bearer $bearer',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
      _log('HTTP ${res.statusCode} ← $path '
          'body=${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
      return {'code': res.statusCode == 200 ? 407 : res.statusCode};
    } on TimeoutException {
      _log('timeout ← $path');
      return {'code': 408};
    } catch (e) {
      _log('error ← $path: $e');
      return {'code': 407};
    }
  }

  /// POST /user/login — exchanges agent credentials for the REST auth token
  /// (the bearer the push registration endpoints require, also exposed to
  /// apps via Piopiy.getAuthToken()).
  Future<Map<String, dynamic>> getToken(String userId, String password) async {
    final res =
        await _post('/user/login', {'id': userId, 'password': password});
    if (res['code'] == 200 && res['token'] is String) {
      return {'code': 200, 'token': res['token']};
    }
    return {'code': 407};
  }

  /// POST /push/register — registers the device push token so this device is
  /// woken for incoming calls.
  Future<Map<String, dynamic>> registerPush(
    String authToken, {
    required String token,
    required String provider, // 'apns' | 'fcm'
    required String platform, // 'ios' | 'android'
    required String sbc,
  }) {
    return _post(
      '/push/register',
      {'token': token, 'provider': provider, 'platform': platform, 'sbc': sbc},
      bearer: authToken,
    );
  }

  /// POST /push/unregister — stops push wake-ups (sign-out / DND).
  Future<Map<String, dynamic>> unregisterPush(
    String authToken, {
    required String token,
  }) {
    return _post('/push/unregister', {'token': token}, bearer: authToken);
  }
}
