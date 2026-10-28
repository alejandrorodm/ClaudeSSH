import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../../core/claude/claude_command.dart';
import '../../core/notifications/agent_notifier.dart';
import '../../core/remote/folder_label.dart';
import '../../core/ssh/ssh_gateway.dart';
import '../servers/server_profile.dart';
import 'permission_prompt.dart';

enum SessionStatus { connecting, running, exited, failed }

/// Maximum number of unattended reconnect attempts after a dropped
/// connection, before giving up and leaving the "Resume" button for the user.
const maxAutoReconnectAttempts = 3;

/// Delay before each automatic reconnect attempt, longest last.
const autoReconnectDelays = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
];

/// One tab: a live `claude` process on the VPS, attached to a terminal view.
class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required this.profile,
    required this.gateway,
    required this.loadCredentials,
    required this.directory,
    this.mode = ClaudeMode.bypass,
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

  /// Option numbers of a numbered Claude prompt detected near the end of the
  /// terminal (for example `[1, 2, 3]`), or empty when none is showing.
  List<int> promptOptions = const [];
  Timer? _promptDebounce;

  /// True while [start] is retrying after a dropped connection, without the
  /// user having to tap "Resume" themselves.
  bool autoReconnecting = false;
  int reconnectAttempt = 0;
  Timer? _reconnectTimer;
  bool _stoppedByUser = false;

  SSHClient? _client;
  SSHSession? _session;

  /// Tab title: the last folder of [directory].
  String get title => folderLabel(directory);

  bool get isRunning => status == SessionStatus.running;

  /// Starts (or restarts) Claude. With [continueConversation] it resumes the
  /// most recent conversation in [directory].
  Future<void> start({bool continueConversation = false}) async {
    _reconnectTimer?.cancel();
    _stoppedByUser = false;
    await _close();
    status = SessionStatus.connecting;
    errorMessage = null;
    exitCode = null;
    promptOptions = const [];
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
      utf8.decoder.bind(session.stdout).listen(_onReceive);
      utf8.decoder.bind(session.stderr).listen(_onReceive);
      status = SessionStatus.running;
      reconnectAttempt = 0;
      autoReconnecting = false;
      notifyListeners();

      session.done.then((_) {
        if (_session != session) return;
        exitCode = session.exitCode;
        status = SessionStatus.exited;
        notifyListeners();
        onEvent?.call(exitCode == 0 ? AgentEvent.finished : AgentEvent.failed);
        // exitCode 0 means the user (or Claude) ended the process on
        // purpose, e.g. `/exit`; anything else looks like a dropped
        // connection, worth retrying on its own.
        if (exitCode != 0) _scheduleReconnect();
      });
    } catch (error) {
      status = SessionStatus.failed;
      errorMessage = error.toString();
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_stoppedByUser) return;
    if (reconnectAttempt >= maxAutoReconnectAttempts) {
      autoReconnecting = false;
      notifyListeners();
      return;
    }
    final delay = autoReconnectDelays[reconnectAttempt];
    reconnectAttempt++;
    autoReconnecting = true;
    notifyListeners();
    _reconnectTimer = Timer(delay, () {
      if (_stoppedByUser) return;
      start(continueConversation: true);
    });
  }

  /// Cancels a pending or in-progress automatic reconnect, for example
  /// because the user tapped "Resume" themselves or is closing the tab.
  void cancelAutoReconnect() {
    _stoppedByUser = true;
    _reconnectTimer?.cancel();
    autoReconnecting = false;
    reconnectAttempt = 0;
  }

  /// Switches permission mode. Claude restarts and resumes the conversation.
  Future<void> setMode(ClaudeMode next) async {
    if (next == mode) return;
    mode = next;
    terminal.write('\r\n\x1b[2m-- mode: ${next.label} --\x1b[0m\r\n');
    await start(continueConversation: true);
  }

  /// Sends raw key input, for example an escape sequence from the toolbar.
  void sendKey(String sequence) {
    _clearPrompt();
    _sendBytes(sequence);
  }

  /// Pastes [text] as a single block and submits it, so newlines inside the
  /// message do not send early.
  void sendMessage(String text) {
    _clearPrompt();
    _sendBytes('\x1b[200~$text\x1b[201~');
    _sendBytes('\r');
  }

  /// Answers a detected numbered prompt with option [n].
  void answerPrompt(int n) => sendMessage('$n');

  void _clearPrompt() {
    if (promptOptions.isEmpty) return;
    promptOptions = const [];
    notifyListeners();
  }

  void _onReceive(String chunk) {
    terminal.write(chunk);
    // Debounced: Claude's menu usually arrives over several chunks, so wait
    // for output to settle before reading the buffer back.
    _promptDebounce?.cancel();
    _promptDebounce = Timer(const Duration(milliseconds: 150), () {
      final tailStart = (terminal.buffer.height - 20).clamp(
        0,
        terminal.buffer.height,
      );
      final text = terminal.buffer.getText(
        BufferRangeLine(
          CellOffset(0, tailStart),
          CellOffset(terminal.viewWidth, terminal.buffer.height - 1),
        ),
      );
      final detected = detectPermissionOptions(text);
      if (listEquals(detected, promptOptions)) return;
      promptOptions = detected;
      notifyListeners();
    });
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
    cancelAutoReconnect();
    _promptDebounce?.cancel();
    _close();
    super.dispose();
  }
}
