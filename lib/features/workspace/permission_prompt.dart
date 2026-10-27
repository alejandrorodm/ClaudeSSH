/// Detects a Claude Code numbered permission/choice prompt (for example
/// "1. Yes", "2. Yes, and don't ask again", "3. No") near the end of the
/// terminal, so the app can offer one-tap number buttons instead of making
/// the user type a digit on a phone keyboard.
///
/// This is a heuristic over plain text, not a protocol: it only looks at the
/// last [lookback] lines and requires at least two consecutive numbered
/// lines starting at 1 or 2, which keeps it from firing on unrelated
/// numbered lists earlier in a long response. Returns the sorted option
/// numbers, or an empty list when nothing prompt-like is there.
final _numberedLine = RegExp(r'^[\s❯>]*(\d)\.\s+\S');

List<int> detectPermissionOptions(String recentText, {int lookback = 15}) {
  final lines = recentText
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.isNotEmpty)
      .toList();
  final tail = lines.length > lookback
      ? lines.sublist(lines.length - lookback)
      : lines;

  final options = <int>[];
  for (final line in tail) {
    final match = _numberedLine.firstMatch(line);
    if (match == null) {
      // A numbered run must be contiguous: once it breaks, drop whatever
      // was collected so far and start looking again from here.
      if (options.isNotEmpty && options.length < 2) options.clear();
      continue;
    }
    final n = int.parse(match.group(1)!);
    if (options.isEmpty && n > 2) continue; // menus start at 1 or 2
    if (options.isNotEmpty && n != options.last + 1) {
      options.clear();
      if (n > 2) continue;
    }
    options.add(n);
  }
  return options.length >= 2 ? options : const [];
}
