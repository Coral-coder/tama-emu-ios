package com.lightwave.tama

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var usb: UsbSerialBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usb = UsbSerialBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tama/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "tone" -> {
                    val freq = call.argument<Double>("freq") ?: 4096.0
                    val on = call.argument<Boolean>("on") ?: false
                    val vol = call.argument<Double>("volume") ?: 0.35
                    TamaTone.set(freq, on, vol.toFloat())
                    result.success(null)
                }
                "keepAlive" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    val i = Intent(this, TamaService::class.java)
                    if (on) {
                        i.putExtra("title", call.argument<String>("title") ?: "Tama")
                        i.putExtra("text", call.argument<String>("text") ?: "Your Tamagotchi keeps living")
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    } else {
                        stopService(i)
                    }
                    result.success(null)
                }
                "keepScreenOn" -> {
                    if (call.argument<Boolean>("on") == true) window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                "askToNotify" -> {
                    if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 7)
                    result.success(null)
                }
                "notify" -> {
                    val nm = getSystemService(android.app.NotificationManager::class.java)
                    if (Build.VERSION.SDK_INT >= 26) {
                        nm.createNotificationChannel(android.app.NotificationChannel("calls", "Your Tamagotchi calling", android.app.NotificationManager.IMPORTANCE_HIGH))
                    }
                    val open = android.app.PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), android.app.PendingIntent.FLAG_IMMUTABLE)
                    @Suppress("DEPRECATION")
                    val b = if (Build.VERSION.SDK_INT >= 26) android.app.Notification.Builder(this, "calls") else android.app.Notification.Builder(this)
                    nm.notify((System.currentTimeMillis() % 100000).toInt() + 10, b.setContentTitle(call.argument<String>("title") ?: "Tama")
                        .setContentText(call.argument<String>("body") ?: "")
                        .setSmallIcon(R.mipmap.ic_launcher).setAutoCancel(true).setContentIntent(open).build())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
