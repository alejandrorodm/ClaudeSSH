import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/core/claude/claude_command.dart';
import 'package:claude_ssh/core/remote/remote_directory.dart';
import 'package:claude_ssh/features/servers/server_profile.dart';

void main() {
  group('buildLaunchCommand', () {
    test('starts an interactive claude with the chosen permission mode', () {
      final command = buildLaunchCommand(mode: ClaudeMode.plan);
      expect(command, endsWith('exec claude --permission-mode plan'));
    });

    test('maps Build to acceptEdits', () {
      final command = buildLaunchCommand();
      expect(command, endsWith('--permission-mode acceptEdits'));
    });

    test('resumes the conversation when asked', () {
      final command = buildLaunchCommand(continueConversation: true);
      expect(command, endsWith('--permission-mode acceptEdits --continue'));
    });

    test('changes to the working directory before exec', () {
      final command = buildLaunchCommand(workingDirectory: '/srv/app');
      expect(command, contains("cd -- '/srv/app' && exec claude"));
    });

    test('expands a leading tilde and quotes spaces', () {
      final command = buildLaunchCommand(workingDirectory: '~/projects/my app');
      expect(command, contains('cd -- "\$HOME"/\'projects/my app\' && '));
    });

    test('puts the user local bin on PATH for non-interactive shells', () {
      expect(
        buildLaunchCommand(),
        startsWith('export PATH="\$HOME/.local/bin:\$PATH"; '),
      );
    });

    test('quotes a single quote in the path', () {
      final command = buildLaunchCommand(workingDirectory: "/srv/it's");
      expect(command, contains(r"cd -- '/srv/it'\''s' && "));
    });
  });

  group('buildListDirectoryCommand', () {
    test('lists the given path with pwd and ls -1Ap', () {
      expect(
        buildListDirectoryCommand('/srv/app'),
        "export PATH=\"\$HOME/.local/bin:\$PATH\"; cd -- '/srv/app' && pwd && ls -1Ap",
      );
    });

    test('starts from the home directory when the path is empty', () {
      expect(buildListDirectoryCommand(''), contains('cd -- "\$HOME" && pwd'));
    });
  });

  group('RemoteDirectory.parse', () {
    test('reads the path and sorted folders, skipping files', () {
      final directory = RemoteDirectory.parse(
        '/home/zoiyo/app\nsrc/\nREADME.md\nDocs/\n.git/\n',
      );
      expect(directory.path, '/home/zoiyo/app');
      expect(directory.folders, ['.git', 'Docs', 'src']);
    });

    test('has a parent unless at root', () {
      expect(RemoteDirectory.parse('/home/zoiyo/app\n').parent, '/home/zoiyo');
      expect(RemoteDirectory.parse('/home\n').parent, '/');
      expect(RemoteDirectory.parse('/\n').parent, isNull);
    });
  });

  group('ServerProfile', () {
    test('round-trips through JSON without secrets', () {
      const profile = ServerProfile(
        id: '1',
        name: 'VPS',
        host: 'example.com',
        port: 2222,
        username: 'zoiyo',
        auth: AuthMethod.privateKey,
        workingDirectory: '~/app',
      );

      final restored = ServerProfile.fromJson(profile.toJson());

      expect(restored.endpoint, 'example.com:2222');
      expect(restored.auth, AuthMethod.privateKey);
      expect(restored.workingDirectory, '~/app');
      expect(restored.toJson().containsKey('password'), isFalse);
    });
  });
}
