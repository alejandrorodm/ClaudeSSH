import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../../core/claude/claude_command.dart';
import '../../core/notifications/agent_notifier.dart';
import '../../core/ssh/ssh_gateway.dart';
import '../servers/server_profile.dart';

enum SessionStatus { connecting, running, exited, failed }

/// One tab: a live `claude` process on the VPS, attached to a terminal view.
class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required this.profile,
    required this.gateway,
    required this.loadCredentials,
    required this.directory,
    this.mode = ClaudeMode.build,
  }) {
    terminal.onOutput = _sendBytes;
    terminal.onBell = _onBell;
    terminal.onResize = (width, height, _, _) =>
        _session?.resizeTerminal(width, height);
  }

  final ServerProfile profile;
  final SshGateway gateway;
  final Future<SshCredentials> Function() loadCredentials;

  /// Folder on the VPS where Claude runs.
  final String directory;
  ClaudeMode mode;

  final Terminal terminal = Terminal(maxLines: 10000);

  /// Called when the session needs the user or ends on its own.
  void Function(AgentEvent event)? onEvent;

  DateTime? _lastBell;

  SessionStatus status = SessionStatus.connecting;
  String? errorMessage;
  int? exitCode;

  SSHClient? _client;
  SSHSession? _session;

  /// Tab title: the last folder of [directory].
  String get title {
    final trimmed = directory.replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty || trimmed == '~') return '~';
    return trimmed.split('/').last;
  }

  bool get isRunning => status == SessionStatus.running;

  /// Starts (or restarts) Claude. With [continueConversation] it resumes the
  /// most recent conversation in [directory].
  Future<void> start({bool continueConversation = false}) async {
    await _close();
    status = SessionStatus.connecting;
    errorMessage = null;
    exitCode = null;
    notifyListeners();

    try {
      final client = await gateway.connect(profile, await loadCredentials());
      _client = client;
      final session = await client.execute(
        buildLaunchCommand(
          workingDirectory: directory,
          mode: mode,
          continueConversation: continueConversation,
        ),
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );
      _session = session;
      utf8.decoder.bind(session.stdout).listen(terminal.write);
      utf8.decoder.bind(session.stderr).listen(terminal.write);
      status = SessionStatus.running;
      notifyListeners();

      session.done.then((_) {
        if (_session != session) return;
        exitCode = session.exitCode;
        status = SessionStatus.exited;
        notifyListeners();
        onEvent?.call(exitCode == 0 ? AgentEvent.finished : AgentEvent.failed);
      });
    } catch (error) {
      status = SessionStatus.failed;
      errorMessage = error.toString();
      notifyListeners();
    }
  }

  /// Switches permission mode. Claude restarts and resumes the conversation.
  Future<void> setMode(ClaudeMode next) async {
    if (next == mode) return;
    mode = next;
    terminal.write('\r\n\x1b[2m-- mode: ${next.label} --\x1b[0m\r\n');
    await start(continueConversation: true);
  }

  /// Sends raw key input, for example an escape sequence from the toolbar.
  void sendKey(String sequence) => _sendBytes(sequence);

  /// Pastes [text] as a single block and submits it, so newlines inside the
  /// message do not send early.
  void sendMessage(String text) {
    _sendBytes('\x1b[200~$text\x1b[201~');
    _sendBytes('\r');
  }

  /// Claude rings the terminal bell when it needs input. Ignore repeats, so
  /// one question does not produce a burst of notifications.
  void _onBell() {
    final now = DateTime.now();
    final last = _lastBell;
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _lastBell = now;
    onEvent?.call(AgentEvent.needsYou);
  }

  void _sendBytes(String data) {
    if (!isRunning) return;
    _session?.stdin.add(utf8.encode(data));
  }

  Future<void> _close() async {
    _session?.close();
    _session = null;
    _client?.close();
    _client = null;
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }
}
