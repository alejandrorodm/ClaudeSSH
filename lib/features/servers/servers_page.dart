import 'package:flutter/material.dart';

import '../../main.dart';
import '../workspace/workspace_page.dart';
import 'server_form_page.dart';
import 'server_profile.dart';

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

  void _openChat(ServerProfile profile) {
    final services = AppServices.of(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkspacePage(
          profile: profile,
          repository: services.repository,
          gateway: services.gateway,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
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
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: servers.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
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
