import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// What happened to a Claude session that the user should hear about.
enum AgentEvent { finished, failed, needsYou }

/// Packs [serverId]/[directory] into the payload [AgentNotifier.show] sends,
/// so tapping the notification can jump straight to that session. Reversed
/// by [parseSessionPayload].
String encodeSessionPayload(String serverId, String directory) =>
    '$serverId|$directory';

/// Reverses [encodeSessionPayload], or null if [payload] isn't one (for
/// example a payload from a version of the app that shaped it differently).
({String serverId, String directory})? parseSessionPayload(String payload) {
  final separator = payload.indexOf('|');
  if (separator == -1) return null;
  return (
    serverId: payload.substring(0, separator),
    directory: payload.substring(separator + 1),
  );
}

/// Shows Claude session updates in the Android notification shade.
///
/// The small icon is the mascot in the status bar, drawn for the event.
class AgentNotifier {
  AgentNotifier(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static const _channelId = 'agents';
  static const _channelName = 'Claude agents';

  /// [onTap] fires with whatever [show] was given as [payload] when the
  /// user taps the notification, so the app can jump straight to that
  /// session's tab instead of just opening to wherever it was.
  Future<void> init({void Function(String payload)? onTap}) async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_claude_done'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null) onTap?.call(payload);
      },
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
    String? payload,
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
          payload: payload,
        )
        .catchError((Object _) {});
  }

  String _iconFor(AgentEvent event) => switch (event) {
    AgentEvent.finished || AgentEvent.failed => 'ic_stat_claude_done',
    AgentEvent.needsYou => 'ic_stat_claude_attention',
  };
}
