package com.athena.reading

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class IngestionForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "athena_ingestion_channel"
        const val NOTIFICATION_ID = 40401
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_PROGRESS = "extra_progress"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Athena Reading"
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0

        val notification = buildNotification(title, progress)
        startForeground(NOTIFICATION_ID, notification)
        return START_NOT_STICKY
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

    private fun buildNotification(title: String, progress: Int): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle(title)
            .setContentText(if (progress > 0) "Extracting book pages... ($progress%)" else "Processing book...")
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

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.athena.reading/foreground_service"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val title = call.argument<String>("title") ?: "Processing book..."
                    val intent = Intent(this, IngestionForegroundService::class.java).apply {
                        putExtra(IngestionForegroundService.EXTRA_TITLE, title)
                        putExtra(IngestionForegroundService.EXTRA_PROGRESS, 0)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "updateProgress" -> {
                    val progress = call.argument<Int>("progress") ?: 0
                    val title = call.argument<String>("title") ?: "Processing book..."
                    val intent = Intent(this, IngestionForegroundService::class.java).apply {
                        putExtra(IngestionForegroundService.EXTRA_TITLE, title)
                        putExtra(IngestionForegroundService.EXTRA_PROGRESS, progress)
                    }
                    startService(intent)
                    result.success(true)
                }
                "stopService" -> {
                    val intent = Intent(this, IngestionForegroundService::class.java)
                    stopService(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
