import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../core/app_config.dart';
import '../models/models.dart';
import '../services/sip_bridge.dart';
import 'android_audio_call_screen.dart';
import 'android_conversation_screen.dart';
import 'conference_screen.dart';

class AndroidHomeShell extends StatefulWidget {
  const AndroidHomeShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<AndroidHomeShell> createState() => _AndroidHomeShellState();
}

class _AndroidHomeShellState extends State<AndroidHomeShell> {
  int index = 1;
  bool dialer = false;
  bool audioVisible = false;
  String? shownVideoCall;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (widget.controller.sipCallState == SipCallState.incoming &&
        !audioVisible &&
        mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openAudio());
    }
    final call = widget.controller.incomingVideoCall;
    if (call != null && shownVideoCall != call.callId && mounted) {
      shownVideoCall = call.callId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _incomingVideo(call));
    }
  }

  Future<void> _incomingVideo(VideoCallSession call) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(call.peer.displayName),
        content: Text('Входящий видеозвонок · ${call.peer.sipNumber}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отклонить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ответить'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (accepted == true) {
      final session = await widget.controller.answerIncomingVideo();
      if (session != null && mounted) await _openVideo(session);
    } else {
      await widget.controller.rejectIncomingVideo();
    }
  }

  Future<void> _openConversation(Conversation conversation) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AndroidConversationScreen(
            controller: widget.controller,
            conversation: conversation,
          ),
        ),
      );

  Future<void> _audio(String number) async {
    if (await widget.controller.startAudioCall(number) && mounted) {
      await _openAudio();
    }
  }

  Future<void> _openAudio() async {
    if (audioVisible || !mounted) return;
    audioVisible = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => AndroidAudioCallScreen(controller: widget.controller),
        ),
      );
    } finally {
      audioVisible = false;
    }
  }

  Future<void> _video(TvoiceUser peer) async {
    try {
      await _openVideo(await widget.controller.startVideoCall(peer));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _openVideo(VideoCallSession session) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) =>
              ConferenceScreen(controller: widget.controller, session: session),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final palette = AndroidPalette.of(context);
    final pages = [
      _Contacts(
        controller: widget.controller,
        audio: _audio,
        video: _video,
        open: _openConversation,
      ),
      dialer
          ? _Dialer(controller: widget.controller, audio: _audio, video: _video)
          : _Calls(
              controller: widget.controller,
              onDialer: () => setState(() => dialer = true),
              onCall: _audio,
            ),
      _Chats(controller: widget.controller, open: _openConversation),
      _Account(controller: widget.controller),
    ];
    return PopScope(
      canPop: index == 1 && !dialer,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (dialer) {
          setState(() => dialer = false);
        } else if (index != 1) {
          setState(() => index = 1);
        }
      },
      child: Scaffold(
        backgroundColor: palette.page,
        body: SafeArea(
          child: Column(
            children: [
              if (widget.controller.hasActiveSipCall)
                _ActiveCallBanner(
                  controller: widget.controller,
                  open: _openAudio,
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: KeyedSubtree(
                    key: ValueKey('$index-$dialer'),
                    child: pages[index],
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Container(
            height: 62,
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border(top: BorderSide(color: palette.line)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                _Nav(
                  icon: Icons.contacts_rounded,
                  label: 'Контакты',
                  selected: index == 0,
                  tap: () => _select(0),
                ),
                _Nav(
                  icon: Icons.call_rounded,
                  label: 'Звонки',
                  selected: index == 1,
                  tap: () => _select(1),
                ),
                _Nav(
                  icon: Icons.chat_bubble_rounded,
                  label: 'Чаты',
                  selected: index == 2,
                  tap: () => _select(2),
                ),
                _Nav(
                  icon: Icons.person_rounded,
                  label: 'Аккаунт',
                  selected: index == 3,
                  tap: () => _select(3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _select(int value) => setState(() {
    index = value;
    dialer = false;
  });
}

class AndroidPalette {
  const AndroidPalette({
    required this.page,
    required this.surface,
    required this.primary,
    required this.secondary,
    required this.line,
    required this.search,
  });
  final Color page;
  final Color surface;
  final Color primary;
  final Color secondary;
  final Color line;
  final Color search;
  static const blue = Color(0xff0a84ff);
  static const green = Color(0xff22c55e);
  static const red = Color(0xffff3b30);

  factory AndroidPalette.of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AndroidPalette(
      page: dark ? const Color(0xff0f172a) : const Color(0xfff7f9fc),
      surface: dark ? const Color(0xff172033) : Colors.white,
      primary: dark ? const Color(0xfff8fafc) : const Color(0xff0b2345),
      secondary: dark ? const Color(0xff94a3b8) : const Color(0xff6b7a90),
      line: dark ? const Color(0xff263449) : const Color(0xffe6ebf2),
      search: dark ? const Color(0xff1e293b) : const Color(0xfff0f3f8),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.child, this.fab});
  final String title;
  final Widget child;
  final Widget? fab;
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: p.primary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(child: child),
            ],
          ),
        ),
        if (fab != null) Positioned(right: 16, bottom: 16, child: fab!),
      ],
    );
  }
}

class _Contacts extends StatefulWidget {
  const _Contacts({
    required this.controller,
    required this.audio,
    required this.video,
    required this.open,
  });
  final AppController controller;
  final ValueChanged<String> audio;
  final ValueChanged<TvoiceUser> video;
  final ValueChanged<Conversation> open;
  @override
  State<_Contacts> createState() => _ContactsState();
}

class _ContactsState extends State<_Contacts> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    final contacts = widget.controller.contacts
        .where(
          (item) =>
              query.isEmpty ||
              item.displayName.toLowerCase().contains(query) ||
              item.sipNumber.contains(query),
        )
        .toList();
    return _Page(
      title: 'Контакты',
      fab: FloatingActionButton(
        onPressed: widget.controller.refreshContacts,
        backgroundColor: AndroidPalette.blue,
        foregroundColor: Colors.white,
        child: const Icon(Icons.person_add_alt_1_rounded),
      ),
      child: Column(
        children: [
          _Search(
            hint: 'Поиск',
            changed: (value) => setState(() => query = value.toLowerCase()),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: contacts.isEmpty
                ? Center(
                    child: Text(
                      'Контакты не найдены',
                      style: TextStyle(color: p.secondary, fontSize: 12),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: widget.controller.refreshContacts,
                    child: ListView.separated(
                      itemCount: contacts.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, indent: 52, color: p.line),
                      itemBuilder: (context, index) {
                        final peer = contacts[index];
                        return SizedBox(
                          height: 62,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              radius: 20,
                              backgroundColor: AndroidPalette.blue,
                              foregroundColor: Colors.white,
                              child: Text(
                                _initials(peer.displayName, peer.sipNumber),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            title: Text(
                              peer.displayName,
                              maxLines: 1,
                              style: TextStyle(
                                color: p.primary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              'Tvoice • доступен для чата',
                              maxLines: 1,
                              style: const TextStyle(
                                color: AndroidPalette.green,
                                fontSize: 12,
                              ),
                            ),
                            onTap: () async => widget.open(
                              await widget.controller.openDirect(peer),
                            ),
                            trailing: Wrap(
                              children: [
                                IconButton(
                                  onPressed: () => widget.audio(peer.sipNumber),
                                  color: AndroidPalette.blue,
                                  icon: const Icon(Icons.call_rounded),
                                ),
                                IconButton(
                                  onPressed: () => widget.video(peer),
                                  color: AndroidPalette.blue,
                                  icon: const Icon(Icons.videocam_rounded),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Calls extends StatelessWidget {
  const _Calls({
    required this.controller,
    required this.onDialer,
    required this.onCall,
  });
  final AppController controller;
  final VoidCallback onDialer;
  final ValueChanged<String> onCall;
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    return _Page(
      title: 'Звонки',
      fab: FloatingActionButton(
        onPressed: onDialer,
        backgroundColor: AndroidPalette.blue,
        foregroundColor: Colors.white,
        child: const Icon(Icons.dialpad_rounded),
      ),
      child: Column(
        children: [
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: p.search,
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(
              children: const [
                _Filter(label: 'Все', active: true),
                _Filter(label: 'Пропущенные'),
                _Filter(label: 'Избранные'),
              ],
            ),
          ),
          Expanded(
            child: controller.callHistory.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.history_rounded,
                          color: AndroidPalette.blue,
                          size: 48,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'История пока пуста',
                          style: TextStyle(
                            color: p.primary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Нажмите кнопку клавиатуры, чтобы позвонить',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.secondary, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(top: 12, bottom: 92),
                    itemCount: controller.callHistory.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: p.line, indent: 58),
                    itemBuilder: (context, index) {
                      final entry = controller.callHistory[index];
                      final missed = entry.result == CallResult.missed;
                      final failed = entry.result == CallResult.failed;
                      final color = missed || failed
                          ? const Color(0xffef4444)
                          : AndroidPalette.green;
                      return ListTile(
                        onTap: () => onCall(entry.number),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 3,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: color.withValues(alpha: .12),
                          foregroundColor: color,
                          child: Icon(
                            entry.media == CallMedia.video
                                ? Icons.videocam_rounded
                                : entry.direction == CallDirection.incoming
                                ? Icons.call_received_rounded
                                : Icons.call_made_rounded,
                          ),
                        ),
                        title: Text(
                          entry.number,
                          style: TextStyle(
                            color: missed ? color : p.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          _callDescription(entry),
                          style: TextStyle(color: p.secondary, fontSize: 12),
                        ),
                        trailing: IconButton(
                          onPressed: () => onCall(entry.number),
                          color: AndroidPalette.blue,
                          icon: const Icon(Icons.call_rounded),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _callDescription(CallHistoryEntry entry) {
    final time = entry.startedAt;
    final stamp =
        '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    if (entry.result == CallResult.missed) return 'Пропущенный · $stamp';
    if (entry.result == CallResult.failed) return 'Не состоялся · $stamp';
    final duration = entry.duration;
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${entry.direction == CallDirection.incoming ? 'Входящий' : 'Исходящий'} · $stamp · $minutes:$seconds';
  }
}

class _Filter extends StatelessWidget {
  const _Filter({required this.label, this.active = false});
  final String label;
  final bool active;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? AndroidPalette.blue : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.white : AndroidPalette.of(context).secondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _Dialer extends StatefulWidget {
  const _Dialer({
    required this.controller,
    required this.audio,
    required this.video,
  });
  final AppController controller;
  final ValueChanged<String> audio;
  final ValueChanged<TvoiceUser> video;
  @override
  State<_Dialer> createState() => _DialerState();
}

class _DialerState extends State<_Dialer> {
  String number = '';
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    final own = widget.controller.user?.sipNumber ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          const Text(
            'Tvoice',
            style: TextStyle(
              color: AndroidPalette.blue,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            own,
            style: TextStyle(
              color: p.primary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            '● В сети',
            style: TextStyle(color: AndroidPalette.green, fontSize: 13),
          ),
          const Spacer(),
          Container(
            height: 70,
            padding: const EdgeInsets.only(left: 12, right: 8),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.line),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    number.isEmpty ? 'Введите номер' : number,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: number.isEmpty ? p.secondary : p.primary,
                      fontSize: number.isEmpty ? 20 : 32,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(
                    () => number = number.isEmpty
                        ? ''
                        : number.substring(0, number.length - 1),
                  ),
                  icon: const Icon(Icons.backspace_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['0'],
          ])
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: row
                  .map(
                    (key) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      child: SizedBox(
                        width: 78,
                        height: 62,
                        child: Material(
                          color: p.surface,
                          elevation: 2,
                          borderRadius: BorderRadius.circular(35),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(35),
                            onTap: () => setState(() => number += key),
                            child: Center(
                              child: Text(
                                key,
                                style: TextStyle(
                                  color: p.primary,
                                  fontSize: 28,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _RoundAction(
                icon: Icons.videocam_rounded,
                color: AndroidPalette.blue,
                tap: number.isEmpty
                    ? null
                    : () {
                        final peer =
                            widget.controller.contacts
                                .where((item) => item.sipNumber == number)
                                .firstOrNull ??
                            TvoiceUser(
                              id: number,
                              sipNumber: number,
                              displayName: number,
                            );
                        widget.video(peer);
                      },
              ),
              const SizedBox(width: 24),
              _RoundAction(
                icon: Icons.call_rounded,
                color: AndroidPalette.green,
                large: true,
                tap: number.isEmpty ? null : () => widget.audio(number),
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.color,
    required this.tap,
    this.large = false,
  });
  final IconData icon;
  final Color color;
  final VoidCallback? tap;
  final bool large;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: large ? 76 : 70,
    child: Material(
      color: tap == null ? color.withValues(alpha: .4) : color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: tap,
        child: Icon(icon, color: Colors.white, size: 32),
      ),
    ),
  );
}

class _Chats extends StatefulWidget {
  const _Chats({required this.controller, required this.open});
  final AppController controller;
  final ValueChanged<Conversation> open;
  @override
  State<_Chats> createState() => _ChatsState();
}

class _ChatsState extends State<_Chats> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    final items = widget.controller.conversations
        .where(
          (item) =>
              query.isEmpty ||
              item.peer.displayName.toLowerCase().contains(query) ||
              item.peer.sipNumber.contains(query),
        )
        .toList();
    return _Page(
      title: 'Чаты',
      fab: FloatingActionButton(
        onPressed: widget.controller.refreshConversations,
        backgroundColor: AndroidPalette.blue,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add_comment_rounded),
      ),
      child: Column(
        children: [
          _Search(
            hint: 'Поиск чатов',
            changed: (value) => setState(() => query = value.toLowerCase()),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.chat_bubble_rounded,
                          size: 48,
                          color: AndroidPalette.blue,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Сообщений пока нет',
                          style: TextStyle(
                            color: p.primary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Начните чат по SIP-номеру абонента',
                          style: TextStyle(color: p.secondary, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: widget.controller.refreshConversations,
                    child: ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, indent: 54, color: p.line),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return SizedBox(
                          height: 62,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            onTap: () => widget.open(item),
                            leading: CircleAvatar(
                              radius: 20,
                              backgroundColor: AndroidPalette.blue,
                              child: Text(
                                _initials(
                                  item.peer.displayName,
                                  item.peer.sipNumber,
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            title: Text(
                              item.peer.displayName,
                              style: TextStyle(
                                color: p.primary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              item.lastMessage?.body ?? item.peer.sipNumber,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.secondary,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Icon(
                              Icons.chevron_right_rounded,
                              color: p.secondary,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Account extends StatelessWidget {
  const _Account({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    final user = controller.user!;
    return _Page(
      title: 'Аккаунт',
      child: ListView(
        children: [
          SizedBox(
            height: 92,
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 32,
                  backgroundColor: AndroidPalette.blue,
                  child: Icon(
                    Icons.person_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      user.sipNumber,
                      style: TextStyle(
                        color: p.primary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '● Подключено',
                      style: TextStyle(
                        color: AndroidPalette.green,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      'Чат подключён',
                      style: TextStyle(color: p.secondary, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _Section(label: 'Аккаунты', palette: p),
          _Setting(
            icon: Icons.person_rounded,
            title: user.sipNumber,
            value: 'Активный',
          ),
          const _Setting(icon: Icons.add_rounded, title: 'Добавить аккаунт'),
          _Section(label: 'Настройки', palette: p),
          const _Setting(
            icon: Icons.chat_bubble_rounded,
            title: 'Уведомления',
            value: 'Включены',
          ),
          const _Setting(
            icon: Icons.volume_up_rounded,
            title: 'Звук и устройства',
            value: 'Звук и вибрация',
          ),
          const _Setting(
            icon: Icons.contacts_rounded,
            title: 'Язык',
            value: 'Русский',
          ),
          _Setting(
            icon: Icons.palette_rounded,
            title: 'Оформление',
            value: switch (controller.themeMode) {
              ThemeMode.system => 'Системная',
              ThemeMode.light => 'Светлая',
              ThemeMode.dark => 'Тёмная',
            },
            tap: () => _theme(context),
          ),
          const _Setting(
            icon: Icons.info_outline_rounded,
            title: 'SIP-сервер',
            value: '185.177.2.115 • UDP',
          ),
          _Section(label: 'О приложении', palette: p),
          Text(
            'Tvoice — звонки и сообщения между абонентами вашего SIP-сервера.',
            style: TextStyle(color: p.secondary, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            'Tvoice ${AppConfig.version} • SIP Core 1.8 • Chat Core 0.4',
            style: const TextStyle(color: AndroidPalette.blue, fontSize: 12),
          ),
          const SizedBox(height: 5),
          Text(
            'Developed by Шогирдои Малем',
            style: TextStyle(
              color: p.primary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: controller.logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: AndroidPalette.red,
              ),
              child: const Text('Выйти из аккаунта'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _theme(BuildContext context) async {
    final value = await showDialog<ThemeMode>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Оформление'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ThemeMode.system),
            child: const Text('Системная'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ThemeMode.light),
            child: const Text('Светлая'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ThemeMode.dark),
            child: const Text('Тёмная'),
          ),
        ],
      ),
    );
    if (value != null) controller.setThemeMode(value);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.palette});
  final String label;
  final AndroidPalette palette;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 5),
    child: Text(
      label,
      style: TextStyle(
        color: palette.secondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _Setting extends StatelessWidget {
  const _Setting({
    required this.icon,
    required this.title,
    this.value = '',
    this.tap,
  });
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? tap;
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    return Column(
      children: [
        SizedBox(
          height: 54,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: tap,
            leading: Icon(icon, color: AndroidPalette.blue),
            title: Text(
              title,
              style: TextStyle(
                color: p.primary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value.isNotEmpty)
                  Text(
                    value,
                    style: TextStyle(color: p.secondary, fontSize: 12),
                  ),
                Icon(Icons.chevron_right_rounded, color: p.secondary),
              ],
            ),
          ),
        ),
        Divider(height: 1, indent: 50, color: p.line),
      ],
    );
  }
}

class _Search extends StatelessWidget {
  const _Search({required this.hint, required this.changed});
  final String hint;
  final ValueChanged<String> changed;
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    return SizedBox(
      height: 40,
      child: TextField(
        onChanged: changed,
        style: TextStyle(color: p.primary, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search_rounded),
          filled: true,
          fillColor: p.search,
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.icon,
    required this.label,
    required this.selected,
    required this.tap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback tap;
  @override
  Widget build(BuildContext context) {
    final color = selected
        ? AndroidPalette.blue
        : AndroidPalette.of(context).secondary;
    return Expanded(
      child: InkWell(
        onTap: tap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 23),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveCallBanner extends StatelessWidget {
  const _ActiveCallBanner({required this.controller, required this.open});
  final AppController controller;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) {
    final p = AndroidPalette.of(context);
    return InkWell(
      onTap: open,
      child: Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xff18365e)
              : const Color(0xffe6f0ff),
          border: Border(bottom: BorderSide(color: p.line)),
        ),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 18,
              backgroundColor: AndroidPalette.green,
              child: Icon(Icons.call_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    controller.sipRemoteNumber,
                    style: TextStyle(
                      color: p.primary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    controller.sipCallState == SipCallState.connected
                        ? 'Соединено'
                        : 'Идёт вызов…',
                    style: TextStyle(color: p.secondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: controller.hangupSipCall,
              style: IconButton.styleFrom(
                backgroundColor: AndroidPalette.red,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.call_end_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

String _initials(String name, String fallback) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((item) => item.isNotEmpty)
      .toList();
  if (parts.isEmpty) {
    return fallback.length >= 2 ? fallback.substring(0, 2) : fallback;
  }
  return parts.take(2).map((item) => item[0].toUpperCase()).join();
}
