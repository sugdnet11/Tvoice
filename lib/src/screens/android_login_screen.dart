import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../widgets/android_brand.dart';

class AndroidLoginScreen extends StatefulWidget {
  const AndroidLoginScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<AndroidLoginScreen> createState() => _AndroidLoginScreenState();
}

class _AndroidLoginScreenState extends State<AndroidLoginScreen> {
  final number = TextEditingController();
  final password = TextEditingController();
  bool hidden = true;

  @override
  void dispose() {
    number.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();
    await widget.controller.login(number.text.trim(), password.text);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final primary = dark ? const Color(0xfff8fafc) : const Color(0xff0b2345);
    final secondary = dark ? const Color(0xff94a3b8) : const Color(0xff6b7a90);
    final surface = dark ? const Color(0xff172033) : Colors.white;
    final line = dark ? const Color(0xff263449) : const Color(0xffe6ebf2);
    return Scaffold(
      backgroundColor: dark ? const Color(0xff0f172a) : const Color(0xfff7f9fc),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 40,
              ),
              child: AutofillGroup(
                child: Column(
                  children: [
                    const TojiktelecomBrand(compact: true),
                    const SizedBox(height: 18),
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(36),
                        border: Border.all(color: line),
                      ),
                      padding: const EdgeInsets.all(6),
                      child: const AndroidTvoiceMark(size: 60),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Tvoice',
                      style: TextStyle(
                        color: Color(0xff0a84ff),
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Добро пожаловать!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: primary,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Один вход для звонков и чата',
                      style: TextStyle(color: secondary, fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    _Field(
                      controller: number,
                      label: 'SIP-номер',
                      hint: 'Например, 70707',
                      keyboardType: TextInputType.phone,
                      autofillHints: const [AutofillHints.username],
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      controller: password,
                      label: 'Пароль',
                      hint: 'Введите пароль',
                      obscureText: hidden,
                      autofillHints: const [AutofillHints.password],
                      suffix: IconButton(
                        onPressed: () => setState(() => hidden = !hidden),
                        icon: Icon(
                          hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                    if (widget.controller.error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        widget.controller.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xffff3b30)),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton(
                        onPressed: widget.controller.busy ? null : submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xff0a84ff),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: widget.controller.busy
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Войти',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
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
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
    this.autofillHints,
    this.obscureText = false,
    this.suffix,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final bool obscureText;
  final Widget? suffix;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: keyboardType,
    autofillHints: autofillHints,
    obscureText: obscureText,
    onSubmitted: onSubmitted,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffix,
    ),
  );
}

class AndroidSplashScreen extends StatelessWidget {
  const AndroidSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? const Color(0xff0f172a) : const Color(0xfff7f9fc),
      body: SafeArea(
        child: Stack(
          children: [
            const Positioned(
              top: 58,
              left: 0,
              right: 0,
              child: Center(child: TojiktelecomBrand()),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Tvoice',
                    style: TextStyle(
                      color: dark
                          ? const Color(0xfff8fafc)
                          : const Color(0xff0b2345),
                      fontSize: 58,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Добро пожаловать!',
                    style: TextStyle(color: Color(0xff6b7a90), fontSize: 21),
                  ),
                ],
              ),
            ),
            Positioned(
              bottom: 82,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  _SplashDot(active: false),
                  SizedBox(width: 14),
                  _SplashDot(active: true),
                  SizedBox(width: 14),
                  _SplashDot(active: false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplashDot extends StatelessWidget {
  const _SplashDot({required this.active});
  final bool active;
  @override
  Widget build(BuildContext context) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(
      color: active ? const Color(0xff0a84ff) : const Color(0xffeaf3ff),
      shape: BoxShape.circle,
    ),
  );
}
