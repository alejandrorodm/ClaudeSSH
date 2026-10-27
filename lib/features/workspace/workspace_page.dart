import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:xterm/xterm.dart';

import '../../core/claude/claude_command.dart';
import '../../core/notifications/agent_notifier.dart';
import '../../core/ssh/ssh_gateway.dart';
import '../../core/storage/server_repository.dart';
import '../../main.dart';
import '../servers/server_profile.dart';
import '../files/file_browser_page.dart';
import 'folder_browser_page.dart';
import 'terminal_log.dart';
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
  bool? _wakelockOn;

  TerminalSession? get _current =>
      _sessions.isEmpty ? null : _sessions[_active];

  @override
  void dispose() {
    for (final session in _sessions) {
      session.dispose();
    }
    _compose.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  /// Keeps the screen on while a Claude process is actively running in any
  /// tab, so a long task does not get interrupted by the phone locking.
  void _syncWakelock() {
    final shouldStayOn = _sessions.any((s) => s.isRunning);
    if (_wakelockOn == shouldStayOn) return;
    _wakelockOn = shouldStayOn;
    if (shouldStayOn) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
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

  void _sendQuickCommand(String command) => _current?.sendMessage(command);

  Future<void> _openSearch() async {
    final session = _current;
    if (session == null) return;
    final buffer = session.terminal.buffer;
    final text = buffer.getText(
      BufferRangeLine(
        const CellOffset(0, 0),
        CellOffset(session.terminal.viewWidth, buffer.height - 1),
      ),
    );
    final lines = text.split('\n');
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SearchSheet(lines: lines),
    );
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
            tooltip: 'Search & copy',
            icon: const Icon(Icons.search),
            onPressed: _current == null ? null : _openSearch,
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
        builder: (context, _) {
          _syncWakelock();
          final current = _current;
          return Column(
            children: [
              _TabStrip(
                sessions: _sessions,
                active: _active,
                onSelect: (index) => setState(() => _active = index),
                onClose: _closeSession,
              ),
              const Divider(height: 1),
              Expanded(child: _buildTerminal()),
              if (current != null) ...[
                if (current.promptOptions.isNotEmpty)
                  _PromptReplyBar(
                    options: current.promptOptions,
                    onAnswer: current.answerPrompt,
                  ),
                _QuickCommandsBar(onCommand: _sendQuickCommand),
                _KeyBar(onKey: (sequence) => current.sendKey(sequence)),
                _Composer(
                  controller: _compose,
                  mode: current.mode,
                  onModeTap: _pickMode,
                  onSend: _sendMessage,
                ),
              ],
            ],
          );
        },
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
    var (text, canRestart) = switch (session.status) {
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
    if (session.autoReconnecting) {
      text =
          'Connection dropped — reconnecting '
          '(attempt ${session.reconnectAttempt}/$maxAutoReconnectAttempts)…';
      canRestart = true;
    }
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

/// One-tap replies to a detected Claude permission prompt ("1. Yes", …),
/// so answering does not need the phone's number row.
class _PromptReplyBar extends StatelessWidget {
  const _PromptReplyBar({required this.options, required this.onAnswer});

  final List<int> options;
  final ValueChanged<int> onAnswer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.touch_app_outlined,
            size: 18,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Claude is asking:',
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
          for (final n in options)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: FilledButton(
                onPressed: () => onAnswer(n),
                child: Text('$n'),
              ),
            ),
        ],
      ),
    );
  }
}

/// Full Claude Code commands that are tedious to type on a phone keyboard.
class _QuickCommandsBar extends StatelessWidget {
  const _QuickCommandsBar({required this.onCommand});

  final ValueChanged<String> onCommand;

  static const _commands = ['/clear', '/compact', '/usage', '/model'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        itemCount: _commands.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final command = _commands[index];
          return ActionChip(
            label: Text(command),
            onPressed: () => onCommand(command),
          );
        },
      ),
    );
  }
}

/// Searches the terminal's plain text and lets the user copy a line.
class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.lines});

  final List<String> lines;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _query = TextEditingController();
  List<int> _matches = const [];

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      setState(() => _matches = findMatchingLines(widget.lines, _query.text));
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search this session',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy all'),
                    onPressed: () => _copy(widget.lines.join('\n')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _query.text.trim().isEmpty
                    ? const Center(child: Text('Type to search'))
                    : _matches.isEmpty
                    ? const Center(child: Text('No matches'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _matches.length,
                        itemBuilder: (context, index) {
                          final line = widget.lines[_matches[index]];
                          return ListTile(
                            dense: true,
                            title: Text(
                              line,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.copy_outlined, size: 18),
                            onTap: () => _copy(line),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
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
