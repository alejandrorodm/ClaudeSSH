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
                        launchService(serviceIntent(SshForegroundService.ACTION_START))
                        result.success(null)
                    }
                    "stop" -> {
                        launchService(serviceIntent(SshForegroundService.ACTION_STOP))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun serviceIntent(action: String): Intent {
        val intent = Intent(this, SshForegroundService::class.java)
        intent.action = action
        return intent
    }

    private fun launchService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
