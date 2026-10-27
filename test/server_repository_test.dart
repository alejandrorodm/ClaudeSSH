import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/core/storage/server_repository.dart';
import 'package:claude_ssh/features/servers/server_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // save()/credentialsFor() touch FlutterSecureStorage's platform channel,
  // which has no real implementation in a plain `dart test` environment.
  // Back it with a tiny in-memory store so those calls behave like the
  // real plugin instead of throwing MissingPluginException.
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        final key = (call.arguments as Map?)?['key'] as String?;
        switch (call.method) {
          case 'write':
            secureStore[key!] = (call.arguments as Map)['value'] as String;
            return null;
          case 'read':
            return secureStore[key];
          case 'delete':
            secureStore.remove(key);
            return null;
          case 'containsKey':
            return secureStore.containsKey(key);
          case 'readAll':
            return secureStore;
          case 'deleteAll':
            secureStore.clear();
            return null;
          case 'isProtectedDataAvailable':
            return true;
          default:
            return null;
        }
      });

  test('the first server can be added when nothing is stored yet', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    final servers = await repository.loadAll();
    expect(
      () => servers.add(
        const ServerProfile(
          id: '1',
          name: 'VPS',
          host: 'example.com',
          port: 22,
          username: 'zoiyo',
          auth: AuthMethod.privateKey,
        ),
      ),
      returnsNormally,
    );
  });

  test('terminal font size defaults and stays within bounds', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    expect(
      repository.terminalFontSize(),
      ServerRepository.defaultTerminalFontSize,
    );
    await repository.setTerminalFontSize(100);
    expect(repository.terminalFontSize(), ServerRepository.maxTerminalFontSize);
    await repository.setTerminalFontSize(1);
    expect(repository.terminalFontSize(), ServerRepository.minTerminalFontSize);
  });

  group('export / import', () {
    Future<ServerRepository> freshRepository() async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      return ServerRepository(preferences, const FlutterSecureStorage());
    }

    const profile = ServerProfile(
      id: 'original-id',
      name: 'VPS',
      host: 'example.com',
      port: 22,
      username: 'zoiyo',
      auth: AuthMethod.privateKey,
      workingDirectory: '~/app',
    );

    test('exported JSON never contains a secret field', () async {
      final repository = await freshRepository();
      await repository.save(
        profile,
        const SshCredentials(privateKeyPem: 'SECRET-KEY-MATERIAL'),
      );

      final json = await repository.exportProfilesJson();

      expect(json, isNot(contains('SECRET-KEY-MATERIAL')));
      expect(json, contains('example.com'));
    });

    test(
      'importing adds servers with new ids, never overwriting by id',
      () async {
        final source = await freshRepository();
        await source.save(profile, const SshCredentials());
        final json = await source.exportProfilesJson();

        final target = await freshRepository();
        await target.save(
          profile.copyWith(name: 'Existing server with the same id'),
          const SshCredentials(),
        );

        final count = await target.importProfiles(json);
        final servers = await target.loadAll();

        expect(count, 1);
        expect(servers, hasLength(2));
        expect(servers.map((s) => s.id).toSet(), hasLength(2));
        expect(
          servers.firstWhere((s) => s.id == 'original-id').name,
          'Existing server with the same id',
        );
        expect(
          servers.any((s) => s.name == 'VPS' && s.id != 'original-id'),
          isTrue,
        );
      },
    );

    test('rejects a file that is not a Claude SSH export', () async {
      final repository = await freshRepository();
      expect(
        () => repository.importProfiles('{"not": "an export"}'),
        throwsFormatException,
      );
      expect(await repository.loadAll(), isEmpty);
    });
  });
}
