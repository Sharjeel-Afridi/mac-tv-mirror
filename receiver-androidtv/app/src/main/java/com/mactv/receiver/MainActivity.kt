package com.mactv.receiver

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Full-screen receiver. The TCP server lives for as long as the activity is started; the decoder
 * lives for as long as there is a surface to draw on. Frames that arrive without a decoder are
 * dropped, and a keyframe is requested when the decoder comes back.
 */
class MainActivity : Activity(), SurfaceHolder.Callback, ReceiverServer.Listener {

    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private val ui = Handler(Looper.getMainLooper())

    private var server: ReceiverServer? = null
    @Volatile private var decoder: VideoDecoder? = null
    private var advertiser: DiscoveryAdvertiser? = null

    @Volatile private var lastConfig: ByteArray? = null
    @Volatile private var streamWidth = 1920
    @Volatile private var streamHeight = 1080
    @Volatile private var overlayVisible = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        surfaceView = findViewById(R.id.surface)
        statusView = findViewById(R.id.status)
        surfaceView.holder.addCallback(this)
        hideSystemUi()
    }

    override fun onStart() {
        super.onStart()
        server = ReceiverServer(Wire.DEFAULT_PORT, this).also { it.start() }
        advertiser = DiscoveryAdvertiser(this).also { it.start(Wire.DEFAULT_PORT) }
        showWaiting()
        // Re-render once NSD has settled on a name.
        ui.postDelayed({ if (overlayVisible) showWaiting() }, 1500)
    }

    override fun onStop() {
        super.onStop()
        advertiser?.stop()
        advertiser = null
        server?.stop()
        server = null
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    // MARK: SurfaceHolder.Callback

    override fun surfaceCreated(holder: SurfaceHolder) {
        val d = VideoDecoder(holder.surface, ::onOutputSize) { server?.requestKeyframe() }
        d.setStreamSize(streamWidth, streamHeight)
        decoder = d
        lastConfig?.let { d.configure(it) }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        decoder?.stop()
        decoder = null
    }

    // MARK: ReceiverServer.Listener (network thread)

    override fun onClientConnected(remote: String) {
        ui.post { setOverlay(getString(R.string.connecting, remote)) }
    }

    override fun onHello(info: JSONObject) {
        streamWidth = info.optInt("width", 1920)
        streamHeight = info.optInt("height", 1080)
        decoder?.setStreamSize(streamWidth, streamHeight)
        val name = info.optString("name", "Mac")
        Log.i(TAG, "hello from $name ${streamWidth}x$streamHeight @ ${info.optInt("fps")} fps")
        ui.post { setOverlay(getString(R.string.connected, name)) }
    }

    override fun onVideoConfig(annexB: ByteArray) {
        lastConfig = annexB
        decoder?.configure(annexB)
    }

    override fun onVideoFrame(annexB: ByteArray, isKeyframe: Boolean, ptsMicros: Long) {
        decoder?.submit(annexB, isKeyframe, ptsMicros)
        if (overlayVisible) {
            overlayVisible = false
            ui.post { statusView.visibility = View.GONE }
        }
    }

    override fun onClientDisconnected(reason: String?) {
        Log.i(TAG, "sender disconnected: $reason")
        lastConfig = null
        decoder?.stop()
        ui.post { showWaiting() }
    }

    // MARK: UI

    private fun onOutputSize(w: Int, h: Int) {
        ui.post { fitSurface(w, h) }
    }

    /** Letterbox/pillarbox the video inside the screen, keeping its aspect ratio. */
    private fun fitSurface(videoW: Int, videoH: Int) {
        val parent = surfaceView.parent as? View ?: return
        val pw = parent.width
        val ph = parent.height
        if (pw == 0 || ph == 0 || videoW <= 0 || videoH <= 0) return
        val scale = minOf(pw.toFloat() / videoW, ph.toFloat() / videoH)
        val lp = surfaceView.layoutParams as FrameLayout.LayoutParams
        val newW = (videoW * scale).toInt()
        val newH = (videoH * scale).toInt()
        if (lp.width == newW && lp.height == newH) return
        lp.width = newW
        lp.height = newH
        lp.gravity = Gravity.CENTER
        surfaceView.layoutParams = lp
    }

    private fun showWaiting() {
        val ip = localIpv4() ?: "no Wi-Fi address"
        val bonjour = advertiser?.registeredName ?: DiscoveryAdvertiser.defaultName()
        setOverlay(getString(R.string.waiting_detail, ip, Wire.DEFAULT_PORT, bonjour))
    }

    private fun setOverlay(text: String) {
        overlayVisible = true
        statusView.text = text
        statusView.visibility = View.VISIBLE
    }

    private fun hideSystemUi() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
    }

    private fun localIpv4(): String? = try {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { it.isSiteLocalAddress }
            ?.hostAddress
    } catch (e: Exception) {
        null
    }

    companion object {
        private const val TAG = "mactv.main"
    }
}
