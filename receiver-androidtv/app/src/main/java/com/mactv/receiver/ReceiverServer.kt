package com.mactv.receiver

import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * Accepts one Mac at a time on [port], parses framed messages and hands them to [listener]
 * on the network thread. Control messages (HELLO_ACK, REQUEST_KEYFRAME) go back the same socket.
 */
class ReceiverServer(private val port: Int, private val listener: Listener) {

    interface Listener {
        fun onClientConnected(remote: String)
        fun onHello(info: JSONObject)
        fun onVideoConfig(annexB: ByteArray)
        fun onVideoFrame(annexB: ByteArray, isKeyframe: Boolean, ptsMicros: Long)
        fun onClientDisconnected(reason: String?)
    }

    @Volatile private var running = false
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var client: Socket? = null
    @Volatile private var output: OutputStream? = null
    private val writeLock = Any()
    private var thread: Thread? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread(::run, "mactv-server").apply { start() }
    }

    fun stop() {
        running = false
        try { serverSocket?.close() } catch (_: IOException) {}
        try { client?.close() } catch (_: IOException) {}
    }

    /** Ask the Mac for a keyframe (decoder (re)started or fell behind). Safe from any thread. */
    fun requestKeyframe() {
        // Socket writes must not happen on the main thread.
        Thread { send(Wire.REQUEST_KEYFRAME) }.start()
    }

    private fun run() {
        val server = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(port))
            }
        } catch (e: IOException) {
            Log.e(TAG, "cannot listen on port $port", e)
            running = false
            return
        }
        serverSocket = server
        Log.i(TAG, "listening on port $port")

        while (running) {
            val socket = try { server.accept() } catch (e: IOException) { break }
            socket.tcpNoDelay = true
            socket.receiveBufferSize = 1 shl 20
            client = socket
            output = socket.getOutputStream()
            listener.onClientConnected(socket.inetAddress?.hostAddress ?: "?")
            var reason: String? = null
            try {
                serve(socket)
            } catch (e: IOException) {
                reason = e.message ?: e.javaClass.simpleName
            } finally {
                try { socket.close() } catch (_: IOException) {}
                client = null
                output = null
                listener.onClientDisconnected(reason)
            }
        }
        try { server.close() } catch (_: IOException) {}
        serverSocket = null
        Log.i(TAG, "server stopped")
    }

    @Throws(IOException::class)
    private fun serve(socket: Socket) {
        val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 1 shl 20))
        while (running) {
            val msg = Wire.read(input)
            when (msg.type) {
                Wire.HELLO -> {
                    val info = try {
                        JSONObject(String(msg.payload, Charsets.UTF_8))
                    } catch (e: Exception) {
                        JSONObject()
                    }
                    listener.onHello(info)
                    send(Wire.HELLO_ACK, ackPayload())
                }
                Wire.VIDEO_CONFIG -> listener.onVideoConfig(msg.payload)
                Wire.VIDEO_FRAME -> listener.onVideoFrame(msg.payload, msg.isKeyframe, msg.ptsMicros)
                else -> Log.d(TAG, "ignoring message type ${msg.type} (${msg.payload.size} bytes)")
            }
        }
    }

    private fun ackPayload(): ByteArray = JSONObject()
        .put("v", Wire.VERSION)
        .put("name", Build.MODEL)
        .put("maxWidth", 1920)
        .put("maxHeight", 1080)
        .toString()
        .toByteArray(Charsets.UTF_8)

    private fun send(type: Int, payload: ByteArray = ByteArray(0)) {
        val out = output ?: return
        synchronized(writeLock) {
            try {
                out.write(Wire.encode(type, payload = payload))
                out.flush()
            } catch (e: IOException) {
                Log.w(TAG, "control send failed: ${e.message}")
            }
        }
    }

    companion object {
        private const val TAG = "mactv.server"
    }
}
