import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/sftp/remote_file_service.dart';
import '../../core/ssh/ssh_gateway.dart';
import '../../core/storage/server_repository.dart';
import '../servers/server_profile.dart';

/// Browses files on the VPS and downloads the ones you tap.
class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({
    super.key,
    required this.profile,
    required this.repository,
    required this.gateway,
    required this.startPath,
  });

  final ServerProfile profile;
  final ServerRepository repository;
  final SshGateway gateway;

  /// Folder to open first. `~` and empty mean the login directory.
  final String startPath;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  RemoteFileService? _service;
  String _path = '';
  List<RemoteEntry> _entries = const [];
  String? _error;
  bool _loading = true;

  _Download? _download;
  _Upload? _upload;

  bool get _busy => _download != null || _upload != null;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final credentials = await widget.repository.credentialsFor(
        widget.profile.id,
      );
      final client = await widget.gateway.connect(widget.profile, credentials);
      if (!mounted) {
        client.close();
        return;
      }
      _service = RemoteFileService(client);
      await _open(widget.startPath);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _open(String path) async {
    final service = _service;
    if (service == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resolved = await service.resolve(path);
      final entries = await service.list(resolved);
      if (!mounted) return;
      setState(() {
        _path = resolved;
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _error = error.toString();
      _loading = false;
    });
  }

  String? get _parent {
    if (_path.isEmpty || _path == '/') return null;
    final index = _path.lastIndexOf('/');
    return index <= 0 ? '/' : _path.substring(0, index);
  }

  Future<void> _tap(RemoteEntry entry) async {
    if (entry.isDirectory) {
      await _open('$_path/${entry.name}');
      return;
    }
    await _downloadFile(entry);
  }

  Future<void> _uploadFile() async {
    final service = _service;
    if (service == null || _busy) return;
    final picked = await FilePicker.pickFile();
    if (picked?.path == null || !mounted) return;
    final localPath = picked!.path!;
    final name = picked.name;

    setState(() => _upload = _Upload(name, 0, picked.lengthSync()));
    try {
      await service.upload(
        localPath,
        _path,
        name,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() => _upload = _Upload(name, sent, total));
        },
      );
      if (!mounted) return;
      setState(() => _upload = null);
      await _open(_path);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Uploaded $name')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _upload = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Upload failed: $error')));
    }
  }

  Future<void> _downloadFile(RemoteEntry entry) async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _download = _Download(entry.name, 0, entry.size));
    try {
      final file = await service.download(
        '$_path/${entry.name}',
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() => _download = _Download(entry.name, received, total));
        },
      );
      if (!mounted) return;
      setState(() => _download = null);
      _showDownloaded(file, entry);
    } catch (error) {
      if (!mounted) return;
      setState(() => _download = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Download failed: $error')));
    }
  }

  void _showDownloaded(File file, RemoteEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                file.uri.pathSegments.last,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Downloaded ${formatBytes(entry.size ?? file.lengthSync())}',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.ios_share),
                label: const Text('Save or share'),
                onPressed: () {
                  Navigator.pop(context);
                  SharePlus.instance.share(
                    ShareParams(files: [XFile(file.path)]),
                  );
                },
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _service?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            tooltip: 'Upload a file here',
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: _service == null || _busy ? null : _uploadFile,
          ),
          IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.home_outlined),
            onPressed: _service == null || _loading ? null : () => _open(''),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_upload != null) _UploadBar(upload: _upload!),
          if (_download != null) _DownloadBar(download: _download!),
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(
              _path.isEmpty ? '…' : _path,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () =>
                    _service == null ? _connect() : _open(widget.startPath),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final parent = _parent;
    return ListView.builder(
      itemCount: _entries.length + (parent == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (parent != null && index == 0) {
          return ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('..'),
            onTap: () => _open(parent),
          );
        }
        final entry = _entries[index - (parent == null ? 0 : 1)];
        return ListTile(
          leading: Icon(
            entry.isDirectory
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
          ),
          title: Text(entry.name, overflow: TextOverflow.ellipsis),
          subtitle: entry.size == null ? null : Text(formatBytes(entry.size!)),
          trailing: entry.isDirectory
              ? const Icon(Icons.chevron_right)
              : const Icon(Icons.download_outlined),
          onTap: _busy ? null : () => _tap(entry),
        );
      },
    );
  }
}

class _Download {
  const _Download(this.name, this.received, this.total);

  final String name;
  final int received;
  final int? total;
}

class _DownloadBar extends StatelessWidget {
  const _DownloadBar({required this.download});

  final _Download download;

  @override
  Widget build(BuildContext context) {
    final total = download.total;
    final progress = (total == null || total == 0)
        ? null
        : download.received / total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Downloading ${download.name}'
            ' — ${formatBytes(download.received)}'
            '${total == null ? '' : ' of ${formatBytes(total)}'}',
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress),
        ],
      ),
    );
  }
}

class _Upload {
  const _Upload(this.name, this.sent, this.total);

  final String name;
  final int sent;
  final int? total;
}

class _UploadBar extends StatelessWidget {
  const _UploadBar({required this.upload});

  final _Upload upload;

  @override
  Widget build(BuildContext context) {
    final total = upload.total;
    final progress = (total == null || total == 0) ? null : upload.sent / total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Uploading ${upload.name}'
            ' — ${formatBytes(upload.sent)}'
            '${total == null ? '' : ' of ${formatBytes(total)}'}',
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress),
        ],
      ),
    );
  }
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}
