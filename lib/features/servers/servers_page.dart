import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/remote/folder_label.dart';
import '../../main.dart';
import '../workspace/workspace_page.dart';
import 'server_form_page.dart';
import 'server_profile.dart';
import 'settings_page.dart';

/// One favorite folder shortcut on the home screen, resolved across every
/// saved server.
class _FavoriteEntry {
  const _FavoriteEntry(this.server, this.path);

  final ServerProfile server;
  final String path;
}

class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  Future<List<ServerProfile>>? _servers;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _servers ??= _load();
  }

  Future<List<ServerProfile>> _load() {
    return AppServices.of(context).repository.loadAll();
  }

  void _reload() => setState(() => _servers = _load());

  Future<void> _openForm({
    ServerProfile? existing,
    ServerProfile? template,
  }) async {
    final services = AppServices.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServerFormPage(
          existing: existing,
          template: template,
          repository: services.repository,
        ),
      ),
    );
    _reload();
  }

  void _openChat(ServerProfile profile, {String? initialDirectory}) {
    final services = AppServices.of(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkspacePage(
          profile: profile,
          repository: services.repository,
          gateway: services.gateway,
          initialDirectory: initialDirectory,
        ),
      ),
    );
  }

  List<_FavoriteEntry> _favoriteEntries(List<ServerProfile> servers) {
    final repository = AppServices.of(context).repository;
    return [
      for (final server in servers)
        for (final path in repository.favoriteFolders(server.id))
          _FavoriteEntry(server, path),
    ];
  }

  Future<void> _export() async {
    final repository = AppServices.of(context).repository;
    final json = await repository.exportProfilesJson();
    if (!mounted) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            utf8.encode(json),
            name: 'claude-ssh-servers.json',
            mimeType: 'application/json',
          ),
        ],
        subject: 'Claude SSH servers',
      ),
    );
  }

  Future<void> _import() async {
    final repository = AppServices.of(context).repository;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null || !mounted) return;
    try {
      final json = await picked.xFile.readAsString();
      final count = await repository.importProfiles(json);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$count server${count == 1 ? '' : 's'} imported. '
            'Passwords and keys were not included — add them again.',
          ),
        ),
      );
      _reload();
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Servers'),
        actions: [
          IconButton(
            tooltip: 'Import servers',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: _import,
          ),
          IconButton(
            tooltip: 'Export servers (no passwords or keys)',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _export,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsPage(
                  repository: AppServices.of(context).repository,
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: FutureBuilder<List<ServerProfile>>(
        future: _servers,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final servers = snapshot.data!;
          if (servers.isEmpty) {
            return const _EmptyState();
          }
          final favorites = _favoriteEntries(servers);
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: servers.length + (favorites.isEmpty ? 0 : 1),
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              if (favorites.isNotEmpty) {
                if (index == 0) {
                  return _FavoriteFoldersRow(
                    favorites: favorites,
                    onTap: (entry) =>
                        _openChat(entry.server, initialDirectory: entry.path),
                  );
                }
                index -= 1;
              }
              final server = servers[index];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: const CircleAvatar(child: Icon(Icons.dns_outlined)),
                  title: Text(server.name),
                  subtitle: Text('${server.username}@${server.endpoint}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Duplicate',
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () => _openForm(template: server),
                      ),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _openForm(existing: server),
                      ),
                    ],
                  ),
                  onTap: () => _openChat(server),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _FavoriteFoldersRow extends StatelessWidget {
  const _FavoriteFoldersRow({required this.favorites, required this.onTap});

  final List<_FavoriteEntry> favorites;
  final ValueChanged<_FavoriteEntry> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(
            'Favorite folders',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: favorites.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final entry = favorites[index];
              return ActionChip(
                avatar: const Icon(Icons.star, size: 16),
                label: Text('${entry.server.name} · ${folderLabel(entry.path)}'),
                tooltip: entry.path,
                onPressed: () => onTap(entry),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('No servers yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Add your VPS to start chatting with Claude Code running on it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
