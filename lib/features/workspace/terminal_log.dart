/// Case-insensitive line search over the terminal's plain text, used by the
/// search sheet so the user can find and copy something Claude printed
/// without scrolling through the live view by hand.
List<int> findMatchingLines(List<String> lines, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return [];
  return [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].toLowerCase().contains(needle)) i,
  ];
}
