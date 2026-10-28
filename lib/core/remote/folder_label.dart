/// Last segment of a remote folder [path], for a compact display label
/// (e.g. a tab title or a quick-access chip).
String folderLabel(String path) {
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  if (trimmed.isEmpty || trimmed == '~') return '~';
  return trimmed.split('/').last;
}
