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
                else -> result.notImplemented()
            }
        }
    }
}
