package com.aeris.sdk

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import com.google.gson.JsonObject
import java.util.concurrent.atomic.AtomicLong

/** 同一 Engine 的订阅共享监听，最后一个订阅离开时释放。 */
class NetworkStatusEventProvider(context: Context) : BridgeSnapshotEventProvider {
    private val connectivity = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val generation = AtomicLong()
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun start(publish: (JsonObject) -> Unit) {
        check(callback == null) { "Provider already observing" }
        val epoch = generation.incrementAndGet()
        fun changed() { if (generation.get() == epoch) publish(snapshot()) }
        val listener = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = changed()
            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) = changed()
        }
        connectivity.registerDefaultNetworkCallback(listener)
        callback = listener
    }
    override fun snapshot(): JsonObject {
        val capabilities = connectivity.activeNetwork?.let(connectivity::getNetworkCapabilities)
        val available = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        val validated = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        val kind = when {
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cellular"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "wired"
            else -> "other"
        }
        val metered = capabilities != null && connectivity.isActiveNetworkMetered
        return SystemEventSnapshots.network(available, validated, kind, metered,
            metered && connectivity.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED)
    }
    override fun stop() {
        generation.incrementAndGet()
        val old = callback
        callback = null
        if (old != null) runCatching { connectivity.unregisterNetworkCallback(old) }
    }
}
