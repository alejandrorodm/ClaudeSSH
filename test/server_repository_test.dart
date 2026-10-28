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

  test('last session is unset until a session is remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    expect(repository.lastSession(), isNull);
    await repository.setLastSession(
      serverId: 'srv-1',
      serverName: 'My VPS',
      directory: '~/project',
    );
    final last = repository.lastSession();
    expect(last!.serverId, 'srv-1');
    expect(last.serverName, 'My VPS');
    expect(last.directory, '~/project');
  });

  test('open tabs are unset until a workspace remembers some', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    expect(repository.openTabs('srv-1'), isEmpty);
    expect(repository.openTabsActiveIndex('srv-1'), 0);
  });

  test('open tabs round-trip, including which one was active', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    await repository.setOpenTabs(
      'srv-1',
      const [
        OpenTab(directory: '~/project-a', mode: 'build'),
        OpenTab(directory: '~/project-b', mode: 'plan'),
      ],
      active: 1,
    );

    final tabs = repository.openTabs('srv-1');
    expect(tabs, hasLength(2));
    expect(tabs[0].directory, '~/project-a');
    expect(tabs[0].mode, 'build');
    expect(tabs[1].directory, '~/project-b');
    expect(tabs[1].mode, 'plan');
    expect(repository.openTabsActiveIndex('srv-1'), 1);
  });

  test('closing every tab clears what was remembered for that server', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    await repository.setOpenTabs('srv-1', const [
      OpenTab(directory: '~/project-a', mode: 'build'),
    ]);
    await repository.setOpenTabs('srv-1', const []);

    expect(repository.openTabs('srv-1'), isEmpty);
    expect(repository.openTabsActiveIndex('srv-1'), 0);
  });

  test('open tabs for one server never leak into another', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    await repository.setOpenTabs('srv-1', const [
      OpenTab(directory: '~/project-a', mode: 'build'),
    ]);

    expect(repository.openTabs('srv-2'), isEmpty);
  });

  test('a folder starts out not favorite and toggles on and off', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    expect(repository.isFavoriteFolder('srv-1', '~/project'), isFalse);
    await repository.toggleFavoriteFolder('srv-1', '~/project');
    expect(repository.isFavoriteFolder('srv-1', '~/project'), isTrue);
    expect(repository.favoriteFolders('srv-1'), ['~/project']);

    await repository.toggleFavoriteFolder('srv-1', '~/project');
    expect(repository.isFavoriteFolder('srv-1', '~/project'), isFalse);
    expect(repository.favoriteFolders('srv-1'), isEmpty);
  });

  test('favorite folders for one server never leak into another', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    await repository.toggleFavoriteFolder('srv-1', '~/project');
    expect(repository.favoriteFolders('srv-2'), isEmpty);
  });

  test('recent folders are empty until one is remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    expect(repository.recentFolders('srv-1'), isEmpty);
  });

  test('a re-opened recent folder moves back to the front, not duplicated', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    await repository.rememberRecentFolder('srv-1', '~/a');
    await repository.rememberRecentFolder('srv-1', '~/b');
    await repository.rememberRecentFolder('srv-1', '~/a');

    expect(repository.recentFolders('srv-1'), ['~/a', '~/b']);
  });

  test('recent folders are capped so the list cannot grow forever', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    for (var i = 0; i < 12; i++) {
      await repository.rememberRecentFolder('srv-1', '~/project-$i');
    }

    final recents = repository.recentFolders('srv-1');
    expect(recents.length, ServerRepository.maxRecentFolders);
    expect(recents.first, '~/project-11');
  });

  test('quick commands default to the built-in set until changed', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    expect(repository.quickCommands(), [
      '/clear',
      '/compact',
      '/usage',
      '/model',
    ]);

    await repository.setQuickCommands(['/clear', '/my-command']);
    expect(repository.quickCommands(), ['/clear', '/my-command']);
  });

  test('biometric lock is off by default and persists once set', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    expect(repository.biometricLockEnabled(), isFalse);
    await repository.setBiometricLockEnabled(true);
    expect(repository.biometricLockEnabled(), isTrue);
    await repository.setBiometricLockEnabled(false);
    expect(repository.biometricLockEnabled(), isFalse);
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
