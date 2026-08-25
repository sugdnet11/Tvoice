import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/sip_bridge.dart';
import 'android_home_shell.dart';

class AndroidAudioCallScreen extends StatefulWidget {
  const AndroidAudioCallScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AndroidAudioCallScreen> createState() => _AndroidAudioCallScreenState();
}

class _AndroidAudioCallScreenState extends State<AndroidAudioCallScreen> {
  Timer? timer;
  bool closing = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.sipConnectedAt != null) setState(() {});
    });
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
    if (!closing &&
        (widget.controller.sipCallState == SipCallState.ended ||
            widget.controller.sipCallState == SipCallState.error)) {
      closing = true;
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.maybePop(context);
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.controller.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final p = AndroidPalette.of(context);
    final incoming = c.sipCallState == SipCallState.incoming;
    final connected =
        c.sipCallState == SipCallState.connected ||
        c.sipCallState == SipCallState.paused;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xff1e3557)
                  : const Color(0xffeaf3ff),
              p.page,
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              children: [
                SizedBox(
                  height: 44,
                  child: Stack(
                    children: [
                      const Center(
                        child: Text(
                          'Tvoice',
                          style: TextStyle(
                            color: AndroidPalette.blue,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          onPressed: () => Navigator.pop(context),
                          style: IconButton.styleFrom(
                            backgroundColor: p.surface,
                            foregroundColor: AndroidPalette.blue,
                            side: BorderSide(color: p.line),
                          ),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                CircleAvatar(
                  radius: 40,
                  backgroundColor: AndroidPalette.blue,
                  child: Text(
                    _avatar(c.sipRemoteNumber),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  c.sipRemoteNumber.isEmpty ? 'Абонент' : c.sipRemoteNumber,
                  style: TextStyle(
                    color: p.primary,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  connected ? duration(c.sipConnectedAt) : status(c),
                  style: TextStyle(
                    color: AndroidPalette.blue.withValues(alpha: .85),
                    fontSize: 16,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                if (incoming)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _Incoming(
                        icon: Icons.call_end_rounded,
                        label: 'Отклонить',
                        color: AndroidPalette.red,
                        tap: c.hangupSipCall,
                      ),
                      _Incoming(
                        icon: Icons.call_rounded,
                        label: 'Ответить',
                        color: AndroidPalette.green,
                        tap: c.answerSipCall,
                      ),
                    ],
                  )
                else ...[
                  Row(
                    children: [
                      _Control(
                        icon: c.sipMuted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        label: 'Микрофон',
                        selected: c.sipMuted,
                        tap: () => c.setSipMuted(!c.sipMuted),
                      ),
                      const _Control(
                        icon: Icons.dialpad_rounded,
                        label: 'Клавиатура',
                        tap: _noop,
                      ),
                      _Control(
                        icon: Icons.volume_up_rounded,
                        label: 'Динамик',
                        selected: c.sipSpeaker,
                        tap: () => c.setSipSpeaker(!c.sipSpeaker),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Control(
                        icon: c.sipHeld
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        label: 'Удержание',
                        selected: c.sipHeld,
                        tap: () => c.setSipHeld(!c.sipHeld),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox.square(
                    dimension: 80,
                    child: Material(
                      color: AndroidPalette.red,
                      shape: const CircleBorder(),
                      elevation: 3,
                      child: InkWell(
                        onTap: c.hangupSipCall,
                        customBorder: const CircleBorder(),
                        child: const Icon(
                          Icons.call_end_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static void _noop() {}
  String _avatar(String value) =>
      value.length >= 2 ? value.substring(0, 2) : value;
  String duration(DateTime? start) {
    if (start == null) return '00:00';
    final d = DateTime.now().difference(start);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  String status(AppController c) => switch (c.sipCallState) {
    SipCallState.incoming => 'Входящий звонок',
    SipCallState.outgoing => 'Вызов…',
    SipCallState.ringing => 'Идёт вызов…',
    SipCallState.paused => 'Удержание',
    SipCallState.ended => 'Звонок завершён',
    SipCallState.error =>
      c.sipCallMessage.isEmpty ? 'Ошибка звонка' : c.sipCallMessage,
    _ => c.sipCallMessage,
  };
}

class _Control extends StatelessWidget {
  const _Control({
    required this.icon,
    required this.label,
    required this.tap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback tap;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    return Expanded(
      child: Column(
        children: [
          SizedBox.square(
            dimension: 58,
            child: Material(
              color: selected ? const Color(0xffdbe8ff) : p.surface,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: tap,
                child: Icon(
                  icon,
                  color: selected ? AndroidPalette.blue : p.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(label, style: TextStyle(color: p.primary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Incoming extends StatelessWidget {
  const _Incoming({
    required this.icon,
    required this.label,
    required this.color,
    required this.tap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final Future<void> Function() tap;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox.square(
        dimension: 72,
        child: Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: tap,
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
      ),
      const SizedBox(height: 9),
      Text(
        label,
        style: TextStyle(
          color: AndroidPalette.of(context).primary,
          fontSize: 12,
        ),
      ),
    ],
  );
}
