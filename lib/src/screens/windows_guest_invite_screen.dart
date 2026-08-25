import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/desktop_window_controller.dart';
import '../widgets/tvoice_logo.dart';
import 'windows_conference_screen.dart';

class WindowsGuestInviteScreen extends StatefulWidget {
  const WindowsGuestInviteScreen({
    super.key,
    required this.controller,
    required this.inviteToken,
    required this.originalLink,
  });
  final AppController controller;
  final String inviteToken;
  final Uri originalLink;

  @override
  State<WindowsGuestInviteScreen> createState() => _WindowsGuestInviteScreenState();
}

class _WindowsGuestInviteScreenState extends State<WindowsGuestInviteScreen> {
  final _name = TextEditingController();
  Map<String, dynamic>? _invite;
  String? _error;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final invite = await widget.controller.api.conferenceInvitation(widget.inviteToken);
      if (mounted) setState(() => _invite = invite);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _join() async {
    final name = _name.text.trim();
    if (name.length < 2 || _joining) return;
    setState(() => _joining = true);
    try {
      final session = await widget.controller.api.guestJoinConference(widget.inviteToken, name);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => WindowsConferenceScreen(
          controller: widget.controller,
          session: session,
        ),
      ));
    } catch (error) {
      if (mounted) setState(() { _joining = false; _error = error.toString(); });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: TvoiceLogo(size: 58, showWordmark: false)),
                  const SizedBox(height: 20),
                  Text(
                    _invite?['title']?.toString() ?? 'Приглашение в конференцию',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _invite == null ? 'Проверяем приглашение…' :
                      '${_invite!['participantCount']} из ${_invite!['maxParticipants']} участников',
                    textAlign: TextAlign.center,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  if (_invite?['active'] == true && _invite?['allowGuests'] == true) ...[
                    const SizedBox(height: 22),
                    TextField(
                      controller: _name,
                      autofocus: true,
                      maxLength: 50,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _join(),
                      decoration: const InputDecoration(
                        labelText: 'Ваше имя',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _joining || _name.text.trim().length < 2 ? null : _join,
                      icon: const Icon(Icons.login_rounded),
                      label: Text(_joining ? 'Подключение…' : 'Войти как гость'),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      DesktopWindowController.keepPendingLink(widget.originalLink);
                      Navigator.pop(context);
                    },
                    child: const Text('Войти в аккаунт Tvoice'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
