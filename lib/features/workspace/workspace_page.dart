import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../core/claude/claude_command.dart';
import '../../core/notifications/agent_notifier.dart';
import '../../core/ssh/ssh_gateway.dart';
import '../../core/storage/server_repository.dart';
import '../../main.dart';
import '../servers/server_profile.dart';
import '../files/file_browser_page.dart';
import 'folder_browser_page.dart';
import 'terminal_session.dart';

/// Tabs of live Claude Code sessions on one server.
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.profile,
    required this.repository,
    required this.gateway,
  });

  final ServerProfile profile;
  final ServerRepository repository;
  final SshGateway gateway;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  final List<TerminalSession> _sessions = [];
  int _active = 0;
  final _compose = TextEditingController();
  late double _fontSize = widget.repository.terminalFontSize();

  TerminalSession? get _current =>
      _sessions.isEmpty ? null : _sessions[_active];

  @override
  void dispose() {
    for (final session in _sessions) {
      session.dispose();
    }
    _compose.dispose();
    super.dispose();
  }

  Future<void> _newSession() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FolderBrowserPage(
          profile: widget.profile,
          repository: widget.repository,
          gateway: widget.gateway,
        ),
      ),
    );
    if (path == null || !mounted) return;

    final session = TerminalSession(
      profile: widget.profile,
      gateway: widget.gateway,
      loadCredentials: () =>
          widget.repository.credentialsFor(widget.profile.id),
      directory: path,
    );
    session.onEvent = (event) => _notify(session, event);
    setState(() {
      _sessions.add(session);
      _active = _sessions.length - 1;
    });
    session.start();
  }

  /// Notifies only while the app is in the background: if the user is
  /// looking at the app, the terminal already shows what happened.
  void _notify(TerminalSession session, AgentEvent event) {
    if (!mounted) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.resumed) return;

    final body = switch (event) {
      AgentEvent.finished => 'Claude finished.',
      AgentEvent.failed => 'Claude stopped with an error.',
      AgentEvent.needsYou => 'Claude needs your input.',
    };
    AppServices.of(context).notifier.show(
      id: identityHashCode(session) & 0x7fffffff,
      event: event,
      title: '${widget.profile.name} · ${session.title}',
      body: body,
    );
  }

  void _closeSession(int index) {
    final session = _sessions[index];
    setState(() {
      _sessions.removeAt(index);
      if (_active >= _sessions.length) _active = _sessions.length - 1;
      if (_active < 0) _active = 0;
    });
    session.dispose();
  }

  /// Resizing the font changes the column count, and the terminal reports the
  /// new size to the VPS so Claude redraws its panels (for example /usage).
  void _changeFontSize(double delta) {
    setState(() => _fontSize += delta);
    widget.repository.setTerminalFontSize(_fontSize);
  }

  void _openFiles() {
    final session = _current;
    final start = session?.directory ?? widget.profile.workingDirectory;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileBrowserPage(
          profile: widget.profile,
          repository: widget.repository,
          gateway: widget.gateway,
          startPath: start,
        ),
      ),
    );
  }

  void _sendMessage() {
    final text = _compose.text;
    final session = _current;
    if (session == null || text.trim().isEmpty) return;
    session.sendMessage(text);
    _compose.clear();
  }

  Future<void> _pickMode() async {
    final session = _current;
    if (session == null) return;
    final chosen = await showModalBottomSheet<ClaudeMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in ClaudeMode.values)
              ListTile(
                leading: Icon(
                  mode == session.mode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(mode.label),
                subtitle: Text(mode.hint),
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) session.setMode(chosen);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name),
        actions: [
          IconButton(
            tooltip: 'Smaller text',
            icon: const Icon(Icons.text_decrease),
            onPressed: _fontSize <= ServerRepository.minTerminalFontSize
                ? null
                : () => _changeFontSize(-1),
          ),
          IconButton(
            tooltip: 'Larger text',
            icon: const Icon(Icons.text_increase),
            onPressed: _fontSize >= ServerRepository.maxTerminalFontSize
                ? null
                : () => _changeFontSize(1),
          ),
          IconButton(
            tooltip: 'Files',
            icon: const Icon(Icons.folder_copy_outlined),
            onPressed: _openFiles,
          ),
          IconButton(
            tooltip: 'New session',
            icon: const Icon(Icons.add),
            onPressed: _newSession,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(_sessions),
        builder: (context, _) => Column(
          children: [
            _TabStrip(
              sessions: _sessions,
              active: _active,
              onSelect: (index) => setState(() => _active = index),
              onClose: _closeSession,
            ),
            const Divider(height: 1),
            Expanded(child: _buildTerminal()),
            if (_current != null) ...[
              _KeyBar(onKey: (sequence) => _current?.sendKey(sequence)),
              _Composer(
                controller: _compose,
                mode: _current!.mode,
                onModeTap: _pickMode,
                onSend: _sendMessage,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTerminal() {
    final session = _current;
    if (session == null) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Choose a folder to start'),
          onPressed: _newSession,
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: TerminalView(
            session.terminal,
            key: ValueKey(session),
            autofocus: true,
            textStyle: TerminalStyle(fontSize: _fontSize),
          ),
        ),
        if (session.status != SessionStatus.running)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: _StatusBanner(
              session: session,
              onRestart: () => session.start(continueConversation: true),
            ),
          ),
      ],
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.sessions,
    required this.active,
    required this.onSelect,
    required this.onClose,
  });

  final List<TerminalSession> sessions;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: sessions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final session = sessions[index];
          final selected = index == active;
          return InputChip(
            selected: selected,
            avatar: _StatusDot(status: session.status),
            label: Text(session.title),
            onPressed: () => onSelect(index),
            onDeleted: () => onClose(index),
            deleteIconColor: scheme.onSurfaceVariant,
          );
        },
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      SessionStatus.connecting => scheme.tertiary,
      SessionStatus.running => scheme.primary,
      SessionStatus.exited => scheme.outline,
      SessionStatus.failed => scheme.error,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.session, required this.onRestart});

  final TerminalSession session;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, canRestart) = switch (session.status) {
      SessionStatus.connecting => ('Connecting…', false),
      SessionStatus.exited => (
        'Claude exited (code ${session.exitCode ?? '?'}).',
        true,
      ),
      SessionStatus.failed => (
        'Connection failed: ${session.errorMessage ?? 'unknown error'}',
        true,
      ),
      SessionStatus.running => ('', false),
    };
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(child: Text(text)),
            if (canRestart)
              FilledButton.tonal(
                onPressed: onRestart,
                child: const Text('Resume'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Keys a phone keyboard does not have, one tap each.
class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.onKey});

  final ValueChanged<String> onKey;

  static const _keys = <(String, String)>[
    ('Esc', '\x1b'),
    ('Tab', '\t'),
    ('⇧Tab', '\x1b[Z'),
    ('↑', '\x1b[A'),
    ('↓', '\x1b[B'),
    ('←', '\x1b[D'),
    ('→', '\x1b[C'),
    ('/', '/'),
    ('Ctrl-C', '\x03'),
    ('Ctrl-D', '\x04'),
    ('Ctrl-L', '\x0c'),
    ('Enter', '\r'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: _keys.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final (label, sequence) = _keys[index];
          return OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(44, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: () => onKey(sequence),
            child: Text(label),
          );
        },
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.mode,
    required this.onModeTap,
    required this.onSend,
  });

  final TextEditingController controller;
  final ClaudeMode mode;
  final VoidCallback onModeTap;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ActionChip(
              label: Text(mode.label),
              avatar: const Icon(Icons.tune, size: 18),
              onPressed: onModeTap,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Message Claude',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.arrow_upward_rounded),
              onPressed: onSend,
            ),
          ],
        ),
      ),
    );
  }
}
