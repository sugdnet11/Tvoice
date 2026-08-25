import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../controllers/app_controller.dart';
import '../models/models.dart';
import 'android_audio_call_screen.dart';
import 'android_home_shell.dart';
import 'conference_screen.dart';

class AndroidConversationScreen extends StatefulWidget {
  const AndroidConversationScreen({
    super.key,
    required this.controller,
    required this.conversation,
  });
  final AppController controller;
  final Conversation conversation;
  @override
  State<AndroidConversationScreen> createState() =>
      _AndroidConversationScreenState();
}

class _AndroidConversationScreenState extends State<AndroidConversationScreen> {
  final text = TextEditingController();
  final scroll = ScrollController();
  bool sending = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
    widget.controller.loadMessages(widget.conversation.id).then((_) => down());
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void down() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) {
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  });
  Future<void> send() async {
    if (sending || text.text.trim().isEmpty) return;
    final value = text.text;
    text.clear();
    setState(() => sending = true);
    try {
      await widget.controller.sendMessage(widget.conversation.id, value);
      down();
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> audio() async {
    if (await widget.controller.startAudioCall(
          widget.conversation.peer.sipNumber,
        ) &&
        mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => AndroidAudioCallScreen(controller: widget.controller),
        ),
      );
    }
  }

  Future<void> video() async {
    try {
      final session = await widget.controller.startVideoCall(
        widget.conversation.peer,
      );
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ConferenceScreen(
              controller: widget.controller,
              session: session,
            ),
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
    final p = AndroidPalette.of(context);
    final messages =
        widget.controller.messages[widget.conversation.id] ??
        const <ChatMessage>[];
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xff0f172a)
          : const Color(0xfff3f7fd),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 55,
              color: p.surface,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    color: AndroidPalette.blue,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: AndroidPalette.blue,
                    child: Text(
                      _avatar(widget.conversation.peer.sipNumber),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.conversation.peer.displayName,
                          maxLines: 1,
                          style: TextStyle(
                            color: p.primary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Text(
                          'Онлайн',
                          style: TextStyle(
                            color: AndroidPalette.green,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: audio,
                    color: AndroidPalette.blue,
                    icon: const Icon(Icons.call_rounded),
                  ),
                  IconButton(
                    onPressed: video,
                    color: AndroidPalette.blue,
                    icon: const Icon(Icons.videocam_rounded),
                  ),
                  IconButton(
                    onPressed: () {},
                    color: AndroidPalette.blue,
                    icon: const Icon(Icons.more_vert_rounded),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.line),
            Expanded(
              child: messages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        final mine = message.sentBy(widget.controller.user!.id);
                        return Align(
                          alignment: mine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 310),
                            margin: const EdgeInsets.only(bottom: 7),
                            padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
                            decoration: BoxDecoration(
                              color: mine ? AndroidPalette.blue : p.surface,
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(14),
                                topRight: const Radius.circular(14),
                                bottomLeft: Radius.circular(mine ? 14 : 4),
                                bottomRight: Radius.circular(mine ? 4 : 14),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: Text(
                                    message.body,
                                    style: TextStyle(
                                      color: mine ? Colors.white : p.primary,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  DateFormat('HH:mm')
                                      .format(message.createdAt.toLocal()),
                                  style: TextStyle(
                                    color: mine ? Colors.white70 : p.secondary,
                                    fontSize: 10,
                                  ),
                                ),
                                if (mine) ...[
                                  const SizedBox(width: 3),
                                  _Status(status: message.status),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              color: p.surface,
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: SafeArea(
                top: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: () {},
                      color: AndroidPalette.blue,
                      icon: const Icon(Icons.add_rounded),
                    ),
                    Expanded(
                      child: TextField(
                        controller: text,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        onSubmitted: (_) => send(),
                        decoration: InputDecoration(
                          hintText: 'Сообщение...',
                          filled: true,
                          fillColor: p.search,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () {},
                      color: AndroidPalette.blue,
                      icon: const Icon(Icons.emoji_emotions_outlined),
                    ),
                    IconButton(
                      onPressed: sending ? null : send,
                      style: IconButton.styleFrom(
                        backgroundColor: AndroidPalette.blue,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.send_rounded),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _avatar(String value) =>
      value.length >= 2 ? value.substring(0, 2) : value;
}

class _Status extends StatelessWidget {
  const _Status({required this.status});
  final MessageStatus status;
  @override
  Widget build(BuildContext context) {
    final double =
        status == MessageStatus.delivered || status == MessageStatus.read;
    return Icon(
      double ? Icons.done_all_rounded : Icons.done_rounded,
      size: 15,
      color: status == MessageStatus.read
          ? const Color(0xff072f65)
          : Colors.white70,
    );
  }
}
