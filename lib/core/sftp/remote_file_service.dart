import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:path_provider/path_provider.dart';

class RemoteEntry {
  const RemoteEntry({required this.name, required this.isDirectory, this.size});

  final String name;
  final bool isDirectory;

  /// Size in bytes; null for folders or when the server does not report it.
  final int? size;
}

/// Lists and downloads files over SFTP on an already connected [SSHClient].
class RemoteFileService {
  RemoteFileService(this._client);

  final SSHClient _client;
  SftpClient? _sftp;

  Future<SftpClient> get _sftpClient async => _sftp ??= await _client.sftp();

  /// Turns `~`, `~/x` and relative paths into absolute ones.
  Future<String> resolve(String path) async {
    final sftp = await _sftpClient;
    final home = await sftp.absolute('.');
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == '~') return home;
    if (trimmed.startsWith('~/')) return '$home/${trimmed.substring(2)}';
    if (trimmed.startsWith('/')) return trimmed;
    return '$home/$trimmed';
  }

  /// Folders first, then files, each sorted case-insensitively.
  Future<List<RemoteEntry>> list(String path) async {
    final sftp = await _sftpClient;
    final names = await sftp.listdir(path);
    final entries =
        [
          for (final name in names)
            if (name.filename != '.' && name.filename != '..')
              RemoteEntry(
                name: name.filename,
                isDirectory: name.attr.isDirectory,
                size: name.attr.isDirectory ? null : name.attr.size,
              ),
        ]..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    return entries;
  }

  /// Streams [remotePath] into the app's download folder and returns the file.
  /// [onProgress] receives bytes received so far and the total, when known.
  Future<File> download(
    String remotePath, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final sftp = await _sftpClient;
    final total = (await sftp.stat(remotePath)).size;
    final target = await _uniqueTarget(remotePath.split('/').last);

    final remote = await sftp.open(remotePath);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in remote.read()) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
      await remote.close();
    }
    return target;
  }

  Future<File> _uniqueTarget(String name) async {
    final documents = await getApplicationDocumentsDirectory();
    final folder = Directory('${documents.path}/downloads')
      ..createSync(recursive: true);

    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var candidate = File('${folder.path}/$name');
    var counter = 2;
    while (candidate.existsSync()) {
      candidate = File('${folder.path}/$stem ($counter)$extension');
      counter++;
    }
    return candidate;
  }

  Future<void> close() async {
    await _sftp?.close();
    _sftp = null;
    _client.close();
  }
}
