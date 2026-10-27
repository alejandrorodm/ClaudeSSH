enum AuthMethod { password, privateKey }

/// A saved VPS. Secrets are not part of this model; see [SshCredentials].
class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.auth,
    this.workingDirectory = '',
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final AuthMethod auth;

  /// Directory on the VPS where Claude runs. Empty means the login directory.
  final String workingDirectory;

  String get endpoint => '$host:$port';

  ServerProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    AuthMethod? auth,
    String? workingDirectory,
  }) {
    return ServerProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      auth: auth ?? this.auth,
      workingDirectory: workingDirectory ?? this.workingDirectory,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'auth': auth.name,
    'workingDirectory': workingDirectory,
  };

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      username: json['username'] as String,
      auth: AuthMethod.values.byName(json['auth'] as String),
      workingDirectory: json['workingDirectory'] as String? ?? '',
    );
  }
}

/// Secrets for one profile. Stored in platform secure storage.
class SshCredentials {
  const SshCredentials({this.password, this.privateKeyPem, this.passphrase});

  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
}
