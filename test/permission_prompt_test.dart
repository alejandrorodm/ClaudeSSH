import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/features/workspace/permission_prompt.dart';

void main() {
  group('detectPermissionOptions', () {
    test('detects a standard three-option permission prompt', () {
      const text = '''
Bash(rm file.txt)
Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again this session
  3. No, and tell Claude what to do differently
''';
      expect(detectPermissionOptions(text), [1, 2, 3]);
    });

    test('detects a two-option prompt without a cursor glyph', () {
      const text = '1. Yes\n2. No';
      expect(detectPermissionOptions(text), [1, 2]);
    });

    test('ignores a single numbered line', () {
      expect(detectPermissionOptions('1. just one line'), isEmpty);
    });

    test('ignores an unrelated numbered list elsewhere in the output', () {
      const text = '''
Steps:
1. First
2. Second
3. Third

Some unrelated trailing text that is not a menu.
''';
      expect(detectPermissionOptions(text, lookback: 2), isEmpty);
    });

    test('ignores plain text with no digits', () {
      expect(detectPermissionOptions('just chatting with Claude'), isEmpty);
    });

    test('requires the run to start at 1 or 2', () {
      expect(detectPermissionOptions('5. Yes\n6. No'), isEmpty);
    });
  });
}
