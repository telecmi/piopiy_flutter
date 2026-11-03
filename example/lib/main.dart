// PIOPIY Flutter example — sign in with TeleCMI agent credentials, dial out,
// receive calls on the native OS call UI, and drive every in-call control.
// Credentials are saved after the first sign-in and the app signs in
// automatically from then on.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:piopiy_flutter/piopiy_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Created on first use — after Firebase.initializeApp() in main().
final piopiy = Piopiy(const PiopiyOptions(name: 'PiopiyExample', debug: true));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // Android push needs Firebase. The SDK registers its FCM background
    // handler itself (autoBackgroundPush) — no other push code.
    await Firebase.initializeApp();
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
  final _transferTo = TextEditingController();

  bool _signedIn = false;
  String _callState = 'idle'; // idle · incoming · outgoing · active
  bool _inbound = false; // push-delivered call (no hold/DTMF/transfer yet)
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

  void _setCall(String state) {
    if (!mounted) return;
    setState(() => _callState = state);
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
    piopiy.on('sbc_logout', (d) => _logLine('⚠️ signed out by the server: $d'));
    piopiy.on('connected', (_) => _logLine('🔌 connected'));
    piopiy.on('disconnected', (_) => _logLine('🔌 disconnected'));
    piopiy.on('pushRegistered', (_) => _logLine('📲 push token registered'));

    piopiy.on('inComingCall', (c) {
      setState(() {
        _callState = 'incoming';
        _inbound = c?['transport'] == 'push';
        _peer = (c?['name'] ?? c?['from'] ?? '').toString();
      });
      _logLine('📞 incoming from ${c?['from']}'
          '${c?['team_name'] != null ? ' (${c?['team_name']})' : ''}');
    });
    piopiy.on('trying', (_) {
      setState(() {
        _callState = 'outgoing';
        _inbound = false;
      });
      _logLine('trying…');
    });
    piopiy.on('ringing', (_) => _logLine('ringing…'));
    piopiy.on('answered', (_) {
      _setCall('active');
      _logLine('call connected');
    });
    piopiy.on('hold', (d) => _logLine('⏸ on hold (${d?['whom']})'));
    piopiy.on('unhold', (d) => _logLine('▶️ resumed (${d?['whom']})'));
    piopiy.on('dtmf', (d) => _logLine('DTMF ${d?['dtmf']} (${d?['type']})'));
    piopiy.on('ended', (d) {
      _setCall('idle');
      _logLine('call ended ${d?['reason'] ?? ''}');
    });
    piopiy.on('hangup', (_) {
      _setCall('idle');
      _logLine('call hung up');
    });
    piopiy.on('missedCall', (m) => _logLine('📵 missed call from ${m?['from'] ?? 'unknown'}'));
    piopiy.on('transfer', (t) => _logLine('↪️ transfer ${t?['state']} ${t?['to'] ?? ''}'));
    piopiy.on('record', (r) => _logLine('⏺ recording ${r?['state']}'));
    piopiy.on('RTC', (r) => _logLine('media ${r?['state']}'));
    piopiy.on('NETStats', (n) => _logLine('⚠️ network: ${n?['msg']}'));
    piopiy.on('mediaFailed', (_) => _logLine('⚠️ microphone unavailable'));
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
    final res = await piopiy.logout();
    _logLine('push unregistered: ${res['code']}');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('voice.user');
    await prefs.remove('voice.pass');
    await prefs.remove('voice.region');
  }

  Future<void> _transfer({required bool team}) async {
    final to = _transferTo.text.trim();
    if (to.isEmpty) return;
    final res = team ? await piopiy.teamTransfer(to) : await piopiy.transfer(to);
    _logLine('transfer → $to: $res');
  }

  Widget _keypad() {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final k in keys)
          SizedBox(
            width: 56,
            child: OutlinedButton(
              onPressed: () => piopiy.sendDtmf(k),
              child: Text(k),
            ),
          ),
      ],
    );
  }

  List<Widget> _inCallControls() {
    final outbound = !_inbound;
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonal(
            onPressed: () async {
              piopiy.onMute() ? await piopiy.unMute() : await piopiy.mute();
              setState(() {});
            },
            child: Text(piopiy.onMute() ? 'Unmute' : 'Mute'),
          ),
          FilledButton.tonal(
            onPressed: () async {
              await piopiy.speaker(!piopiy.onSpeaker());
              setState(() {});
            },
            child: Text(piopiy.onSpeaker() ? 'Earpiece' : 'Speaker'),
          ),
          if (outbound)
            FilledButton.tonal(
              onPressed: () {
                piopiy.onHold() ? piopiy.unHold() : piopiy.hold();
                Future.delayed(const Duration(milliseconds: 600), () {
                  if (mounted) setState(() {});
                });
              },
              child: Text(piopiy.onHold() ? 'Resume' : 'Hold'),
            ),
        ],
      ),
      if (outbound) ...[
        const SizedBox(height: 12),
        _keypad(),
        const SizedBox(height: 12),
        TextField(
          controller: _transferTo,
          decoration: const InputDecoration(labelText: 'Transfer to (extension / number / team)'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(onPressed: () => _transfer(team: false), child: const Text('Transfer')),
            OutlinedButton(onPressed: () => _transfer(team: true), child: const Text('Team transfer')),
            OutlinedButton(onPressed: piopiy.merge, child: const Text('Merge')),
            OutlinedButton(onPressed: piopiy.cancel, child: const Text('Cancel transfer')),
          ],
        ),
      ],
      const SizedBox(height: 12),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.red),
        onPressed: piopiy.terminate,
        child: const Text('Hang up'),
      ),
    ];
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
              '${_peer.isNotEmpty && _callState != 'idle' ? '  •  $_peer' : ''}',
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
                onPressed: () {
                  setState(() => _peer = _dial.text.trim());
                  piopiy.call(_dial.text.trim());
                },
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
            if (_callState == 'active' || _callState == 'outgoing') ..._inCallControls(),
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
