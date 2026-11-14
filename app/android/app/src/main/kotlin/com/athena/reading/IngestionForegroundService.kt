package com.athena.reading

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat

class IngestionForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "athena_ingestion_channel"
        const val NOTIFICATION_ID = 40401
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_PROGRESS = "extra_progress"
        const val EXTRA_PAGE = "extra_page"
        const val EXTRA_TOTAL = "extra_total"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Athena Reading"
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
        val page = intent?.getIntExtra(EXTRA_PAGE, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0

        val notification = buildNotification(title, progress, page, total)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, 0)
        }
        return START_REDELIVER_INTENT
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 / API 35 requirement:
        // Signal pause/checkpoint and stop within 2 seconds so OS never kills process with ForegroundServiceDidNotStopInTimeException
        try {
            stopSelf(startId)
        } catch (_: Exception) {
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Athena Document Ingestion",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows progress during book ingestion"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, progress: Int, page: Int, total: Int): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val contentText = when {
            page > 0 && total > 0 -> "Extracting page $page of $total ($progress%)..."
            progress > 0 -> "Extracting book pages... ($progress%)"
            else -> "Processing book..."
        }

        builder.setContentTitle(title)
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)

        if (progress in 1..99) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }

        return builder.build()
    }
}

