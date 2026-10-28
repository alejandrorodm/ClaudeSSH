import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/core/notifications/agent_notifier.dart';

void main() {
  group('session payload', () {
    test('round-trips the server id and directory', () {
      final payload = encodeSessionPayload('srv-1', '~/project');
      final parsed = parseSessionPayload(payload);
      expect(parsed!.serverId, 'srv-1');
      expect(parsed.directory, '~/project');
    });

    test('keeps a directory that itself contains a separator', () {
      final payload = encodeSessionPayload('srv-1', '~/a|b');
      final parsed = parseSessionPayload(payload);
      expect(parsed!.serverId, 'srv-1');
      expect(parsed.directory, '~/a|b');
    });

    test('returns null for a payload with no separator', () {
      expect(parseSessionPayload('not-a-payload'), isNull);
    });
  });
}
