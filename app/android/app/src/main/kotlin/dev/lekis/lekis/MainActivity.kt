package dev.lekis.lekis

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service 要求 Activity 继承 AudioServiceActivity，Flutter 引擎才能和后台媒体服务共用。
class MainActivity : AudioServiceActivity() {
    // Android 默认丢弃 Wi-Fi 组播包；mDNS / SSDP 扫描期间要短暂持有这把锁。
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Rust 核心的音频输出（cpal → AAudio）需要 JavaVM 和 Context，必须在 Dart 调用核心之前登记。
        System.loadLibrary("lekis_bridge")
        initRustAndroidContext(applicationContext)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DISCOVERY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> result.success(acquireMulticastLock())
                "release" -> {
                    releaseMulticastLock()
                    result.success(true)
                }
                "deviceName" -> result.success(deviceName())
                "openUrl" -> {
                    val url = call.argument<String>("url").orEmpty()
                    result.success(openExternalUrl(url))
                }
                else -> result.notImplemented()
            }
        }
    }

    // 用户在系统设置里起的名字（"Fold5"）；拿不到就用厂商 + 型号。
    // Connect 设备列表里显示它，比 "Android 设备" 好认。
    private fun deviceName(): String {
        val named = runCatching {
            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        }.getOrNull()
        if (!named.isNullOrBlank()) return named.trim()
        val model = Build.MODEL.orEmpty().trim()
        val maker = Build.MANUFACTURER.orEmpty().trim()
        return when {
            model.isEmpty() -> maker
            maker.isEmpty() || model.startsWith(maker, ignoreCase = true) -> model
            else -> "${maker.replaceFirstChar { it.uppercase() }} $model"
        }
    }

    private fun openExternalUrl(rawUrl: String): Boolean {
        val uri = runCatching { Uri.parse(rawUrl.trim()) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") return false
        return runCatching {
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        }.getOrDefault(false)
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }

    /// 拿不到锁（没有 Wi-Fi、系统限制……）时返回 false，但扫描仍然继续。
    private fun acquireMulticastLock(): Boolean = try {
        val lock = multicastLock ?: run {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifi?.createMulticastLock(MULTICAST_LOCK_TAG)?.also {
                it.setReferenceCounted(false)
                multicastLock = it
            }
        }
        if (lock != null && !lock.isHeld) lock.acquire()
        lock?.isHeld == true
    } catch (e: Exception) {
        false
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
            // 释放失败也不影响扫描结果，进程退出时系统会回收。
        }
        multicastLock = null
    }

    companion object {
        private const val DISCOVERY_CHANNEL = "dev.lekis.lekis/discovery"
        private const val MULTICAST_LOCK_TAG = "lekis-discovery"

        @JvmStatic
        external fun initRustAndroidContext(context: Context)
    }
}
