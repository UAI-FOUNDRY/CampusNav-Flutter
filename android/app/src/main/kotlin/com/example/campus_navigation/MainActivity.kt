package com.example.campus_navigation

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Flutter app, plus one small native piece: Wi-Fi scans for
 * "Use my location" (lib/services/wifi_fingerprints.dart). Which networks
 * are around, and how strong, tells the room and floor inside buildings,
 * where GPS cannot.
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "campusnav/wifi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scan" -> scan(call.argument<Boolean>("fresh") ?: true, result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Starts a scan and answers with the results when it is done (at most
     * 6 s). Android allows only a few scans a minute; when one is refused
     * the latest results (with their age) are sent straight away.
     */
    private fun scan(fresh: Boolean, result: MethodChannel.Result) {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi == null) {
            result.error("unavailable", "This phone has no Wi-Fi", null)
            return
        }
        if (Build.VERSION.SDK_INT >= 23 &&
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("no_permission", "Scanning Wi-Fi needs the location permission", null)
            return
        }
        if (!fresh) {
            result.success(read(wifi))
            return
        }
        var answered = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (answered) return
                answered = true
                try {
                    unregisterReceiver(this)
                } catch (e: Exception) {
                    // already unregistered
                }
                result.success(read(wifi))
            }
        }
        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                // A system broadcast; the flag is required for receivers since Android 14.
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
        } catch (e: Exception) {
            result.success(read(wifi))
            return
        }
        @Suppress("DEPRECATION")
        val started = try {
            wifi.startScan()
        } catch (e: Exception) {
            false
        }
        main.postDelayed({
            if (!answered) {
                answered = true
                try {
                    unregisterReceiver(receiver)
                } catch (e: Exception) {
                    // already unregistered
                }
                result.success(read(wifi))
            }
        }, if (started) 6000L else 50L)
    }

    /** The latest scan results: id, name, strength, frequency and age. */
    private fun read(wifi: WifiManager): List<Map<String, Any>> {
        val nowMicros = SystemClock.elapsedRealtime() * 1000L
        val results: List<ScanResult> = try {
            wifi.scanResults ?: emptyList()
        } catch (e: SecurityException) {
            emptyList()
        }
        return results.map { r ->
            @Suppress("DEPRECATION")
            val ssid = r.SSID ?: ""
            mapOf(
                "bssid" to (r.BSSID ?: ""),
                "ssid" to ssid,
                "level" to r.level,
                "freq" to r.frequency,
                "ageMs" to ((nowMicros - r.timestamp) / 1000L),
            )
        }
    }
}
