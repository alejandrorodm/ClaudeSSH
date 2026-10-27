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
        const val ACTION_STOP = "dev.zoiyo.phone_ssh_client.action.STOP"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> startInForeground()
        }
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
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
