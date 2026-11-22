package com.lightwave.tama

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** USB serial adapters for Dart: method channel "tama/usb", received bytes on event channel "tama/usb/rx". */
class UsbSerialBridge(private val ctx: Context, messenger: BinaryMessenger) : SerialInputOutputManager.Listener {
    private val usb = ctx.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private var port: UsbSerialPort? = null
    private var io: SerialInputOutputManager? = null
    private var sink: EventChannel.EventSink? = null
    private val writer = Executors.newSingleThreadExecutor()

    init {
        MethodChannel(messenger, "tama/usb").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "list" -> result.success(list())
                    "open" -> open(call.argument<Int>("id")!!, call.argument<Int>("baud") ?: 460800, result)
                    "write" -> {
                        val data = call.argument<ByteArray>("data")!!
                        val p = port ?: return@setMethodCallHandler result.error("closed", "not open", null)
                        writer.execute {
                            try { p.write(data, 2000); main.post { result.success(null) } }
                            catch (e: Exception) { main.post { result.error("write", e.message, null) } }
                        }
                    }
                    "baud" -> { port?.setParameters(call.argument<Int>("baud")!!, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE); result.success(null) }
                    "signals" -> {
                        call.argument<Boolean>("dtr")?.let { port?.dtr = it }
                        call.argument<Boolean>("rts")?.let { port?.rts = it }
                        result.success(null)
                    }
                    "close" -> { close(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("usb", e.message, null)
            }
        }
        EventChannel(messenger, "tama/usb/rx").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, events: EventChannel.EventSink?) { sink = events }
            override fun onCancel(args: Any?) { sink = null }
        })
    }

    private fun list(): List<Map<String, Any?>> =
        UsbSerialProber.getDefaultProber().findAllDrivers(usb).map { d ->
            val dev = d.device
            mapOf("id" to dev.deviceId, "name" to (dev.productName ?: dev.deviceName), "vid" to dev.vendorId, "pid" to dev.productId,
                "driver" to d.javaClass.simpleName.removeSuffix("SerialDriver"))
        }

    private fun open(id: Int, baud: Int, result: MethodChannel.Result) {
        val driver = UsbSerialProber.getDefaultProber().findAllDrivers(usb).firstOrNull { it.device.deviceId == id }
            ?: return result.error("usb", "adapter not found", null)
        val dev = driver.device
        if (!usb.hasPermission(dev)) {
            askPermission(dev) { ok -> if (ok) open(id, baud, result) else result.error("usb", "permission denied", null) }
            return
        }
        close()
        val conn = usb.openDevice(dev) ?: return result.error("usb", "could not open the adapter", null)
        val p = driver.ports[0]
        p.open(conn)
        p.setParameters(baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
        try { p.dtr = true; p.rts = true } catch (_: Exception) {}
        port = p
        io = SerialInputOutputManager(p, this).also { it.start() }
        result.success(null)
    }

    private fun askPermission(dev: UsbDevice, done: (Boolean) -> Unit) {
        val action = "com.lightwave.tama.USB_PERMISSION"
        val rx = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                ctx.unregisterReceiver(this)
                done(i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            }
        }
        if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(rx, IntentFilter(action), Context.RECEIVER_NOT_EXPORTED)
        else ctx.registerReceiver(rx, IntentFilter(action))
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(ctx, 0, Intent(action).setPackage(ctx.packageName), flags)
        usb.requestPermission(dev, pi)
    }

    fun close() {
        io?.listener = null
        io?.stop()
        io = null
        try { port?.close() } catch (_: Exception) {}
        port = null
    }

    override fun onNewData(data: ByteArray) { main.post { sink?.success(data) } }

    override fun onRunError(e: Exception) {
        main.post { sink?.error("usb", e.message, null); close() }
    }
}
