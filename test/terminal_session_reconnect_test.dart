import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/features/workspace/terminal_session.dart';

void main() {
  test('there is one reconnect delay per allowed attempt', () {
    expect(autoReconnectDelays.length, maxAutoReconnectAttempts);
  });

  test('reconnect delays grow, so retries do not hammer the server', () {
    for (var i = 1; i < autoReconnectDelays.length; i++) {
      expect(
        autoReconnectDelays[i].compareTo(autoReconnectDelays[i - 1]),
        greaterThan(0),
      );
    }
  });
}
