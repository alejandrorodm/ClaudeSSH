import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/features/files/file_browser_page.dart';

void main() {
  test('formats sizes in human units', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
  });
}
