package com.mactv.receiver

import java.io.DataInputStream
import java.io.IOException
import java.nio.ByteBuffer

/** Wire protocol v1. See PROTOCOL.md at the repository root. All integers are big-endian. */
object Wire {
    const val VERSION = 1
    const val HEADER_SIZE = 16
    const val MAX_PAYLOAD = 16 * 1024 * 1024
    const val DEFAULT_PORT = 7000
    const val SERVICE_TYPE = "_mactvmirror._tcp."

    const val HELLO = 0x01
    const val VIDEO_CONFIG = 0x02
    const val VIDEO_FRAME = 0x03
    const val AUDIO_CONFIG = 0x04
    const val AUDIO_FRAME = 0x05
    const val HELLO_ACK = 0x10
    const val REQUEST_KEYFRAME = 0x11

    const val FLAG_KEYFRAME = 0x01

    private val EMPTY = ByteArray(0)

    class Message(val type: Int, val flags: Int, val ptsMicros: Long, val payload: ByteArray) {
        val isKeyframe: Boolean get() = flags and FLAG_KEYFRAME != 0
    }

    /** Blocks until one complete message has been read. Throws on EOF or a corrupt header. */
    @Throws(IOException::class)
    fun read(input: DataInputStream): Message {
        val type = input.readUnsignedByte()
        val flags = input.readUnsignedByte()
        input.readUnsignedShort() // reserved
        val pts = input.readLong()
        val length = input.readInt()
        if (length < 0 || length > MAX_PAYLOAD) throw IOException("bad payload length $length")
        val payload = ByteArray(length)
        input.readFully(payload)
        return Message(type, flags, pts, payload)
    }

    fun encode(type: Int, flags: Int = 0, ptsMicros: Long = 0L, payload: ByteArray = EMPTY): ByteArray {
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size)
        buf.put(type.toByte())
        buf.put(flags.toByte())
        buf.putShort(0)
        buf.putLong(ptsMicros)
        buf.putInt(payload.size)
        buf.put(payload)
        return buf.array()
    }
}
