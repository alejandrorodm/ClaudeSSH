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
