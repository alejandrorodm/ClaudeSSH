import 'dart:convert';

/// A directory listing read from the VPS.
class RemoteDirectory {
  const RemoteDirectory({required this.path, required this.folders});

  /// Absolute path, as reported by `pwd`.
  final String path;

  /// Subdirectory names, without the trailing slash, sorted case-insensitively.
  final List<String> folders;

  /// Parses the output of `buildListDirectoryCommand`: the first line is the
  /// path from `pwd`, then one `ls -1Ap` entry per line. Folders end with `/`.
  factory RemoteDirectory.parse(String output) {
    final lines = const LineSplitter().convert(output);
    if (lines.isEmpty) {
      throw const FormatException('Empty directory listing');
    }
    final folders =
        lines
            .skip(1)
            .where((line) => line.endsWith('/'))
            .map((line) => line.substring(0, line.length - 1))
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return RemoteDirectory(path: lines.first, folders: folders);
  }

  /// Parent of [path], or `null` at the root.
  String? get parent {
    if (path == '/') return null;
    final index = path.lastIndexOf('/');
    return index <= 0 ? '/' : path.substring(0, index);
  }
}
