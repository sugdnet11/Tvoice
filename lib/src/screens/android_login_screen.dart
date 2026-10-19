import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../core/app_config.dart';
import '../models/models.dart';
import '../services/android_platform_bridge.dart';
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
  CompanyProfile company = const CompanyProfile(
    id: '00000000-0000-0000-0000-000000000001',
    code: 'TOJIKTELECOM',
    name: 'Tojiktelecom',
    sip: SipProfile(host: AppConfig.sipHost, port: AppConfig.sipPort),
  );
  bool hidden = true;
  bool resolvingCompany = false;
  String? companyError;

  @override
  void initState() {
    super.initState();
    unawaited(AndroidPlatformBridge.initialize(onLink: _handleLink));
    unawaited(_resolveCompany(company.code, silent: true));
  }

  @override
  void dispose() {
    number.dispose();
    password.dispose();
    AndroidPlatformBridge.dispose();
    super.dispose();
  }

  Future<void> _handleLink(Uri uri) async {
    final code = CompanyLink.companyCode(uri);
    if (code != null) await _resolveCompany(code);
  }

  Future<bool> _resolveCompany(String code, {bool silent = false}) async {
    if (resolvingCompany) return false;
    setState(() {
      resolvingCompany = true;
      companyError = null;
    });
    try {
      final resolved = await widget.controller.resolveCompany(code);
      if (!mounted) return false;
      setState(() => company = resolved);
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (!silent) setState(() => companyError = error.toString());
      return false;
    } finally {
      if (mounted) setState(() => resolvingCompany = false);
    }
  }

  Future<void> _chooseCompany() async {
    final code = TextEditingController();
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Подключение компании',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Введите код, выданный администратором компании. SIP, чат и видео подключатся автоматически.',
            ),
            const SizedBox(height: 18),
            TextField(
              controller: code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Код компании',
                hintText: 'Например, COMPANY01',
                prefixIcon: Icon(Icons.business_rounded),
              ),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => Navigator.pop(context, code.text),
              child: const Text('Продолжить'),
            ),
            TextButton.icon(
              onPressed: () => Navigator.pop(context, 'TOJIKTELECOM'),
              icon: const Icon(Icons.apartment_rounded),
              label: const Text('Использовать Tojiktelecom'),
            ),
          ],
        ),
      ),
    );
    code.dispose();
    if (selected == null || selected.trim().isEmpty) return;
    await _resolveCompany(selected.trim().toUpperCase());
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();
    await widget.controller.login(
      number.text.trim(),
      password.text,
      tenantCode: company.code,
    );
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
                    if (company.code == 'TOJIKTELECOM')
                      const TojiktelecomBrand()
                    else
                      _CompanyBrand(company: company),
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
                      'Один вход для звонков, чата и видео',
                      style: TextStyle(color: secondary, fontSize: 14),
                    ),
                    const SizedBox(height: 20),
                    Material(
                      color: surface,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: resolvingCompany ? null : _chooseCompany,
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: line),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.business_rounded,
                                color: Color(0xff0a84ff),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      company.name,
                                      style: TextStyle(
                                        color: primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      'Код: ${company.code}',
                                      style: TextStyle(
                                        color: secondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (resolvingCompany)
                                const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (companyError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        companyError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xffff3b30),
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
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

class _CompanyBrand extends StatelessWidget {
  const _CompanyBrand({required this.company});
  final CompanyProfile company;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (company.logoUrl != null && company.logoUrl!.isNotEmpty)
        Image.network(
          company.logoUrl!,
          height: 62,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(
            Icons.apartment_rounded,
            size: 54,
            color: Color(0xff0a84ff),
          ),
        )
      else
        const Icon(Icons.apartment_rounded, size: 54, color: Color(0xff0a84ff)),
      const SizedBox(height: 6),
      Text(
        company.name,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
    ],
  );
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
