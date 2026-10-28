package dev.zoiyo.phone_ssh_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Holds Android's foreground-service priority for this process while a
 * Claude session is running in the background, so the OS is less likely to
 * freeze or kill the app and silently drop the SSH connection.
 *
 * This service carries no SSH or Claude logic of its own: the session lives
 * in the Dart isolate as it always did. Its only job is the ongoing
 * notification [startForeground] requires.
 */
class SshForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "claude_ssh_background"
        private const val NOTIFICATION_ID = 42
        const val ACTION_START = "dev.zoiyo.phone_ssh_client.action.START"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        return START_NOT_STICKY
    }

    // Stopping goes through Context.stopService() (see MainActivity), which
    // calls this directly instead of onStartCommand — never route a stop
    // through startForegroundService(), see the warning on startInForeground.
    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    // Android 15+ (API 35) caps a "dataSync" foreground service at 6 hours of
    // background runtime per rolling 24h window. Past that, the OS calls this
    // instead of just killing the process — but if the service doesn't stop
    // itself promptly, the OS crashes the app with
    // ForegroundServiceDidNotStopInTimeException. A long background SSH
    // session can hit that limit, so stop immediately; Dart's own reconnect
    // logic brings the session back once the app is foregrounded again.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // Must be called within 5 seconds of this service being launched via
    // startForegroundService() (Android 8+), or the OS kills the whole app
    // with ForegroundServiceDidNotStartInTimeException — regardless of what
    // the intent was for. Never launch this service that way for a stop.
    private fun startInForeground() {
        createChannel()
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Exception) {
            // The OS can refuse to promote a background start (e.g. Android
            // 12+ start restrictions). Losing the foreground priority just
            // means the process may get frozen/killed sooner, not a crash.
            stopSelf()
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Claude SSH")
            .setContentText("Keeping your session connected in the background")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun createChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Background connection",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Shown while Claude SSH keeps a session alive in the background"
        manager.createNotificationChannel(channel)
    }
}
