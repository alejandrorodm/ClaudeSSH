import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/features/workspace/terminal_log.dart';

void main() {
  group('findMatchingLines', () {
    test('finds case-insensitive matches', () {
      final lines = ['Hello World', 'nothing here', 'say HELLO again'];
      expect(findMatchingLines(lines, 'hello'), [0, 2]);
    });

    test('returns nothing for a blank query', () {
      expect(findMatchingLines(['a', 'b'], '   '), isEmpty);
    });

    test('returns nothing when there is no match', () {
      expect(findMatchingLines(['a', 'b'], 'zzz'), isEmpty);
    });
  });
}
