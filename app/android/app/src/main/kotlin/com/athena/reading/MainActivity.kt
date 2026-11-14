package com.athena.reading

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNELS = listOf("athena/foreground_ingestion", "com.athena.reading/foreground_service")
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 40402

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        for (channel in CHANNELS) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundService", "startService" -> {
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
                    "updateForegroundProgress", "updateProgress" -> {
                        val progress = call.argument<Int>("percent") ?: call.argument<Int>("progress") ?: 0
                        val page = call.argument<Int>("page") ?: 0
                        val total = call.argument<Int>("total") ?: 0
                        val title = call.argument<String>("title") ?: "Processing book..."
                        val intent = Intent(this, IngestionForegroundService::class.java).apply {
                            putExtra(IngestionForegroundService.EXTRA_TITLE, title)
                            putExtra(IngestionForegroundService.EXTRA_PROGRESS, progress)
                            putExtra(IngestionForegroundService.EXTRA_PAGE, page)
                            putExtra(IngestionForegroundService.EXTRA_TOTAL, total)
                        }
                        startService(intent)
                        result.success(true)
                    }
                    "stopForegroundService", "stopService" -> {
                        val intent = Intent(this, IngestionForegroundService::class.java)
                        stopService(intent)
                        result.success(true)
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (ContextCompat.checkSelfPermission(
                                    this,
                                    Manifest.permission.POST_NOTIFICATIONS
                                ) != PackageManager.PERMISSION_GRANTED
                            ) {
                                ActivityCompat.requestPermissions(
                                    this,
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                    NOTIFICATION_PERMISSION_REQUEST_CODE
                                )
                                result.success(true)
                            } else {
                                result.success(true)
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
