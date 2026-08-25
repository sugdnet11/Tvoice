import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../widgets/tvoice_logo.dart';
import '../services/desktop_window_controller.dart';
import 'windows_guest_invite_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _number = TextEditingController();
  final _password = TextEditingController();
  bool _hidden = true;
  StreamSubscription<Uri>? _deepLinks;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _deepLinks = DesktopWindowController.links.listen(_openInvite);
      final pending = DesktopWindowController.takePendingLink();
      if (pending != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _openInvite(pending));
      }
    }
  }

  Future<void> _openInvite(Uri uri) async {
    if (!mounted || uri.host != 'conference' || uri.path != '/join') return;
    final token = uri.queryParameters['token'];
    if (token == null || token.length < 32) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WindowsGuestInviteScreen(
        controller: widget.controller,
        inviteToken: token,
        originalLink: uri,
      ),
    ));
  }

  @override
  void dispose() {
    _number.dispose();
    _password.dispose();
    unawaited(_deepLinks?.cancel());
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.controller.busy) return;
    FocusScope.of(context).unfocus();
    await widget.controller.login(_number.text, _password.text);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 26),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: TvoiceLogo(size: 60, showWordmark: false),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Вход в Tvoice',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.5,
                            ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Войдите в свою учётную запись',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        key: const ValueKey('login-sip-number'),
                        controller: _number,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        keyboardType: TextInputType.phone,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: 'SIP-номер',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('login-password'),
                        controller: _password,
                        obscureText: _hidden,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Пароль',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _hidden = !_hidden),
                            icon: Icon(
                              _hidden
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        alignment: Alignment.topCenter,
                        child: widget.controller.error == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  widget.controller.error!,
                                  key: const ValueKey('login-error'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        key: const ValueKey('login-submit'),
                        onPressed: widget.controller.busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: widget.controller.busy
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  SizedBox(width: 10),
                                  Text('Выполняется вход…'),
                                ],
                              )
                            : const Text(
                                'Войти',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
