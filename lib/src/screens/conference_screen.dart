import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

import '../controllers/app_controller.dart';
import '../models/models.dart';
import '../services/android_platform_bridge.dart';

class ConferenceScreen extends StatefulWidget {
  const ConferenceScreen({
    super.key,
    required this.controller,
    required this.session,
  });
  final AppController controller;
  final VideoCallSession session;

  @override
  State<ConferenceScreen> createState() => _ConferenceScreenState();
}

class _ConferenceScreenState extends State<ConferenceScreen> {
  late final Room _room;
  late final EventsListener<RoomEvent> _roomEvents;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  bool _connecting = true;
  bool _muted = false;
  bool _cameraOff = false;
  bool _ending = false;
  bool _historyConnected = false;
  Offset? _localPreviewOffset;
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
    _muted = !widget.session.initialMicrophone;
    _cameraOff = !widget.session.initialCamera;
    _room.addListener(_roomChanged);
    _roomEvents = _room.createListener()
      ..on<RoomDisconnectedEvent>(_roomDisconnected);
    widget.controller.addListener(_appChanged);
    _connect();
  }

  Future<void> _connect() async {
    try {
      await _room.connect(
        widget.session.url!,
        widget.session.token!,
        // WebRTC uses direct ICE candidates first. The Tvoice LiveKit server
        // advertises 185.177.2.115:443/UDP and retains TCP as a fallback.
        connectOptions: const ConnectOptions(autoSubscribe: true),
      );
      await _room.localParticipant?.setMicrophoneEnabled(!_muted);
      await _room.localParticipant?.setCameraEnabled(!_cameraOff);
      _markConnectedWhenPeerJoins();
      try {
        await AudioManager.instance.setSpeakerOutputPreferred(true);
      } catch (_) {
        // Desktop platforms use the selected system output device.
      }
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
      });
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
    _markConnectedWhenPeerJoins();
    if (mounted) setState(() {});
  }

  void _roomDisconnected(RoomDisconnectedEvent event) {
    if (_ending || !mounted) return;
    _ending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Конференция завершена на сервере')),
      );
    });
  }

  void _markConnectedWhenPeerJoins() {
    if (_historyConnected || _room.remoteParticipants.isEmpty) return;
    _historyConnected = true;
    widget.controller.markVideoConnected(widget.session.callId);
  }

  void _appChanged() {
    if (!widget.session.isConferenceRoom &&
        widget.controller.lastEndedVideoCallId == widget.session.callId &&
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
            'Вы выйдете из разговора, но комната и ссылка останутся '
            'доступными. Аннулировать комнату можно в разделе «Конференции».',
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

  Future<void> _shareInvite() async {
    final invite = widget.session.inviteUrl;
    if (invite == null || invite.isEmpty) return;
    final shared = await AndroidPlatformBridge.shareText(
      text: '${widget.session.title ?? 'Конференция Tvoice'}\n$invite',
      title: 'Приглашение в Tvoice',
    );
    if (shared || !mounted) return;
    await Clipboard.setData(ClipboardData(text: invite));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Ссылка скопирована')));
    }
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
      if (track != null) {
        final options = track.currentOptions;
        final current = options is CameraCaptureOptions
            ? options.cameraPosition
            : CameraPosition.front;
        await track.setCameraPosition(current.switched());
        break;
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestClose());
      },
      child: Scaffold(
        backgroundColor: const Color(0xff080b10),
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: _connecting
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(8, 70, 8, 104),
                        child: _buildVideoStage(),
                      ),
              ),
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: _requestClose,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.session.title ??
                                widget.session.peer.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _formatDuration(_elapsed),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.session.inviteUrl?.isNotEmpty == true)
                      IconButton.filledTonal(
                        tooltip: 'Поделиться ссылкой',
                        onPressed: _shareInvite,
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                      ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 20,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xe61a2029),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _CallButton(
                            icon: _muted
                                ? Icons.mic_off_rounded
                                : Icons.mic_rounded,
                            active: !_muted,
                            onPressed: _toggleMicrophone,
                          ),
                          _CallButton(
                            icon: _cameraOff
                                ? Icons.videocam_off_rounded
                                : Icons.videocam_rounded,
                            active: !_cameraOff,
                            onPressed: _toggleCamera,
                          ),
                          _CallButton(
                            icon: Icons.cameraswitch_rounded,
                            active: true,
                            onPressed: _flipCamera,
                            emphasized: true,
                          ),
                          const SizedBox(width: 4),
                          IconButton.filled(
                            onPressed: _requestClose,
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xffee344e),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.all(16),
                            ),
                            icon: const Icon(Icons.call_end_rounded, size: 27),
                          ),
                        ],
                      ),
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

  Widget _buildVideoStage() {
    final local = _room.localParticipant;
    final remotes = _room.remoteParticipants.values.toList();
    final participants = <Participant>[...remotes, ?local];

    if (widget.session.isConferenceRoom || participants.length >= 3) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final count = participants.length;
          if (count == 0) {
            return _WaitingForParticipant(peer: widget.session.peer);
          }
          final aspect = constraints.maxWidth / constraints.maxHeight;
          final columns = math.sqrt(count * aspect).ceil().clamp(1, count);
          final rowCount = (count / columns).ceil();
          final baseRowSize = count ~/ rowCount;
          final widerRows = count % rowCount;
          final rowSizes = [
            for (var row = 0; row < rowCount; row++)
              baseRowSize + (row < widerRows ? 1 : 0),
          ];
          final maxColumns = rowSizes.reduce(math.max);
          final rowStarts = <int>[];
          var offset = 0;
          for (final size in rowSizes) {
            rowStarts.add(offset);
            offset += size;
          }
          return Column(
            children: [
              for (var row = 0; row < rowSizes.length; row++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: row == rowSizes.length - 1 ? 0 : 3.5,
                    ),
                    child: FractionallySizedBox(
                      widthFactor: rowSizes[row] / maxColumns,
                      child: Row(
                        children: [
                          for (var column = 0; column < rowSizes[row]; column++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  right: column == rowSizes[row] - 1 ? 0 : 3.5,
                                ),
                                child: _ParticipantTile(
                                  participant:
                                      participants[rowStarts[row] + column],
                                  local:
                                      participants[rowStarts[row] + column] ==
                                      local,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final previewSide = (constraints.maxWidth * .29).clamp(104.0, 148.0);
        final maxX = (constraints.maxWidth - previewSide - 10).clamp(
          10.0,
          double.infinity,
        );
        final maxY = (constraints.maxHeight - previewSide - 10).clamp(
          10.0,
          double.infinity,
        );
        final requested =
            _localPreviewOffset ?? Offset(maxX.toDouble(), maxY.toDouble());
        final offset = Offset(
          requested.dx.clamp(10.0, maxX.toDouble()),
          requested.dy.clamp(10.0, maxY.toDouble()),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: remotes.isNotEmpty
                  ? _ParticipantTile(
                      participant: remotes.first,
                      local: false,
                      fit: VideoViewFit.contain,
                    )
                  : _WaitingForParticipant(peer: widget.session.peer),
            ),
            if (local != null)
              Positioned(
                left: offset.dx,
                top: offset.dy,
                width: previewSide.toDouble(),
                height: previewSide.toDouble(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) {
                    setState(() {
                      _localPreviewOffset = Offset(
                        (offset.dx + details.delta.dx).clamp(
                          10.0,
                          maxX.toDouble(),
                        ),
                        (offset.dy + details.delta.dy).clamp(
                          10.0,
                          maxY.toDouble(),
                        ),
                      );
                    });
                  },
                  child: _ParticipantTile(participant: local, local: true),
                ),
              ),
          ],
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }
}

class _WaitingForParticipant extends StatelessWidget {
  const _WaitingForParticipant({required this.peer});
  final TvoiceUser peer;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xff202733),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white12),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 46,
            backgroundColor: const Color(0xff313b4b),
            child: Text(
              peer.displayName.isEmpty
                  ? '?'
                  : peer.displayName[0].toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            peer.displayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Ожидание подключения…',
            style: TextStyle(color: Colors.white60),
          ),
        ],
      ),
    ),
  );
}

class _ParticipantTile extends StatefulWidget {
  const _ParticipantTile({
    required this.participant,
    required this.local,
    this.fit = VideoViewFit.cover,
  });
  final Participant participant;
  final bool local;
  final VideoViewFit fit;
  @override
  State<_ParticipantTile> createState() => _ParticipantTileState();
}

class _ParticipantTileState extends State<_ParticipantTile> {
  @override
  void initState() {
    super.initState();
    widget.participant.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _ParticipantTile oldWidget) {
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
    final speaking = widget.participant.isSpeaking;
    final color = speaking ? const Color(0xff24e6a5) : Colors.white12;
    final name = widget.participant.name.isNotEmpty
        ? widget.participant.name
        : widget.participant.identity;
    final track = _track;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xff202733),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color, width: speaking ? 2.5 : 1),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            VideoTrackRenderer(
              track,
              fit: widget.fit,
              mirrorMode: widget.local
                  ? VideoViewMirrorMode.mirror
                  : VideoViewMirrorMode.off,
            )
          else
            Center(
              child: CircleAvatar(
                radius: 38,
                backgroundColor: const Color(0xff313b4b),
                child: Text(
                  name.isEmpty ? '?' : name[0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 7,
            right: 7,
            bottom: 7,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color: speaking
                    ? const Color(0xff24e6a5)
                    : const Color(0xaa11151c),
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              child: Row(
                children: [
                  if (speaking) ...[
                    const Icon(
                      Icons.graphic_eq_rounded,
                      size: 15,
                      color: Color(0xff06150f),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      widget.local ? '$name · Вы' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: speaking
                            ? const Color(0xff06150f)
                            : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.active,
    required this.onPressed,
    this.emphasized = false,
  });
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;
  final bool emphasized;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: IconButton.filledTonal(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: emphasized
            ? const Color(0xff087dff)
            : active
            ? const Color(0xff313b48)
            : Colors.white,
        foregroundColor: active ? Colors.white : const Color(0xff11151c),
        padding: const EdgeInsets.all(14),
      ),
      icon: Icon(icon, size: 25),
    ),
  );
}
