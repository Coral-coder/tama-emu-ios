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

    /** Changes of the tone to come, in time order: (when in System.nanoTime, frequency, on). */
    private class Change(val at: Long, val freq: Double, val on: Boolean)
    private val queue = ArrayDeque<Change>()

    fun set(f: Double, o: Boolean, v: Float) {
        synchronized(queue) { queue.clear() }
        freq = if (f < 100) 100.0 else f
        on = o
        volume = v.coerceIn(0f, 1f)
        if (o) ensure()
    }

    /**
     * A change of the tone [delayMs] from now. The player makes it at the very sample of its own
     * steady count of samples, so a melody sent ahead of time keeps its rhythm.
     */
    fun schedule(f: Double, o: Boolean, v: Float, delayMs: Long) {
        val at = System.nanoTime() + delayMs.coerceAtLeast(0) * 1_000_000
        volume = v.coerceIn(0f, 1f)
        synchronized(queue) {
            // what was planned after this moment is replaced by it
            while (queue.isNotEmpty() && queue.last().at >= at) queue.removeLast()
            queue.addLast(Change(at, if (f < 100) 100.0 else f, o))
            while (queue.size > 64) queue.removeFirst()
        }
        ensure()
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
        val buf = ShortArray(256)
        var phase = 0.0
        var level = 0f
        var idle = 0
        // the samples written so far are the clock: sample n sounds at base + n / RATE (plus the
        // track's own, constant, delay). Writing blocks, so the count follows real time; when it
        // falls behind (a stall), the base moves with it.
        var base = System.nanoTime()
        var n = 0L
        val perSample = 1_000_000_000.0 / RATE
        try {
            while (true) {
                val now = System.nanoTime()
                val behind = now - (base + (n * perSample).toLong())
                if (behind > 60_000_000 || behind < -200_000_000) base += behind
                val blockAt = base + (n * perSample).toLong()
                val due = synchronized(queue) {
                    val l = ArrayList<Change>()
                    while (queue.isNotEmpty() && queue.first().at < blockAt + (buf.size * perSample).toLong()) l.add(queue.removeFirst())
                    l
                }
                var next = 0
                var target = if (on) volume else 0f
                var step = freq / RATE
                for (i in buf.indices) {
                    while (next < due.size && due[next].at <= blockAt + (i * perSample).toLong()) {
                        freq = due[next].freq
                        on = due[next].on
                        target = if (on) volume else 0f
                        step = freq / RATE
                        next++
                    }
                    level += (target - level) * 0.01f
                    phase += step
                    if (phase >= 1) phase -= 1
                    buf[i] = ((if (phase < 0.5) 1 else -1) * level * 12000).toInt().toShort()
                }
                track.write(buf, 0, buf.size)
                n += buf.size
                val waiting = synchronized(queue) { queue.isNotEmpty() }
                if (!on && !waiting && level < 0.001f) { if (++idle > 800) break } else idle = 0   // ~5 s of silence: stop
            }
        } finally {
            track.stop()
            track.release()
        }
    }
}
