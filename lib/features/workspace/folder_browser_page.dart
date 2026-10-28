import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/claude/claude_command.dart';
import '../../core/remote/folder_label.dart';
import '../../core/remote/remote_directory.dart';
import '../../core/ssh/ssh_gateway.dart';
import '../../core/storage/server_repository.dart';
import '../servers/server_profile.dart';

/// Browses folders on the VPS. Pops with the chosen absolute path.
class FolderBrowserPage extends StatefulWidget {
  const FolderBrowserPage({
    super.key,
    required this.profile,
    required this.repository,
    required this.gateway,
  });

  final ServerProfile profile;
  final ServerRepository repository;
  final SshGateway gateway;

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  RemoteDirectory? _directory;
  String? _error;
  bool _loading = true;
  late List<String> _favorites = widget.repository.favoriteFolders(
    widget.profile.id,
  );
  late final List<String> _recents = widget.repository.recentFolders(
    widget.profile.id,
  );

  @override
  void initState() {
    super.initState();
    _open(widget.profile.workingDirectory);
  }

  void _enter(String path) => Navigator.of(context).pop(path);

  void _toggleFavorite(String path) {
    widget.repository.toggleFavoriteFolder(widget.profile.id, path);
    setState(() {
      _favorites = widget.repository.favoriteFolders(widget.profile.id);
    });
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final credentials = await widget.repository.credentialsFor(
        widget.profile.id,
      );
      final client = await widget.gateway.connect(widget.profile, credentials);
      try {
        final session = await client.execute(buildListDirectoryCommand(path));
        final output = await utf8.decoder.bind(session.stdout).join();
        final stderr = await utf8.decoder.bind(session.stderr).join();
        await session.done;
        if (session.exitCode != 0) {
          throw Exception(stderr.trim().isEmpty ? 'Cannot open $path' : stderr);
        }
        if (!mounted) return;
        setState(() {
          _directory = RemoteDirectory.parse(output);
          _loading = false;
        });
      } finally {
        client.close();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final directory = _directory;
    final isCurrentFavorite =
        directory != null && _favorites.contains(directory.path);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose folder'),
        actions: [
          IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.home_outlined),
            onPressed: () => _open(''),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_favorites.isNotEmpty)
            _QuickFolderRow(
              title: 'Favorites',
              icon: Icons.star,
              paths: _favorites,
              onTap: _enter,
            ),
          if (_recents.isNotEmpty)
            _QuickFolderRow(
              title: 'Recent',
              icon: Icons.history,
              paths: _recents,
              onTap: _enter,
            ),
          if (_favorites.isNotEmpty || _recents.isNotEmpty)
            const Divider(height: 1),
          if (directory != null)
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(directory.path, overflow: TextOverflow.ellipsis),
              subtitle: Text('${directory.folders.length} folders'),
              trailing: IconButton(
                tooltip: isCurrentFavorite
                    ? 'Remove from favorites'
                    : 'Add to favorites',
                icon: Icon(isCurrentFavorite ? Icons.star : Icons.star_border),
                onPressed: () => _toggleFavorite(directory.path),
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _buildList(directory)),
        ],
      ),
      bottomNavigationBar: directory == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text('Open Claude here'),
                  onPressed: () => Navigator.of(context).pop(directory.path),
                ),
              ),
            ),
    );
  }

  Widget _buildList(RemoteDirectory? directory) {
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
                onPressed: () => _open(widget.profile.workingDirectory),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final current = directory!;
    final entries = [if (current.parent != null) '..', ...current.folders];
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final name = entries[index];
        final isUp = name == '..';
        return ListTile(
          leading: Icon(isUp ? Icons.arrow_upward : Icons.folder_outlined),
          title: Text(name),
          onTap: () => _open(isUp ? current.parent! : '${current.path}/$name'),
        );
      },
    );
  }
}

/// A horizontally scrollable row of quick-access folders (favorites or
/// recents), each entering that folder directly on tap.
class _QuickFolderRow extends StatelessWidget {
  const _QuickFolderRow({
    required this.title,
    required this.icon,
    required this.paths,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final List<String> paths;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text(title, style: Theme.of(context).textTheme.labelMedium),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: paths.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final path = paths[index];
              return ActionChip(
                avatar: Icon(icon, size: 16),
                label: Text(folderLabel(path)),
                tooltip: path,
                onPressed: () => onTap(path),
              );
            },
          ),
        ),
      ],
    );
  }
}
