import 'dart:typed_data' show Int64List;
import 'dart:ui' show Color;

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
  static const _urgentChannelId = 'agents_urgent';
  static const _urgentChannelName = 'Claude needs you';

  /// Brand accent (matches the app's seed color), so notifications stand
  /// out from the system's flat gray default instead of blending in.
  static const _accentColor = Color(0xFFD97757);

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
        description: 'Sessions that finish or run into an error',
        importance: Importance.high,
      ),
    );
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        _urgentChannelId,
        _urgentChannelName,
        description: 'Claude is waiting on your input',
        // A channel's importance and vibration are locked in once created
        // (Android 8+), hence its own channel: this is the one case worth
        // interrupting the user for, so it gets the loudest treatment.
        importance: Importance.max,
        vibrationPattern: Int64List.fromList([0, 250, 150, 250, 150, 400]),
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
    final urgent = event == AgentEvent.needsYou;
    // Notifications are best effort: a failure here must never reach the UI.
    return _plugin
        .show(
          id: id,
          title: title,
          body: body,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              urgent ? _urgentChannelId : _channelId,
              urgent ? _urgentChannelName : _channelName,
              icon: _iconFor(event),
              largeIcon: const DrawableResourceAndroidBitmap(
                'ic_notification_large',
              ),
              importance: urgent ? Importance.max : Importance.high,
              priority: urgent ? Priority.max : Priority.high,
              color: _accentColor,
              colorized: true,
              category: urgent ? AndroidNotificationCategory.reminder : null,
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
