import 'package:shared_preferences/shared_preferences.dart';

import '../ssh/ssh_gateway.dart';

class KnownHostsPreferences implements KnownHostsStore {
  KnownHostsPreferences(this._preferences);

  final SharedPreferences _preferences;

  String _key(String endpoint) => 'known_host.$endpoint';

  @override
  Future<String?> fingerprintFor(String endpoint) async {
    return _preferences.getString(_key(endpoint));
  }

  @override
  Future<void> save(String endpoint, String fingerprint) {
    return _preferences.setString(_key(endpoint), fingerprint);
  }
}
