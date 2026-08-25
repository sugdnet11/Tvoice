import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/models.dart';
import '../services/sip_bridge.dart';
import 'audio_call_screen.dart';
import 'conference_screen.dart';
import 'conversation_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  String? _shownIncomingId;
  bool _audioScreenVisible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() {
    if (widget.controller.sipCallState == SipCallState.incoming &&
        !_audioScreenVisible &&
        mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openAudioCall());
    }
    final call = widget.controller.incomingVideoCall;
    if (call == null) {
      _shownIncomingId = null;
      return;
    }
    if (_shownIncomingId == call.callId || !mounted) return;
    _shownIncomingId = call.callId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showIncoming(call));
  }

  Future<void> _showIncoming(VideoCallSession call) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const CircleAvatar(
          radius: 34,
          child: Icon(Icons.videocam_rounded, size: 34),
        ),
        title: Text(call.peer.displayName),
        content: Text(
          'Входящий видеозвонок · ${call.peer.sipNumber}',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          FilledButton.tonalIcon(
            onPressed: () => Navigator.pop(context, false),
            icon: const Icon(Icons.call_end_rounded),
            label: const Text('Отклонить'),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.videocam_rounded),
            label: const Text('Принять'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (accepted == true) {
      final session = await widget.controller.answerIncomingVideo();
      if (session != null && mounted) await _openConference(session);
    } else {
      await widget.controller.rejectIncomingVideo();
    }
  }

  Future<void> _openConversation(Conversation conversation) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationScreen(
          controller: widget.controller,
          conversation: conversation,
        ),
      ),
    );
  }

  Future<void> _startVideo(TvoiceUser peer) async {
    try {
      final session = await widget.controller.startVideoCall(peer);
      if (mounted) await _openConference(session);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _startAudio(String number) async {
    final started = await widget.controller.startAudioCall(number);
    if (started && mounted) await _openAudioCall();
  }

  Future<void> _openAudioCall() async {
    if (_audioScreenVisible || !mounted) return;
    _audioScreenVisible = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => AudioCallScreen(controller: widget.controller),
        ),
      );
    } finally {
      _audioScreenVisible = false;
    }
  }

  Future<void> _openConference(VideoCallSession session) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            ConferenceScreen(controller: widget.controller, session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _ContactsPage(
        controller: widget.controller,
        onChat: (peer) async =>
            _openConversation(await widget.controller.openDirect(peer)),
        onAudio: (peer) => _startAudio(peer.sipNumber),
        onVideo: _startVideo,
      ),
      _CallsPage(controller: widget.controller, onCall: _startAudio),
      _ChatsPage(controller: widget.controller, onOpen: _openConversation),
      _AccountPage(controller: widget.controller),
    ];
    final destinations = const [
      NavigationDestination(
        icon: Icon(Icons.contacts_outlined),
        selectedIcon: Icon(Icons.contacts_rounded),
        label: 'Контакты',
      ),
      NavigationDestination(
        icon: Icon(Icons.call_outlined),
        selectedIcon: Icon(Icons.call_rounded),
        label: 'Звонки',
      ),
      NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline_rounded),
        selectedIcon: Icon(Icons.chat_bubble_rounded),
        label: 'Чаты',
      ),
      NavigationDestination(
        icon: Icon(Icons.person_outline_rounded),
        selectedIcon: Icon(Icons.person_rounded),
        label: 'Аккаунт',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 760;
        final content = Stack(
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: KeyedSubtree(
                  key: ValueKey(_index),
                  child: pages[_index],
                ),
              ),
            ),
            if (widget.controller.hasActiveSipCall)
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: _ActiveCallBar(
                  controller: widget.controller,
                  onTap: _openAudioCall,
                ),
              ),
          ],
        );
        if (desktop) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (value) =>
                      setState(() => _index = value),
                  extended: constraints.maxWidth >= 1050,
                  leading: const Padding(
                    padding: EdgeInsets.only(top: 18, bottom: 24),
                    child: CircleAvatar(
                      radius: 24,
                      child: Text(
                        'T',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 23,
                        ),
                      ),
                    ),
                  ),
                  destinations: destinations
                      .map(
                        (item) => NavigationRailDestination(
                          icon: item.icon,
                          selectedIcon: item.selectedIcon,
                          label: Text(item.label),
                        ),
                      )
                      .toList(),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            ),
          );
        }
        return Scaffold(
          body: content,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: destinations,
          ),
        );
      },
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, required this.child, this.action});
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.2,
                          ),
                    ),
                  ),
                  ?action,
                ],
              ),
              const SizedBox(height: 20),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ContactsPage extends StatelessWidget {
  const _ContactsPage({
    required this.controller,
    required this.onChat,
    required this.onAudio,
    required this.onVideo,
  });
  final AppController controller;
  final ValueChanged<TvoiceUser> onChat;
  final ValueChanged<TvoiceUser> onAudio;
  final ValueChanged<TvoiceUser> onVideo;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Контакты',
    action: IconButton.filledTonal(
      onPressed: controller.refreshContacts,
      icon: const Icon(Icons.refresh_rounded),
    ),
    child: controller.contacts.isEmpty
        ? const _EmptyState(
            icon: Icons.people_outline_rounded,
            title: 'Контактов пока нет',
            subtitle: 'Список синхронизируется с учётными записями FreePBX',
          )
        : ListView.separated(
            itemCount: controller.contacts.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final peer = controller.contacts[index];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 7,
                  ),
                  leading: CircleAvatar(
                    child: Text(
                      peer.displayName.isEmpty
                          ? '?'
                          : peer.displayName[0].toUpperCase(),
                    ),
                  ),
                  title: Text(
                    peer.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(peer.sipNumber),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        tooltip: 'Сообщение',
                        onPressed: () => onChat(peer),
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                      ),
                      IconButton(
                        tooltip: 'Аудиозвонок',
                        onPressed: () => onAudio(peer),
                        icon: const Icon(Icons.call_outlined),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Видеозвонок',
                        onPressed: () => onVideo(peer),
                        icon: const Icon(Icons.videocam_outlined),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

class _CallsPage extends StatefulWidget {
  const _CallsPage({required this.controller, required this.onCall});
  final AppController controller;
  final Future<void> Function(String) onCall;
  @override
  State<_CallsPage> createState() => _CallsPageState();
}

class _CallsPageState extends State<_CallsPage> {
  final number = TextEditingController();

  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Звонки',
    child: LayoutBuilder(
      builder: (context, constraints) {
        final history = _DesktopCallHistory(
          entries: widget.controller.callHistory,
          onCall: widget.onCall,
        );
        final dialer = _DesktopDialer(number: number, onCall: widget.onCall);
        if (constraints.maxWidth < 760) {
          return ListView(
            children: [
              SizedBox(height: 330, child: history),
              const SizedBox(height: 18),
              dialer,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 5, child: history),
            const SizedBox(width: 20),
            Expanded(flex: 4, child: dialer),
          ],
        );
      },
    ),
  );
}

class _DesktopCallHistory extends StatelessWidget {
  const _DesktopCallHistory({required this.entries, required this.onCall});
  final List<CallHistoryEntry> entries;
  final Future<void> Function(String) onCall;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('История', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Expanded(
            child: entries.isEmpty
                ? const _EmptyState(
                    icon: Icons.history_rounded,
                    title: 'История пока пуста',
                    subtitle: 'Совершённые и пропущенные звонки появятся здесь',
                  )
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final unsuccessful = entry.result != CallResult.completed;
                      final accent = unsuccessful
                          ? Theme.of(context).colorScheme.error
                          : const Color(0xff16a36a);
                      return ListTile(
                        onTap: () => onCall(entry.number),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 3,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: accent.withValues(alpha: .12),
                          foregroundColor: accent,
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
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(_desktopCallDescription(entry)),
                        trailing: IconButton(
                          tooltip: 'Позвонить снова',
                          onPressed: () => onCall(entry.number),
                          icon: const Icon(Icons.call_rounded),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _DesktopDialer extends StatelessWidget {
  const _DesktopDialer({required this.number, required this.onCall});
  final TextEditingController number;
  final Future<void> Function(String) onCall;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextField(
            controller: number,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.phone,
            style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              hintText: 'Номер абонента',
              prefixIcon: Icon(Icons.dialpad_rounded),
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: List.generate(12, (index) {
              final label = index < 9
                  ? '${index + 1}'
                  : index == 9
                  ? '*'
                  : index == 10
                  ? '0'
                  : '#';
              return SizedBox.square(
                dimension: 58,
                child: FilledButton.tonal(
                  onPressed: () {
                    number.text += label;
                    number.selection = TextSelection.collapsed(
                      offset: number.text.length,
                    );
                  },
                  child: Text(label, style: const TextStyle(fontSize: 21)),
                ),
              );
            }),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filled(
                onPressed: () {
                  if (number.text.isNotEmpty) onCall(number.text);
                },
                iconSize: 29,
                padding: const EdgeInsets.all(15),
                icon: const Icon(Icons.call_rounded),
              ),
              const SizedBox(width: 18),
              IconButton.filledTonal(
                onPressed: () {
                  if (number.text.isNotEmpty) {
                    number.text = number.text.substring(
                      0,
                      number.text.length - 1,
                    );
                  }
                },
                iconSize: 25,
                padding: const EdgeInsets.all(15),
                icon: const Icon(Icons.backspace_outlined),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

String _desktopCallDescription(CallHistoryEntry entry) {
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

class _ChatsPage extends StatelessWidget {
  const _ChatsPage({required this.controller, required this.onOpen});
  final AppController controller;
  final ValueChanged<Conversation> onOpen;
  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Чаты',
    action: IconButton.filledTonal(
      onPressed: controller.refreshConversations,
      icon: const Icon(Icons.refresh_rounded),
    ),
    child: controller.conversations.isEmpty
        ? const _EmptyState(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Сообщений пока нет',
            subtitle: 'Начните чат из раздела «Контакты»',
          )
        : ListView.separated(
            itemCount: controller.conversations.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = controller.conversations[index];
              return Card(
                child: ListTile(
                  onTap: () => onOpen(item),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: CircleAvatar(
                    child: Text(
                      item.peer.displayName.isEmpty
                          ? '?'
                          : item.peer.displayName[0].toUpperCase(),
                    ),
                  ),
                  title: Text(
                    item.peer.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    item.lastMessage?.body.isNotEmpty == true
                        ? item.lastMessage!.body
                        : item.peer.sipNumber,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                ),
              );
            },
          ),
  );
}

class _AccountPage extends StatelessWidget {
  const _AccountPage({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final user = controller.user!;
    final sipText = switch (controller.sipState) {
      SipRegistrationState.registered => 'SIP подключён',
      SipRegistrationState.connecting => 'SIP подключается…',
      SipRegistrationState.failed => 'Ошибка SIP',
      SipRegistrationState.unavailable => 'SIP-модуль ожидает подключения',
    };
    return _PageFrame(
      title: 'Аккаунт',
      child: ListView(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 34,
                    child: Icon(Icons.person_rounded, size: 34),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.displayName,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(user.sipNumber),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone_in_talk_outlined),
                  title: const Text('FreePBX'),
                  subtitle: Text(sipText),
                  trailing: const Text('UDP · 5060'),
                ),
                const Divider(height: 1, indent: 56),
                const ListTile(
                  leading: Icon(Icons.chat_bubble_outline_rounded),
                  title: Text('Чат'),
                  subtitle: Text('Подключён к защищённому серверу'),
                ),
                const Divider(height: 1, indent: 56),
                const ListTile(
                  leading: Icon(Icons.hd_rounded),
                  title: Text('Видео'),
                  subtitle: Text('LiveKit · Full HD · UDP 443'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: ListTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('Оформление'),
              subtitle: Text(switch (controller.themeMode) {
                ThemeMode.system => 'Системная',
                ThemeMode.light => 'Светлая',
                ThemeMode.dark => 'Тёмная',
              }),
              trailing: DropdownButton<ThemeMode>(
                value: controller.themeMode,
                underline: const SizedBox(),
                onChanged: (value) {
                  if (value != null) controller.setThemeMode(value);
                },
                items: const [
                  DropdownMenuItem(
                    value: ThemeMode.system,
                    child: Text('Система'),
                  ),
                  DropdownMenuItem(
                    value: ThemeMode.light,
                    child: Text('Светлая'),
                  ),
                  DropdownMenuItem(
                    value: ThemeMode.dark,
                    child: Text('Тёмная'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: controller.logout,
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Выйти из аккаунта'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Center(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 52),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 18),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ActiveCallBar extends StatelessWidget {
  const _ActiveCallBar({required this.controller, required this.onTap});
  final AppController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Material(
        elevation: 10,
        shadowColor: Colors.black38,
        color: const Color(0xff163d68),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0x26ffffff),
                  child: Icon(Icons.call_rounded, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        controller.sipRemoteNumber,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        controller.sipCallState == SipCallState.connected
                            ? 'Соединено · нажмите, чтобы открыть'
                            : controller.sipCallState == SipCallState.incoming
                            ? 'Входящий звонок'
                            : 'Идёт вызов…',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filled(
                  onPressed: controller.hangupSipCall,
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xffef4058),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.call_end_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
