package com.lightwave.tama

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import kotlin.concurrent.thread

/** The toy's buzzer: a square wave streamed to an AudioTrack while a tone is on. */
object TamaTone {
    private const val RATE = 44100
    @Volatile private var freq = 4096.0
    @Volatile private var on = false
    @Volatile private var volume = 0.35f
    private var worker: Thread? = null
    private val lock = Object()

    fun set(f: Double, o: Boolean, v: Float) {
        freq = if (f < 100) 100.0 else f
        on = o
        volume = v.coerceIn(0f, 1f)
        if (o) ensure()
    }

    private fun ensure() = synchronized(lock) {
        if (worker?.isAlive == true) return
        worker = thread(name = "tama-tone", isDaemon = true) { run() }
    }

    private fun run() {
        val min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(maxOf(min, 4096))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track.play()
        val buf = ShortArray(512)
        var phase = 0.0
        var level = 0f
        var idle = 0
        try {
            while (true) {
                val target = if (on) volume else 0f
                val step = freq / RATE
                for (i in buf.indices) {
                    level += (target - level) * 0.01f
                    phase += step
                    if (phase >= 1) phase -= 1
                    buf[i] = ((if (phase < 0.5) 1 else -1) * level * 12000).toInt().toShort()
                }
                track.write(buf, 0, buf.size)
                if (!on && level < 0.001f) { if (++idle > 400) break } else idle = 0   // ~5 s of silence: stop
            }
        } finally {
            track.stop()
            track.release()
        }
    }
}
