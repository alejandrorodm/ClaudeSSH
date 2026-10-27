import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../features/servers/server_profile.dart';

/// Remembers the host key fingerprint seen for each endpoint.
abstract interface class KnownHostsStore {
  Future<String?> fingerprintFor(String endpoint);
  Future<void> save(String endpoint, String fingerprint);
}

class HostKeyChangedException implements Exception {
  const HostKeyChangedException({
    required this.endpoint,
    required this.expected,
    required this.actual,
  });

  final String endpoint;
  final String expected;
  final String actual;

  @override
  String toString() =>
      'The host key for $endpoint has changed. Expected $expected, got $actual. '
      'Refusing to connect.';
}

class SshGateway {
  SshGateway(this._knownHosts);

  final KnownHostsStore _knownHosts;

  static const _connectTimeout = Duration(seconds: 15);

  Future<SSHClient> connect(
    ServerProfile profile,
    SshCredentials credentials,
  ) async {
    // Parse the key before opening the socket so bad input fails fast.
    final identities = profile.auth == AuthMethod.privateKey
        ? SSHKeyPair.fromPem(
            credentials.privateKeyPem ?? '',
            _emptyToNull(credentials.passphrase),
          )
        : null;

    final endpoint = profile.endpoint;
    HostKeyChangedException? hostKeyError;

    final socket = await SSHSocket.connect(
      profile.host,
      profile.port,
      timeout: _connectTimeout,
    );

    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: profile.auth == AuthMethod.password
          ? () => credentials.password
          : null,
      onVerifyHostKey: (type, fingerprint) async {
        try {
          return await _verifyHostKey(endpoint, fingerprint);
        } on HostKeyChangedException catch (error) {
          hostKeyError = error;
          return false;
        }
      },
    );

    try {
      await client.authenticated;
      return client;
    } catch (error) {
      client.close();
      throw hostKeyError ?? error;
    }
  }

  Future<bool> _verifyHostKey(String endpoint, Uint8List fingerprint) async {
    final actual = _formatFingerprint(fingerprint);
    final expected = await _knownHosts.fingerprintFor(endpoint);

    if (expected == null) {
      // Trust on first use: the fingerprint is stored and checked from now on.
      await _knownHosts.save(endpoint, actual);
      return true;
    }
    if (expected == actual) return true;

    throw HostKeyChangedException(
      endpoint: endpoint,
      expected: expected,
      actual: actual,
    );
  }

  String _formatFingerprint(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(':');

  String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;
}
