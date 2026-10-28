import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/core/claude/claude_command.dart';
import 'package:claude_ssh/core/remote/remote_directory.dart';
import 'package:claude_ssh/features/servers/server_profile.dart';

void main() {
  group('buildLaunchCommand', () {
    test('starts claude with the chosen permission mode', () {
      final command = buildLaunchCommand(mode: ClaudeMode.plan);
      expect(command, contains('claude --permission-mode plan'));
    });

    test('maps Build to acceptEdits', () {
      final command = buildLaunchCommand(mode: ClaudeMode.build);
      expect(command, contains('--permission-mode acceptEdits'));
    });

    test('maps Bypass to bypassPermissions', () {
      final command = buildLaunchCommand(mode: ClaudeMode.bypass);
      expect(command, contains('--permission-mode bypassPermissions'));
    });

    test('defaults to Bypass when no mode is given', () {
      final command = buildLaunchCommand();
      expect(command, contains('--permission-mode bypassPermissions'));
    });

    test('resumes the conversation when asked', () {
      final command = buildLaunchCommand(continueConversation: true);
      expect(
        command,
        contains('--permission-mode bypassPermissions --continue'),
      );
    });

    test('wraps claude in a tmux session keyed by the directory, with a '
        'plain fallback when tmux is unavailable', () {
      final command = buildLaunchCommand(
        workingDirectory: '/srv/app',
        mode: ClaudeMode.plan,
      );
      expect(command, contains('cd -- \'/srv/app\' && if command -v tmux'));
      expect(
        command,
        contains(
          "exec tmux new-session -A -s claude_ssh__srv_app "
          "'claude --permission-mode plan'; ",
        ),
      );
      expect(command, contains('else exec claude --permission-mode plan; fi'));
    });

    test('forceRestart kills the existing tmux session before recreating '
        'it, so a mode switch actually takes effect', () {
      final command = buildLaunchCommand(
        workingDirectory: '/srv/app',
        forceRestart: true,
      );
      expect(
        command,
        contains(
          'tmux kill-session -t claude_ssh__srv_app 2>/dev/null; '
          'exec tmux new-session -A -s claude_ssh__srv_app',
        ),
      );
    });

    test('does not kill any tmux session without forceRestart', () {
      final command = buildLaunchCommand(workingDirectory: '/srv/app');
      expect(command, isNot(contains('kill-session')));
    });

    test('best-effort enables linger, so a systemd host does not kill the '
        'tmux server once the SSH login session ends', () {
      final command = buildLaunchCommand();
      expect(
        command,
        contains('loginctl enable-linger "\$(whoami)" >/dev/null 2>&1'),
      );
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

  group('buildKillSessionCommand', () {
    test('kills the tmux session keyed by the directory', () {
      expect(
        buildKillSessionCommand('/srv/app'),
        'tmux kill-session -t claude_ssh__srv_app 2>/dev/null; true',
      );
    });

    test('uses the same session name as buildLaunchCommand for the same '
        'directory', () {
      final launch = buildLaunchCommand(workingDirectory: '~/a/b');
      final kill = buildKillSessionCommand('~/a/b');
      expect(launch, contains(tmuxSessionName('~/a/b')));
      expect(kill, contains(tmuxSessionName('~/a/b')));
    });
  });

  group('tmuxSessionName', () {
    test('sanitizes characters a tmux session name cannot contain', () {
      expect(tmuxSessionName('/srv/app'), 'claude_ssh__srv_app');
      expect(tmuxSessionName("/srv/it's"), 'claude_ssh__srv_it_s');
    });

    test('falls back to home when no directory is given', () {
      expect(tmuxSessionName(null), 'claude_ssh__');
      expect(tmuxSessionName(''), 'claude_ssh__');
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
