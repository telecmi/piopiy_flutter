// PIOPIY Flutter example — sign in with TeleCMI agent credentials, dial out,
// receive calls on the native OS call UI. Credentials are saved after the
// first sign-in and the app signs in automatically from then on.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:piopiy_flutter/piopiy_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

final piopiy = Piopiy(const PiopiyOptions(name: 'PiopiyExample', debug: true));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
    // Killed-state Android wake-ups ring natively from the background isolate.
    FirebaseMessaging.onBackgroundMessage(piopiyBackgroundPushHandler);
  } catch (_) {
    // Firebase not configured (iOS-only run) — pushes come via PushKit.
  }
  runApp(const PiopiyExampleApp());
}

class PiopiyExampleApp extends StatelessWidget {
  const PiopiyExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PIOPIY Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF16A34A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _region = TextEditingController(text: 'sbcsg.telecmi.com');
  final _dial = TextEditingController();

  bool _signedIn = false;
  String _callState = 'idle';
  String _peer = '';
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _wire();
    _autoSignIn();
  }

  void _logLine(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '${TimeOfDay.now().format(context)}  $line');
      if (_log.length > 100) _log.removeLast();
    });
  }

  void _wire() {
    piopiy.on('login', (_) {
      setState(() => _signedIn = true);
      _logLine('✅ signed in');
    });
    piopiy.on('loginFailed', (d) => _logLine('⚠️ login failed: $d'));
    piopiy.on('logout', (_) {
      setState(() {
        _signedIn = false;
        _callState = 'idle';
      });
      _logLine('👋 signed out');
    });
    piopiy.on('pushRegistered', (_) => _logLine('📲 push token registered'));
    piopiy.on('inComingCall', (c) {
      setState(() {
        _callState = 'incoming';
        _peer = (c?['from'] ?? '').toString();
      });
      _logLine('📞 incoming from ${c?['from']}');
    });
    piopiy.on('trying', (_) {
      setState(() => _callState = 'outgoing');
      _logLine('trying…');
    });
    piopiy.on('ringing', (_) => _logLine('ringing…'));
    piopiy.on('answered', (_) {
      setState(() => _callState = 'active');
      _logLine('call connected');
    });
    piopiy.on('ended', (_) {
      setState(() => _callState = 'idle');
      _logLine('call ended');
    });
    piopiy.on('hangup', (d) {
      setState(() => _callState = 'idle');
      _logLine('call hung up ($d)');
    });
    piopiy.on('error', (e) => _logLine('⚠️ $e'));
    piopiy.on('log', (l) => debugPrint('[sdk] $l'));
  }

  Future<void> _autoSignIn() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString('voice.user');
    final p = prefs.getString('voice.pass');
    final r = prefs.getString('voice.region');
    if (u != null && p != null) {
      _user.text = u;
      _pass.text = p;
      if (r != null) _region.text = r;
      _logLine('auto sign-in (saved)');
      await _signIn();
    }
  }

  Future<void> _signIn() async {
    final user = _user.text.trim();
    final pass = _pass.text;
    final region = _region.text.trim();
    if (user.isEmpty || pass.isEmpty) return;
    await [Permission.microphone, Permission.notification].request();
    _logLine('signing in $user@$region…');
    await piopiy.login(user, pass, region);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('voice.user', user);
    await prefs.setString('voice.pass', pass);
    await prefs.setString('voice.region', region);
  }

  Future<void> _signOut() async {
    await piopiy.logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('voice.user');
    await prefs.remove('voice.pass');
    await prefs.remove('voice.region');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PIOPIY Voice')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_signedIn) ...[
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Agent id'),
            ),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            TextField(
              controller: _region,
              decoration: const InputDecoration(labelText: 'Region (SBC)'),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _signIn, child: const Text('Sign in')),
          ] else ...[
            Text(
              'state: $_callState'
              '${_peer.isNotEmpty ? '  •  $_peer' : ''}',
            ),
            const SizedBox(height: 8),
            if (_callState == 'idle') ...[
              TextField(
                controller: _dial,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Number to call'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => piopiy.call(_dial.text.trim()),
                child: const Text('Call'),
              ),
            ],
            if (_callState == 'incoming')
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: piopiy.answer,
                      child: const Text('Answer'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: piopiy.reject,
                      child: const Text('Reject'),
                    ),
                  ),
                ],
              ),
            if (_callState == 'active' || _callState == 'outgoing') ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: piopiy.mute,
                      child: const Text('Mute'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: piopiy.unMute,
                      child: const Text('Unmute'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => piopiy.speaker(true),
                      child: const Text('Speaker'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: piopiy.terminate,
                child: const Text('Hang up'),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _signOut, child: const Text('Sign out')),
          ],
          const Divider(height: 32),
          const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final line in _log)
            Text(
              line,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
        ],
      ),
    );
  }
}
