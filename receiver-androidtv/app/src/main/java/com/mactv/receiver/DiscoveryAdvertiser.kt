package com.mactv.receiver

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log

/** Advertises this TV as `_mactvmirror._tcp` so `mactv discover` can find it. */
class DiscoveryAdvertiser(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.RegistrationListener? = null

    /** The name actually registered (Android appends " (2)" etc. on collisions). */
    @Volatile var registeredName: String? = null
        private set

    fun start(port: Int, name: String = defaultName()) {
        if (listener != null) return
        val info = NsdServiceInfo()
        info.serviceName = name
        info.serviceType = Wire.SERVICE_TYPE
        info.port = port
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {
                registeredName = i.serviceName
                Log.i(TAG, "advertising as \"${i.serviceName}\" on port $port")
            }
            override fun onRegistrationFailed(i: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "registration failed: $errorCode")
            }
            override fun onServiceUnregistered(i: NsdServiceInfo) {
                registeredName = null
            }
            override fun onUnregistrationFailed(i: NsdServiceInfo, errorCode: Int) {}
        }
        listener = l
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let { l ->
            try { nsd.unregisterService(l) } catch (_: Exception) {}
        }
        listener = null
        registeredName = null
    }

    companion object {
        private const val TAG = "mactv.nsd"
        fun defaultName(): String = Build.MODEL.ifBlank { "Android TV" }.take(40)
    }
}
