/// Permission modes offered in the app, mapped to Claude Code's --permission-mode.
enum ClaudeMode {
  plan('plan', 'Plan', 'Reads and proposes; never edits'),
  build('acceptEdits', 'Build', 'Edits files without asking'),
  auto('auto', 'Auto', 'Claude Code decides when to ask'),
  bypass('bypassPermissions', 'Bypass', 'Skips every permission prompt');

  const ClaudeMode(this.flag, this.label, this.hint);

  final String flag;
  final String label;
  final String hint;
}

/// Command that starts an interactive Claude Code session in [workingDirectory].
///
/// When `tmux` is available on the remote host, Claude runs inside a tmux
/// session keyed by [workingDirectory] instead of directly under the SSH
/// PTY: a dropped connection then only detaches the tmux client, it does not
/// send Claude a SIGHUP, so reconnecting (same command) re-attaches to the
/// same running conversation instead of starting a new one. Without tmux,
/// Claude runs directly as before and a dropped connection does kill it.
///
/// `exec` replaces the shell, so the tab closes when the tmux client (or
/// Claude itself, without tmux) exits. Pass [continueConversation] to resume
/// the most recent conversation in that directory — only relevant when a new
/// process is actually started, not when reattaching to one already running.
/// Pass [forceRestart] (used when switching permission mode) to kill any
/// existing tmux session first, so the new mode flag actually takes effect
/// instead of reattaching to the old process.
String buildLaunchCommand({
  String? workingDirectory,
  ClaudeMode mode = ClaudeMode.bypass,
  bool continueConversation = false,
  bool forceRestart = false,
}) {
  final cd = _changeDirectory(workingDirectory);
  final continueFlag = continueConversation ? ' --continue' : '';
  final claude = 'claude --permission-mode ${mode.flag}$continueFlag';
  final session = tmuxSessionName(workingDirectory);
  final kill = forceRestart ? 'tmux kill-session -t $session 2>/dev/null; ' : '';
  return 'export PATH="\$HOME/.local/bin:\$PATH"; '
      // On a systemd host, "KillUserProcesses" (the default on many distros)
      // tears down every process owned by this user, tmux server included,
      // once the SSH login session ends — the same connection drop this
      // whole tmux layer exists to survive. Enabling linger keeps the user's
      // systemd instance (and anything it owns) running after that. Best
      // effort: harmless no-op without systemd, or without permission.
      '$_enableLinger; '
      '$cd'
      'if command -v tmux >/dev/null 2>&1; then '
      '$kill'
      'exec tmux new-session -A -s $session ${_quote(claude)}; '
      'else '
      'exec $claude; '
      'fi';
}

/// Ends the detached tmux session (if any) holding Claude for
/// [workingDirectory] on the remote host. Used only when the user
/// deliberately closes a tab, so Claude does not keep running — and
/// billing — in the background forever; a dropped connection or the app
/// being killed must never run this.
String buildKillSessionCommand(String? workingDirectory) {
  final session = tmuxSessionName(workingDirectory);
  return 'tmux kill-session -t $session 2>/dev/null; true';
}

const _enableLinger =
    'command -v loginctl >/dev/null 2>&1 && '
    'loginctl enable-linger "\$(whoami)" >/dev/null 2>&1';

/// Deterministic tmux session name for [workingDirectory], so the same
/// folder always maps to the same remote session.
String tmuxSessionName(String? workingDirectory) {
  final raw = (workingDirectory == null || workingDirectory.trim().isEmpty)
      ? '~'
      : workingDirectory.trim();
  final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return 'claude_ssh_$safe';
}

/// Lists subdirectories and reads the current path, from `pwd` and `ls -1Ap`.
String buildListDirectoryCommand(String path) {
  final cd = path.trim().isEmpty
      ? 'cd -- "\$HOME"'
      : 'cd -- ${_pathArgument(path.trim())}';
  return 'export PATH="\$HOME/.local/bin:\$PATH"; $cd && pwd && ls -1Ap';
}

String _changeDirectory(String? path) {
  final trimmed = path?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  return 'cd -- ${_pathArgument(trimmed)} && ';
}

/// Expands a leading `~` ourselves, because quoting disables tilde expansion.
String _pathArgument(String path) {
  if (path == '~') return '"\$HOME"';
  if (path.startsWith('~/')) return '"\$HOME"/${_quote(path.substring(2))}';
  return _quote(path);
}

String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
