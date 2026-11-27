package com.lightwave.tama

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var usb: UsbSerialBridge? = null
    private var channel: MethodChannel? = null

    /** The game whose notification was tapped, until the app has taken it. */
    private var opened: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        opened = intent?.getStringExtra("game")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("game")?.let {
            opened = it
            channel?.invokeMethod("opened", it)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usb = UsbSerialBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tama/native")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeOpened" -> {
                    result.success(opened)
                    opened = null
                }
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
                "power" -> {
                    val hold = call.argument<Boolean>("hold") ?: true
                    val wakeIn = call.argument<Int>("wakeIn") ?: 0
                    TamaService.cancelWake(this)
                    if (!hold && wakeIn > 0) TamaService.wakeIn(this, wakeIn)
                    TamaService.hold(this, hold)
                    result.success(null)
                }
                "appVersion" -> {
                    val pi = packageManager.getPackageInfo(packageName, 0)
                    @Suppress("DEPRECATION")
                    val code = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode.toInt() else pi.versionCode
                    result.success(code)
                }
                "installApk" -> {
                    // the downloaded update, handed to Android's installer (the user confirms)
                    try {
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                android.net.Uri.parse("package:$packageName")))
                            result.success("Allow Tama to install updates, then press Update again.")
                        } else {
                            val f = java.io.File(call.argument<String>("path")!!)
                            val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.updates", f)
                            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success("ok")
                        }
                    } catch (e: Exception) {
                        result.success("The installer did not open: ${e.message}")
                    }
                }
                "openSettings" -> {
                    startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        android.net.Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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
                    val game = call.argument<String>("game")
                    val open = android.app.PendingIntent.getActivity(this, (game ?: "").hashCode(),
                        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra("game", game),
                        android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
                    // the game's screen as it was when the pet called
                    val screen = call.argument<String>("image")?.let { android.graphics.BitmapFactory.decodeFile(it) }
                    @Suppress("DEPRECATION")
                    val b = if (Build.VERSION.SDK_INT >= 26) android.app.Notification.Builder(this, "calls") else android.app.Notification.Builder(this)
                    nm.notify((System.currentTimeMillis() % 100000).toInt() + 10, b.setContentTitle(call.argument<String>("title") ?: "Tama")
                        .setContentText(call.argument<String>("body") ?: "")
                        .setSmallIcon(R.drawable.ic_notify).setColor(0xFF0B4A8B.toInt())
                        .setLargeIcon(screen ?: android.graphics.BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher))
                        .also { if (screen != null) it.setStyle(android.app.Notification.BigPictureStyle().bigPicture(screen)) }
                        .setAutoCancel(true).setContentIntent(open).build())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
