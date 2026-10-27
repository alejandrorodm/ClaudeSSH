import 'package:flutter/services.dart';

/// Starts and stops the Android foreground service that keeps this process
/// alive (and the SSH sessions connected) while the app is backgrounded.
///
/// The service holds no session state of its own — see
/// `SshForegroundService.kt` — so start/stop are safe to call repeatedly or
/// redundantly; they only toggle whether the ongoing notification exists.
class ForegroundServiceController {
  static const _channel = MethodChannel(
    'dev.zoiyo.claude_ssh/foreground_service',
  );

  Future<void> start() => _channel.invokeMethod('start').catchError((_) {});

  Future<void> stop() => _channel.invokeMethod('stop').catchError((_) {});
}
