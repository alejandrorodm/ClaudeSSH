import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/background/foreground_service.dart';
import 'core/notifications/agent_notifier.dart';
import 'core/shortcuts/launcher_shortcuts.dart';
import 'core/ssh/ssh_gateway.dart';
import 'core/storage/known_hosts_preferences.dart';
import 'core/storage/server_repository.dart';
import 'features/lock/lock_gate.dart';
import 'features/servers/server_profile.dart';
import 'features/servers/servers_page.dart';
import 'features/workspace/workspace_page.dart';

/// Lets the "resume last session" launcher shortcut navigate from outside
/// any widget's own BuildContext.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final secureStorage = const FlutterSecureStorage();
  final knownHosts = KnownHostsPreferences(preferences);
  final repository = ServerRepository(preferences, secureStorage);
  final gateway = SshGateway(knownHosts);
  final notifier = AgentNotifier(FlutterLocalNotificationsPlugin());
  final shortcuts = LauncherShortcuts(repository);

  Future<void> openWorkspace(String serverId, String directory) async {
    final profiles = await repository.loadAll();
    ServerProfile? profile;
    for (final candidate in profiles) {
      if (candidate.id == serverId) profile = candidate;
    }
    if (profile == null) return; // the server was removed since
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => WorkspacePage(
          profile: profile!,
          repository: repository,
          gateway: gateway,
          initialDirectory: directory,
        ),
      ),
    );
  }

  shortcuts.initialize(
    (last) => openWorkspace(last.serverId, last.directory),
  );

  runApp(
    AppServices(
      repository: repository,
      gateway: gateway,
      notifier: notifier,
      foregroundService: ForegroundServiceController(),
      launcherShortcuts: shortcuts,
      child: const PhoneSshApp(),
    ),
  );

  // After the first frame: a slow or failed permission prompt must never
  // block the UI from appearing.
  notifier
      .init(
        onTap: (payload) {
          final parsed = parseSessionPayload(payload);
          if (parsed == null) return;
          openWorkspace(parsed.serverId, parsed.directory);
        },
      )
      .catchError((Object _) {});
  shortcuts.refresh();
}

/// Makes the repository and SSH gateway available to every screen.
class AppServices extends InheritedWidget {
  const AppServices({
    super.key,
    required this.repository,
    required this.gateway,
    required this.notifier,
    required this.foregroundService,
    required this.launcherShortcuts,
    required super.child,
  });

  final ServerRepository repository;
  final SshGateway gateway;
  final AgentNotifier notifier;
  final ForegroundServiceController foregroundService;
  final LauncherShortcuts launcherShortcuts;

  static AppServices of(BuildContext context) {
    final services = context.dependOnInheritedWidgetOfExactType<AppServices>();
    assert(services != null, 'AppServices not found in widget tree');
    return services!;
  }

  @override
  bool updateShouldNotify(AppServices oldWidget) => false;
}

class PhoneSshApp extends StatelessWidget {
  const PhoneSshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Claude SSH',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD97757)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD97757),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Builder(
        builder: (context) => LockGate(
          repository: AppServices.of(context).repository,
          child: const ServersPage(),
        ),
      ),
    );
  }
}
