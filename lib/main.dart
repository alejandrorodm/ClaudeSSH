import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/background/foreground_service.dart';
import 'core/notifications/agent_notifier.dart';
import 'core/ssh/ssh_gateway.dart';
import 'core/storage/known_hosts_preferences.dart';
import 'core/storage/server_repository.dart';
import 'features/lock/lock_gate.dart';
import 'features/servers/servers_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final secureStorage = const FlutterSecureStorage();
  final knownHosts = KnownHostsPreferences(preferences);
  final notifier = AgentNotifier(FlutterLocalNotificationsPlugin());

  runApp(
    AppServices(
      repository: ServerRepository(preferences, secureStorage),
      gateway: SshGateway(knownHosts),
      notifier: notifier,
      foregroundService: ForegroundServiceController(),
      child: const PhoneSshApp(),
    ),
  );

  // After the first frame: a slow or failed permission prompt must never
  // block the UI from appearing.
  notifier.init().catchError((Object _) {});
}

/// Makes the repository and SSH gateway available to every screen.
class AppServices extends InheritedWidget {
  const AppServices({
    super.key,
    required this.repository,
    required this.gateway,
    required this.notifier,
    required this.foregroundService,
    required super.child,
  });

  final ServerRepository repository;
  final SshGateway gateway;
  final AgentNotifier notifier;
  final ForegroundServiceController foregroundService;

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
