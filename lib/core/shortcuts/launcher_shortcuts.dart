import 'package:quick_actions/quick_actions.dart';

import '../storage/server_repository.dart';
import '../../features/servers/server_profile.dart';

/// A single home-screen launcher shortcut that jumps back into whichever
/// session was opened most recently, across any server.
class LauncherShortcuts {
  LauncherShortcuts(this._repository);

  static const _resumeType = 'resume_last_session';

  final ServerRepository _repository;
  final _actions = const QuickActions();

  /// Registers the tap handler. Call once, early in `main()`. A shortcut is
  /// a convenience, never required, so any platform failure is swallowed.
  void initialize(void Function(LastSession session) onResume) {
    _actions
        .initialize((type) {
          if (type != _resumeType) return;
          final last = _repository.lastSession();
          if (last != null) onResume(last);
        })
        .catchError((_) {});
  }

  /// Remembers [profile]/[directory] as the session to resume, and updates
  /// the shortcut's label to match.
  Future<void> remember(ServerProfile profile, String directory) async {
    await _repository.setLastSession(
      serverId: profile.id,
      serverName: profile.name,
      directory: directory,
    );
    await refresh();
  }

  /// Rebuilds the shortcut from whatever is currently remembered. Safe to
  /// call at startup, even before anything has been opened.
  Future<void> refresh() async {
    final last = _repository.lastSession();
    try {
      if (last == null) {
        await _actions.clearShortcutItems();
        return;
      }
      await _actions.setShortcutItems([
        ShortcutItem(
          type: _resumeType,
          localizedTitle: 'Resume ${last.serverName}',
          localizedSubtitle: _folderLabel(last.directory),
        ),
      ]);
    } catch (_) {
      // A missing shortcut is a minor convenience loss, not worth surfacing.
    }
  }

  String _folderLabel(String directory) {
    final trimmed = directory.replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty || trimmed == '~') return '~';
    return trimmed.split('/').last;
  }
}
