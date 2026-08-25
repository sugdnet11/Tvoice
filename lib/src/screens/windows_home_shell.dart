import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../models/models.dart';
import '../services/sip_bridge.dart';
import '../services/desktop_window_controller.dart';
import '../theme/desktop_design.dart';
import '../widgets/tvoice_logo.dart';
import 'audio_call_screen.dart';
import 'windows_conference_screen.dart';

enum _DesktopSection { calls, dialer, contacts, chats, conferences }

enum _CallFilter { all, missed, favorites }

class WindowsHomeShell extends StatefulWidget {
  const WindowsHomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<WindowsHomeShell> createState() => _WindowsHomeShellState();
}

class _WindowsHomeShellState extends State<WindowsHomeShell> {
  _DesktopSection _section = _DesktopSection.calls;
  _CallFilter _callFilter = _CallFilter.all;
  String _contactQuery = '';
  String _callQuery = '';
  String _chatQuery = '';
  String? _selectedContactId;
  String? _selectedCallNumber;
  String? _selectedConversationId;
  bool _chatDetailsVisible = false;
  String? _shownIncomingVideoId;
  bool _accountMenuVisible = false;
  bool _audioScreenVisible = false;
  final FocusNode _accountMenuFocusNode = FocusNode(debugLabel: 'account-menu');
  StreamSubscription<Uri>? _deepLinkSubscription;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    _deepLinkSubscription = DesktopWindowController.links.listen(
      _handleDeepLink,
    );
    final pendingLink = DesktopWindowController.takePendingLink();
    if (pendingLink != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _handleDeepLink(pendingLink),
      );
    }
    unawaited(_restoreDesktopSection());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _accountMenuFocusNode.dispose();
    unawaited(_deepLinkSubscription?.cancel());
    super.dispose();
  }

  Future<void> _handleDeepLink(Uri uri) async {
    if (!mounted || uri.host != 'conference' || uri.path != '/join') return;
    final token = uri.queryParameters['token'];
    if (token == null || token.length < 32) return;
    try {
      final session = await widget.controller.joinConference(token);
      if (mounted) await _openConference(session);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось войти в конференцию: $error')),
        );
      }
    }
  }

  Future<void> _restoreDesktopSection() async {
    final sipNumber = widget.controller.user?.sipNumber;
    if (sipNumber == null || sipNumber.isEmpty) return;
    final stored = await widget.controller.sessionStore.readDesktopSection(
      sipNumber,
    );
    final section = switch (stored) {
      'contacts' => _DesktopSection.contacts,
      'dialer' => _DesktopSection.dialer,
      'chats' => _DesktopSection.chats,
      'conferences' => _DesktopSection.conferences,
      _ => _DesktopSection.calls,
    };
    if (mounted) {
      setState(() => _section = section);
    }
  }

  void _selectSection(_DesktopSection section) {
    setState(() {
      _section = section;
      _accountMenuVisible = false;
      _selectedContactId = null;
      _selectedCallNumber = null;
      _chatDetailsVisible = false;
    });
    final sipNumber = widget.controller.user?.sipNumber;
    if (sipNumber != null && sipNumber.isNotEmpty) {
      unawaited(
        widget.controller.sessionStore.writeDesktopSection(
          sipNumber,
          section.name,
        ),
      );
    }
  }

  void _toggleAccountMenu() {
    setState(() => _accountMenuVisible = !_accountMenuVisible);
    if (_accountMenuVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _accountMenuFocusNode.requestFocus();
      });
    }
  }

  void _closeAccountMenu() {
    if (_accountMenuVisible) {
      setState(() => _accountMenuVisible = false);
    }
  }

  void _closeDetails() {
    if (_selectedContactId == null &&
        _selectedCallNumber == null &&
        !_chatDetailsVisible) {
      return;
    }
    setState(() {
      _selectedContactId = null;
      _selectedCallNumber = null;
      _chatDetailsVisible = false;
    });
  }

  void _controllerChanged() {
    if (widget.controller.sipCallState == SipCallState.incoming &&
        !_audioScreenVisible &&
        mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openAudioCall());
    }
    final call = widget.controller.incomingVideoCall;
    if (call == null) {
      _shownIncomingVideoId = null;
      return;
    }
    if (_shownIncomingVideoId == call.callId || !mounted) return;
    _shownIncomingVideoId = call.callId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showIncoming(call));
  }

  Future<void> _showIncoming(VideoCallSession call) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const CircleAvatar(
          radius: 32,
          child: Icon(Icons.videocam_rounded, size: 32),
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
            label: const Text('Ответить'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    try {
      if (accepted == true) {
        final session = await widget.controller.answerIncomingVideo();
        if (session != null && mounted) await _openConference(session);
      } else {
        await widget.controller.rejectIncomingVideo();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось принять вызов: $error')),
        );
      }
    }
  }

  Future<void> _startAudio(String number) async {
    if (number.isEmpty) return;
    if (await widget.controller.startAudioCall(number) && mounted) {
      await _openAudioCall();
    }
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

  Future<void> _openConference(VideoCallSession session) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => WindowsConferenceScreen(
            controller: widget.controller,
            session: session,
          ),
        ),
      );

  Future<void> _openChatFor(TvoiceUser peer) async {
    try {
      final conversation = await widget.controller.openDirect(peer);
      if (!mounted) return;
      setState(() {
        _section = _DesktopSection.chats;
        _selectedConversationId = conversation.id;
      });
      final sipNumber = widget.controller.user?.sipNumber;
      if (sipNumber != null && sipNumber.isNotEmpty) {
        unawaited(
          widget.controller.sessionStore.writeDesktopSection(
            sipNumber,
            _DesktopSection.chats.name,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _closeAccountMenu();
          _closeDetails();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Stack(
            children: [
              Row(
                children: [
                  _Sidebar(
                    section: _section,
                    accountMenuVisible: _accountMenuVisible,
                    sipNumber: widget.controller.user?.sipNumber ?? '',
                    onSection: _selectSection,
                    onAccount: _toggleAccountMenu,
                  ),
                  VerticalDivider(width: 1, color: scheme.outlineVariant),
                  Expanded(child: _buildSection()),
                ],
              ),
              if (_accountMenuVisible) ...[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closeAccountMenu,
                  ),
                ),
                Positioned(
                  left: TvSizes.sidebar,
                  bottom: 18,
                  child: _AccountPopover(
                    controller: widget.controller,
                    focusNode: _accountMenuFocusNode,
                    onSettings: _showSettings,
                    onAddAccount: _addAccount,
                    onLogout: () async {
                      _closeAccountMenu();
                      await widget.controller.logout();
                    },
                  ),
                ),
              ],
              if (_detailsContent() case final details?)
                _DetailsDrawer(onClose: _closeDetails, child: details),
              if (widget.controller.hasActiveSipCall)
                Positioned(
                  left: TvSizes.sidebar + 24,
                  right: 24,
                  bottom: 18,
                  child: _ActiveCallBar(
                    controller: widget.controller,
                    onOpen: _openAudioCall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection() => switch (_section) {
    _DesktopSection.contacts => _contactsSection(),
    _DesktopSection.calls => _callsSection(),
    _DesktopSection.dialer => _dialerSection(),
    _DesktopSection.chats => _chatsSection(),
    _DesktopSection.conferences => _conferencesSection(),
  };

  Widget _contactsSection() {
    final contacts = widget.controller.contacts.where((peer) {
      final query = _contactQuery.toLowerCase();
      return query.isEmpty ||
          peer.sipNumber.toLowerCase().contains(query) ||
          peer.displayName.toLowerCase().contains(query);
    }).toList();
    final selected = contacts.where((peer) => peer.id == _selectedContactId);
    final peer = selected.isNotEmpty ? selected.first : null;
    return _ListPanel(
      title: 'Контакты',
      subtitle: '${contacts.length} абонентов',
      searchHint: 'Поиск контактов',
      onSearch: (value) => setState(() => _contactQuery = value),
      onRefresh: widget.controller.refreshContacts,
      child: contacts.isEmpty
          ? const _EmptyPanel(
              icon: Icons.people_outline_rounded,
              title: 'Контактов пока нет',
              subtitle: 'Список синхронизируется с FreePBX',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
              itemCount: contacts.length,
              itemBuilder: (context, index) {
                final item = contacts[index];
                return _PersonRow(
                  peer: item,
                  selected: item.id == peer?.id,
                  onTap: () => setState(() => _selectedContactId = item.id),
                  onCall: () => _startAudio(item.sipNumber),
                );
              },
            ),
    );
  }

  Widget _callsSection() {
    final history = widget.controller.callHistory.where((entry) {
      final matchesFilter = switch (_callFilter) {
        _CallFilter.all => true,
        _CallFilter.missed => entry.result == CallResult.missed,
        _CallFilter.favorites => widget.controller.favoriteCallNumbers.contains(
          entry.number,
        ),
      };
      final query = _callQuery.trim().toLowerCase();
      final contact = _contactByNumber(entry.number);
      return matchesFilter &&
          (query.isEmpty ||
              entry.number.toLowerCase().contains(query) ||
              (contact?.displayName.toLowerCase().contains(query) ?? false));
    }).toList();
    final selectedNumber = _selectedCallNumber;
    return Padding(
      padding: const EdgeInsets.all(TvSizes.contentPadding),
      child: _CallsPanel(
        entries: history,
        filter: _callFilter,
        favorites: widget.controller.favoriteCallNumbers,
        contacts: widget.controller.contacts,
        selectedNumber: selectedNumber,
        sipNumber: widget.controller.user?.sipNumber ?? '',
        onFilter: (value) => setState(() => _callFilter = value),
        onSearch: (value) => setState(() => _callQuery = value),
        onSelect: (number) => setState(() => _selectedCallNumber = number),
        onCall: _startAudio,
        onVideo: (number) {
          final peer = _contactByNumber(number);
          if (peer != null) _startVideo(peer);
        },
      ),
    );
  }

  Widget _dialerSection() => _DialerPanel(
    onAudio: _startAudio,
    onVideo: (number) => _startVideo(
      _contactByNumber(number) ??
          TvoiceUser(
            id: 'number-$number',
            sipNumber: number,
            displayName: number,
          ),
    ),
  );

  TvoiceUser? _contactByNumber(String number) {
    for (final peer in widget.controller.contacts) {
      if (peer.sipNumber == number) return peer;
    }
    return null;
  }

  Widget _chatsSection() {
    final conversations = widget.controller.conversations.where((item) {
      final query = _chatQuery.toLowerCase();
      return query.isEmpty ||
          item.peer.sipNumber.toLowerCase().contains(query) ||
          item.peer.displayName.toLowerCase().contains(query);
    }).toList();
    final selected = conversations.where(
      (item) => item.id == _selectedConversationId,
    );
    final conversation = selected.isNotEmpty
        ? selected.first
        : conversations.isEmpty
        ? null
        : conversations.first;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          children: [
            SizedBox(
              width: 390,
              child: _ListPanel(
                title: 'Чаты',
                subtitle: '',
                searchHint: 'Поиск чатов',
                onSearch: (value) => setState(() => _chatQuery = value),
                onRefresh: widget.controller.refreshConversations,
                child: conversations.isEmpty
                    ? const _EmptyPanel(
                        icon: Icons.chat_bubble_outline_rounded,
                        title: 'Сообщений пока нет',
                        subtitle: 'Начните диалог в разделе «Контакты»',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 18),
                        itemCount: conversations.length,
                        itemBuilder: (context, index) {
                          final item = conversations[index];
                          return _ConversationRow(
                            conversation: item,
                            selected: item.id == conversation?.id,
                            onTap: () => setState(() {
                              _selectedConversationId = item.id;
                              _chatDetailsVisible = false;
                            }),
                          );
                        },
                      ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: conversation == null
                  ? const _WelcomePanel(
                      icon: Icons.forum_outlined,
                      title: 'Выберите диалог',
                      subtitle: 'Переписка откроется в этой части окна',
                    )
                  : _DesktopConversation(
                      key: ValueKey(conversation.id),
                      controller: widget.controller,
                      conversation: conversation,
                      onAudio: () => _startAudio(conversation.peer.sipNumber),
                      onVideo: () => _startVideo(conversation.peer),
                      onDetails: () => setState(
                        () => _chatDetailsVisible = !_chatDetailsVisible,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _conferencesSection() => _ConferenceLanding(
    controller: widget.controller,
    onOpen: _openConference,
  );

  Widget? _detailsContent() {
    if (_section == _DesktopSection.contacts && _selectedContactId != null) {
      final matches = widget.controller.contacts.where(
        (peer) => peer.id == _selectedContactId,
      );
      if (matches.isEmpty) return null;
      final peer = matches.first;
      return _ContactDetails(
        peer: peer,
        favorite: widget.controller.favoriteCallNumbers.contains(
          peer.sipNumber,
        ),
        onFavorite: () =>
            widget.controller.toggleFavoriteCallNumber(peer.sipNumber),
        onChat: () => _openChatFor(peer),
        onAudio: () => _startAudio(peer.sipNumber),
        onVideo: () => _startVideo(peer),
      );
    }
    if (_section == _DesktopSection.calls && _selectedCallNumber != null) {
      final number = _selectedCallNumber!;
      final peer =
          _contactByNumber(number) ??
          TvoiceUser(
            id: 'number-$number',
            sipNumber: number,
            displayName: number,
          );
      return _CallContactPanel(
        peer: peer,
        entries: widget.controller.callHistory
            .where((item) => item.number == number)
            .toList(),
        favorite: widget.controller.favoriteCallNumbers.contains(number),
        onFavorite: () => widget.controller.toggleFavoriteCallNumber(number),
        onAudio: () => _startAudio(number),
        onVideo: () => _startVideo(peer),
      );
    }
    if (_section == _DesktopSection.chats && _chatDetailsVisible) {
      final matches = widget.controller.conversations.where(
        (item) => item.id == _selectedConversationId,
      );
      if (matches.isEmpty) return null;
      final peer = matches.first.peer;
      return _ChatInfoPanel(
        peer: peer,
        onAudio: () => _startAudio(peer.sipNumber),
        onVideo: () => _startVideo(peer),
      );
    }
    return null;
  }

  Future<void> _showSettings() async {
    setState(() => _accountMenuVisible = false);
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Настройки оформления'),
        children: [
          _ThemeChoice(
            label: 'Системная тема',
            value: ThemeMode.system,
            selected: widget.controller.themeMode,
          ),
          _ThemeChoice(
            label: 'Светлая тема',
            value: ThemeMode.light,
            selected: widget.controller.themeMode,
          ),
          _ThemeChoice(
            label: 'Тёмная тема',
            value: ThemeMode.dark,
            selected: widget.controller.themeMode,
          ),
        ],
      ),
    );
    if (selected != null) widget.controller.setThemeMode(selected);
  }

  Future<void> _addAccount() async {
    setState(() => _accountMenuVisible = false);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Добавить аккаунт'),
        content: const Text(
          'Откроется экран входа для подключения другого SIP-аккаунта.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    if (proceed == true) await widget.controller.logout();
  }
}

class _DetailsDrawer extends StatelessWidget {
  const _DetailsDrawer({required this.onClose, required this.child});

  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: Colors.black.withValues(alpha: .12)),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          width: 360,
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 190),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 1, end: 0),
            builder: (context, value, content) => Transform.translate(
              offset: Offset(360 * value, 0),
              child: content,
            ),
            child: Material(
              elevation: 18,
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                child: Stack(
                  children: [
                    Positioned.fill(child: child),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton(
                        tooltip: 'Закрыть',
                        onPressed: onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _DialerPanel extends StatefulWidget {
  const _DialerPanel({required this.onAudio, required this.onVideo});
  final ValueChanged<String> onAudio;
  final ValueChanged<String> onVideo;

  @override
  State<_DialerPanel> createState() => _DialerPanelState();
}

class _DialerPanelState extends State<_DialerPanel> {
  final _number = TextEditingController();
  final _focus = FocusNode(debugLabel: 'desktop-dialer');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _number.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _append(String value) {
    _number.text += value;
    _number.selection = TextSelection.collapsed(offset: _number.text.length);
    setState(() {});
  }

  void _backspace() {
    if (_number.text.isEmpty) return;
    _number.text = _number.text.substring(0, _number.text.length - 1);
    _number.selection = TextSelection.collapsed(offset: _number.text.length);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final character = event.character;
      if (character != null && RegExp(r'^[0-9*#]$').hasMatch(character)) {
        _append(character);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        _backspace();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          _number.text.isNotEmpty) {
        widget.onAudio(_number.text);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Padding(
      padding: const EdgeInsets.all(TvSizes.contentPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader(title: 'Набор номера', sipNumber: ''),
          const Spacer(),
          Center(
            child: SizedBox(
              width: 360,
              child: Column(
                children: [
                  TextField(
                    controller: _number,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9*#]')),
                    ],
                    keyboardType: TextInputType.phone,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (_number.text.isNotEmpty) widget.onAudio(_number.text);
                    },
                    decoration: InputDecoration(
                      hintText: 'Введите SIP-номер',
                      suffixIcon: IconButton(
                        tooltip: 'Удалить цифру',
                        onPressed: _backspace,
                        icon: const Icon(Icons.backspace_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.65,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (final key in const [
                        '1',
                        '2',
                        '3',
                        '4',
                        '5',
                        '6',
                        '7',
                        '8',
                        '9',
                        '*',
                        '0',
                        '#',
                      ])
                        FilledButton.tonal(
                          onPressed: () => _append(key),
                          child: Text(
                            key,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _number.text.isEmpty
                            ? null
                            : () => widget.onAudio(_number.text),
                        icon: const Icon(Icons.call_rounded),
                        label: const Text('Позвонить'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _number.text.isEmpty
                            ? null
                            : () => widget.onVideo(_number.text),
                        icon: const Icon(Icons.videocam_rounded),
                        label: const Text('Видео'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.section,
    required this.accountMenuVisible,
    required this.sipNumber,
    required this.onSection,
    required this.onAccount,
  });

  final _DesktopSection section;
  final bool accountMenuVisible;
  final String sipNumber;
  final ValueChanged<_DesktopSection> onSection;
  final VoidCallback onAccount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: TvSizes.sidebar,
      decoration: const BoxDecoration(
        color: TvColors.panel,
        border: Border(right: BorderSide(color: TvColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 14),
      child: Column(
        children: [
          const TvoiceLogo(size: 40, showWordmark: false),
          const SizedBox(height: 30),
          _SideItem(
            icon: Icons.call_rounded,
            label: 'Звонки',
            selected: section == _DesktopSection.calls,
            onTap: () => onSection(_DesktopSection.calls),
          ),
          _SideItem(
            icon: Icons.dialpad_rounded,
            label: 'Набор номера',
            selected: section == _DesktopSection.dialer,
            onTap: () => onSection(_DesktopSection.dialer),
          ),
          _SideItem(
            icon: Icons.contacts_rounded,
            label: 'Контакты',
            selected: section == _DesktopSection.contacts,
            onTap: () => onSection(_DesktopSection.contacts),
          ),
          _SideItem(
            icon: Icons.chat_bubble_rounded,
            label: 'Чаты',
            selected: section == _DesktopSection.chats,
            onTap: () => onSection(_DesktopSection.chats),
          ),
          _SideItem(
            icon: Icons.groups_rounded,
            label: 'Конференции',
            selected: section == _DesktopSection.conferences,
            onTap: () => onSection(_DesktopSection.conferences),
          ),
          const Spacer(),
          _AccountButton(
            label: sipNumber.isEmpty ? 'Аккаунт' : sipNumber,
            initials: sipNumber.isEmpty ? 'T' : sipNumber.substring(0, 1),
            selected: accountMenuVisible,
            onTap: onAccount,
          ),
        ],
      ),
    );
  }
}

class _AccountButton extends StatelessWidget {
  const _AccountButton({
    required this.label,
    required this.initials,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String initials;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    preferBelow: false,
    child: Material(
      color: selected ? TvColors.selected : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        key: const ValueKey('desktop-account-button'),
        onTap: onTap,
        customBorder: const CircleBorder(),
        focusColor: TvColors.selected,
        hoverColor: TvColors.selected,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: CircleAvatar(
            radius: 21,
            backgroundColor: selected ? TvColors.bluePressed : TvColors.blue,
            foregroundColor: Colors.white,
            child: Text(
              initials.toUpperCase(),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      preferBelow: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              color: selected ? TvColors.selected : Colors.transparent,
              borderRadius: BorderRadius.circular(TvSizes.radius),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(TvSizes.radius),
                child: SizedBox.square(
                  dimension: TvSizes.sidebarAction,
                  child: Icon(
                    icon,
                    size: TvSizes.sidebarIcon,
                    color: selected ? TvColors.blue : TvColors.iconMuted,
                  ),
                ),
              ),
            ),
            if (selected)
              const Positioned(
                left: -12,
                top: 10,
                bottom: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: TvColors.blue,
                    borderRadius: BorderRadius.horizontal(
                      right: Radius.circular(3),
                    ),
                  ),
                  child: SizedBox(width: 3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ListPanel extends StatelessWidget {
  const _ListPanel({
    required this.title,
    required this.subtitle,
    required this.searchHint,
    required this.onSearch,
    required this.onRefresh,
    required this.child,
  });

  final String title;
  final String subtitle;
  final String searchHint;
  final ValueChanged<String> onSearch;
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.7,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Обновить',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: TextField(
            onChanged: onSearch,
            decoration: InputDecoration(
              hintText: searchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
            ),
          ),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.peer,
    required this.selected,
    required this.onTap,
    required this.onCall,
  });

  final TvoiceUser peer;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          onTap: onTap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: CircleAvatar(
            child: Text(_initial(peer.displayName, peer.sipNumber)),
          ),
          title: Text(
            peer.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(peer.sipNumber),
          trailing: IconButton(
            tooltip: 'Позвонить',
            onPressed: onCall,
            icon: const Icon(Icons.call_rounded),
          ),
        ),
      ),
    );
  }
}

class _ContactDetails extends StatelessWidget {
  const _ContactDetails({
    required this.peer,
    required this.favorite,
    required this.onFavorite,
    required this.onChat,
    required this.onAudio,
    required this.onVideo,
  });

  final TvoiceUser peer;
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onChat;
  final VoidCallback onAudio;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            children: [
              CircleAvatar(
                radius: 58,
                child: Text(
                  _initial(peer.displayName, peer.sipNumber),
                  style: const TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                peer.displayName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                peer.sipNumber,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: onAudio,
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Позвонить'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: onVideo,
                    icon: const Icon(Icons.videocam_rounded),
                    label: const Text('Видео'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: onChat,
                    icon: const Icon(Icons.chat_bubble_rounded),
                    label: const Text('Сообщение'),
                  ),
                  IconButton.filledTonal(
                    tooltip: favorite
                        ? 'Убрать из избранных'
                        : 'Добавить в избранные',
                    onPressed: onFavorite,
                    icon: Icon(
                      favorite ? Icons.star_rounded : Icons.star_border_rounded,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ignore: unused_element
class _LegacyCallsPanel extends StatelessWidget {
  const _LegacyCallsPanel({
    required this.entries,
    required this.filter,
    required this.favorites,
    required this.onFilter,
    required this.onCall,
    required this.onFavorite,
  });

  final List<CallHistoryEntry> entries;
  final _CallFilter filter;
  final Set<String> favorites;
  final ValueChanged<_CallFilter> onFilter;
  final ValueChanged<String> onCall;
  final ValueChanged<String> onFavorite;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 14),
          child: Text(
            'Звонки',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -.7,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: SegmentedButton<_CallFilter>(
            segments: const [
              ButtonSegment(value: _CallFilter.all, label: Text('Все')),
              ButtonSegment(
                value: _CallFilter.missed,
                label: Text('Пропущенные'),
              ),
              ButtonSegment(
                value: _CallFilter.favorites,
                label: Text('Избранные'),
              ),
            ],
            selected: {filter},
            showSelectedIcon: false,
            onSelectionChanged: (value) => onFilter(value.first),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? _EmptyPanel(
                  icon: filter == _CallFilter.favorites
                      ? Icons.star_border_rounded
                      : Icons.history_rounded,
                  title: switch (filter) {
                    _CallFilter.all => 'История пока пуста',
                    _CallFilter.missed => 'Нет пропущенных звонков',
                    _CallFilter.favorites => 'Нет избранных номеров',
                  },
                  subtitle: filter == _CallFilter.favorites
                      ? 'Нажмите звезду возле номера в истории или контактах'
                      : 'Новые звонки появятся в этом списке',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final missed = entry.result == CallResult.missed;
                    final failed = entry.result == CallResult.failed;
                    final accent = missed || failed
                        ? Theme.of(context).colorScheme.error
                        : const Color(0xff16a36a);
                    final favorite = favorites.contains(entry.number);
                    return ListTile(
                      onTap: () => onCall(entry.number),
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
                        style: TextStyle(
                          color: missed ? accent : null,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(_callDescription(entry)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: favorite
                                ? 'Убрать из избранных'
                                : 'В избранные',
                            onPressed: () => onFavorite(entry.number),
                            icon: Icon(
                              favorite
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Позвонить',
                            onPressed: () => onCall(entry.number),
                            icon: const Icon(Icons.call_rounded),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _CallsPanel extends StatelessWidget {
  const _CallsPanel({
    required this.entries,
    required this.filter,
    required this.favorites,
    required this.contacts,
    required this.selectedNumber,
    required this.sipNumber,
    required this.onFilter,
    required this.onSearch,
    required this.onSelect,
    required this.onCall,
    required this.onVideo,
  });

  final List<CallHistoryEntry> entries;
  final _CallFilter filter;
  final Set<String> favorites;
  final List<TvoiceUser> contacts;
  final String? selectedNumber;
  final String sipNumber;
  final ValueChanged<_CallFilter> onFilter;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onCall;
  final ValueChanged<String> onVideo;

  TvoiceUser? _peer(String number) {
    for (final peer in contacts) {
      if (peer.sipNumber == number) return peer;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final today = <CallHistoryEntry>[];
    final older = <CallHistoryEntry>[];
    final now = DateTime.now();
    for (final entry in entries) {
      final local = entry.startedAt.toLocal();
      if (local.year == now.year &&
          local.month == now.month &&
          local.day == now.day) {
        today.add(entry);
      } else {
        older.add(entry);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title: 'Звонки', sipNumber: sipNumber),
        const SizedBox(height: 18),
        Row(
          children: [
            _FilterTabs(filter: filter, onChanged: onFilter),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: TvSizes.searchHeight,
                child: TextField(
                  onChanged: onSearch,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Поиск',
                    isDense: true,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Expanded(
          child: entries.isEmpty
              ? _EmptyPanel(
                  icon: filter == _CallFilter.favorites
                      ? Icons.star_border_rounded
                      : Icons.history_rounded,
                  title: switch (filter) {
                    _CallFilter.all => 'История пока пуста',
                    _CallFilter.missed => 'Нет пропущенных звонков',
                    _CallFilter.favorites => 'Нет избранных номеров',
                  },
                  subtitle: 'Новые звонки появятся в этом списке',
                )
              : ListView(
                  children: [
                    if (today.isNotEmpty) ...[
                      const _ListGroupLabel('Сегодня'),
                      ...today.map(_row),
                    ],
                    if (older.isNotEmpty) ...[
                      const _ListGroupLabel('Ранее'),
                      ...older.map(_row),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _row(CallHistoryEntry entry) {
    final peer = _peer(entry.number);
    final selected = selectedNumber == entry.number;
    final missed =
        entry.result == CallResult.missed || entry.result == CallResult.failed;
    final directionIcon = entry.direction == CallDirection.incoming
        ? Icons.call_received_rounded
        : Icons.call_made_rounded;
    return Container(
      key: ValueKey('call-row-${entry.id}'),
      height: TvSizes.listRow,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: selected ? TvColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(TvSizes.radius),
        border: selected ? Border.all(color: const Color(0xffd5e7ff)) : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(TvSizes.radius),
        onTap: () => onSelect(entry.number),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _Avatar(
                label: _initial(
                  peer?.displayName ?? entry.number,
                  entry.number,
                ),
                online: !missed,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer?.displayName ?? entry.number,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          directionIcon,
                          size: 16,
                          color: missed ? TvColors.red : TvColors.green,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          entry.number,
                          style: const TextStyle(
                            color: TvColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                _messageTime(entry.startedAt),
                style: const TextStyle(
                  color: TvColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 28),
              SizedBox(
                width: 52,
                child: Text(
                  _compactDuration(entry.duration),
                  style: const TextStyle(
                    color: TvColors.textSecondary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              _RoundAction(
                tooltip: 'Аудиозвонок',
                icon: Icons.call_rounded,
                onPressed: () => onCall(entry.number),
              ),
              const SizedBox(width: 8),
              _RoundAction(
                tooltip: 'Видеозвонок',
                icon: Icons.videocam_rounded,
                onPressed: () => onVideo(entry.number),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.more_vert_rounded, color: TvColors.iconMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterTabs extends StatelessWidget {
  const _FilterTabs({required this.filter, required this.onChanged});
  final _CallFilter filter;
  final ValueChanged<_CallFilter> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    height: 46,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: TvColors.subtle,
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _tab('Все', _CallFilter.all, 68),
        _tab('Пропущенные', _CallFilter.missed, 126),
        _tab('Избранные', _CallFilter.favorites, 104),
      ],
    ),
  );

  Widget _tab(String label, _CallFilter value, double width) => SizedBox(
    width: width,
    child: Material(
      color: value == filter ? TvColors.blue : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(10),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: value == filter ? Colors.white : TvColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}

// ignore: unused_element
class _DesktopDialer extends StatelessWidget {
  const _DesktopDialer({
    required this.number,
    required this.onAudio,
    required this.onVideo,
  });

  final TextEditingController number;
  final VoidCallback onAudio;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            children: [
              const Text(
                'Набор номера',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 22),
              TextField(
                controller: number,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.phone,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
                decoration: const InputDecoration(hintText: 'Номер абонента'),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: List.generate(12, (index) {
                  final label = index < 9
                      ? '${index + 1}'
                      : index == 9
                      ? '*'
                      : index == 10
                      ? '0'
                      : '#';
                  return SizedBox.square(
                    dimension: 60,
                    child: FilledButton.tonal(
                      onPressed: () {
                        number.text += label;
                        number.selection = TextSelection.collapsed(
                          offset: number.text.length,
                        );
                      },
                      child: Text(label, style: const TextStyle(fontSize: 20)),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filled(
                    tooltip: 'Аудиозвонок',
                    onPressed: onAudio,
                    padding: const EdgeInsets.all(16),
                    icon: const Icon(Icons.call_rounded, size: 28),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(
                    tooltip: 'Видеозвонок',
                    onPressed: onVideo,
                    padding: const EdgeInsets.all(16),
                    icon: const Icon(Icons.videocam_rounded, size: 28),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(
                    tooltip: 'Удалить цифру',
                    onPressed: () {
                      if (number.text.isEmpty) return;
                      number.text = number.text.substring(
                        0,
                        number.text.length - 1,
                      );
                    },
                    padding: const EdgeInsets.all(16),
                    icon: const Icon(Icons.backspace_outlined, size: 25),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          onTap: onTap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          leading: CircleAvatar(
            child: Text(
              _initial(
                conversation.peer.displayName,
                conversation.peer.sipNumber,
              ),
            ),
          ),
          title: Text(
            conversation.peer.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            conversation.lastMessage?.body.isNotEmpty == true
                ? conversation.lastMessage!.body
                : conversation.peer.sipNumber,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _DesktopConversation extends StatefulWidget {
  const _DesktopConversation({
    super.key,
    required this.controller,
    required this.conversation,
    required this.onAudio,
    required this.onVideo,
    required this.onDetails,
  });

  final AppController controller;
  final Conversation conversation;
  final VoidCallback onAudio;
  final VoidCallback onVideo;
  final VoidCallback onDetails;

  @override
  State<_DesktopConversation> createState() => _DesktopConversationState();
}

class _DesktopConversationState extends State<_DesktopConversation> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await widget.controller.loadMessages(widget.conversation.id);
      _scrollDown();
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final value = _text.text.trim();
    if (_sending || value.isEmpty) return;
    _text.clear();
    setState(() => _sending = true);
    try {
      await widget.controller.sendMessage(widget.conversation.id, value);
      _scrollDown();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final messages =
        widget.controller.messages[widget.conversation.id] ??
        const <ChatMessage>[];
    return SafeArea(
      child: Column(
        children: [
          Container(
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                InkWell(
                  onTap: widget.onDetails,
                  customBorder: const CircleBorder(),
                  child: CircleAvatar(
                    child: Text(
                      _initial(
                        widget.conversation.peer.displayName,
                        widget.conversation.peer.sipNumber,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: widget.onDetails,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.conversation.peer.displayName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          widget.conversation.peer.sipNumber,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Аудиозвонок',
                  onPressed: widget.onAudio,
                  icon: const Icon(Icons.call_outlined),
                ),
                IconButton(
                  tooltip: 'Видеозвонок',
                  onPressed: widget.onVideo,
                  icon: const Icon(Icons.videocam_outlined),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _EmptyPanel(
                    icon: Icons.cloud_off_rounded,
                    title: 'Не удалось загрузить сообщения',
                    subtitle: _error!,
                  )
                : messages.isEmpty
                ? const _EmptyPanel(
                    icon: Icons.waving_hand_outlined,
                    title: 'Начните диалог',
                    subtitle: 'Отправьте первое сообщение этому абоненту',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(18),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final mine = message.sentBy(widget.controller.user!.id);
                      return Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 520),
                          margin: const EdgeInsets.only(bottom: 7),
                          padding: const EdgeInsets.fromLTRB(13, 9, 9, 7),
                          decoration: BoxDecoration(
                            color: mine
                                ? scheme.primaryContainer
                                : Theme.of(context).cardColor,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(15),
                              topRight: const Radius.circular(15),
                              bottomLeft: Radius.circular(mine ? 15 : 4),
                              bottomRight: Radius.circular(mine ? 4 : 15),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Flexible(child: Text(message.body)),
                              const SizedBox(width: 9),
                              Text(
                                _messageTime(message.createdAt),
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 10,
                                ),
                              ),
                              if (mine) ...[
                                const SizedBox(width: 3),
                                _MessageStatus(status: message.status),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 5,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Сообщение',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageStatus extends StatelessWidget {
  const _MessageStatus({required this.status});

  final MessageStatus status;

  @override
  Widget build(BuildContext context) {
    final read = status == MessageStatus.read;
    final delivered = read || status == MessageStatus.delivered;
    return Icon(
      delivered ? Icons.done_all_rounded : Icons.done_rounded,
      size: 15,
      color: read
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

class _AccountPopover extends StatelessWidget {
  const _AccountPopover({
    required this.controller,
    required this.focusNode,
    required this.onSettings,
    required this.onAddAccount,
    required this.onLogout,
  });

  final AppController controller;
  final FocusNode focusNode;
  final VoidCallback onSettings;
  final VoidCallback onAddAccount;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final user = controller.user!;
    final scheme = Theme.of(context).colorScheme;
    final online = controller.sipState == SipRegistrationState.registered;
    final status = switch (controller.sipState) {
      SipRegistrationState.registered => 'В сети',
      SipRegistrationState.connecting => 'Подключение…',
      SipRegistrationState.failed => 'Ошибка SIP',
      SipRegistrationState.unavailable => 'Не подключено',
    };
    return FocusTraversalGroup(
      child: Focus(
        focusNode: focusNode,
        child: Material(
          key: const ValueKey('desktop-account-menu'),
          elevation: 8,
          shadowColor: const Color(0x2410233f),
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          color: scheme.surfaceContainerHigh,
          child: Container(
            width: 280,
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: TvColors.blue,
                    foregroundColor: Colors.white,
                    child: Text(
                      user.sipNumber.isEmpty ? 'T' : user.sipNumber[0],
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  title: Text(
                    user.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: online ? TvColors.green : TvColors.iconMuted,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(child: Text('${user.sipNumber} · $status')),
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  key: const ValueKey('account-settings'),
                  onTap: onSettings,
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Настройки'),
                ),
                ListTile(
                  key: const ValueKey('account-add'),
                  onTap: onAddAccount,
                  leading: const Icon(Icons.person_add_alt_1_outlined),
                  title: const Text('Добавить аккаунт'),
                ),
                const Divider(),
                ListTile(
                  key: const ValueKey('account-logout'),
                  onTap: onLogout,
                  leading: Icon(Icons.logout_rounded, color: scheme.error),
                  title: Text('Выйти', style: TextStyle(color: scheme.error)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.label,
    required this.value,
    required this.selected,
  });

  final String label;
  final ThemeMode value;
  final ThemeMode selected;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: () => Navigator.pop(context, value),
    leading: Icon(
      value == selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_off_rounded,
      color: value == selected ? Theme.of(context).colorScheme.primary : null,
    ),
    title: Text(label),
  );
}

class _ActiveCallBar extends StatelessWidget {
  const _ActiveCallBar({required this.controller, required this.onOpen});

  final AppController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 540),
      child: Material(
        elevation: 12,
        color: const Color(0xff163d68),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0x26ffffff),
                  child: Icon(Icons.call_rounded, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
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
                            ? 'Соединено · открыть звонок'
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.sipNumber});
  final String title;
  final String sipNumber;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            height: 1,
            fontWeight: FontWeight.w800,
            letterSpacing: -.7,
          ),
        ),
        const Spacer(),
        Stack(
          clipBehavior: Clip.none,
          children: [
            const CircleAvatar(
              radius: 20,
              backgroundColor: TvColors.selected,
              child: Icon(Icons.person_rounded, color: TvColors.blue),
            ),
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: TvColors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ),
        if (sipNumber.isNotEmpty) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: TvColors.blue,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              sipNumber.length > 2 ? sipNumber.substring(0, 2) : sipNumber,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _CallContactPanel extends StatelessWidget {
  const _CallContactPanel({
    required this.peer,
    required this.entries,
    required this.favorite,
    required this.onFavorite,
    required this.onAudio,
    required this.onVideo,
  });
  final TvoiceUser peer;
  final List<CallHistoryEntry> entries;
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onAudio;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: TvColors.panel,
      borderRadius: BorderRadius.circular(TvSizes.panelRadius),
      border: Border.all(color: TvColors.border),
    ),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 28, 22, 24),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Avatar(
                    label: _initial(peer.displayName, peer.sipNumber),
                    size: TvSizes.profileAvatar,
                    online: true,
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            peer.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            peer.sipNumber,
                            style: const TextStyle(
                              color: TvColors.textSecondary,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 5),
                          const Text(
                            'Онлайн',
                            style: TextStyle(
                              color: TvColors.green,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: favorite
                        ? 'Убрать из избранных'
                        : 'Добавить в избранные',
                    onPressed: onFavorite,
                    icon: Icon(
                      favorite ? Icons.star_rounded : Icons.star_border_rounded,
                    ),
                  ),
                  const Icon(
                    Icons.more_vert_rounded,
                    color: TvColors.iconMuted,
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onAudio,
                      icon: const Icon(Icons.call_rounded),
                      label: const Text('Аудиозвонок'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onVideo,
                      icon: const Icon(Icons.videocam_rounded),
                      label: const Text('Видеозвонок'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        side: const BorderSide(color: TvColors.blue),
                        foregroundColor: TvColors.blue,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Недавние звонки',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text(
                    'История с этим абонентом пуста',
                    style: TextStyle(color: TvColors.textSecondary),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: entries.take(8).length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final missed = entry.result != CallResult.completed;
                    return ListTile(
                      leading: Icon(
                        entry.direction == CallDirection.incoming
                            ? Icons.call_received_rounded
                            : Icons.call_made_rounded,
                        color: missed ? TvColors.red : TvColors.green,
                      ),
                      title: Text(
                        _relativeDate(entry.startedAt),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        missed
                            ? 'Пропущенный звонок'
                            : entry.direction == CallDirection.incoming
                            ? 'Входящий звонок'
                            : 'Исходящий звонок',
                      ),
                      trailing: Text(
                        _compactDuration(entry.duration),
                        style: const TextStyle(color: TvColors.textSecondary),
                      ),
                    );
                  },
                ),
        ),
        const Text(
          'История звонков',
          style: TextStyle(color: TvColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 14),
      ],
    ),
  );
}

class _ChatInfoPanel extends StatelessWidget {
  const _ChatInfoPanel({
    required this.peer,
    required this.onAudio,
    required this.onVideo,
  });
  final TvoiceUser peer;
  final VoidCallback onAudio;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) => Material(
    color: TvColors.panel,
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 24, 18, 10),
            child: Text(
              'Файлы, ссылки и медиа',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Text(
              'Общих файлов пока нет',
              style: TextStyle(color: TvColors.textSecondary, fontSize: 13),
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text(
              'Участники (2)',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          ListTile(
            leading: _Avatar(
              label: _initial(peer.displayName, peer.sipNumber),
              online: true,
            ),
            title: Text(
              peer.displayName,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(peer.sipNumber),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.notifications_none_rounded),
            title: const Text('Уведомления'),
            trailing: const Text(
              'Вкл.',
              style: TextStyle(color: TvColors.textSecondary),
            ),
          ),
          ListTile(
            onTap: onAudio,
            leading: const Icon(Icons.call_outlined),
            title: const Text('Аудиозвонок'),
          ),
          ListTile(
            onTap: onVideo,
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('Видеозвонок'),
          ),
          const Spacer(),
          const ListTile(
            leading: Icon(Icons.logout_rounded, color: TvColors.red),
            title: Text('Выйти из чата', style: TextStyle(color: TvColors.red)),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

class _ConferenceLanding extends StatefulWidget {
  const _ConferenceLanding({required this.controller, required this.onOpen});
  final AppController controller;
  final Future<void> Function(VideoCallSession) onOpen;
  @override
  State<_ConferenceLanding> createState() => _ConferenceLandingState();
}

class _ConferenceLandingState extends State<_ConferenceLanding> {
  List<ConferenceRoom> _rooms = const [];
  bool _loading = true;
  bool _creating = false;
  String? _openingId;
  String? _revokingId;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRooms());
  }

  Future<void> _loadRooms({bool showProgress = true}) async {
    if (showProgress && mounted) setState(() => _loading = true);
    try {
      final rooms = await widget.controller.conferenceRooms();
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createRoom() async {
    final options = await showDialog<_ConferenceOptions>(
      context: context,
      builder: (_) => const _CreateConferenceDialog(),
    );
    if (options == null || !mounted) return;
    setState(() => _creating = true);
    try {
      final room = await widget.controller.createConferenceRoom(
        title: options.title,
        allowGuests: options.allowGuests,
      );
      if (!mounted) return;
      setState(() => _rooms = [room, ..._rooms]);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Комната создана и сохранена на сервере'),
          action: room.inviteUrl.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Копировать ссылку',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: room.inviteUrl)),
                ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось создать комнату: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _openRoom(ConferenceRoom room) async {
    setState(() => _openingId = room.id);
    try {
      final session = await widget.controller.openConferenceRoom(room);
      if (mounted) await widget.onOpen(session);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось войти в комнату: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Future<void> _copyInvite(ConferenceRoom room) async {
    if (room.inviteUrl.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: room.inviteUrl));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ссылка приглашения скопирована')),
      );
    }
  }

  Future<void> _revokeRoom(ConferenceRoom room) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Аннулировать ссылку?'),
        content: Text(
          'Комната «${room.title}» будет закрыта для всех, а ссылка перестанет работать.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: TvColors.red),
            child: const Text('Аннулировать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revokingId = room.id);
    try {
      await widget.controller.revokeConferenceRoom(room.id);
      if (!mounted) return;
      setState(
        () => _rooms = _rooms.where((item) => item.id != room.id).toList(),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ссылка аннулирована, комната закрыта')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось аннулировать ссылку: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(TvSizes.contentPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader(title: 'Конференции', sipNumber: ''),
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Постоянные комнаты',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Создайте ссылку один раз и входите в комнату в любое время.',
                      style: TextStyle(color: TvColors.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Обновить комнаты',
                onPressed: _loading ? null : _loadRooms,
                icon: const Icon(Icons.refresh_rounded),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _creating ? null : _createRoom,
                icon: _creating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded),
                label: const Text('Новая конференция'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: _loading && _rooms.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _rooms.isEmpty
                  ? _EmptyPanel(
                      icon: Icons.cloud_off_outlined,
                      title: 'Не удалось загрузить комнаты',
                      subtitle: _error!,
                    )
                  : _rooms.isEmpty
                  ? const _EmptyPanel(
                      icon: Icons.groups_outlined,
                      title: 'Комнат пока нет',
                      subtitle: 'Нажмите «Новая конференция», чтобы создать постоянную ссылку',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _rooms.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final room = _rooms[index];
                        final opening = _openingId == room.id;
                        final revoking = _revokingId == room.id;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: TvColors.selected,
                              foregroundColor: TvColors.blue,
                              child: Icon(Icons.video_camera_front_rounded),
                            ),
                            title: Text(
                              room.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text(
                                  'Создана ${_conferenceDate(room.createdAt)}',
                                ),
                                if (room.inviteUrl.isNotEmpty)
                                  Text(
                                    room.inviteUrl,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: TvColors.blue,
                                    ),
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Копировать ссылку',
                                  onPressed: room.inviteUrl.isEmpty
                                      ? null
                                      : () => _copyInvite(room),
                                  icon: const Icon(Icons.link_rounded),
                                ),
                                const SizedBox(width: 6),
                                FilledButton.icon(
                                  onPressed: opening || revoking
                                      ? null
                                      : () => _openRoom(room),
                                  icon: opening
                                      ? const SizedBox.square(
                                          dimension: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.login_rounded),
                                  label: const Text('Войти'),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: opening || revoking
                                      ? null
                                      : () => _revokeRoom(room),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: TvColors.red,
                                    side: const BorderSide(color: TvColors.red),
                                  ),
                                  icon: revoking
                                      ? const SizedBox.square(
                                          dimension: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.link_off_rounded),
                                  label: const Text('Аннулировать'),
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

String _conferenceDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} · '
      '${two(local.hour)}:${two(local.minute)}';
}

class _ConferenceOptions {
  const _ConferenceOptions({required this.title, required this.allowGuests});
  final String title;
  final bool allowGuests;
}

class _CreateConferenceDialog extends StatefulWidget {
  const _CreateConferenceDialog();
  @override
  State<_CreateConferenceDialog> createState() =>
      _CreateConferenceDialogState();
}

class _CreateConferenceDialogState extends State<_CreateConferenceDialog> {
  final _title = TextEditingController(text: 'Новая конференция');
  bool _allowGuests = true;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Создать постоянную комнату'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'После создания комната сохранится на сервере. Конференция не запустится автоматически.',
            style: TextStyle(color: TvColors.textSecondary),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: 120,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Название комнаты'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _allowGuests,
            onChanged: (value) => setState(() => _allowGuests = value),
            secondary: const Icon(Icons.link_rounded),
            title: const Text('Разрешить гостевой вход'),
            subtitle: const Text('Гости смогут входить по сохранённой ссылке'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: _title.text.trim().length < 2
            ? null
            : () => Navigator.pop(
                context,
                _ConferenceOptions(
                  title: _title.text.trim(),
                  allowGuests: _allowGuests,
                ),
              ),
        child: const Text('Создать комнату'),
      ),
    ],
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.label, this.online = false, this.size = 48});
  final String label;
  final bool online;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: size / 2,
          backgroundColor: TvColors.selected,
          foregroundColor: TvColors.navy,
          child: Text(
            label,
            style: TextStyle(fontSize: size * .34, fontWeight: FontWeight.w700),
          ),
        ),
        if (online)
          Positioned(
            right: 0,
            bottom: 1,
            child: Container(
              width: size * .24,
              height: size * .24,
              decoration: BoxDecoration(
                color: TvColors.green,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
      ],
    ),
  );
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: IconButton(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: TvColors.panel,
        foregroundColor: TvColors.blue,
        side: const BorderSide(color: TvColors.border),
      ),
      icon: Icon(icon),
    ),
  );
}

class _ListGroupLabel extends StatelessWidget {
  const _ListGroupLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
    child: Text(
      label,
      style: const TextStyle(
        color: TvColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 58, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
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
  );
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 46, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    ),
  );
}

String _initial(String displayName, String sipNumber) {
  final value = displayName.trim().isNotEmpty ? displayName : sipNumber;
  return value.isEmpty ? '?' : value[0].toUpperCase();
}

String _messageTime(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _callDescription(CallHistoryEntry entry) {
  final time = entry.startedAt.toLocal();
  final stamp =
      '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  if (entry.result == CallResult.missed) return 'Пропущенный · $stamp';
  if (entry.result == CallResult.failed) return 'Не состоялся · $stamp';
  final duration = entry.duration;
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final direction = entry.direction == CallDirection.incoming
      ? 'Входящий'
      : 'Исходящий';
  return '$direction · $stamp · $minutes:$seconds';
}

String _compactDuration(Duration value) {
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '${value.inHours > 0 ? '${value.inHours}:' : ''}$minutes:$seconds';
}

String _relativeDate(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(local.year, local.month, local.day);
  final prefix = date == today
      ? 'Сегодня'
      : date == today.subtract(const Duration(days: 1))
      ? 'Вчера'
      : '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}';
  return '$prefix, ${_messageTime(local)}';
}
