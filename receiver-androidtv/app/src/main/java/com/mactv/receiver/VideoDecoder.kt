package com.mactv.receiver

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Feeds Annex-B H.264 access units into the TV's hardware decoder, rendering straight to [surface].
 *
 * Latency policy: every decoded frame is rendered immediately (no timestamp pacing). If the input
 * queue backs up, it is flushed and a keyframe is requested so the picture resyncs instead of
 * drifting further behind the Mac.
 */
class VideoDecoder(
    private val surface: Surface,
    private val onOutputSize: (width: Int, height: Int) -> Unit,
    private val onNeedKeyframe: () -> Unit,
) {
    private class Frame(val data: ByteArray, val isKeyframe: Boolean, val ptsMicros: Long)

    private val queue = LinkedBlockingQueue<Frame>()
    @Volatile private var codec: MediaCodec? = null
    @Volatile private var running = false
    @Volatile private var waitingForKeyframe = true
    private var thread: Thread? = null
    private var width = 1920
    private var height = 1080
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null

    @Volatile var decodedFrames = 0L
        private set

    fun setStreamSize(w: Int, h: Int) {
        if (w > 0 && h > 0) {
            width = w
            height = h
        }
    }

    /** Annex-B SPS+PPS from a VIDEO_CONFIG message or a keyframe. (Re)starts the codec if they changed. */
    @Synchronized
    fun configure(annexB: ByteArray) {
        val nals = splitNals(annexB)
        val newSps = nals.firstOrNull { nalType(it) == NAL_SPS }
        val newPps = nals.firstOrNull { nalType(it) == NAL_PPS }
        if (newSps == null || newPps == null) {
            Log.w(TAG, "config without SPS/PPS (${nals.size} NALs)")
            return
        }
        if (codec != null && newSps.contentEquals(sps) && newPps.contentEquals(pps)) return
        sps = newSps
        pps = newPps
        restart()
    }

    fun submit(data: ByteArray, isKeyframe: Boolean, ptsMicros: Long) {
        if (codec == null) {
            // No VIDEO_CONFIG seen (or codec died): keyframes carry SPS/PPS in-band, use those.
            if (!isKeyframe) return
            configure(data)
            if (codec == null) return
        }
        if (waitingForKeyframe) {
            if (!isKeyframe) return
            waitingForKeyframe = false
        }
        if (queue.size >= MAX_QUEUED) {
            queue.clear()
            if (!isKeyframe) {
                waitingForKeyframe = true
                Log.w(TAG, "decoder behind; flushed queue, requesting keyframe")
                onNeedKeyframe()
                return
            }
        }
        queue.offer(Frame(data, isKeyframe, ptsMicros))
    }

    @Synchronized
    fun stop() {
        running = false
        thread?.let { t ->
            t.interrupt()
            try { t.join(1000) } catch (_: InterruptedException) {}
        }
        thread = null
        releaseCodec()
        queue.clear()
        waitingForKeyframe = true
    }

    // MARK: internals

    private fun restart() {
        stop()
        val c = try {
            createCodec()
        } catch (e: Exception) {
            Log.e(TAG, "cannot create H.264 decoder", e)
            return
        }
        codec = c
        running = true
        waitingForKeyframe = true
        thread = Thread(::loop, "mactv-decoder").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        onNeedKeyframe()
    }

    private fun createCodec(): MediaCodec {
        val mime = MediaFormat.MIMETYPE_VIDEO_AVC
        val c = MediaCodec.createDecoderByType(mime)
        var lowLatency = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val caps = c.codecInfo.getCapabilitiesForType(mime)
            lowLatency = caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        }
        try {
            c.configure(buildFormat(mime, lowLatency), surface, null, 0)
        } catch (e: Exception) {
            if (!lowLatency) throw e
            Log.w(TAG, "low-latency configure refused, retrying without: ${e.message}")
            c.reset()
            c.configure(buildFormat(mime, false), surface, null, 0)
            lowLatency = false
        }
        c.start()
        Log.i(TAG, "decoder ${c.name} ${width}x$height low-latency=$lowLatency")
        return c
    }

    private fun buildFormat(mime: String, lowLatency: Boolean): MediaFormat =
        MediaFormat.createVideoFormat(mime, width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(START_CODE + sps!!))
            setByteBuffer("csd-1", ByteBuffer.wrap(START_CODE + pps!!))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
            if (lowLatency && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }

    private fun releaseCodec() {
        codec?.let { c ->
            try { c.stop() } catch (_: Exception) {}
            try { c.release() } catch (_: Exception) {}
        }
        codec = null
    }

    private fun loop() {
        val c = codec ?: return
        val info = MediaCodec.BufferInfo()
        var pending: Frame? = null
        while (running) {
            try {
                if (pending == null) pending = queue.poll(2, TimeUnit.MILLISECONDS)
                val frame = pending
                if (frame != null) {
                    val idx = c.dequeueInputBuffer(2_000)
                    if (idx >= 0) {
                        val buf = c.getInputBuffer(idx)
                        if (buf == null || frame.data.size > buf.capacity()) {
                            Log.w(TAG, "frame of ${frame.data.size} bytes does not fit input buffer; skipped")
                            c.queueInputBuffer(idx, 0, 0, 0, 0)
                        } else {
                            buf.clear()
                            buf.put(frame.data)
                            val flags = if (frame.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                            c.queueInputBuffer(idx, 0, frame.data.size, frame.ptsMicros, flags)
                        }
                        pending = null
                    }
                }
                drainOutput(c, info)
            } catch (e: InterruptedException) {
                break
            } catch (e: IllegalStateException) {
                // MediaCodec.CodecException is an IllegalStateException. Drop the codec; the next
                // keyframe's in-band SPS/PPS will rebuild it.
                if (running) {
                    Log.e(TAG, "decoder error, will rebuild on next keyframe", e)
                    running = false
                    releaseCodec()
                    queue.clear()
                    waitingForKeyframe = true
                    onNeedKeyframe()
                }
                break
            }
        }
    }

    private fun drainOutput(c: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val out = c.dequeueOutputBuffer(info, 0)
            when {
                out >= 0 -> {
                    c.releaseOutputBuffer(out, true)
                    decodedFrames++
                }
                out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = c.outputFormat
                    val w = if (f.containsKey("crop-right") && f.containsKey("crop-left"))
                        f.getInteger("crop-right") - f.getInteger("crop-left") + 1
                    else f.getInteger(MediaFormat.KEY_WIDTH)
                    val h = if (f.containsKey("crop-bottom") && f.containsKey("crop-top"))
                        f.getInteger("crop-bottom") - f.getInteger("crop-top") + 1
                    else f.getInteger(MediaFormat.KEY_HEIGHT)
                    Log.i(TAG, "output ${w}x$h")
                    onOutputSize(w, h)
                }
                else -> return
            }
        }
    }

    companion object {
        private const val TAG = "mactv.decoder"
        private const val MAX_QUEUED = 6
        private const val NAL_SPS = 7
        private const val NAL_PPS = 8
        private val START_CODE = byteArrayOf(0, 0, 0, 1)

        private fun nalType(nal: ByteArray): Int = if (nal.isEmpty()) -1 else nal[0].toInt() and 0x1f

        /** Split an Annex-B byte stream into NAL units (start codes removed, 3- and 4-byte forms). */
        fun splitNals(data: ByteArray): List<ByteArray> {
            val out = ArrayList<ByteArray>()
            var i = 0
            var payloadStart = -1
            while (i + 2 < data.size) {
                if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                    if (payloadStart >= 0) {
                        var end = i
                        if (end > payloadStart && data[end - 1].toInt() == 0) end-- // 4-byte start code
                        if (end > payloadStart) out.add(data.copyOfRange(payloadStart, end))
                    }
                    i += 3
                    payloadStart = i
                } else {
                    i++
                }
            }
            if (payloadStart in 0 until data.size) out.add(data.copyOfRange(payloadStart, data.size))
            return out
        }
    }
}
