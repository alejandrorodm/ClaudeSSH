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
/// It runs under a PTY, so every Claude feature works: permission prompts,
/// slash commands and questions. `exec` replaces the shell, so the tab
/// closes when Claude exits. Pass [continueConversation] to resume the most
/// recent conversation in that directory, which is how a mode change keeps
/// the chat history.
String buildLaunchCommand({
  String? workingDirectory,
  ClaudeMode mode = ClaudeMode.bypass,
  bool continueConversation = false,
}) {
  final cd = _changeDirectory(workingDirectory);
  final continueFlag = continueConversation ? ' --continue' : '';
  return 'export PATH="\$HOME/.local/bin:\$PATH"; '
      '$cd'
      'exec claude --permission-mode ${mode.flag}$continueFlag';
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
