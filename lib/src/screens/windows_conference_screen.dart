// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;

import '../controllers/app_controller.dart';
import '../models/models.dart';
import '../theme/desktop_design.dart';
import '../widgets/tvoice_logo.dart';
import '../services/desktop_window_controller.dart';

/// Windows-only call surface. The Android client keeps its compact call UI.
class WindowsConferenceScreen extends StatefulWidget {
  const WindowsConferenceScreen({
    super.key,
    required this.controller,
    required this.session,
  });

  final AppController controller;
  final VideoCallSession session;

  @override
  State<WindowsConferenceScreen> createState() =>
      _WindowsConferenceScreenState();
}

class _WindowsConferenceScreenState extends State<WindowsConferenceScreen> {
  late final Room _room;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  bool _connecting = true;
  bool _muted = false;
  bool _cameraOff = false;
  bool _ending = false;
  bool _historyConnected = false;
  bool _showRightPanel = false;
  bool _showChat = false;
  bool _sharingScreen = false;
  int _unreadRoomMessages = 0;
  bool _fullscreen = false;
  bool _speakerMode = false;
  String? _pinnedIdentity;
  final List<_RoomMessage> _roomMessages = [];
  late final EventsListener<RoomEvent> _roomEvents;
  Offset? _previewOffset;
  String? _error;

  @override
  void initState() {
    super.initState();
    _room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: CameraPosition.front,
          params: VideoParametersPresets.h1080_169,
          maxFrameRate: 30,
        ),
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: true,
          videoEncoding: VideoEncoding(maxBitrate: 3000000, maxFramerate: 30),
          videoSimulcastLayers: [
            VideoParametersPresets.h360_169,
            VideoParametersPresets.h720_169,
          ],
        ),
      ),
    );
    _room.addListener(_roomChanged);
    _roomEvents = _room.createListener()..on<DataReceivedEvent>(_onRoomData);
    widget.controller.addListener(_appChanged);
    _connect();
  }

  Future<void> _connect() async {
    try {
      await _room.connect(
        widget.session.url!,
        widget.session.token!,
        connectOptions: const ConnectOptions(autoSubscribe: true),
      );
      await _room.localParticipant?.setMicrophoneEnabled(
        widget.session.initialMicrophone,
      );
      await _room.localParticipant?.setCameraEnabled(
        widget.session.initialCamera,
      );
      _muted = !widget.session.initialMicrophone;
      _cameraOff = !widget.session.initialCamera;
      try {
        await AudioManager.instance.setSpeakerOutputPreferred(true);
      } catch (_) {
        // Windows uses the selected system audio device.
      }
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
      });
      _markConnected();
      if (mounted) setState(() => _connecting = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = 'Не удалось подключить видео: $error';
        });
      }
    }
  }

  void _roomChanged() {
    _markConnected();
    if (mounted) setState(() {});
  }

  void _markConnected() {
    if (_historyConnected || _room.remoteParticipants.isEmpty) return;
    _historyConnected = true;
    widget.controller.markVideoConnected(widget.session.callId);
  }

  void _onRoomData(DataReceivedEvent event) {
    if (event.topic != 'tvoice.room.chat') return;
    try {
      final data = jsonDecode(utf8.decode(event.data)) as Map<String, dynamic>;
      final text = data['text']?.toString().trim() ?? '';
      if (text.isEmpty) return;
      setState(() {
        _roomMessages.add(
          _RoomMessage(
            sender: event.participant?.name.isNotEmpty == true
                ? event.participant!.name
                : event.participant?.identity ?? 'Участник',
            text: text,
            mine: false,
          ),
        );
        if (!_showChat) _unreadRoomMessages++;
      });
    } catch (_) {
      // Ignore malformed packets from older clients.
    }
  }

  Future<void> _sendRoomMessage(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    await _room.localParticipant?.publishData(
      utf8.encode(
        jsonEncode({
          'text': value,
          'sentAt': DateTime.now().toUtc().toIso8601String(),
        }),
      ),
      reliable: true,
      topic: 'tvoice.room.chat',
    );
    if (mounted) {
      setState(
        () => _roomMessages.add(
          _RoomMessage(sender: 'Вы', text: value, mine: true),
        ),
      );
    }
  }

  void _appChanged() {
    if (widget.controller.lastEndedVideoCallId == widget.session.callId &&
        !_ending) {
      _ending = true;
      _close(notifyPeer: false);
    }
  }

  Future<void> _close({bool notifyPeer = true}) async {
    if (notifyPeer) {
      try {
        if (!widget.session.isConferenceRoom) {
          await widget.controller.endVideoCall(widget.session.callId);
        }
      } catch (_) {}
    }
    await _room.disconnect();
    if (_fullscreen) await DesktopWindowController.setFullscreen(false);
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(false);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _requestClose() async {
    if (_ending) return;
    if (widget.session.isConferenceRoom) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Покинуть конференцию?'),
          content: const Text(
            'Вы выйдете из разговора, но комната и ссылка останутся доступными. '
            'Аннулировать ссылку можно в разделе «Конференции».',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Выйти'),
            ),
          ],
        ),
      );
      if (leave != true) return;
    }
    _ending = true;
    await _close(notifyPeer: !widget.session.isConferenceRoom);
  }

  Future<void> _toggleMicrophone() async {
    _muted = !_muted;
    await _room.localParticipant?.setMicrophoneEnabled(!_muted);
    if (mounted) setState(() {});
  }

  Future<void> _toggleCamera() async {
    _cameraOff = !_cameraOff;
    await _room.localParticipant?.setCameraEnabled(!_cameraOff);
    if (mounted) setState(() {});
  }

  Future<void> _flipCamera() async {
    final participant = _room.localParticipant;
    if (participant == null) return;
    for (final publication in participant.videoTrackPublications) {
      final track = publication.track;
      if (track == null) continue;
      final options = track.currentOptions;
      final current = options is CameraCaptureOptions
          ? options.cameraPosition
          : CameraPosition.front;
      await track.setCameraPosition(current.switched());
      return;
    }
  }

  Future<void> _toggleScreenShare() async {
    final participant = _room.localParticipant;
    if (participant == null) return;
    try {
      if (_sharingScreen) {
        await participant.setScreenShareEnabled(false);
      } else {
        final sourceId = await ScreenSelectDialog.show(
          context,
          titleText: 'Выберите экран или окно',
          screenTabText: 'Весь экран',
          windowTabText: 'Окно',
          cancelText: 'Отмена',
          shareText: 'Демонстрировать',
        );
        if (sourceId == null) return;
        await participant.setScreenShareEnabled(
          true,
          screenShareCaptureOptions: ScreenShareCaptureOptions(
            sourceId: sourceId,
            maxFrameRate: 15,
            params: VideoParametersPresets.screenShareH1080FPS15,
          ),
        );
      }
      if (mounted) setState(() => _sharingScreen = !_sharingScreen);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось запустить демонстрацию: $error')),
        );
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_appChanged);
    _room.removeListener(_roomChanged);
    unawaited(_roomEvents.dispose());
    unawaited(_room.dispose().then((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final participantCount = _room.remoteParticipants.length + 1;
    final conference = widget.session.isConferenceRoom || participantCount > 2;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_ending) {
          _requestClose();
        }
      },
      child: Scaffold(
        backgroundColor: TvColors.appBackground,
        body: Row(
          children: [
            const _CallSidebar(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _connecting
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                        ? _CallError(message: _error!)
                        : Padding(
                            padding: EdgeInsets.fromLTRB(
                              conference ? 20 : 0,
                              conference ? 92 : 0,
                              conference ? 20 : 0,
                              conference ? 108 : 0,
                            ),
                            child: _buildStage(conference),
                          ),
                  ),
                  Positioned(
                    top: 18,
                    left: 22,
                    right: 22,
                    child: _CallTopBar(
                      peer: widget.session.peer,
                      elapsed: _elapsed,
                      conference: conference,
                      participantCount: participantCount,
                      onBack: () {
                        _requestClose();
                      },
                    ),
                  ),
                  Positioned(
                    bottom: 26,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _CallControlBar(
                        muted: _muted,
                        cameraOff: _cameraOff,
                        rightPanelVisible: _showRightPanel,
                        onMicrophone: _toggleMicrophone,
                        onCamera: _toggleCamera,
                        onFlipCamera: _flipCamera,
                        sharingScreen: _sharingScreen,
                        unreadMessages: _unreadRoomMessages,
                        onShare: _toggleScreenShare,
                        onParticipants: () => setState(() {
                          _showRightPanel = !_showRightPanel;
                          _showChat = false;
                        }),
                        onChat: () => setState(() {
                          _showRightPanel = true;
                          _showChat = true;
                          _unreadRoomMessages = 0;
                        }),
                        onMore: _showConferenceMenu,
                        endLabel: conference ? 'Выйти' : 'Завершить',
                        onEnd: () {
                          _requestClose();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_showRightPanel)
              SizedBox(
                width: conference ? 340 : 286,
                child: _showChat
                    ? _RoomChatPanel(
                        messages: _roomMessages,
                        onSend: _sendRoomMessage,
                      )
                    : _ParticipantsPanel(room: _room),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showConferenceMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              ),
              title: Text(
                _fullscreen
                    ? 'Выйти из полноэкранного режима'
                    : 'На весь экран',
              ),
              onTap: () => Navigator.pop(context, 'fullscreen'),
            ),
            ListTile(
              leading: Icon(
                _speakerMode
                    ? Icons.grid_view_rounded
                    : Icons.record_voice_over_rounded,
              ),
              title: Text(_speakerMode ? 'Режим сетки' : 'Активный спикер'),
              onTap: () => Navigator.pop(context, 'speaker'),
            ),
            if (widget.session.inviteUrl?.isNotEmpty == true)
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('Копировать приглашение'),
                onTap: () => Navigator.pop(context, 'invite'),
              ),
            ListTile(
              leading: const Icon(Icons.settings_input_component_rounded),
              title: const Text('Камера и микрофон'),
              onTap: () => Navigator.pop(context, 'devices'),
            ),
          ],
        ),
      ),
    );
    if (action == 'fullscreen') {
      _fullscreen = !_fullscreen;
      await DesktopWindowController.setFullscreen(_fullscreen);
      if (mounted) setState(() {});
    } else if (action == 'speaker') {
      setState(() {
        _speakerMode = !_speakerMode;
        if (!_speakerMode) _pinnedIdentity = null;
      });
    } else if (action == 'invite') {
      await Clipboard.setData(ClipboardData(text: widget.session.inviteUrl!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ссылка приглашения скопирована')),
        );
      }
    } else if (action == 'devices') {
      await _showDevicePicker();
    }
  }

  Future<void> _showDevicePicker() async {
    final audioInputs = await Hardware.instance.audioInputs();
    final videoInputs = await Hardware.instance.videoInputs();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Камера и микрофон'),
        children: [
          const ListTile(title: Text('Микрофоны')),
          for (final device in audioInputs)
            ListTile(
              leading: const Icon(Icons.mic_outlined),
              title: Text(device.label.isEmpty ? 'Микрофон' : device.label),
              onTap: () async {
                await _room.setAudioInputDevice(device);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          const Divider(),
          const ListTile(title: Text('Камеры')),
          for (final device in videoInputs)
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: Text(device.label.isEmpty ? 'Камера' : device.label),
              onTap: () async {
                await _room.setVideoInputDevice(device);
                if (context.mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildStage(bool conference) {
    final local = _room.localParticipant;
    final remotes = _room.remoteParticipants.values.toList(growable: false);
    if (conference) {
      final participants = <Participant>[...remotes, ?local];
      final sharing = participants
          .where((p) => _screenTrack(p) != null)
          .toList();
      if (sharing.isNotEmpty) {
        final presenter = sharing.first;
        final track = _screenTrack(presenter)!;
        return Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: const Color(0xff111827),
                  child: VideoTrackRenderer(track, fit: VideoViewFit.contain),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 118,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: participants.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, index) => SizedBox(
                  width: 190,
                  child: _DesktopParticipantTile(
                    participant: participants[index],
                    local: participants[index] == local,
                  ),
                ),
              ),
            ),
          ],
        );
      }
      Participant? focused;
      if (_pinnedIdentity != null) {
        for (final participant in participants) {
          if (participant.identity == _pinnedIdentity) focused = participant;
        }
      } else if (_speakerMode) {
        for (final participant in participants) {
          if (participant.isSpeaking) {
            focused = participant;
            break;
          }
        }
        focused ??= remotes.isNotEmpty ? remotes.first : local;
      }
      if (focused != null) {
        final strip = participants.where((item) => item != focused).toList();
        return Column(
          children: [
            Expanded(
              child: _DesktopParticipantTile(
                participant: focused,
                local: focused == local,
                onTap: () => setState(() => _pinnedIdentity = null),
              ),
            ),
            if (strip.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 118,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: strip.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, index) => SizedBox(
                    width: 190,
                    child: _DesktopParticipantTile(
                      participant: strip[index],
                      local: strip[index] == local,
                      onTap: () => setState(
                        () => _pinnedIdentity = strip[index].identity,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      }
      final count = participants.length.clamp(1, 16);
      final rowSizes = switch (count) {
        1 => [1],
        2 => [1, 1],
        3 => [1, 2],
        4 => [2, 2],
        5 => [3, 2],
        6 => [3, 3],
        7 => [3, 2, 2],
        8 => [3, 3, 2],
        9 => [3, 3, 3],
        10 => [4, 3, 3],
        11 => [4, 4, 3],
        12 => [4, 4, 4],
        13 => [4, 3, 3, 3],
        14 => [4, 4, 3, 3],
        15 => [4, 4, 4, 3],
        _ => [4, 4, 4, 4],
      };
      final maxColumns = rowSizes.reduce((a, b) => a > b ? a : b);
      return Column(
        children: [
          for (var row = 0; row < rowSizes.length; row++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: row == rowSizes.length - 1 ? 0 : 4,
                ),
                child: FractionallySizedBox(
                  widthFactor: rowSizes[row] / maxColumns,
                  child: Builder(
                    builder: (context) {
                      final start = rowSizes
                          .take(row)
                          .fold<int>(0, (sum, value) => sum + value);
                      return Row(
                        children: [
                          for (var column = 0; column < rowSizes[row]; column++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  right: column == rowSizes[row] - 1 ? 0 : 4,
                                ),
                                child: _DesktopParticipantTile(
                                  participant: participants[start + column],
                                  local: participants[start + column] == local,
                                  onTap: () => setState(() {
                                    _pinnedIdentity =
                                        participants[start + column].identity;
                                    _speakerMode = true;
                                  }),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth * .25).clamp(180.0, 300.0);
        final height = width * 9 / 16;
        final maxX = (constraints.maxWidth - width - 20).clamp(
          20.0,
          double.infinity,
        );
        final maxY = (constraints.maxHeight - height - 120).clamp(
          76.0,
          double.infinity,
        );
        final desired = _previewOffset ?? Offset(maxX.toDouble(), 76);
        final offset = Offset(
          desired.dx.clamp(20.0, maxX.toDouble()),
          desired.dy.clamp(76.0, maxY.toDouble()),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            if (remotes.isNotEmpty)
              _DesktopParticipantTile(
                participant: remotes.first,
                local: false,
                borderRadius: BorderRadius.zero,
              )
            else
              _WaitingForPeer(peer: widget.session.peer),
            if (local != null)
              Positioned(
                left: offset.dx,
                top: offset.dy,
                width: width.toDouble(),
                height: height.toDouble(),
                child: GestureDetector(
                  onPanUpdate: (details) => setState(() {
                    _previewOffset = Offset(
                      (offset.dx + details.delta.dx).clamp(
                        20.0,
                        maxX.toDouble(),
                      ),
                      (offset.dy + details.delta.dy).clamp(
                        76.0,
                        maxY.toDouble(),
                      ),
                    );
                  }),
                  child: _DesktopParticipantTile(
                    participant: local,
                    local: true,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  VideoTrack? _screenTrack(Participant participant) {
    for (final publication in participant.videoTrackPublications) {
      if (publication.source == TrackSource.screenShareVideo &&
          publication.track is VideoTrack &&
          !publication.muted) {
        return publication.track as VideoTrack;
      }
    }
    return null;
  }
}

class _CallSidebar extends StatelessWidget {
  const _CallSidebar();

  @override
  Widget build(BuildContext context) => Container(
    width: TvSizes.sidebar,
    decoration: const BoxDecoration(
      color: TvColors.panel,
      border: Border(right: BorderSide(color: TvColors.border)),
    ),
    child: const Column(
      children: [
        SizedBox(height: 20),
        TvoiceLogo(size: 40, showWordmark: false),
        Spacer(),
        SizedBox(height: 28),
      ],
    ),
  );
}

class _CallTopBar extends StatelessWidget {
  const _CallTopBar({
    required this.peer,
    required this.elapsed,
    required this.conference,
    required this.participantCount,
    required this.onBack,
  });

  final TvoiceUser peer;
  final Duration elapsed;
  final bool conference;
  final int participantCount;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _OverlayButton(icon: Icons.arrow_back_rounded, onPressed: onBack),
      const SizedBox(width: 12),
      CircleAvatar(
        radius: 21,
        backgroundColor: TvColors.panel,
        child: Text(_initial(peer.displayName, peer.sipNumber)),
      ),
      const SizedBox(width: 10),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            conference ? 'Видеоконференция' : peer.displayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(blurRadius: 8, color: Colors.black45)],
            ),
          ),
          Text(
            conference
                ? '$participantCount участников · ${_duration(elapsed)}'
                : '${peer.sipNumber} · ${_duration(elapsed)} · Защищённое соединение',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
            ),
          ),
        ],
      ),
    ],
  );
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: const Color(0x660b1524),
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white38),
    ),
    icon: Icon(icon),
  );
}

class _CallControlBar extends StatelessWidget {
  const _CallControlBar({
    required this.muted,
    required this.cameraOff,
    required this.rightPanelVisible,
    required this.sharingScreen,
    required this.unreadMessages,
    required this.onMicrophone,
    required this.onCamera,
    required this.onFlipCamera,
    required this.onShare,
    required this.onParticipants,
    required this.onChat,
    required this.onMore,
    required this.endLabel,
    required this.onEnd,
  });
  final bool muted;
  final bool cameraOff;
  final bool rightPanelVisible;
  final bool sharingScreen;
  final int unreadMessages;
  final VoidCallback onMicrophone;
  final VoidCallback onCamera;
  final VoidCallback onFlipCamera;
  final VoidCallback onShare;
  final VoidCallback onParticipants;
  final VoidCallback onChat;
  final VoidCallback onMore;
  final String endLabel;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: TvColors.lightOverlay,
      borderRadius: BorderRadius.circular(TvSizes.floatingRadius),
      border: Border.all(color: Colors.white),
      boxShadow: const [TvShadows.floating],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Control(
          icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: 'Микрофон',
          active: !muted,
          onPressed: onMicrophone,
        ),
        _Control(
          icon: cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
          label: 'Камера',
          active: !cameraOff,
          onPressed: onCamera,
        ),
        _Control(
          icon: Icons.cameraswitch_rounded,
          label: 'Камера',
          active: true,
          onPressed: onFlipCamera,
        ),
        _Control(
          icon: sharingScreen
              ? Icons.stop_screen_share_rounded
              : Icons.screen_share_outlined,
          label: 'Демонстрация',
          active: sharingScreen,
          onPressed: onShare,
        ),
        _Control(
          icon: Icons.groups_rounded,
          label: 'Участники',
          active: rightPanelVisible,
          onPressed: onParticipants,
        ),
        Badge(
          isLabelVisible: unreadMessages > 0,
          label: Text('$unreadMessages'),
          child: _Control(
            icon: Icons.chat_outlined,
            label: 'Чат',
            active: false,
            onPressed: onChat,
          ),
        ),
        _Control(
          icon: Icons.more_horiz_rounded,
          label: 'Ещё',
          active: false,
          onPressed: onMore,
        ),
        const SizedBox(width: 8),
        _Control(
          icon: Icons.call_end_rounded,
          label: endLabel,
          active: true,
          danger: true,
          onPressed: onEnd,
        ),
      ],
    ),
  );
}

class _Control extends StatelessWidget {
  const _Control({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
    this.danger = false,
  });
  final IconData icon;
  final String label;
  final bool active;
  final bool danger;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: danger ? 88 : 78,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          onPressed: onPressed,
          style: IconButton.styleFrom(
            backgroundColor: danger
                ? TvColors.red
                : active
                ? TvColors.blue
                : TvColors.panel,
            foregroundColor: danger || active ? Colors.white : TvColors.navy,
            side: danger || active
                ? BorderSide.none
                : const BorderSide(color: TvColors.border),
          ),
          icon: Icon(icon),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: 10,
            color: danger ? TvColors.red : TvColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _DesktopParticipantTile extends StatefulWidget {
  const _DesktopParticipantTile({
    required this.participant,
    required this.local,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    this.onTap,
  });
  final Participant participant;
  final bool local;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;
  @override
  State<_DesktopParticipantTile> createState() =>
      _DesktopParticipantTileState();
}

class _DesktopParticipantTileState extends State<_DesktopParticipantTile> {
  @override
  void initState() {
    super.initState();
    widget.participant.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _DesktopParticipantTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      oldWidget.participant.removeListener(_changed);
      widget.participant.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.participant.removeListener(_changed);
    super.dispose();
  }

  VideoTrack? get _track {
    for (final publication in widget.participant.videoTrackPublications) {
      if (publication.source == TrackSource.camera &&
          publication.track is VideoTrack &&
          !publication.muted) {
        return publication.track as VideoTrack;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.participant.name.isNotEmpty
        ? widget.participant.name
        : widget.participant.identity;
    final speaking = widget.participant.isSpeaking;
    final track = _track;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xff273243),
        borderRadius: widget.borderRadius,
        border: Border.all(
          color: speaking ? TvColors.blue : Colors.white24,
          width: speaking ? 3 : 1,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            VideoTrackRenderer(
              track,
              fit: VideoViewFit.cover,
              mirrorMode: widget.local
                  ? VideoViewMirrorMode.mirror
                  : VideoViewMirrorMode.off,
            )
          else
            Center(
              child: CircleAvatar(
                radius: 42,
                backgroundColor: TvColors.navy,
                foregroundColor: Colors.white,
                child: Text(
                  _initial(name, widget.participant.identity),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: speaking ? TvColors.blue : const Color(0xaa0b1524),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                widget.local ? '${name.isEmpty ? 'Вы' : name} · Вы' : name,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (widget.onTap != null)
            Positioned.fill(
              child: Tooltip(
                message: 'Закрепить участника',
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: widget.onTap,
                ),
              ),
            ),
          Positioned(
            right: 10,
            bottom: 10,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: const Color(0xaa0b1524),
                  child: Icon(
                    widget.participant.isMicrophoneEnabled()
                        ? Icons.mic_rounded
                        : Icons.mic_off_rounded,
                    size: 18,
                    color: widget.participant.isMicrophoneEnabled()
                        ? TvColors.green
                        : TvColors.red,
                  ),
                ),
                const SizedBox(width: 6),
                CircleAvatar(
                  radius: 17,
                  backgroundColor: const Color(0xaa0b1524),
                  child: Icon(
                    track == null
                        ? Icons.videocam_off_rounded
                        : Icons.videocam_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantsPanel extends StatefulWidget {
  const _ParticipantsPanel({required this.room});
  final Room room;

  @override
  State<_ParticipantsPanel> createState() => _ParticipantsPanelState();
}

class _ParticipantsPanelState extends State<_ParticipantsPanel> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final participants =
        <Participant>[
          ?widget.room.localParticipant,
          ...widget.room.remoteParticipants.values,
        ].where((participant) {
          final query = _query.trim().toLowerCase();
          return query.isEmpty ||
              participant.name.toLowerCase().contains(query) ||
              participant.identity.toLowerCase().contains(query);
        }).toList();
    return Container(
      decoration: const BoxDecoration(
        color: TvColors.panel,
        border: Border(left: BorderSide(color: TvColors.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Участники (${participants.length})',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                const Icon(
                  Icons.people_alt_outlined,
                  color: TvColors.iconMuted,
                ),
              ],
            ),
          ),
          const Divider(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Поиск',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              itemCount: participants.length,
              itemBuilder: (context, index) {
                final participant = participants[index];
                final local = participant == widget.room.localParticipant;
                final name = participant.name.isNotEmpty
                    ? participant.name
                    : participant.identity;
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(_initial(name, participant.identity)),
                  ),
                  title: Text(
                    local ? 'Вы' : name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    participant.isSpeaking ? 'Говорит' : 'Онлайн',
                    style: const TextStyle(color: TvColors.green, fontSize: 12),
                  ),
                  trailing: Icon(
                    participant.isMicrophoneEnabled()
                        ? Icons.mic_rounded
                        : Icons.mic_off_rounded,
                    color: participant.isMicrophoneEnabled()
                        ? TvColors.green
                        : TvColors.red,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CallChatPanel extends StatefulWidget {
  const _CallChatPanel({required this.controller, required this.peer});
  final AppController controller;
  final TvoiceUser peer;
  @override
  State<_CallChatPanel> createState() => _CallChatPanelState();
}

class _CallChatPanelState extends State<_CallChatPanel> {
  final _text = TextEditingController();
  Conversation? _conversation;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.controller.openDirect(widget.peer);
      await widget.controller.loadMessages(value.id);
      _conversation = value;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _conversation == null) return;
    _text.clear();
    await widget.controller.sendMessage(_conversation!.id, text);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _conversation == null
        ? const <ChatMessage>[]
        : widget.controller.messages[_conversation!.id] ??
              const <ChatMessage>[];
    return Container(
      decoration: const BoxDecoration(
        color: TvColors.panel,
        border: Border(left: BorderSide(color: TvColors.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 24),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Чат звонка',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const Divider(height: 30),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final mine = message.sentBy(
                        widget.controller.user?.id ?? '',
                      );
                      return Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: mine ? TvColors.blue : TvColors.subtle,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            message.body,
                            style: TextStyle(
                              color: mine ? Colors.white : TvColors.textPrimary,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Сообщение...',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _send,
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

class _RoomMessage {
  const _RoomMessage({
    required this.sender,
    required this.text,
    required this.mine,
  });
  final String sender;
  final String text;
  final bool mine;
}

class _RoomChatPanel extends StatefulWidget {
  const _RoomChatPanel({required this.messages, required this.onSend});
  final List<_RoomMessage> messages;
  final Future<void> Function(String) onSend;

  @override
  State<_RoomChatPanel> createState() => _RoomChatPanelState();
}

class _RoomChatPanelState extends State<_RoomChatPanel> {
  final _text = TextEditingController();
  bool _sending = false;

  Future<void> _send() async {
    final value = _text.text.trim();
    if (value.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(value);
      _text.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: TvColors.panel,
      border: Border(left: BorderSide(color: TvColors.border)),
    ),
    child: Column(
      children: [
        const SizedBox(height: 24),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Чат комнаты',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const Divider(height: 30),
        Expanded(
          child: widget.messages.isEmpty
              ? const Center(child: Text('Сообщений пока нет'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: widget.messages.length,
                  itemBuilder: (context, index) {
                    final message = widget.messages[index];
                    return Align(
                      alignment: message.mine
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: message.mine ? TvColors.blue : TvColors.subtle,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!message.mine)
                              Text(
                                message.sender,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            Text(
                              message.text,
                              style: TextStyle(
                                color: message.mine
                                    ? Colors.white
                                    : TvColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Сообщение...',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
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

class _WaitingForPeer extends StatelessWidget {
  const _WaitingForPeer({required this.peer});
  final TvoiceUser peer;
  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xff536174),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 54,
            backgroundColor: TvColors.navy,
            foregroundColor: Colors.white,
            child: Text(
              _initial(peer.displayName, peer.sipNumber),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            peer.displayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Ожидание подключения…',
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ),
  );
}

class _CallError extends StatelessWidget {
  const _CallError({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(30),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: TvColors.red),
      ),
    ),
  );
}

String _duration(Duration value) {
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return value.inHours > 0
      ? '${value.inHours}:$minutes:$seconds'
      : '$minutes:$seconds';
}

String _initial(String name, String fallback) {
  final value = name.trim().isEmpty ? fallback.trim() : name.trim();
  return value.isEmpty ? '?' : value.characters.first.toUpperCase();
}
