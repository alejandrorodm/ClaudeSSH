import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/servers/server_profile.dart';

/// Persists server profiles (plain JSON) and their secrets (secure storage).
class ServerRepository {
  ServerRepository(this._preferences, this._secureStorage);

  static const _profilesKey = 'servers.v1';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;

  Future<List<ServerProfile>> loadAll() async {
    final raw = _preferences.getString(_profilesKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((item) => ServerProfile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(ServerProfile profile, SshCredentials credentials) async {
    final profiles = await loadAll();
    final index = profiles.indexWhere((p) => p.id == profile.id);
    if (index == -1) {
      profiles.add(profile);
    } else {
      profiles[index] = profile;
    }
    await _writeProfiles(profiles);
    await _writeSecret(profile.id, 'password', credentials.password);
    await _writeSecret(profile.id, 'privateKey', credentials.privateKeyPem);
    await _writeSecret(profile.id, 'passphrase', credentials.passphrase);
  }

  Future<SshCredentials> credentialsFor(String profileId) async {
    return SshCredentials(
      password: await _secureStorage.read(
        key: _secretKey(profileId, 'password'),
      ),
      privateKeyPem: await _secureStorage.read(
        key: _secretKey(profileId, 'privateKey'),
      ),
      passphrase: await _secureStorage.read(
        key: _secretKey(profileId, 'passphrase'),
      ),
    );
  }

  Future<void> delete(String profileId) async {
    final profiles = await loadAll();
    profiles.removeWhere((p) => p.id == profileId);
    await _writeProfiles(profiles);
    for (final field in const ['password', 'privateKey', 'passphrase']) {
      await _secureStorage.delete(key: _secretKey(profileId, field));
    }
  }

  /// Marker so [importProfiles] can tell a real export from an unrelated file.
  static const _exportKind = 'claude-ssh-servers';
  static const _exportVersion = 1;

  /// Server settings only, never secrets: passwords and keys stay in secure
  /// storage and are deliberately left out of the exported file.
  Future<String> exportProfilesJson() async {
    final profiles = await loadAll();
    return const JsonEncoder.withIndent('  ').convert({
      'kind': _exportKind,
      'version': _exportVersion,
      'servers': profiles.map((p) => p.toJson()).toList(),
    });
  }

  /// Imports servers from [json] as new profiles (new ids), so an import can
  /// never silently overwrite an existing server's settings. Credentials are
  /// not part of the file and must be re-entered after importing.
  ///
  /// Returns the number of servers imported. Throws a [FormatException] if
  /// [json] is not a file this app exported.
  Future<int> importProfiles(String json) async {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic> ||
        decoded['kind'] != _exportKind ||
        decoded['servers'] is! List) {
      throw const FormatException('Not a Claude SSH servers export file.');
    }

    final incoming = (decoded['servers'] as List).cast<Map<String, dynamic>>();
    final profiles = await loadAll();
    final existingIds = profiles.map((p) => p.id).toSet();
    var seed = DateTime.now().microsecondsSinceEpoch;
    for (final source in incoming) {
      var id = '${seed++}';
      while (existingIds.contains(id)) {
        id = '${seed++}';
      }
      existingIds.add(id);
      profiles.add(ServerProfile.fromJson({...source, 'id': id}));
    }
    await _writeProfiles(profiles);
    return incoming.length;
  }

  /// Whether the app asks to unlock (biometrics or device PIN/pattern) on
  /// cold start. Off by default: turning it on requires a successful
  /// authentication first, so the toggle can never lock a user out of an
  /// app they just installed.
  bool biometricLockEnabled() =>
      _preferences.getBool(_biometricLockKey) ?? false;

  Future<void> setBiometricLockEnabled(bool enabled) {
    return _preferences.setBool(_biometricLockKey, enabled);
  }

  static const _biometricLockKey = 'security.biometricLock';

  /// Remembers the most recently opened session, so a home screen shortcut
  /// can jump straight back into it.
  Future<void> setLastSession({
    required String serverId,
    required String serverName,
    required String directory,
  }) {
    return _preferences.setString(
      _lastSessionKey,
      jsonEncode({
        'serverId': serverId,
        'serverName': serverName,
        'directory': directory,
      }),
    );
  }

  LastSession? lastSession() {
    final raw = _preferences.getString(_lastSessionKey);
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return LastSession(
      serverId: map['serverId'] as String,
      serverName: map['serverName'] as String,
      directory: map['directory'] as String,
    );
  }

  static const _lastSessionKey = 'lastSession';

  /// Every tab open in [serverId]'s workspace, in order, so they can be
  /// restored if Android kills the app's process while backgrounded. Empty
  /// when the server was never opened, or every tab was closed.
  List<OpenTab> openTabs(String serverId) {
    final raw = _preferences.getString(_openTabsKey(serverId));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map(
          (item) => OpenTab(
            directory: (item as Map<String, dynamic>)['directory'] as String,
            mode: item['mode'] as String,
          ),
        )
        .toList();
  }

  /// Which of [openTabs] was active, 0 when none was remembered.
  int openTabsActiveIndex(String serverId) =>
      _preferences.getInt(_openTabsActiveKey(serverId)) ?? 0;

  /// Remembers every open tab for [serverId]. An empty [tabs] list clears
  /// whatever was remembered, e.g. because the user closed every tab.
  Future<void> setOpenTabs(
    String serverId,
    List<OpenTab> tabs, {
    int active = 0,
  }) async {
    if (tabs.isEmpty) {
      await _preferences.remove(_openTabsKey(serverId));
      await _preferences.remove(_openTabsActiveKey(serverId));
      return;
    }
    await _preferences.setString(
      _openTabsKey(serverId),
      jsonEncode(
        tabs.map((t) => {'directory': t.directory, 'mode': t.mode}).toList(),
      ),
    );
    await _preferences.setInt(_openTabsActiveKey(serverId), active);
  }

  String _openTabsKey(String serverId) => 'workspace.tabs.$serverId';

  String _openTabsActiveKey(String serverId) =>
      'workspace.tabs.$serverId.active';

  /// Folders marked favorite in [serverId]'s folder browser, for one-tap
  /// entry without browsing there again.
  List<String> favoriteFolders(String serverId) =>
      _preferences.getStringList(_favoritesKey(serverId)) ?? const [];

  bool isFavoriteFolder(String serverId, String directory) =>
      favoriteFolders(serverId).contains(directory);

  /// Adds [directory] to [serverId]'s favorites, or removes it if it was
  /// already there.
  Future<void> toggleFavoriteFolder(String serverId, String directory) {
    final favorites = [...favoriteFolders(serverId)];
    if (!favorites.remove(directory)) favorites.add(directory);
    return _preferences.setStringList(_favoritesKey(serverId), favorites);
  }

  String _favoritesKey(String serverId) => 'workspace.favorites.$serverId';

  /// How many recently opened folders [rememberRecentFolder] keeps per
  /// server, oldest dropped first.
  static const maxRecentFolders = 8;

  /// Folders recently opened in [serverId]'s workspace, most recent first.
  List<String> recentFolders(String serverId) =>
      _preferences.getStringList(_recentFoldersKey(serverId)) ?? const [];

  /// Moves [directory] to the front of [serverId]'s recent folders,
  /// capped at [maxRecentFolders].
  Future<void> rememberRecentFolder(String serverId, String directory) {
    final recents = [...recentFolders(serverId)];
    recents.remove(directory);
    recents.insert(0, directory);
    if (recents.length > maxRecentFolders) {
      recents.removeRange(maxRecentFolders, recents.length);
    }
    return _preferences.setStringList(_recentFoldersKey(serverId), recents);
  }

  String _recentFoldersKey(String serverId) => 'workspace.recents.$serverId';

  static const _defaultQuickCommands = ['/clear', '/compact', '/usage', '/model'];

  /// Full Claude Code commands shown as one-tap chips, customizable because
  /// different users lean on different slash commands.
  List<String> quickCommands() =>
      _preferences.getStringList(_quickCommandsKey) ?? _defaultQuickCommands;

  Future<void> setQuickCommands(List<String> commands) =>
      _preferences.setStringList(_quickCommandsKey, commands);

  static const _quickCommandsKey = 'workspace.quickCommands';

  static const defaultTerminalFontSize = 13.0;
  static const minTerminalFontSize = 9.0;
  static const maxTerminalFontSize = 24.0;

  /// Terminal text size, kept on this phone only.
  double terminalFontSize() =>
      _preferences.getDouble(_fontSizeKey) ?? defaultTerminalFontSize;

  Future<void> setTerminalFontSize(double size) {
    final clamped = size
        .clamp(minTerminalFontSize, maxTerminalFontSize)
        .toDouble();
    return _preferences.setDouble(_fontSizeKey, clamped);
  }

  static const _fontSizeKey = 'terminal.fontSize';

  /// Unsaved form values, so leaving the app mid-edit does not lose them.
  /// Secrets are never stored here: preferences are plain text.
  Map<String, dynamic>? loadDraft(String draftId) {
    final raw = _preferences.getString(_draftKey(draftId));
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> saveDraft(String draftId, Map<String, dynamic> draft) {
    return _preferences.setString(_draftKey(draftId), jsonEncode(draft));
  }

  Future<void> clearDraft(String draftId) {
    return _preferences.remove(_draftKey(draftId));
  }

  String _draftKey(String draftId) => 'server.draft.$draftId';

  Future<void> _writeProfiles(List<ServerProfile> profiles) {
    final raw = jsonEncode(profiles.map((p) => p.toJson()).toList());
    return _preferences.setString(_profilesKey, raw);
  }

  Future<void> _writeSecret(String profileId, String field, String? value) {
    final key = _secretKey(profileId, field);
    if (value == null || value.isEmpty) {
      return _secureStorage.delete(key: key);
    }
    return _secureStorage.write(key: key, value: value);
  }

  String _secretKey(String profileId, String field) =>
      'server.$profileId.$field';
}

/// The server and folder a "resume last session" shortcut jumps back into.
class LastSession {
  const LastSession({
    required this.serverId,
    required this.serverName,
    required this.directory,
  });

  final String serverId;
  final String serverName;
  final String directory;
}

/// One restored workspace tab: the folder it was open in and its
/// [ClaudeMode.name] (kept as a plain string so storage does not depend on
/// the claude feature).
class OpenTab {
  const OpenTab({required this.directory, required this.mode});

  final String directory;
  final String mode;
}
