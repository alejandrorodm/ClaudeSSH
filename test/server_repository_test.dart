import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/core/storage/server_repository.dart';
import 'package:claude_ssh/features/servers/server_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
}
