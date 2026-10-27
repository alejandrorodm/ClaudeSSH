import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// What happened to a Claude session that the user should hear about.
enum AgentEvent { finished, failed, needsYou }

/// Shows Claude session updates in the Android notification shade.
///
/// The small icon is the mascot in the status bar, drawn for the event.
class AgentNotifier {
  AgentNotifier(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static const _channelId = 'agents';
  static const _channelName = 'Claude agents';

  Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_claude_done'),
      ),
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Sessions that finish or need your input',
        importance: Importance.high,
      ),
    );
    await android?.requestNotificationsPermission();
  }

  Future<void> show({
    required int id,
    required AgentEvent event,
    required String title,
    required String body,
  }) {
    // Notifications are best effort: a failure here must never reach the UI.
    return _plugin
        .show(
          id: id,
          title: title,
          body: body,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              icon: _iconFor(event),
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        )
        .catchError((Object _) {});
  }

  String _iconFor(AgentEvent event) => switch (event) {
    AgentEvent.finished || AgentEvent.failed => 'ic_stat_claude_done',
    AgentEvent.needsYou => 'ic_stat_claude_attention',
  };
}
