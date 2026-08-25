import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/sip_bridge.dart';

class AudioCallScreen extends StatefulWidget {
  const AudioCallScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen> {
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.sipConnectedAt != null) setState(() {});
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final state = widget.controller.sipCallState;
    if (!_closing &&
        (state == SipCallState.ended || state == SipCallState.error)) {
      _closing = true;
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.maybePop(context);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final incoming = controller.sipCallState == SipCallState.incoming;
    final connected =
        controller.sipCallState == SipCallState.connected ||
        controller.sipCallState == SipCallState.paused;
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xff12345b), Color(0xff07101c)],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: 6,
                left: 10,
                child: IconButton.filledTonal(
                  tooltip: 'Свернуть',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircleAvatar(
                          radius: 64,
                          backgroundColor: Color(0x26ffffff),
                          child: Icon(
                            Icons.person_rounded,
                            size: 72,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          controller.sipRemoteNumber.isEmpty
                              ? 'Абонент'
                              : controller.sipRemoteNumber,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          connected
                              ? _duration(controller.sipConnectedAt)
                              : _stateText(controller),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 17,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 70),
                        if (incoming)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _LargeCallButton(
                                color: const Color(0xffef4058),
                                icon: Icons.call_end_rounded,
                                label: 'Отклонить',
                                onPressed: controller.hangupSipCall,
                              ),
                              _LargeCallButton(
                                color: const Color(0xff27c66f),
                                icon: Icons.call_rounded,
                                label: 'Принять',
                                onPressed: controller.answerSipCall,
                              ),
                            ],
                          )
                        else
                          Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _RoundControl(
                                    icon: controller.sipMuted
                                        ? Icons.mic_off_rounded
                                        : Icons.mic_rounded,
                                    label: 'Микрофон',
                                    selected: controller.sipMuted,
                                    onPressed: () => controller.setSipMuted(
                                      !controller.sipMuted,
                                    ),
                                  ),
                                  const SizedBox(width: 34),
                                  _RoundControl(
                                    icon: controller.sipHeld
                                        ? Icons.play_arrow_rounded
                                        : Icons.pause_rounded,
                                    label: controller.sipHeld
                                        ? 'Продолжить'
                                        : 'Удержание',
                                    selected: controller.sipHeld,
                                    onPressed: () => controller.setSipHeld(
                                      !controller.sipHeld,
                                    ),
                                  ),
                                  const SizedBox(width: 34),
                                  _RoundControl(
                                    icon: Icons.volume_up_rounded,
                                    label: 'Динамик',
                                    selected: controller.sipSpeaker,
                                    onPressed: () => controller.setSipSpeaker(
                                      !controller.sipSpeaker,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 42),
                              IconButton.filled(
                                onPressed: controller.hangupSipCall,
                                style: IconButton.styleFrom(
                                  backgroundColor: const Color(0xffef4058),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.all(22),
                                ),
                                icon: const Icon(
                                  Icons.call_end_rounded,
                                  size: 34,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _duration(DateTime? startedAt) {
    if (startedAt == null) return '00:00';
    final duration = DateTime.now().difference(startedAt);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  String _stateText(AppController controller) =>
      switch (controller.sipCallState) {
        SipCallState.incoming => 'Входящий аудиозвонок',
        SipCallState.outgoing => 'Вызов…',
        SipCallState.ringing => 'Идёт вызов…',
        SipCallState.paused => 'На удержании',
        SipCallState.ended => 'Звонок завершён',
        SipCallState.error =>
          controller.sipCallMessage.isEmpty
              ? 'Ошибка звонка'
              : controller.sipCallMessage,
        _ => controller.sipCallMessage,
      };
}

class _LargeCallButton extends StatelessWidget {
  const _LargeCallButton({
    required this.color,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final Color color;
  final IconData icon;
  final String label;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      IconButton.filled(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.all(22),
        ),
        icon: Icon(icon, size: 34),
      ),
      const SizedBox(height: 9),
      Text(label, style: const TextStyle(color: Colors.white70)),
    ],
  );
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      IconButton.filledTonal(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: selected ? Colors.white : const Color(0x26ffffff),
          foregroundColor: selected ? const Color(0xff07101c) : Colors.white,
          padding: const EdgeInsets.all(18),
        ),
        icon: Icon(icon, size: 28),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white70)),
    ],
  );
}
