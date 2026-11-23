package com.lightwave.tama

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock

/** Keeps the process (and with it the Dart emulator) running while the app is in the background. */
class TamaService : Service() {
    companion object {
        private var wake: PowerManager.WakeLock? = null

        /** The processor stays up while a console is awake; while they all sleep it may rest. */
        fun hold(c: Context, on: Boolean) {
            if (on) {
                if (wake == null) {
                    wake = (c.getSystemService(POWER_SERVICE) as PowerManager)
                        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tama:emulator").also { it.setReferenceCounted(false) }
                }
                if (wake?.isHeld != true) wake?.acquire()
            } else {
                wake?.let { if (it.isHeld) it.release() }
            }
        }

        private fun pending(c: Context): PendingIntent = PendingIntent.getBroadcast(
            c, 1, Intent(c, TamaWake::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        /** Wakes the phone when the sleeping consoles' next alarm rings. */
        fun wakeIn(c: Context, seconds: Int) {
            val am = c.getSystemService(AlarmManager::class.java)
            val at = SystemClock.elapsedRealtime() + seconds * 1000L
            if (Build.VERSION.SDK_INT >= 23) am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending(c))
            else am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending(c))
        }

        fun cancelWake(c: Context) {
            c.getSystemService(AlarmManager::class.java).cancel(pending(c))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "Tama"
        val text = intent?.getStringExtra("text") ?: "Your Tamagotchi keeps living"
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("tama", "Running toy", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "tama") else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setContentTitle(title).setContentText(text).setSmallIcon(R.drawable.ic_notify).setColor(0xFF0B4A8B.toInt())
                        .setLargeIcon(android.graphics.BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher)).setOngoing(true).setContentIntent(open).build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, n)
        }
        hold(this, true)
        return START_STICKY
    }

    override fun onDestroy() {
        hold(this, false)
        cancelWake(this)
        super.onDestroy()
    }
}

/** The alarm set by [TamaService.wakeIn]: the processor is held a moment so the emulator runs the
 *  console's wake-up; the emulator then holds it on for as long as the console stays awake. */
class TamaWake : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        TamaService.hold(c, true)
    }
}
