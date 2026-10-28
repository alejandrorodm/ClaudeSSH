import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:xterm/xterm.dart';

import '../../core/background/foreground_service.dart';
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
    this.initialDirectory,
  });

  final ServerProfile profile;
  final ServerRepository repository;
  final SshGateway gateway;

  /// When set (for example from the "resume last session" launcher
  /// shortcut), a session opens here immediately instead of showing the
  /// folder browser.
  final String? initialDirectory;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage>
    with WidgetsBindingObserver {
  final List<TerminalSession> _sessions = [];
  int _active = 0;
  final _compose = TextEditingController();
  late double _fontSize = widget.repository.terminalFontSize();
  late List<String> _quickCommands = widget.repository.quickCommands();
  bool? _wakelockOn;
  late ForegroundServiceController _foregroundService;

  TerminalSession? get _current =>
      _sessions.isEmpty ? null : _sessions[_active];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final initialDirectory = widget.initialDirectory;
    if (initialDirectory != null) {
      // Resumes the conversation already in that folder, same as any other
      // restored tab below — a launcher shortcut is not a brand new chat.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openSession(initialDirectory, continueConversation: true),
      );
    } else {
      _restoreTabs();
    }
  }

  /// Reopens whatever tabs were still open last time this server's workspace
  /// closed — including Android killing the app's process while it was
  /// backgrounded, which drops every in-memory session with it.
  void _restoreTabs() {
    final restored = widget.repository.openTabs(widget.profile.id);
    if (restored.isEmpty) return;
    final activeIndex = widget.repository.openTabsActiveIndex(
      widget.profile.id,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final tab in restored) {
        if (!mounted) return;
        _openSession(
          tab.directory,
          mode: ClaudeMode.values.firstWhere(
            (m) => m.name == tab.mode,
            orElse: () => ClaudeMode.bypass,
          ),
          continueConversation: true,
        );
      }
      if (mounted) {
        setState(
          () => _active = activeIndex.clamp(0, _sessions.length - 1),
        );
        // The loop above persisted "active" as whichever tab opened last;
        // overwrite it now with the index actually restored above, so a
        // second process kill resumes on the right tab too.
        _persistTabs();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cached here, not read from context in dispose(): InheritedWidget
    // lookups are not allowed once a State starts unmounting.
    _foregroundService = AppServices.of(context).foregroundService;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final session in _sessions) {
      session.dispose();
    }
    _compose.dispose();
    WakelockPlus.disable();
    _foregroundService.stop();
    super.dispose();
  }

  /// While backgrounded with a live session, a foreground service keeps the
  /// process (and the SSH connection) from being frozen or killed. Coming
  /// back to the foreground stops it — Flutter itself already keeps the app
  /// alive while it is visible.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (_sessions.any((s) => s.isRunning)) _foregroundService.start();
    } else if (state == AppLifecycleState.resumed) {
      _foregroundService.stop();
    }
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
    _openSession(path);
  }

  void _openSession(
    String path, {
    ClaudeMode mode = ClaudeMode.bypass,
    bool continueConversation = false,
  }) {
    final session = TerminalSession(
      profile: widget.profile,
      gateway: widget.gateway,
      loadCredentials: () =>
          widget.repository.credentialsFor(widget.profile.id),
      directory: path,
      mode: mode,
    );
    session.onEvent = (event) => _notify(session, event);
    setState(() {
      _sessions.add(session);
      _active = _sessions.length - 1;
    });
    session.start(continueConversation: continueConversation);
    AppServices.of(context).launcherShortcuts.remember(widget.profile, path);
    widget.repository.rememberRecentFolder(widget.profile.id, path);
    _persistTabs();
  }

  /// Saves every open tab (folder + mode) and which one is active, so
  /// [_restoreTabs] can bring them all back later.
  void _persistTabs() {
    widget.repository.setOpenTabs(
      widget.profile.id,
      _sessions
          .map((s) => OpenTab(directory: s.directory, mode: s.mode.name))
          .toList(),
      active: _active,
    );
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
      // Parsed back in main.dart to jump straight to this session's folder.
      payload: encodeSessionPayload(widget.profile.id, session.directory),
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
    _persistTabs();
  }

  void _selectTab(int index) {
    setState(() => _active = index);
    _persistTabs();
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

  Future<void> _editQuickCommands() async {
    final updated = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _QuickCommandsEditorSheet(commands: _quickCommands),
    );
    if (updated == null || !mounted) return;
    setState(() => _quickCommands = updated);
    widget.repository.setQuickCommands(updated);
  }

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
      builder: (context) => _SearchSheet(lines: lines, sessionTitle: session.title),
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
    if (chosen != null) {
      await session.setMode(chosen);
      if (mounted) _persistTabs();
    }
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
                onSelect: _selectTab,
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
                _QuickCommandsBar(
                  commands: _quickCommands,
                  onCommand: _sendQuickCommand,
                  onEdit: _editQuickCommands,
                ),
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
/// Customizable: [onEdit] opens the editor for [commands].
class _QuickCommandsBar extends StatelessWidget {
  const _QuickCommandsBar({
    required this.commands,
    required this.onCommand,
    required this.onEdit,
  });

  final List<String> commands;
  final ValueChanged<String> onCommand;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        itemCount: commands.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          if (index == commands.length) {
            return ActionChip(
              avatar: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit'),
              onPressed: onEdit,
            );
          }
          final command = commands[index];
          return ActionChip(
            label: Text(command),
            onPressed: () => onCommand(command),
          );
        },
      ),
    );
  }
}

/// Add, remove, or keep the quick commands shown in [_QuickCommandsBar].
/// Pops with the final list once the user is done.
class _QuickCommandsEditorSheet extends StatefulWidget {
  const _QuickCommandsEditorSheet({required this.commands});

  final List<String> commands;

  @override
  State<_QuickCommandsEditorSheet> createState() =>
      _QuickCommandsEditorSheetState();
}

class _QuickCommandsEditorSheetState
    extends State<_QuickCommandsEditorSheet> {
  late final List<String> _commands = [...widget.commands];
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final text = _input.text.trim();
    if (text.isEmpty || _commands.contains(text)) return;
    setState(() {
      _commands.add(text);
      _input.clear();
    });
  }

  void _remove(int index) => setState(() => _commands.removeAt(index));

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Quick commands',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (_commands.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No quick commands yet.'),
              ),
            for (var i = 0; i < _commands.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_commands[i]),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: () => _remove(i),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(
                      hintText: '/my-command',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: const Text('Add')),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_commands),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Searches the terminal's plain text and lets the user copy a line.
class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.lines, required this.sessionTitle});

  final List<String> lines;
  final String sessionTitle;

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

  void _share() {
    SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            utf8.encode(widget.lines.join('\n')),
            name: '${widget.sessionTitle}.log.txt',
            mimeType: 'text/plain',
          ),
        ],
      ),
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
                  IconButton(
                    tooltip: 'Share log',
                    icon: const Icon(Icons.ios_share_outlined),
                    onPressed: _share,
                  ),
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
