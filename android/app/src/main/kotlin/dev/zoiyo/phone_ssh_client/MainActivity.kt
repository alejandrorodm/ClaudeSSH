package dev.zoiyo.phone_ssh_client

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity (not plain FlutterActivity) because local_auth's
 * biometric prompt needs a FragmentActivity host.
 */
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "dev.zoiyo.claude_ssh/foreground_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startInForeground()
                        result.success(null)
                    }
                    "stop" -> {
                        // Must go through plain stopService(), never
                        // startForegroundService(): on Android 8+, that call
                        // requires Service.startForeground() within 5
                        // seconds no matter what the intent is for, and a
                        // stop never calls it — the OS then kills the whole
                        // app with ForegroundServiceDidNotStartInTimeException.
                        // Safe to call even if the service isn't running.
                        stopService(Intent(this, SshForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startInForeground() {
        val intent = Intent(this, SshForegroundService::class.java)
        intent.action = SshForegroundService.ACTION_START
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
